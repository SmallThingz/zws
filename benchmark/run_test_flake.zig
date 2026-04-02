const std = @import("std");

const Config = struct {
    test_bin: []const u8,
    iterations: usize = 100,
    start_seed: u32 = 1,
    jobs: usize = 1,
    retries: usize = 3,
    timeout_seconds: u32 = 120,
    test_filter: ?[]const u8 = null,
    skip_filter: ?[]const u8 = null,
    verbose: bool = false,
};

const RunOutcome = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,
};

const FailureKind = enum {
    fail,
    leak,
    crash,
};

const FailureItem = struct {
    kind: FailureKind,
    test_name: []u8,
    line: []u8,
};

fn usage() void {
    std.debug.print(
        \\run_test_flake
        \\
        \\Usage:
        \\  zig build test-flake -- [options]
        \\
        \\Options:
        \\  --iterations=<n>                 default: 100
        \\  --start-seed=<u32>               default: 1
        \\  --jobs=<n>                       default: 1
        \\  --retries=<n>                    default: 3
        \\  --timeout-seconds=<n>            default: 120
        \\  --test-filter=<substring>        optional
        \\  --skip-filter=<substring>        optional
        \\  --verbose                        print full stdout/stderr on failure
        \\  --help
        \\
    , .{});
}

fn parseUnsigned(comptime T: type, s: []const u8) !T {
    return std.fmt.parseUnsigned(T, s, 10);
}

fn startsWithValue(arg: []const u8, prefix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, arg, prefix)) return null;
    return arg[prefix.len..];
}

fn classify(term: std.process.Child.Term) []const u8 {
    return switch (term) {
        .exited => |code| if (code == 0) "pass" else "fail",
        .signal => "signal",
        .stopped => "stopped",
        .unknown => "unknown",
    };
}

fn runTimeout(cfg: Config) std.Io.Timeout {
    return .{
        .duration = .{
            .raw = std.Io.Duration.fromSeconds(@as(i64, cfg.timeout_seconds)),
            .clock = .awake,
        },
    };
}

fn failed(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code != 0,
        else => true,
    };
}

fn printTerm(term: std.process.Child.Term) void {
    switch (term) {
        .exited => |code| std.debug.print("term=exited code={d}\n", .{code}),
        .signal => |sig| std.debug.print("term=signal sig={d} ({s})\n", .{ @intFromEnum(sig), @tagName(sig) }),
        .stopped => |sig| std.debug.print("term=stopped sig={d}\n", .{sig}),
        .unknown => |v| std.debug.print("term=unknown value={d}\n", .{v}),
    }
}

fn deinitFailures(allocator: std.mem.Allocator, failures: []FailureItem) void {
    for (failures) |f| {
        allocator.free(f.test_name);
        allocator.free(f.line);
    }
    allocator.free(failures);
}

fn stripAnsiAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        const b = input[i];
        if (b == '\x1b' and i + 1 < input.len and input[i + 1] == '[') {
            i += 2;
            while (i < input.len) : (i += 1) {
                const c = input[i];
                if (c >= '@' and c <= '~') {
                    i += 1;
                    break;
                }
            }
            continue;
        }
        if (b != '\r') {
            try out.append(allocator, b);
        }
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

fn parseFailureLine(line: []const u8) ?struct { kind: FailureKind, test_name: []const u8 } {
    const prefixes = [_]struct { kind: FailureKind, text: []const u8 }{
        .{ .kind = .fail, .text = "error " },
        .{ .kind = .leak, .text = "leak " },
        .{ .kind = .crash, .text = "crash " },
    };

    for (prefixes) |prefix| {
        if (!std.mem.startsWith(u8, line, prefix.text)) continue;
        const rest = std.mem.trim(u8, line[prefix.text.len..], " \t");
        if (rest.len == 0) return null;

        const term_idx = std.mem.indexOf(u8, rest, " | ") orelse rest.len;
        const test_name = std.mem.trim(u8, rest[0..term_idx], " \t");
        if (test_name.len == 0) return null;

        return .{ .kind = prefix.kind, .test_name = test_name };
    }

    return null;
}

fn extractFailures(allocator: std.mem.Allocator, stderr: []const u8) ![]FailureItem {
    const clean = try stripAnsiAlloc(allocator, stderr);
    defer allocator.free(clean);

    var failures: std.ArrayList(FailureItem) = .empty;
    errdefer {
        for (failures.items) |f| {
            allocator.free(f.test_name);
            allocator.free(f.line);
        }
        failures.deinit(allocator);
    }

    var it = std.mem.splitScalar(u8, clean, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t");
        if (line.len == 0) continue;
        const parsed = parseFailureLine(line) orelse continue;

        var duplicate = false;
        for (failures.items) |existing| {
            if (existing.kind == parsed.kind and std.mem.eql(u8, existing.test_name, parsed.test_name)) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) continue;

        try failures.append(allocator, .{
            .kind = parsed.kind,
            .test_name = try allocator.dupe(u8, parsed.test_name),
            .line = try allocator.dupe(u8, line),
        });
    }

    if (failures.items.len == 0) {
        failures.deinit(allocator);
        return try allocator.alloc(FailureItem, 0);
    }

    return failures.toOwnedSlice(allocator);
}

fn runWithSeed(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: Config,
    seed: u32,
) !RunOutcome {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);

    const seed_s = try std.fmt.allocPrint(allocator, "{d}", .{seed});
    defer allocator.free(seed_s);
    const jobs_s = try std.fmt.allocPrint(allocator, "{d}", .{cfg.jobs});
    defer allocator.free(jobs_s);

    try argv.append(allocator, cfg.test_bin);
    try argv.append(allocator, "--seed");
    try argv.append(allocator, seed_s);
    try argv.append(allocator, "--jobs");
    try argv.append(allocator, jobs_s);

    if (cfg.test_filter) |f| {
        const filter_arg = try std.fmt.allocPrint(allocator, "--zws-match={s}", .{f});
        defer allocator.free(filter_arg);
        try argv.append(allocator, filter_arg);
    }

    if (cfg.skip_filter) |f| {
        const skip_arg = try std.fmt.allocPrint(allocator, "--zws-skip={s}", .{f});
        defer allocator.free(skip_arg);
        try argv.append(allocator, skip_arg);
    }

    const result = try std.process.run(allocator, io, .{
        .argv = argv.items,
        .stdout_limit = .limited(16 * 1024 * 1024),
        .stderr_limit = .limited(16 * 1024 * 1024),
        .reserve_amount = 64 * 1024,
        .timeout = runTimeout(cfg),
    });

    return .{
        .term = result.term,
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}

fn runSingleTestWithSeed(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: Config,
    seed: u32,
    test_name: []const u8,
) !RunOutcome {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);

    const seed_s = try std.fmt.allocPrint(allocator, "{d}", .{seed});
    defer allocator.free(seed_s);

    try argv.append(allocator, cfg.test_bin);
    try argv.append(allocator, "--zws-run-test");
    try argv.append(allocator, test_name);
    try argv.append(allocator, "--seed");
    try argv.append(allocator, seed_s);

    const result = try std.process.run(allocator, io, .{
        .argv = argv.items,
        .stdout_limit = .limited(2 * 1024 * 1024),
        .stderr_limit = .limited(2 * 1024 * 1024),
        .reserve_amount = 16 * 1024,
        .timeout = runTimeout(cfg),
    });

    return .{
        .term = result.term,
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}

fn printRepro(cfg: Config, seed: u32) void {
    std.debug.print("\nrepro command:\n", .{});
    std.debug.print("  zig build test -- --seed {d} --jobs {d}", .{ seed, cfg.jobs });
    if (cfg.test_filter) |f| {
        std.debug.print(" --zws-match \"{s}\"", .{f});
    }
    if (cfg.skip_filter) |f| {
        std.debug.print(" --zws-skip \"{s}\"", .{f});
    }
    std.debug.print("\n", .{});
}

fn printSingleTestRepro(seed: u32, test_name: []const u8) void {
    std.debug.print(
        "  zig build test -- --zws-run-test \"{s}\" --seed {d}\n",
        .{ test_name, seed },
    );
}

fn freeOutcome(allocator: std.mem.Allocator, outcome: RunOutcome) void {
    allocator.free(outcome.stdout);
    allocator.free(outcome.stderr);
}

/// Starts this executable.
pub fn main(init: std.process.Init) !void {
    var cfg: Config = .{
        .test_bin = "",
    };

    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer it.deinit();
    _ = it.next();

    while (it.next()) |arg_z| {
        const arg: []const u8 = arg_z;
        if (std.mem.eql(u8, arg, "--help")) {
            usage();
            return;
        }
        if (std.mem.eql(u8, arg, "--verbose")) {
            cfg.verbose = true;
            continue;
        }
        if (startsWithValue(arg, "--test-bin=")) |v| {
            cfg.test_bin = v;
            continue;
        }
        if (startsWithValue(arg, "--iterations=")) |v| {
            cfg.iterations = try parseUnsigned(usize, v);
            continue;
        }
        if (startsWithValue(arg, "--start-seed=")) |v| {
            cfg.start_seed = try parseUnsigned(u32, v);
            continue;
        }
        if (startsWithValue(arg, "--jobs=")) |v| {
            cfg.jobs = try parseUnsigned(usize, v);
            continue;
        }
        if (startsWithValue(arg, "--retries=")) |v| {
            cfg.retries = try parseUnsigned(usize, v);
            continue;
        }
        if (startsWithValue(arg, "--timeout-seconds=")) |v| {
            cfg.timeout_seconds = try parseUnsigned(u32, v);
            continue;
        }
        if (startsWithValue(arg, "--test-filter=")) |v| {
            cfg.test_filter = v;
            continue;
        }
        if (startsWithValue(arg, "--skip-filter=")) |v| {
            cfg.skip_filter = v;
            continue;
        }
        return error.UnknownArg;
    }

    if (cfg.test_bin.len == 0) return error.MissingTestBinary;
    if (cfg.jobs == 0) return error.InvalidJobs;
    if (cfg.iterations == 0) return error.InvalidIterations;
    if (cfg.retries == 0) return error.InvalidRetries;
    if (cfg.timeout_seconds == 0) return error.InvalidTimeout;

    std.debug.print(
        "test-flake: iterations={d} start_seed={d} jobs={d} retries={d} timeout={d}s\n",
        .{ cfg.iterations, cfg.start_seed, cfg.jobs, cfg.retries, cfg.timeout_seconds },
    );

    var i: usize = 0;
    var transient_failures: usize = 0;
    while (i < cfg.iterations) : (i += 1) {
        const seed_u64 = @as(u64, cfg.start_seed) + i;
        if (seed_u64 > std.math.maxInt(u32)) return error.SeedOverflow;
        const seed: u32 = @intCast(seed_u64);

        std.debug.print("  seed {d}/{d} (seed={d})\n", .{ i + 1, cfg.iterations, seed });

        const run = runWithSeed(init.gpa, init.io, cfg, seed) catch |err| switch (err) {
            error.Timeout => {
                std.debug.print(
                    "\nflaky failure caught at seed={d} (timeout after {d}s)\n",
                    .{ seed, cfg.timeout_seconds },
                );
                printRepro(cfg, seed);
                return error.FlakyFailureFound;
            },
            else => return err,
        };
        defer freeOutcome(init.gpa, run);

        if (!failed(run.term)) {
            continue;
        }

        std.debug.print("\nflaky failure caught at seed={d} ({s})\n", .{ seed, classify(run.term) });
        printTerm(run.term);
        const failures = try extractFailures(init.gpa, run.stderr);
        defer deinitFailures(init.gpa, failures);

        if (failures.len != 0) {
            std.debug.print("detected failing tests:\n", .{});
            for (failures) |f| {
                std.debug.print("  - {s}\n", .{f.line});
            }
        }

        if (cfg.verbose) {
            if (run.stderr.len != 0) {
                std.debug.print("stderr:\n{s}", .{run.stderr});
                if (run.stderr[run.stderr.len - 1] != '\n') std.debug.print("\n", .{});
            }
            if (run.stdout.len != 0) {
                std.debug.print("stdout:\n{s}", .{run.stdout});
                if (run.stdout[run.stdout.len - 1] != '\n') std.debug.print("\n", .{});
            }
        } else {
            std.debug.print("full failing logs omitted (rerun with --verbose)\n", .{});
        }

        var reproduced: usize = 0;
        var r: usize = 0;
        while (r < cfg.retries) : (r += 1) {
            const retry = runWithSeed(init.gpa, init.io, cfg, seed) catch |err| switch (err) {
                error.Timeout => {
                    reproduced += 1;
                    continue;
                },
                else => return err,
            };
            defer freeOutcome(init.gpa, retry);
            if (failed(retry.term)) reproduced += 1;
        }

        std.debug.print(
            "reproducibility at seed {d}: {d}/{d} failing reruns\n",
            .{ seed, reproduced, cfg.retries },
        );
        if (reproduced == 0) {
            transient_failures += 1;
            std.debug.print("seed {d} did not reproduce; continuing sweep\n", .{seed});
            continue;
        }
        if (failures.len != 0) {
            std.debug.print("single-test repro commands:\n", .{});
            var isolated_failures: usize = 0;
            for (failures) |f| {
                printSingleTestRepro(seed, f.test_name);

                const single = runSingleTestWithSeed(init.gpa, init.io, cfg, seed, f.test_name) catch |err| switch (err) {
                    error.Timeout => {
                        isolated_failures += 1;
                        std.debug.print("    isolate status: timeout\n", .{});
                        continue;
                    },
                    else => return err,
                };
                defer freeOutcome(init.gpa, single);
                if (failed(single.term)) isolated_failures += 1;
                std.debug.print(
                    "    isolate status: {s}\n",
                    .{classify(single.term)},
                );
            }
            if (isolated_failures == 0) {
                std.debug.print(
                    "    note: isolated reruns passed; this failure is likely order-dependent or cross-test-state dependent.\n",
                    .{},
                );
            }
        }
        printRepro(cfg, seed);
        return error.FlakyFailureFound;
    }

    if (transient_failures != 0) {
        std.debug.print(
            "no reproducible flaky failures found across {d} seeded runs ({d} non-reproducible failures seen)\n",
            .{ cfg.iterations, transient_failures },
        );
        return;
    }

    std.debug.print("no flaky failures found across {d} seeded runs\n", .{cfg.iterations});
}
