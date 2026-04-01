const std = @import("std");
const Io = std.Io;

const conn = @import("conn.zig");
const proto = @import("protocol.zig");
const test_support = @import("test_support.zig");

pub const ReceiveMode = enum {
    solid_slice,
    stream,
};

pub const Options = struct {
    receive_mode: ReceiveMode = .solid_slice,
    auto_flush: bool = true,
    close_on_handler_error: bool = true,
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

pub fn SliceContext(comptime ConnType: type) type {
    return struct {
        io: Io,
        conn: *ConnType,
        user: *anyopaque,
        message: conn.Message,

        const Self = @This();

        pub fn T(self: *const Self, comptime StateType: type) *StateType {
            return @ptrCast(@alignCast(self.user));
        }

        pub fn respond(self: *Self, value: anytype) anyerror!void {
            const normalized = normalizeResponse(value);
            try writeNormalizedResponse(self.conn, self.message.opcode, normalized);
        }

        pub fn flush(self: *Self) anyerror!void {
            try self.conn.flush();
        }
    };
}

pub fn StreamContext(comptime ConnType: type) type {
    return struct {
        io: Io,
        conn: *ConnType,
        user: *anyopaque,
        stream: *StreamReader(ConnType),

        const Self = @This();

        pub fn T(self: *const Self, comptime StateType: type) *StateType {
            return @ptrCast(@alignCast(self.user));
        }

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
            try writeNormalizedResponse(self.conn, self.stream.opcode, normalized);
        }

        pub fn flush(self: *Self) anyerror!void {
            try self.conn.flush();
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
    user: anytype,
    message_buf: []u8,
    comptime handler: anytype,
) anyerror!void {
    const ConnType = pointerChildType(@TypeOf(conn_ptr), "conn_ptr");
    const user_ptr = asAnyOpaquePtr(user);

    if (comptime opts.receive_mode == .solid_slice) {
        while (true) {
            const message = conn_ptr.readMessage(message_buf) catch |err| switch (err) {
                error.EndOfStream, error.ConnectionClosed => return,
                else => return err,
            };

            var ctx: SliceContext(ConnType) = .{
                .io = io,
                .conn = conn_ptr,
                .user = user_ptr,
                .message = message,
            };
            try processHandlerResult(opts, io, conn_ptr, message.opcode, handler, &ctx);
        }
    }

    while (true) {
        const start = beginMessageStream(conn_ptr) catch |err| switch (err) {
            error.EndOfStream, error.ConnectionClosed => return,
            else => return err,
        };
        var stream = StreamReader(ConnType).init(conn_ptr, start);
        var ctx: StreamContext(ConnType) = .{
            .io = io,
            .conn = conn_ptr,
            .user = user_ptr,
            .stream = &stream,
        };
        try processHandlerResult(opts, io, conn_ptr, start.opcode, handler, &ctx);
        stream.discard() catch |err| switch (err) {
            error.EndOfStream, error.ConnectionClosed => return,
            else => return err,
        };
    }
}

fn beginMessageStream(c: anytype) anyerror!MessageStart {
    var control_buf: [125]u8 = undefined;
    while (true) {
        const header = try c.beginFrame();
        if (proto.isControl(header.opcode)) {
            const payload = try c.readFrameAll(control_buf[0..]);
            if (try handleControlFrame(c, payload, header.opcode)) return error.ConnectionClosed;
            continue;
        }
        const opcode = proto.messageOpcode(header.opcode) orelse return error.UnexpectedContinuation;
        if (header.compressed) return error.InvalidCompressedMessage;
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

fn processHandlerResult(
    comptime opts: Options,
    io: Io,
    conn_ptr: anytype,
    request_opcode: conn.MessageOpcode,
    comptime handler: anytype,
    ctx: anytype,
) anyerror!void {
    const fn_info = handlerFnInfo(@TypeOf(handler));
    const ReturnType = fn_info.return_type orelse @compileError("handler must have a return type");
    const raw: ReturnType = callHandler(ReturnType, handler, io, ctx);
    const raw_info = @typeInfo(@TypeOf(raw));
    switch (raw_info) {
        .error_union => {
            const value = raw catch |err| {
                try handleHandlerError(opts, conn_ptr);
                return err;
            };
            try writeResult(conn_ptr, request_opcode, value);
        },
        else => {
            try writeResult(conn_ptr, request_opcode, raw);
        },
    }
    if (comptime opts.auto_flush) {
        try conn_ptr.flush();
    }
}

fn writeResult(conn_ptr: anytype, request_opcode: conn.MessageOpcode, value: anytype) anyerror!void {
    const T = @TypeOf(value);
    if (T == void) return;
    const normalized = normalizeResponse(value);
    try writeNormalizedResponse(conn_ptr, request_opcode, normalized);
}

fn handleHandlerError(comptime opts: Options, conn_ptr: anytype) anyerror!void {
    if (comptime !opts.close_on_handler_error) return;
    conn_ptr.writeClose(1011, "") catch {};
    conn_ptr.flush() catch {};
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
        .pointer => |ptr_info| switch (@typeInfo(ptr_info.child)) {
            .@"fn" => |fn_info| fn_info,
            else => @compileError("handler must be a function or a pointer to function"),
        },
        else => @compileError("handler must be a function or a pointer to function"),
    };
}

fn writeNormalizedResponse(conn_ptr: anytype, request_opcode: conn.MessageOpcode, response: Response) anyerror!void {
    const response_opcode = response.opcode orelse request_opcode;
    switch (response.body) {
        .none => return,
        .bytes => |body| {
            try writeSingleBody(conn_ptr, response_opcode, body);
        },
        .chunks => |chunks| {
            try writeChunkedBody(conn_ptr, response_opcode, chunks);
        },
    }
}

fn writeSingleBody(conn_ptr: anytype, opcode: conn.MessageOpcode, body: []const u8) anyerror!void {
    switch (opcode) {
        .text => try conn_ptr.writeText(body),
        .binary => try conn_ptr.writeBinary(body),
    }
}

fn writeChunkedBody(conn_ptr: anytype, opcode: conn.MessageOpcode, chunks: []const []const u8) anyerror!void {
    const first_opcode = switch (opcode) {
        .text => conn.Opcode.text,
        .binary => conn.Opcode.binary,
    };

    if (chunks.len == 0) {
        try conn_ptr.writeFrame(first_opcode, "", true);
        return;
    }

    for (chunks, 0..) |chunk, idx| {
        const fin = idx + 1 == chunks.len;
        if (idx == 0) {
            try conn_ptr.writeFrame(first_opcode, chunk, fin);
        } else {
            try conn_ptr.writeFrame(.continuation, chunk, fin);
        }
    }
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

fn asAnyOpaquePtr(ptr: anytype) *anyopaque {
    const PtrType = @TypeOf(ptr);
    const info = @typeInfo(PtrType);
    if (info != .pointer or info.pointer.size != .one) {
        @compileError("user state must be a single-item pointer");
    }
    return @ptrCast(ptr);
}

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
        fn handle(ctx: *SliceContext(conn.Server)) []const u8 {
            const st = ctx.T(State);
            st.calls += 1;
            std.testing.expectEqual(conn.MessageOpcode.text, ctx.message.opcode) catch unreachable;
            std.testing.expectEqualStrings("ping", ctx.message.payload) catch unreachable;
            return "pong";
        }
    };

    try run(.{}, io, &server_conn, &state, output[0..], H.handle);
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
        fn handle(_: *SliceContext(conn.Server)) R {
            return .{
                .opcode = .binary,
                .body = "abc",
            };
        }
    };
    var state: u8 = 0;
    try run(.{}, io, &server_conn, &state, output[0..], H.handle);

    var out_reader = Io.Reader.fixed(output[0..writer.end]);
    var sink: [0]u8 = .{};
    var out_writer = Io.Writer.fixed(sink[0..]);
    var client = conn.Client.init(&out_reader, &out_writer, .{});
    var message_buf: [64]u8 = undefined;
    const msg = try client.readMessage(message_buf[0..]);
    try std.testing.expectEqual(conn.MessageOpcode.binary, msg.opcode);
    try std.testing.expectEqualStrings("abc", msg.payload);
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
        fn handle(_: *SliceContext(conn.Server)) []const []const u8 {
            return chunks[0..];
        }
    };
    var state: u8 = 0;
    try run(.{}, io, &server_conn, &state, output[0..], H.handle);

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
        fn handle(ctx: *StreamContext(conn.Server)) ![]const u8 {
            var tmp: [2]u8 = undefined;
            const st = ctx.T(State);
            st.len = 0;
            while (true) {
                const chunk = try ctx.readChunk(tmp[0..]);
                if (chunk.len == 0) break;
                @memcpy(st.buf[st.len..][0..chunk.len], chunk);
                st.len += chunk.len;
            }
            return st.buf[0..st.len];
        }
    };

    try run(.{ .receive_mode = .stream }, io, &server_conn, &state, &.{}, H.handle);

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
        fn handle(io_param: Io, _: *SliceContext(conn.Server)) ![]const u8 {
            _ = io_param;
            return "done";
        }
    };
    var state: u8 = 0;
    try run(.{}, io, &server_conn, &state, output[0..], H.handle);
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
        fn handle(_: *SliceContext(conn.Server)) error{HandlerFailed}!void {
            return error.HandlerFailed;
        }
    };
    var state: u8 = 0;
    try std.testing.expectError(error.HandlerFailed, run(.{}, io, &server_conn, &state, output[0..], H.handle));

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
        fn handle(_: *SliceContext(conn.Server)) error{HandlerFailed}!void {
            return error.HandlerFailed;
        }
    };
    var state: u8 = 0;
    try std.testing.expectError(error.HandlerFailed, run(.{ .close_on_handler_error = false }, io, &server_conn, &state, output[0..], H.handle));
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
        fn handle(_: *SliceContext(conn.Server)) struct { body: void } {
            return .{ .body = {} };
        }
    };
    var state: u8 = 0;
    try run(.{}, io, &server_conn, &state, output[0..], H.handle);
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
        fn handle(ctx: *StreamContext(conn.Server)) ![]const u8 {
            var tmp: [2]u8 = undefined;
            const first = try ctx.readChunk(tmp[0..]);
            try std.testing.expectEqualStrings("he", first);
            // Return early without consuming the full message; run() must discard tail.
            return "ok";
        }
    };
    var state: u8 = 0;
    try run(.{ .receive_mode = .stream }, io, &server_conn, &state, &.{}, H.handle);

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
        0xC1, // FIN + RSV1 + text opcode
        0x81, // masked + payload len 1
        0x01, 0x02, 0x03, 0x04,
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
        fn handle(_: *StreamContext(conn.Server)) !void {}
    };
    var state: u8 = 0;
    try std.testing.expectError(
        error.InvalidCompressedMessage,
        run(.{ .receive_mode = .stream }, io, &server_conn, &state, &.{}, H.handle),
    );
}
