const builtin = @import("builtin");
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
    if (builtin.os.tag == .linux) {
        var ts: std.os.linux.timespec = undefined;
        if (std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts) == 0) {
            return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
        }
    }
    return 0;
}

test "default clock callback is callable" {
    const clock: Clock = .{};
    _ = clock.nowNs();
}

test "Clock.nowNs uses custom callback and preserves context" {
    const State = struct {
        value: u64,

        fn now(ctx: ?*anyopaque) u64 {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.value += 7;
            return self.value;
        }
    };

    var state: State = .{ .value = 10 };
    const clock: Clock = .{
        .ctx = &state,
        .now_ns_fn = State.now,
    };
    try std.testing.expectEqual(@as(u64, 17), clock.nowNs());
    try std.testing.expectEqual(@as(u64, 24), clock.nowNs());
}

test "DeadlineController invokes only configured callbacks" {
    const State = struct {
        read: ?u64 = null,
        write: ?u64 = null,
        flush: ?u64 = null,

        fn setRead(ctx: ?*anyopaque, deadline_ns: ?u64) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.read = deadline_ns;
        }
        fn setWrite(ctx: ?*anyopaque, deadline_ns: ?u64) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.write = deadline_ns;
        }
        fn setFlush(ctx: ?*anyopaque, deadline_ns: ?u64) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.flush = deadline_ns;
        }
    };

    var state: State = .{};
    const controller: DeadlineController = .{
        .ctx = &state,
        .set_read_deadline_ns_fn = State.setRead,
        .set_flush_deadline_ns_fn = State.setFlush,
    };
    controller.setReadDeadlineNs(123);
    controller.setWriteDeadlineNs(456);
    controller.setFlushDeadlineNs(null);

    try std.testing.expectEqual(@as(?u64, 123), state.read);
    try std.testing.expectEqual(@as(?u64, null), state.write);
    try std.testing.expectEqual(@as(?u64, null), state.flush);

    const controller_all: DeadlineController = .{
        .ctx = &state,
        .set_write_deadline_ns_fn = State.setWrite,
    };
    controller_all.setWriteDeadlineNs(789);
    try std.testing.expectEqual(@as(?u64, 789), state.write);
}

test "Observer.emit forwards event to callback" {
    const State = struct {
        called: bool = false,
        seen: ?Event = null,

        fn onEvent(ctx: ?*anyopaque, event: Event) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.called = true;
            self.seen = event;
        }
    };

    var state: State = .{};
    const observer: Observer = .{
        .ctx = &state,
        .on_event_fn = State.onEvent,
    };
    observer.emit(.{ .ping_received = .{ .payload_len = 9 } });

    try std.testing.expect(state.called);
    switch (state.seen.?) {
        .ping_received => |event| try std.testing.expectEqual(@as(usize, 9), event.payload_len),
        else => return error.TestExpectedEqual,
    }
}
