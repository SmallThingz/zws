const std = @import("std");
const Io = std.Io;

const proto = @import("protocol.zig");
const extensions = @import("extensions.zig");
const observe = @import("observe.zig");
const flate_backend = @import("flate_backend.zig");
const test_support = @import("test_support.zig");

const control_payload_max_len = 125;
const frame_header_max_len = 14;
const mask_len = 4;

pub const Role = proto.Role;
pub const Opcode = proto.Opcode;
pub const MessageOpcode = proto.MessageOpcode;

pub const ProtocolError = error{
    FrameActive,
    NoActiveFrame,
    ReservedBitsSet,
    UnknownOpcode,
    InvalidFrameLength,
    MaskBitInvalid,
    FrameTooLarge,
    MessageTooLarge,
    UnexpectedContinuation,
    ExpectedContinuation,
    ControlFrameFragmented,
    ControlFrameTooLarge,
    InvalidClosePayload,
    InvalidCloseCode,
    InvalidUtf8,
    InvalidCompressedMessage,
    ConnectionClosed,
    Timeout,
    FragmentWriteInProgress,
    UnexpectedContinuationWrite,
    OutOfMemory,
};

pub const StaticConfig = struct {
    role: Role = .server,
    auto_pong: bool = true,
    auto_reply_close: bool = true,
    validate_utf8: bool = true,
    runtime_hooks: bool = true,
};

pub const Config = struct {
    max_frame_payload_len: u64 = std.math.maxInt(u64),
    max_message_payload_len: usize = std.math.maxInt(usize),
    permessage_deflate: ?PerMessageDeflateConfig = null,
    timeouts: observe.TimeoutConfig = .{},
    observer: ?observe.Observer = null,
};

pub const PerMessageDeflateConfig = struct {
    allocator: std.mem.Allocator,
    negotiated: extensions.PerMessageDeflate = .{},
    compression_level: i32 = 1,
};

pub const FrameHeader = struct {
    fin: bool,
    masked: bool,
    compressed: bool = false,
    opcode: Opcode,
    payload_len: u64,
};

pub const Frame = struct {
    header: FrameHeader,
    payload: []u8,
};

pub const Message = struct {
    opcode: MessageOpcode,
    payload: []u8,
};

pub const CloseFrame = struct {
    code: ?u16 = null,
    reason: []const u8 = "",
};

pub const BorrowedFrame = struct {
    /// Borrowed payload backed by the reader buffer until the next peek/fill.
    header: FrameHeader,
    payload: []u8,
};

pub const EchoResult = struct {
    opcode: Opcode,
    payload_len: usize,
};

const ParsedHeader = struct {
    header: FrameHeader,
    header_len: usize,
    mask: [mask_len]u8,
};

/// Creates a websocket connection type specialized for a fixed role and policy
/// set so the hot path can be compiled without runtime configuration branches.
pub fn Conn(comptime static: StaticConfig) type {
    const expects_masked = static.role == .server;
    const auto_pong = static.auto_pong;
    const auto_reply_close = static.auto_reply_close;
    const validate_utf8 = static.validate_utf8;
    const runtime_hooks = static.runtime_hooks;

    return struct {
        reader: *Io.Reader,
        writer: *Io.Writer,
        config: Config,
        mask_prng: std.Random.DefaultPrng,

        recv_active: bool = false,
        recv_header: FrameHeader = undefined,
        recv_remaining: u64 = 0,
        recv_mask: [mask_len]u8 = .{0} ** mask_len,
        recv_mask_offset: usize = 0,
        recv_fragment_opcode: ?MessageOpcode = null,
        recv_fragment_compressed: bool = false,

        send_fragment_opcode: ?MessageOpcode = null,
        close_sent: bool = false,
        close_received: bool = false,

        const Self = @This();
        const masked_write_scratch_len = 4096;
        const TimedOp = struct {
            phase: observe.IoPhase,
            start_ns: u64,
            budget_ns: u64,
        };

        pub fn init(reader: *Io.Reader, writer: *Io.Writer, config: Config) Self {
            const seed = nextMaskSeed() ^
                @as(u64, @truncate(@intFromPtr(reader))) ^
                (@as(u64, @truncate(@intFromPtr(writer))) << 1);
            return .{
                .reader = reader,
                .writer = writer,
                .config = config,
                .mask_prng = std.Random.DefaultPrng.init(seed),
            };
        }

        fn nextMaskSeed() u64 {
            const Seed = struct {
                var value: u64 = 0x9e37_79b9_7f4a_7c15;
            };
            Seed.value +%= 0xbf58_476d_1ce4_e5b9;
            return Seed.value;
        }

        pub fn flush(self: *Self) (ProtocolError || Io.Writer.Error)!void {
            try self.flushTimed();
        }

        fn emit(self: *const Self, event: observe.Event) void {
            if (comptime !runtime_hooks) return;
            if (self.config.observer) |observer| observer.emit(event);
        }

        fn beginTimedOp(self: *const Self, phase: observe.IoPhase) ?TimedOp {
            if (comptime !runtime_hooks) return null;
            const budget_ns = switch (phase) {
                .read => self.config.timeouts.read_ns,
                .write => self.config.timeouts.write_ns,
                .flush => self.config.timeouts.flush_ns,
            } orelse return null;

            const start_ns = self.config.timeouts.clock.nowNs();
            const deadline_ns = std.math.add(u64, start_ns, budget_ns) catch std.math.maxInt(u64);
            if (self.config.timeouts.deadlines) |deadlines| switch (phase) {
                .read => deadlines.setReadDeadlineNs(deadline_ns),
                .write => deadlines.setWriteDeadlineNs(deadline_ns),
                .flush => deadlines.setFlushDeadlineNs(deadline_ns),
            };

            return .{
                .phase = phase,
                .start_ns = start_ns,
                .budget_ns = budget_ns,
            };
        }

        fn clearTimedOp(self: *const Self, phase: observe.IoPhase) void {
            if (comptime !runtime_hooks) return;
            if (self.config.timeouts.deadlines) |deadlines| switch (phase) {
                .read => deadlines.setReadDeadlineNs(null),
                .write => deadlines.setWriteDeadlineNs(null),
                .flush => deadlines.setFlushDeadlineNs(null),
            };
        }

        fn finishTimedOp(self: *const Self, timed: ?TimedOp) ProtocolError!void {
            if (comptime !runtime_hooks) return;
            const op = timed orelse return;
            const elapsed_ns = self.config.timeouts.clock.nowNs() -| op.start_ns;
            if (elapsed_ns > op.budget_ns) {
                self.emit(.{ .timeout = .{
                    .phase = op.phase,
                    .budget_ns = op.budget_ns,
                    .elapsed_ns = elapsed_ns,
                } });
                return error.Timeout;
            }
        }

        fn peekGreedyTimed(self: *Self, n: usize) (ProtocolError || Io.Reader.Error)![]const u8 {
            if (comptime !runtime_hooks) return self.reader.peekGreedy(n);
            const timed = self.beginTimedOp(.read);
            defer self.clearTimedOp(.read);
            const out = try self.reader.peekGreedy(n);
            try self.finishTimedOp(timed);
            return out;
        }

        fn peekTimed(self: *Self, n: usize) (ProtocolError || Io.Reader.Error)![]const u8 {
            if (comptime !runtime_hooks) return self.reader.peek(n);
            const timed = self.beginTimedOp(.read);
            defer self.clearTimedOp(.read);
            const out = try self.reader.peek(n);
            try self.finishTimedOp(timed);
            return out;
        }

        fn readSliceAllTimed(self: *Self, dest: []u8) (ProtocolError || Io.Reader.Error)!void {
            if (comptime !runtime_hooks) return self.reader.readSliceAll(dest);
            const timed = self.beginTimedOp(.read);
            defer self.clearTimedOp(.read);
            try self.reader.readSliceAll(dest);
            try self.finishTimedOp(timed);
        }

        fn writeAllTimed(self: *Self, bytes: []const u8) (ProtocolError || Io.Writer.Error)!void {
            if (comptime !runtime_hooks) return self.writer.writeAll(bytes);
            const timed = self.beginTimedOp(.write);
            defer self.clearTimedOp(.write);
            try self.writer.writeAll(bytes);
            try self.finishTimedOp(timed);
        }

        fn flushTimed(self: *Self) (ProtocolError || Io.Writer.Error)!void {
            if (comptime !runtime_hooks) return self.writer.flush();
            const timed = self.beginTimedOp(.flush);
            defer self.clearTimedOp(.flush);
            try self.writer.flush();
            try self.finishTimedOp(timed);
        }

        fn observeFrameRead(self: *const Self, header: FrameHeader, borrowed: bool) void {
            self.emit(.{ .frame_read = .{
                .opcode = header.opcode,
                .payload_len = header.payload_len,
                .fin = header.fin,
                .compressed = header.compressed,
                .borrowed = borrowed,
            } });
        }

        fn observeFrameWrite(self: *const Self, opcode: Opcode, payload_len: usize, fin: bool, compressed: bool) void {
            self.emit(.{ .frame_write = .{
                .opcode = opcode,
                .payload_len = payload_len,
                .fin = fin,
                .compressed = compressed,
            } });
        }

        fn observeMessageRead(self: *const Self, opcode: MessageOpcode, payload_len: usize, compressed: bool) void {
            self.emit(.{ .message_read = .{
                .opcode = opcode,
                .payload_len = payload_len,
                .compressed = compressed,
            } });
        }

        fn observeControlReceived(self: *const Self, opcode: Opcode, payload: []const u8) void {
            switch (opcode) {
                .ping => self.emit(.{ .ping_received = .{ .payload_len = payload.len } }),
                .pong => self.emit(.{ .pong_received = .{ .payload_len = payload.len } }),
                .close => {
                    const close_frame: CloseFrame = parseClosePayload(payload, validate_utf8) catch .{};
                    self.emit(.{ .close_received = .{
                        .code = close_frame.code,
                        .payload_len = payload.len,
                    } });
                },
                else => {},
            }
        }

        fn observeCloseSent(self: *const Self, code: ?u16, payload_len: usize) void {
            self.emit(.{ .close_sent = .{
                .code = code,
                .payload_len = payload_len,
            } });
        }

        fn observeProtocolError(self: *const Self, err: ProtocolError) void {
            self.emit(.{ .protocol_error = .{ .name = @errorName(err) } });
        }

        pub fn beginFrame(self: *Self) (ProtocolError || Io.Reader.Error)!FrameHeader {
            if (self.recv_active) return error.FrameActive;

            const available = try self.peekGreedyTimed(2);
            const prefix = if (available.len >= 2) available else try self.peekTimed(2);
            const header_need = neededHeaderLen(prefix[1]);
            const header_bytes = if (prefix.len >= header_need) prefix else try self.peekTimed(header_need);
            const parsed = (self.parseHeaderBytes(header_bytes) catch |err| {
                self.observeProtocolError(err);
                return err;
            }).?;

            self.reader.toss(parsed.header_len);
            self.recv_active = true;
            self.recv_header = parsed.header;
            self.recv_remaining = parsed.header.payload_len;
            self.recv_mask = parsed.mask;
            self.recv_mask_offset = 0;
            return self.recv_header;
        }

        pub fn beginFrameBorrowed(self: *Self) (ProtocolError || Io.Reader.Error)!?BorrowedFrame {
            if (self.recv_active) return error.FrameActive;

            const available = try self.peekGreedyTimed(2);
            const prefix = if (available.len >= 2) available else try self.peekTimed(2);
            const header_need = neededHeaderLen(prefix[1]);
            if (header_need > self.reader.buffer.len) return null;

            const header_bytes = if (prefix.len >= header_need) prefix else try self.peekTimed(header_need);
            const parsed = (self.parseHeaderBytes(header_bytes) catch |err| {
                self.observeProtocolError(err);
                return err;
            }).?;
            const payload_len: usize = std.math.cast(usize, parsed.header.payload_len) orelse return null;
            const total_len = std.math.add(usize, parsed.header_len, payload_len) catch return null;
            if (total_len > self.reader.buffer.len) return null;

            const frame_bytes = try self.peekTimed(total_len);
            const payload: []u8 = @constCast(frame_bytes[parsed.header_len..][0..payload_len]);
            if (parsed.header.masked) applyMask(payload, parsed.mask, 0);
            self.reader.toss(total_len);
            self.noteConsumedFrame(parsed.header);
            self.observeFrameRead(parsed.header, true);

            return .{
                .header = parsed.header,
                .payload = payload,
            };
        }

        pub fn readFrameBorrowed(self: *Self) (ProtocolError || Io.Reader.Error)!?BorrowedFrame {
            return self.beginFrameBorrowed();
        }

        pub fn readFrameChunk(self: *Self, dest: []u8) (ProtocolError || Io.Reader.Error)![]u8 {
            if (!self.recv_active) return error.NoActiveFrame;
            if (self.recv_remaining == 0) {
                self.finishActiveFrame();
                return dest[0..0];
            }
            if (dest.len == 0) return dest[0..0];

            const remaining = std.math.cast(usize, self.recv_remaining) orelse std.math.maxInt(usize);
            const n: usize = @min(dest.len, remaining);
            try self.readSliceAllTimed(dest[0..n]);
            if (self.recv_header.masked) applyMask(dest[0..n], self.recv_mask, self.recv_mask_offset);

            self.recv_remaining -= n;
            self.recv_mask_offset += n;

            if (self.recv_remaining == 0) self.finishActiveFrame();
            return dest[0..n];
        }

        pub fn readFrameAll(self: *Self, dest: []u8) (ProtocolError || Io.Reader.Error)![]u8 {
            if (!self.recv_active) return error.NoActiveFrame;
            const remaining = std.math.cast(usize, self.recv_remaining) orelse return error.MessageTooLarge;
            if (remaining > dest.len) return error.MessageTooLarge;
            if (self.recv_remaining == 0) {
                self.finishActiveFrame();
                return dest[0..0];
            }
            return try self.readFrameChunk(dest[0..remaining]);
        }

        pub fn discardFrame(self: *Self) (ProtocolError || Io.Reader.Error)!void {
            if (!self.recv_active) return error.NoActiveFrame;
            var scratch: [512]u8 = undefined;
            while (self.recv_active) {
                _ = try self.readFrameChunk(scratch[0..]);
            }
        }

        pub fn readFrame(self: *Self, buf: []u8) (ProtocolError || Io.Reader.Error)!Frame {
            const header = try self.beginFrame();
            const payload = try self.readFrameAll(buf);
            return .{
                .header = header,
                .payload = payload,
            };
        }

        pub fn readMessage(self: *Self, buf: []u8) (ProtocolError || Io.Reader.Error || Io.Writer.Error)!Message {
            var total_len: usize = 0;
            var message_opcode: ?MessageOpcode = self.recv_fragment_opcode;
            var message_compressed = self.recv_fragment_compressed;
            var compressed_payload: ?std.ArrayList(u8) = null;
            defer if (compressed_payload) |*list| list.deinit(compressionAllocator(self));
            var control_buf: [control_payload_max_len]u8 = undefined;

            while (true) {
                const header = try self.beginFrame();
                if (proto.isControl(header.opcode)) {
                    const payload = try self.readFrameAll(control_buf[0..]);
                    self.observeControlReceived(header.opcode, payload);
                    switch (header.opcode) {
                        .ping => if (comptime auto_pong) {
                            if (!self.close_sent) {
                                try self.writePong(payload);
                                self.emit(.{ .auto_pong_sent = .{ .payload_len = payload.len } });
                            }
                        },
                        .pong => {},
                        .close => {
                            self.close_received = true;
                            self.recv_fragment_opcode = null;
                            self.recv_fragment_compressed = false;
                            const close_frame = try parseClosePayload(payload, validate_utf8);
                            if (comptime auto_reply_close) {
                                if (!self.close_sent) try self.writeClose(close_frame.code, close_frame.reason);
                            }
                            return error.ConnectionClosed;
                        },
                        else => unreachable,
                    }
                    continue;
                }

                if (message_opcode == null) {
                    message_opcode = proto.messageOpcode(header.opcode) orelse unreachable;
                    message_compressed = header.compressed;
                }

                if (message_compressed) {
                    var list = if (compressed_payload) |*existing|
                        existing
                    else blk: {
                        compressed_payload = .empty;
                        break :blk &(compressed_payload.?);
                    };

                    const frame_len = std.math.cast(usize, header.payload_len) orelse {
                        try self.discardFrame();
                        if (try self.discardRemainingMessage()) return error.ConnectionClosed;
                        return error.MessageTooLarge;
                    };
                    const start = list.items.len;
                    list.resize(compressionAllocator(self), start + frame_len) catch return error.OutOfMemory;
                    errdefer list.shrinkRetainingCapacity(start);
                    _ = try self.readFrameAll(list.items[start .. start + frame_len]);

                    if (!header.fin) continue;

                    const inflated = try self.inflateMessage(list.items, buf);
                    const final_opcode = message_opcode.?;
                    if (comptime validate_utf8) {
                        if (final_opcode == .text and !std.unicode.utf8ValidateSlice(inflated)) return error.InvalidUtf8;
                    }
                    self.observeMessageRead(final_opcode, inflated.len, true);
                    return .{
                        .opcode = final_opcode,
                        .payload = inflated,
                    };
                }

                if (header.payload_len > buf.len - total_len) {
                    try self.discardFrame();
                    if (try self.discardRemainingMessage()) return error.ConnectionClosed;
                    return error.MessageTooLarge;
                }
                const chunk = try self.readFrameAll(buf[total_len..]);
                total_len += chunk.len;

                if (total_len > self.config.max_message_payload_len) {
                    if (try self.discardRemainingMessage()) return error.ConnectionClosed;
                    return error.MessageTooLarge;
                }
                if (!header.fin) continue;

                const final_opcode = message_opcode.?;
                if (comptime validate_utf8) {
                    if (final_opcode == .text and !std.unicode.utf8ValidateSlice(buf[0..total_len])) return error.InvalidUtf8;
                }
                self.observeMessageRead(final_opcode, total_len, false);
                return .{
                    .opcode = final_opcode,
                    .payload = buf[0..total_len],
                };
            }
        }

        pub fn echoFrame(self: *Self, scratch: []u8) (ProtocolError || Io.Reader.Error || Io.Writer.Error)!EchoResult {
            if (try self.readFrameBorrowed()) |frame| {
                return try self.echoFramePayload(frame.header, frame.payload);
            }
            const frame = try self.readFrame(scratch);
            return try self.echoFramePayload(frame.header, frame.payload);
        }

        pub fn writeFrame(
            self: *Self,
            opcode: Opcode,
            payload: []const u8,
            fin: bool,
        ) (ProtocolError || Io.Writer.Error)!void {
            try self.writeFrameInternal(opcode, payload, fin, false);
        }

        fn writeFrameInternal(
            self: *Self,
            opcode: Opcode,
            payload: []const u8,
            fin: bool,
            compressed: bool,
        ) (ProtocolError || Io.Writer.Error)!void {
            if (proto.isControl(opcode) and payload.len > control_payload_max_len) return error.ControlFrameTooLarge;
            if (proto.isControl(opcode) and compressed) return error.ReservedBitsSet;
            self.validateOutgoingSequence(opcode, fin) catch |err| {
                self.observeProtocolError(err);
                return err;
            };

            var header_buf: [frame_header_max_len]u8 = undefined;
            var header_len: usize = 0;

            const fin_bit: u8 = if (fin) 0x80 else 0;
            const compressed_bit: u8 = if (compressed) 0x40 else 0;
            header_buf[header_len] = @as(u8, @intFromEnum(opcode)) | fin_bit | compressed_bit;
            header_len += 1;

            if (payload.len <= control_payload_max_len) {
                header_buf[header_len] = @as(u8, @intCast(payload.len));
                if (comptime !expects_masked) header_buf[header_len] |= 0x80;
                header_len += 1;
            } else if (payload.len <= std.math.maxInt(u16)) {
                header_buf[header_len] = 126;
                if (comptime !expects_masked) header_buf[header_len] |= 0x80;
                header_len += 1;
                std.mem.writeInt(u16, header_buf[header_len..][0..2], @as(u16, @intCast(payload.len)), .big);
                header_len += 2;
            } else {
                header_buf[header_len] = 127;
                if (comptime !expects_masked) header_buf[header_len] |= 0x80;
                header_len += 1;
                std.mem.writeInt(u64, header_buf[header_len..][0..8], payload.len, .big);
                header_len += 8;
            }

            if (comptime !expects_masked) {
                var mask: [mask_len]u8 = undefined;
                self.mask_prng.random().bytes(mask[0..]);
                @memcpy(header_buf[header_len..][0..4], mask[0..]);
                header_len += 4;
                try self.writeAllTimed(header_buf[0..header_len]);

                var scratch: [masked_write_scratch_len]u8 = undefined;
                var offset: usize = 0;
                while (offset < payload.len) {
                    const n = @min(masked_write_scratch_len, payload.len - offset);
                    @memcpy(scratch[0..n], payload[offset..][0..n]);
                    applyMask(scratch[0..n], mask, offset);
                    try self.writeAllTimed(scratch[0..n]);
                    offset += n;
                }
                self.observeFrameWrite(opcode, payload.len, fin, compressed);
                return;
            }

            try self.writeAllTimed(header_buf[0..header_len]);
            try self.writeAllTimed(payload);
            self.observeFrameWrite(opcode, payload.len, fin, compressed);
        }

        pub fn writeText(self: *Self, payload: []const u8) (ProtocolError || Io.Writer.Error)!void {
            try validateUtf8IfEnabled(validate_utf8, payload);
            try self.writeMessage(.text, payload);
        }

        pub fn writeBinary(self: *Self, payload: []const u8) (ProtocolError || Io.Writer.Error)!void {
            try self.writeMessage(.binary, payload);
        }

        fn writeMessage(self: *Self, opcode: Opcode, payload: []const u8) (ProtocolError || Io.Writer.Error)!void {
            if (self.config.permessage_deflate == null or payload.len == 0) {
                try self.writeFrameInternal(opcode, payload, true, false);
                return;
            }

            const compressed_payload = try self.deflateMessage(payload);
            defer compressionAllocator(self).free(compressed_payload);
            try self.writeFrameInternal(opcode, compressed_payload, true, true);
        }

        pub fn writePing(self: *Self, payload: []const u8) (ProtocolError || Io.Writer.Error)!void {
            try self.writeControlFrame(.ping, payload);
        }

        pub fn writePong(self: *Self, payload: []const u8) (ProtocolError || Io.Writer.Error)!void {
            try self.writeControlFrame(.pong, payload);
        }

        pub fn writeClose(
            self: *Self,
            code: ?u16,
            reason: []const u8,
        ) (ProtocolError || Io.Writer.Error)!void {
            if (code == null and reason.len != 0) return error.InvalidClosePayload;
            try validateUtf8IfEnabled(validate_utf8, reason);

            var payload: [control_payload_max_len]u8 = undefined;
            var len: usize = 0;
            if (code) |close_code| {
                if (!proto.isValidCloseCode(close_code)) return error.InvalidCloseCode;
                std.mem.writeInt(u16, payload[0..2], close_code, .big);
                len = 2;
            }

            if (len + reason.len > control_payload_max_len) return error.ControlFrameTooLarge;
            @memcpy(payload[len..][0..reason.len], reason);
            len += reason.len;

            try self.writeControlFrame(.close, payload[0..len]);
            self.close_sent = true;
            self.observeCloseSent(code, len);
        }

        fn parseHeaderBytes(self: *Self, bytes: []const u8) ProtocolError!?ParsedHeader {
            if (bytes.len < 2) return null;
            const compressed = (bytes[0] & 0x40) != 0;
            if ((bytes[0] & 0x30) != 0) return error.ReservedBitsSet;
            if (compressed and self.config.permessage_deflate == null) return error.ReservedBitsSet;

            const opcode: Opcode = switch (@as(u4, @truncate(bytes[0]))) {
                0x0 => .continuation,
                0x1 => .text,
                0x2 => .binary,
                0x8 => .close,
                0x9 => .ping,
                0xA => .pong,
                else => return error.UnknownOpcode,
            };
            const fin = (bytes[0] & 0x80) != 0;
            const masked = (bytes[1] & 0x80) != 0;
            if (masked != expects_masked) return error.MaskBitInvalid;

            const header_len = neededHeaderLen(bytes[1]);
            if (bytes.len < header_len) return null;

            var payload_len: u64 = bytes[1] & 0x7f;
            var idx: usize = 2;
            if (payload_len == 126) {
                payload_len = std.mem.readInt(u16, bytes[idx..][0..2], .big);
                if (payload_len < 126) return error.InvalidFrameLength;
                idx += 2;
            } else if (payload_len == 127) {
                if ((bytes[idx] & 0x80) != 0) return error.InvalidFrameLength;
                payload_len = std.mem.readInt(u64, bytes[idx..][0..8], .big);
                if (payload_len <= std.math.maxInt(u16)) return error.InvalidFrameLength;
                idx += 8;
            }

            if (payload_len > self.config.max_frame_payload_len) return error.FrameTooLarge;

            if (proto.isControl(opcode)) {
                if (!fin) return error.ControlFrameFragmented;
                if (compressed) return error.ReservedBitsSet;
                if (payload_len > control_payload_max_len) return error.ControlFrameTooLarge;
            } else switch (opcode) {
                .continuation => {
                    if (compressed) return error.ReservedBitsSet;
                    if (self.recv_fragment_opcode == null) return error.UnexpectedContinuation;
                },
                .text, .binary => {
                    if (self.recv_fragment_opcode != null) return error.ExpectedContinuation;
                },
                else => unreachable,
            }

            var mask: [mask_len]u8 = .{0} ** mask_len;
            if (masked) {
                mask = bytes[idx..][0..mask_len].*;
            }

            return .{
                .header = .{
                    .fin = fin,
                    .masked = masked,
                    .compressed = compressed,
                    .opcode = opcode,
                    .payload_len = payload_len,
                },
                .header_len = header_len,
                .mask = mask,
            };
        }

        fn echoFramePayload(self: *Self, header: FrameHeader, payload: []const u8) (ProtocolError || Io.Writer.Error)!EchoResult {
            if (proto.isControl(header.opcode)) self.observeControlReceived(header.opcode, payload);
            switch (header.opcode) {
                .continuation, .text, .binary => try self.writeFrameInternal(header.opcode, payload, header.fin, header.compressed),
                .ping => if (!self.close_sent) {
                    try self.writeControlFrame(.pong, payload);
                    self.emit(.{ .auto_pong_sent = .{ .payload_len = payload.len } });
                },
                .pong => {},
                .close => {
                    self.close_received = true;
                    self.recv_fragment_opcode = null;
                    self.recv_fragment_compressed = false;
                    const close_frame = try parseClosePayload(payload, validate_utf8);
                    if (!self.close_sent) {
                        try self.writeClose(close_frame.code, close_frame.reason);
                    }
                },
            }
            return .{
                .opcode = header.opcode,
                .payload_len = payload.len,
            };
        }

        fn discardRemainingMessage(self: *Self) (ProtocolError || Io.Reader.Error || Io.Writer.Error)!bool {
            var control_buf: [control_payload_max_len]u8 = undefined;

            while (self.recv_fragment_opcode != null) {
                const header = try self.beginFrame();
                if (!proto.isControl(header.opcode)) {
                    try self.discardFrame();
                    continue;
                }

                const payload = try self.readFrameAll(control_buf[0..]);
                self.observeControlReceived(header.opcode, payload);
                switch (header.opcode) {
                    .ping => if (comptime auto_pong) {
                        if (!self.close_sent) {
                            try self.writePong(payload);
                            self.emit(.{ .auto_pong_sent = .{ .payload_len = payload.len } });
                        }
                    },
                    .pong => {},
                    .close => {
                        self.close_received = true;
                        self.recv_fragment_opcode = null;
                        self.recv_fragment_compressed = false;
                        const close_frame = try parseClosePayload(payload, validate_utf8);
                        if (comptime auto_reply_close) {
                            if (!self.close_sent) try self.writeClose(close_frame.code, close_frame.reason);
                        }
                        return true;
                    },
                    else => unreachable,
                }
            }
            return false;
        }

        fn writeControlFrame(self: *Self, opcode: Opcode, payload: []const u8) (ProtocolError || Io.Writer.Error)!void {
            if (payload.len > control_payload_max_len) return error.ControlFrameTooLarge;
            try self.writeFrame(opcode, payload, true);
        }

        fn inflateMessage(self: *Self, compressed_payload: []const u8, dest: []u8) ProtocolError![]u8 {
            const inflated = flate_backend.inflateMessage(compressionAllocator(self), compressed_payload, dest) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.CounterTooLarge => return error.MessageTooLarge,
                error.MessageTooLarge => return error.MessageTooLarge,
                error.InflateFailed => return error.InvalidCompressedMessage,
            };
            if (inflated.len > self.config.max_message_payload_len) return error.MessageTooLarge;
            return inflated;
        }

        fn deflateMessage(self: *Self, payload: []const u8) ProtocolError![]u8 {
            const pmd = self.config.permessage_deflate.?;
            return flate_backend.deflateMessage(
                pmd.allocator,
                payload,
                pmd.compression_level,
                outgoingFlushMode(static.role, pmd.negotiated),
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.CounterTooLarge => return error.MessageTooLarge,
                error.DeflateFailed => return error.InvalidCompressedMessage,
            };
        }

        fn compressionAllocator(self: *const Self) std.mem.Allocator {
            return self.config.permessage_deflate.?.allocator;
        }

        fn validateOutgoingSequence(self: *Self, opcode: Opcode, fin: bool) ProtocolError!void {
            if (self.close_sent) return error.ConnectionClosed;

            if (proto.isControl(opcode)) {
                if (!fin) return error.ControlFrameFragmented;
                return;
            }

            switch (opcode) {
                .continuation => {
                    if (self.send_fragment_opcode == null) return error.UnexpectedContinuationWrite;
                    if (fin) self.send_fragment_opcode = null;
                },
                .text, .binary => {
                    if (self.send_fragment_opcode != null) return error.FragmentWriteInProgress;
                    if (!fin) self.send_fragment_opcode = proto.messageOpcode(opcode).?;
                },
                else => unreachable,
            }
        }

        fn noteConsumedFrame(self: *Self, header: FrameHeader) void {
            if (!header.fin) {
                if (proto.messageOpcode(header.opcode)) |message_opcode| {
                    self.recv_fragment_opcode = message_opcode;
                    self.recv_fragment_compressed = header.compressed;
                }
                return;
            }
            if (header.opcode == .continuation) {
                self.recv_fragment_opcode = null;
                self.recv_fragment_compressed = false;
            } else if (proto.isData(header.opcode)) {
                self.recv_fragment_compressed = false;
            }
        }

        fn finishActiveFrame(self: *Self) void {
            const header = self.recv_header;
            self.recv_active = false;
            self.recv_remaining = 0;
            self.recv_mask_offset = 0;
            self.noteConsumedFrame(header);
            self.observeFrameRead(header, false);
        }
    };
}

fn validateUtf8IfEnabled(comptime enabled: bool, payload: []const u8) ProtocolError!void {
    if (comptime enabled) {
        if (!std.unicode.utf8ValidateSlice(payload)) return error.InvalidUtf8;
    }
}

fn outgoingFlushMode(comptime role: Role, negotiated: extensions.PerMessageDeflate) i32 {
    const no_context_takeover = switch (role) {
        .server => negotiated.server_no_context_takeover,
        .client => negotiated.client_no_context_takeover,
    };
    return if (no_context_takeover) flate_backend.full_flush else flate_backend.sync_flush;
}

pub fn parseClosePayload(payload: []const u8, validate_utf8: bool) ProtocolError!CloseFrame {
    if (payload.len == 0) {
        return .{};
    }
    if (payload.len == 1) return error.InvalidClosePayload;

    const code = std.mem.readInt(u16, payload[0..2], .big);
    if (!proto.isValidCloseCode(code)) return error.InvalidCloseCode;
    const reason = payload[2..];
    if (validate_utf8 and !std.unicode.utf8ValidateSlice(reason)) return error.InvalidUtf8;

    return .{
        .code = code,
        .reason = reason,
    };
}

fn neededHeaderLen(second: u8) usize {
    const len_code = second & 0x7f;
    return 2 +
        (if (len_code == 126) @as(usize, 2) else if (len_code == 127) @as(usize, 8) else @as(usize, 0)) +
        (if ((second & 0x80) != 0) @as(usize, 4) else @as(usize, 0));
}

fn applyMask(bytes: []u8, mask: [mask_len]u8, start_offset: usize) void {
    if (bytes.len == 0) return;

    const offset = start_offset & 3;
    var i: usize = 0;
    if (bytes.len >= 64) {
        const Vec = @Vector(16, u8);
        var repeated_mask_bytes_vec: [16]u8 = undefined;
        for (0..16) |j| {
            repeated_mask_bytes_vec[j] = mask[(offset + j) & 3];
        }
        const repeated_mask_vec: Vec = repeated_mask_bytes_vec;

        while (i + @sizeOf(Vec) <= bytes.len) : (i += @sizeOf(Vec)) {
            const ptr: *align(1) Vec = @ptrCast(bytes[i..].ptr);
            ptr.* ^= repeated_mask_vec;
        }
    } else {
        var repeated_mask_bytes_u64: [8]u8 = undefined;
        for (0..8) |j| {
            repeated_mask_bytes_u64[j] = mask[(offset + j) & 3];
        }
        const repeated_mask_u64 = std.mem.readInt(u64, repeated_mask_bytes_u64[0..], .little);

        while (i + 8 <= bytes.len) : (i += 8) {
            const value = std.mem.readInt(u64, bytes[i..][0..8], .little);
            std.mem.writeInt(u64, bytes[i..][0..8], value ^ repeated_mask_u64, .little);
        }
    }
    while (i < bytes.len) : (i += 1) {
        bytes[i] ^= mask[(offset + i) & 3];
    }
}

fn appendTestFrame(
    out: *std.ArrayList(u8),
    a: std.mem.Allocator,
    opcode: Opcode,
    fin: bool,
    masked: bool,
    payload: []const u8,
    mask: [mask_len]u8,
) !void {
    try test_support.appendTestFrame(Opcode, out, a, opcode, fin, masked, payload, mask);
}

fn appendMalformedHeader(out: *std.ArrayList(u8), a: std.mem.Allocator, first: u8, second: u8) !void {
    try out.append(a, first);
    try out.append(a, second);
}

test "validateUtf8IfEnabled enforces comptime-enabled validation only" {
    const invalid_utf8 = [_]u8{ 0xC3, 0x28 };
    try validateUtf8IfEnabled(false, invalid_utf8[0..]);
    try std.testing.expectError(error.InvalidUtf8, validateUtf8IfEnabled(true, invalid_utf8[0..]));
}

test "neededHeaderLen covers base extended and masked layouts" {
    try std.testing.expectEqual(@as(usize, 2), neededHeaderLen(0x05));
    try std.testing.expectEqual(@as(usize, 6), neededHeaderLen(0x85));
    try std.testing.expectEqual(@as(usize, 4), neededHeaderLen(126));
    try std.testing.expectEqual(@as(usize, 8), neededHeaderLen(0xFE));
    try std.testing.expectEqual(@as(usize, 10), neededHeaderLen(127));
    try std.testing.expectEqual(@as(usize, 14), neededHeaderLen(0xFF));
}

test "server reads masked text frame" {
    const wire = [_]u8{
        0x81,
        0x82,
        0x37,
        0xfa,
        0x21,
        0x3d,
        0x7f,
        0x93,
    };
    var reader = Io.Reader.fixed(wire[0..]);
    var sink_buf: [1]u8 = undefined;
    var writer = Io.Writer.fixed(sink_buf[0..]);
    var conn = Conn(.{}).init(&reader, &writer, .{});

    var buf: [16]u8 = undefined;
    const frame = try conn.readFrame(buf[0..]);
    try std.testing.expect(frame.header.fin);
    try std.testing.expectEqual(Opcode.text, frame.header.opcode);
    try std.testing.expectEqualStrings("Hi", frame.payload);
}

test "server rejects unmasked client frame" {
    const wire = [_]u8{ 0x81, 0x02, 'O', 'K' };
    var reader = Io.Reader.fixed(wire[0..]);
    var sink_buf: [1]u8 = undefined;
    var writer = Io.Writer.fixed(sink_buf[0..]);
    var conn = Conn(.{}).init(&reader, &writer, .{});

    try std.testing.expectError(error.MaskBitInvalid, conn.beginFrame());
}

test "writeFrame writes unmasked server frame" {
    var out: [64]u8 = undefined;
    var writer = Io.Writer.fixed(out[0..]);
    var reader = Io.Reader.fixed(""[0..]);
    var conn = Conn(.{}).init(&reader, &writer, .{});

    try conn.writeBinary("abc");
    try std.testing.expectEqualSlices(u8, &.{ 0x82, 0x03, 'a', 'b', 'c' }, out[0..writer.end]);
}

test "readMessage reassembles fragments and auto-pongs" {
    const wire = [_]u8{
        0x01, 0x83, 0x11, 0x22, 0x33,       0x44,       'H' ^ 0x11, 'e' ^ 0x22, 'l' ^ 0x33,
        0x89, 0x81, 0xaa, 0xbb, 0xcc,       0xdd,       '!' ^ 0xaa, 0x80,       0x82,
        0x55, 0x66, 0x77, 0x88, 'l' ^ 0x55, 'o' ^ 0x66,
    };

    var reader = Io.Reader.fixed(wire[0..]);
    var out: [64]u8 = undefined;
    var writer = Io.Writer.fixed(out[0..]);
    var conn = Conn(.{}).init(&reader, &writer, .{});

    var msg_buf: [32]u8 = undefined;
    const message = try conn.readMessage(msg_buf[0..]);
    try std.testing.expectEqual(MessageOpcode.text, message.opcode);
    try std.testing.expectEqualStrings("Hello", message.payload);
    try std.testing.expectEqualSlices(u8, &.{ 0x8A, 0x01, '!' }, out[0..writer.end]);
}

test "client writes masked frame" {
    var out: [64]u8 = undefined;
    var writer = Io.Writer.fixed(out[0..]);
    var reader = Io.Reader.fixed(""[0..]);
    var conn = Conn(.{ .role = .client }).init(&reader, &writer, .{});

    try conn.writeText("ok");
    const written = out[0..writer.end];
    try std.testing.expect(written.len == 8);
    try std.testing.expectEqual(@as(u8, 0x81), written[0]);
    try std.testing.expect((written[1] & 0x80) != 0);
    try std.testing.expectEqual(@as(u8, 2), written[1] & 0x7f);

    const mask = written[2..6];
    try std.testing.expectEqual(written[6], 'o' ^ mask[0]);
    try std.testing.expectEqual(written[7], 'k' ^ mask[1]);
}

test "parseClosePayload validates close reason" {
    const payload = [_]u8{ 0x03, 0xE8, 'b', 'y', 'e' };
    const close = try parseClosePayload(payload[0..], true);
    try std.testing.expectEqual(@as(?u16, 1000), close.code);
    try std.testing.expectEqualStrings("bye", close.reason);
}

test "generic writeFrame rejects oversized control payloads" {
    var out: [256]u8 = undefined;
    var writer = Io.Writer.fixed(out[0..]);
    var reader = Io.Reader.fixed(""[0..]);
    var conn = Conn(.{}).init(&reader, &writer, .{});

    var payload: [126]u8 = undefined;
    @memset(payload[0..], 'x');
    try std.testing.expectError(error.ControlFrameTooLarge, conn.writeFrame(.ping, payload[0..], true));
}

test "init produces distinct mask streams for different connections" {
    var out1: [64]u8 = undefined;
    var out2: [64]u8 = undefined;
    var writer1 = Io.Writer.fixed(out1[0..]);
    var writer2 = Io.Writer.fixed(out2[0..]);
    var reader1 = Io.Reader.fixed(""[0..]);
    var reader2 = Io.Reader.fixed(""[0..]);
    var conn1 = Conn(.{ .role = .client }).init(&reader1, &writer1, .{});
    var conn2 = Conn(.{ .role = .client }).init(&reader2, &writer2, .{});

    try conn1.writeBinary("ab");
    try conn2.writeBinary("ab");
    try std.testing.expect(!std.mem.eql(u8, out1[2..6], out2[2..6]));
}

test "flush forwards to writer" {
    var out: [16]u8 = undefined;
    var writer = Io.Writer.fixed(out[0..]);
    var reader = Io.Reader.fixed(""[0..]);
    var conn = Conn(.{}).init(&reader, &writer, .{});
    try conn.flush();
}

test "beginFrame rejects reserved bits and unknown opcode" {
    {
        const wire = [_]u8{ 0xC1, 0x80, 1, 2, 3, 4 };
        var reader = Io.Reader.fixed(wire[0..]);
        var sink: [0]u8 = .{};
        var writer = Io.Writer.fixed(sink[0..]);
        var conn = Conn(.{}).init(&reader, &writer, .{});
        try std.testing.expectError(error.ReservedBitsSet, conn.beginFrame());
    }
    {
        const wire = [_]u8{ 0x83, 0x80, 1, 2, 3, 4 };
        var reader = Io.Reader.fixed(wire[0..]);
        var sink: [0]u8 = .{};
        var writer = Io.Writer.fixed(sink[0..]);
        var conn = Conn(.{}).init(&reader, &writer, .{});
        try std.testing.expectError(error.UnknownOpcode, conn.beginFrame());
    }
}

test "beginFrame rejects invalid extended length and configured frame limit" {
    {
        const wire = [_]u8{
            0x82,
            0xFF,
            0x80,
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
            0x01,
            1,
            2,
            3,
            4,
        };
        var reader = Io.Reader.fixed(wire[0..]);
        var sink: [0]u8 = .{};
        var writer = Io.Writer.fixed(sink[0..]);
        var conn = Conn(.{}).init(&reader, &writer, .{});
        try std.testing.expectError(error.InvalidFrameLength, conn.beginFrame());
    }
    {
        var wire: std.ArrayList(u8) = .empty;
        defer wire.deinit(std.testing.allocator);
        try appendTestFrame(&wire, std.testing.allocator, .binary, true, true, "1234", .{ 1, 2, 3, 4 });
        var reader = Io.Reader.fixed(wire.items);
        var sink: [0]u8 = .{};
        var writer = Io.Writer.fixed(sink[0..]);
        var conn = Conn(.{}).init(&reader, &writer, .{ .max_frame_payload_len = 3 });
        try std.testing.expectError(error.FrameTooLarge, conn.beginFrame());
    }
    {
        const wire = [_]u8{
            0x82,
            0xFE,
            0x00,
            0x7D,
            1,
            2,
            3,
            4,
        };
        var reader = Io.Reader.fixed(wire[0..]);
        var sink: [0]u8 = .{};
        var writer = Io.Writer.fixed(sink[0..]);
        var conn = Conn(.{}).init(&reader, &writer, .{});
        try std.testing.expectError(error.InvalidFrameLength, conn.beginFrame());
    }
    {
        const wire = [_]u8{
            0x82,
            0xFF,
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
            0xFF,
            0xFF,
            1,
            2,
            3,
            4,
        };
        var reader = Io.Reader.fixed(wire[0..]);
        var sink: [0]u8 = .{};
        var writer = Io.Writer.fixed(sink[0..]);
        var conn = Conn(.{}).init(&reader, &writer, .{});
        try std.testing.expectError(error.InvalidFrameLength, conn.beginFrame());
    }
}

test "beginFrame enforces control frame rules and continuation sequencing" {
    {
        var wire: std.ArrayList(u8) = .empty;
        defer wire.deinit(std.testing.allocator);
        try appendTestFrame(&wire, std.testing.allocator, .ping, false, true, "", .{ 1, 2, 3, 4 });
        var reader = Io.Reader.fixed(wire.items);
        var sink: [0]u8 = .{};
        var writer = Io.Writer.fixed(sink[0..]);
        var conn = Conn(.{}).init(&reader, &writer, .{});
        try std.testing.expectError(error.ControlFrameFragmented, conn.beginFrame());
    }
    {
        var payload: [126]u8 = undefined;
        @memset(payload[0..], 'x');
        var wire: std.ArrayList(u8) = .empty;
        defer wire.deinit(std.testing.allocator);
        try appendTestFrame(&wire, std.testing.allocator, .ping, true, true, payload[0..], .{ 1, 2, 3, 4 });
        var reader = Io.Reader.fixed(wire.items);
        var sink: [0]u8 = .{};
        var writer = Io.Writer.fixed(sink[0..]);
        var conn = Conn(.{}).init(&reader, &writer, .{});
        try std.testing.expectError(error.ControlFrameTooLarge, conn.beginFrame());
    }
    {
        var wire: std.ArrayList(u8) = .empty;
        defer wire.deinit(std.testing.allocator);
        try appendTestFrame(&wire, std.testing.allocator, .continuation, true, true, "x", .{ 1, 2, 3, 4 });
        var reader = Io.Reader.fixed(wire.items);
        var sink: [0]u8 = .{};
        var writer = Io.Writer.fixed(sink[0..]);
        var conn = Conn(.{}).init(&reader, &writer, .{});
        try std.testing.expectError(error.UnexpectedContinuation, conn.beginFrame());
    }
    {
        var wire: std.ArrayList(u8) = .empty;
        defer wire.deinit(std.testing.allocator);
        try appendTestFrame(&wire, std.testing.allocator, .text, false, true, "hel", .{ 1, 2, 3, 4 });
        try appendTestFrame(&wire, std.testing.allocator, .binary, true, true, "bad", .{ 5, 6, 7, 8 });
        var reader = Io.Reader.fixed(wire.items);
        var sink: [0]u8 = .{};
        var writer = Io.Writer.fixed(sink[0..]);
        var conn = Conn(.{}).init(&reader, &writer, .{});
        _ = try conn.beginFrame();
        try conn.discardFrame();
        try std.testing.expectError(error.ExpectedContinuation, conn.beginFrame());
    }
}

test "beginFrame supports client role and extended lengths" {
    {
        const wire = [_]u8{ 0x82, 0x02, 'o', 'k' };
        var reader = Io.Reader.fixed(wire[0..]);
        var sink: [0]u8 = .{};
        var writer = Io.Writer.fixed(sink[0..]);
        var conn = Conn(.{ .role = .client }).init(&reader, &writer, .{});
        const header = try conn.beginFrame();
        try std.testing.expectEqual(@as(u64, 2), header.payload_len);
        try std.testing.expect(!header.masked);
    }
    {
        var wire: std.ArrayList(u8) = .empty;
        defer wire.deinit(std.testing.allocator);
        var payload: [126]u8 = undefined;
        @memset(payload[0..], 'x');
        try appendTestFrame(&wire, std.testing.allocator, .binary, true, false, payload[0..], .{ 0, 0, 0, 0 });
        var reader = Io.Reader.fixed(wire.items);
        var sink: [0]u8 = .{};
        var writer = Io.Writer.fixed(sink[0..]);
        var conn = Conn(.{ .role = .client }).init(&reader, &writer, .{});
        const header = try conn.beginFrame();
        try std.testing.expectEqual(@as(u64, 126), header.payload_len);
        try conn.discardFrame();
    }
    {
        const wire = [_]u8{
            0x82,
            0x7F,
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
            0x01,
            0x00,
            0x00,
        };
        var reader = Io.Reader.fixed(wire[0..]);
        var sink: [0]u8 = .{};
        var writer = Io.Writer.fixed(sink[0..]);
        var conn = Conn(.{ .role = .client }).init(&reader, &writer, .{});
        const header = try conn.beginFrame();
        try std.testing.expectEqual(@as(u64, 65536), header.payload_len);
    }
}

test "readFrameChunk and readFrameAll enforce active frame semantics" {
    var reader = Io.Reader.fixed(""[0..]);
    var sink: [0]u8 = .{};
    var writer = Io.Writer.fixed(sink[0..]);
    var conn = Conn(.{}).init(&reader, &writer, .{});
    var tmp: [4]u8 = undefined;

    try std.testing.expectError(error.NoActiveFrame, conn.readFrameChunk(tmp[0..]));
    try std.testing.expectError(error.NoActiveFrame, conn.readFrameAll(tmp[0..]));
    try std.testing.expectError(error.NoActiveFrame, conn.discardFrame());
}

test "readFrameChunk handles recv_remaining values larger than usize" {
    var reader = Io.Reader.fixed("ab"[0..]);
    var sink: [0]u8 = .{};
    var writer = Io.Writer.fixed(sink[0..]);
    var conn = Conn(.{}).init(&reader, &writer, .{});
    conn.recv_active = true;
    conn.recv_header = .{
        .fin = true,
        .masked = false,
        .opcode = .binary,
        .payload_len = std.math.maxInt(u64),
    };
    conn.recv_remaining = std.math.maxInt(u64);

    var buf: [2]u8 = undefined;
    const chunk = try conn.readFrameChunk(buf[0..]);
    try std.testing.expectEqualStrings("ab", chunk);
    try std.testing.expectEqual(std.math.maxInt(u64) - 2, conn.recv_remaining);
    try std.testing.expect(conn.recv_active);
}

test "beginFrameBorrowed returns FrameActive while a streamed frame is active" {
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(std.testing.allocator);
    try appendTestFrame(&wire, std.testing.allocator, .binary, true, true, "abc", .{ 1, 2, 3, 4 });

    var reader = Io.Reader.fixed(wire.items);
    var sink: [0]u8 = .{};
    var writer = Io.Writer.fixed(sink[0..]);
    var conn = Conn(.{}).init(&reader, &writer, .{});

    _ = try conn.beginFrame();
    try std.testing.expectError(error.FrameActive, conn.beginFrameBorrowed());
}

test "readFrameBorrowed returns null when the buffered reader cannot hold the frame" {
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(std.testing.allocator);
    try appendTestFrame(&wire, std.testing.allocator, .binary, true, true, "abc", .{ 1, 2, 3, 4 });

    var base_reader = Io.Reader.fixed(wire.items);
    var indirect_buffer: [6]u8 = undefined;
    var indirect = std.testing.ReaderIndirect.init(&base_reader, indirect_buffer[0..]);

    var sink: [0]u8 = .{};
    var writer = Io.Writer.fixed(sink[0..]);
    var conn = Conn(.{}).init(&indirect.interface, &writer, .{});

    try std.testing.expect((try conn.readFrameBorrowed()) == null);
}

test "readFrameChunk zero length does not consume payload and discardFrame drains current frame" {
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(std.testing.allocator);
    try appendTestFrame(&wire, std.testing.allocator, .binary, true, true, "abc", .{ 1, 2, 3, 4 });
    try appendTestFrame(&wire, std.testing.allocator, .text, true, true, "z", .{ 5, 6, 7, 8 });

    var reader = Io.Reader.fixed(wire.items);
    var sink: [0]u8 = .{};
    var writer = Io.Writer.fixed(sink[0..]);
    var conn = Conn(.{}).init(&reader, &writer, .{});

    _ = try conn.beginFrame();
    var empty: [0]u8 = .{};
    try std.testing.expectEqual(@as(usize, 0), (try conn.readFrameChunk(empty[0..])).len);

    var buf: [3]u8 = undefined;
    try std.testing.expectEqualStrings("abc", try conn.readFrameAll(buf[0..]));

    const next = try conn.readFrame(buf[0..]);
    try std.testing.expectEqual(Opcode.text, next.header.opcode);
    try std.testing.expectEqualStrings("z", next.payload);
}

test "readFrameChunk unmasks correctly across multiple chunk reads" {
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(std.testing.allocator);
    try appendTestFrame(&wire, std.testing.allocator, .binary, true, true, "hello", .{ 1, 2, 3, 4 });

    var reader = Io.Reader.fixed(wire.items);
    var sink: [0]u8 = .{};
    var writer = Io.Writer.fixed(sink[0..]);
    var conn = Conn(.{}).init(&reader, &writer, .{});

    _ = try conn.beginFrame();
    var first: [2]u8 = undefined;
    var second: [3]u8 = undefined;
    try std.testing.expectEqualStrings("he", try conn.readFrameChunk(first[0..]));
    try std.testing.expect(conn.recv_active);
    try std.testing.expectEqualStrings("llo", try conn.readFrameChunk(second[0..]));
    try std.testing.expect(!conn.recv_active);
}

test "readFrameAll rejects destination that is too small and zero payload frames work" {
    {
        var wire: std.ArrayList(u8) = .empty;
        defer wire.deinit(std.testing.allocator);
        try appendTestFrame(&wire, std.testing.allocator, .binary, true, true, "abcd", .{ 1, 2, 3, 4 });
        var reader = Io.Reader.fixed(wire.items);
        var sink: [0]u8 = .{};
        var writer = Io.Writer.fixed(sink[0..]);
        var conn = Conn(.{}).init(&reader, &writer, .{});
        _ = try conn.beginFrame();
        var buf: [3]u8 = undefined;
        try std.testing.expectError(error.MessageTooLarge, conn.readFrameAll(buf[0..]));
    }
    {
        var wire: std.ArrayList(u8) = .empty;
        defer wire.deinit(std.testing.allocator);
        try appendTestFrame(&wire, std.testing.allocator, .pong, true, true, "", .{ 1, 2, 3, 4 });
        var reader = Io.Reader.fixed(wire.items);
        var sink: [0]u8 = .{};
        var writer = Io.Writer.fixed(sink[0..]);
        var conn = Conn(.{}).init(&reader, &writer, .{});
        var buf: [1]u8 = undefined;
        const frame = try conn.readFrame(buf[0..]);
        try std.testing.expectEqual(@as(u64, 0), frame.header.payload_len);
        try std.testing.expectEqual(@as(usize, 0), frame.payload.len);
    }
}

test "readMessage handles pong close and configured auto reply behavior" {
    {
        var wire: std.ArrayList(u8) = .empty;
        defer wire.deinit(std.testing.allocator);
        try appendTestFrame(&wire, std.testing.allocator, .pong, true, true, "!", .{ 1, 2, 3, 4 });
        try appendTestFrame(&wire, std.testing.allocator, .binary, true, true, "ok", .{ 5, 6, 7, 8 });
        var reader = Io.Reader.fixed(wire.items);
        var out: [16]u8 = undefined;
        var writer = Io.Writer.fixed(out[0..]);
        var conn = Conn(.{ .auto_pong = false }).init(&reader, &writer, .{});
        var buf: [8]u8 = undefined;
        const msg = try conn.readMessage(buf[0..]);
        try std.testing.expectEqual(MessageOpcode.binary, msg.opcode);
        try std.testing.expectEqualStrings("ok", msg.payload);
        try std.testing.expectEqual(@as(usize, 0), writer.end);
    }
    {
        var wire: std.ArrayList(u8) = .empty;
        defer wire.deinit(std.testing.allocator);
        const close_payload = [_]u8{ 0x03, 0xE8, 'b', 'y', 'e' };
        try appendTestFrame(&wire, std.testing.allocator, .close, true, true, close_payload[0..], .{ 1, 2, 3, 4 });
        var reader = Io.Reader.fixed(wire.items);
        var out: [32]u8 = undefined;
        var writer = Io.Writer.fixed(out[0..]);
        var conn = Conn(.{}).init(&reader, &writer, .{});
        var buf: [8]u8 = undefined;
        try std.testing.expectError(error.ConnectionClosed, conn.readMessage(buf[0..]));
        try std.testing.expect(conn.close_received);
        try std.testing.expect(conn.close_sent);
        try std.testing.expectEqualSlices(u8, &.{ 0x88, 0x05, 0x03, 0xE8, 'b', 'y', 'e' }, out[0..writer.end]);
    }
    {
        var wire: std.ArrayList(u8) = .empty;
        defer wire.deinit(std.testing.allocator);
        try appendTestFrame(&wire, std.testing.allocator, .close, true, true, "", .{ 1, 2, 3, 4 });
        var reader = Io.Reader.fixed(wire.items);
        var out: [8]u8 = undefined;
        var writer = Io.Writer.fixed(out[0..]);
        var conn = Conn(.{ .auto_reply_close = false }).init(&reader, &writer, .{});
        var buf: [1]u8 = undefined;
        try std.testing.expectError(error.ConnectionClosed, conn.readMessage(buf[0..]));
        try std.testing.expect(conn.close_received);
        try std.testing.expect(!conn.close_sent);
        try std.testing.expectEqual(@as(usize, 0), writer.end);
    }
}

test "readMessage clears fragmented receive state when a close interrupts a message" {
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(std.testing.allocator);
    try appendTestFrame(&wire, std.testing.allocator, .text, false, true, "abc", .{ 1, 2, 3, 4 });
    try appendTestFrame(&wire, std.testing.allocator, .close, true, true, "", .{ 5, 6, 7, 8 });

    var reader = Io.Reader.fixed(wire.items);
    var out: [8]u8 = undefined;
    var writer = Io.Writer.fixed(out[0..]);
    var conn = Conn(.{}).init(&reader, &writer, .{});
    var buf: [8]u8 = undefined;

    try std.testing.expectError(error.ConnectionClosed, conn.readMessage(buf[0..]));
    try std.testing.expect(conn.close_received);
    try std.testing.expect(conn.recv_fragment_opcode == null);
    try std.testing.expectEqualSlices(u8, &.{ 0x88, 0x00 }, out[0..writer.end]);
}

test "readMessage ignores ping frames after a local close has already been sent" {
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(std.testing.allocator);
    try appendTestFrame(&wire, std.testing.allocator, .ping, true, true, "!", .{ 1, 2, 3, 4 });
    try appendTestFrame(&wire, std.testing.allocator, .close, true, true, "", .{ 5, 6, 7, 8 });

    var reader = Io.Reader.fixed(wire.items);
    var out: [8]u8 = undefined;
    var writer = Io.Writer.fixed(out[0..]);
    var conn = Conn(.{}).init(&reader, &writer, .{});
    try conn.writeClose(null, "");

    var buf: [1]u8 = undefined;
    try std.testing.expectError(error.ConnectionClosed, conn.readMessage(buf[0..]));
    try std.testing.expect(conn.close_received);
    try std.testing.expectEqualSlices(u8, &.{ 0x88, 0x00 }, out[0..writer.end]);
}

test "readMessage enforces utf8 and message size limits" {
    {
        const invalid_utf8 = [_]u8{ 0xC3, 0x28 };
        var wire: std.ArrayList(u8) = .empty;
        defer wire.deinit(std.testing.allocator);
        try appendTestFrame(&wire, std.testing.allocator, .text, true, true, invalid_utf8[0..], .{ 1, 2, 3, 4 });
        var reader = Io.Reader.fixed(wire.items);
        var sink: [0]u8 = .{};
        var writer = Io.Writer.fixed(sink[0..]);
        var conn = Conn(.{}).init(&reader, &writer, .{});
        var buf: [8]u8 = undefined;
        try std.testing.expectError(error.InvalidUtf8, conn.readMessage(buf[0..]));
    }
    {
        var wire: std.ArrayList(u8) = .empty;
        defer wire.deinit(std.testing.allocator);
        try appendTestFrame(&wire, std.testing.allocator, .text, false, true, "abc", .{ 1, 2, 3, 4 });
        try appendTestFrame(&wire, std.testing.allocator, .continuation, true, true, "de", .{ 5, 6, 7, 8 });
        var reader = Io.Reader.fixed(wire.items);
        var sink: [0]u8 = .{};
        var writer = Io.Writer.fixed(sink[0..]);
        var conn = Conn(.{}).init(&reader, &writer, .{ .max_message_payload_len = 4 });
        var buf: [8]u8 = undefined;
        try std.testing.expectError(error.MessageTooLarge, conn.readMessage(buf[0..]));
    }
}

test "readMessage drains oversized frames before returning MessageTooLarge" {
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(std.testing.allocator);
    try appendTestFrame(&wire, std.testing.allocator, .binary, true, true, "abcd", .{ 1, 2, 3, 4 });
    try appendTestFrame(&wire, std.testing.allocator, .text, true, true, "z", .{ 5, 6, 7, 8 });

    var reader = Io.Reader.fixed(wire.items);
    var sink: [0]u8 = .{};
    var writer = Io.Writer.fixed(sink[0..]);
    var conn = Conn(.{}).init(&reader, &writer, .{});

    var msg_buf: [3]u8 = undefined;
    try std.testing.expectError(error.MessageTooLarge, conn.readMessage(msg_buf[0..]));
    try std.testing.expect(!conn.recv_active);

    var frame_buf: [1]u8 = undefined;
    const next = try conn.readFrame(frame_buf[0..]);
    try std.testing.expectEqual(Opcode.text, next.header.opcode);
    try std.testing.expectEqualStrings("z", next.payload);
}

test "readMessage drains fragmented oversized messages and preserves next message boundary" {
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(std.testing.allocator);
    try appendTestFrame(&wire, std.testing.allocator, .text, false, true, "abc", .{ 1, 2, 3, 4 });
    try appendTestFrame(&wire, std.testing.allocator, .ping, true, true, "!", .{ 5, 6, 7, 8 });
    try appendTestFrame(&wire, std.testing.allocator, .continuation, true, true, "de", .{ 9, 10, 11, 12 });
    try appendTestFrame(&wire, std.testing.allocator, .binary, true, true, "ok", .{ 13, 14, 15, 16 });

    var reader = Io.Reader.fixed(wire.items);
    var out: [8]u8 = undefined;
    var writer = Io.Writer.fixed(out[0..]);
    var conn = Conn(.{}).init(&reader, &writer, .{});

    var msg_buf: [2]u8 = undefined;
    try std.testing.expectError(error.MessageTooLarge, conn.readMessage(msg_buf[0..]));
    try std.testing.expect(!conn.recv_active);
    try std.testing.expect(conn.recv_fragment_opcode == null);
    try std.testing.expectEqualSlices(u8, &.{ 0x8A, 0x01, '!' }, out[0..writer.end]);

    var frame_buf: [2]u8 = undefined;
    const next = try conn.readFrame(frame_buf[0..]);
    try std.testing.expectEqual(Opcode.binary, next.header.opcode);
    try std.testing.expectEqualStrings("ok", next.payload);
}

test "readMessage drains fragmented messages that exceed configured max size" {
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(std.testing.allocator);
    try appendTestFrame(&wire, std.testing.allocator, .text, false, true, "abc", .{ 1, 2, 3, 4 });
    try appendTestFrame(&wire, std.testing.allocator, .continuation, false, true, "de", .{ 5, 6, 7, 8 });
    try appendTestFrame(&wire, std.testing.allocator, .continuation, true, true, "f", .{ 9, 10, 11, 12 });
    try appendTestFrame(&wire, std.testing.allocator, .binary, true, true, "ok", .{ 13, 14, 15, 16 });

    var reader = Io.Reader.fixed(wire.items);
    var sink: [0]u8 = .{};
    var writer = Io.Writer.fixed(sink[0..]);
    var conn = Conn(.{}).init(&reader, &writer, .{ .max_message_payload_len = 4 });

    var msg_buf: [8]u8 = undefined;
    try std.testing.expectError(error.MessageTooLarge, conn.readMessage(msg_buf[0..]));
    try std.testing.expect(!conn.recv_active);
    try std.testing.expect(conn.recv_fragment_opcode == null);

    var frame_buf: [2]u8 = undefined;
    const next = try conn.readFrame(frame_buf[0..]);
    try std.testing.expectEqual(Opcode.binary, next.header.opcode);
    try std.testing.expectEqualStrings("ok", next.payload);
}

test "writeFrame supports extended lengths and sequencing rules" {
    {
        var payload: [126]u8 = undefined;
        @memset(payload[0..], 'a');
        var out: [256]u8 = undefined;
        var writer = Io.Writer.fixed(out[0..]);
        var reader = Io.Reader.fixed(""[0..]);
        var conn = Conn(.{}).init(&reader, &writer, .{});
        try conn.writeBinary(payload[0..]);
        try std.testing.expectEqual(@as(u8, 0x82), out[0]);
        try std.testing.expectEqual(@as(u8, 126), out[1]);
        try std.testing.expectEqual(@as(u8, 0), out[2]);
        try std.testing.expectEqual(@as(u8, 126), out[3]);
    }
    {
        const payload = try std.testing.allocator.alloc(u8, 65536);
        defer std.testing.allocator.free(payload);
        @memset(payload, 'b');
        const out = try std.testing.allocator.alloc(u8, 65546);
        defer std.testing.allocator.free(out);
        var writer = Io.Writer.fixed(out);
        var reader = Io.Reader.fixed(""[0..]);
        var conn = Conn(.{}).init(&reader, &writer, .{});
        try conn.writeBinary(payload);
        try std.testing.expectEqual(@as(u8, 0x82), out[0]);
        try std.testing.expectEqual(@as(u8, 127), out[1]);
        try std.testing.expectEqual(@as(u8, 0), out[2]);
        try std.testing.expectEqual(@as(u8, 0), out[6]);
        try std.testing.expectEqual(@as(u8, 1), out[7]);
        try std.testing.expectEqual(@as(u8, 0), out[8]);
        try std.testing.expectEqual(@as(u8, 0), out[9]);
    }
    {
        var out: [64]u8 = undefined;
        var writer = Io.Writer.fixed(out[0..]);
        var reader = Io.Reader.fixed(""[0..]);
        var conn = Conn(.{}).init(&reader, &writer, .{});
        try conn.writeFrame(.text, "hel", false);
        try std.testing.expectError(error.FragmentWriteInProgress, conn.writeFrame(.binary, "x", true));
        try conn.writeFrame(.continuation, "lo", true);
        try conn.writeBinary("x");
        try std.testing.expectEqualSlices(u8, &.{
            0x01, 0x03, 'h', 'e', 'l',
            0x80, 0x02, 'l', 'o', 0x82,
            0x01, 'x',
        }, out[0..writer.end]);
    }
    {
        var out: [8]u8 = undefined;
        var writer = Io.Writer.fixed(out[0..]);
        var reader = Io.Reader.fixed(""[0..]);
        var conn = Conn(.{}).init(&reader, &writer, .{});
        try std.testing.expectError(error.UnexpectedContinuationWrite, conn.writeFrame(.continuation, "x", true));
        try std.testing.expectError(error.ControlFrameFragmented, conn.writeFrame(.ping, "", false));
    }
    {
        var payload: [126]u8 = undefined;
        @memset(payload[0..], 'm');
        var out: [256]u8 = undefined;
        var writer = Io.Writer.fixed(out[0..]);
        var reader = Io.Reader.fixed(""[0..]);
        var conn = Conn(.{ .role = .client }).init(&reader, &writer, .{});
        try conn.writeBinary(payload[0..]);
        try std.testing.expectEqual(@as(u8, 0x82), out[0]);
        try std.testing.expectEqual(@as(u8, 0xFE), out[1]);
        try std.testing.expectEqual(@as(u8, 0), out[2]);
        try std.testing.expectEqual(@as(u8, 126), out[3]);
        try std.testing.expectEqual(@as(usize, 4 + 4 + 126), writer.end);
    }
}

test "writeText writePing writePong and writeClose validate inputs" {
    {
        const invalid_utf8 = [_]u8{ 0xC3, 0x28 };
        var out: [16]u8 = undefined;
        var writer = Io.Writer.fixed(out[0..]);
        var reader = Io.Reader.fixed(""[0..]);
        var conn = Conn(.{}).init(&reader, &writer, .{});
        try std.testing.expectError(error.InvalidUtf8, conn.writeText(invalid_utf8[0..]));
    }
    {
        var payload: [126]u8 = undefined;
        @memset(payload[0..], 'x');
        var out: [16]u8 = undefined;
        var writer = Io.Writer.fixed(out[0..]);
        var reader = Io.Reader.fixed(""[0..]);
        var conn = Conn(.{}).init(&reader, &writer, .{});
        try std.testing.expectError(error.ControlFrameTooLarge, conn.writePing(payload[0..]));
        try std.testing.expectError(error.ControlFrameTooLarge, conn.writePong(payload[0..]));
    }
    {
        var out: [256]u8 = undefined;
        var writer = Io.Writer.fixed(out[0..]);
        var reader = Io.Reader.fixed(""[0..]);
        var conn = Conn(.{}).init(&reader, &writer, .{});
        try std.testing.expectError(error.InvalidClosePayload, conn.writeClose(null, "reason"));
        try std.testing.expectError(error.InvalidCloseCode, conn.writeClose(1005, ""));
        try std.testing.expectError(error.InvalidUtf8, conn.writeClose(1000, &[_]u8{ 0xC3, 0x28 }));

        var long_reason: [124]u8 = undefined;
        @memset(long_reason[0..], 'r');
        try std.testing.expectError(error.ControlFrameTooLarge, conn.writeClose(1000, long_reason[0..]));

        try conn.writeClose(null, "");
        try std.testing.expect(conn.close_sent);
        try std.testing.expectEqualSlices(u8, &.{ 0x88, 0x00 }, out[0..writer.end]);
    }
    {
        var out: [64]u8 = undefined;
        var writer = Io.Writer.fixed(out[0..]);
        var reader = Io.Reader.fixed(""[0..]);
        var conn = Conn(.{}).init(&reader, &writer, .{});
        try conn.writeClose(null, "");
        try std.testing.expectError(error.ConnectionClosed, conn.writeText("x"));
        try std.testing.expectError(error.ConnectionClosed, conn.writeBinary("x"));
        try std.testing.expectError(error.ConnectionClosed, conn.writePing(""));
        try std.testing.expectError(error.ConnectionClosed, conn.writePong(""));
        try std.testing.expectError(error.ConnectionClosed, conn.writeClose(null, ""));
        try std.testing.expectEqualSlices(u8, &.{ 0x88, 0x00 }, out[0..writer.end]);
    }
}

test "client control writers emit masked frames" {
    var out: [64]u8 = undefined;
    var writer = Io.Writer.fixed(out[0..]);
    var reader = Io.Reader.fixed(""[0..]);
    var conn = Conn(.{ .role = .client }).init(&reader, &writer, .{});

    try conn.writePing("!");
    try conn.writePong("?");

    const written = out[0..writer.end];
    try std.testing.expectEqual(@as(u8, 0x89), written[0]);
    try std.testing.expectEqual(@as(u8, 0x81), written[1]);
    try std.testing.expectEqual(written[6], '!' ^ written[2]);
    try std.testing.expectEqual(@as(u8, 0x8A), written[7]);
    try std.testing.expectEqual(@as(u8, 0x81), written[8]);
    try std.testing.expectEqual(written[13], '?' ^ written[9]);
}

test "parseClosePayload covers empty invalid code and utf8-disabled behavior" {
    {
        const close = try parseClosePayload("", true);
        try std.testing.expect(close.code == null);
        try std.testing.expectEqual(@as(usize, 0), close.reason.len);
    }
    try std.testing.expectError(error.InvalidClosePayload, parseClosePayload(&[_]u8{0x03}, true));
    try std.testing.expectError(error.InvalidCloseCode, parseClosePayload(&[_]u8{ 0x03, 0xED }, true));
    {
        const close = try parseClosePayload(&[_]u8{ 0x03, 0xE8 }, true);
        try std.testing.expectEqual(@as(?u16, 1000), close.code);
        try std.testing.expectEqual(@as(usize, 0), close.reason.len);
    }
    {
        const payload = [_]u8{ 0x03, 0xE8, 0xC3, 0x28 };
        const close = try parseClosePayload(payload[0..], false);
        try std.testing.expectEqual(@as(?u16, 1000), close.code);
        try std.testing.expectEqualSlices(u8, &.{ 0xC3, 0x28 }, close.reason);
    }
    try std.testing.expectError(error.InvalidUtf8, parseClosePayload(&[_]u8{ 0x03, 0xE8, 0xC3, 0x28 }, true));
}

test "readFrameBorrowed unmasks payload without a copy" {
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(std.testing.allocator);
    try appendTestFrame(&wire, std.testing.allocator, .text, true, true, "borrowed", .{ 1, 2, 3, 4 });

    var reader = Io.Reader.fixed(wire.items);
    var sink: [0]u8 = .{};
    var writer = Io.Writer.fixed(sink[0..]);
    var conn = Conn(.{}).init(&reader, &writer, .{});

    const frame = (try conn.readFrameBorrowed()).?;
    try std.testing.expectEqual(Opcode.text, frame.header.opcode);
    try std.testing.expect(frame.header.fin);
    try std.testing.expectEqualStrings("borrowed", frame.payload);
}

test "readFrameBorrowed handles empty payload control frames" {
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(std.testing.allocator);
    try appendTestFrame(&wire, std.testing.allocator, .ping, true, true, "", .{ 1, 2, 3, 4 });

    var reader = Io.Reader.fixed(wire.items);
    var sink: [0]u8 = .{};
    var writer = Io.Writer.fixed(sink[0..]);
    var conn = Conn(.{}).init(&reader, &writer, .{});

    const frame = (try conn.readFrameBorrowed()).?;
    try std.testing.expectEqual(Opcode.ping, frame.header.opcode);
    try std.testing.expectEqual(@as(usize, 0), frame.payload.len);
}

test "readFrameBorrowed supports unmasked client-role frames" {
    const wire = [_]u8{ 0x82, 0x02, 'o', 'k' };
    var reader = Io.Reader.fixed(wire[0..]);
    var sink: [0]u8 = .{};
    var writer = Io.Writer.fixed(sink[0..]);
    var conn = Conn(.{ .role = .client }).init(&reader, &writer, .{});

    const frame = (try conn.readFrameBorrowed()).?;
    try std.testing.expectEqual(Opcode.binary, frame.header.opcode);
    try std.testing.expectEqualStrings("ok", frame.payload);
}

test "readFrameBorrowed returns null for payload sizes that cannot fit in usize" {
    const wire = [_]u8{
        0x82,
        0xFF,
        0x7F,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        1,
        2,
        3,
        4,
    };
    var reader = Io.Reader.fixed(wire[0..]);
    var sink: [0]u8 = .{};
    var writer = Io.Writer.fixed(sink[0..]);
    var conn = Conn(.{}).init(&reader, &writer, .{});

    try std.testing.expect((try conn.readFrameBorrowed()) == null);
}

test "echoFrame preserves fragmentation and mirrors close payload" {
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(std.testing.allocator);
    try appendTestFrame(&wire, std.testing.allocator, .text, false, true, "hel", .{ 1, 2, 3, 4 });
    try appendTestFrame(&wire, std.testing.allocator, .continuation, true, true, "lo", .{ 5, 6, 7, 8 });
    try appendTestFrame(&wire, std.testing.allocator, .close, true, true, &.{ 0x03, 0xE8, 'b', 'y', 'e' }, .{ 9, 10, 11, 12 });

    var reader = Io.Reader.fixed(wire.items);
    var out: [64]u8 = undefined;
    var writer = Io.Writer.fixed(out[0..]);
    var conn = Conn(.{}).init(&reader, &writer, .{});
    var scratch: [16]u8 = undefined;

    try std.testing.expectEqual(Opcode.text, (try conn.echoFrame(scratch[0..])).opcode);
    try std.testing.expectEqual(Opcode.continuation, (try conn.echoFrame(scratch[0..])).opcode);
    try std.testing.expectEqual(Opcode.close, (try conn.echoFrame(scratch[0..])).opcode);
    try std.testing.expect(conn.close_received);
    try std.testing.expect(conn.close_sent);
    try std.testing.expectEqualSlices(u8, &.{
        0x01, 0x03, 'h',  'e', 'l',
        0x80, 0x02, 'l',  'o', 0x88,
        0x05, 0x03, 0xE8, 'b', 'y',
        'e',
    }, out[0..writer.end]);
}

test "echoFrame falls back to scratch buffer when borrowing is unavailable" {
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(std.testing.allocator);
    try appendTestFrame(&wire, std.testing.allocator, .binary, true, true, "abc", .{ 1, 2, 3, 4 });

    var base_reader = Io.Reader.fixed(wire.items);
    var indirect_buffer: [6]u8 = undefined;
    var indirect = std.testing.ReaderIndirect.init(&base_reader, indirect_buffer[0..]);

    var out: [16]u8 = undefined;
    var writer = Io.Writer.fixed(out[0..]);
    var conn = Conn(.{}).init(&indirect.interface, &writer, .{});
    var scratch: [8]u8 = undefined;

    const echoed = try conn.echoFrame(scratch[0..]);
    try std.testing.expectEqual(Opcode.binary, echoed.opcode);
    try std.testing.expectEqual(@as(usize, 3), echoed.payload_len);
    try std.testing.expectEqualSlices(u8, &.{ 0x82, 0x03, 'a', 'b', 'c' }, out[0..writer.end]);
}

test "echoFrame ignores pong frames without writing output" {
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(std.testing.allocator);
    try appendTestFrame(&wire, std.testing.allocator, .pong, true, true, "!", .{ 1, 2, 3, 4 });

    var reader = Io.Reader.fixed(wire.items);
    var out: [8]u8 = undefined;
    var writer = Io.Writer.fixed(out[0..]);
    var conn = Conn(.{}).init(&reader, &writer, .{});
    var scratch: [4]u8 = undefined;

    const echoed = try conn.echoFrame(scratch[0..]);
    try std.testing.expectEqual(Opcode.pong, echoed.opcode);
    try std.testing.expectEqual(@as(usize, 1), echoed.payload_len);
    try std.testing.expectEqual(@as(usize, 0), writer.end);
}

test "echoFrame validates close payload even after local close was sent" {
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(std.testing.allocator);
    try appendTestFrame(&wire, std.testing.allocator, .close, true, true, &.{0x03}, .{ 1, 2, 3, 4 });

    var reader = Io.Reader.fixed(wire.items);
    var out: [16]u8 = undefined;
    var writer = Io.Writer.fixed(out[0..]);
    var conn = Conn(.{}).init(&reader, &writer, .{});
    try conn.writeClose(null, "");

    var scratch: [8]u8 = undefined;
    try std.testing.expectError(error.InvalidClosePayload, conn.echoFrame(scratch[0..]));
}

test "echoFrame clears fragmented receive state when a close interrupts a message" {
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(std.testing.allocator);
    try appendTestFrame(&wire, std.testing.allocator, .text, false, true, "abc", .{ 1, 2, 3, 4 });
    try appendTestFrame(&wire, std.testing.allocator, .close, true, true, "", .{ 5, 6, 7, 8 });

    var reader = Io.Reader.fixed(wire.items);
    var out: [8]u8 = undefined;
    var writer = Io.Writer.fixed(out[0..]);
    var conn = Conn(.{}).init(&reader, &writer, .{});
    var scratch: [8]u8 = undefined;

    try std.testing.expectEqual(Opcode.text, (try conn.echoFrame(scratch[0..])).opcode);
    try std.testing.expect(conn.recv_fragment_opcode != null);
    try std.testing.expectEqual(Opcode.close, (try conn.echoFrame(scratch[0..])).opcode);
    try std.testing.expect(conn.close_received);
    try std.testing.expect(conn.recv_fragment_opcode == null);
    try std.testing.expectEqualSlices(u8, &.{
        0x01, 0x03, 'a', 'b', 'c',
        0x88, 0x00,
    }, out[0..writer.end]);
}

test "echoFrame ignores ping frames after a local close has already been sent" {
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(std.testing.allocator);
    try appendTestFrame(&wire, std.testing.allocator, .ping, true, true, "!", .{ 1, 2, 3, 4 });

    var reader = Io.Reader.fixed(wire.items);
    var out: [8]u8 = undefined;
    var writer = Io.Writer.fixed(out[0..]);
    var conn = Conn(.{}).init(&reader, &writer, .{});
    try conn.writeClose(null, "");

    var scratch: [4]u8 = undefined;
    const echoed = try conn.echoFrame(scratch[0..]);
    try std.testing.expectEqual(Opcode.ping, echoed.opcode);
    try std.testing.expectEqual(@as(usize, 1), echoed.payload_len);
    try std.testing.expectEqualSlices(u8, &.{ 0x88, 0x00 }, out[0..writer.end]);
}

test "readMessage accepts empty text messages" {
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(std.testing.allocator);
    try appendTestFrame(&wire, std.testing.allocator, .text, true, true, "", .{ 1, 2, 3, 4 });

    var reader = Io.Reader.fixed(wire.items);
    var sink: [0]u8 = .{};
    var writer = Io.Writer.fixed(sink[0..]);
    var conn = Conn(.{}).init(&reader, &writer, .{});
    var buf: [1]u8 = undefined;

    const msg = try conn.readMessage(buf[0..]);
    try std.testing.expectEqual(MessageOpcode.text, msg.opcode);
    try std.testing.expectEqual(@as(usize, 0), msg.payload.len);
}

test "readMessage handles control frames interleaved with fragments" {
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(std.testing.allocator);
    try appendTestFrame(&wire, std.testing.allocator, .text, false, true, "he", .{ 1, 2, 3, 4 });
    try appendTestFrame(&wire, std.testing.allocator, .ping, true, true, "!", .{ 5, 6, 7, 8 });
    try appendTestFrame(&wire, std.testing.allocator, .continuation, true, true, "llo", .{ 9, 10, 11, 12 });

    var reader = Io.Reader.fixed(wire.items);
    var out: [8]u8 = undefined;
    var writer = Io.Writer.fixed(out[0..]);
    var conn = Conn(.{}).init(&reader, &writer, .{});
    var buf: [8]u8 = undefined;

    const msg = try conn.readMessage(buf[0..]);
    try std.testing.expectEqual(MessageOpcode.text, msg.opcode);
    try std.testing.expectEqualStrings("hello", msg.payload);
    try std.testing.expectEqualSlices(u8, &.{ 0x8A, 0x01, '!' }, out[0..writer.end]);
}

test "readMessage resumes fragmented messages after frame-level reads" {
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(std.testing.allocator);
    try appendTestFrame(&wire, std.testing.allocator, .text, false, true, "he", .{ 1, 2, 3, 4 });
    try appendTestFrame(&wire, std.testing.allocator, .continuation, true, true, "llo", .{ 5, 6, 7, 8 });

    var reader = Io.Reader.fixed(wire.items);
    var sink: [0]u8 = .{};
    var writer = Io.Writer.fixed(sink[0..]);
    var conn = Conn(.{}).init(&reader, &writer, .{});
    var frame_buf: [4]u8 = undefined;
    const frame = try conn.readFrame(frame_buf[0..]);
    try std.testing.expectEqual(Opcode.text, frame.header.opcode);
    try std.testing.expectEqualStrings("he", frame.payload);

    var msg_buf: [8]u8 = undefined;
    const msg = try conn.readMessage(msg_buf[0..]);
    try std.testing.expectEqual(MessageOpcode.text, msg.opcode);
    try std.testing.expectEqualStrings("llo", msg.payload);
}

test "permessage-deflate client/server roundtrip preserves message payloads" {
    const pmd_cfg: PerMessageDeflateConfig = .{
        .allocator = std.testing.allocator,
    };

    var out: [1024]u8 = undefined;
    var client_writer = Io.Writer.fixed(out[0..]);
    var empty_reader = Io.Reader.fixed(""[0..]);
    var client = Conn(.{ .role = .client }).init(&empty_reader, &client_writer, .{
        .permessage_deflate = pmd_cfg,
    });

    const payload = "zwebsocket interop text payload with enough repetition to exercise permessage-deflate";
    try client.writeText(payload);

    var server_reader = Io.Reader.fixed(out[0..client_writer.end]);
    var sink: [0]u8 = .{};
    var server_writer = Io.Writer.fixed(sink[0..]);
    var server = Conn(.{}).init(&server_reader, &server_writer, .{
        .permessage_deflate = pmd_cfg,
    });
    var message_buf: [256]u8 = undefined;
    const message = try server.readMessage(message_buf[0..]);
    try std.testing.expectEqual(MessageOpcode.text, message.opcode);
    try std.testing.expectEqualStrings(payload, message.payload);
}

test "beginFrame rejects compressed control frames even when permessage-deflate is enabled" {
    const wire = [_]u8{
        0xC9,
        0x80,
        0x01,
        0x02,
        0x03,
        0x04,
    };
    var reader = Io.Reader.fixed(wire[0..]);
    var sink: [0]u8 = .{};
    var writer = Io.Writer.fixed(sink[0..]);
    var conn = Conn(.{}).init(&reader, &writer, .{
        .permessage_deflate = .{
            .allocator = std.testing.allocator,
        },
    });
    try std.testing.expectError(error.ReservedBitsSet, conn.beginFrame());
}

test "applyMask is reversible across chunk boundaries and offsets" {
    var payload = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 };
    const original = payload;
    const mask = [_]u8{ 0x11, 0x22, 0x33, 0x44 };
    applyMask(payload[0..4], mask, 0);
    applyMask(payload[4..], mask, 4);
    applyMask(payload[0..3], mask, 0);
    applyMask(payload[3..], mask, 3);
    try std.testing.expectEqualSlices(u8, original[0..], payload[0..]);
}

const TestObserverState = struct {
    events: [16]observe.Event = undefined,
    len: usize = 0,

    fn onEvent(ctx: ?*anyopaque, event: observe.Event) void {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        self.events[self.len] = event;
        self.len += 1;
    }

    fn observer(self: *@This()) observe.Observer {
        return .{
            .ctx = self,
            .on_event_fn = onEvent,
        };
    }
};

const TestClockState = struct {
    now_ns: u64 = 0,
    step_ns: u64,

    fn now(ctx: ?*anyopaque) u64 {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        const current = self.now_ns;
        self.now_ns += self.step_ns;
        return current;
    }
};

const TestDeadlineState = struct {
    read_calls: [8]?u64 = [_]?u64{null} ** 8,
    read_len: usize = 0,
    write_calls: [8]?u64 = [_]?u64{null} ** 8,
    write_len: usize = 0,
    flush_calls: [8]?u64 = [_]?u64{null} ** 8,
    flush_len: usize = 0,

    fn setRead(ctx: ?*anyopaque, deadline_ns: ?u64) void {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        self.read_calls[self.read_len] = deadline_ns;
        self.read_len += 1;
    }

    fn setWrite(ctx: ?*anyopaque, deadline_ns: ?u64) void {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        self.write_calls[self.write_len] = deadline_ns;
        self.write_len += 1;
    }

    fn setFlush(ctx: ?*anyopaque, deadline_ns: ?u64) void {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        self.flush_calls[self.flush_len] = deadline_ns;
        self.flush_len += 1;
    }
};

test "observer records frame reads and writes" {
    var state: TestObserverState = .{};

    var empty_reader = Io.Reader.fixed(""[0..]);
    var write_buf: [32]u8 = undefined;
    var write_writer = Io.Writer.fixed(write_buf[0..]);
    var write_conn = Conn(.{}).init(&empty_reader, &write_writer, .{
        .observer = state.observer(),
    });
    try write_conn.writeBinary("abc");

    const wire = [_]u8{ 0x81, 0x02, 'O', 'K' };
    var read_reader = Io.Reader.fixed(wire[0..]);
    var read_sink: [0]u8 = .{};
    var read_writer = Io.Writer.fixed(read_sink[0..]);
    var read_conn = Conn(.{ .role = .client }).init(&read_reader, &read_writer, .{
        .observer = state.observer(),
    });
    var frame_buf: [8]u8 = undefined;
    _ = try read_conn.readFrame(frame_buf[0..]);

    try std.testing.expectEqual(@as(usize, 2), state.len);
    switch (state.events[0]) {
        .frame_write => |event| {
            try std.testing.expectEqual(Opcode.binary, event.opcode);
            try std.testing.expectEqual(@as(u64, 3), event.payload_len);
            try std.testing.expect(event.fin);
        },
        else => try std.testing.expect(false),
    }
    switch (state.events[1]) {
        .frame_read => |event| {
            try std.testing.expectEqual(Opcode.text, event.opcode);
            try std.testing.expectEqual(@as(u64, 2), event.payload_len);
            try std.testing.expect(!event.borrowed);
        },
        else => try std.testing.expect(false),
    }
}

test "echoFrame emits close_received once per close frame" {
    var state: TestObserverState = .{};
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(std.testing.allocator);
    const close_payload = [_]u8{ 0x03, 0xE8 };
    try appendTestFrame(&wire, std.testing.allocator, .close, true, true, close_payload[0..], .{ 1, 2, 3, 4 });

    var reader = Io.Reader.fixed(wire.items);
    var out: [64]u8 = undefined;
    var writer = Io.Writer.fixed(out[0..]);
    var conn = Conn(.{}).init(&reader, &writer, .{
        .observer = state.observer(),
    });
    var scratch: [32]u8 = undefined;
    const echoed = try conn.echoFrame(scratch[0..]);
    try std.testing.expectEqual(Opcode.close, echoed.opcode);

    var close_received_count: usize = 0;
    for (state.events[0..state.len]) |event| {
        switch (event) {
            .close_received => close_received_count += 1,
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 1), close_received_count);
}

test "read timeout returns Timeout and emits a timeout event" {
    var observer_state: TestObserverState = .{};
    var clock_state: TestClockState = .{
        .step_ns = 5,
    };
    const wire = [_]u8{ 0x81, 0x00 };
    var reader = Io.Reader.fixed(wire[0..]);
    var sink: [0]u8 = .{};
    var writer = Io.Writer.fixed(sink[0..]);
    var conn = Conn(.{ .role = .client }).init(&reader, &writer, .{
        .timeouts = .{
            .clock = .{
                .ctx = &clock_state,
                .now_ns_fn = TestClockState.now,
            },
            .read_ns = 1,
        },
        .observer = observer_state.observer(),
    });

    try std.testing.expectError(error.Timeout, conn.beginFrame());
    try std.testing.expectEqual(@as(usize, 1), observer_state.len);
    switch (observer_state.events[0]) {
        .timeout => |event| {
            try std.testing.expectEqual(observe.IoPhase.read, event.phase);
            try std.testing.expectEqual(@as(u64, 1), event.budget_ns);
            try std.testing.expect(event.elapsed_ns > event.budget_ns);
        },
        else => try std.testing.expect(false),
    }
}

test "deadline controller is set and cleared around timed reads and writes" {
    const StaticClock = struct {
        fn now(_: ?*anyopaque) u64 {
            return 10;
        }
    };

    var deadline_state: TestDeadlineState = .{};

    const read_wire = [_]u8{ 0x81, 0x01, 'x' };
    var reader = Io.Reader.fixed(read_wire[0..]);
    var read_sink: [0]u8 = .{};
    var read_writer = Io.Writer.fixed(read_sink[0..]);
    var read_conn = Conn(.{ .role = .client }).init(&reader, &read_writer, .{
        .timeouts = .{
            .clock = .{
                .now_ns_fn = StaticClock.now,
            },
            .read_ns = 20,
            .deadlines = .{
                .ctx = &deadline_state,
                .set_read_deadline_ns_fn = TestDeadlineState.setRead,
            },
        },
    });
    var read_buf: [4]u8 = undefined;
    _ = try read_conn.readFrame(read_buf[0..]);

    try std.testing.expect(deadline_state.read_len >= 2);
    try std.testing.expectEqual(@as(?u64, 30), deadline_state.read_calls[0]);
    try std.testing.expectEqual(@as(?u64, null), deadline_state.read_calls[deadline_state.read_len - 1]);

    var empty_reader = Io.Reader.fixed(""[0..]);
    var out: [16]u8 = undefined;
    var writer = Io.Writer.fixed(out[0..]);
    var write_conn = Conn(.{}).init(&empty_reader, &writer, .{
        .timeouts = .{
            .clock = .{
                .now_ns_fn = StaticClock.now,
            },
            .write_ns = 20,
            .flush_ns = 20,
            .deadlines = .{
                .ctx = &deadline_state,
                .set_write_deadline_ns_fn = TestDeadlineState.setWrite,
                .set_flush_deadline_ns_fn = TestDeadlineState.setFlush,
            },
        },
    });
    try write_conn.writeBinary("y");
    try write_conn.flush();

    try std.testing.expect(deadline_state.write_len >= 2);
    try std.testing.expectEqual(@as(?u64, 30), deadline_state.write_calls[0]);
    try std.testing.expectEqual(@as(?u64, null), deadline_state.write_calls[deadline_state.write_len - 1]);
    try std.testing.expect(deadline_state.flush_len >= 2);
    try std.testing.expectEqual(@as(?u64, 30), deadline_state.flush_calls[0]);
    try std.testing.expectEqual(@as(?u64, null), deadline_state.flush_calls[deadline_state.flush_len - 1]);
}

test "runtime_hooks false disables observer and timeout hooks" {
    var observer_state: TestObserverState = .{};
    var clock_state: TestClockState = .{
        .step_ns = 5,
    };
    var deadline_state: TestDeadlineState = .{};

    const wire = [_]u8{ 0x81, 0x01, 'x' };
    var reader = Io.Reader.fixed(wire[0..]);
    var write_buf: [16]u8 = undefined;
    var writer = Io.Writer.fixed(write_buf[0..]);
    var conn = Conn(.{
        .role = .client,
        .runtime_hooks = false,
    }).init(&reader, &writer, .{
        .timeouts = .{
            .clock = .{
                .ctx = &clock_state,
                .now_ns_fn = TestClockState.now,
            },
            .read_ns = 1,
            .write_ns = 1,
            .flush_ns = 1,
            .deadlines = .{
                .ctx = &deadline_state,
                .set_read_deadline_ns_fn = TestDeadlineState.setRead,
                .set_write_deadline_ns_fn = TestDeadlineState.setWrite,
                .set_flush_deadline_ns_fn = TestDeadlineState.setFlush,
            },
        },
        .observer = observer_state.observer(),
    });

    var frame_buf: [8]u8 = undefined;
    const frame = try conn.readFrame(frame_buf[0..]);
    try std.testing.expectEqual(Opcode.text, frame.header.opcode);
    try std.testing.expectEqualStrings("x", frame.payload);
    try conn.writeBinary("ok");
    try conn.flush();

    try std.testing.expectEqual(@as(usize, 0), observer_state.len);
    try std.testing.expectEqual(@as(usize, 0), deadline_state.read_len);
    try std.testing.expectEqual(@as(usize, 0), deadline_state.write_len);
    try std.testing.expectEqual(@as(usize, 0), deadline_state.flush_len);
}
