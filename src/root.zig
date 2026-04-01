//! Low-allocation RFC 6455 websocket primitives for Zig.
//!
//! The hot-path API is `Conn`, which exposes:
//! - low-level frame streaming (`beginFrame`, `readFrameChunk`, `readFrameAll`, `discardFrame`)
//! - convenience helpers (`readFrame`, `readMessage`, `writeFrame`, `writeText`, `writeBinary`)
//! - strict server upgrade handling (`Handshake.upgrade`)
//!
//! `Conn.Type` exposes the comptime-specialized connection type constructor.
//! `Conn.Default`, `Conn.Server`, and `Conn.Client` are convenient aliases for
//! common configurations. Supporting protocol/extension/observe types live
//! under `Protocol`, `Extensions`, and `Observe`. Message handler helpers live
//! under `Handler`.
const std = @import("std");
const builtin = @import("builtin");

pub const Protocol = @import("protocol.zig");
const handshake = @import("handshake.zig");
pub const Handshake = struct {
    pub const Error = handshake.Error;
    pub const computeAcceptKey = handshake.computeAcceptKey;
    pub const upgrade = handshake.upgrade;
};
pub const Observe = @import("observe.zig");
pub const Extensions = @import("extensions.zig");
pub const Conn = @import("conn.zig");
pub const Handler = @import("handler.zig");

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
    defer if (map_opt) |*map| map.deinit();

    fuzz_abi.fuzzer_init(.fromSlice(cache_dir));

    const test_name = @typeName(@TypeOf(testOne));
    fuzz_abi.fuzzer_set_test(Wrapper.testOneC, .fromSlice(test_name));

    for (fuzz_opts.corpus) |input| {
        fuzz_abi.fuzzer_add_input(.fromSlice(input));
    }
    fuzz_abi.fuzzer_run();
}

test "fuzz falls back to a single empty-smith input when corpus is empty" {
    const State = struct {
        calls: usize = 0,
        saw_empty: bool = false,
    };

    const Harness = struct {
        fn testOne(state: *State, smith: *std.testing.Smith) !void {
            state.calls += 1;
            state.saw_empty = smith.in != null and smith.in.?.len == 0;
        }
    };

    var state: State = .{};
    try fuzz(&state, Harness.testOne, .{ .corpus = &.{} });
    try std.testing.expectEqual(@as(usize, 1), state.calls);
    try std.testing.expect(state.saw_empty);
}

test "fuzz replays every provided corpus input in non-fuzz builds" {
    const State = struct {
        calls: usize = 0,
        total_len: usize = 0,
    };

    const Harness = struct {
        fn testOne(state: *State, smith: *std.testing.Smith) !void {
            state.calls += 1;
            state.total_len += smith.in.?.len;
        }
    };

    var state: State = .{};
    const corpus = [_][]const u8{ "a", "bc", "" };
    try fuzz(&state, Harness.testOne, .{ .corpus = corpus[0..] });
    try std.testing.expectEqual(@as(usize, corpus.len), state.calls);
    try std.testing.expectEqual(@as(usize, 3), state.total_len);
}

test "public type aliases resolve to the specialized core implementations" {
    try std.testing.expectEqualStrings(@typeName(Conn.Conn(.{})), @typeName(Conn.Default));
    try std.testing.expectEqualStrings(@typeName(Conn.Conn(.{ .role = .server })), @typeName(Conn.Server));
    try std.testing.expectEqualStrings(@typeName(Conn.Conn(.{ .role = .client })), @typeName(Conn.Client));
    try std.testing.expectEqualStrings(
        @typeName(Conn.ConnWithHooks(.{}, Observe.DefaultRuntimeHooks)),
        @typeName(Conn.TypeWithHooks(.{}, Observe.DefaultRuntimeHooks)),
    );
    try std.testing.expectEqualStrings(@typeName(Observe.TimeoutConfig), @typeName(Observe.TimeoutConfig));
    try std.testing.expectEqualStrings(@typeName(Observe.IoPhase), @typeName(Observe.IoPhase));
    try std.testing.expectEqualStrings(@typeName(Handler.Response), @typeName(Handler.Response));
}

test {
    _ = @import("observe.zig");
    _ = @import("extensions.zig");
    _ = @import("protocol.zig");
    _ = @import("handshake.zig");
    _ = @import("conn.zig");
    _ = @import("handler.zig");
    _ = @import("flate_backend.zig");
    _ = @import("test_support.zig");
    _ = @import("validation_tests.zig");
}
