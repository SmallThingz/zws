const std = @import("std");
const builtin = @import("builtin");

pub const std_options: std.Options = .{
    // ReleaseFast test binaries were crashing during std's segfault-handler
    // bootstrap on this target; keep the runner stable and let the OS default
    // signal handling terminate hard crashes.
    .enable_segfault_handler = false,
    .signal_stack_size = null,
};

pub const panic = std.debug.FullPanic(panicHandler);

const default_job_cap: usize = 16;

fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    var rest = msg;
    rest_loop: switch (rest.len != 0) {
        true => {
            const wrote = std.c.write(std.posix.STDERR_FILENO, rest.ptr, rest.len);
            if (wrote <= 0) return;
            rest = rest[@intCast(wrote)..];
            continue :rest_loop rest.len != 0;
        },
        false => {},
    }
}

/// Implements fuzz.
pub fn fuzz(
    context: anytype,
    comptime testOne: fn (context: @TypeOf(context), smith: *std.testing.Smith) anyerror!void,
    fuzz_opts: std.testing.FuzzInputOptions,
) anyerror!void {
    if (comptime builtin.fuzz) {
        return fuzzBuiltin(context, testOne, fuzz_opts);
    }

    if (fuzz_opts.corpus.len == 0) {
        var smith: std.testing.Smith = .{ .in = "" };
        return testOne(context, &smith);
    }

    for (fuzz_opts.corpus) |input| {
        var smith: std.testing.Smith = .{ .in = input };
        try testOne(context, &smith);
    }
}

fn fuzzBuiltin(
    context: anytype,
    comptime testOne: fn (context: @TypeOf(context), smith: *std.testing.Smith) anyerror!void,
    fuzz_opts: std.testing.FuzzInputOptions,
) anyerror!void {
    const fuzz_abi = std.Build.abi.fuzz;
    const Smith = std.testing.Smith;
    const Ctx = @TypeOf(context);

    const Wrapper = struct {
        var ctx: Ctx = undefined;
        /// Implements test one c.
        pub fn testOneC() callconv(.c) void {
            var smith: Smith = .{ .in = null };
            testOne(ctx, &smith) catch {};
        }
    };

    Wrapper.ctx = context;

    var cache_dir: []const u8 = ".";
    var map_opt: ?std.process.Environ.Map = null;
    if (std.testing.environ.createMap(std.testing.allocator)) |map| {
        map_opt = map;
        if (map.get("ZIG_CACHE_DIR")) |v| {
            cache_dir = v;
        } else if (map.get("ZIG_GLOBAL_CACHE_DIR")) |v| {
            cache_dir = v;
        }
    } else |_| {}

    fuzz_abi.fuzzer_init(.fromSlice(cache_dir));

    const test_name = @typeName(@TypeOf(testOne));
    fuzz_abi.fuzzer_set_test(Wrapper.testOneC, .fromSlice(test_name));

    for (fuzz_opts.corpus) |input| {
        fuzz_abi.fuzzer_new_input(.fromSlice(input));
    }

    fuzz_abi.fuzzer_main(.forever, 0);

    if (map_opt) |*m| m.deinit();
}

/// Starts this executable.
pub fn main(init: std.process.Init) void {
    const code = mainImpl(init) catch |err| blk: {
        print("test-runner fatal: {s}\n", .{@errorName(err)});
        break :blk @as(u8, 1);
    };
    std.process.exit(code);
}

fn mainImpl(init: std.process.Init) !u8 {
    const threaded = std.Io.Threaded.init(init.gpa, .{
        .argv0 = .init(init.minimal.args),
        .environ = init.minimal.environ,
    });
    std.testing.io_instance = threaded;
    // NOTE: ReleaseFast teardown currently crashes in std.Io.Threaded.deinit()
    // for this runner path after all tests have completed. Keep process-exit
    // cleanup implicit (OS reclaim) so successful test runs do not false-fail.
    std.testing.environ = init.minimal.environ;

    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);

    const argv0_z = arg_it.next() orelse "test-runner";
    const argv0 = argv0_z[0..argv0_z.len];

    var child_test_name: ?[]const u8 = null;
    var filter: ?[]const u8 = null;
    var exclude_filters: std.ArrayList([]const u8) = .empty;
    var jobs: ?usize = null;
    var seed: ?u32 = null;

    while (arg_it.next()) |arg_z| {
        const arg = arg_z[0..arg_z.len];
        if (std.mem.startsWith(u8, arg, "--zws-match=")) {
            const idx = std.mem.indexOfScalar(u8, arg, '=') orelse unreachable;
            filter = arg[idx + 1 ..];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--zws-skip=")) {
            const idx = std.mem.indexOfScalar(u8, arg, '=') orelse unreachable;
            try exclude_filters.append(init.gpa, arg[idx + 1 ..]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--zws-run-test")) {
            const name_z = arg_it.next() orelse return error.MissingTestName;
            child_test_name = name_z[0..name_z.len];
        } else if (std.mem.eql(u8, arg, "--zws-match")) {
            const f_z = arg_it.next() orelse return error.MissingFilter;
            filter = f_z[0..f_z.len];
        } else if (std.mem.eql(u8, arg, "--zws-skip")) {
            const f_z = arg_it.next() orelse return error.MissingFilter;
            try exclude_filters.append(init.gpa, f_z[0..f_z.len]);
        } else if (std.mem.eql(u8, arg, "--jobs")) {
            const j_z = arg_it.next() orelse return error.MissingJobs;
            jobs = try parseUsize(j_z[0..j_z.len]);
        } else if (std.mem.eql(u8, arg, "--seed")) {
            const s_z = arg_it.next() orelse return error.MissingSeed;
            seed = try parseU32(s_z[0..s_z.len]);
        } else if (std.mem.eql(u8, arg, "--help")) {
            printHelp();
            return 0;
        } else {
            // Ignore unknown args to stay compatible with Zig's test flags.
        }
    }

    if (child_test_name) |name| {
        const code = runSingleTest(name, seed);
        return code;
    }

    try runAllTests(init.gpa, init.io, argv0, filter, exclude_filters.items, jobs, seed);
    return 0;
}

fn panicHandler(msg: []const u8, first_trace_addr: ?usize) noreturn {
    std.debug.defaultPanic(msg, first_trace_addr);
}

fn parseUsize(s: []const u8) !usize {
    return std.fmt.parseUnsigned(usize, s, 10);
}

fn parseU32(s: []const u8) !u32 {
    return std.fmt.parseUnsigned(u32, s, 10);
}

fn printHelp() void {
    print(
        "Usage: test-runner [--zws-match <str>] [--zws-skip <str>] [--jobs <n>] [--seed <n>]\n" ++
            "  --seed also controls deterministic test ordering in parent mode.\n",
        .{},
    );
}

fn testGroupKey(name: []const u8) []const u8 {
    const marker = ".test.";
    if (std.mem.indexOf(u8, name, marker)) |idx| {
        return name[0 .. idx + marker.len];
    }
    return name;
}

const TestInfo = struct {
    /// Stores `name`.
    name: []const u8,
};

const Status = enum {
    pass,
    fail,
    skip,
    leak,
    crash,
};

const Summary = struct {
    /// Stores `pass`.
    pass: usize = 0,
    /// Stores `fail`.
    fail: usize = 0,
    /// Stores `skip`.
    skip: usize = 0,
    /// Stores `leak`.
    leak: usize = 0,
    /// Stores `crash`.
    crash: usize = 0,
};

const Dashboard = struct {
    /// Stores currently running test names per worker slot.
    running: []?[]const u8,
    /// Number of dashboard lines currently rendered.
    rendered_lines: usize = 0,
};

fn noteStatus(summary: *Summary, status: Status) void {
    switch (status) {
        .pass => summary.pass += 1,
        .fail => summary.fail += 1,
        .skip => summary.skip += 1,
        .leak => summary.leak += 1,
        .crash => summary.crash += 1,
    }
}

fn printRunnerError(name: []const u8, err: anyerror) void {
    print("\n== TEST {s} ==\nrunner error: {s}\n", .{ name, @errorName(err) });
}

fn runAllTests(
    gpa: std.mem.Allocator,
    io: std.Io,
    argv0: []const u8,
    filter: ?[]const u8,
    exclude_filters: []const []const u8,
    jobs: ?usize,
    seed: ?u32,
) !void {
    var tests: std.ArrayList(TestInfo) = .empty;
    defer tests.deinit(gpa);

    for (builtin.test_functions) |t| {
        if (filter) |f| {
            if (std.mem.indexOf(u8, t.name, f) == null) continue;
        }
        var excluded = false;
        for (exclude_filters) |f| {
            if (std.mem.indexOf(u8, t.name, f) != null) {
                excluded = true;
                break;
            }
        }
        if (excluded) continue;
        try tests.append(gpa, .{ .name = t.name });
    }

    if (tests.items.len == 0) {
        print("0 tests selected\n", .{});
        return;
    }

    const GroupBucket = struct {
        key: []const u8,
        items: std.ArrayList(TestInfo) = .empty,
        next: usize = 0,
    };

    var buckets: std.ArrayList(GroupBucket) = .empty;
    defer {
        for (buckets.items) |*b| b.items.deinit(gpa);
        buckets.deinit(gpa);
    }

    for (tests.items) |t| {
        const key = testGroupKey(t.name);
        var found: ?usize = null;
        for (buckets.items, 0..) |b, bi| {
            if (std.mem.eql(u8, b.key, key)) {
                found = bi;
                break;
            }
        }
        if (found == null) {
            try buckets.append(gpa, .{ .key = key });
            found = buckets.items.len - 1;
        }
        try buckets.items[found.?].items.append(gpa, t);
    }

    if (seed) |s| {
        var prng = std.Random.DefaultPrng.init(@as(u64, s));
        var random = prng.random();
        shuffleSlice(GroupBucket, &random, buckets.items);
        for (buckets.items) |*bucket| {
            shuffleSlice(TestInfo, &random, bucket.items.items);
        }
    }

    var reordered: std.ArrayList(TestInfo) = .empty;
    defer reordered.deinit(gpa);
    try reordered.ensureTotalCapacity(gpa, tests.items.len);

    var remaining = tests.items.len;
    reorder_loop: switch (remaining != 0) {
        true => {
            for (buckets.items) |*bucket| {
                if (bucket.next >= bucket.items.items.len) continue;
                try reordered.append(gpa, bucket.items.items[bucket.next]);
                bucket.next += 1;
                remaining -= 1;
            }
            continue :reorder_loop remaining != 0;
        },
        false => {},
    }

    @memcpy(tests.items, reordered.items);

    const cpu_count = std.Thread.getCpuCount() catch 1;
    var job_count = jobs orelse @min(cpu_count, default_job_cap);
    if (job_count == 0) job_count = 1;
    if (job_count > tests.items.len) job_count = tests.items.len;

    var next_index: std.atomic.Value(usize) = .init(0);
    var summary: Summary = .{};
    var print_mutex: std.Io.Mutex = .init;
    var count_mutex: std.Io.Mutex = .init;
    const slot_count: usize = if (builtin.single_threaded or job_count <= 2) 1 else job_count;
    const running = try gpa.alloc(?[]const u8, slot_count);
    defer gpa.free(running);
    @memset(running, null);
    var dashboard: Dashboard = .{ .running = running };

    var ctx = WorkerCtx{
        .gpa = gpa,
        .io = io,
        .argv0 = argv0,
        .tests = tests.items,
        .seed = seed,
        .next_index = &next_index,
        .summary = &summary,
        .print_mutex = &print_mutex,
        .count_mutex = &count_mutex,
        .dashboard = &dashboard,
        .allow_fork = builtin.os.tag != .windows and builtin.link_libc and (builtin.single_threaded or job_count <= 2),
    };

    if (builtin.single_threaded or job_count <= 2) {
        for (tests.items) |t| {
            print_mutex.lockUncancelable(io);
            ctx.dashboard.running[0] = t.name;
            renderDashboardLocked(&ctx);
            print_mutex.unlock(io);

            const result = runChildTest(&ctx, t.name) catch |err| {
                print_mutex.lockUncancelable(io);
                defer print_mutex.unlock(io);
                clearDashboardLocked(&ctx);
                ctx.dashboard.running[0] = null;
                printRunnerError(t.name, err);
                renderDashboardLocked(&ctx);
                noteStatus(&summary, .fail);
                continue;
            };

            print_mutex.lockUncancelable(io);
            defer deinitChildResult(gpa, result);
            clearDashboardLocked(&ctx);
            ctx.dashboard.running[0] = null;
            printTestOutput(t.name, result);
            renderDashboardLocked(&ctx);
            print_mutex.unlock(io);
            noteStatus(&summary, result.status);
        }
    } else {
        const threads = try gpa.alloc(std.Thread, job_count);
        defer gpa.free(threads);
        for (threads, 0..) |*t, i| {
            t.* = try std.Thread.spawn(.{}, worker, .{ &ctx, i });
        }
        for (threads) |t| t.join();
    }

    print_mutex.lockUncancelable(io);
    clearDashboardLocked(&ctx);
    print_mutex.unlock(io);

    print(
        "\npass: {d}  fail: {d}  skip: {d}  leak: {d}  crash: {d}\n",
        .{ summary.pass, summary.fail, summary.skip, summary.leak, summary.crash },
    );

    if (summary.fail != 0 or summary.crash != 0 or summary.leak != 0) {
        std.process.exit(1);
    }
}

fn shuffleSlice(comptime T: type, random: *std.Random, items: []T) void {
    if (items.len <= 1) return;
    var i: usize = items.len - 1;
    shuffle_loop: switch (i != 0) {
        true => {
            const j = random.uintLessThan(usize, i + 1);
            std.mem.swap(T, &items[i], &items[j]);
            i -= 1;
            continue :shuffle_loop i != 0;
        },
        false => {},
    }
}

const WorkerCtx = struct {
    /// Stores `gpa`.
    gpa: std.mem.Allocator,
    /// Stores `io`.
    io: std.Io,
    /// Stores `argv0`.
    argv0: []const u8,
    /// Stores `tests`.
    tests: []const TestInfo,
    /// Stores `seed`.
    seed: ?u32,
    /// Stores `next_index`.
    next_index: *std.atomic.Value(usize),
    /// Stores `summary`.
    summary: *Summary,
    /// Stores `print_mutex`.
    print_mutex: *std.Io.Mutex,
    /// Stores `count_mutex`.
    count_mutex: *std.Io.Mutex,
    /// Stores running dashboard state.
    dashboard: *Dashboard,
    /// Whether this runner may use the low-overhead fork path.
    allow_fork: bool,
};

fn clearDashboardLocked(ctx: *WorkerCtx) void {
    // Rewind and erase previously rendered "running ..." lines.
    if (ctx.dashboard.rendered_lines == 0) return;
    print("\x1b[{d}F", .{ctx.dashboard.rendered_lines});
    var i: usize = 0;
    clear_loop: switch (i < ctx.dashboard.rendered_lines) {
        true => {
            print("\x1b[2K\n", .{});
            i += 1;
            continue :clear_loop i < ctx.dashboard.rendered_lines;
        },
        false => {},
    }
    print("\x1b[{d}F", .{ctx.dashboard.rendered_lines});
    ctx.dashboard.rendered_lines = 0;
}

fn renderDashboardLocked(ctx: *WorkerCtx) void {
    clearDashboardLocked(ctx);

    // Render only active slots so finished workers disappear immediately.
    var rendered: usize = 0;
    for (ctx.dashboard.running) |name_opt| {
        if (name_opt) |name| {
            print("\x1b[33mrunning\x1b[0m {s}\n", .{name});
            rendered += 1;
        }
    }
    if (rendered == 0) return;
    ctx.dashboard.rendered_lines = rendered;
}

fn worker(ctx: *WorkerCtx, slot: usize) void {
    // Each worker claims the next index atomically and executes exactly one test at a time.
    var keep_running = true;
    worker_loop: switch (keep_running) {
        true => {
            const idx = ctx.next_index.fetchAdd(1, .seq_cst);
            if (idx >= ctx.tests.len) {
                keep_running = false;
                continue :worker_loop keep_running;
            }

            const test_name = ctx.tests[idx].name;

            ctx.print_mutex.lockUncancelable(ctx.io);
            ctx.dashboard.running[slot] = test_name;
            renderDashboardLocked(ctx);
            ctx.print_mutex.unlock(ctx.io);

            const result = runChildTest(ctx, test_name) catch |err| {
                ctx.print_mutex.lockUncancelable(ctx.io);
                defer ctx.print_mutex.unlock(ctx.io);
                clearDashboardLocked(ctx);
                ctx.dashboard.running[slot] = null;
                printRunnerError(test_name, err);
                renderDashboardLocked(ctx);
                ctx.count_mutex.lockUncancelable(ctx.io);
                noteStatus(ctx.summary, .fail);
                ctx.count_mutex.unlock(ctx.io);
                continue :worker_loop keep_running;
            };

            ctx.print_mutex.lockUncancelable(ctx.io);
            defer ctx.print_mutex.unlock(ctx.io);
            defer deinitChildResult(ctx.gpa, result);
            clearDashboardLocked(ctx);
            ctx.dashboard.running[slot] = null;
            printTestOutput(test_name, result);
            renderDashboardLocked(ctx);

            ctx.count_mutex.lockUncancelable(ctx.io);
            noteStatus(ctx.summary, result.status);
            ctx.count_mutex.unlock(ctx.io);
            continue :worker_loop keep_running;
        },
        false => {},
    }
}

const ChildResult = struct {
    /// Stores `status`.
    status: Status,
    /// Stores `term`.
    term: ?std.process.Child.Term,
    /// Stores `stdout`.
    stdout: []u8,
    /// Stores `stderr`.
    stderr: []u8,
};

fn runChildTest(ctx: *WorkerCtx, test_name: []const u8) !ChildResult {
    if (ctx.allow_fork) return runForkedTest(ctx, test_name);
    return runExecTest(ctx, test_name);
}

fn runExecTest(ctx: *WorkerCtx, test_name: []const u8) !ChildResult {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(ctx.gpa);

    try argv.append(ctx.gpa, ctx.argv0);
    try argv.append(ctx.gpa, "--zws-run-test");
    try argv.append(ctx.gpa, test_name);

    var seed_buf: ?[]u8 = null;
    if (ctx.seed) |s| {
        const seed_str = try std.fmt.allocPrint(ctx.gpa, "{d}", .{s});
        seed_buf = seed_str;
        try argv.append(ctx.gpa, "--seed");
        try argv.append(ctx.gpa, seed_str);
    }
    defer if (seed_buf) |b| ctx.gpa.free(b);

    const run_result = std.process.run(ctx.gpa, ctx.io, .{
        .argv = argv.items,
        .stdout_limit = .limited(256 * 1024),
        .stderr_limit = .limited(256 * 1024),
        .reserve_amount = 16 * 1024,
    }) catch |err| {
        return .{
            .status = .fail,
            .term = null,
            .stdout = try ctx.gpa.dupe(u8, ""),
            .stderr = try std.fmt.allocPrint(ctx.gpa, "runner error: {s}\n", .{@errorName(err)}),
        };
    };
    errdefer ctx.gpa.free(run_result.stdout);
    errdefer ctx.gpa.free(run_result.stderr);

    return .{
        .status = classifyStatus(run_result.term),
        .term = run_result.term,
        .stdout = run_result.stdout,
        .stderr = run_result.stderr,
    };
}

fn runForkedTest(ctx: *WorkerCtx, test_name: []const u8) !ChildResult {
    var stdout_pipe: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&stdout_pipe) != 0) return error.PipeFailed;
    errdefer {
        _ = std.c.close(stdout_pipe[0]);
        _ = std.c.close(stdout_pipe[1]);
    }

    var stderr_pipe: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&stderr_pipe) != 0) return error.PipeFailed;
    errdefer {
        _ = std.c.close(stderr_pipe[0]);
        _ = std.c.close(stderr_pipe[1]);
    }

    const pid = std.c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        _ = std.c.close(stdout_pipe[0]);
        _ = std.c.close(stderr_pipe[0]);

        if (std.c.dup2(stdout_pipe[1], std.posix.STDOUT_FILENO) < 0) std.c._exit(126);
        if (std.c.dup2(stderr_pipe[1], std.posix.STDERR_FILENO) < 0) std.c._exit(126);

        _ = std.c.close(stdout_pipe[1]);
        _ = std.c.close(stderr_pipe[1]);
        std.c._exit(runSingleTest(test_name, ctx.seed));
    }

    _ = std.c.close(stdout_pipe[1]);
    _ = std.c.close(stderr_pipe[1]);
    errdefer {
        _ = std.c.close(stdout_pipe[0]);
        _ = std.c.close(stderr_pipe[0]);
    }

    const collected = try collectForkOutput(ctx.gpa, stdout_pipe[0], stderr_pipe[0]);
    errdefer {
        ctx.gpa.free(collected.stdout);
        ctx.gpa.free(collected.stderr);
    }

    var status: c_int = 0;
    if (std.c.waitpid(pid, &status, 0) < 0) return error.WaitPidFailed;

    return .{
        .status = classifyStatus(termFromWaitStatus(status)),
        .term = termFromWaitStatus(status),
        .stdout = collected.stdout,
        .stderr = collected.stderr,
    };
}

fn collectForkOutput(gpa: std.mem.Allocator, stdout_fd: std.c.fd_t, stderr_fd: std.c.fd_t) !struct { stdout: []u8, stderr: []u8 } {
    var stdout_list: std.ArrayList(u8) = .empty;
    errdefer stdout_list.deinit(gpa);
    var stderr_list: std.ArrayList(u8) = .empty;
    errdefer stderr_list.deinit(gpa);

    try stdout_list.ensureTotalCapacity(gpa, 256);
    try stderr_list.ensureTotalCapacity(gpa, 256);

    var poll_fds = [_]std.posix.pollfd{
        .{ .fd = stdout_fd, .events = std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR, .revents = 0 },
        .{ .fd = stderr_fd, .events = std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR, .revents = 0 },
    };
    var open_count: usize = 2;
    poll_loop: switch (open_count != 0) {
        true => {
            _ = try std.posix.poll(&poll_fds, -1);
            if (poll_fds[0].fd >= 0 and (poll_fds[0].revents & (std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR)) != 0) {
                if (try drainFdToList(stdout_fd, &stdout_list, gpa)) {
                    _ = std.c.close(stdout_fd);
                    poll_fds[0].fd = -1;
                    open_count -= 1;
                }
            }
            if (poll_fds[1].fd >= 0 and (poll_fds[1].revents & (std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR)) != 0) {
                if (try drainFdToList(stderr_fd, &stderr_list, gpa)) {
                    _ = std.c.close(stderr_fd);
                    poll_fds[1].fd = -1;
                    open_count -= 1;
                }
            }
            continue :poll_loop open_count != 0;
        },
        false => {},
    }

    return .{
        .stdout = try stdout_list.toOwnedSlice(gpa),
        .stderr = try stderr_list.toOwnedSlice(gpa),
    };
}

fn drainFdToList(fd: std.c.fd_t, list: *std.ArrayList(u8), gpa: std.mem.Allocator) !bool {
    var buf: [8192]u8 = undefined;
    const n = try std.posix.read(fd, &buf);
    if (n == 0) return true;
    try list.appendSlice(gpa, buf[0..n]);
    return false;
}

fn termFromWaitStatus(status: c_int) std.process.Child.Term {
    const s: u32 = @bitCast(status);
    if (std.c.W.IFEXITED(s)) return .{ .exited = std.c.W.EXITSTATUS(s) };
    if (std.c.W.IFSIGNALED(s)) return .{ .signal = std.c.W.TERMSIG(s) };
    if (std.c.W.IFSTOPPED(s)) return .{ .stopped = std.c.W.STOPSIG(s) };
    return .{ .unknown = s };
}

fn classifyStatus(term: std.process.Child.Term) Status {
    // The child protocol maps exit code 2 => skip and 3 => leak; signals are crashes.
    switch (term) {
        .exited => |code| return switch (code) {
            0 => .pass,
            2 => .skip,
            3 => .leak,
            else => .fail,
        },
        .signal, .stopped, .unknown => return .crash,
    }
}

fn printTestOutput(name: []const u8, res: ChildResult) void {
    const color = switch (res.status) {
        .pass => "\x1b[32m",
        .skip => "\x1b[94m",
        else => "\x1b[31m",
    };
    const label = switch (res.status) {
        .pass => "ok",
        .skip => "skip",
        .leak => "leak",
        .crash => "crash",
        .fail => "error",
    };

    print("{s}{s}\x1b[0m {s}", .{ color, label, name });

    if (res.term) |term| {
        switch (term) {
            .exited => |code| if (code != 0) print(" | exit {d}", .{code}),
            .signal => |sig| print(" | signal {d} ({s})", .{ @intFromEnum(sig), @tagName(sig) }),
            .stopped => |code| print(" | stopped {d}", .{code}),
            .unknown => |code| print(" | unknown {d}", .{code}),
        }
    } else {
        print(" | no-term", .{});
    }

    print("\n", .{});
    if (res.stderr.len != 0 and res.status != .pass and res.status != .skip) {
        print("stderr:\n{s}", .{res.stderr});
        if (res.stderr[res.stderr.len - 1] != '\n') print("\n", .{});
    }
    if (res.stdout.len != 0 and res.status != .pass and res.status != .skip) {
        print("stdout:\n{s}", .{res.stdout});
        if (res.stdout[res.stdout.len - 1] != '\n') print("\n", .{});
    }
}

fn deinitChildResult(gpa: std.mem.Allocator, res: ChildResult) void {
    gpa.free(res.stdout);
    gpa.free(res.stderr);
}

fn runSingleTest(name: []const u8, seed: ?u32) u8 {
    if (seed) |s| std.testing.random_seed = s;

    const test_fn = findTest(name) orelse {
        print("unknown test: {s}\n", .{name});
        return 1;
    };

    std.testing.allocator_instance = .{};
    const result = test_fn.func();
    const leak_status = std.testing.allocator_instance.deinit();

    if (leak_status == .leak) {
        print("memory leak\n", .{});
        return 3;
    }

    if (result) |_| {
        return 0;
    } else |err| switch (err) {
        error.SkipZigTest => return 2,
        else => {
            print("{s}\n", .{@errorName(err)});
            printErrorReturnTrace();
            return 1;
        },
    }
}

fn printErrorReturnTrace() void {
    const trace = @errorReturnTrace() orelse return;

    var buf: [4096]u8 = undefined;
    const stderr_file = std.Io.File.stderr();
    var stderr_writer = stderr_file.writer(std.Options.debug_io, &buf);
    std.debug.writeStackTrace(trace, .{
        .writer = &stderr_writer.interface,
        .mode = .no_color,
    }) catch {};
    stderr_writer.interface.flush() catch {};
}

const TestFn = std.meta.Elem(@TypeOf(builtin.test_functions));

fn findTest(name: []const u8) ?TestFn {
    for (builtin.test_functions) |t| {
        if (std.mem.eql(u8, t.name, name)) return t;
    }
    return null;
}
