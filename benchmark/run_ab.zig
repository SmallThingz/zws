const std = @import("std");
const builtin = @import("builtin");
const scripts = @import("scripts.zig");

const PeerCount = 3;

const Config = struct {
    rounds: usize = 6,
    host: []const u8 = "127.0.0.1",
    path: []const u8 = "/",
    single_conns: usize = 1,
    multi_conns: usize = 16,
    iters: usize = 200_000,
    warmup: usize = 10_000,
    pipelined_depth: usize = 8,
    msg_size: usize = 16,
    optimize: []const u8 = "ReleaseFast",
    zws_port: u16 = 9101,
    uws_port: u16 = 9102,
    uws_deadline_port: u16 = 9103,
    uws_deadline_ms: usize = 30_000,
};

const Suite = struct {
    label: []const u8,
    conns: usize,
    pipeline: usize,
};

const Peer = struct {
    label: []const u8,
    port: u16,
    rate_path: []const u8,
};

const SuiteResult = struct {
    suite: Suite,
    averages: [PeerCount]f64,
};

const BenchPaths = struct {
    zws_server: []const u8,
    uws_server: []const u8,
    bench_bin: []const u8,
};

const Servers = struct {
    zws: std.process.Child,
    uws: std.process.Child,
    uws_deadline: std.process.Child,
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

fn parseRateFile(io: std.Io, path: []const u8) !f64 {
    const file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    var buf: [128]u8 = undefined;
    var reader = file.reader(io, &buf);
    const line_incl = try reader.interface.takeDelimiterInclusive('\n');
    const line = std.mem.trim(u8, line_incl, " \t\r\n");
    return try std.fmt.parseFloat(f64, line);
}

fn runChecked(
    io: std.Io,
    argv: []const []const u8,
    cwd: ?[]const u8,
    env_map: ?*const std.process.Environ.Map,
    inherit_stdout: bool,
) !void {
    const cwd_opt: std.process.Child.Cwd = if (cwd) |path| .{ .path = path } else .inherit;
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = cwd_opt,
        .environ_map = env_map,
        .stdin = .ignore,
        .stdout = if (inherit_stdout) .inherit else .ignore,
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
    try runChecked(io, &.{ "zig", "build", "install", optimize_arg }, root, null, true);
}

fn runBenchRate(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    bench_path: []const u8,
    cfg: Config,
    suite: Suite,
    peer: Peer,
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

    const conns_arg = try std.fmt.bufPrint(&conns_buf, "--conns={d}", .{suite.conns});
    const iters_arg = try std.fmt.bufPrint(&iters_buf, "--iters={d}", .{cfg.iters});
    const warmup_arg = try std.fmt.bufPrint(&warmup_buf, "--warmup={d}", .{cfg.warmup});
    const pipeline_arg = try std.fmt.bufPrint(&pipeline_buf, "--pipeline={d}", .{suite.pipeline});
    const port_arg = try std.fmt.bufPrint(&port_buf, "--port={d}", .{peer.port});
    const size_arg = try std.fmt.bufPrint(&size_buf, "--msg-size={d}", .{cfg.msg_size});
    const host_arg = try std.fmt.bufPrint(&host_buf, "--host={s}", .{cfg.host});
    const path_arg = try std.fmt.bufPrint(&path_buf, "--path={s}", .{cfg.path});
    const rate_arg = try std.fmt.bufPrint(&rate_buf, "--rate-file={s}", .{peer.rate_path});

    var env = try std.process.Environ.createMap(environ, allocator);
    defer env.deinit();
    try env.put("BENCH_LABEL", peer.label);

    try runChecked(
        io,
        &.{ bench_path, host_arg, port_arg, path_arg, conns_arg, iters_arg, warmup_arg, pipeline_arg, size_arg, "--quiet", rate_arg },
        root,
        &env,
        false,
    );
    return parseRateFile(io, peer.rate_path);
}

fn startServers(
    io: std.Io,
    root: []const u8,
    cfg: Config,
    suite: Suite,
    paths: BenchPaths,
) !Servers {
    var zws_port_buf: [16]u8 = undefined;
    var zws_pipeline_buf: [32]u8 = undefined;
    var zws_size_buf: [32]u8 = undefined;
    const zws_port_arg = try std.fmt.bufPrint(&zws_port_buf, "--port={d}", .{cfg.zws_port});
    const zws_pipeline_arg = try std.fmt.bufPrint(&zws_pipeline_buf, "--pipeline={d}", .{suite.pipeline});
    const zws_size_arg = try std.fmt.bufPrint(&zws_size_buf, "--msg-size={d}", .{cfg.msg_size});

    var uws_port_buf: [16]u8 = undefined;
    const uws_port_arg = try std.fmt.bufPrint(&uws_port_buf, "--port={d}", .{cfg.uws_port});
    var uws_deadline_port_buf: [16]u8 = undefined;
    var uws_deadline_ms_buf: [32]u8 = undefined;
    const uws_deadline_port_arg = try std.fmt.bufPrint(&uws_deadline_port_buf, "--port={d}", .{cfg.uws_deadline_port});
    const uws_deadline_ms_arg = try std.fmt.bufPrint(&uws_deadline_ms_buf, "--deadline-ms={d}", .{cfg.uws_deadline_ms});

    const children: Servers = .{
        .zws = try spawnBackground(io, &.{ paths.zws_server, zws_port_arg, zws_pipeline_arg, zws_size_arg }, root),
        .uws = try spawnBackground(io, &.{ paths.uws_server, uws_port_arg }, root),
        .uws_deadline = try spawnBackground(io, &.{ paths.uws_server, uws_deadline_port_arg, uws_deadline_ms_arg }, root),
    };
    try waitForPort(io, cfg.zws_port, 10_000);
    try waitForPort(io, cfg.uws_port, 10_000);
    try waitForPort(io, cfg.uws_deadline_port, 10_000);
    return children;
}

fn stopServers(io: std.Io, children: *const Servers) void {
    var zws = children.zws;
    var uws = children.uws;
    var uws_deadline = children.uws_deadline;
    terminateChild(io, &zws);
    terminateChild(io, &uws);
    terminateChild(io, &uws_deadline);
}

fn printSuiteTable(
    writer: *std.Io.Writer,
    result: SuiteResult,
) !void {
    const zws_avg = result.averages[0];
    const uws_avg = result.averages[1];
    const uws_deadline_avg = result.averages[2];
    const delta_plain = zws_avg - uws_avg;
    const pct_plain = if (uws_avg == 0) 0 else (delta_plain / uws_avg) * 100.0;
    const delta_deadline = zws_avg - uws_deadline_avg;
    const pct_deadline = if (uws_deadline_avg == 0) 0 else (delta_deadline / uws_deadline_avg) * 100.0;

    try writer.print(
        \\Suite: {s}  ({d} conn, pipeline={d})
        \\  zwebsocket           {d:>12.2} msg/s
        \\  uWebSockets          {d:>12.2} msg/s
        \\  uWebSockets+deadline {d:>12.2} msg/s
        \\  delta vs uWS         {d:>12.2} msg/s ({d:>7.2}%)
        \\  delta vs uWS+dl      {d:>12.2} msg/s ({d:>7.2}%)
        \\
    ,
        .{
            result.suite.label,
            result.suite.conns,
            result.suite.pipeline,
            zws_avg,
            uws_avg,
            uws_deadline_avg,
            delta_plain,
            pct_plain,
            delta_deadline,
            pct_deadline,
        },
    );
}

fn printFinalTable(writer: *std.Io.Writer, results: []const SuiteResult) !void {
    try writer.writeAll("== final summary ==\n");
    try writer.writeAll("suite                         zwebsocket        uWebSockets     uWS+deadline       vs uWS        vs uWS+dl\n");
    try writer.writeAll("----------------------------  ----------------  ----------------  ----------------  ------------  ------------\n");
    for (results) |result| {
        const zws_avg = result.averages[0];
        const uws_avg = result.averages[1];
        const uws_deadline_avg = result.averages[2];
        const pct_plain = if (uws_avg == 0) 0 else ((zws_avg - uws_avg) / uws_avg) * 100.0;
        const pct_deadline = if (uws_deadline_avg == 0) 0 else ((zws_avg - uws_deadline_avg) / uws_deadline_avg) * 100.0;
        try writer.print(
            "{s:<28}  {d:>16.2}  {d:>16.2}  {d:>16.2}  {d:>11.2}%  {d:>11.2}%\n",
            .{
                result.suite.label,
                zws_avg,
                uws_avg,
                uws_deadline_avg,
                pct_plain,
                pct_deadline,
            },
        );
    }
}

fn runSuite(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    cfg: Config,
    suite: Suite,
    paths: BenchPaths,
    peers: []const Peer,
    writer: *std.Io.Writer,
    environ: std.process.Environ,
) !SuiteResult {
    try writer.print("== suite: {s} ({d} conn, pipeline={d}) ==\n", .{ suite.label, suite.conns, suite.pipeline });
    const children = try startServers(io, root, cfg, suite, paths);
    defer stopServers(io, &children);

    var sums: [PeerCount]f64 = @splat(0);
    for (0..cfg.rounds) |idx| {
        for (peers, 0..) |peer, peer_idx| {
            const rate = try runBenchRate(io, allocator, root, paths.bench_bin, cfg, suite, peer, environ);
            sums[peer_idx] += rate;
            try writer.print("[{d}/{d}] {s:<22} {d:.2} msg/s\n", .{ idx + 1, cfg.rounds, peer.label, rate });
        }
    }

    const rounds_f = @as(f64, @floatFromInt(cfg.rounds));
    const result: SuiteResult = .{
        .suite = suite,
        .averages = .{
            sums[0] / rounds_f,
            sums[1] / rounds_f,
            sums[2] / rounds_f,
        },
    };
    try writer.writeAll("\n");
    try printSuiteTable(writer, result);
    return result;
}

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    const root = try std.process.currentPathAlloc(init.io, allocator);
    const env = init.environ_map;
    const env_pipeline = scripts.envInt(env, "PIPELINE", 8);
    const pipelined_depth = if (env_pipeline <= 1)
        8
    else
        env_pipeline;

    const cfg: Config = .{
        .rounds = scripts.envInt(env, "ROUNDS", 6),
        .host = env.get("HOST") orelse "127.0.0.1",
        .path = env.get("WS_PATH") orelse "/",
        .single_conns = scripts.envInt(env, "SINGLE_CONNS", 1),
        .multi_conns = scripts.envInt(env, "MULTI_CONNS", scripts.envInt(env, "CONNS", 16)),
        .iters = scripts.envInt(env, "ITERS", 200_000),
        .warmup = scripts.envInt(env, "WARMUP", 10_000),
        .pipelined_depth = scripts.envInt(env, "PIPELINE_DEPTH", pipelined_depth),
        .msg_size = scripts.envInt(env, "MSG_SIZE", 16),
        .optimize = env.get("OPTIMIZE") orelse "ReleaseFast",
        .zws_port = @intCast(scripts.envInt(env, "ZWS_PORT", 9101)),
        .uws_port = @intCast(scripts.envInt(env, "UWS_PORT", 9102)),
        .uws_deadline_port = @intCast(scripts.envInt(env, "UWS_DEADLINE_PORT", 9103)),
        .uws_deadline_ms = scripts.envInt(env, "UWS_DEADLINE_MS", 30_000),
    };
    if (cfg.single_conns == 0 or cfg.multi_conns == 0) return error.InvalidConns;
    if (cfg.pipelined_depth <= 1) return error.InvalidPipelineDepth;

    var stdout_buf: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_buf);

    try stdout.interface.writeAll("== build ==\n");
    try buildZwebsocketBins(init.io, root, cfg.optimize);

    const uws_dir = try std.fs.path.join(allocator, &.{ root, ".zig-cache", "uWebSockets-bench" });
    const paths: BenchPaths = .{
        .uws_server = try scripts.buildUwsServer(init.io, allocator, root, uws_dir, init.minimal.environ),
        .zws_server = try std.fs.path.join(allocator, &.{ root, "zig-out", "bin", "zwebsocket-bench-server" }),
        .bench_bin = try std.fs.path.join(allocator, &.{ root, "zig-out", "bin", "zwebsocket-bench" }),
    };

    const zws_rate_path = try std.fs.path.join(allocator, &.{ root, ".zig-cache", "bench-rate-zws.txt" });
    const uws_rate_path = try std.fs.path.join(allocator, &.{ root, ".zig-cache", "bench-rate-uws.txt" });
    const uws_deadline_rate_path = try std.fs.path.join(allocator, &.{ root, ".zig-cache", "bench-rate-uws-deadline.txt" });
    const peers = [_]Peer{
        .{ .label = "zwebsocket", .port = cfg.zws_port, .rate_path = zws_rate_path },
        .{ .label = "uWebSockets", .port = cfg.uws_port, .rate_path = uws_rate_path },
        .{ .label = "uWebSockets+deadline", .port = cfg.uws_deadline_port, .rate_path = uws_deadline_rate_path },
    };
    const suites = [_]Suite{
        .{ .label = "single / non-pipelined", .conns = cfg.single_conns, .pipeline = 1 },
        .{ .label = "single / pipelined", .conns = cfg.single_conns, .pipeline = cfg.pipelined_depth },
        .{ .label = "multi / non-pipelined", .conns = cfg.multi_conns, .pipeline = 1 },
        .{ .label = "multi / pipelined", .conns = cfg.multi_conns, .pipeline = cfg.pipelined_depth },
    };

    var results: [suites.len]SuiteResult = undefined;
    for (suites, 0..) |suite, idx| {
        results[idx] = try runSuite(
            init.io,
            allocator,
            root,
            cfg,
            suite,
            paths,
            peers[0..],
            &stdout.interface,
            init.minimal.environ,
        );
    }

    try printFinalTable(&stdout.interface, results[0..]);
    try stdout.interface.flush();
}
