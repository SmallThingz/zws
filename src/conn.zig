const std = @import("std");
const Io = std.Io;

const proto = @import("protocol.zig");

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
    ConnectionClosed,
    FragmentWriteInProgress,
    UnexpectedContinuationWrite,
};

pub const Config = struct {
    role: Role = .server,
    auto_pong: bool = true,
    auto_reply_close: bool = true,
    validate_utf8: bool = true,
    max_frame_payload_len: u64 = std.math.maxInt(u64),
    max_message_payload_len: usize = std.math.maxInt(usize),
};

pub const FrameHeader = struct {
    fin: bool,
    masked: bool,
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

pub const Conn = struct {
    reader: *Io.Reader,
    writer: *Io.Writer,
    config: Config,
    mask_prng: std.Random.DefaultPrng,

    recv_active: bool = false,
    recv_header: FrameHeader = undefined,
    recv_remaining: u64 = 0,
    recv_mask: [4]u8 = .{0} ** 4,
    recv_mask_offset: usize = 0,
    recv_fragment_opcode: ?MessageOpcode = null,

    send_fragment_opcode: ?MessageOpcode = null,
    close_sent: bool = false,
    close_received: bool = false,

    const Self = @This();
    const masked_write_scratch_len = 4096;

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

    pub fn flush(self: *Self) Io.Writer.Error!void {
        try self.writer.flush();
    }

    pub fn beginFrame(self: *Self) (ProtocolError || Io.Reader.Error)!FrameHeader {
        if (self.recv_active) return error.FrameActive;

        var header_buf: [2]u8 = undefined;
        try self.reader.readSliceAll(header_buf[0..]);

        if ((header_buf[0] & 0x70) != 0) return error.ReservedBitsSet;

        const opcode: Opcode = switch (@as(u4, @truncate(header_buf[0]))) {
            0x0 => .continuation,
            0x1 => .text,
            0x2 => .binary,
            0x8 => .close,
            0x9 => .ping,
            0xA => .pong,
            else => return error.UnknownOpcode,
        };
        const fin = (header_buf[0] & 0x80) != 0;
        const masked = (header_buf[1] & 0x80) != 0;

        const expected_masked = self.config.role == .server;
        if (masked != expected_masked) return error.MaskBitInvalid;

        var payload_len: u64 = header_buf[1] & 0x7f;
        if (payload_len == 126) {
            var ext: [2]u8 = undefined;
            try self.reader.readSliceAll(ext[0..]);
            payload_len = std.mem.readInt(u16, ext[0..], .big);
        } else if (payload_len == 127) {
            var ext: [8]u8 = undefined;
            try self.reader.readSliceAll(ext[0..]);
            if ((ext[0] & 0x80) != 0) return error.InvalidFrameLength;
            payload_len = std.mem.readInt(u64, ext[0..], .big);
        }

        if (payload_len > self.config.max_frame_payload_len) return error.FrameTooLarge;

        if (proto.isControl(opcode)) {
            if (!fin) return error.ControlFrameFragmented;
            if (payload_len > 125) return error.ControlFrameTooLarge;
        } else switch (opcode) {
            .continuation => {
                if (self.recv_fragment_opcode == null) return error.UnexpectedContinuation;
            },
            .text, .binary => {
                if (self.recv_fragment_opcode != null) return error.ExpectedContinuation;
            },
            else => unreachable,
        }

        if (masked) {
            try self.reader.readSliceAll(self.recv_mask[0..]);
        } else {
            self.recv_mask = .{0} ** 4;
        }

        self.recv_header = .{
            .fin = fin,
            .masked = masked,
            .opcode = opcode,
            .payload_len = payload_len,
        };
        self.recv_active = true;
        self.recv_remaining = payload_len;
        self.recv_mask_offset = 0;

        if (!fin) {
            if (proto.messageOpcode(opcode)) |message_opcode| {
                self.recv_fragment_opcode = message_opcode;
            }
        }

        return self.recv_header;
    }

    pub fn readFrameChunk(self: *Self, dest: []u8) (ProtocolError || Io.Reader.Error)![]u8 {
        if (!self.recv_active) return error.NoActiveFrame;
        if (self.recv_remaining == 0) {
            self.finishActiveFrame();
            return dest[0..0];
        }
        if (dest.len == 0) return dest[0..0];

        const n: usize = @min(dest.len, @as(usize, @intCast(self.recv_remaining)));
        try self.reader.readSliceAll(dest[0..n]);
        if (self.recv_header.masked) applyMask(dest[0..n], self.recv_mask, self.recv_mask_offset);

        self.recv_remaining -= n;
        self.recv_mask_offset += n;

        if (self.recv_remaining == 0) self.finishActiveFrame();
        return dest[0..n];
    }

    pub fn readFrameAll(self: *Self, dest: []u8) (ProtocolError || Io.Reader.Error)![]u8 {
        if (!self.recv_active) return error.NoActiveFrame;
        if (self.recv_remaining > dest.len) return error.MessageTooLarge;
        if (self.recv_remaining == 0) {
            self.finishActiveFrame();
            return dest[0..0];
        }
        return try self.readFrameChunk(dest[0..@as(usize, @intCast(self.recv_remaining))]);
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
        var message_opcode: ?MessageOpcode = null;
        var control_buf: [125]u8 = undefined;

        while (true) {
            const header = try self.beginFrame();
            if (proto.isControl(header.opcode)) {
                const payload = try self.readFrameAll(control_buf[0..]);
                switch (header.opcode) {
                    .ping => if (self.config.auto_pong) try self.writePong(payload),
                    .pong => {},
                    .close => {
                        self.close_received = true;
                        const close_frame = try parseClosePayload(payload, self.config.validate_utf8);
                        if (self.config.auto_reply_close and !self.close_sent) {
                            try self.writeClose(close_frame.code, close_frame.reason);
                        }
                        return error.ConnectionClosed;
                    },
                    else => unreachable,
                }
                continue;
            }

            if (message_opcode == null) {
                message_opcode = proto.messageOpcode(header.opcode) orelse unreachable;
            }

            if (header.payload_len > buf.len - total_len) return error.MessageTooLarge;
            const chunk = try self.readFrameAll(buf[total_len..]);
            total_len += chunk.len;

            if (total_len > self.config.max_message_payload_len) return error.MessageTooLarge;
            if (!header.fin) continue;

            const final_opcode = message_opcode.?;
            if (final_opcode == .text and self.config.validate_utf8 and !std.unicode.utf8ValidateSlice(buf[0..total_len])) {
                return error.InvalidUtf8;
            }
            return .{
                .opcode = final_opcode,
                .payload = buf[0..total_len],
            };
        }
    }

    pub fn writeFrame(
        self: *Self,
        opcode: Opcode,
        payload: []const u8,
        fin: bool,
    ) (ProtocolError || Io.Writer.Error)!void {
        if (proto.isControl(opcode) and payload.len > 125) return error.ControlFrameTooLarge;
        try self.validateOutgoingSequence(opcode, fin);

        var header_buf: [14]u8 = undefined;
        var header_len: usize = 0;

        const fin_bit: u8 = if (fin) 0x80 else 0;
        header_buf[header_len] = @as(u8, @intFromEnum(opcode)) | fin_bit;
        header_len += 1;

        const masked = self.config.role == .client;
        if (payload.len <= 125) {
            header_buf[header_len] = @as(u8, @intCast(payload.len));
            if (masked) header_buf[header_len] |= 0x80;
            header_len += 1;
        } else if (payload.len <= std.math.maxInt(u16)) {
            header_buf[header_len] = 126;
            if (masked) header_buf[header_len] |= 0x80;
            header_len += 1;
            std.mem.writeInt(u16, header_buf[header_len..][0..2], @as(u16, @intCast(payload.len)), .big);
            header_len += 2;
        } else {
            header_buf[header_len] = 127;
            if (masked) header_buf[header_len] |= 0x80;
            header_len += 1;
            std.mem.writeInt(u64, header_buf[header_len..][0..8], payload.len, .big);
            header_len += 8;
        }

        if (masked) {
            var mask: [4]u8 = undefined;
            self.mask_prng.random().bytes(mask[0..]);
            @memcpy(header_buf[header_len..][0..4], mask[0..]);
            header_len += 4;
            try self.writer.writeAll(header_buf[0..header_len]);

            var scratch: [masked_write_scratch_len]u8 = undefined;
            var offset: usize = 0;
            while (offset < payload.len) {
                const n = @min(masked_write_scratch_len, payload.len - offset);
                @memcpy(scratch[0..n], payload[offset..][0..n]);
                applyMask(scratch[0..n], mask, offset);
                try self.writer.writeAll(scratch[0..n]);
                offset += n;
            }
            return;
        }

        try self.writer.writeAll(header_buf[0..header_len]);
        try self.writer.writeAll(payload);
    }

    pub fn writeText(self: *Self, payload: []const u8) (ProtocolError || Io.Writer.Error)!void {
        if (self.config.validate_utf8 and !std.unicode.utf8ValidateSlice(payload)) return error.InvalidUtf8;
        try self.writeFrame(.text, payload, true);
    }

    pub fn writeBinary(self: *Self, payload: []const u8) (ProtocolError || Io.Writer.Error)!void {
        try self.writeFrame(.binary, payload, true);
    }

    pub fn writePing(self: *Self, payload: []const u8) (ProtocolError || Io.Writer.Error)!void {
        if (payload.len > 125) return error.ControlFrameTooLarge;
        try self.writeFrame(.ping, payload, true);
    }

    pub fn writePong(self: *Self, payload: []const u8) (ProtocolError || Io.Writer.Error)!void {
        if (payload.len > 125) return error.ControlFrameTooLarge;
        try self.writeFrame(.pong, payload, true);
    }

    pub fn writeClose(
        self: *Self,
        code: ?u16,
        reason: []const u8,
    ) (ProtocolError || Io.Writer.Error)!void {
        if (code == null and reason.len != 0) return error.InvalidClosePayload;
        if (self.config.validate_utf8 and !std.unicode.utf8ValidateSlice(reason)) return error.InvalidUtf8;

        var payload: [125]u8 = undefined;
        var len: usize = 0;
        if (code) |close_code| {
            if (!proto.isValidCloseCode(close_code)) return error.InvalidCloseCode;
            std.mem.writeInt(u16, payload[0..2], close_code, .big);
            len = 2;
        }

        if (len + reason.len > 125) return error.ControlFrameTooLarge;
        @memcpy(payload[len..][0..reason.len], reason);
        len += reason.len;

        try self.writeFrame(.close, payload[0..len], true);
        self.close_sent = true;
    }

    fn validateOutgoingSequence(self: *Self, opcode: Opcode, fin: bool) ProtocolError!void {
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

    fn finishActiveFrame(self: *Self) void {
        const header = self.recv_header;
        self.recv_active = false;
        self.recv_remaining = 0;
        self.recv_mask_offset = 0;

        if (header.opcode == .continuation and header.fin) {
            self.recv_fragment_opcode = null;
        }
    }
};

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

fn applyMask(bytes: []u8, mask: [4]u8, start_offset: usize) void {
    if (bytes.len == 0) return;

    const offset = start_offset & 3;
    var repeated_mask_bytes: [8]u8 = undefined;
    for (0..8) |i| {
        repeated_mask_bytes[i] = mask[(offset + i) & 3];
    }
    const repeated_mask = std.mem.readInt(u64, repeated_mask_bytes[0..], .little);

    var i: usize = 0;
    while (i + 8 <= bytes.len) : (i += 8) {
        const value = std.mem.readInt(u64, bytes[i..][0..8], .little);
        std.mem.writeInt(u64, bytes[i..][0..8], value ^ repeated_mask, .little);
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
    mask: [4]u8,
) !void {
    const first: u8 = @as(u8, @intFromEnum(opcode)) | if (fin) @as(u8, 0x80) else 0;
    try out.append(a, first);

    if (payload.len <= 125) {
        try out.append(a, @as(u8, @intCast(payload.len)) | if (masked) @as(u8, 0x80) else 0);
    } else if (payload.len <= std.math.maxInt(u16)) {
        try out.append(a, 126 | if (masked) @as(u8, 0x80) else 0);
        var ext: [2]u8 = undefined;
        std.mem.writeInt(u16, ext[0..], @as(u16, @intCast(payload.len)), .big);
        try out.appendSlice(a, ext[0..]);
    } else {
        try out.append(a, 127 | if (masked) @as(u8, 0x80) else 0);
        var ext: [8]u8 = undefined;
        std.mem.writeInt(u64, ext[0..], payload.len, .big);
        try out.appendSlice(a, ext[0..]);
    }

    if (masked) {
        try out.appendSlice(a, mask[0..]);
        const start = out.items.len;
        try out.resize(a, start + payload.len);
        @memcpy(out.items[start..][0..payload.len], payload);
        applyMask(out.items[start..][0..payload.len], mask, 0);
    } else {
        try out.appendSlice(a, payload);
    }
}

fn appendMalformedHeader(out: *std.ArrayList(u8), a: std.mem.Allocator, first: u8, second: u8) !void {
    try out.append(a, first);
    try out.append(a, second);
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
    var conn = Conn.init(&reader, &writer, .{});

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
    var conn = Conn.init(&reader, &writer, .{});

    try std.testing.expectError(error.MaskBitInvalid, conn.beginFrame());
}

test "writeFrame writes unmasked server frame" {
    var out: [64]u8 = undefined;
    var writer = Io.Writer.fixed(out[0..]);
    var reader = Io.Reader.fixed(""[0..]);
    var conn = Conn.init(&reader, &writer, .{ .role = .server });

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
    var conn = Conn.init(&reader, &writer, .{
        .role = .server,
        .auto_pong = true,
    });

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
    var conn = Conn.init(&reader, &writer, .{ .role = .client });

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
    var conn = Conn.init(&reader, &writer, .{});

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
    var conn1 = Conn.init(&reader1, &writer1, .{ .role = .client });
    var conn2 = Conn.init(&reader2, &writer2, .{ .role = .client });

    try conn1.writeBinary("ab");
    try conn2.writeBinary("ab");
    try std.testing.expect(!std.mem.eql(u8, out1[2..6], out2[2..6]));
}

test "flush forwards to writer" {
    var out: [16]u8 = undefined;
    var writer = Io.Writer.fixed(out[0..]);
    var reader = Io.Reader.fixed(""[0..]);
    var conn = Conn.init(&reader, &writer, .{});
    try conn.flush();
}

test "beginFrame rejects reserved bits and unknown opcode" {
    {
        const wire = [_]u8{ 0xC1, 0x80, 1, 2, 3, 4 };
        var reader = Io.Reader.fixed(wire[0..]);
        var writer = Io.Writer.fixed(&[_]u8{});
        var conn = Conn.init(&reader, &writer, .{});
        try std.testing.expectError(error.ReservedBitsSet, conn.beginFrame());
    }
    {
        const wire = [_]u8{ 0x83, 0x80, 1, 2, 3, 4 };
        var reader = Io.Reader.fixed(wire[0..]);
        var writer = Io.Writer.fixed(&[_]u8{});
        var conn = Conn.init(&reader, &writer, .{});
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
        var writer = Io.Writer.fixed(&[_]u8{});
        var conn = Conn.init(&reader, &writer, .{});
        try std.testing.expectError(error.InvalidFrameLength, conn.beginFrame());
    }
    {
        var wire: std.ArrayList(u8) = .empty;
        defer wire.deinit(std.testing.allocator);
        try appendTestFrame(&wire, std.testing.allocator, .binary, true, true, "1234", .{ 1, 2, 3, 4 });
        var reader = Io.Reader.fixed(wire.items);
        var writer = Io.Writer.fixed(&[_]u8{});
        var conn = Conn.init(&reader, &writer, .{ .max_frame_payload_len = 3 });
        try std.testing.expectError(error.FrameTooLarge, conn.beginFrame());
    }
}

test "beginFrame enforces control frame rules and continuation sequencing" {
    {
        var wire: std.ArrayList(u8) = .empty;
        defer wire.deinit(std.testing.allocator);
        try appendTestFrame(&wire, std.testing.allocator, .ping, false, true, "", .{ 1, 2, 3, 4 });
        var reader = Io.Reader.fixed(wire.items);
        var writer = Io.Writer.fixed(&[_]u8{});
        var conn = Conn.init(&reader, &writer, .{});
        try std.testing.expectError(error.ControlFrameFragmented, conn.beginFrame());
    }
    {
        var payload: [126]u8 = undefined;
        @memset(payload[0..], 'x');
        var wire: std.ArrayList(u8) = .empty;
        defer wire.deinit(std.testing.allocator);
        try appendTestFrame(&wire, std.testing.allocator, .ping, true, true, payload[0..], .{ 1, 2, 3, 4 });
        var reader = Io.Reader.fixed(wire.items);
        var writer = Io.Writer.fixed(&[_]u8{});
        var conn = Conn.init(&reader, &writer, .{});
        try std.testing.expectError(error.ControlFrameTooLarge, conn.beginFrame());
    }
    {
        var wire: std.ArrayList(u8) = .empty;
        defer wire.deinit(std.testing.allocator);
        try appendTestFrame(&wire, std.testing.allocator, .continuation, true, true, "x", .{ 1, 2, 3, 4 });
        var reader = Io.Reader.fixed(wire.items);
        var writer = Io.Writer.fixed(&[_]u8{});
        var conn = Conn.init(&reader, &writer, .{});
        try std.testing.expectError(error.UnexpectedContinuation, conn.beginFrame());
    }
    {
        var wire: std.ArrayList(u8) = .empty;
        defer wire.deinit(std.testing.allocator);
        try appendTestFrame(&wire, std.testing.allocator, .text, false, true, "hel", .{ 1, 2, 3, 4 });
        try appendTestFrame(&wire, std.testing.allocator, .binary, true, true, "bad", .{ 5, 6, 7, 8 });
        var reader = Io.Reader.fixed(wire.items);
        var writer = Io.Writer.fixed(&[_]u8{});
        var conn = Conn.init(&reader, &writer, .{});
        _ = try conn.beginFrame();
        try conn.discardFrame();
        try std.testing.expectError(error.ExpectedContinuation, conn.beginFrame());
    }
}

test "beginFrame supports client role and extended lengths" {
    {
        const wire = [_]u8{ 0x82, 0x02, 'o', 'k' };
        var reader = Io.Reader.fixed(wire[0..]);
        var writer = Io.Writer.fixed(&[_]u8{});
        var conn = Conn.init(&reader, &writer, .{ .role = .client });
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
        var writer = Io.Writer.fixed(&[_]u8{});
        var conn = Conn.init(&reader, &writer, .{ .role = .client });
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
        var writer = Io.Writer.fixed(&[_]u8{});
        var conn = Conn.init(&reader, &writer, .{ .role = .client });
        const header = try conn.beginFrame();
        try std.testing.expectEqual(@as(u64, 65536), header.payload_len);
    }
}

test "readFrameChunk and readFrameAll enforce active frame semantics" {
    var reader = Io.Reader.fixed(""[0..]);
    var writer = Io.Writer.fixed(&[_]u8{});
    var conn = Conn.init(&reader, &writer, .{});
    var tmp: [4]u8 = undefined;

    try std.testing.expectError(error.NoActiveFrame, conn.readFrameChunk(tmp[0..]));
    try std.testing.expectError(error.NoActiveFrame, conn.readFrameAll(tmp[0..]));
    try std.testing.expectError(error.NoActiveFrame, conn.discardFrame());
}

test "readFrameChunk zero length does not consume payload and discardFrame drains current frame" {
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(std.testing.allocator);
    try appendTestFrame(&wire, std.testing.allocator, .binary, true, true, "abc", .{ 1, 2, 3, 4 });
    try appendTestFrame(&wire, std.testing.allocator, .text, true, true, "z", .{ 5, 6, 7, 8 });

    var reader = Io.Reader.fixed(wire.items);
    var writer = Io.Writer.fixed(&[_]u8{});
    var conn = Conn.init(&reader, &writer, .{});

    _ = try conn.beginFrame();
    var empty: [0]u8 = .{};
    try std.testing.expectEqual(@as(usize, 0), (try conn.readFrameChunk(empty[0..])).len);

    var buf: [3]u8 = undefined;
    try std.testing.expectEqualStrings("abc", try conn.readFrameAll(buf[0..]));

    const next = try conn.readFrame(buf[0..]);
    try std.testing.expectEqual(Opcode.text, next.header.opcode);
    try std.testing.expectEqualStrings("z", next.payload);
}

test "readFrameAll rejects destination that is too small and zero payload frames work" {
    {
        var wire: std.ArrayList(u8) = .empty;
        defer wire.deinit(std.testing.allocator);
        try appendTestFrame(&wire, std.testing.allocator, .binary, true, true, "abcd", .{ 1, 2, 3, 4 });
        var reader = Io.Reader.fixed(wire.items);
        var writer = Io.Writer.fixed(&[_]u8{});
        var conn = Conn.init(&reader, &writer, .{});
        _ = try conn.beginFrame();
        var buf: [3]u8 = undefined;
        try std.testing.expectError(error.MessageTooLarge, conn.readFrameAll(buf[0..]));
    }
    {
        var wire: std.ArrayList(u8) = .empty;
        defer wire.deinit(std.testing.allocator);
        try appendTestFrame(&wire, std.testing.allocator, .pong, true, true, "", .{ 1, 2, 3, 4 });
        var reader = Io.Reader.fixed(wire.items);
        var writer = Io.Writer.fixed(&[_]u8{});
        var conn = Conn.init(&reader, &writer, .{});
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
        var conn = Conn.init(&reader, &writer, .{ .auto_pong = false });
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
        var conn = Conn.init(&reader, &writer, .{});
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
        var conn = Conn.init(&reader, &writer, .{ .auto_reply_close = false });
        var buf: [1]u8 = undefined;
        try std.testing.expectError(error.ConnectionClosed, conn.readMessage(buf[0..]));
        try std.testing.expect(conn.close_received);
        try std.testing.expect(!conn.close_sent);
        try std.testing.expectEqual(@as(usize, 0), writer.end);
    }
}

test "readMessage enforces utf8 and message size limits" {
    {
        const invalid_utf8 = [_]u8{ 0xC3, 0x28 };
        var wire: std.ArrayList(u8) = .empty;
        defer wire.deinit(std.testing.allocator);
        try appendTestFrame(&wire, std.testing.allocator, .text, true, true, invalid_utf8[0..], .{ 1, 2, 3, 4 });
        var reader = Io.Reader.fixed(wire.items);
        var writer = Io.Writer.fixed(&[_]u8{});
        var conn = Conn.init(&reader, &writer, .{});
        var buf: [8]u8 = undefined;
        try std.testing.expectError(error.InvalidUtf8, conn.readMessage(buf[0..]));
    }
    {
        var wire: std.ArrayList(u8) = .empty;
        defer wire.deinit(std.testing.allocator);
        try appendTestFrame(&wire, std.testing.allocator, .text, false, true, "abc", .{ 1, 2, 3, 4 });
        try appendTestFrame(&wire, std.testing.allocator, .continuation, true, true, "de", .{ 5, 6, 7, 8 });
        var reader = Io.Reader.fixed(wire.items);
        var writer = Io.Writer.fixed(&[_]u8{});
        var conn = Conn.init(&reader, &writer, .{ .max_message_payload_len = 4 });
        var buf: [8]u8 = undefined;
        try std.testing.expectError(error.MessageTooLarge, conn.readMessage(buf[0..]));
    }
}

test "writeFrame supports extended lengths and sequencing rules" {
    {
        var payload: [126]u8 = undefined;
        @memset(payload[0..], 'a');
        var out: [256]u8 = undefined;
        var writer = Io.Writer.fixed(out[0..]);
        var reader = Io.Reader.fixed(""[0..]);
        var conn = Conn.init(&reader, &writer, .{ .role = .server });
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
        var conn = Conn.init(&reader, &writer, .{ .role = .server });
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
        var conn = Conn.init(&reader, &writer, .{});
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
        var conn = Conn.init(&reader, &writer, .{});
        try std.testing.expectError(error.UnexpectedContinuationWrite, conn.writeFrame(.continuation, "x", true));
        try std.testing.expectError(error.ControlFrameFragmented, conn.writeFrame(.ping, "", false));
    }
}

test "writeText writePing writePong and writeClose validate inputs" {
    {
        const invalid_utf8 = [_]u8{ 0xC3, 0x28 };
        var out: [16]u8 = undefined;
        var writer = Io.Writer.fixed(out[0..]);
        var reader = Io.Reader.fixed(""[0..]);
        var conn = Conn.init(&reader, &writer, .{});
        try std.testing.expectError(error.InvalidUtf8, conn.writeText(invalid_utf8[0..]));
    }
    {
        var payload: [126]u8 = undefined;
        @memset(payload[0..], 'x');
        var out: [16]u8 = undefined;
        var writer = Io.Writer.fixed(out[0..]);
        var reader = Io.Reader.fixed(""[0..]);
        var conn = Conn.init(&reader, &writer, .{});
        try std.testing.expectError(error.ControlFrameTooLarge, conn.writePing(payload[0..]));
        try std.testing.expectError(error.ControlFrameTooLarge, conn.writePong(payload[0..]));
    }
    {
        var out: [256]u8 = undefined;
        var writer = Io.Writer.fixed(out[0..]);
        var reader = Io.Reader.fixed(""[0..]);
        var conn = Conn.init(&reader, &writer, .{});
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
        const payload = [_]u8{ 0x03, 0xE8, 0xC3, 0x28 };
        const close = try parseClosePayload(payload[0..], false);
        try std.testing.expectEqual(@as(?u16, 1000), close.code);
        try std.testing.expectEqualSlices(u8, &.{ 0xC3, 0x28 }, close.reason);
    }
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
