const std = @import("std");

const Io = std.Io;

const Config = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 9001,
    conns: usize = 1,
    pipeline: usize = 1,
    msg_size: usize = 16,
    mode: []const u8 = "sync",
    deadline_ms: usize = 0,
    help: bool = false,
};

fn parseKeyVal(arg: []const u8) ?struct { key: []const u8, val: []const u8 } {
    if (!std.mem.startsWith(u8, arg, "--")) return null;
    const eq = std.mem.indexOfScalar(u8, arg, '=') orelse return null;
    return .{ .key = arg[2..eq], .val = arg[eq + 1 ..] };
}

fn isLocalHost(host: []const u8) bool {
    return std.mem.eql(u8, host, "127.0.0.1") or
        std.mem.eql(u8, host, "localhost");
}

fn terminateChild(io: Io, child: *std.process.Child) void {
    if (child.id == null) return;
    if (child.id) |pid| std.posix.kill(pid, .TERM) catch {};
    _ = child.wait(io) catch {};
    child.id = null;
}

fn waitForPort(io: Io, port: u16, timeout_ms: u64) !void {
    const start = std.Io.Timestamp.now(io, .awake);
    const deadline = start.addDuration(std.Io.Duration.fromMilliseconds(@intCast(timeout_ms)));
    while (std.Io.Timestamp.now(io, .awake).nanoseconds < deadline.nanoseconds) {
        const addr: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(port) };
        if (std.Io.net.IpAddress.connect(&addr, io, .{ .mode = .stream })) |stream| {
            stream.close(io);
            return;
        } else |_| {}
        try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .awake);
    }
    return error.PortWaitTimedOut;
}

fn spawnBackground(io: Io, argv: []const []const u8, cwd: []const u8) !std.process.Child {
    return try std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .inherit,
    });
}

fn runForwarded(io: Io, argv: []const []const u8, cwd: []const u8) !void {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) return error.ProcessFailed,
        else => return error.ProcessFailed,
    }
}

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    const root = try std.process.currentPathAlloc(init.io, allocator);
    const bench_path = try std.fs.path.join(allocator, &.{ root, "zig-out", "bin", "zwebsocket-bench" });
    const server_path = try std.fs.path.join(allocator, &.{ root, "zig-out", "bin", "zwebsocket-bench-server" });

    var cfg: Config = .{};
    var bench_args: std.ArrayList([]const u8) = .empty;
    defer bench_args.deinit(allocator);
    try bench_args.append(allocator, bench_path);

    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer it.deinit();
    _ = it.next();

    while (it.next()) |arg_z| {
        const arg: []const u8 = arg_z;
        if (std.mem.eql(u8, arg, "--help")) {
            try bench_args.append(allocator, arg);
            cfg.help = true;
            continue;
        }
        if (parseKeyVal(arg)) |kv| {
            if (std.mem.eql(u8, kv.key, "host")) {
                cfg.host = kv.val;
                try bench_args.append(allocator, arg);
            } else if (std.mem.eql(u8, kv.key, "port")) {
                cfg.port = try std.fmt.parseInt(u16, kv.val, 10);
                try bench_args.append(allocator, arg);
            } else if (std.mem.eql(u8, kv.key, "conns")) {
                cfg.conns = try std.fmt.parseInt(usize, kv.val, 10);
                try bench_args.append(allocator, arg);
            } else if (std.mem.eql(u8, kv.key, "pipeline")) {
                cfg.pipeline = try std.fmt.parseInt(usize, kv.val, 10);
                try bench_args.append(allocator, arg);
            } else if (std.mem.eql(u8, kv.key, "msg-size")) {
                cfg.msg_size = try std.fmt.parseInt(usize, kv.val, 10);
                try bench_args.append(allocator, arg);
            } else if (std.mem.eql(u8, kv.key, "mode")) {
                cfg.mode = kv.val;
            } else if (std.mem.eql(u8, kv.key, "deadline-ms")) {
                cfg.deadline_ms = try std.fmt.parseInt(usize, kv.val, 10);
            } else {
                try bench_args.append(allocator, arg);
            }
        } else {
            try bench_args.append(allocator, arg);
        }
    }

    if (cfg.help or !isLocalHost(cfg.host)) {
        try runForwarded(init.io, bench_args.items, root);
        return;
    }
    if (cfg.conns == 0) return error.InvalidConns;

    var port_buf: [32]u8 = undefined;
    var pipeline_buf: [32]u8 = undefined;
    var size_buf: [32]u8 = undefined;
    var deadline_buf: [32]u8 = undefined;
    var mode_buf: [32]u8 = undefined;
    var expected_conns_buf: [32]u8 = undefined;
    const port_arg = try std.fmt.bufPrint(&port_buf, "--port={d}", .{cfg.port});
    const pipeline_arg = try std.fmt.bufPrint(&pipeline_buf, "--pipeline={d}", .{cfg.pipeline});
    const size_arg = try std.fmt.bufPrint(&size_buf, "--msg-size={d}", .{cfg.msg_size});
    const mode_arg = try std.fmt.bufPrint(&mode_buf, "--mode={s}", .{cfg.mode});
    const deadline_arg = try std.fmt.bufPrint(&deadline_buf, "--deadline-ms={d}", .{cfg.deadline_ms});
    const expected_conns_arg = try std.fmt.bufPrint(&expected_conns_buf, "--expected-conns={d}", .{cfg.conns});

    var server = try spawnBackground(init.io, &.{ server_path, port_arg, pipeline_arg, size_arg, expected_conns_arg, mode_arg, deadline_arg }, root);
    defer terminateChild(init.io, &server);
    try waitForPort(init.io, cfg.port, 10_000);
    try runForwarded(init.io, bench_args.items, root);
}
