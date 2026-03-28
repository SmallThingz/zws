const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("zwebsocket", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.linkSystemLibrary("c", .{});
    mod.linkSystemLibrary("z", .{});

    const support_common = b.createModule(.{
        .root_source_file = b.path("support/common.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zwebsocket", .module = mod },
        },
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
                .{ .name = "zws_support_common", .module = support_common },
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
                .{ .name = "zws_support_common", .module = support_common },
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
                .{ .name = "zws_support_common", .module = support_common },
            },
        }),
    });
    const install_compare = b.addInstallArtifact(compare_exe, .{});

    const echo_server_exe = b.addExecutable(.{
        .name = "zwebsocket-echo-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/echo_server.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zwebsocket", .module = mod },
                .{ .name = "zws_support_common", .module = support_common },
            },
        }),
    });
    const install_echo_server = b.addInstallArtifact(echo_server_exe, .{});

    const frame_echo_server_exe = b.addExecutable(.{
        .name = "zwebsocket-frame-echo-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/frame_echo_server.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zwebsocket", .module = mod },
                .{ .name = "zws_support_common", .module = support_common },
            },
        }),
    });
    const install_frame_echo_server = b.addInstallArtifact(frame_echo_server_exe, .{});

    const client_exe = b.addExecutable(.{
        .name = "zwebsocket-client",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/ws_client.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zwebsocket", .module = mod },
                .{ .name = "zws_support_common", .module = support_common },
            },
        }),
    });
    const install_client = b.addInstallArtifact(client_exe, .{});

    const interop_client_exe = b.addExecutable(.{
        .name = "zwebsocket-interop-client",
        .root_module = b.createModule(.{
            .root_source_file = b.path("validation/zws_client.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zwebsocket", .module = mod },
                .{ .name = "zws_support_common", .module = support_common },
            },
        }),
    });
    const install_interop_client = b.addInstallArtifact(interop_client_exe, .{});

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

    const example_server_step = b.step("example-echo-server", "Build the example websocket echo server");
    example_server_step.dependOn(&install_echo_server.step);

    const example_frame_server_step = b.step("example-frame-echo-server", "Build the frame-oriented websocket echo server example");
    example_frame_server_step.dependOn(&install_frame_echo_server.step);

    const example_client_step = b.step("example-client", "Build the websocket client example");
    example_client_step.dependOn(&install_client.step);

    const examples_step = b.step("examples", "Build all zwebsocket examples");
    examples_step.dependOn(&install_echo_server.step);
    examples_step.dependOn(&install_frame_echo_server.step);
    examples_step.dependOn(&install_client.step);

    const interop_client_step = b.step("interop-client", "Build the websocket interoperability client");
    interop_client_step.dependOn(&install_interop_client.step);

    const interop_run = b.addSystemCommand(&.{"python3"});
    interop_run.step.dependOn(&install_echo_server.step);
    interop_run.step.dependOn(&install_interop_client.step);
    interop_run.addFileArg(b.path("validation/run_interop.py"));
    interop_run.addArg("--server-bin");
    interop_run.addArg(b.getInstallPath(.bin, "zwebsocket-echo-server"));
    interop_run.addArg("--client-bin");
    interop_run.addArg(b.getInstallPath(.bin, "zwebsocket-interop-client"));
    const interop_step = b.step("interop", "Run the websocket interoperability matrix");
    interop_step.dependOn(&interop_run.step);

    const soak_run = b.addSystemCommand(&.{"python3"});
    soak_run.step.dependOn(&install_echo_server.step);
    soak_run.addFileArg(b.path("validation/soak.py"));
    soak_run.addArg("--server-bin");
    soak_run.addArg(b.getInstallPath(.bin, "zwebsocket-echo-server"));
    const soak_compressed = b.addSystemCommand(&.{"python3"});
    soak_compressed.step.dependOn(&install_echo_server.step);
    soak_compressed.addFileArg(b.path("validation/soak.py"));
    soak_compressed.addArg("--server-bin");
    soak_compressed.addArg(b.getInstallPath(.bin, "zwebsocket-echo-server"));
    soak_compressed.addArg("--compression");
    const soak_step = b.step("soak", "Run websocket soak tests against the example server");
    soak_step.dependOn(&soak_run.step);
    soak_step.dependOn(&soak_compressed.step);

    const validate_step = b.step("validate", "Run tests, interop, and soak validation");
    validate_step.dependOn(&run_mod_tests.step);
    validate_step.dependOn(&interop_run.step);
    validate_step.dependOn(&soak_run.step);
    validate_step.dependOn(&soak_compressed.step);
}
