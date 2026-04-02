const std = @import("std");
const builtin = @import("builtin");
const scripts = @import("scripts.zig");

const PeerCount = 8;

const Config = struct {
    rounds: usize = 2,
    host: []const u8 = "127.0.0.1",
    path: []const u8 = "/",
    single_conns: usize = 1,
    multi_conns: usize = 16,
    iters: usize = 200_000,
    warmup: usize = 10_000,
    pipelined_depth: usize = 8,
    msg_size: usize = 16,
    optimize: []const u8 = "ReleaseFast",
    bench_timeout_ms: usize = 120_000,
    zws_sync_port: u16 = 9101,
    zws_sync_deadline_port: u16 = 9102,
    zws_async_port: u16 = 9103,
    zws_async_deadline_port: u16 = 9104,
    uws_sync_port: u16 = 9105,
    uws_sync_deadline_port: u16 = 9106,
    uws_async_port: u16 = 9107,
    uws_async_deadline_port: u16 = 9108,
    zws_deadline_ms: usize = 30_000,
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

const ReadmeSnapshot = struct {
    generated_awake_ns: u64,
    fairness: []const u8,
    config: ConfigSnapshot,
    peers: [PeerCount][]const u8,
    suites: [4]SuiteSnapshot,
};

const ConfigSnapshot = struct {
    rounds: usize,
    host: []const u8,
    path: []const u8,
    single_conns: usize,
    multi_conns: usize,
    iters: usize,
    warmup: usize,
    pipelined_depth: usize,
    msg_size: usize,
    bench_timeout_ms: usize,
    zws_deadline_ms: usize,
    uws_deadline_ms: usize,
};

const SuiteSnapshot = struct {
    label: []const u8,
    conns: usize,
    pipeline: usize,
    averages: [PeerCount]f64,
};

const BenchPaths = struct {
    zws_server: []const u8,
    uws_server: []const u8,
    bench_bin: []const u8,
};

const Servers = struct {
    zws_sync: std.process.Child,
    zws_sync_deadline: std.process.Child,
    zws_async: std.process.Child,
    zws_async_deadline: std.process.Child,
    uws_sync: std.process.Child,
    uws_sync_deadline: std.process.Child,
    uws_async: std.process.Child,
    uws_async_deadline: std.process.Child,
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

fn runBenchClient(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    cwd: []const u8,
    env_map: *const std.process.Environ.Map,
    timeout_ms: usize,
) !void {
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .environ_map = env_map,
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(16 * 1024),
        .timeout = .{
            .duration = .{
                .raw = std.Io.Duration.fromMilliseconds(@intCast(timeout_ms)),
                .clock = .awake,
            },
        },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) return error.ProcessFailed,
        else => return error.ProcessFailed,
    }
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

    try runBenchClient(
        allocator,
        io,
        &.{ bench_path, host_arg, port_arg, path_arg, conns_arg, iters_arg, warmup_arg, pipeline_arg, size_arg, "--quiet", rate_arg },
        root,
        &env,
        cfg.bench_timeout_ms,
    );
    return parseRateFile(io, peer.rate_path);
}

fn startServers(io: std.Io, root: []const u8, cfg: Config, suite: Suite, paths: BenchPaths) !Servers {
    var zws_sync_port_buf: [16]u8 = undefined;
    var zws_sync_dl_port_buf: [16]u8 = undefined;
    var zws_async_port_buf: [16]u8 = undefined;
    var zws_async_dl_port_buf: [16]u8 = undefined;
    var zws_pipeline_buf: [32]u8 = undefined;
    var zws_size_buf: [32]u8 = undefined;
    var zws_deadline_buf: [32]u8 = undefined;
    var zws_expected_conns_buf: [32]u8 = undefined;

    const zws_sync_port_arg = try std.fmt.bufPrint(&zws_sync_port_buf, "--port={d}", .{cfg.zws_sync_port});
    const zws_sync_dl_port_arg = try std.fmt.bufPrint(&zws_sync_dl_port_buf, "--port={d}", .{cfg.zws_sync_deadline_port});
    const zws_async_port_arg = try std.fmt.bufPrint(&zws_async_port_buf, "--port={d}", .{cfg.zws_async_port});
    const zws_async_dl_port_arg = try std.fmt.bufPrint(&zws_async_dl_port_buf, "--port={d}", .{cfg.zws_async_deadline_port});
    const zws_pipeline_arg = try std.fmt.bufPrint(&zws_pipeline_buf, "--pipeline={d}", .{suite.pipeline});
    const zws_size_arg = try std.fmt.bufPrint(&zws_size_buf, "--msg-size={d}", .{cfg.msg_size});
    const zws_deadline_arg = try std.fmt.bufPrint(&zws_deadline_buf, "--deadline-ms={d}", .{cfg.zws_deadline_ms});
    const zws_expected_conns_arg = try std.fmt.bufPrint(&zws_expected_conns_buf, "--expected-conns={d}", .{suite.conns});

    var uws_sync_port_buf: [16]u8 = undefined;
    var uws_sync_dl_port_buf: [16]u8 = undefined;
    var uws_async_port_buf: [16]u8 = undefined;
    var uws_async_dl_port_buf: [16]u8 = undefined;
    var uws_deadline_ms_buf: [32]u8 = undefined;
    const uws_sync_port_arg = try std.fmt.bufPrint(&uws_sync_port_buf, "--port={d}", .{cfg.uws_sync_port});
    const uws_sync_dl_port_arg = try std.fmt.bufPrint(&uws_sync_dl_port_buf, "--port={d}", .{cfg.uws_sync_deadline_port});
    const uws_async_port_arg = try std.fmt.bufPrint(&uws_async_port_buf, "--port={d}", .{cfg.uws_async_port});
    const uws_async_dl_port_arg = try std.fmt.bufPrint(&uws_async_dl_port_buf, "--port={d}", .{cfg.uws_async_deadline_port});
    const uws_deadline_ms_arg = try std.fmt.bufPrint(&uws_deadline_ms_buf, "--deadline-ms={d}", .{cfg.uws_deadline_ms});

    const children: Servers = .{
        .zws_sync = try spawnBackground(io, &.{ paths.zws_server, zws_sync_port_arg, zws_pipeline_arg, zws_size_arg, zws_expected_conns_arg, "--mode=sync" }, root),
        .zws_sync_deadline = try spawnBackground(io, &.{ paths.zws_server, zws_sync_dl_port_arg, zws_pipeline_arg, zws_size_arg, zws_expected_conns_arg, "--mode=sync", zws_deadline_arg }, root),
        .zws_async = try spawnBackground(io, &.{ paths.zws_server, zws_async_port_arg, zws_pipeline_arg, zws_size_arg, zws_expected_conns_arg, "--mode=async" }, root),
        .zws_async_deadline = try spawnBackground(io, &.{ paths.zws_server, zws_async_dl_port_arg, zws_pipeline_arg, zws_size_arg, zws_expected_conns_arg, "--mode=async", zws_deadline_arg }, root),
        .uws_sync = try spawnBackground(io, &.{ paths.uws_server, uws_sync_port_arg, "--mode=sync" }, root),
        .uws_sync_deadline = try spawnBackground(io, &.{ paths.uws_server, uws_sync_dl_port_arg, "--mode=sync", uws_deadline_ms_arg }, root),
        .uws_async = try spawnBackground(io, &.{ paths.uws_server, uws_async_port_arg, "--mode=async" }, root),
        .uws_async_deadline = try spawnBackground(io, &.{ paths.uws_server, uws_async_dl_port_arg, "--mode=async", uws_deadline_ms_arg }, root),
    };
    try waitForPort(io, cfg.zws_sync_port, 10_000);
    try waitForPort(io, cfg.zws_sync_deadline_port, 10_000);
    try waitForPort(io, cfg.zws_async_port, 10_000);
    try waitForPort(io, cfg.zws_async_deadline_port, 10_000);
    try waitForPort(io, cfg.uws_sync_port, 10_000);
    try waitForPort(io, cfg.uws_sync_deadline_port, 10_000);
    try waitForPort(io, cfg.uws_async_port, 10_000);
    try waitForPort(io, cfg.uws_async_deadline_port, 10_000);
    return children;
}

fn stopServers(io: std.Io, children: *const Servers) void {
    var zws_sync = children.zws_sync;
    var zws_sync_deadline = children.zws_sync_deadline;
    var zws_async = children.zws_async;
    var zws_async_deadline = children.zws_async_deadline;
    var uws_sync = children.uws_sync;
    var uws_sync_deadline = children.uws_sync_deadline;
    var uws_async = children.uws_async;
    var uws_async_deadline = children.uws_async_deadline;
    terminateChild(io, &zws_sync);
    terminateChild(io, &zws_sync_deadline);
    terminateChild(io, &zws_async);
    terminateChild(io, &zws_async_deadline);
    terminateChild(io, &uws_sync);
    terminateChild(io, &uws_sync_deadline);
    terminateChild(io, &uws_async);
    terminateChild(io, &uws_async_deadline);
}

fn printSuiteTable(writer: *std.Io.Writer, peers: []const Peer, result: SuiteResult) !void {
    try writer.print("Suite: {s}  ({d} conn, pipeline={d})\n", .{ result.suite.label, result.suite.conns, result.suite.pipeline });
    for (peers, 0..) |peer, idx| {
        try writer.print("  {s:<22} {d:>12.2} msg/s\n", .{ peer.label, result.averages[idx] });
    }
    try writer.writeAll("\n");
}

fn printFinalTable(writer: *std.Io.Writer, peers: []const Peer, results: []const SuiteResult) !void {
    try writer.writeAll("== final summary ==\n");
    try writer.writeAll("suite                         ");
    for (peers) |peer| {
        try writer.print("{s:<18}", .{peer.label});
    }
    try writer.writeAll("\n");
    try writer.writeAll("----------------------------  ");
    for (peers) |_| {
        try writer.writeAll("------------------");
    }
    try writer.writeAll("\n");
    for (results) |result| {
        try writer.print("{s:<28}  ", .{result.suite.label});
        for (result.averages) |avg| {
            try writer.print("{d:>18.2}", .{avg});
        }
        try writer.writeAll("\n");
    }
}

fn nowAwakeNs(io: std.Io) u64 {
    const ts = std.Io.Timestamp.now(io, .awake);
    if (ts.nanoseconds <= 0) return 0;
    return std.math.cast(u64, ts.nanoseconds) orelse 0;
}

fn renderResultsMarkdown(
    allocator: std.mem.Allocator,
    cfg: Config,
    peers: []const Peer,
    results: []const SuiteResult,
    source_json_rel_path: []const u8,
    include_heading: bool,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;

    if (include_heading) try w.writeAll("# WebSocket Benchmark Snapshot\n\n");
    try w.print("Source: `{s}`\n\n", .{source_json_rel_path});
    try w.print(
        "Config: host=`{s}` path=`{s}` rounds={d} single_conns={d} multi_conns={d} iters={d} warmup={d} pipeline_depth={d} msg_size={d} bench_timeout_ms={d} zws_deadline_ms={d} uws_deadline_ms={d}\n\n",
        .{
            cfg.host,
            cfg.path,
            cfg.rounds,
            cfg.single_conns,
            cfg.multi_conns,
            cfg.iters,
            cfg.warmup,
            cfg.pipelined_depth,
            cfg.msg_size,
            cfg.bench_timeout_ms,
            cfg.zws_deadline_ms,
            cfg.uws_deadline_ms,
        },
    );
    try w.writeAll("| Suite | ");
    for (peers, 0..) |peer, idx| {
        try w.writeAll(peer.label);
        if (idx + 1 != peers.len) try w.writeAll(" | ");
    }
    try w.writeAll(" |\n|---");
    for (peers) |_| try w.writeAll("|---:");
    try w.writeAll("|\n");
    for (results) |result| {
        try w.print("| {s} | ", .{result.suite.label});
        for (result.averages, 0..) |avg, idx| {
            try w.print("{d:.2}", .{avg});
            if (idx + 1 != result.averages.len) try w.writeAll(" | ");
        }
        try w.writeAll(" |\n");
    }
    try w.writeAll("\nFairness notes: all peers use the same benchmark client, identical per-suite client settings, and the matrix runs strict interleaved rounds for every peer inside each suite.\n");
    return out.toOwnedSlice();
}

fn renderComparisonMarkdown(
    allocator: std.mem.Allocator,
    cfg: Config,
    results: []const SuiteResult,
    source_json_rel_path: []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;

    try w.print("Source: `{s}`\n\n", .{source_json_rel_path});
    try w.print(
        "Config: host=`{s}` path=`{s}` rounds={d} single_conns={d} multi_conns={d} iters={d} warmup={d} pipeline_depth={d} msg_size={d} bench_timeout_ms={d} zws_deadline_ms={d} uws_deadline_ms={d}\n\n",
        .{
            cfg.host,
            cfg.path,
            cfg.rounds,
            cfg.single_conns,
            cfg.multi_conns,
            cfg.iters,
            cfg.warmup,
            cfg.pipelined_depth,
            cfg.msg_size,
            cfg.bench_timeout_ms,
            cfg.zws_deadline_ms,
            cfg.uws_deadline_ms,
        },
    );
    try w.writeAll("| Suite | sync | sync+dl | async | async+dl |\n");
    try w.writeAll("|---|---:|---:|---:|---:|\n");
    for (results) |result| {
        try w.print("| {s} | ", .{result.suite.label});
        try writeDeltaCell(w, result.averages[0], result.averages[4]);
        try w.writeAll(" | ");
        try writeDeltaCell(w, result.averages[1], result.averages[5]);
        try w.writeAll(" | ");
        try writeDeltaCell(w, result.averages[2], result.averages[6]);
        try w.writeAll(" | ");
        try writeDeltaCell(w, result.averages[3], result.averages[7]);
        try w.writeAll(" |\n");
    }
    try w.writeAll("\nValues show `zws` vs matching `uWS` throughput delta.\n");
    try w.writeAll("Fairness notes: all peers use the same benchmark client, identical per-suite client settings, and the matrix runs strict interleaved rounds for every peer inside each suite.\n");
    return out.toOwnedSlice();
}

fn writeDeltaCell(writer: *std.Io.Writer, ours: f64, theirs: f64) !void {
    if (theirs == 0 or !std.math.isFinite(ours) or !std.math.isFinite(theirs)) {
        try writer.writeAll("n/a");
        return;
    }
    const delta = ((ours / theirs) - 1.0) * 100.0;
    if (delta >= 0) {
        try writer.print("+{d:.2}%", .{delta});
    } else {
        try writer.print("{d:.2}%", .{delta});
    }
}

fn writeArtifacts(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    cfg: Config,
    peers: []const Peer,
    results: []const SuiteResult,
) !void {
    const full_md = try renderResultsMarkdown(allocator, cfg, peers, results, "benchmark/results/latest.json", true);
    defer allocator.free(full_md);
    const benchmark_summary_md = try renderResultsMarkdown(allocator, cfg, peers, results, "benchmark/results/latest.json", false);
    defer allocator.free(benchmark_summary_md);
    const root_summary_md = try renderComparisonMarkdown(allocator, cfg, results, "benchmark/results/latest.json");
    defer allocator.free(root_summary_md);

    const snapshot: ReadmeSnapshot = .{
        .generated_awake_ns = nowAwakeNs(io),
        .fairness = "all peers use the same benchmark client, identical per-suite client settings, and the matrix runs strict interleaved rounds for every peer inside each suite.",
        .config = .{
            .rounds = cfg.rounds,
            .host = cfg.host,
            .path = cfg.path,
            .single_conns = cfg.single_conns,
            .multi_conns = cfg.multi_conns,
            .iters = cfg.iters,
            .warmup = cfg.warmup,
            .pipelined_depth = cfg.pipelined_depth,
            .msg_size = cfg.msg_size,
            .bench_timeout_ms = cfg.bench_timeout_ms,
            .zws_deadline_ms = cfg.zws_deadline_ms,
            .uws_deadline_ms = cfg.uws_deadline_ms,
        },
        .peers = .{
            peers[0].label,
            peers[1].label,
            peers[2].label,
            peers[3].label,
            peers[4].label,
            peers[5].label,
            peers[6].label,
            peers[7].label,
        },
        .suites = .{
            .{ .label = results[0].suite.label, .conns = results[0].suite.conns, .pipeline = results[0].suite.pipeline, .averages = results[0].averages },
            .{ .label = results[1].suite.label, .conns = results[1].suite.conns, .pipeline = results[1].suite.pipeline, .averages = results[1].averages },
            .{ .label = results[2].suite.label, .conns = results[2].suite.conns, .pipeline = results[2].suite.pipeline, .averages = results[2].averages },
            .{ .label = results[3].suite.label, .conns = results[3].suite.conns, .pipeline = results[3].suite.pipeline, .averages = results[3].averages },
        },
    };

    var json_writer: std.Io.Writer.Allocating = .init(allocator);
    defer json_writer.deinit();
    var json_stream: std.json.Stringify = .{
        .writer = &json_writer.writer,
        .options = .{ .whitespace = .indent_2 },
    };
    try json_stream.write(snapshot);

    try scripts.writeCompareArtifactsAndSyncReadme(
        io,
        allocator,
        root,
        root_summary_md,
        benchmark_summary_md,
        full_md,
        json_writer.written(),
    );
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
    var averages: [PeerCount]f64 = undefined;
    for (&averages, sums) |*dst, sum| dst.* = sum / rounds_f;

    const result: SuiteResult = .{
        .suite = suite,
        .averages = averages,
    };
    try writer.writeAll("\n");
    try printSuiteTable(writer, peers, result);
    return result;
}

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    const root = try std.process.currentPathAlloc(init.io, allocator);
    const env = init.environ_map;
    const env_pipeline = scripts.envInt(env, "PIPELINE", 8);
    const pipelined_depth = if (env_pipeline <= 1) 8 else env_pipeline;

    const cfg: Config = .{
        .rounds = scripts.envInt(env, "ROUNDS", 2),
        .host = env.get("HOST") orelse "127.0.0.1",
        .path = env.get("WS_PATH") orelse "/",
        .single_conns = scripts.envInt(env, "SINGLE_CONNS", 1),
        .multi_conns = scripts.envInt(env, "MULTI_CONNS", scripts.envInt(env, "CONNS", 16)),
        .iters = scripts.envInt(env, "ITERS", 200_000),
        .warmup = scripts.envInt(env, "WARMUP", 10_000),
        .pipelined_depth = scripts.envInt(env, "PIPELINE_DEPTH", pipelined_depth),
        .msg_size = scripts.envInt(env, "MSG_SIZE", 16),
        .optimize = env.get("OPTIMIZE") orelse "ReleaseFast",
        .bench_timeout_ms = scripts.envInt(env, "BENCH_TIMEOUT_MS", 120_000),
        .zws_sync_port = @intCast(scripts.envInt(env, "ZWS_SYNC_PORT", 9101)),
        .zws_sync_deadline_port = @intCast(scripts.envInt(env, "ZWS_SYNC_DEADLINE_PORT", 9102)),
        .zws_async_port = @intCast(scripts.envInt(env, "ZWS_ASYNC_PORT", 9103)),
        .zws_async_deadline_port = @intCast(scripts.envInt(env, "ZWS_ASYNC_DEADLINE_PORT", 9104)),
        .uws_sync_port = @intCast(scripts.envInt(env, "UWS_SYNC_PORT", 9105)),
        .uws_sync_deadline_port = @intCast(scripts.envInt(env, "UWS_SYNC_DEADLINE_PORT", 9106)),
        .uws_async_port = @intCast(scripts.envInt(env, "UWS_ASYNC_PORT", 9107)),
        .uws_async_deadline_port = @intCast(scripts.envInt(env, "UWS_ASYNC_DEADLINE_PORT", 9108)),
        .zws_deadline_ms = scripts.envInt(env, "ZWS_DEADLINE_MS", 30_000),
        .uws_deadline_ms = scripts.envInt(env, "UWS_DEADLINE_MS", 30_000),
    };
    if (cfg.single_conns == 0 or cfg.multi_conns == 0) return error.InvalidConns;
    if (cfg.pipelined_depth <= 1) return error.InvalidPipelineDepth;

    var stdout_buf: [2048]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_buf);

    try stdout.interface.writeAll("== build ==\n");
    try buildZwebsocketBins(init.io, root, cfg.optimize);

    const uws_dir = try std.fs.path.join(allocator, &.{ root, ".zig-cache", "uWebSockets-bench" });
    const paths: BenchPaths = .{
        .uws_server = try scripts.buildUwsServer(init.io, allocator, root, uws_dir, init.minimal.environ),
        .zws_server = try std.fs.path.join(allocator, &.{ root, "zig-out", "bin", "zwebsocket-bench-server" }),
        .bench_bin = try std.fs.path.join(allocator, &.{ root, "zig-out", "bin", "zwebsocket-bench" }),
    };

    const peers = [_]Peer{
        .{ .label = "zws-sync", .port = cfg.zws_sync_port, .rate_path = try std.fs.path.join(allocator, &.{ root, ".zig-cache", "bench-rate-zws-sync.txt" }) },
        .{ .label = "zws-sync+dl", .port = cfg.zws_sync_deadline_port, .rate_path = try std.fs.path.join(allocator, &.{ root, ".zig-cache", "bench-rate-zws-sync-dl.txt" }) },
        .{ .label = "zws-async", .port = cfg.zws_async_port, .rate_path = try std.fs.path.join(allocator, &.{ root, ".zig-cache", "bench-rate-zws-async.txt" }) },
        .{ .label = "zws-async+dl", .port = cfg.zws_async_deadline_port, .rate_path = try std.fs.path.join(allocator, &.{ root, ".zig-cache", "bench-rate-zws-async-dl.txt" }) },
        .{ .label = "uWS-sync", .port = cfg.uws_sync_port, .rate_path = try std.fs.path.join(allocator, &.{ root, ".zig-cache", "bench-rate-uws-sync.txt" }) },
        .{ .label = "uWS-sync+dl", .port = cfg.uws_sync_deadline_port, .rate_path = try std.fs.path.join(allocator, &.{ root, ".zig-cache", "bench-rate-uws-sync-dl.txt" }) },
        .{ .label = "uWS-async", .port = cfg.uws_async_port, .rate_path = try std.fs.path.join(allocator, &.{ root, ".zig-cache", "bench-rate-uws-async.txt" }) },
        .{ .label = "uWS-async+dl", .port = cfg.uws_async_deadline_port, .rate_path = try std.fs.path.join(allocator, &.{ root, ".zig-cache", "bench-rate-uws-async-dl.txt" }) },
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

    try printFinalTable(&stdout.interface, peers[0..], results[0..]);
    try writeArtifacts(init.io, allocator, root, cfg, peers[0..], results[0..]);
    try stdout.interface.flush();
}
