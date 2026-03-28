const std = @import("std");
const proto = @import("protocol.zig");

pub const Clock = struct {
    ctx: ?*anyopaque = null,
    now_ns_fn: *const fn (ctx: ?*anyopaque) u64 = defaultNowNs,

    pub fn nowNs(self: Clock) u64 {
        return self.now_ns_fn(self.ctx);
    }
};

pub const DeadlineController = struct {
    ctx: ?*anyopaque = null,
    set_read_deadline_ns_fn: ?*const fn (ctx: ?*anyopaque, deadline_ns: ?u64) void = null,
    set_write_deadline_ns_fn: ?*const fn (ctx: ?*anyopaque, deadline_ns: ?u64) void = null,
    set_flush_deadline_ns_fn: ?*const fn (ctx: ?*anyopaque, deadline_ns: ?u64) void = null,

    pub fn setReadDeadlineNs(self: DeadlineController, deadline_ns: ?u64) void {
        if (self.set_read_deadline_ns_fn) |f| f(self.ctx, deadline_ns);
    }

    pub fn setWriteDeadlineNs(self: DeadlineController, deadline_ns: ?u64) void {
        if (self.set_write_deadline_ns_fn) |f| f(self.ctx, deadline_ns);
    }

    pub fn setFlushDeadlineNs(self: DeadlineController, deadline_ns: ?u64) void {
        if (self.set_flush_deadline_ns_fn) |f| f(self.ctx, deadline_ns);
    }
};

pub const TimeoutConfig = struct {
    clock: Clock = .{},
    read_ns: ?u64 = null,
    write_ns: ?u64 = null,
    flush_ns: ?u64 = null,
    deadlines: ?DeadlineController = null,
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

pub const Observer = struct {
    ctx: ?*anyopaque = null,
    on_event_fn: *const fn (ctx: ?*anyopaque, event: Event) void,

    pub fn emit(self: Observer, event: Event) void {
        self.on_event_fn(self.ctx, event);
    }
};

fn defaultNowNs(_: ?*anyopaque) u64 {
    if (@hasDecl(std.c, "clock_gettime") and @hasDecl(std.c, "CLOCK")) {
        var ts: std.c.timespec = undefined;
        if (std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts) == 0) {
            return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
        }
    }
    return 0;
}
