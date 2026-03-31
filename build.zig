const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const static_libc = b.option(bool, "static_libc", "Link against static ziglibc instead of system libc") orelse false;

    const ziglibc_dep = if (static_libc) b.dependency("ziglibc", .{
        .target = target,
        .optimize = optimize,
        .trace = false,
    }) else null;
    const static_libc_artifact = if (ziglibc_dep) |dep| findDependencyArtifactByLinkage(dep, "cguana", .static) else null;

    const mod = b.addModule("zwebsocket", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = !static_libc,
    });
    mod.linkSystemLibrary("z", .{});
    if (static_libc_artifact) |artifact| {
        configureStaticLibc(mod, artifact, ziglibc_dep.?);
    } else {
        mod.linkSystemLibrary("c", .{});
    }

    const support_common = b.createModule(.{
        .root_source_file = b.path("support/common.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = !static_libc,
        .imports = &.{
            .{ .name = "zwebsocket", .module = mod },
        },
    });
    if (static_libc_artifact) |artifact| {
        configureStaticLibc(support_common, artifact, ziglibc_dep.?);
    }

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
            .link_libc = !static_libc,
            .imports = &.{
                .{ .name = "zwebsocket", .module = mod },
                .{ .name = "zws_support_common", .module = support_common },
            },
        }),
    });
    if (static_libc_artifact) |artifact| {
        configureStaticLibc(bench_exe.root_module, artifact, ziglibc_dep.?);
    }
    const install_bench = b.addInstallArtifact(bench_exe, .{});

    const bench_server_exe = b.addExecutable(.{
        .name = "zwebsocket-bench-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmark/zwebsocket_server.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = !static_libc,
            .imports = &.{
                .{ .name = "zwebsocket", .module = mod },
                .{ .name = "zws_support_common", .module = support_common },
            },
        }),
    });
    if (static_libc_artifact) |artifact| {
        configureStaticLibc(bench_server_exe.root_module, artifact, ziglibc_dep.?);
    }
    const install_bench_server = b.addInstallArtifact(bench_server_exe, .{});

    const compare_exe = b.addExecutable(.{
        .name = "zwebsocket-bench-compare",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmark/run_compare.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = !static_libc,
            .imports = &.{
                .{ .name = "zwebsocket", .module = mod },
                .{ .name = "zws_support_common", .module = support_common },
            },
        }),
    });
    if (static_libc_artifact) |artifact| {
        configureStaticLibc(compare_exe.root_module, artifact, ziglibc_dep.?);
    }
    const install_compare = b.addInstallArtifact(compare_exe, .{});

    const bench_ab_exe = b.addExecutable(.{
        .name = "zwebsocket-bench-ab",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmark/run_ab.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const echo_server_exe = b.addExecutable(.{
        .name = "zwebsocket-echo-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/echo_server.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = !static_libc,
            .imports = &.{
                .{ .name = "zwebsocket", .module = mod },
                .{ .name = "zws_support_common", .module = support_common },
            },
        }),
    });
    if (static_libc_artifact) |artifact| {
        configureStaticLibc(echo_server_exe.root_module, artifact, ziglibc_dep.?);
    }
    const install_echo_server = b.addInstallArtifact(echo_server_exe, .{});

    const frame_echo_server_exe = b.addExecutable(.{
        .name = "zwebsocket-frame-echo-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/frame_echo_server.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = !static_libc,
            .imports = &.{
                .{ .name = "zwebsocket", .module = mod },
                .{ .name = "zws_support_common", .module = support_common },
            },
        }),
    });
    if (static_libc_artifact) |artifact| {
        configureStaticLibc(frame_echo_server_exe.root_module, artifact, ziglibc_dep.?);
    }
    const install_frame_echo_server = b.addInstallArtifact(frame_echo_server_exe, .{});

    const client_exe = b.addExecutable(.{
        .name = "zwebsocket-client",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/ws_client.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = !static_libc,
            .imports = &.{
                .{ .name = "zwebsocket", .module = mod },
                .{ .name = "zws_support_common", .module = support_common },
            },
        }),
    });
    if (static_libc_artifact) |artifact| {
        configureStaticLibc(client_exe.root_module, artifact, ziglibc_dep.?);
    }
    const install_client = b.addInstallArtifact(client_exe, .{});

    const interop_client_exe = b.addExecutable(.{
        .name = "zwebsocket-interop-client",
        .root_module = b.createModule(.{
            .root_source_file = b.path("validation/zws_client.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = !static_libc,
            .imports = &.{
                .{ .name = "zwebsocket", .module = mod },
                .{ .name = "zws_support_common", .module = support_common },
            },
        }),
    });
    if (static_libc_artifact) |artifact| {
        configureStaticLibc(interop_client_exe.root_module, artifact, ziglibc_dep.?);
    }
    const install_interop_client = b.addInstallArtifact(interop_client_exe, .{});

    const repeated_offer_client_exe = b.addExecutable(.{
        .name = "zwebsocket-repeated-pmd-offer-client",
        .root_module = b.createModule(.{
            .root_source_file = b.path("validation/repeated_pmd_offer_client.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = !static_libc,
            .imports = &.{
                .{ .name = "zwebsocket", .module = mod },
                .{ .name = "zws_support_common", .module = support_common },
            },
        }),
    });
    if (static_libc_artifact) |artifact| {
        configureStaticLibc(repeated_offer_client_exe.root_module, artifact, ziglibc_dep.?);
    }
    const install_repeated_offer_client = b.addInstallArtifact(repeated_offer_client_exe, .{});

    const interop_runner_exe = b.addExecutable(.{
        .name = "zwebsocket-interop-runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("validation/run_interop.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = !static_libc,
        }),
    });
    if (static_libc_artifact) |artifact| {
        configureStaticLibc(interop_runner_exe.root_module, artifact, ziglibc_dep.?);
    }

    const soak_runner_exe = b.addExecutable(.{
        .name = "zwebsocket-soak-runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("validation/soak.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = !static_libc,
            .imports = &.{
                .{ .name = "zwebsocket", .module = mod },
                .{ .name = "zws_support_common", .module = support_common },
            },
        }),
    });
    if (static_libc_artifact) |artifact| {
        configureStaticLibc(soak_runner_exe.root_module, artifact, ziglibc_dep.?);
    }

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
    const compare_step = b.step("bench-compare", "Compare zwebsocket and uWebSockets");
    compare_step.dependOn(&compare_run.step);

    const bench_ab_run = b.addRunArtifact(bench_ab_exe);
    const bench_ab_step = b.step("bench-ab", "Run low-noise interleaved zwebsocket vs uWebSockets benchmark rounds");
    bench_ab_step.dependOn(&bench_ab_run.step);

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

    const repeated_offer_client_step = b.step("interop-repeated-offer-client", "Build the repeated permessage-deflate offer regression client");
    repeated_offer_client_step.dependOn(&install_repeated_offer_client.step);

    const interop_run = b.addRunArtifact(interop_runner_exe);
    interop_run.step.dependOn(&install_echo_server.step);
    interop_run.step.dependOn(&install_interop_client.step);
    interop_run.step.dependOn(&install_repeated_offer_client.step);
    interop_run.addArg(b.fmt("--server-bin={s}", .{b.getInstallPath(.bin, "zwebsocket-echo-server")}));
    interop_run.addArg(b.fmt("--client-bin={s}", .{b.getInstallPath(.bin, "zwebsocket-interop-client")}));
    interop_run.addArg(b.fmt("--repeated-client-bin={s}", .{b.getInstallPath(.bin, "zwebsocket-repeated-pmd-offer-client")}));
    const interop_step = b.step("interop", "Run the websocket interoperability matrix");
    interop_step.dependOn(&interop_run.step);

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

fn configureStaticLibc(module: *std.Build.Module, artifact: *std.Build.Step.Compile, dep: *std.Build.Dependency) void {
    module.addIncludePath(dep.path("inc/libc"));
    module.addIncludePath(dep.path("inc/posix"));
    module.addIncludePath(dep.path("inc/gnu"));
    module.linkLibrary(artifact);
}

fn findDependencyArtifactByLinkage(
    dep: *std.Build.Dependency,
    name: []const u8,
    linkage: std.builtin.LinkMode,
) *std.Build.Step.Compile {
    var found: ?*std.Build.Step.Compile = null;
    for (dep.builder.install_tls.step.dependencies.items) |dep_step| {
        const install_artifact = dep_step.cast(std.Build.Step.InstallArtifact) orelse continue;
        if (!std.mem.eql(u8, install_artifact.artifact.name, name)) continue;
        if (install_artifact.artifact.linkage != linkage) continue;

        if (found != null) {
            std.debug.panic(
                "artifact '{s}' with linkage '{s}' is ambiguous in dependency",
                .{ name, @tagName(linkage) },
            );
        }
        found = install_artifact.artifact;
    }

    if (found) |artifact| return artifact;
    std.debug.panic(
        "unable to find artifact '{s}' with linkage '{s}' in dependency install graph",
        .{ name, @tagName(linkage) },
    );
}
