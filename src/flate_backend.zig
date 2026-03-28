const std = @import("std");
const flate = std.compress.flate;
const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("zlib.h");
});

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
pub const sync_flush = c.Z_SYNC_FLUSH;
pub const full_flush = c.Z_FULL_FLUSH;
const sync_flush_tail = [_]u8{ 0x00, 0x00, 0xff, 0xff };
const takeover_sentinel: u8 = 0x00;

fn zalloc(_: ?*anyopaque, items: c_uint, size: c_uint) callconv(.c) ?*anyopaque {
    const total = std.math.mul(usize, @as(usize, items), @as(usize, size)) catch return null;
    return c.malloc(total);
}

fn zfree(_: ?*anyopaque, ptr: ?*anyopaque) callconv(.c) void {
    c.free(ptr);
}

fn flateCounter(n: usize) error{CounterTooLarge}!u32 {
    return std.math.cast(u32, n) orelse error.CounterTooLarge;
}

fn zlibCounter(n: usize) error{CounterTooLarge}!c_uint {
    return std.math.cast(c_uint, n) orelse error.CounterTooLarge;
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

pub const TakeoverDeflater = struct {
    allocator: std.mem.Allocator = undefined,
    output: std.Io.Writer.Allocating = undefined,
    compressor: flate.Compress = undefined,
    compress_buf: [flate.max_window_len]u8 = undefined,

    pub fn init(self: *@This(), allocator: std.mem.Allocator, level: i32) DeflateError!void {
        self.allocator = allocator;
        self.output = std.Io.Writer.Allocating.initCapacity(allocator, 64) catch return error.OutOfMemory;
        self.compressor = flate.Compress.init(
            &self.output.writer,
            self.compress_buf[0..],
            .raw,
            optionsFromLevel(level),
        ) catch return error.DeflateFailed;
    }

    pub fn deinit(self: *@This()) void {
        self.output.deinit();
    }

    pub fn deflateMessage(self: *@This(), payload: []const u8) DeflateError![]u8 {
        _ = flateCounter(payload.len) catch return error.CounterTooLarge;

        self.compressor.writer.writeAll(payload) catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory,
        };
        self.compressor.writer.writeByte(takeover_sentinel) catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory,
        };
        self.compressor.writer.flush() catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory,
        };

        const encoded = self.output.toOwnedSlice() catch return error.OutOfMemory;
        errdefer self.allocator.free(encoded);

        return encoded;
    }
};

pub const TakeoverInflater = struct {
    input_reader: std.Io.Reader = std.Io.Reader.fixed(""[0..]),
    decompressor: flate.Decompress = undefined,
    inflate_buf: [flate.max_window_len]u8 = undefined,

    pub fn init(self: *@This()) void {
        self.input_reader = std.Io.Reader.fixed(""[0..]);
        self.decompressor = .init(&self.input_reader, .raw, self.inflate_buf[0..]);
    }

    pub fn deinit(_: *@This()) void {}

    pub fn inflateMessage(self: *@This(), allocator: std.mem.Allocator, compressed_payload: []const u8, dest: []u8) InflateError![]u8 {
        _ = flateCounter(compressed_payload.len) catch return error.CounterTooLarge;
        _ = flateCounter(dest.len) catch return error.CounterTooLarge;

        const input_len = std.math.add(usize, compressed_payload.len, sync_flush_tail.len) catch return error.CounterTooLarge;
        const input = allocator.alloc(u8, input_len) catch return error.OutOfMemory;
        defer allocator.free(input);
        @memcpy(input[0..compressed_payload.len], compressed_payload);
        @memcpy(input[compressed_payload.len..], sync_flush_tail[0..]);

        self.input_reader = std.Io.Reader.fixed(input);
        self.decompressor.input = &self.input_reader;

        var writer = std.Io.Writer.fixed(dest);
        while (true) {
            _ = self.decompressor.reader.stream(&writer, .unlimited) catch |err| switch (err) {
                error.WriteFailed => return error.MessageTooLarge,
                error.EndOfStream => return error.InflateFailed,
                error.ReadFailed => {
                    if (self.decompressor.err) |decode_err| {
                        if (decode_err == error.EndOfStream) {
                            const trailing = self.decompressor.reader.buffered();
                            if (trailing.len != 0) {
                                if (trailing.len > dest.len - writer.end) return error.MessageTooLarge;
                                @memcpy(dest[writer.end..][0..trailing.len], trailing);
                                writer.end += trailing.len;
                                self.decompressor.reader.toss(trailing.len);
                            }
                            self.decompressor.err = null;
                            if (writer.end == 0) return error.InflateFailed;
                            if (dest[writer.end - 1] != takeover_sentinel) return error.InflateFailed;
                            return dest[0 .. writer.end - 1];
                        }
                    }
                    return error.InflateFailed;
                },
            };
        }
    }
};

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
    stream.avail_in = zlibCounter(payload.len) catch return error.CounterTooLarge;

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

    if (!std.mem.endsWith(u8, out.items, &sync_flush_tail)) return error.DeflateFailed;
    out.shrinkRetainingCapacity(out.items.len - sync_flush_tail.len);
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
    stream.avail_in = zlibCounter(compressed_payload.len) catch return error.CounterTooLarge;
    stream.next_out = if (dest.len == 0) null else @ptrCast(dest.ptr);
    stream.avail_out = zlibCounter(dest.len) catch return error.CounterTooLarge;

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

test "deflateMessage and inflateMessage roundtrip binary data" {
    var payload: [512]u8 = undefined;
    for (&payload, 0..) |*b, i| {
        b.* = @truncate((i * 29 + 11) & 0xff);
    }

    const compressed = try deflateMessage(std.testing.allocator, payload[0..], 1, sync_flush);
    defer std.testing.allocator.free(compressed);
    try std.testing.expect(compressed.len > 0);

    var out: [1024]u8 = undefined;
    const inflated = try inflateMessage(std.testing.allocator, compressed, out[0..]);
    try std.testing.expectEqualSlices(u8, payload[0..], inflated);
}

test "deflateMessage outputs streams that a reused zlib inflater can consume sequentially" {
    const m1 = "hello hello hello";
    const m2 = "hello hello hello again";

    const c1 = try deflateMessage(std.testing.allocator, m1, 1, sync_flush);
    defer std.testing.allocator.free(c1);
    const c2 = try deflateMessage(std.testing.allocator, m2, 1, sync_flush);
    defer std.testing.allocator.free(c2);
    const in1 = try std.mem.concat(std.testing.allocator, u8, &.{ c1, &sync_flush_tail });
    defer std.testing.allocator.free(in1);
    const in2 = try std.mem.concat(std.testing.allocator, u8, &.{ c2, &sync_flush_tail });
    defer std.testing.allocator.free(in2);

    var stream: c.z_stream = std.mem.zeroes(c.z_stream);
    stream.zalloc = zalloc;
    stream.zfree = zfree;
    try std.testing.expectEqual(@as(c_int, c.Z_OK), c.inflateInit2_(&stream, -15, c.ZLIB_VERSION, @sizeOf(c.z_stream)));
    defer _ = c.inflateEnd(&stream);

    var out1: [64]u8 = undefined;
    stream.next_in = @ptrCast(@constCast(in1.ptr));
    stream.avail_in = try zlibCounter(in1.len);
    stream.next_out = @ptrCast(out1[0..].ptr);
    stream.avail_out = try zlibCounter(out1.len);
    while (true) {
        const rc = c.inflate(&stream, c.Z_SYNC_FLUSH);
        if (rc == c.Z_OK or rc == c.Z_BUF_ERROR) {
            if (stream.avail_in == 0) break;
            if (stream.avail_out == 0) return error.MessageTooLarge;
            continue;
        }
        return error.InflateFailed;
    }
    try std.testing.expectEqualStrings(m1, out1[0..stream.total_out]);

    const out1_len = stream.total_out;
    var out2: [64]u8 = undefined;
    stream.next_in = @ptrCast(@constCast(in2.ptr));
    stream.avail_in = try zlibCounter(in2.len);
    stream.next_out = @ptrCast(out2[0..].ptr);
    stream.avail_out = try zlibCounter(out2.len);
    while (true) {
        const rc = c.inflate(&stream, c.Z_SYNC_FLUSH);
        if (rc == c.Z_OK or rc == c.Z_BUF_ERROR) {
            if (stream.avail_in == 0) break;
            if (stream.avail_out == 0) return error.MessageTooLarge;
            continue;
        }
        return error.InflateFailed;
    }
    const out2_len = stream.total_out - out1_len;
    try std.testing.expectEqualStrings(m2, out2[0..out2_len]);
}

test "inflateMessage accepts RFC7692 stripped sync-flush payloads" {
    const stripped_sync_payload = [_]u8{ 0xca, 0x48, 0xcd, 0xc9, 0xc9, 0x07, 0x00 };
    var out: [32]u8 = undefined;
    const inflated = try inflateMessage(std.testing.allocator, stripped_sync_payload[0..], out[0..]);
    try std.testing.expectEqualStrings("hello", inflated);
}

test "takeover helpers roundtrip multiple messages through shared compression state" {
    var deflater: TakeoverDeflater = undefined;
    try deflater.init(std.testing.allocator, 1);
    defer deflater.deinit();

    var inflater: TakeoverInflater = undefined;
    inflater.init();
    defer inflater.deinit();

    const m1 = "hello hello hello";
    const m2 = "hello hello hello again";
    const c1 = try deflater.deflateMessage(m1);
    defer std.testing.allocator.free(c1);
    const c2 = try deflater.deflateMessage(m2);
    defer std.testing.allocator.free(c2);

    var out1: [64]u8 = undefined;
    var out2: [64]u8 = undefined;
    const got1 = try inflater.inflateMessage(std.testing.allocator, c1, out1[0..]);
    const got2 = try inflater.inflateMessage(std.testing.allocator, c2, out2[0..]);
    try std.testing.expectEqualStrings(m1, got1);
    try std.testing.expectEqualStrings(m2, got2);
}

test "flateCounter rejects lengths that do not fit 32-bit counters" {
    try std.testing.expectEqual(@as(u32, 123), try flateCounter(123));
    try std.testing.expectError(error.CounterTooLarge, flateCounter(@as(usize, std.math.maxInt(u32)) + 1));
}

test "zlibCounter rejects lengths that do not fit zlib counters" {
    try std.testing.expectEqual(@as(c_uint, 123), try zlibCounter(123));
    try std.testing.expectError(error.CounterTooLarge, zlibCounter(@as(usize, std.math.maxInt(c_uint)) + 1));
}
