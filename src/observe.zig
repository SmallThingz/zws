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

fn isHookSelfPointer(comptime Param: type, comptime Hooks: type) bool {
    const info = @typeInfo(Param);
    if (info != .pointer) return false;
    if (info.pointer.size != .one) return false;
    return info.pointer.child == Hooks;
}

fn hasNowNsSignature(comptime Hooks: type) bool {
    if (!@hasDecl(Hooks, "nowNs")) return false;
    const fn_info = switch (@typeInfo(@TypeOf(Hooks.nowNs))) {
        .@"fn" => |info| info,
        else => return false,
    };
    if (fn_info.params.len != 1) return false;
    const self_type = fn_info.params[0].type orelse return false;
    if (!isHookSelfPointer(self_type, Hooks)) return false;
    return fn_info.return_type == u64;
}

fn hasDeadlineSignature(comptime Hooks: type, comptime name: []const u8) bool {
    if (!@hasDecl(Hooks, name)) return false;
    const fn_info = switch (@typeInfo(@TypeOf(@field(Hooks, name)))) {
        .@"fn" => |info| info,
        else => return false,
    };
    if (fn_info.params.len != 2) return false;
    const self_type = fn_info.params[0].type orelse return false;
    if (!isHookSelfPointer(self_type, Hooks)) return false;
    if (fn_info.params[1].type != ?u64) return false;
    return fn_info.return_type == void;
}

fn hasOnEventSignature(comptime Hooks: type) bool {
    if (!@hasDecl(Hooks, "onEvent")) return false;
    const fn_info = switch (@typeInfo(@TypeOf(Hooks.onEvent))) {
        .@"fn" => |info| info,
        else => return false,
    };
    if (fn_info.params.len != 2) return false;
    const self_type = fn_info.params[0].type orelse return false;
    if (!isHookSelfPointer(self_type, Hooks)) return false;
    if (fn_info.params[1].type != Event) return false;
    return fn_info.return_type == void;
}

pub fn validateHooks(comptime Hooks: type) void {
    comptime {
        if (!hasNowNsSignature(Hooks)) {
            @compileError(@typeName(Hooks) ++ " must define nowNs(self: *Hooks or *const Hooks) u64");
        }
        if (!hasDeadlineSignature(Hooks, "setReadDeadlineNs")) {
            @compileError(@typeName(Hooks) ++ " must define setReadDeadlineNs(self: *Hooks or *const Hooks, deadline_ns: ?u64) void");
        }
        if (!hasDeadlineSignature(Hooks, "setWriteDeadlineNs")) {
            @compileError(@typeName(Hooks) ++ " must define setWriteDeadlineNs(self: *Hooks or *const Hooks, deadline_ns: ?u64) void");
        }
        if (!hasDeadlineSignature(Hooks, "setFlushDeadlineNs")) {
            @compileError(@typeName(Hooks) ++ " must define setFlushDeadlineNs(self: *Hooks or *const Hooks, deadline_ns: ?u64) void");
        }
        if (!hasOnEventSignature(Hooks)) {
            @compileError(@typeName(Hooks) ++ " must define onEvent(self: *Hooks or *const Hooks, event: Event) void");
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

test "hook signature helpers reject wrong runtime hook method shapes" {
    const GoodConstHooks = struct {
        fn nowNs(_: *const @This()) u64 {
            return 1;
        }

        fn setReadDeadlineNs(_: *const @This(), _: ?u64) void {}

        fn setWriteDeadlineNs(_: *const @This(), _: ?u64) void {}

        fn setFlushDeadlineNs(_: *const @This(), _: ?u64) void {}

        fn onEvent(_: *const @This(), _: Event) void {}
    };
    const BadNowReturn = struct {
        fn nowNs(_: *const @This()) usize {
            return 1;
        }
    };
    const BadDeadlineParam = struct {
        fn setReadDeadlineNs(_: *const @This(), _: u64) void {}
    };
    const BadOnEventParam = struct {
        fn onEvent(_: *const @This(), _: FrameEvent) void {}
    };

    try std.testing.expect(hasNowNsSignature(GoodConstHooks));
    try std.testing.expect(hasDeadlineSignature(GoodConstHooks, "setReadDeadlineNs"));
    try std.testing.expect(hasDeadlineSignature(GoodConstHooks, "setWriteDeadlineNs"));
    try std.testing.expect(hasDeadlineSignature(GoodConstHooks, "setFlushDeadlineNs"));
    try std.testing.expect(hasOnEventSignature(GoodConstHooks));
    try std.testing.expect(!hasNowNsSignature(BadNowReturn));
    try std.testing.expect(!hasDeadlineSignature(BadDeadlineParam, "setReadDeadlineNs"));
    try std.testing.expect(!hasOnEventSignature(BadOnEventParam));
}
