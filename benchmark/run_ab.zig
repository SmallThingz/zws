const std = @import("std");
const builtin = @import("builtin");
const scripts = @import("scripts.zig");

const Config = struct {
    rounds: usize = 6,
    host: []const u8 = "127.0.0.1",
    path: []const u8 = "/",
    conns: usize = 16,
    iters: usize = 200_000,
    warmup: usize = 10_000,
    pipeline: usize = 1,
    msg_size: usize = 16,
    optimize: []const u8 = "ReleaseFast",
    zws_port: u16 = 9101,
    uws_port: u16 = 9102,
    uws_deadline_port: u16 = 9103,
    uws_deadline_ms: usize = 30_000,
};

const Peer = struct {
    label: []const u8,
    port: u16,
    rate_path: []const u8,
};

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

fn waitForPort(io: std.Io, port: u16, timeout_ms: u64) !void {
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

fn parseRateFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !f64 {
    const file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    var buf: [128]u8 = undefined;
    var reader = file.reader(io, &buf);
    const line_incl = try reader.interface.takeDelimiterInclusive('\n');
    const line = std.mem.trim(u8, line_incl, " \t\r\n");
    _ = allocator;
    return try std.fmt.parseFloat(f64, line);
}

fn runChecked(
    io: std.Io,
    argv: []const []const u8,
    cwd: ?[]const u8,
    env_map: ?*const std.process.Environ.Map,
) !void {
    const cwd_opt: std.process.Child.Cwd = if (cwd) |path| .{ .path = path } else .inherit;
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = cwd_opt,
        .environ_map = env_map,
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

fn spawnBackground(io: std.Io, argv: []const []const u8, cwd: ?[]const u8) !std.process.Child {
    const cwd_opt: std.process.Child.Cwd = if (cwd) |path| .{ .path = path } else .inherit;
    return try std.process.spawn(io, .{
        .argv = argv,
        .cwd = cwd_opt,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .inherit,
    });
}

fn buildZwebsocketBins(io: std.Io, root: []const u8, optimize: []const u8) !void {
    var optimize_buf: [64]u8 = undefined;
    const optimize_arg = try std.fmt.bufPrint(&optimize_buf, "-Doptimize={s}", .{optimize});
    try runChecked(io, &.{ "zig", "build", "install", optimize_arg }, root, null);
}

fn runBenchRate(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    bench_path: []const u8,
    cfg: Config,
    label: []const u8,
    port: u16,
    rate_path: []const u8,
    environ: std.process.Environ,
) !f64 {
    var conns_buf: [32]u8 = undefined;
    var iters_buf: [32]u8 = undefined;
    var warmup_buf: [32]u8 = undefined;
    var pipeline_buf: [32]u8 = undefined;
    var port_buf: [32]u8 = undefined;
    var size_buf: [32]u8 = undefined;
    var host_buf: [64]u8 = undefined;
    var path_buf: [256]u8 = undefined;
    var rate_buf: [512]u8 = undefined;

    const conns_arg = try std.fmt.bufPrint(&conns_buf, "--conns={d}", .{cfg.conns});
    const iters_arg = try std.fmt.bufPrint(&iters_buf, "--iters={d}", .{cfg.iters});
    const warmup_arg = try std.fmt.bufPrint(&warmup_buf, "--warmup={d}", .{cfg.warmup});
    const pipeline_arg = try std.fmt.bufPrint(&pipeline_buf, "--pipeline={d}", .{cfg.pipeline});
    const port_arg = try std.fmt.bufPrint(&port_buf, "--port={d}", .{port});
    const size_arg = try std.fmt.bufPrint(&size_buf, "--msg-size={d}", .{cfg.msg_size});
    const host_arg = try std.fmt.bufPrint(&host_buf, "--host={s}", .{cfg.host});
    const path_arg = try std.fmt.bufPrint(&path_buf, "--path={s}", .{cfg.path});
    const rate_arg = try std.fmt.bufPrint(&rate_buf, "--rate-file={s}", .{rate_path});

    var env = try std.process.Environ.createMap(environ, allocator);
    defer env.deinit();
    try env.put("BENCH_LABEL", label);

    try runChecked(
        io,
        &.{ bench_path, host_arg, port_arg, path_arg, conns_arg, iters_arg, warmup_arg, pipeline_arg, size_arg, "--quiet", rate_arg },
        root,
        &env,
    );
    return parseRateFile(io, allocator, rate_path);
}

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    const root = try std.process.currentPathAlloc(init.io, allocator);
    const env = init.environ_map;
    const cfg: Config = .{
        .rounds = scripts.envInt(env, "ROUNDS", 6),
        .host = env.get("HOST") orelse "127.0.0.1",
        .path = env.get("WS_PATH") orelse "/",
        .conns = scripts.envInt(env, "CONNS", 16),
        .iters = scripts.envInt(env, "ITERS", 200_000),
        .warmup = scripts.envInt(env, "WARMUP", 10_000),
        .pipeline = scripts.envInt(env, "PIPELINE", 1),
        .msg_size = scripts.envInt(env, "MSG_SIZE", 16),
        .optimize = env.get("OPTIMIZE") orelse "ReleaseFast",
        .zws_port = @intCast(scripts.envInt(env, "ZWS_PORT", 9101)),
        .uws_port = @intCast(scripts.envInt(env, "UWS_PORT", 9102)),
        .uws_deadline_port = @intCast(scripts.envInt(env, "UWS_DEADLINE_PORT", 9103)),
        .uws_deadline_ms = scripts.envInt(env, "UWS_DEADLINE_MS", 30_000),
    };

    var stdout_buf: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_buf);
    try stdout.interface.writeAll("== build ==\n");

    try buildZwebsocketBins(init.io, root, cfg.optimize);

    const uws_dir = try std.fs.path.join(allocator, &.{ root, ".zig-cache", "uWebSockets-bench" });
    const uws_server = try scripts.buildUwsServer(init.io, allocator, root, uws_dir, init.minimal.environ);
    const zws_server = try std.fs.path.join(allocator, &.{ root, "zig-out", "bin", "zwebsocket-bench-server" });
    const bench_bin = try std.fs.path.join(allocator, &.{ root, "zig-out", "bin", "zwebsocket-bench" });

    try stdout.interface.writeAll("== start servers ==\n");

    var zws_port_buf: [16]u8 = undefined;
    var zws_pipeline_buf: [32]u8 = undefined;
    var zws_size_buf: [32]u8 = undefined;
    const zws_port_arg = try std.fmt.bufPrint(&zws_port_buf, "--port={d}", .{cfg.zws_port});
    const zws_pipeline_arg = try std.fmt.bufPrint(&zws_pipeline_buf, "--pipeline={d}", .{cfg.pipeline});
    const zws_size_arg = try std.fmt.bufPrint(&zws_size_buf, "--msg-size={d}", .{cfg.msg_size});

    var uws_port_buf: [16]u8 = undefined;
    const uws_port_arg = try std.fmt.bufPrint(&uws_port_buf, "--port={d}", .{cfg.uws_port});
    var uws_deadline_port_buf: [16]u8 = undefined;
    var uws_deadline_ms_buf: [32]u8 = undefined;
    const uws_deadline_port_arg = try std.fmt.bufPrint(&uws_deadline_port_buf, "--port={d}", .{cfg.uws_deadline_port});
    const uws_deadline_ms_arg = try std.fmt.bufPrint(&uws_deadline_ms_buf, "--deadline-ms={d}", .{cfg.uws_deadline_ms});

    var zws_server_child = try spawnBackground(init.io, &.{ zws_server, zws_port_arg, zws_pipeline_arg, zws_size_arg }, root);
    defer terminateChild(init.io, &zws_server_child);
    var uws_server_child = try spawnBackground(init.io, &.{ uws_server, uws_port_arg }, root);
    defer terminateChild(init.io, &uws_server_child);
    var uws_deadline_server_child = try spawnBackground(init.io, &.{ uws_server, uws_deadline_port_arg, uws_deadline_ms_arg }, root);
    defer terminateChild(init.io, &uws_deadline_server_child);

    try waitForPort(init.io, cfg.zws_port, 10_000);
    try waitForPort(init.io, cfg.uws_port, 10_000);
    try waitForPort(init.io, cfg.uws_deadline_port, 10_000);

    const zws_rate_path = try std.fs.path.join(allocator, &.{ root, ".zig-cache", "bench-rate-zws.txt" });
    const uws_rate_path = try std.fs.path.join(allocator, &.{ root, ".zig-cache", "bench-rate-uws.txt" });
    const uws_deadline_rate_path = try std.fs.path.join(allocator, &.{ root, ".zig-cache", "bench-rate-uws-deadline.txt" });

    const peers = [_]Peer{
        .{ .label = "zwebsocket", .port = cfg.zws_port, .rate_path = zws_rate_path },
        .{ .label = "uWebSockets", .port = cfg.uws_port, .rate_path = uws_rate_path },
        .{ .label = "uWebSockets+deadline", .port = cfg.uws_deadline_port, .rate_path = uws_deadline_rate_path },
    };
    var sums: [peers.len]f64 = @splat(0);

    try stdout.interface.print("== interleaved rounds ({d}) ==\n", .{cfg.rounds});
    for (0..cfg.rounds) |idx| {
        for (peers, 0..) |peer, peer_idx| {
            try stdout.interface.print("[{d}/{d}] {s}\n", .{ idx + 1, cfg.rounds, peer.label });
            const rate = try runBenchRate(
                init.io,
                allocator,
                root,
                bench_bin,
                cfg,
                peer.label,
                peer.port,
                peer.rate_path,
                init.minimal.environ,
            );
            sums[peer_idx] += rate;
            try stdout.interface.print("  {s}: {d:.2} msg/s\n", .{ peer.label, rate });
        }
    }

    const rounds_f = @as(f64, @floatFromInt(cfg.rounds));
    const zws_avg = sums[0] / rounds_f;
    const uws_avg = sums[1] / rounds_f;
    const uws_deadline_avg = sums[2] / rounds_f;
    const plain_delta = zws_avg - uws_avg;
    const plain_pct = if (uws_avg == 0) 0 else (plain_delta / uws_avg) * 100.0;
    const deadline_delta = zws_avg - uws_deadline_avg;
    const deadline_pct = if (uws_deadline_avg == 0) 0 else (deadline_delta / uws_deadline_avg) * 100.0;

    try stdout.interface.writeAll("\n== summary ==\n");
    try stdout.interface.print("zwebsocket avg: {d:.2} msg/s\n", .{zws_avg});
    try stdout.interface.print("uWebSockets avg: {d:.2} msg/s\n", .{uws_avg});
    try stdout.interface.print("uWebSockets+deadline avg: {d:.2} msg/s\n", .{uws_deadline_avg});
    try stdout.interface.print("delta vs uWebSockets: {d:.2} msg/s ({d:.2}%)\n", .{ plain_delta, plain_pct });
    try stdout.interface.print("delta vs uWebSockets+deadline: {d:.2} msg/s ({d:.2}%)\n", .{ deadline_delta, deadline_pct });
}
