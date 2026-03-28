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
