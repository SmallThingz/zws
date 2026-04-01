const std = @import("std");

pub fn appendTestFrame(
    comptime Opcode: type,
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    opcode: Opcode,
    fin: bool,
    masked: bool,
    payload: []const u8,
    mask: [4]u8,
) !void {
    const first: u8 = @as(u8, @intFromEnum(opcode)) | if (fin) @as(u8, 0x80) else 0;
    try out.append(allocator, first);

    if (payload.len <= 125) {
        try out.append(allocator, @as(u8, @intCast(payload.len)) | if (masked) @as(u8, 0x80) else 0);
    } else if (payload.len <= std.math.maxInt(u16)) {
        try out.append(allocator, 126 | if (masked) @as(u8, 0x80) else 0);
        var ext: [2]u8 = undefined;
        std.mem.writeInt(u16, ext[0..], @as(u16, @intCast(payload.len)), .big);
        try out.appendSlice(allocator, ext[0..]);
    } else {
        try out.append(allocator, 127 | if (masked) @as(u8, 0x80) else 0);
        var ext: [8]u8 = undefined;
        std.mem.writeInt(u64, ext[0..], payload.len, .big);
        try out.appendSlice(allocator, ext[0..]);
    }

    if (!masked) {
        try out.appendSlice(allocator, payload);
        return;
    }

    try out.appendSlice(allocator, mask[0..]);
    const start = out.items.len;
    try out.resize(allocator, start + payload.len);
    @memcpy(out.items[start..][0..payload.len], payload);
    for (out.items[start..][0..payload.len], 0..) |*b, i| {
        b.* ^= mask[i & 3];
    }
}

const TestOpcode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
};

test "appendTestFrame writes unmasked short and extended payload frames" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);

    try appendTestFrame(TestOpcode, &out, std.testing.allocator, .text, true, false, "hi", .{ 1, 2, 3, 4 });
    try std.testing.expectEqualSlices(u8, &.{ 0x81, 0x02, 'h', 'i' }, out.items);

    out.clearRetainingCapacity();
    var payload_126: [126]u8 = undefined;
    @memset(&payload_126, 'a');
    try appendTestFrame(TestOpcode, &out, std.testing.allocator, .binary, false, false, payload_126[0..], .{ 1, 2, 3, 4 });
    try std.testing.expectEqual(@as(u8, 0x02), out.items[0]);
    try std.testing.expectEqual(@as(u8, 126), out.items[1]);
    try std.testing.expectEqual(@as(u8, 0), out.items[2]);
    try std.testing.expectEqual(@as(u8, 126), out.items[3]);
    try std.testing.expectEqual(@as(usize, 4 + payload_126.len), out.items.len);
}

test "appendTestFrame masks payload bytes and writes 64-bit lengths" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);

    var payload_big: [65536]u8 = undefined;
    for (&payload_big, 0..) |*b, i| b.* = @truncate(i);
    const mask = [_]u8{ 0x11, 0x22, 0x33, 0x44 };
    try appendTestFrame(TestOpcode, &out, std.testing.allocator, .binary, true, true, payload_big[0..], mask);

    try std.testing.expectEqual(@as(u8, 0x82), out.items[0]);
    try std.testing.expectEqual(@as(u8, 0xFF), out.items[1]);
    try std.testing.expectEqual(@as(u64, payload_big.len), std.mem.readInt(u64, out.items[2..10], .big));
    try std.testing.expectEqualSlices(u8, mask[0..], out.items[10..14]);
    try std.testing.expectEqual(payload_big[0] ^ mask[0], out.items[14]);
    try std.testing.expectEqual(payload_big[1] ^ mask[1], out.items[15]);
    try std.testing.expectEqual(payload_big[2] ^ mask[2], out.items[16]);
    try std.testing.expectEqual(payload_big[3] ^ mask[3], out.items[17]);
}

test "appendTestFrame writes masked zero-length continuation frames without payload bytes" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);

    const mask = [_]u8{ 0xaa, 0xbb, 0xcc, 0xdd };
    try appendTestFrame(TestOpcode, &out, std.testing.allocator, .continuation, false, true, "", mask);

    try std.testing.expectEqual(@as(u8, 0x00), out.items[0]);
    try std.testing.expectEqual(@as(u8, 0x80), out.items[1]);
    try std.testing.expectEqualSlices(u8, mask[0..], out.items[2..6]);
    try std.testing.expectEqual(@as(usize, 6), out.items.len);
}
