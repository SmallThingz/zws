const std = @import("std");
const zws = @import("root.zig");
const test_support = @import("test_support.zig");

const Io = std.Io;

test "fuzz malformed frame streams do not panic" {
    const Harness = struct {
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
    };
    try std.testing.fuzz({}, Harness.fuzzMalformedFrames, .{
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

test "property random fragmented messages with interleaved pings preserve payload and pong order" {
    var prng = std.Random.DefaultPrng.init(0x0ddc_0ffe_e15e_beef);
    const random = prng.random();
    const ping_cases = [_][]const u8{ "", "!", "ok", "1234" };

    for (0..96) |_| {
        const is_text = random.boolean();
        const total_len = random.uintAtMost(usize, 96);
        const max_fragments = if (total_len == 0) @as(usize, 1) else @min(@as(usize, 4), total_len);
        const fragment_count = if (total_len == 0) @as(usize, 1) else random.uintAtMost(usize, max_fragments - 1) + 1;
        const payload = try std.testing.allocator.alloc(u8, total_len);
        defer std.testing.allocator.free(payload);
        if (is_text) {
            for (payload, 0..) |*b, i| b.* = @intCast('a' + @as(u8, @intCast(i % 26)));
        } else {
            random.bytes(payload);
        }

        var wire: std.ArrayList(u8) = .empty;
        defer wire.deinit(std.testing.allocator);
        var expected_ping_idx: [6]usize = undefined;
        var expected_ping_len: usize = 0;
        var offset: usize = 0;

        // Generate valid fragmented messages, then inject ping frames between
        // fragments to stress message assembly plus auto-pong ordering.
        for (0..fragment_count) |frag_idx| {
            const remaining = total_len - offset;
            const last = frag_idx + 1 == fragment_count;
            const frag_len = if (last)
                remaining
            else blk: {
                const remaining_fragments = fragment_count - frag_idx;
                const max_here = remaining - (remaining_fragments - 1);
                break :blk random.uintAtMost(usize, max_here - 1) + 1;
            };
            const opcode: zws.Protocol.Opcode = if (frag_idx == 0)
                (if (is_text) .text else .binary)
            else
                .continuation;
            try test_support.appendTestFrame(
                zws.Protocol.Opcode,
                &wire,
                std.testing.allocator,
                opcode,
                last,
                true,
                payload[offset .. offset + frag_len],
                .{ @intCast(1 + frag_idx), @intCast(2 + frag_idx), @intCast(3 + frag_idx), @intCast(4 + frag_idx) },
            );
            offset += frag_len;

            if (!last and random.boolean()) {
                const ping_idx = random.uintAtMost(usize, ping_cases.len - 1);
                try test_support.appendTestFrame(
                    zws.Protocol.Opcode,
                    &wire,
                    std.testing.allocator,
                    .ping,
                    true,
                    true,
                    ping_cases[ping_idx],
                    .{ @intCast(5 + frag_idx), @intCast(6 + frag_idx), @intCast(7 + frag_idx), @intCast(8 + frag_idx) },
                );
                expected_ping_idx[expected_ping_len] = ping_idx;
                expected_ping_len += 1;
            }
        }

        var reader = Io.Reader.fixed(wire.items);
        var out: [128]u8 = undefined;
        var writer = Io.Writer.fixed(out[0..]);
        var server = zws.Conn.Server.init(&reader, &writer, .{});
        var message_buf: [128]u8 = undefined;

        const message = try server.readMessage(message_buf[0..]);
        try std.testing.expectEqual(if (is_text) zws.Protocol.MessageOpcode.text else zws.Protocol.MessageOpcode.binary, message.opcode);
        try std.testing.expectEqualSlices(u8, payload, message.payload);

        var out_reader = Io.Reader.fixed(out[0..writer.end]);
        var sink: [0]u8 = .{};
        var out_writer = Io.Writer.fixed(sink[0..]);
        var client = zws.Conn.Client.init(&out_reader, &out_writer, .{});
        var frame_buf: [8]u8 = undefined;
        for (expected_ping_idx[0..expected_ping_len]) |ping_idx| {
            const pong = try client.readFrame(frame_buf[0..]);
            try std.testing.expectEqual(zws.Protocol.Opcode.pong, pong.header.opcode);
            try std.testing.expectEqualStrings(ping_cases[ping_idx], pong.payload);
        }
        try std.testing.expectError(error.EndOfStream, client.readFrame(frame_buf[0..]));
    }
}

test "property random permessage-deflate offer sets preserve alternatives and first-offer rules" {
    const OfferCase = struct {
        text: []const u8,
        parsed: zws.Extensions.PerMessageDeflate,
    };
    const offer_cases = [_]OfferCase{
        .{
            .text = "permessage-deflate",
            .parsed = .{
                .server_no_context_takeover = false,
                .client_no_context_takeover = false,
            },
        },
        .{
            .text = "permessage-deflate; client_no_context_takeover",
            .parsed = .{
                .server_no_context_takeover = false,
                .client_no_context_takeover = true,
            },
        },
        .{
            .text = "permessage-deflate; server_no_context_takeover",
            .parsed = .{
                .server_no_context_takeover = true,
                .client_no_context_takeover = false,
            },
        },
        .{
            .text = "permessage-deflate; server_no_context_takeover; client_no_context_takeover",
            .parsed = .{
                .server_no_context_takeover = true,
                .client_no_context_takeover = true,
            },
        },
        .{
            .text = "permessage-deflate; client_max_window_bits",
            .parsed = .{
                .server_no_context_takeover = false,
                .client_no_context_takeover = false,
            },
        },
        .{
            .text = "permessage-deflate; server_max_window_bits=12; client_no_context_takeover",
            .parsed = .{
                .server_no_context_takeover = false,
                .client_no_context_takeover = true,
            },
        },
    };
    const noise_cases = [_][]const u8{
        "x-test",
        "foo; bar=1",
        "x-webkit-deflate-frame",
    };

    var prng = std.Random.DefaultPrng.init(0xa11e_4299_55aa_7711);
    const random = prng.random();

    for (0..96) |_| {
        var header: std.ArrayList(u8) = .empty;
        defer header.deinit(std.testing.allocator);
        var expected: [6]zws.Extensions.PerMessageDeflate = undefined;
        var expected_len: usize = 0;

        const part_count = random.uintAtMost(usize, 6);
        for (0..part_count) |idx| {
            if (idx != 0) try header.appendSlice(std.testing.allocator, ", ");
            if (random.boolean()) {
                const offer_idx = random.uintAtMost(usize, offer_cases.len - 1);
                try header.appendSlice(std.testing.allocator, offer_cases[offer_idx].text);
                expected[expected_len] = offer_cases[offer_idx].parsed;
                expected_len += 1;
            } else {
                const noise_idx = random.uintAtMost(usize, noise_cases.len - 1);
                try header.appendSlice(std.testing.allocator, noise_cases[noise_idx]);
            }
        }

        var offers = zws.Extensions.parsePerMessageDeflate(header.items);
        for (expected[0..expected_len]) |want| {
            const got = (try offers.next()).?;
            try std.testing.expectEqualDeep(want, got);
        }
        try std.testing.expectEqual(@as(?zws.Extensions.PerMessageDeflate, null), try offers.next());

        if (expected_len == 0) {
            try std.testing.expectEqual(@as(?zws.Extensions.PerMessageDeflate, null), try zws.Extensions.parsePerMessageDeflateFirst(header.items));
        } else if (expected_len == 1) {
            try std.testing.expectEqualDeep(expected[0], (try zws.Extensions.parsePerMessageDeflateFirst(header.items)).?);
        } else {
            try std.testing.expectError(error.DuplicateExtensionOffer, zws.Extensions.parsePerMessageDeflateFirst(header.items));
        }
    }
}
