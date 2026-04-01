const std = @import("std");
const builtin = @import("builtin");

pub fn envInt(env: *const std.process.Environ.Map, name: []const u8, default: usize) usize {
    const v = env.get(name) orelse return default;
    return std.fmt.parseInt(usize, v, 10) catch default;
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

fn dirExists(io: std.Io, path: []const u8) bool {
    const dir = std.Io.Dir.openDirAbsolute(io, path, .{}) catch return false;
    dir.close(io);
    return true;
}

fn ensureClone(io: std.Io, cwd: []const u8, dir: []const u8, url: []const u8) !void {
    if (dirExists(io, dir)) return;
    try runChecked(io, &.{ "git", "clone", "--depth", "1", url, dir }, cwd, null);
}

pub fn buildUwsServer(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    uws_dir: []const u8,
    environ: std.process.Environ,
) ![]u8 {
    try ensureClone(io, root, uws_dir, "https://github.com/uNetworking/uWebSockets");

    const usockets_dir = try std.fs.path.join(allocator, &.{ root, ".zig-cache", "uSockets-bench" });
    defer allocator.free(usockets_dir);
    try ensureClone(io, root, usockets_dir, "https://github.com/uNetworking/uSockets");

    const tmp_dir = try std.fs.path.join(allocator, &.{ root, ".zig-cache", "tmp" });
    defer allocator.free(tmp_dir);
    try runChecked(io, &.{ "mkdir", "-p", tmp_dir }, root, null);

    var env = try std.process.Environ.createMap(environ, allocator);
    defer env.deinit();
    try env.put("TMPDIR", tmp_dir);
    try env.put("TMP", tmp_dir);
    try env.put("TEMP", tmp_dir);

    try runChecked(io, &.{ "make", "WITH_ZLIB=0" }, usockets_dir, &env);

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
    }, root, &env);

    return out_path;
}
