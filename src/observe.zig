const std = @import("std");
const proto = @import("protocol.zig");

pub const TimeoutConfig = struct {
    read_ns: ?u64 = null,
    write_ns: ?u64 = null,
    flush_ns: ?u64 = null,
};

pub const IoPhase = enum {
    read,
    write,
    flush,
};

pub const FrameEvent = struct {
    opcode: proto.Opcode,
    payload_len: u64,
    fin: bool,
    compressed: bool,
    borrowed: bool = false,
};

pub const MessageEvent = struct {
    opcode: proto.MessageOpcode,
    payload_len: usize,
    compressed: bool,
};

pub const PayloadEvent = struct {
    payload_len: usize,
};

pub const CloseEvent = struct {
    code: ?u16 = null,
    payload_len: usize,
};

pub const TimeoutEvent = struct {
    phase: IoPhase,
    budget_ns: u64,
    elapsed_ns: u64,
};

pub const ErrorEvent = struct {
    name: []const u8,
};

pub const HandshakeAcceptedEvent = struct {
    selected_subprotocol: bool,
    permessage_deflate: bool,
    extra_headers_len: usize,
};

pub const Event = union(enum) {
    frame_read: FrameEvent,
    frame_write: FrameEvent,
    message_read: MessageEvent,
    ping_received: PayloadEvent,
    pong_received: PayloadEvent,
    close_received: CloseEvent,
    close_sent: CloseEvent,
    auto_pong_sent: PayloadEvent,
    timeout: TimeoutEvent,
    protocol_error: ErrorEvent,
    handshake_rejected: ErrorEvent,
    handshake_accepted: HandshakeAcceptedEvent,
};

pub const DefaultRuntimeHooks = struct {
    pub fn nowNs(_: *const @This()) u64 {
        const io = std.Io.Threaded.global_single_threaded.io();
        const ts = std.Io.Timestamp.now(io, .awake);
        if (ts.nanoseconds <= 0) return 0;
        return std.math.cast(u64, ts.nanoseconds) orelse 0;
    }

    pub fn setReadDeadlineNs(_: *@This(), _: ?u64) void {}

    pub fn setWriteDeadlineNs(_: *@This(), _: ?u64) void {}

    pub fn setFlushDeadlineNs(_: *@This(), _: ?u64) void {}

    pub fn onEvent(_: *@This(), _: Event) void {}
};

pub fn validateHooks(comptime Hooks: type) void {
    comptime {
        if (!@hasDecl(Hooks, "nowNs")) {
            @compileError(@typeName(Hooks) ++ " must define nowNs(self) u64");
        }
        if (!@hasDecl(Hooks, "setReadDeadlineNs")) {
            @compileError(@typeName(Hooks) ++ " must define setReadDeadlineNs(self, deadline_ns)");
        }
        if (!@hasDecl(Hooks, "setWriteDeadlineNs")) {
            @compileError(@typeName(Hooks) ++ " must define setWriteDeadlineNs(self, deadline_ns)");
        }
        if (!@hasDecl(Hooks, "setFlushDeadlineNs")) {
            @compileError(@typeName(Hooks) ++ " must define setFlushDeadlineNs(self, deadline_ns)");
        }
        if (!@hasDecl(Hooks, "onEvent")) {
            @compileError(@typeName(Hooks) ++ " must define onEvent(self, event)");
        }
    }
}

test "default runtime hooks are callable" {
    var hooks: DefaultRuntimeHooks = .{};
    const a = hooks.nowNs();
    const b = hooks.nowNs();
    try std.testing.expect(b >= a);
    hooks.setReadDeadlineNs(1);
    hooks.setWriteDeadlineNs(2);
    hooks.setFlushDeadlineNs(null);
    hooks.onEvent(.{ .ping_received = .{ .payload_len = 3 } });
}

test "validateHooks accepts typed hooks with the required methods" {
    const TestHooks = struct {
        fn nowNs(_: *const @This()) u64 {
            return 1;
        }

        fn setReadDeadlineNs(_: *@This(), _: ?u64) void {}

        fn setWriteDeadlineNs(_: *@This(), _: ?u64) void {}

        fn setFlushDeadlineNs(_: *@This(), _: ?u64) void {}

        fn onEvent(_: *@This(), _: Event) void {}
    };

    validateHooks(TestHooks);
}
