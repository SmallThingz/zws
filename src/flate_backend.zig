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
const sync_flush_tail = [_]u8{ 0x00, 0x00, 0xff, 0xff };
const takeover_sentinel: u8 = 0x00;

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
    initialized: bool = false,

    pub fn init(self: *@This()) void {
        self.input_reader = std.Io.Reader.fixed(""[0..]);
        self.decompressor = .init(&self.input_reader, .raw, self.inflate_buf[0..]);
        self.initialized = true;
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
            const n = self.decompressor.reader.stream(&writer, .unlimited) catch |err| switch (err) {
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
            _ = n;
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
