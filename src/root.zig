//! Low-allocation RFC 6455 websocket primitives for Zig.
//!
//! The hot-path API is `Conn`, which exposes:
//! - low-level frame streaming (`beginFrame`, `readFrameChunk`, `readFrameAll`, `discardFrame`)
//! - convenience helpers (`readFrame`, `readMessage`, `writeFrame`, `writeText`, `writeBinary`)
//! - strict server handshake validation (`acceptServerHandshake`, `writeServerHandshakeResponse`)
//!
//! `ConnType` exposes the comptime-specialized connection type constructor.
//! `Conn`, `ServerConn`, and `ClientConn` are convenient aliases for common
//! configurations.
const proto = @import("protocol.zig");
const handshake = @import("handshake.zig");
const conn = @import("conn.zig");
const extensions = @import("extensions.zig");
const observe = @import("observe.zig");
const std = @import("std");
const builtin = @import("builtin");

pub const Role = proto.Role;
pub const Opcode = proto.Opcode;
pub const MessageOpcode = proto.MessageOpcode;
pub const CloseCode = proto.CloseCode;
pub const isControl = proto.isControl;
pub const isData = proto.isData;
pub const isValidCloseCode = proto.isValidCloseCode;

pub const Header = handshake.Header;
pub const ServerHandshakeRequest = handshake.ServerHandshakeRequest;
pub const ServerHandshakeOptions = handshake.ServerHandshakeOptions;
pub const ServerHandshakeResponse = handshake.ServerHandshakeResponse;
pub const HandshakeError = handshake.HandshakeError;
pub const Clock = observe.Clock;
pub const DeadlineController = observe.DeadlineController;
pub const TimeoutConfig = observe.TimeoutConfig;
pub const IoPhase = observe.IoPhase;
pub const Observer = observe.Observer;
pub const ObserveEvent = observe.Event;
pub const ObserveFrameEvent = observe.FrameEvent;
pub const ObserveMessageEvent = observe.MessageEvent;
pub const ObservePayloadEvent = observe.PayloadEvent;
pub const ObserveCloseEvent = observe.CloseEvent;
pub const ObserveTimeoutEvent = observe.TimeoutEvent;
pub const ObserveErrorEvent = observe.ErrorEvent;
pub const ObserveHandshakeAcceptedEvent = observe.HandshakeAcceptedEvent;
pub const PerMessageDeflate = extensions.PerMessageDeflate;
pub const offersPerMessageDeflate = extensions.offersPerMessageDeflate;
pub const parsePerMessageDeflate = extensions.parsePerMessageDeflate;
pub const computeAcceptKey = handshake.computeAcceptKey;
pub const acceptServerHandshake = handshake.acceptServerHandshake;
pub const writeServerHandshakeResponse = handshake.writeServerHandshakeResponse;
pub const serverHandshake = handshake.serverHandshake;

pub const StaticConfig = conn.StaticConfig;
pub const Config = conn.Config;
pub const PerMessageDeflateConfig = conn.PerMessageDeflateConfig;
pub const ProtocolError = conn.ProtocolError;
pub const FrameHeader = conn.FrameHeader;
pub const Frame = conn.Frame;
pub const Message = conn.Message;
pub const CloseFrame = conn.CloseFrame;
pub const BorrowedFrame = conn.BorrowedFrame;
pub const EchoResult = conn.EchoResult;
pub const ConnType = conn.Conn;
pub const Conn = conn.Conn(.{});
pub const ServerConn = conn.Conn(.{ .role = .server });
pub const ClientConn = conn.Conn(.{ .role = .client });
pub const parseClosePayload = conn.parseClosePayload;

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

test {
    _ = @import("observe.zig");
    _ = @import("extensions.zig");
    _ = @import("protocol.zig");
    _ = @import("handshake.zig");
    _ = @import("conn.zig");
    _ = @import("zlib_backend.zig");
    _ = @import("validation_tests.zig");
}
