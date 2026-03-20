const std = @import("std");

const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("zlib.h");
});

pub const DeflateError = error{
    OutOfMemory,
    DeflateFailed,
};

pub const InflateError = error{
    OutOfMemory,
    InflateFailed,
    MessageTooLarge,
};

pub const sync_flush = c.Z_SYNC_FLUSH;
pub const full_flush = c.Z_FULL_FLUSH;

fn zalloc(_: ?*anyopaque, items: c_uint, size: c_uint) callconv(.c) ?*anyopaque {
    const total = @as(usize, items) * @as(usize, size);
    return c.malloc(total);
}

fn zfree(_: ?*anyopaque, ptr: ?*anyopaque) callconv(.c) void {
    c.free(ptr);
}

pub fn deflateMessage(
    allocator: std.mem.Allocator,
    payload: []const u8,
    level: i32,
    flush_mode: i32,
) DeflateError![]u8 {
    var stream: c.z_stream = std.mem.zeroes(c.z_stream);
    stream.zalloc = zalloc;
    stream.zfree = zfree;
    const init_rc = c.deflateInit2_(
        &stream,
        @intCast(level),
        c.Z_DEFLATED,
        -15,
        c.MAX_MEM_LEVEL,
        c.Z_DEFAULT_STRATEGY,
        c.ZLIB_VERSION,
        @sizeOf(c.z_stream),
    );
    if (init_rc != c.Z_OK) return error.DeflateFailed;
    defer _ = c.deflateEnd(&stream);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    stream.next_in = if (payload.len == 0) null else @ptrCast(@constCast(payload.ptr));
    stream.avail_in = @as(c_uint, @intCast(payload.len));

    var chunk: [1024]u8 = undefined;
    while (true) {
        stream.next_out = @ptrCast(&chunk[0]);
        stream.avail_out = @as(c_uint, @intCast(chunk.len));

        const rc = c.deflate(&stream, @intCast(flush_mode));
        if (rc != c.Z_OK) return error.DeflateFailed;

        const produced = chunk.len - stream.avail_out;
        out.appendSlice(allocator, chunk[0..produced]) catch return error.OutOfMemory;

        if (stream.avail_in == 0 and stream.avail_out != 0) break;
    }

    if (!std.mem.endsWith(u8, out.items, &.{ 0x00, 0x00, 0xff, 0xff })) {
        return error.DeflateFailed;
    }
    out.shrinkRetainingCapacity(out.items.len - 4);
    return out.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

pub fn inflateMessage(
    allocator: std.mem.Allocator,
    compressed_payload: []const u8,
    dest: []u8,
) InflateError![]u8 {
    _ = allocator;

    var stream: c.z_stream = std.mem.zeroes(c.z_stream);
    stream.zalloc = zalloc;
    stream.zfree = zfree;
    const init_rc = c.inflateInit2_(&stream, -15, c.ZLIB_VERSION, @sizeOf(c.z_stream));
    if (init_rc != c.Z_OK) return error.InflateFailed;
    defer _ = c.inflateEnd(&stream);

    stream.next_in = if (compressed_payload.len == 0) null else @ptrCast(@constCast(compressed_payload.ptr));
    stream.avail_in = @as(c_uint, @intCast(compressed_payload.len));
    stream.next_out = if (dest.len == 0) null else @ptrCast(dest.ptr);
    stream.avail_out = @as(c_uint, @intCast(dest.len));

    while (true) {
        const prev_in = stream.avail_in;
        const prev_out = stream.avail_out;
        const rc = c.inflate(&stream, c.Z_SYNC_FLUSH);
        switch (rc) {
            c.Z_STREAM_END => return dest[0..stream.total_out],
            c.Z_OK => {
                if (stream.avail_in == 0) return dest[0..stream.total_out];
                if (stream.avail_out == 0) return error.MessageTooLarge;
            },
            c.Z_BUF_ERROR => {
                if (stream.avail_in == 0) return dest[0..stream.total_out];
                if (stream.avail_out == 0) return error.MessageTooLarge;
            },
            else => return error.InflateFailed,
        }

        if (stream.avail_in == prev_in and stream.avail_out == prev_out) {
            return error.InflateFailed;
        }
    }
}

test "zlib permessage-deflate helpers roundtrip sync and full flush payloads" {
    const payload = "zwebsocket interop text payload with enough repetition to exercise permessage-deflate";

    inline for (.{ sync_flush, full_flush }) |flush_mode| {
        const compressed = try deflateMessage(std.testing.allocator, payload, 1, flush_mode);
        defer std.testing.allocator.free(compressed);

        var out: [256]u8 = undefined;
        const inflated = try inflateMessage(std.testing.allocator, compressed, out[0..]);
        try std.testing.expectEqualStrings(payload, inflated);
    }
}
