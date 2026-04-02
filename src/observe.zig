const std = @import("std");

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
};

fn isHookSelfPointer(comptime Param: type, comptime Hooks: type) bool {
    const info = @typeInfo(Param);
    if (info != .pointer) return false;
    if (info.pointer.size != .one) return false;
    return info.pointer.child == Hooks;
}

// Keep runtime-hook validation fully comptime-driven so disabled deadline
// support disappears from specialized connection types entirely.
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
}

test "validateHooks accepts typed hooks with the required methods" {
    const TestHooks = struct {
        fn nowNs(_: *const @This()) u64 {
            return 1;
        }

        fn setReadDeadlineNs(_: *@This(), _: ?u64) void {}

        fn setWriteDeadlineNs(_: *@This(), _: ?u64) void {}

        fn setFlushDeadlineNs(_: *@This(), _: ?u64) void {}
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
    };
    const BadNowReturn = struct {
        fn nowNs(_: *const @This()) usize {
            return 1;
        }
    };
    const BadDeadlineParam = struct {
        fn setReadDeadlineNs(_: *const @This(), _: u64) void {}
    };

    try std.testing.expect(hasNowNsSignature(GoodConstHooks));
    try std.testing.expect(hasDeadlineSignature(GoodConstHooks, "setReadDeadlineNs"));
    try std.testing.expect(hasDeadlineSignature(GoodConstHooks, "setWriteDeadlineNs"));
    try std.testing.expect(hasDeadlineSignature(GoodConstHooks, "setFlushDeadlineNs"));
    try std.testing.expect(!hasNowNsSignature(BadNowReturn));
    try std.testing.expect(!hasDeadlineSignature(BadDeadlineParam, "setReadDeadlineNs"));
}
