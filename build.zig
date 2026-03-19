const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("zwebsocket", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const bench_exe = b.addExecutable(.{
        .name = "zwebsocket-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmark/bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zwebsocket", .module = mod },
            },
        }),
    });
    const install_bench = b.addInstallArtifact(bench_exe, .{});

    const bench_server_exe = b.addExecutable(.{
        .name = "zwebsocket-bench-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmark/zwebsocket_server.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zwebsocket", .module = mod },
            },
        }),
    });
    const install_bench_server = b.addInstallArtifact(bench_server_exe, .{});

    const compare_exe = b.addExecutable(.{
        .name = "zwebsocket-bench-compare",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmark/run_compare.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zwebsocket", .module = mod },
            },
        }),
    });
    const install_compare = b.addInstallArtifact(compare_exe, .{});

    const test_step = b.step("test", "Run zwebsocket tests");
    test_step.dependOn(&run_mod_tests.step);

    const bench_run = b.addRunArtifact(bench_exe);
    bench_run.step.dependOn(&install_bench.step);
    if (b.args) |args| bench_run.addArgs(args);
    const bench_step = b.step("bench", "Run the websocket benchmark client");
    bench_step.dependOn(&bench_run.step);

    const compare_run = b.addRunArtifact(compare_exe);
    compare_run.step.dependOn(&install_bench.step);
    compare_run.step.dependOn(&install_bench_server.step);
    compare_run.step.dependOn(&install_compare.step);
    if (b.args) |args| compare_run.addArgs(args);
    const compare_step = b.step("bench-compare", "Compare zwebsocket and uWebSockets");
    compare_step.dependOn(&compare_run.step);

    const bench_server_step = b.step("bench-server", "Build the standalone websocket benchmark server");
    bench_server_step.dependOn(&install_bench_server.step);
}
