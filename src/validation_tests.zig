const std = @import("std");
const zws = @import("root.zig");

const Io = std.Io;

fn appendTestFrame(
    out: *std.ArrayList(u8),
    a: std.mem.Allocator,
    opcode: zws.Opcode,
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
        for (out.items[start..][0..payload.len], 0..) |*b, i| {
            b.* ^= mask[i & 3];
        }
    } else {
        try out.appendSlice(a, payload);
    }
}

fn fuzzMalformedFrames(_: void, smith: *std.testing.Smith) !void {
    var input_buf: [96]u8 = undefined;
    const len = smith.slice(&input_buf);
    var reader = Io.Reader.fixed(input_buf[0..len]);
    var sink: [256]u8 = undefined;
    var writer = Io.Writer.fixed(sink[0..]);
    var conn = zws.Conn.init(&reader, &writer, .{});
    var scratch: [128]u8 = undefined;

    var steps: usize = 0;
    while (steps < 8) : (steps += 1) {
        const before_seek = reader.seek;
        _ = conn.echoFrame(scratch[0..]) catch break;
        if (reader.seek == before_seek and !conn.recv_active) break;
    }
}

test "fuzz malformed frame streams do not panic" {
    try std.testing.fuzz({}, fuzzMalformedFrames, .{
        .corpus = &.{
            "",
            "\x81",
            "\x81\x80\x01\x02\x03\x04",
            "\xC1\x80\x01\x02\x03\x04",
            "\x82\xFF\x7F\xFF\xFF\xFF\xFF\xFF\xFF\xFF\x01\x02\x03\x04",
            "\x89\x80\x01\x02\x03\x04",
        },
    });
}

test "property random client/server frame roundtrips preserve payload and opcode" {
    var prng = std.Random.DefaultPrng.init(0x5eed_cafe_dead_beef);
    const random = prng.random();

    for (0..128) |_| {
        const is_text = random.boolean();
        const payload_len = random.uintAtMost(usize, 256);
        const payload = try std.testing.allocator.alloc(u8, payload_len);
        defer std.testing.allocator.free(payload);
        if (is_text) {
            for (payload, 0..) |*b, i| b.* = @intCast('a' + @as(u8, @intCast(i % 26)));
        } else {
            random.bytes(payload);
        }

        var out: [512]u8 = undefined;
        var client_writer = Io.Writer.fixed(out[0..]);
        var empty_reader = Io.Reader.fixed(""[0..]);
        var client = zws.ClientConn.init(&empty_reader, &client_writer, .{});
        if (is_text) {
            try client.writeText(payload);
        } else {
            try client.writeBinary(payload);
        }

        var server_reader = Io.Reader.fixed(out[0..client_writer.end]);
        var sink: [0]u8 = .{};
        var server_writer = Io.Writer.fixed(sink[0..]);
        var server = zws.ServerConn.init(&server_reader, &server_writer, .{});
        const frame = try server.readFrame(payload);

        try std.testing.expectEqual(if (is_text) zws.Opcode.text else zws.Opcode.binary, frame.header.opcode);
        try std.testing.expectEqualStrings(payload, frame.payload);
    }
}

test "property random fragmented masked reads reconstruct message bytes" {
    var prng = std.Random.DefaultPrng.init(0x1234_5678_9abc_def0);
    const random = prng.random();

    for (0..96) |_| {
        const total_len = random.uintAtMost(usize, 128);
        const split_at = if (total_len == 0) 0 else random.uintAtMost(usize, total_len);
        const payload = try std.testing.allocator.alloc(u8, total_len);
        defer std.testing.allocator.free(payload);
        random.bytes(payload);

        var wire: std.ArrayList(u8) = .empty;
        defer wire.deinit(std.testing.allocator);
        try appendTestFrame(&wire, std.testing.allocator, .binary, split_at == total_len, true, payload[0..split_at], .{ 1, 2, 3, 4 });
        if (split_at != total_len) {
            try appendTestFrame(&wire, std.testing.allocator, .continuation, true, true, payload[split_at..], .{ 5, 6, 7, 8 });
        }

        var reader = Io.Reader.fixed(wire.items);
        var sink: [0]u8 = .{};
        var writer = Io.Writer.fixed(sink[0..]);
        var conn = zws.ServerConn.init(&reader, &writer, .{});
        const message = try conn.readMessage(payload);

        try std.testing.expectEqual(zws.MessageOpcode.binary, message.opcode);
        try std.testing.expectEqualSlices(u8, payload, message.payload);
    }
}
