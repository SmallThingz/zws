const std = @import("std");
const builtin = @import("builtin");
const zws = @import("zws");
const common = @import("zws_support_common");

const Config = struct {
    server_bin: []const u8,
    host: []const u8 = "127.0.0.1",
    port: u16 = 9200,
    connections: usize = 32,
    duration_ms: u64 = 10_000,
    compression: bool = false,
};

const SharedState = struct {
    total_messages: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    err_mutex: std.Io.Mutex = .init,
    first_err: ?anyerror = null,

    fn noteError(self: *SharedState, io: std.Io, err: anyerror) void {
        self.err_mutex.lockUncancelable(io);
        defer self.err_mutex.unlock(io);
        if (self.first_err == null) self.first_err = err;
        self.failed.store(true, .release);
    }
};

const WorkerArgs = struct {
    io: std.Io,
    host: []const u8,
    port: u16,
    compression: bool,
    index: usize,
    deadline: std.Io.Timestamp,
    shared: *SharedState,
};

fn parseDurationMs(text: []const u8) !u64 {
    const seconds = try std.fmt.parseFloat(f64, text);
    if (seconds < 0) return error.InvalidDuration;
    return @intFromFloat(seconds * 1000.0);
}

fn parseArgs(init: std.process.Init) !Config {
    var cfg: Config = .{ .server_bin = "" };

    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer it.deinit();
    _ = it.next();

    while (it.next()) |arg_z| {
        const arg: []const u8 = arg_z;
        if (std.mem.eql(u8, arg, "--compression")) {
            cfg.compression = true;
            continue;
        }
        const kv = common.parseKeyVal(arg) orelse return error.UnknownArg;
        if (std.mem.eql(u8, kv.key, "server-bin")) {
            cfg.server_bin = kv.val;
        } else if (std.mem.eql(u8, kv.key, "host")) {
            cfg.host = kv.val;
        } else if (std.mem.eql(u8, kv.key, "port")) {
            cfg.port = try std.fmt.parseInt(u16, kv.val, 10);
        } else if (std.mem.eql(u8, kv.key, "connections")) {
            cfg.connections = try std.fmt.parseInt(usize, kv.val, 10);
        } else if (std.mem.eql(u8, kv.key, "duration")) {
            cfg.duration_ms = try parseDurationMs(kv.val);
        } else {
            return error.UnknownArg;
        }
    }

    if (cfg.server_bin.len == 0) return error.MissingRequiredArg;
    if (cfg.connections == 0) return error.InvalidConnections;
    return cfg;
}

fn terminateChild(io: std.Io, child: *std.process.Child) void {
    if (child.id == null) return;
    if (builtin.os.tag == .windows) {
        child.kill(io) catch {};
        _ = child.wait(io) catch {};
        child.id = null;
        return;
    }
    if (child.id) |pid| std.posix.kill(pid, .TERM) catch {};
    _ = child.wait(io) catch {};
    child.id = null;
}

fn waitForPort(io: std.Io, host: []const u8, port: u16, timeout_ms: u64) !void {
    const addr: std.Io.net.IpAddress = .{ .ip4 = try std.Io.net.Ip4Address.parse(host, port) };
    const start = std.Io.Timestamp.now(io, .awake);
    const deadline = start.addDuration(std.Io.Duration.fromMilliseconds(@intCast(timeout_ms)));
    while (std.Io.Timestamp.now(io, .awake).nanoseconds < deadline.nanoseconds) {
        if (std.Io.net.IpAddress.connect(&addr, io, .{ .mode = .stream })) |stream| {
            stream.close(io);
            return;
        } else |_| {}
        try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .awake);
    }
    return error.PortWaitTimedOut;
}

fn workerMain(args: WorkerArgs) void {
    runWorker(args) catch |err| args.shared.noteError(args.io, err);
}

fn runWorker(args: WorkerArgs) !void {
    const addr: std.Io.net.IpAddress = .{ .ip4 = try std.Io.net.Ip4Address.parse(args.host, args.port) };
    var stream = try std.Io.net.IpAddress.connect(&addr, args.io, .{ .mode = .stream });
    defer stream.close(args.io);
    common.setTcpNoDelay(&stream);

    var read_buf: [64 * 1024]u8 = undefined;
    var write_buf: [16 * 1024]u8 = undefined;
    var sr = stream.reader(args.io, &read_buf);
    var sw = stream.writer(args.io, &write_buf);

    const request = try common.buildClientHandshakeRequest(std.heap.smp_allocator, args.host, "/", args.compression);
    defer std.heap.smp_allocator.free(request);
    const reply = try common.performClientHandshake(&sr.interface, &sw.interface, request);

    const negotiated = if (reply.selected_extensions) |header|
        try zws.Extensions.parsePerMessageDeflateFirst(header)
    else
        null;
    var conn = zws.Conn.Client.init(&sr.interface, &sw.interface, .{
        .permessage_deflate = if (negotiated) |pmd|
            .{
                .allocator = std.heap.smp_allocator,
                .negotiated = pmd,
                .compress_outgoing = true,
            }
        else
            null,
    });

    var message_buf: [128 * 1024]u8 = undefined;
    var binary_payload: [512]u8 = undefined;
    for (&binary_payload, 0..) |*b, i| b.* = @truncate((i * 29 + 11) & 0xff);

    while (!args.shared.failed.load(.acquire) and std.Io.Timestamp.now(args.io, .awake).nanoseconds < args.deadline.nanoseconds) {
        var text_storage: [384]u8 = undefined;
        const prefix = try std.fmt.bufPrint(&text_storage, "zws soak payload {d} ", .{args.index});
        @memset(text_storage[prefix.len .. prefix.len + 256], 'x');
        const text_payload = text_storage[0 .. prefix.len + 256];

        try conn.writeText(text_payload);
        try sw.interface.flush();
        {
            const message = try conn.readMessage(message_buf[0..]);
            if (message.opcode != .text) return error.UnexpectedOpcode;
            if (!std.mem.eql(u8, text_payload, message.payload)) return error.BadEcho;
        }
        _ = args.shared.total_messages.fetchAdd(1, .acq_rel);

        try conn.writeBinary(binary_payload[0..]);
        try sw.interface.flush();
        {
            const message = try conn.readMessage(message_buf[0..]);
            if (message.opcode != .binary) return error.UnexpectedOpcode;
            if (!std.mem.eql(u8, binary_payload[0..], message.payload)) return error.BadEcho;
        }
        _ = args.shared.total_messages.fetchAdd(1, .acq_rel);
    }

    try conn.writeClose(1000, "");
    try sw.interface.flush();
    _ = conn.readMessage(message_buf[0..]) catch {};
}

pub fn main(init: std.process.Init) !void {
    const cfg = try parseArgs(init);

    var server_argv: [3][]const u8 = .{ cfg.server_bin, "", "" };
    var server_len: usize = 2;
    var port_buf: [16]u8 = undefined;
    server_argv[1] = try std.fmt.bufPrint(&port_buf, "--port={d}", .{cfg.port});
    if (cfg.compression) {
        server_argv[2] = "--compression";
        server_len = 3;
    }

    var server = try std.process.spawn(init.io, .{
        .argv = server_argv[0..server_len],
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    defer terminateChild(init.io, &server);

    try waitForPort(init.io, cfg.host, cfg.port, 10_000);

    const started = std.Io.Clock.Timestamp.now(init.io, .awake);
    const deadline = started.addDuration(.{
        .raw = std.Io.Duration.fromMilliseconds(@intCast(cfg.duration_ms)),
        .clock = .awake,
    });

    var shared = SharedState{};
    const threads = try init.gpa.alloc(std.Thread, cfg.connections);
    defer init.gpa.free(threads);
    const worker_args = try init.gpa.alloc(WorkerArgs, cfg.connections);
    defer init.gpa.free(worker_args);

    for (threads, worker_args, 0..) |*thread, *args, idx| {
        args.* = .{
            .io = init.io,
            .host = cfg.host,
            .port = cfg.port,
            .compression = cfg.compression,
            .index = idx,
            .deadline = deadline.raw,
            .shared = &shared,
        };
        thread.* = try std.Thread.spawn(.{}, workerMain, .{args.*});
    }
    for (threads) |thread| thread.join();

    if (shared.first_err) |err| return err;

    const elapsed_ns = started.durationTo(std.Io.Clock.Timestamp.now(init.io, .awake)).raw.toNanoseconds();
    const total_messages = shared.total_messages.load(.acquire);
    const rate = if (elapsed_ns > 0)
        (@as(f64, @floatFromInt(total_messages)) * @as(f64, @floatFromInt(std.time.ns_per_s))) /
            @as(f64, @floatFromInt(elapsed_ns))
    else
        0.0;

    var stdout_buf: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_buf);
    try stdout.interface.print(
        "[soak] connections={d} duration={d:.1}s compression={} messages={d} msg_per_sec={d:.2}\n",
        .{
            cfg.connections,
            @as(f64, @floatFromInt(cfg.duration_ms)) / 1000.0,
            cfg.compression,
            total_messages,
            rate,
        },
    );
}
