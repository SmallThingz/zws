const std = @import("std");
const builtin = @import("builtin");

const RootReadmeBenchCompareStartMarker = "<!-- BENCH_COMPARE:START -->";
const RootReadmeBenchCompareEndMarker = "<!-- BENCH_COMPARE:END -->";
const BenchmarkReadmeBenchCompareStartMarker = "<!-- BENCH_COMPARE:START -->";
const BenchmarkReadmeBenchCompareEndMarker = "<!-- BENCH_COMPARE:END -->";
const BenchmarkResultsRelDir = "benchmark/results";
const BenchmarkLatestJsonRelPath = "benchmark/results/latest.json";
const BenchmarkLatestMdRelPath = "benchmark/results/latest.md";

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

fn readFileMaybe(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io);

    const stat = try file.stat(io);
    if (stat.size > std.math.maxInt(usize)) return error.FileTooLarge;
    const len: usize = @intCast(stat.size);

    const out = try allocator.alloc(u8, len);
    errdefer allocator.free(out);

    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    try reader.interface.readSliceAll(out);
    return out;
}

fn writeFileIfChanged(io: std.Io, allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) !bool {
    const existing = try readFileMaybe(io, allocator, path);
    if (existing) |buf| {
        defer allocator.free(buf);
        if (std.mem.eql(u8, buf, bytes)) return false;
    }
    const file = try std.Io.Dir.createFileAbsolute(io, path, .{ .truncate = true });
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var writer = file.writer(io, &buf);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
    return true;
}

fn updateReadmeSectionAtPath(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    start_marker: []const u8,
    end_marker: []const u8,
    replacement: []const u8,
) !void {
    const readme = try readFileMaybe(io, allocator, path) orelse return error.FileNotFound;
    defer allocator.free(readme);

    const start = std.mem.indexOf(u8, readme, start_marker) orelse return error.ReadmeBenchMarkersMissing;
    const after_start = start + start_marker.len;
    const end = std.mem.indexOfPos(u8, readme, after_start, end_marker) orelse return error.ReadmeBenchMarkersMissing;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.appendSlice(allocator, readme[0..after_start]);
    try out.appendSlice(allocator, "\n\n");
    try out.appendSlice(allocator, replacement);
    if (replacement.len == 0 or replacement[replacement.len - 1] != '\n') try out.append(allocator, '\n');
    if (readme[end - 1] != '\n') try out.append(allocator, '\n');
    try out.appendSlice(allocator, readme[end..]);

    _ = try writeFileIfChanged(io, allocator, path, out.items);
}

fn syncReadmes(io: std.Io, allocator: std.mem.Allocator, root: []const u8, replacement: []const u8) !void {
    const root_readme_path = try std.fs.path.join(allocator, &.{ root, "README.md" });
    defer allocator.free(root_readme_path);
    try updateReadmeSectionAtPath(
        io,
        allocator,
        root_readme_path,
        RootReadmeBenchCompareStartMarker,
        RootReadmeBenchCompareEndMarker,
        replacement,
    );

    const benchmark_readme_path = try std.fs.path.join(allocator, &.{ root, "benchmark", "README.md" });
    defer allocator.free(benchmark_readme_path);
    try updateReadmeSectionAtPath(
        io,
        allocator,
        benchmark_readme_path,
        BenchmarkReadmeBenchCompareStartMarker,
        BenchmarkReadmeBenchCompareEndMarker,
        replacement,
    );
}

pub fn writeCompareArtifactsAndSyncReadme(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    summary_md: []const u8,
    full_md: []const u8,
    json: []const u8,
) !void {
    const results_dir = try std.fs.path.join(allocator, &.{ root, BenchmarkResultsRelDir });
    defer allocator.free(results_dir);
    try std.Io.Dir.createDirPath(.cwd(), io, results_dir);

    const json_path = try std.fs.path.join(allocator, &.{ root, BenchmarkLatestJsonRelPath });
    defer allocator.free(json_path);
    _ = try writeFileIfChanged(io, allocator, json_path, json);

    const md_path = try std.fs.path.join(allocator, &.{ root, BenchmarkLatestMdRelPath });
    defer allocator.free(md_path);
    _ = try writeFileIfChanged(io, allocator, md_path, full_md);

    try syncReadmes(io, allocator, root, summary_md);
}
