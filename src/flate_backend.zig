const std = @import("std");
const flate = std.compress.flate;

pub const DeflateError = error{
    OutOfMemory,
    DeflateFailed,
    CounterTooLarge,
};

pub const InflateError = error{
    OutOfMemory,
    InflateFailed,
    MessageTooLarge,
    CounterTooLarge,
};

/// Backend-local flush mode identifiers kept for compatibility with conn.zig.
pub const sync_flush: i32 = 0;
pub const full_flush: i32 = 1;

fn flateCounter(n: usize) error{CounterTooLarge}!u32 {
    return std.math.cast(u32, n) orelse error.CounterTooLarge;
}

fn optionsFromLevel(level: i32) flate.Compress.Options {
    return switch (level) {
        std.math.minInt(i32)...1 => .fastest,
        2 => .level_2,
        3 => .level_3,
        4 => .level_4,
        5 => .level_5,
        6 => .level_6,
        7 => .level_7,
        8 => .level_8,
        else => .best,
    };
}

pub fn deflateMessage(
    allocator: std.mem.Allocator,
    payload: []const u8,
    level: i32,
    flush_mode: i32,
) DeflateError![]u8 {
    switch (flush_mode) {
        sync_flush, full_flush => {},
        else => return error.DeflateFailed,
    }
    _ = flateCounter(payload.len) catch return error.CounterTooLarge;

    const initial_capacity = @max(@as(usize, 256), payload.len +| (payload.len / 8) + 64);
    var out = std.Io.Writer.Allocating.initCapacity(allocator, initial_capacity) catch return error.OutOfMemory;
    errdefer out.deinit();

    var compress_buf: [flate.max_window_len]u8 = undefined;
    var compressor = flate.Compress.init(
        &out.writer,
        compress_buf[0..],
        .raw,
        optionsFromLevel(level),
    ) catch return error.DeflateFailed;

    compressor.writer.writeAll(payload) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
    };
    compressor.finish() catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
    };

    return out.toOwnedSlice() catch return error.OutOfMemory;
}

pub fn inflateMessage(
    allocator: std.mem.Allocator,
    compressed_payload: []const u8,
    dest: []u8,
) InflateError![]u8 {
    _ = flateCounter(compressed_payload.len) catch return error.CounterTooLarge;
    _ = flateCounter(dest.len) catch return error.CounterTooLarge;

    // Accept RFC7692-style payloads that omit Z_SYNC_FLUSH tail by appending:
    // - the stripped sync marker
    // - a final empty stored block
    const compat_suffix = [_]u8{
        0x00, 0x00, 0xff, 0xff,
        0x01, 0x00, 0x00, 0xff,
        0xff,
    };
    const input_len = std.math.add(usize, compressed_payload.len, compat_suffix.len) catch return error.CounterTooLarge;
    const input = allocator.alloc(u8, input_len) catch return error.OutOfMemory;
    defer allocator.free(input);
    @memcpy(input[0..compressed_payload.len], compressed_payload);
    @memcpy(input[compressed_payload.len..], compat_suffix[0..]);

    var reader = std.Io.Reader.fixed(input);
    var inflate_buf: [flate.max_window_len]u8 = undefined;
    var decompressor: flate.Decompress = .init(&reader, .raw, inflate_buf[0..]);
    var writer = std.Io.Writer.fixed(dest);

    _ = decompressor.reader.streamRemaining(&writer) catch |err| switch (err) {
        error.WriteFailed => return error.MessageTooLarge,
        else => return error.InflateFailed,
    };
    return dest[0..writer.end];
}

test "flate permessage-deflate helpers roundtrip sync and full flush payloads" {
    const payload = "zwebsocket interop text payload with enough repetition to exercise permessage-deflate";

    inline for (.{ sync_flush, full_flush }) |flush_mode| {
        const compressed = try deflateMessage(std.testing.allocator, payload, 1, flush_mode);
        defer std.testing.allocator.free(compressed);

        var out: [256]u8 = undefined;
        const inflated = try inflateMessage(std.testing.allocator, compressed, out[0..]);
        try std.testing.expectEqualStrings(payload, inflated);
    }
}

test "inflateMessage accepts RFC7692 stripped sync-flush payloads" {
    const stripped_sync_payload = [_]u8{ 0xca, 0x48, 0xcd, 0xc9, 0xc9, 0x07, 0x00 };
    var out: [32]u8 = undefined;
    const inflated = try inflateMessage(std.testing.allocator, stripped_sync_payload[0..], out[0..]);
    try std.testing.expectEqualStrings("hello", inflated);
}

test "flateCounter rejects lengths that do not fit 32-bit counters" {
    try std.testing.expectEqual(@as(u32, 123), try flateCounter(123));
    try std.testing.expectError(error.CounterTooLarge, flateCounter(@as(usize, std.math.maxInt(u32)) + 1));
}
