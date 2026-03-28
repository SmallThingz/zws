const std = @import("std");
const builtin = @import("builtin");

pub const BenchConfig = struct {
    port: u16,
    host: []const u8 = "127.0.0.1",
    path: []const u8 = "/",
    conns: usize,
    iters: usize,
    warmup: usize,
    pipeline: usize = 1,
    msg_size: usize,
    quiet: bool = true,
};

pub fn envInt(env: *const std.process.Environ.Map, name: []const u8, default: usize) usize {
    const v = env.get(name) orelse return default;
    return std.fmt.parseInt(usize, v, 10) catch default;
}

fn printLine(io: std.Io, line: []const u8) void {
    var buf: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buf);
    stdout.interface.writeAll(line) catch {};
    stdout.interface.writeAll("\n") catch {};
}

fn runChecked(io: std.Io, argv: []const []const u8, cwd: ?[]const u8, env_map: ?*const std.process.Environ.Map) !void {
    const cwd_opt: std.process.Child.Cwd = if (cwd) |p| .{ .path = p } else .inherit;
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
    const cwd_opt: std.process.Child.Cwd = if (cwd) |p| .{ .path = p } else .inherit;
    return try std.process.spawn(io, .{
        .argv = argv,
        .cwd = cwd_opt,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .inherit,
    });
}

fn terminateChild(io: std.Io, child: *std.process.Child) void {
    if (child.id == null) return;
    if (builtin.os.tag == .windows) {
        child.kill(io);
        return;
    }
    if (child.id) |pid| {
        std.posix.kill(pid, .KILL) catch {};
    }
    _ = child.wait(io) catch {};
}

fn dirExists(io: std.Io, path: []const u8) bool {
    const dir = std.Io.Dir.openDirAbsolute(io, path, .{}) catch return false;
    dir.close(io);
    return true;
}

fn fileExists(io: std.Io, path: []const u8) bool {
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return false;
    file.close(io);
    return true;
}

pub fn runZwebsocketExternal(io: std.Io, allocator: std.mem.Allocator, cfg: BenchConfig, root: []const u8, environ: std.process.Environ) !void {
    printLine(io, "== zwebsocket ==");

    const server_path = try std.fs.path.join(allocator, &.{ root, "zig-out", "bin", "zwebsocket-bench-server" });
    defer allocator.free(server_path);
    const bench_path = try std.fs.path.join(allocator, &.{ root, "zig-out", "bin", "zwebsocket-bench" });
    defer allocator.free(bench_path);

    var port_buf: [16]u8 = undefined;
    var pipeline_buf: [32]u8 = undefined;
    const port_arg = try std.fmt.bufPrint(&port_buf, "--port={d}", .{cfg.port});
    const pipeline_arg = try std.fmt.bufPrint(&pipeline_buf, "--pipeline={d}", .{cfg.pipeline});
    var server = try spawnBackground(io, &.{ server_path, port_arg, pipeline_arg }, root);
    defer terminateChild(io, &server);

    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(200), .awake);
    try runBench(io, allocator, cfg, root, bench_path, "zwebsocket", environ);
}

fn ensureClone(io: std.Io, cwd: []const u8, dir: []const u8, url: []const u8) !void {
    if (dirExists(io, dir)) return;
    try runChecked(io, &.{ "git", "clone", "--depth", "1", url, dir }, cwd, null);
}

fn buildUwsServer(io: std.Io, allocator: std.mem.Allocator, root: []const u8, uws_dir: []const u8) ![]u8 {
    try ensureClone(io, root, uws_dir, "https://github.com/uNetworking/uWebSockets");

    const usockets_dir = try std.fs.path.join(allocator, &.{ root, ".zig-cache", "uSockets-bench" });
    defer allocator.free(usockets_dir);
    try ensureClone(io, root, usockets_dir, "https://github.com/uNetworking/uSockets");

    try runChecked(io, &.{ "make", "WITH_ZLIB=0" }, usockets_dir, null);

    const out_path = try std.fs.path.join(allocator, &.{ root, "zig-out", "bin", "uws-bench-server" });
    const src_path = try std.fs.path.join(allocator, &.{ root, "benchmark", "uws_server.cpp" });
    const include1 = try std.fs.path.join(allocator, &.{ uws_dir, "src" });
    defer allocator.free(include1);
    const include2 = try std.fs.path.join(allocator, &.{ usockets_dir, "src" });
    defer allocator.free(include2);
    const usockets_lib = try std.fs.path.join(allocator, &.{ usockets_dir, "uSockets.a" });
    defer allocator.free(usockets_lib);

    const include1_arg = try std.fmt.allocPrint(allocator, "-I{s}", .{include1});
    defer allocator.free(include1_arg);
    const include2_arg = try std.fmt.allocPrint(allocator, "-I{s}", .{include2});
    defer allocator.free(include2_arg);
    const out_arg = try std.fmt.allocPrint(allocator, "-o{s}", .{out_path});
    defer allocator.free(out_arg);

    try runChecked(io, &.{
        "g++",
        "-O3",
        "-march=native",
        "-flto=auto",
        "-std=c++2b",
        "-DUWS_NO_ZLIB",
        include1_arg,
        include2_arg,
        src_path,
        usockets_lib,
        "-pthread",
        out_arg,
    }, root, null);

    return out_path;
}

pub fn runUwsExternal(io: std.Io, allocator: std.mem.Allocator, cfg: BenchConfig, root: []const u8, environ: std.process.Environ) !void {
    printLine(io, "== uWebSockets ==");

    const uws_dir = try std.fs.path.join(allocator, &.{ root, ".zig-cache", "uWebSockets-bench" });
    defer allocator.free(uws_dir);
    const server_path = try buildUwsServer(io, allocator, root, uws_dir);
    defer allocator.free(server_path);

    const bench_path = try std.fs.path.join(allocator, &.{ root, "zig-out", "bin", "zwebsocket-bench" });
    defer allocator.free(bench_path);

    var port_buf: [16]u8 = undefined;
    const port_arg = try std.fmt.bufPrint(&port_buf, "--port={d}", .{cfg.port});
    var server = try spawnBackground(io, &.{ server_path, port_arg }, root);
    defer terminateChild(io, &server);

    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(200), .awake);
    try runBench(io, allocator, cfg, root, bench_path, "uWebSockets", environ);
}

fn runBench(
    io: std.Io,
    allocator: std.mem.Allocator,
    cfg: BenchConfig,
    root: []const u8,
    bench_path: []const u8,
    label: []const u8,
    environ: std.process.Environ,
) !void {
    var conns_buf: [32]u8 = undefined;
    var iters_buf: [32]u8 = undefined;
    var warmup_buf: [32]u8 = undefined;
    var pipeline_buf: [32]u8 = undefined;
    var port_buf: [32]u8 = undefined;
    var size_buf: [32]u8 = undefined;
    var host_buf: [64]u8 = undefined;
    var path_buf: [256]u8 = undefined;

    const conns_arg = try std.fmt.bufPrint(&conns_buf, "--conns={d}", .{cfg.conns});
    const iters_arg = try std.fmt.bufPrint(&iters_buf, "--iters={d}", .{cfg.iters});
    const warmup_arg = try std.fmt.bufPrint(&warmup_buf, "--warmup={d}", .{cfg.warmup});
    const pipeline_arg = try std.fmt.bufPrint(&pipeline_buf, "--pipeline={d}", .{cfg.pipeline});
    const port_arg = try std.fmt.bufPrint(&port_buf, "--port={d}", .{cfg.port});
    const size_arg = try std.fmt.bufPrint(&size_buf, "--msg-size={d}", .{cfg.msg_size});
    const host_arg = try std.fmt.bufPrint(&host_buf, "--host={s}", .{cfg.host});
    const path_arg = try std.fmt.bufPrint(&path_buf, "--path={s}", .{cfg.path});

    var env = try std.process.Environ.createMap(environ, allocator);
    defer env.deinit();
    try env.put("BENCH_LABEL", label);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{ bench_path, host_arg, port_arg, path_arg, conns_arg, iters_arg, warmup_arg, pipeline_arg, size_arg, "--quiet" });

    try runChecked(io, argv.items, root, &env);
}
