const std = @import("std");
const zws = @import("root.zig");
const test_support = @import("test_support.zig");

const Io = std.Io;

fn fuzzMalformedFrames(_: void, smith: *std.testing.Smith) !void {
    var input_buf: [96]u8 = undefined;
    const len = smith.slice(&input_buf);
    var reader = Io.Reader.fixed(input_buf[0..len]);
    var sink: [256]u8 = undefined;
    var writer = Io.Writer.fixed(sink[0..]);
    var conn = zws.Conn.Default.init(&reader, &writer, .{});

    var steps: usize = 0;
    while (steps < 8) : (steps += 1) {
        const before_seek = reader.seek;
        _ = conn.beginFrame() catch break;
        conn.discardFrame() catch break;
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
        var client = zws.Conn.Client.init(&empty_reader, &client_writer, .{});
        if (is_text) {
            try client.writeText(payload);
        } else {
            try client.writeBinary(payload);
        }

        var server_reader = Io.Reader.fixed(out[0..client_writer.end]);
        var sink: [0]u8 = .{};
        var server_writer = Io.Writer.fixed(sink[0..]);
        var server = zws.Conn.Server.init(&server_reader, &server_writer, .{});
        const frame = try server.readFrame(payload);

        try std.testing.expectEqual(if (is_text) zws.Protocol.Opcode.text else zws.Protocol.Opcode.binary, frame.header.opcode);
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
        try test_support.appendTestFrame(zws.Protocol.Opcode, &wire, std.testing.allocator, .binary, split_at == total_len, true, payload[0..split_at], .{ 1, 2, 3, 4 });
        if (split_at != total_len) {
            try test_support.appendTestFrame(zws.Protocol.Opcode, &wire, std.testing.allocator, .continuation, true, true, payload[split_at..], .{ 5, 6, 7, 8 });
        }

        var reader = Io.Reader.fixed(wire.items);
        var sink: [0]u8 = .{};
        var writer = Io.Writer.fixed(sink[0..]);
        var conn = zws.Conn.Server.init(&reader, &writer, .{});
        const message = try conn.readMessage(payload);

        try std.testing.expectEqual(zws.Protocol.MessageOpcode.binary, message.opcode);
        try std.testing.expectEqualSlices(u8, payload, message.payload);
    }
}
