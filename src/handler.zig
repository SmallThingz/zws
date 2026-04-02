const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const conn = @import("conn.zig");
const proto = @import("protocol.zig");
const test_support = @import("test_support.zig");

pub const ReceiveMode = enum {
    solid_slice,
    stream,
};

pub const ExecutionMode = enum {
    sequential,
    async,
};

pub const Options = struct {
    receive_mode: ReceiveMode = .solid_slice,
    execution: ExecutionMode = .sequential,
    auto_flush: bool = true,
    close_on_handler_error: bool = true,
    async_max_inflight: usize = 4,
    message_buffer_len: usize = 64 * 1024,
    stage_buffer_len: usize = 0,
};

pub const Body = union(enum) {
    none,
    bytes: []const u8,
    chunks: []const []const u8,
};

pub const Response = struct {
    opcode: ?conn.MessageOpcode = null,
    body: Body = .none,
};

pub fn Scratch(comptime opts: Options) type {
    comptime validateOptions(opts);
    return switch (opts.execution) {
        .sequential => SequentialScratch(opts),
        .async => AsyncScratch(opts),
    };
}

pub fn SliceContext(comptime ConnType: type, comptime StateType: type) type {
    return struct {
        io: Io,
        state: *StateType,
        message: conn.Message,
        _output: ContextOutput(ConnType),
        _stage_buf: []u8 = &.{},

        const Self = @This();

        pub fn respond(self: *Self, value: anytype) anyerror!void {
            const normalized = normalizeResponse(value);
            switch (self._output) {
                .conn => |c| try writeNormalizedResponse(c, self.message.opcode, normalized, self._stage_buf),
                .async => |a| try a.writeResponse(self.message.opcode, normalized, self._stage_buf),
            }
        }

        pub fn flush(self: *Self) anyerror!void {
            switch (self._output) {
                .conn => |c| try c.flush(),
                .async => |a| try a.flush(),
            }
        }
    };
}

pub fn StreamContext(comptime ConnType: type, comptime StateType: type) type {
    return struct {
        io: Io,
        state: *StateType,
        stream: *StreamReader(ConnType),
        _output: ContextOutput(ConnType),
        _stage_buf: []u8 = &.{},

        const Self = @This();

        pub fn opcode(self: *const Self) conn.MessageOpcode {
            return self.stream.opcode;
        }

        pub fn readChunk(self: *Self, dest: []u8) anyerror![]u8 {
            return self.stream.readChunk(dest);
        }

        pub fn discard(self: *Self) anyerror!void {
            try self.stream.discard();
        }

        pub fn respond(self: *Self, value: anytype) anyerror!void {
            const normalized = normalizeResponse(value);
            switch (self._output) {
                .conn => |c| try writeNormalizedResponse(c, self.stream.opcode, normalized, self._stage_buf),
                .async => |a| try a.writeResponse(self.stream.opcode, normalized, self._stage_buf),
            }
        }

        pub fn flush(self: *Self) anyerror!void {
            switch (self._output) {
                .conn => |c| try c.flush(),
                .async => |a| try a.flush(),
            }
        }
    };
}

pub fn StreamReader(comptime ConnType: type) type {
    return struct {
        conn: *ConnType,
        opcode: conn.MessageOpcode,
        frame_fin: bool,
        done: bool = false,
        control_buf: [125]u8 = undefined,

        const Self = @This();

        pub fn init(c: *ConnType, start: MessageStart) Self {
            return .{
                .conn = c,
                .opcode = start.opcode,
                .frame_fin = start.fin,
            };
        }

        pub fn readChunk(self: *Self, dest: []u8) anyerror![]u8 {
            if (self.done) return dest[0..0];
            if (dest.len == 0) return dest[0..0];

            while (true) {
                const chunk = self.conn.readFrameChunk(dest) catch |err| switch (err) {
                    error.NoActiveFrame => {
                        if (self.frame_fin) {
                            self.done = true;
                            return dest[0..0];
                        }
                        try self.beginNextDataFrame();
                        continue;
                    },
                    else => return err,
                };
                if (chunk.len != 0) return chunk;
            }
        }

        pub fn discard(self: *Self) anyerror!void {
            var scratch: [1024]u8 = undefined;
            while (true) {
                const chunk = try self.readChunk(scratch[0..]);
                if (chunk.len == 0) return;
            }
        }

        fn beginNextDataFrame(self: *Self) anyerror!void {
            while (true) {
                const header = try self.conn.beginFrame();
                if (proto.isControl(header.opcode)) {
                    const payload = try self.conn.readFrameAll(self.control_buf[0..]);
                    if (try handleControlFrame(self.conn, payload, header.opcode)) return error.ConnectionClosed;
                    continue;
                }

                if (header.opcode != .continuation) return error.ExpectedContinuation;
                self.frame_fin = header.fin;
                return;
            }
        }
    };
}

const MessageStart = struct {
    opcode: conn.MessageOpcode,
    fin: bool,
};

pub fn run(
    comptime opts: Options,
    io: Io,
    conn_ptr: anytype,
    state_ptr: anytype,
    scratch: *Scratch(opts),
    comptime handler: anytype,
) anyerror!void {
    comptime validateOptions(opts);
    _ = handlerFnInfo(@TypeOf(handler));

    if (comptime opts.execution == .sequential) {
        return runSequential(opts, io, conn_ptr, state_ptr, scratch, handler);
    }
    return runAsync(opts, io, conn_ptr, state_ptr, scratch, handler);
}

fn runSequential(
    comptime opts: Options,
    io: Io,
    conn_ptr: anytype,
    state_ptr: anytype,
    scratch: *SequentialScratch(opts),
    comptime handler: anytype,
) anyerror!void {
    const ConnType = pointerChildType(@TypeOf(conn_ptr), "conn_ptr");
    const StateType = pointerChildType(@TypeOf(state_ptr), "state_ptr");

    if (comptime opts.receive_mode == .solid_slice) {
        while (true) {
            const message = (conn_ptr.readMessageBorrowed() catch |err| switch (err) {
                error.EndOfStream, error.ConnectionClosed => return,
                else => return err,
            }) orelse (conn_ptr.readMessage(scratch.message_buf[0..]) catch |err| switch (err) {
                error.EndOfStream, error.ConnectionClosed => return,
                else => return err,
            });

            var ctx: SliceContext(ConnType, StateType) = .{
                .io = io,
                .state = state_ptr,
                .message = message,
                ._output = .{ .conn = conn_ptr },
            };
            try processHandlerResult(opts, io, &ctx, handler);
        }
    }

    while (true) {
        const start = beginMessageStream(conn_ptr) catch |err| switch (err) {
            error.EndOfStream, error.ConnectionClosed => return,
            else => return err,
        };
        var stream = StreamReader(ConnType).init(conn_ptr, start);
        var ctx: StreamContext(ConnType, StateType) = .{
            .io = io,
            .state = state_ptr,
            .stream = &stream,
            ._output = .{ .conn = conn_ptr },
        };
        try processHandlerResult(opts, io, &ctx, handler);
        stream.discard() catch |err| switch (err) {
            error.EndOfStream, error.ConnectionClosed => return,
            else => return err,
        };
    }
}

fn runAsync(
    comptime opts: Options,
    io: Io,
    conn_ptr: anytype,
    state_ptr: anytype,
    scratch: *AsyncScratch(opts),
    comptime handler: anytype,
) anyerror!void {
    const ConnType = pointerChildType(@TypeOf(conn_ptr), "conn_ptr");
    const StateType = pointerChildType(@TypeOf(state_ptr), "state_ptr");
    const HooksType = @TypeOf(conn_ptr.hooks);
    const ReadConnType = conn.ConnWithHooks(.{
        .role = ConnType.static_config.role,
        .auto_pong = true,
        .auto_reply_close = true,
        .validate_utf8 = ConnType.static_config.validate_utf8,
        .runtime_hooks = ConnType.static_config.runtime_hooks,
        .supports_permessage_deflate = ConnType.static_config.supports_permessage_deflate,
        .permessage_deflate_context_takeover = ConnType.static_config.permessage_deflate_context_takeover,
        .permessage_deflate_min_payload_len = ConnType.static_config.permessage_deflate_min_payload_len,
        .permessage_deflate_require_compression_gain = ConnType.static_config.permessage_deflate_require_compression_gain,
    }, HooksType);
    const Shared = AsyncShared(ConnType);
    const Slot = AsyncSlot(opts);

    var shared: Shared = .{
        .io = io,
        .conn = conn_ptr,
    };
    var output: AsyncOutput(ConnType) = .{
        .shared = &shared,
    };

    var read_writer_buf: [256]u8 = undefined;
    var read_writer = LockedWriterProxy.init(io, conn_ptr.writer, &shared.write_mutex, read_writer_buf[0..]);
    var read_conn = ReadConnType.initWithHooks(conn_ptr.reader, &read_writer.interface, conn_ptr.config, conn_ptr.hooks);

    const Worker = struct {
        fn main(slots: []Slot, shared_ptr: *Shared, output_ptr: *AsyncOutput(ConnType), state: *StateType) void {
            while (true) {
                const slot_index = shared_ptr.nextReadySlot(slots) orelse return;
                const slot = &slots[slot_index];
                const opcode = slot.opcode;
                const message_len = slot.message_len;

                var ctx: SliceContext(ConnType, StateType) = .{
                    .io = shared_ptr.io,
                    .state = state,
                    .message = .{
                        .opcode = opcode,
                        .payload = slot.message_buf[0..message_len],
                    },
                    ._output = .{ .async = output_ptr },
                    ._stage_buf = slot.stage_buf[0..],
                };

                processHandlerResult(opts, shared_ptr.io, &ctx, handler) catch |err| {
                    _ = shared_ptr.recordError(err);
                };
                shared_ptr.releaseSlot(slot);
            }
        }
    };

    var started_threads: usize = 0;
    errdefer {
        shared.stopAccepting(false);
        for (scratch.workers[0..started_threads]) |thread| {
            if (thread) |worker| worker.join();
        }
    }

    for (&scratch.workers) |*worker| {
        worker.* = try std.Thread.spawn(.{}, Worker.main, .{ scratch.slots[0..], &shared, &output, state_ptr });
        started_threads += 1;
    }
    while (try shared.reserveSlot(scratch.slots[0..])) |slot_index| {
        const slot = &scratch.slots[slot_index];
        read_conn.close_sent = conn_ptr.close_sent;

        const message = read_conn.readMessage(slot.message_buf[0..]) catch |err| switch (err) {
            error.EndOfStream => {
                shared.releaseSlot(slot);
                shared.stopAccepting(false);
                break;
            },
            error.ConnectionClosed => {
                shared.releaseSlot(slot);
                conn_ptr.close_received = conn_ptr.close_received or read_conn.close_received;
                conn_ptr.close_sent = conn_ptr.close_sent or read_conn.close_sent;
                shared.stopAccepting(true);
                break;
            },
            else => {
                shared.releaseSlot(slot);
                _ = shared.recordError(err);
                break;
            },
        };

        slot.opcode = message.opcode;
        slot.message_len = message.payload.len;
        shared.enqueueReadySlot(slot);
    }

    shared.stopAccepting(false);
    for (&scratch.workers) |*worker| {
        if (worker.*) |thread| thread.join();
        worker.* = null;
    }

    if (shared.firstError()) |err| return err;
}

fn beginMessageStream(c: anytype) anyerror!MessageStart {
    const ConnType = pointerChildType(@TypeOf(c), "c");
    var control_buf: [125]u8 = undefined;
    while (true) {
        const header = try c.beginFrame();
        if (proto.isControl(header.opcode)) {
            const payload = try c.readFrameAll(control_buf[0..]);
            if (try handleControlFrame(c, payload, header.opcode)) return error.ConnectionClosed;
            continue;
        }
        const opcode = proto.messageOpcode(header.opcode) orelse return error.UnexpectedContinuation;
        if (comptime ConnType.static_config.supports_permessage_deflate) {
            if (header.compressed) return error.InvalidCompressedMessage;
        }
        return .{
            .opcode = opcode,
            .fin = header.fin,
        };
    }
}

fn handleControlFrame(c: anytype, payload: []const u8, opcode: conn.Opcode) anyerror!bool {
    switch (opcode) {
        .ping => {
            c.writePong(payload) catch |err| switch (err) {
                error.ConnectionClosed => return true,
                else => return err,
            };
            try c.flush();
            return false;
        },
        .pong => return false,
        .close => {
            const parsed = try conn.parseClosePayload(payload, true);
            c.writeClose(parsed.code, parsed.reason) catch |err| switch (err) {
                error.ConnectionClosed => {},
                else => return err,
            };
            c.flush() catch {};
            return true;
        },
        else => unreachable,
    }
}

fn processHandlerResult(comptime opts: Options, io: Io, ctx: anytype, comptime handler: anytype) anyerror!void {
    const fn_info = handlerFnInfo(@TypeOf(handler));
    const ReturnType = fn_info.return_type orelse @compileError("handler must have a return type");
    const raw: ReturnType = callHandler(ReturnType, handler, io, ctx);
    const raw_info = @typeInfo(@TypeOf(raw));
    switch (raw_info) {
        .error_union => {
            const value = raw catch |err| {
                handleHandlerError(opts, ctx, err);
                return err;
            };
            try writeResult(ctx, value);
        },
        else => {
            try writeResult(ctx, raw);
        },
    }
    if (comptime opts.auto_flush) {
        try ctx.flush();
    }
}

fn writeResult(ctx: anytype, value: anytype) anyerror!void {
    const T = @TypeOf(value);
    if (T == void) return;
    try ctx.respond(value);
}

fn handleHandlerError(comptime opts: Options, ctx: anytype, err: anyerror) void {
    switch (ctx._output) {
        .conn => |c| {
            if (comptime !opts.close_on_handler_error) return;
            c.writeClose(1011, "") catch {};
            c.flush() catch {};
        },
        .async => |a| {
            const first = a.shared.recordError(err);
            if (comptime !opts.close_on_handler_error) return;
            if (!first) return;
            a.sendInternalClose(1011, "");
        },
    }
}

fn callHandler(comptime ReturnType: type, comptime handler: anytype, io: Io, ctx: anytype) ReturnType {
    const fn_info = handlerFnInfo(@TypeOf(handler));
    return switch (fn_info.params.len) {
        1 => handler(ctx),
        2 => handler(io, ctx),
        else => @compileError("handler must have signature fn(*Ctx) ... or fn(Io, *Ctx) ..."),
    };
}

fn handlerFnInfo(comptime HandlerType: type) std.builtin.Type.Fn {
    return switch (@typeInfo(HandlerType)) {
        .@"fn" => |fn_info| fn_info,
        else => @compileError("handler must be a comptime function (fn), not a function pointer"),
    };
}

fn writeNormalizedResponse(target: anytype, request_opcode: conn.MessageOpcode, response: Response, stage_buf: []u8) anyerror!void {
    const response_opcode = response.opcode orelse request_opcode;
    switch (response.body) {
        .none => return,
        .bytes => |body| try writeSingleBody(target, response_opcode, body),
        .chunks => |chunks| {
            if (stageChunks(stage_buf, chunks)) |staged| {
                try writeSingleBody(target, response_opcode, staged);
            } else {
                try writeChunkedBody(target, response_opcode, chunks);
            }
        },
    }
}

fn writeSingleBody(target: anytype, opcode: conn.MessageOpcode, body: []const u8) anyerror!void {
    switch (opcode) {
        .text => try target.writeText(body),
        .binary => try target.writeBinary(body),
    }
}

fn writeChunkedBody(target: anytype, opcode: conn.MessageOpcode, chunks: []const []const u8) anyerror!void {
    const first_opcode = switch (opcode) {
        .text => conn.Opcode.text,
        .binary => conn.Opcode.binary,
    };

    if (chunks.len == 0) {
        try target.writeFrame(first_opcode, "", true, false);
        return;
    }

    for (chunks, 0..) |chunk, idx| {
        const fin = idx + 1 == chunks.len;
        if (idx == 0) {
            try target.writeFrame(first_opcode, chunk, fin, false);
        } else {
            try target.writeFrame(.continuation, chunk, fin, false);
        }
    }
}

fn stageChunks(stage_buf: []u8, chunks: []const []const u8) ?[]const u8 {
    if (chunks.len == 0) return "";
    var total: usize = 0;
    for (chunks) |chunk| {
        total = std.math.add(usize, total, chunk.len) catch return null;
        if (total > stage_buf.len) return null;
    }
    var end: usize = 0;
    for (chunks) |chunk| {
        @memcpy(stage_buf[end..][0..chunk.len], chunk);
        end += chunk.len;
    }
    return stage_buf[0..end];
}

fn normalizeResponse(value: anytype) Response {
    const T = @TypeOf(value);
    if (T == Response) return value;
    if (comptime isBytesSlice(T)) {
        return .{ .body = .{ .bytes = value } };
    }
    if (comptime isChunkSlice(T)) {
        const chunks: []const []const u8 = value;
        return .{ .body = .{ .chunks = chunks } };
    }
    if (comptime @typeInfo(T) == .@"struct") {
        if (!@hasField(T, "body")) {
            @compileError("handler response structs must define a `body` field");
        }

        var out: Response = .{
            .body = normalizeBody(@field(value, "body")),
        };
        if (@hasField(T, "opcode")) {
            out.opcode = normalizeOpcode(@field(value, "opcode"));
        }
        return out;
    }
    @compileError("unsupported handler response type; expected []const u8, [][]const u8, Response, or a struct with `body`");
}

fn normalizeBody(value: anytype) Body {
    const T = @TypeOf(value);
    if (T == Body) return value;
    if (T == void) return .none;
    if (comptime isBytesSlice(T)) {
        return .{ .bytes = value };
    }
    if (comptime isChunkSlice(T)) {
        const chunks: []const []const u8 = value;
        return .{ .chunks = chunks };
    }
    @compileError("unsupported `body` type; expected []const u8, [][]const u8, or handler.Body");
}

fn normalizeOpcode(value: anytype) ?conn.MessageOpcode {
    const T = @TypeOf(value);
    if (T == conn.MessageOpcode) return value;
    if (T == ?conn.MessageOpcode) return value;
    @compileError("`opcode` must be conn.MessageOpcode or ?conn.MessageOpcode");
}

fn isBytesSlice(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .pointer) return false;
    if (info.pointer.size != .slice) return false;
    return info.pointer.child == u8;
}

fn isChunkSlice(comptime T: type) bool {
    const outer = @typeInfo(T);
    if (outer != .pointer) return false;
    if (outer.pointer.size != .slice) return false;
    const inner = @typeInfo(outer.pointer.child);
    if (inner != .pointer) return false;
    if (inner.pointer.size != .slice) return false;
    return inner.pointer.child == u8;
}

fn pointerChildType(comptime PointerType: type, comptime label: []const u8) type {
    const info = @typeInfo(PointerType);
    if (info != .pointer or info.pointer.size != .one) {
        @compileError(label ++ " must be a single-item pointer");
    }
    return info.pointer.child;
}

fn validateOptions(comptime opts: Options) void {
    if (opts.receive_mode == .solid_slice and opts.message_buffer_len == 0) {
        @compileError("handler solid-slice mode requires message_buffer_len > 0");
    }
    if (opts.execution == .async) {
        if (builtin.single_threaded) {
            @compileError("handler async mode requires a threaded build");
        }
        if (opts.receive_mode != .solid_slice) {
            @compileError("handler async mode only supports .receive_mode = .solid_slice");
        }
        if (opts.async_max_inflight == 0) {
            @compileError("handler async mode requires async_max_inflight > 0");
        }
    }
}

fn SequentialScratch(comptime opts: Options) type {
    return struct {
        message_buf: [if (opts.receive_mode == .solid_slice) opts.message_buffer_len else 0]u8 = undefined,

        const Self = @This();

        pub fn init() Self {
            return .{};
        }
    };
}

fn AsyncScratch(comptime opts: Options) type {
    return struct {
        slots: [opts.async_max_inflight]AsyncSlot(opts) = undefined,
        workers: [asyncWorkerCount(opts)]?std.Thread = undefined,

        const Self = @This();

        pub fn init() Self {
            var out: Self = undefined;
            inline for (&out.slots) |*slot| slot.* = .{};
            inline for (&out.workers) |*worker| worker.* = null;
            return out;
        }
    };
}

fn AsyncSlot(comptime opts: Options) type {
    const stage_len = effectiveStageBufferLen(opts);
    return struct {
        busy: bool = false,
        queued: bool = false,
        opcode: conn.MessageOpcode = .text,
        message_len: usize = 0,
        message_buf: [opts.message_buffer_len]u8 = undefined,
        stage_buf: [stage_len]u8 = undefined,
    };
}

fn asyncWorkerCount(comptime opts: Options) usize {
    return @min(opts.async_max_inflight, 4);
}

fn effectiveStageBufferLen(comptime opts: Options) usize {
    return if (opts.stage_buffer_len == 0) opts.message_buffer_len else opts.stage_buffer_len;
}

fn ContextOutput(comptime ConnType: type) type {
    return union(enum) {
        conn: *ConnType,
        async: *AsyncOutput(ConnType),
    };
}

fn AsyncShared(comptime ConnType: type) type {
    return struct {
        io: Io,
        conn: *ConnType,
        write_mutex: Io.Mutex = .init,
        mutex: Io.Mutex = .init,
        cond: Io.Condition = .init,
        stopping: bool = false,
        shutdown: std.atomic.Value(bool) = .init(false),
        first_error: ?anyerror = null,

        const Self = @This();

        fn reserveSlot(self: *Self, slots: anytype) Io.Cancelable!?usize {
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);

            while (true) {
                if (self.stopping) return null;
                for (slots, 0..) |*slot, idx| {
                    if (!slot.busy) {
                        slot.busy = true;
                        return idx;
                    }
                }
                try self.cond.wait(self.io, &self.mutex);
            }
        }

        fn releaseSlot(self: *Self, slot: anytype) void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            slot.busy = false;
            slot.queued = false;
            self.cond.broadcast(self.io);
        }

        fn enqueueReadySlot(self: *Self, slot: anytype) void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            slot.queued = true;
            self.cond.signal(self.io);
        }

        fn nextReadySlot(self: *Self, slots: anytype) ?usize {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            while (true) {
                for (slots, 0..) |*slot, idx| {
                    if (slot.busy and slot.queued) {
                        slot.queued = false;
                        return idx;
                    }
                }
                if (self.stopping) return null;
                self.cond.waitUncancelable(self.io, &self.mutex);
            }
        }

        fn stopAccepting(self: *Self, shutdown_writes: bool) void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.stopping = true;
            if (shutdown_writes) self.shutdown.store(true, .release);
            self.cond.broadcast(self.io);
        }

        fn recordError(self: *Self, err: anyerror) bool {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            const first = self.first_error == null;
            if (first) self.first_error = err;
            self.stopping = true;
            self.shutdown.store(true, .release);
            self.cond.broadcast(self.io);
            return first;
        }

        fn firstError(self: *Self) ?anyerror {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            return self.first_error;
        }
    };
}

fn AsyncOutput(comptime ConnType: type) type {
    return struct {
        shared: *AsyncShared(ConnType),

        const Self = @This();

        pub fn writeResponse(self: *Self, request_opcode: conn.MessageOpcode, response: Response, stage_buf: []u8) anyerror!void {
            try self.shared.write_mutex.lock(self.shared.io);
            defer self.shared.write_mutex.unlock(self.shared.io);
            if (self.shared.shutdown.load(.acquire)) return error.ConnectionClosed;
            try writeNormalizedResponse(self.shared.conn, request_opcode, response, stage_buf);
        }

        pub fn flush(self: *Self) anyerror!void {
            try self.shared.write_mutex.lock(self.shared.io);
            defer self.shared.write_mutex.unlock(self.shared.io);
            if (self.shared.shutdown.load(.acquire)) return error.ConnectionClosed;
            try self.shared.conn.flush();
        }

        fn sendInternalClose(self: *Self, code: ?u16, reason: []const u8) void {
            self.shared.write_mutex.lockUncancelable(self.shared.io);
            defer self.shared.write_mutex.unlock(self.shared.io);
            self.shared.conn.writeClose(code, reason) catch {};
            self.shared.conn.flush() catch {};
        }
    };
}

const LockedWriterProxy = struct {
    interface: Io.Writer,
    io: Io,
    target: *Io.Writer,
    mutex: *Io.Mutex,

    fn init(io: Io, target: *Io.Writer, mutex: *Io.Mutex, buffer: []u8) LockedWriterProxy {
        return .{
            .interface = .{
                .vtable = &.{
                    .drain = drain,
                    .flush = flush,
                    .rebase = rebase,
                },
                .buffer = buffer,
            },
            .io = io,
            .target = target,
            .mutex = mutex,
        };
    }

    fn drain(io_w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const self: *LockedWriterProxy = @fieldParentPtr("interface", io_w);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const buffered = io_w.buffered();
        if (buffered.len != 0) {
            try self.target.writeAll(buffered);
            _ = io_w.consumeAll();
        }
        return self.target.writeSplat(data, splat);
    }

    fn flush(io_w: *Io.Writer) Io.Writer.Error!void {
        const self: *LockedWriterProxy = @fieldParentPtr("interface", io_w);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const buffered = io_w.buffered();
        if (buffered.len != 0) {
            try self.target.writeAll(buffered);
            _ = io_w.consumeAll();
        }
        try self.target.flush();
    }

    fn rebase(io_w: *Io.Writer, preserve: usize, capacity: usize) Io.Writer.Error!void {
        _ = capacity;
        if (preserve > io_w.end or preserve > io_w.buffer.len) return error.WriteFailed;
        const start = io_w.end - preserve;
        std.mem.copyForwards(u8, io_w.buffer[0..preserve], io_w.buffer[start..][0..preserve]);
        io_w.end = preserve;
    }
};

test "run solid-slice mode invokes handler and writes byte-slice response" {
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(std.testing.allocator);

    try test_support.appendTestFrame(conn.Opcode, &input, std.testing.allocator, .text, true, true, "ping", .{ 1, 2, 3, 4 });
    try test_support.appendTestFrame(conn.Opcode, &input, std.testing.allocator, .close, true, true, &.{ 0x03, 0xE8 }, .{ 5, 6, 7, 8 });

    var reader = Io.Reader.fixed(input.items);
    var output: [512]u8 = undefined;
    var writer = Io.Writer.fixed(output[0..]);
    var server_conn = conn.Server.init(&reader, &writer, .{});
    const io = std.Io.Threaded.global_single_threaded.io();

    const State = struct {
        calls: usize = 0,
    };
    var state: State = .{};

    const H = struct {
        fn handle(ctx: *SliceContext(conn.Server, State)) []const u8 {
            ctx.state.calls += 1;
            std.testing.expectEqual(conn.MessageOpcode.text, ctx.message.opcode) catch unreachable;
            std.testing.expectEqualStrings("ping", ctx.message.payload) catch unreachable;
            return "pong";
        }
    };

    var scratch = Scratch(.{}).init();
    try run(.{}, io, &server_conn, &state, &scratch, H.handle);
    try std.testing.expectEqual(@as(usize, 1), state.calls);

    var out_reader = Io.Reader.fixed(output[0..writer.end]);
    var sink: [0]u8 = .{};
    var out_writer = Io.Writer.fixed(sink[0..]);
    var client = conn.Client.init(&out_reader, &out_writer, .{});
    var message_buf: [64]u8 = undefined;
    const msg = try client.readMessage(message_buf[0..]);
    try std.testing.expectEqual(conn.MessageOpcode.text, msg.opcode);
    try std.testing.expectEqualStrings("pong", msg.payload);
}

test "run solid-slice mode accepts struct responses with body and opcode" {
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(std.testing.allocator);
    try test_support.appendTestFrame(conn.Opcode, &input, std.testing.allocator, .text, true, true, "x", .{ 1, 2, 3, 4 });
    try test_support.appendTestFrame(conn.Opcode, &input, std.testing.allocator, .close, true, true, &.{ 0x03, 0xE8 }, .{ 9, 10, 11, 12 });

    var reader = Io.Reader.fixed(input.items);
    var output: [512]u8 = undefined;
    var writer = Io.Writer.fixed(output[0..]);
    var server_conn = conn.Server.init(&reader, &writer, .{});
    const io = std.Io.Threaded.global_single_threaded.io();

    const R = struct {
        opcode: conn.MessageOpcode,
        body: []const u8,
    };
    const H = struct {
        fn handle(_: *SliceContext(conn.Server, u8)) R {
            return .{
                .opcode = .binary,
                .body = "abc",
            };
        }
    };
    var state: u8 = 0;
    var scratch = Scratch(.{}).init();
    try run(.{}, io, &server_conn, &state, &scratch, H.handle);

    var out_reader = Io.Reader.fixed(output[0..writer.end]);
    var sink: [0]u8 = .{};
    var out_writer = Io.Writer.fixed(sink[0..]);
    var client = conn.Client.init(&out_reader, &out_writer, .{});
    var message_buf: [64]u8 = undefined;
    const msg = try client.readMessage(message_buf[0..]);
    try std.testing.expectEqual(conn.MessageOpcode.binary, msg.opcode);
    try std.testing.expectEqualStrings("abc", msg.payload);
}

test "run solid-slice mode can use borrowed messages when scratch is smaller than payload" {
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(std.testing.allocator);

    try test_support.appendTestFrame(conn.Opcode, &input, std.testing.allocator, .text, true, true, "ping", .{ 1, 2, 3, 4 });
    try test_support.appendTestFrame(conn.Opcode, &input, std.testing.allocator, .close, true, true, &.{ 0x03, 0xE8 }, .{ 5, 6, 7, 8 });

    var reader = Io.Reader.fixed(input.items);
    var output: [512]u8 = undefined;
    var writer = Io.Writer.fixed(output[0..]);
    var server_conn = conn.Server.init(&reader, &writer, .{});
    const io = std.Io.Threaded.global_single_threaded.io();

    const H = struct {
        fn handle(ctx: *SliceContext(conn.Server, u8)) []const u8 {
            std.testing.expectEqualStrings("ping", ctx.message.payload) catch unreachable;
            return "pong";
        }
    };

    var state: u8 = 0;
    var scratch = Scratch(.{ .message_buffer_len = 1 }).init();
    try run(.{ .message_buffer_len = 1 }, io, &server_conn, &state, &scratch, H.handle);

    var out_reader = Io.Reader.fixed(output[0..writer.end]);
    var sink: [0]u8 = .{};
    var out_writer = Io.Writer.fixed(sink[0..]);
    var client = conn.Client.init(&out_reader, &out_writer, .{});
    var message_buf: [64]u8 = undefined;
    const msg = try client.readMessage(message_buf[0..]);
    try std.testing.expectEqual(conn.MessageOpcode.text, msg.opcode);
    try std.testing.expectEqualStrings("pong", msg.payload);
}

test "run solid-slice mode writes chunked response bodies as fragmented frames" {
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(std.testing.allocator);
    try test_support.appendTestFrame(conn.Opcode, &input, std.testing.allocator, .text, true, true, "y", .{ 1, 2, 3, 4 });
    try test_support.appendTestFrame(conn.Opcode, &input, std.testing.allocator, .close, true, true, &.{ 0x03, 0xE8 }, .{ 13, 14, 15, 16 });

    var reader = Io.Reader.fixed(input.items);
    var output: [512]u8 = undefined;
    var writer = Io.Writer.fixed(output[0..]);
    var server_conn = conn.Server.init(&reader, &writer, .{});
    const io = std.Io.Threaded.global_single_threaded.io();

    const chunks = [_][]const u8{ "a", "bc", "def" };
    const H = struct {
        fn handle(_: *SliceContext(conn.Server, u8)) []const []const u8 {
            return chunks[0..];
        }
    };
    var state: u8 = 0;
    var scratch = Scratch(.{}).init();
    try run(.{}, io, &server_conn, &state, &scratch, H.handle);

    var out_reader = Io.Reader.fixed(output[0..writer.end]);
    var sink: [0]u8 = .{};
    var out_writer = Io.Writer.fixed(sink[0..]);
    var client = conn.Client.init(&out_reader, &out_writer, .{});
    var message_buf: [64]u8 = undefined;
    const msg = try client.readMessage(message_buf[0..]);
    try std.testing.expectEqual(conn.MessageOpcode.text, msg.opcode);
    try std.testing.expectEqualStrings("abcdef", msg.payload);
}

test "run stream mode reads fragmented messages without internal message assembly" {
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(std.testing.allocator);

    try test_support.appendTestFrame(conn.Opcode, &input, std.testing.allocator, .text, false, true, "hel", .{ 1, 2, 3, 4 });
    try test_support.appendTestFrame(conn.Opcode, &input, std.testing.allocator, .ping, true, true, "!", .{ 1, 2, 3, 4 });
    try test_support.appendTestFrame(conn.Opcode, &input, std.testing.allocator, .continuation, true, true, "lo", .{ 5, 6, 7, 8 });
    try test_support.appendTestFrame(conn.Opcode, &input, std.testing.allocator, .close, true, true, &.{ 0x03, 0xE8 }, .{ 9, 10, 11, 12 });

    var reader = Io.Reader.fixed(input.items);
    var output: [1024]u8 = undefined;
    var writer = Io.Writer.fixed(output[0..]);
    var server_conn = conn.Server.init(&reader, &writer, .{});
    const io = std.Io.Threaded.global_single_threaded.io();

    const State = struct {
        buf: [32]u8 = undefined,
        len: usize = 0,
    };
    var state: State = .{};

    const H = struct {
        fn handle(ctx: *StreamContext(conn.Server, State)) ![]const u8 {
            var tmp: [2]u8 = undefined;
            ctx.state.len = 0;
            while (true) {
                const chunk = try ctx.readChunk(tmp[0..]);
                if (chunk.len == 0) break;
                @memcpy(ctx.state.buf[ctx.state.len..][0..chunk.len], chunk);
                ctx.state.len += chunk.len;
            }
            return ctx.state.buf[0..ctx.state.len];
        }
    };

    var scratch = Scratch(.{ .receive_mode = .stream }).init();
    try run(.{ .receive_mode = .stream }, io, &server_conn, &state, &scratch, H.handle);

    var out_reader = Io.Reader.fixed(output[0..writer.end]);
    var sink: [0]u8 = .{};
    var out_writer = Io.Writer.fixed(sink[0..]);
    var client = conn.Client.init(&out_reader, &out_writer, .{});
    var payload: [64]u8 = undefined;

    const pong = try client.readFrame(payload[0..]);
    try std.testing.expectEqual(conn.Opcode.pong, pong.header.opcode);
    try std.testing.expectEqualStrings("!", pong.payload);

    const echoed = try client.readMessage(payload[0..]);
    try std.testing.expectEqual(conn.MessageOpcode.text, echoed.opcode);
    try std.testing.expectEqualStrings("hello", echoed.payload);

    const close = try client.readFrame(payload[0..]);
    try std.testing.expectEqual(conn.Opcode.close, close.header.opcode);
    const close_frame = try conn.parseClosePayload(close.payload, true);
    try std.testing.expectEqual(@as(?u16, 1000), close_frame.code);
}

test "run accepts handlers that take io and return error unions" {
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(std.testing.allocator);
    try test_support.appendTestFrame(conn.Opcode, &input, std.testing.allocator, .text, true, true, "ok", .{ 1, 2, 3, 4 });
    try test_support.appendTestFrame(conn.Opcode, &input, std.testing.allocator, .close, true, true, &.{ 0x03, 0xE8 }, .{ 9, 10, 11, 12 });

    var reader = Io.Reader.fixed(input.items);
    var output: [512]u8 = undefined;
    var writer = Io.Writer.fixed(output[0..]);
    var server_conn = conn.Server.init(&reader, &writer, .{});
    const io = std.Io.Threaded.global_single_threaded.io();

    const H = struct {
        fn handle(io_param: Io, _: *SliceContext(conn.Server, u8)) ![]const u8 {
            _ = io_param;
            return "done";
        }
    };
    var state: u8 = 0;
    var scratch = Scratch(.{}).init();
    try run(.{}, io, &server_conn, &state, &scratch, H.handle);
}

test "run closes with 1011 on handler error by default" {
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(std.testing.allocator);
    try test_support.appendTestFrame(conn.Opcode, &input, std.testing.allocator, .text, true, true, "boom", .{ 1, 2, 3, 4 });

    var reader = Io.Reader.fixed(input.items);
    var output: [256]u8 = undefined;
    var writer = Io.Writer.fixed(output[0..]);
    var server_conn = conn.Server.init(&reader, &writer, .{});
    const io = std.Io.Threaded.global_single_threaded.io();

    const H = struct {
        fn handle(_: *SliceContext(conn.Server, u8)) error{HandlerFailed}!void {
            return error.HandlerFailed;
        }
    };
    var state: u8 = 0;
    var scratch = Scratch(.{}).init();
    try std.testing.expectError(error.HandlerFailed, run(.{}, io, &server_conn, &state, &scratch, H.handle));

    var out_reader = Io.Reader.fixed(output[0..writer.end]);
    var sink: [0]u8 = .{};
    var out_writer = Io.Writer.fixed(sink[0..]);
    var client = conn.Client.init(&out_reader, &out_writer, .{});
    var payload: [16]u8 = undefined;
    const frame = try client.readFrame(payload[0..]);
    try std.testing.expectEqual(conn.Opcode.close, frame.header.opcode);
    const close = try conn.parseClosePayload(frame.payload, true);
    try std.testing.expectEqual(@as(?u16, 1011), close.code);
}

test "run can skip 1011 close on handler error when configured" {
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(std.testing.allocator);
    try test_support.appendTestFrame(conn.Opcode, &input, std.testing.allocator, .text, true, true, "boom", .{ 1, 2, 3, 4 });

    var reader = Io.Reader.fixed(input.items);
    var output: [256]u8 = undefined;
    var writer = Io.Writer.fixed(output[0..]);
    var server_conn = conn.Server.init(&reader, &writer, .{});
    const io = std.Io.Threaded.global_single_threaded.io();

    const H = struct {
        fn handle(_: *SliceContext(conn.Server, u8)) error{HandlerFailed}!void {
            return error.HandlerFailed;
        }
    };
    var state: u8 = 0;
    var scratch = Scratch(.{ .close_on_handler_error = false }).init();
    try std.testing.expectError(error.HandlerFailed, run(.{ .close_on_handler_error = false }, io, &server_conn, &state, &scratch, H.handle));
    try std.testing.expectEqual(@as(usize, 0), writer.end);
}

test "run supports struct responses with empty body" {
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(std.testing.allocator);
    try test_support.appendTestFrame(conn.Opcode, &input, std.testing.allocator, .text, true, true, "noop", .{ 1, 2, 3, 4 });

    var reader = Io.Reader.fixed(input.items);
    var output: [256]u8 = undefined;
    var writer = Io.Writer.fixed(output[0..]);
    var server_conn = conn.Server.init(&reader, &writer, .{});
    const io = std.Io.Threaded.global_single_threaded.io();

    const H = struct {
        fn handle(_: *SliceContext(conn.Server, u8)) struct { body: void } {
            return .{ .body = {} };
        }
    };
    var state: u8 = 0;
    var scratch = Scratch(.{}).init();
    try run(.{}, io, &server_conn, &state, &scratch, H.handle);
    try std.testing.expectEqual(@as(usize, 0), writer.end);
}

test "run stream mode discards unread message tail before continuing" {
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(std.testing.allocator);

    try test_support.appendTestFrame(conn.Opcode, &input, std.testing.allocator, .text, false, true, "hel", .{ 1, 2, 3, 4 });
    try test_support.appendTestFrame(conn.Opcode, &input, std.testing.allocator, .continuation, true, true, "lo", .{ 5, 6, 7, 8 });
    try test_support.appendTestFrame(conn.Opcode, &input, std.testing.allocator, .close, true, true, &.{ 0x03, 0xE8 }, .{ 9, 10, 11, 12 });

    var reader = Io.Reader.fixed(input.items);
    var output: [512]u8 = undefined;
    var writer = Io.Writer.fixed(output[0..]);
    var server_conn = conn.Server.init(&reader, &writer, .{});
    const io = std.Io.Threaded.global_single_threaded.io();

    const H = struct {
        fn handle(ctx: *StreamContext(conn.Server, u8)) ![]const u8 {
            var tmp: [2]u8 = undefined;
            const first = try ctx.readChunk(tmp[0..]);
            try std.testing.expectEqualStrings("he", first);
            return "ok";
        }
    };
    var state: u8 = 0;
    var scratch = Scratch(.{ .receive_mode = .stream }).init();
    try run(.{ .receive_mode = .stream }, io, &server_conn, &state, &scratch, H.handle);

    var out_reader = Io.Reader.fixed(output[0..writer.end]);
    var sink: [0]u8 = .{};
    var out_writer = Io.Writer.fixed(sink[0..]);
    var client = conn.Client.init(&out_reader, &out_writer, .{});
    var payload: [32]u8 = undefined;

    const msg = try client.readMessage(payload[0..]);
    try std.testing.expectEqual(conn.MessageOpcode.text, msg.opcode);
    try std.testing.expectEqualStrings("ok", msg.payload);

    const close = try client.readFrame(payload[0..]);
    try std.testing.expectEqual(conn.Opcode.close, close.header.opcode);
}

test "run stream mode rejects compressed messages" {
    const wire = [_]u8{
        0xC1,
        0x81,
        0x01,
        0x02,
        0x03,
        0x04,
        'x' ^ 0x01,
    };
    var reader = Io.Reader.fixed(wire[0..]);
    var output: [128]u8 = undefined;
    var writer = Io.Writer.fixed(output[0..]);
    var server_conn = conn.Server.init(&reader, &writer, .{
        .permessage_deflate = .{
            .allocator = std.testing.allocator,
            .negotiated = .{},
            .compress_outgoing = false,
        },
    });
    const io = std.Io.Threaded.global_single_threaded.io();

    const H = struct {
        fn handle(_: *StreamContext(conn.Server, u8)) !void {}
    };
    var state: u8 = 0;
    var scratch = Scratch(.{ .receive_mode = .stream }).init();
    try std.testing.expectError(
        error.InvalidCompressedMessage,
        run(.{ .receive_mode = .stream }, io, &server_conn, &state, &scratch, H.handle),
    );
}

test "async mode processes multiple messages concurrently and writes completion-order replies" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(std.testing.allocator);
    try test_support.appendTestFrame(conn.Opcode, &input, std.testing.allocator, .text, true, true, "slow", .{ 1, 2, 3, 4 });
    try test_support.appendTestFrame(conn.Opcode, &input, std.testing.allocator, .text, true, true, "fast", .{ 5, 6, 7, 8 });

    var reader = Io.Reader.fixed(input.items);
    var output: [512]u8 = undefined;
    var writer = Io.Writer.fixed(output[0..]);
    var server_conn = conn.Server.init(&reader, &writer, .{});
    const io = std.testing.io;

    const State = struct {
        mutex: Io.Mutex = .init,
        cond: Io.Condition = .init,
        calls: usize = 0,
        fast_done: bool = false,
    };
    var state: State = .{};

    const H = struct {
        fn handle(ctx: *SliceContext(conn.Server, State)) ![]const u8 {
            ctx.state.mutex.lockUncancelable(ctx.io);
            ctx.state.calls += 1;
            if (std.mem.eql(u8, ctx.message.payload, "slow")) {
                while (!ctx.state.fast_done) {
                    ctx.state.cond.waitUncancelable(ctx.io, &ctx.state.mutex);
                }
                ctx.state.mutex.unlock(ctx.io);
                return "slow-reply";
            }
            ctx.state.fast_done = true;
            ctx.state.cond.signal(ctx.io);
            ctx.state.mutex.unlock(ctx.io);
            return "fast-reply";
        }
    };

    var scratch = Scratch(.{
        .execution = .async,
        .async_max_inflight = 2,
        .message_buffer_len = 64,
        .stage_buffer_len = 64,
    }).init();
    try run(.{
        .execution = .async,
        .async_max_inflight = 2,
        .message_buffer_len = 64,
        .stage_buffer_len = 64,
    }, io, &server_conn, &state, &scratch, H.handle);

    try std.testing.expectEqual(@as(usize, 2), state.calls);

    var out_reader = Io.Reader.fixed(output[0..writer.end]);
    var sink: [0]u8 = .{};
    var out_writer = Io.Writer.fixed(sink[0..]);
    var client = conn.Client.init(&out_reader, &out_writer, .{});
    var message_buf: [64]u8 = undefined;

    const first = try client.readMessage(message_buf[0..]);
    try std.testing.expectEqualStrings("fast-reply", first.payload);
    const second = try client.readMessage(message_buf[0..]);
    try std.testing.expectEqualStrings("slow-reply", second.payload);
}

test "async mode sends one 1011 and returns handler error" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(std.testing.allocator);
    try test_support.appendTestFrame(conn.Opcode, &input, std.testing.allocator, .text, true, true, "boom", .{ 1, 2, 3, 4 });

    var reader = Io.Reader.fixed(input.items);
    var output: [256]u8 = undefined;
    var writer = Io.Writer.fixed(output[0..]);
    var server_conn = conn.Server.init(&reader, &writer, .{});
    const io = std.testing.io;

    const H = struct {
        fn handle(_: *SliceContext(conn.Server, u8)) error{HandlerFailed}!void {
            return error.HandlerFailed;
        }
    };
    var state: u8 = 0;
    var scratch = Scratch(.{
        .execution = .async,
        .async_max_inflight = 1,
        .message_buffer_len = 64,
    }).init();
    try std.testing.expectError(error.HandlerFailed, run(.{
        .execution = .async,
        .async_max_inflight = 1,
        .message_buffer_len = 64,
    }, io, &server_conn, &state, &scratch, H.handle));

    var out_reader = Io.Reader.fixed(output[0..writer.end]);
    var sink: [0]u8 = .{};
    var out_writer = Io.Writer.fixed(sink[0..]);
    var client = conn.Client.init(&out_reader, &out_writer, .{});
    var payload: [16]u8 = undefined;
    const frame = try client.readFrame(payload[0..]);
    try std.testing.expectEqual(conn.Opcode.close, frame.header.opcode);
    const close_frame = try conn.parseClosePayload(frame.payload, true);
    try std.testing.expectEqual(@as(?u16, 1011), close_frame.code);
}
