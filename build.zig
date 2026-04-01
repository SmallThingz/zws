const std = @import("std");

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const example_choice = b.option([]const u8, "example", "Select one example: echo-server, frame-echo-server, client");
    const interop_choice = b.option([]const u8, "interop", "Select one interop target: run, client, repeated-offer-client");

    const mod = b.addModule("zwebsocket", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

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
    const support_tests = b.addTest(.{
        .root_module = support_common,
    });
    const run_support_tests = b.addRunArtifact(support_tests);

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
            .root_source_file = b.path("benchmark/run_ab.zig"),
            .target = target,
            .optimize = optimize,
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

    const repeated_offer_client_exe = b.addExecutable(.{
        .name = "zwebsocket-repeated-pmd-offer-client",
        .root_module = b.createModule(.{
            .root_source_file = b.path("validation/repeated_pmd_offer_client.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zwebsocket", .module = mod },
                .{ .name = "zws_support_common", .module = support_common },
            },
        }),
    });
    const install_repeated_offer_client = b.addInstallArtifact(repeated_offer_client_exe, .{});

    const interop_runner_exe = b.addExecutable(.{
        .name = "zwebsocket-interop-runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("validation/run_interop.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const soak_runner_exe = b.addExecutable(.{
        .name = "zwebsocket-soak-runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("validation/soak.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zwebsocket", .module = mod },
                .{ .name = "zws_support_common", .module = support_common },
            },
        }),
    });

    const install_step = b.getInstallStep();
    install_step.dependOn(&install_bench.step);
    install_step.dependOn(&install_bench_server.step);
    install_step.dependOn(&install_compare.step);
    install_step.dependOn(&install_echo_server.step);
    install_step.dependOn(&install_frame_echo_server.step);
    install_step.dependOn(&install_client.step);
    install_step.dependOn(&install_interop_client.step);
    install_step.dependOn(&install_repeated_offer_client.step);

    const test_step = b.step("test", "Run zwebsocket tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_support_tests.step);

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
    const compare_step = b.step("bench-compare", "Run interleaved zwebsocket vs uWebSockets benchmark rounds");
    compare_step.dependOn(&compare_run.step);

    const examples_step = b.step("examples", "Build zwebsocket examples; use -Dexample=echo-server|frame-echo-server|client to select one");
    if (example_choice) |choice| {
        if (eql(choice, "echo-server")) {
            examples_step.dependOn(&install_echo_server.step);
        } else if (eql(choice, "frame-echo-server")) {
            examples_step.dependOn(&install_frame_echo_server.step);
        } else if (eql(choice, "client")) {
            examples_step.dependOn(&install_client.step);
        } else {
            @panic("invalid -Dexample value; expected echo-server, frame-echo-server, or client");
        }
    } else {
        examples_step.dependOn(&install_echo_server.step);
        examples_step.dependOn(&install_frame_echo_server.step);
        examples_step.dependOn(&install_client.step);
    }

    const interop_run = b.addRunArtifact(interop_runner_exe);
    interop_run.step.dependOn(&install_echo_server.step);
    interop_run.step.dependOn(&install_interop_client.step);
    interop_run.step.dependOn(&install_repeated_offer_client.step);
    interop_run.addArg(b.fmt("--server-bin={s}", .{b.getInstallPath(.bin, "zwebsocket-echo-server")}));
    interop_run.addArg(b.fmt("--client-bin={s}", .{b.getInstallPath(.bin, "zwebsocket-interop-client")}));
    interop_run.addArg(b.fmt("--repeated-client-bin={s}", .{b.getInstallPath(.bin, "zwebsocket-repeated-pmd-offer-client")}));
    const interop_step = b.step("interop", "Run interop or build an interop helper with -Dinterop=run|client|repeated-offer-client");
    if (interop_choice) |choice| {
        if (eql(choice, "run")) {
            interop_step.dependOn(&interop_run.step);
        } else if (eql(choice, "client")) {
            interop_step.dependOn(&install_interop_client.step);
        } else if (eql(choice, "repeated-offer-client")) {
            interop_step.dependOn(&install_repeated_offer_client.step);
        } else {
            @panic("invalid -Dinterop value; expected run, client, or repeated-offer-client");
        }
    } else {
        interop_step.dependOn(&interop_run.step);
    }

    const soak_run = b.addRunArtifact(soak_runner_exe);
    soak_run.step.dependOn(&install_echo_server.step);
    soak_run.addArg(b.fmt("--server-bin={s}", .{b.getInstallPath(.bin, "zwebsocket-echo-server")}));
    const soak_compressed = b.addRunArtifact(soak_runner_exe);
    soak_compressed.step.dependOn(&install_echo_server.step);
    soak_compressed.addArg(b.fmt("--server-bin={s}", .{b.getInstallPath(.bin, "zwebsocket-echo-server")}));
    soak_compressed.addArg("--compression");
    const soak_step = b.step("soak", "Run websocket soak tests against the example server");
    soak_step.dependOn(&soak_run.step);
    soak_step.dependOn(&soak_compressed.step);

    const validate_step = b.step("validate", "Run tests, interop, and soak validation");
    validate_step.dependOn(&run_mod_tests.step);
    validate_step.dependOn(&run_support_tests.step);
    validate_step.dependOn(&interop_run.step);
    validate_step.dependOn(&soak_run.step);
    validate_step.dependOn(&soak_compressed.step);
}
