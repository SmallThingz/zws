const std = @import("std");
const Io = std.Io;

const proto = @import("protocol.zig");
const extensions = @import("extensions.zig");
const observe = @import("observe.zig");
const flate_backend = @import("flate_backend.zig");
const test_support = @import("test_support.zig");

const control_payload_max_len = 125;
const frame_header_max_len = 14;
const mask_len = 4;

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
    InvalidCompressedMessage,
    ConnectionClosed,
    Timeout,
    FragmentWriteInProgress,
    UnexpectedContinuationWrite,
    OutOfMemory,
};

pub const Error = ProtocolError;

pub const StaticConfig = struct {
    role: Role = .server,
    auto_pong: bool = true,
    auto_reply_close: bool = true,
    validate_utf8: bool = true,
    runtime_hooks: bool = true,
    supports_permessage_deflate: bool = true,
    /// Enables runtime support for cross-message permessage-deflate context takeover.
    /// When false, each compressed message is treated as independent.
    permessage_deflate_context_takeover: bool = false,
    /// Skip compression for payloads smaller than this size.
    permessage_deflate_min_payload_len: usize = 64,
    /// If true, only send compressed frames when they are smaller than input.
    permessage_deflate_require_compression_gain: bool = true,
};

pub const Config = struct {
    max_frame_payload_len: u64 = std.math.maxInt(u64),
    max_message_payload_len: usize = std.math.maxInt(usize),
    permessage_deflate: ?PerMessageDeflateConfig = null,
    timeouts: observe.TimeoutConfig = .{},
};

pub const PerMessageDeflateConfig = struct {
    allocator: std.mem.Allocator,
    negotiated: extensions.PerMessageDeflate = .{},
    compression_level: i32 = 1,
    compress_outgoing: bool = false,
};

pub const FrameHeader = struct {
    fin: bool,
    masked: bool,
    compressed: bool = false,
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

pub const BorrowedFrame = struct {
    /// Borrowed payload backed by the reader buffer until the next peek/fill.
    header: FrameHeader,
    payload: []u8,
};

const ParsedHeader = struct {
    header: FrameHeader,
    header_len: usize,
    mask: [mask_len]u8,
};

/// Creates a websocket connection type specialized for a fixed role and policy
/// set so the hot path can be compiled without runtime configuration branches.
pub fn Conn(comptime static: StaticConfig) type {
    return ConnWithHooks(static, observe.DefaultRuntimeHooks);
}

pub const Type = Conn;

/// Creates a websocket connection type specialized for a fixed role, policy,
/// and runtime hook implementation.
pub fn ConnWithHooks(comptime static: StaticConfig, comptime Hooks: type) type {
    const expects_masked = static.role == .server;
    const sends_masked = static.role == .client;
    const auto_pong = static.auto_pong;
    const auto_reply_close = static.auto_reply_close;
    const validate_utf8 = static.validate_utf8;
    const runtime_hooks = static.runtime_hooks;
    const supports_permessage_deflate = static.supports_permessage_deflate;
    const permessage_deflate_context_takeover = static.permessage_deflate_context_takeover;
    const permessage_deflate_min_payload_len = static.permessage_deflate_min_payload_len;
    const permessage_deflate_require_compression_gain = static.permessage_deflate_require_compression_gain;
    const StoredPerMessageDeflateField = if (supports_permessage_deflate) ?PerMessageDeflateConfig else void;
    const StoredTimeoutsField = if (runtime_hooks) observe.TimeoutConfig else void;
    const HooksField = if (runtime_hooks) Hooks else void;
    const MaskPrngField = if (sends_masked) std.Random.DefaultPrng else void;
    const RecvMaskField = if (expects_masked) [mask_len]u8 else void;
    const RecvMaskOffsetField = if (expects_masked) usize else void;
    const RecvFragmentCompressedField = if (supports_permessage_deflate) bool else void;
    const SendTakeoverField = if (supports_permessage_deflate and permessage_deflate_context_takeover) ?flate_backend.TakeoverDeflater else void;
    const RecvTakeoverField = if (supports_permessage_deflate and permessage_deflate_context_takeover) ?flate_backend.TakeoverInflater else void;
    if (comptime runtime_hooks) observe.validateHooks(Hooks);

    const StoredConfig = struct {
        max_frame_payload_len: u64 = std.math.maxInt(u64),
        max_message_payload_len: usize = std.math.maxInt(usize),
        permessage_deflate: StoredPerMessageDeflateField = if (supports_permessage_deflate) null else {},
        timeouts: StoredTimeoutsField = if (runtime_hooks) .{} else {},
    };

    return struct {
        pub const static_config = static;

        reader: *Io.Reader,
        writer: *Io.Writer,
        config: StoredConfig,
        hooks: HooksField = if (runtime_hooks) undefined else {},
        mask_prng: MaskPrngField = if (sends_masked) undefined else {},

        recv_active: bool = false,
        recv_header: FrameHeader = undefined,
        recv_remaining: u64 = 0,
        recv_mask: RecvMaskField = if (expects_masked) .{0} ** mask_len else {},
        recv_mask_offset: RecvMaskOffsetField = if (expects_masked) 0 else {},
        recv_fragment_opcode: ?MessageOpcode = null,
        recv_fragment_compressed: RecvFragmentCompressedField = if (supports_permessage_deflate) false else {},

        send_fragment_opcode: ?MessageOpcode = null,
        close_sent: bool = false,
        close_received: bool = false,
        send_takeover: SendTakeoverField = if (supports_permessage_deflate and permessage_deflate_context_takeover) null else {},
        recv_takeover: RecvTakeoverField = if (supports_permessage_deflate and permessage_deflate_context_takeover) null else {},

        const Self = @This();
        const masked_write_scratch_len = 4096;
        const TimedOp = struct {
            start_ns: u64,
            budget_ns: u64,
        };

        pub fn init(reader: *Io.Reader, writer: *Io.Writer, config: anytype) Self {
            return initWithHooks(reader, writer, config, .{});
        }

        pub fn initWithHooks(reader: *Io.Reader, writer: *Io.Writer, config: anytype, hooks: Hooks) Self {
            const seed = nextMaskSeed() ^
                @as(u64, @truncate(@intFromPtr(reader))) ^
                (@as(u64, @truncate(@intFromPtr(writer))) << 1);
            return .{
                .reader = reader,
                .writer = writer,
                .config = normalizeConfig(config),
                .hooks = if (runtime_hooks) hooks else {},
                .mask_prng = if (sends_masked) std.Random.DefaultPrng.init(seed) else {},
            };
        }

        // Accept sparse/anonymous config literals at the public API boundary, then
        // collapse them into the smaller stored shape so disabled features compile out.
        fn normalizeConfig(config: anytype) StoredConfig {
            const T = @TypeOf(config);
            return .{
                .max_frame_payload_len = if (@hasField(T, "max_frame_payload_len")) config.max_frame_payload_len else std.math.maxInt(u64),
                .max_message_payload_len = if (@hasField(T, "max_message_payload_len")) config.max_message_payload_len else std.math.maxInt(usize),
                .permessage_deflate = if (supports_permessage_deflate)
                    if (@hasField(T, "permessage_deflate")) normalizePerMessageDeflateConfig(config.permessage_deflate) else null
                else {},
                .timeouts = if (runtime_hooks)
                    if (@hasField(T, "timeouts")) normalizeTimeoutConfig(config.timeouts) else .{}
                else {},
            };
        }

        // Per-message-deflate configs often arrive as anonymous struct literals from
        // examples/tests; normalize those into the canonical runtime shape once here.
        fn normalizePerMessageDeflateConfig(value: anytype) ?PerMessageDeflateConfig {
            const T = @TypeOf(value);
            if (T == ?PerMessageDeflateConfig) return value;
            if (T == PerMessageDeflateConfig) return value;

            const Child, const child = switch (@typeInfo(T)) {
                .optional => |info| .{ info.child, value orelse return null },
                .@"struct" => .{ T, value },
                else => @compileError("permessage_deflate must be conn.PerMessageDeflateConfig, ?conn.PerMessageDeflateConfig, or a structurally-compatible config"),
            };
            return .{
                .allocator = child.allocator,
                .negotiated = if (@hasField(Child, "negotiated")) normalizeNegotiatedPerMessageDeflate(child.negotiated) else .{},
                .compression_level = if (@hasField(Child, "compression_level")) child.compression_level else 1,
                .compress_outgoing = if (@hasField(Child, "compress_outgoing")) child.compress_outgoing else false,
            };
        }

        // Only the negotiated takeover bits affect the wire format today, so the
        // stored negotiated extension state is reduced to those booleans.
        fn normalizeNegotiatedPerMessageDeflate(value: anytype) extensions.PerMessageDeflate {
            const T = @TypeOf(value);
            if (T == extensions.PerMessageDeflate) return value;
            return .{
                .server_no_context_takeover = if (@hasField(T, "server_no_context_takeover")) value.server_no_context_takeover else false,
                .client_no_context_takeover = if (@hasField(T, "client_no_context_takeover")) value.client_no_context_takeover else false,
            };
        }

        fn normalizeTimeoutConfig(value: anytype) observe.TimeoutConfig {
            const T = @TypeOf(value);
            if (T == observe.TimeoutConfig) return value;
            return .{
                .read_ns = if (@hasField(T, "read_ns")) value.read_ns else null,
                .write_ns = if (@hasField(T, "write_ns")) value.write_ns else null,
                .flush_ns = if (@hasField(T, "flush_ns")) value.flush_ns else null,
            };
        }

        fn nextMaskSeed() u64 {
            const Seed = struct {
                var value: u64 = 0x9e37_79b9_7f4a_7c15;
            };
            Seed.value +%= 0xbf58_476d_1ce4_e5b9;
            return Seed.value;
        }

        pub fn flush(self: *Self) (ProtocolError || Io.Writer.Error)!void {
            try self.flushTimed();
        }

        pub fn deinit(self: *Self) void {
            if (comptime supports_permessage_deflate and permessage_deflate_context_takeover) {
                if (self.send_takeover) |*deflater| {
                    deflater.deinit();
                    self.send_takeover = null;
                }
                if (self.recv_takeover) |*inflater| {
                    inflater.deinit();
                    self.recv_takeover = null;
                }
            }
        }

        fn beginTimedOp(self: *const Self, phase: observe.IoPhase) ?TimedOp {
            if (comptime !runtime_hooks) return null;
            const budget_ns = switch (phase) {
                .read => self.config.timeouts.read_ns,
                .write => self.config.timeouts.write_ns,
                .flush => self.config.timeouts.flush_ns,
            } orelse return null;

            const start_ns = self.hooks.nowNs();
            const deadline_ns = std.math.add(u64, start_ns, budget_ns) catch std.math.maxInt(u64);
            var hooks = @constCast(&self.hooks);
            switch (phase) {
                .read => hooks.setReadDeadlineNs(deadline_ns),
                .write => hooks.setWriteDeadlineNs(deadline_ns),
                .flush => hooks.setFlushDeadlineNs(deadline_ns),
            }

            return .{
                .start_ns = start_ns,
                .budget_ns = budget_ns,
            };
        }

        fn clearTimedOp(self: *const Self, phase: observe.IoPhase) void {
            if (comptime !runtime_hooks) return;
            var hooks = @constCast(&self.hooks);
            switch (phase) {
                .read => hooks.setReadDeadlineNs(null),
                .write => hooks.setWriteDeadlineNs(null),
                .flush => hooks.setFlushDeadlineNs(null),
            }
        }

        fn finishTimedOp(self: *const Self, timed: ?TimedOp) ProtocolError!void {
            if (comptime !runtime_hooks) return;
            const op = timed orelse return;
            const elapsed_ns = self.hooks.nowNs() -| op.start_ns;
            if (elapsed_ns > op.budget_ns) {
                return error.Timeout;
            }
        }

        fn peekGreedyTimed(self: *Self, n: usize) (ProtocolError || Io.Reader.Error)![]const u8 {
            if (comptime !runtime_hooks) return self.reader.peekGreedy(n);
            const timed = self.beginTimedOp(.read);
            defer self.clearTimedOp(.read);
            const out = try self.reader.peekGreedy(n);
            try self.finishTimedOp(timed);
            return out;
        }

        fn peekTimed(self: *Self, n: usize) (ProtocolError || Io.Reader.Error)![]const u8 {
            if (comptime !runtime_hooks) return self.reader.peek(n);
            const timed = self.beginTimedOp(.read);
            defer self.clearTimedOp(.read);
            const out = try self.reader.peek(n);
            try self.finishTimedOp(timed);
            return out;
        }

        fn readSliceAllTimed(self: *Self, dest: []u8) (ProtocolError || Io.Reader.Error)!void {
            if (comptime !runtime_hooks) return self.reader.readSliceAll(dest);
            const timed = self.beginTimedOp(.read);
            defer self.clearTimedOp(.read);
            try self.reader.readSliceAll(dest);
            try self.finishTimedOp(timed);
        }

        fn writeAllTimed(self: *Self, bytes: []const u8) (ProtocolError || Io.Writer.Error)!void {
            if (comptime !runtime_hooks) return self.writer.writeAll(bytes);
            const timed = self.beginTimedOp(.write);
            defer self.clearTimedOp(.write);
            try self.writer.writeAll(bytes);
            try self.finishTimedOp(timed);
        }

        fn writeVecAllTimed(self: *Self, data: [][]const u8) (ProtocolError || Io.Writer.Error)!void {
            if (comptime !runtime_hooks) return self.writer.writeVecAll(data);
            const timed = self.beginTimedOp(.write);
            defer self.clearTimedOp(.write);
            try self.writer.writeVecAll(data);
            try self.finishTimedOp(timed);
        }

        fn flushTimed(self: *Self) (ProtocolError || Io.Writer.Error)!void {
            if (comptime !runtime_hooks) return self.writer.flush();
            const timed = self.beginTimedOp(.flush);
            defer self.clearTimedOp(.flush);
            try self.writer.flush();
            try self.finishTimedOp(timed);
        }

        pub fn beginFrame(self: *Self) (ProtocolError || Io.Reader.Error)!FrameHeader {
            if (self.recv_active) return error.FrameActive;

            const available = try self.peekGreedyTimed(2);
            const prefix = if (available.len >= 2) available else try self.peekTimed(2);
            const header_need = neededHeaderLen(prefix[1]);
            const header_bytes = if (prefix.len >= header_need) prefix else try self.peekTimed(header_need);
            const parsed = (try self.parseHeaderBytes(header_bytes)).?;

            self.reader.toss(parsed.header_len);
            self.recv_active = true;
            self.recv_header = parsed.header;
            self.recv_remaining = parsed.header.payload_len;
            if (comptime expects_masked) {
                self.recv_mask = parsed.mask;
                self.recv_mask_offset = 0;
            }
            return self.recv_header;
        }

        pub fn beginFrameBorrowed(self: *Self) (ProtocolError || Io.Reader.Error)!?BorrowedFrame {
            if (self.recv_active) return error.FrameActive;

            const available = try self.peekGreedyTimed(2);
            const prefix = if (available.len >= 2) available else try self.peekTimed(2);
            const header_need = neededHeaderLen(prefix[1]);
            if (header_need > self.reader.buffer.len) return null;

            const header_bytes = if (prefix.len >= header_need) prefix else try self.peekTimed(header_need);
            const parsed = (try self.parseHeaderBytes(header_bytes)).?;
            const payload_len: usize = std.math.cast(usize, parsed.header.payload_len) orelse return null;
            const total_len = std.math.add(usize, parsed.header_len, payload_len) catch return null;
            if (total_len > self.reader.buffer.len) return null;

            const frame_bytes = if (header_bytes.len >= total_len) header_bytes[0..total_len] else try self.peekTimed(total_len);
            const payload: []u8 = @constCast(frame_bytes[parsed.header_len..][0..payload_len]);
            if (parsed.header.masked) applyMask(payload, parsed.mask, 0);
            self.reader.toss(total_len);
            self.noteConsumedFrame(parsed.header);

            return .{
                .header = parsed.header,
                .payload = payload,
            };
        }

        pub fn readFrameBorrowed(self: *Self) (ProtocolError || Io.Reader.Error)!?BorrowedFrame {
            return self.beginFrameBorrowed();
        }

        pub fn readFrameChunk(self: *Self, dest: []u8) (ProtocolError || Io.Reader.Error)![]u8 {
            if (!self.recv_active) return error.NoActiveFrame;
            if (self.recv_remaining == 0) {
                self.finishActiveFrame();
                return dest[0..0];
            }
            if (dest.len == 0) return dest[0..0];

            const remaining = std.math.cast(usize, self.recv_remaining) orelse std.math.maxInt(usize);
            const n: usize = @min(dest.len, remaining);
            try self.readSliceAllTimed(dest[0..n]);
            if (comptime expects_masked) {
                applyMask(dest[0..n], self.recv_mask, self.recv_mask_offset);
            }

            self.recv_remaining -= n;
            if (comptime expects_masked) {
                self.recv_mask_offset += n;
            }

            if (self.recv_remaining == 0) self.finishActiveFrame();
            return dest[0..n];
        }

        pub fn readFrameAll(self: *Self, dest: []u8) (ProtocolError || Io.Reader.Error)![]u8 {
            if (!self.recv_active) return error.NoActiveFrame;
            const remaining = std.math.cast(usize, self.recv_remaining) orelse return error.MessageTooLarge;
            if (remaining > dest.len) return error.MessageTooLarge;
            if (self.recv_remaining == 0) {
                self.finishActiveFrame();
                return dest[0..0];
            }
            return try self.readFrameChunk(dest[0..remaining]);
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

        pub fn readMessageBorrowed(self: *Self) (ProtocolError || Io.Reader.Error || Io.Writer.Error)!?Message {
            if (self.recv_active) return error.FrameActive;

            var control_buf: [control_payload_max_len]u8 = undefined;
            while (true) {
                const available = try self.peekGreedyTimed(2);
                const prefix = if (available.len >= 2) available else try self.peekTimed(2);
                const header_need = neededHeaderLen(prefix[1]);
                const header_bytes = if (prefix.len >= header_need) prefix else try self.peekTimed(header_need);
                const parsed = (try self.parseHeaderBytes(header_bytes)).?;

                if (proto.isControl(parsed.header.opcode)) {
                    self.reader.toss(parsed.header_len);
                    self.recv_active = true;
                    self.recv_header = parsed.header;
                    self.recv_remaining = parsed.header.payload_len;
                    if (comptime expects_masked) {
                        self.recv_mask = parsed.mask;
                        self.recv_mask_offset = 0;
                    }

                    const payload = try self.readFrameAll(control_buf[0..]);
                    if (try self.handleControlFrame(parsed.header.opcode, payload, auto_reply_close, true)) {
                        return error.ConnectionClosed;
                    }
                    continue;
                }

                if (!parsed.header.fin or parsed.header.opcode == .continuation) return null;
                if (comptime supports_permessage_deflate) {
                    if (parsed.header.compressed) return null;
                }

                const message_opcode = proto.messageOpcode(parsed.header.opcode) orelse return null;
                const payload_len: usize = std.math.cast(usize, parsed.header.payload_len) orelse return null;
                const total_len = std.math.add(usize, parsed.header_len, payload_len) catch return null;
                if (total_len > self.reader.buffer.len) return null;

                const frame_bytes = if (header_bytes.len >= total_len) header_bytes[0..total_len] else try self.peekTimed(total_len);
                const payload: []u8 = @constCast(frame_bytes[parsed.header_len..][0..payload_len]);
                if (parsed.header.masked) applyMask(payload, parsed.mask, 0);
                if (comptime validate_utf8) {
                    if (message_opcode == .text and !std.unicode.utf8ValidateSlice(payload)) return error.InvalidUtf8;
                }

                self.reader.toss(total_len);
                self.noteConsumedFrame(parsed.header);
                return .{
                    .opcode = message_opcode,
                    .payload = payload,
                };
            }
        }

        pub fn readMessage(self: *Self, buf: []u8) (ProtocolError || Io.Reader.Error || Io.Writer.Error)!Message {
            var total_len: usize = 0;
            var message_opcode: ?MessageOpcode = self.recv_fragment_opcode;
            var message_compressed = if (supports_permessage_deflate) self.recv_fragment_compressed else false;
            var compressed_payload: ?std.ArrayList(u8) = null;
            defer if (compressed_payload) |*list| list.deinit(compressionAllocator(self));
            var control_buf: [control_payload_max_len]u8 = undefined;

            while (true) {
                const header = try self.beginFrame();
                if (proto.isControl(header.opcode)) {
                    const payload = try self.readFrameAll(control_buf[0..]);
                    if (try self.handleControlFrame(header.opcode, payload, auto_reply_close, true)) {
                        return error.ConnectionClosed;
                    }
                    continue;
                }

                if (message_opcode == null) {
                    message_opcode = proto.messageOpcode(header.opcode) orelse unreachable;
                    if (comptime supports_permessage_deflate) {
                        message_compressed = header.compressed;
                    }
                }

                if (message_compressed) {
                    if (comptime !supports_permessage_deflate) unreachable;
                    var list = if (compressed_payload) |*existing|
                        existing
                    else blk: {
                        compressed_payload = .empty;
                        break :blk &(compressed_payload.?);
                    };

                    const frame_len = std.math.cast(usize, header.payload_len) orelse {
                        try self.discardFrame();
                        return try self.failMessageTooLarge();
                    };
                    const start = list.items.len;
                    list.resize(compressionAllocator(self), start + frame_len) catch return error.OutOfMemory;
                    errdefer list.shrinkRetainingCapacity(start);
                    _ = try self.readFrameAll(list.items[start .. start + frame_len]);

                    if (!header.fin) continue;

                    const inflated = try self.inflateMessage(list.items, buf);
                    const final_opcode = message_opcode.?;
                    if (comptime validate_utf8) {
                        if (final_opcode == .text and !std.unicode.utf8ValidateSlice(inflated)) return error.InvalidUtf8;
                    }
                    return .{
                        .opcode = final_opcode,
                        .payload = inflated,
                    };
                }

                if (header.payload_len > buf.len - total_len) {
                    try self.discardFrame();
                    return try self.failMessageTooLarge();
                }
                const chunk = try self.readFrameAll(buf[total_len..]);
                total_len += chunk.len;

                if (total_len > self.config.max_message_payload_len) {
                    return try self.failMessageTooLarge();
                }
                if (!header.fin) continue;

                const final_opcode = message_opcode.?;
                if (comptime validate_utf8) {
                    if (final_opcode == .text and !std.unicode.utf8ValidateSlice(buf[0..total_len])) return error.InvalidUtf8;
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
            compressed: bool,
        ) (ProtocolError || Io.Writer.Error)!void {
            try self.writeFrameInternal(opcode, payload, fin, compressed);
        }

        fn writeFrameInternal(
            self: *Self,
            opcode: Opcode,
            payload: []const u8,
            fin: bool,
            compressed: bool,
        ) (ProtocolError || Io.Writer.Error)!void {
            if (proto.isControl(opcode) and payload.len > control_payload_max_len) return error.ControlFrameTooLarge;
            if (proto.isControl(opcode) and compressed) return error.ReservedBitsSet;
            try self.validateOutgoingSequence(opcode, fin);

            var header_buf: [frame_header_max_len]u8 = undefined;
            var header_len: usize = 0;

            const fin_bit: u8 = if (fin) 0x80 else 0;
            const compressed_bit: u8 = if (compressed) 0x40 else 0;
            header_buf[header_len] = @as(u8, @intFromEnum(opcode)) | fin_bit | compressed_bit;
            header_len += 1;

            if (payload.len <= control_payload_max_len) {
                header_buf[header_len] = @as(u8, @intCast(payload.len));
                if (comptime !expects_masked) header_buf[header_len] |= 0x80;
                header_len += 1;
            } else if (payload.len <= std.math.maxInt(u16)) {
                header_buf[header_len] = 126;
                if (comptime !expects_masked) header_buf[header_len] |= 0x80;
                header_len += 1;
                std.mem.writeInt(u16, header_buf[header_len..][0..2], @as(u16, @intCast(payload.len)), .big);
                header_len += 2;
            } else {
                header_buf[header_len] = 127;
                if (comptime !expects_masked) header_buf[header_len] |= 0x80;
                header_len += 1;
                std.mem.writeInt(u64, header_buf[header_len..][0..8], payload.len, .big);
                header_len += 8;
            }

            if (comptime sends_masked) {
                var mask: [mask_len]u8 = undefined;
                self.mask_prng.random().bytes(mask[0..]);
                @memcpy(header_buf[header_len..][0..4], mask[0..]);
                header_len += 4;
                try self.writeAllTimed(header_buf[0..header_len]);

                var scratch: [masked_write_scratch_len]u8 = undefined;
                var offset: usize = 0;
                while (offset < payload.len) {
                    const n = @min(masked_write_scratch_len, payload.len - offset);
                    @memcpy(scratch[0..n], payload[offset..][0..n]);
                    applyMask(scratch[0..n], mask, offset);
                    try self.writeAllTimed(scratch[0..n]);
                    offset += n;
                }
                return;
            }

            var write_parts = [_][]const u8{ header_buf[0..header_len], payload };
            try self.writeVecAllTimed(write_parts[0..]);
        }

        pub fn writeText(self: *Self, payload: []const u8) (ProtocolError || Io.Writer.Error)!void {
            try validateUtf8IfEnabled(validate_utf8, payload);
            try self.writeMessage(.text, payload);
        }

        pub fn writeBinary(self: *Self, payload: []const u8) (ProtocolError || Io.Writer.Error)!void {
            try self.writeMessage(.binary, payload);
        }

        fn writeMessage(self: *Self, opcode: Opcode, payload: []const u8) (ProtocolError || Io.Writer.Error)!void {
            if (comptime !supports_permessage_deflate) {
                try self.writeFrameInternal(opcode, payload, true, false);
                return;
            }
            const pmd = self.config.permessage_deflate;
            if (pmd == null or payload.len == 0 or !pmd.?.compress_outgoing) {
                try self.writeFrameInternal(opcode, payload, true, false);
                return;
            }

            if (payload.len < permessage_deflate_min_payload_len) {
                try self.writeFrameInternal(opcode, payload, true, false);
                return;
            }

            const compressed_payload = try self.deflateMessage(payload);
            defer compressionAllocator(self).free(compressed_payload);

            if (comptime permessage_deflate_require_compression_gain) {
                var can_skip_by_gain = true;
                if (comptime permessage_deflate_context_takeover) {
                    if (self.shouldUseOutgoingContextTakeover()) {
                        // Takeover mode mutates compressor state per message, so once we compress
                        // we must emit the compressed payload to keep both peers in sync.
                        can_skip_by_gain = false;
                    }
                }
                if (can_skip_by_gain and compressed_payload.len >= payload.len) {
                    try self.writeFrameInternal(opcode, payload, true, false);
                    return;
                }
            }
            try self.writeFrameInternal(opcode, compressed_payload, true, true);
        }

        pub fn writePing(self: *Self, payload: []const u8) (ProtocolError || Io.Writer.Error)!void {
            try self.writeControlFrame(.ping, payload);
        }

        pub fn writePong(self: *Self, payload: []const u8) (ProtocolError || Io.Writer.Error)!void {
            try self.writeControlFrame(.pong, payload);
        }

        pub fn writeClose(
            self: *Self,
            code: ?u16,
            reason: []const u8,
        ) (ProtocolError || Io.Writer.Error)!void {
            if (code == null and reason.len != 0) return error.InvalidClosePayload;
            try validateUtf8IfEnabled(validate_utf8, reason);

            var payload: [control_payload_max_len]u8 = undefined;
            var len: usize = 0;
            if (code) |close_code| {
                if (!proto.isValidCloseCode(close_code)) return error.InvalidCloseCode;
                std.mem.writeInt(u16, payload[0..2], close_code, .big);
                len = 2;
            }

            if (len + reason.len > control_payload_max_len) return error.ControlFrameTooLarge;
            @memcpy(payload[len..][0..reason.len], reason);
            len += reason.len;

            try self.writeControlFrame(.close, payload[0..len]);
            self.close_sent = true;
        }

        // Parse and validate the already-buffered frame header in one place so both
        // borrowed and owned read paths share the exact same protocol checks.
        fn parseHeaderBytes(self: *Self, bytes: []const u8) ProtocolError!?ParsedHeader {
            if (bytes.len < 2) return null;
            const HeaderByte0 = packed struct(u8) {
                opcode: u4,
                rsv3: u1,
                rsv2: u1,
                rsv1: u1,
                fin: u1,
            };
            const HeaderByte1 = packed struct(u8) {
                payload_len: u7,
                masked: u1,
            };

            const b0: HeaderByte0 = @bitCast(bytes[0]);
            const b1: HeaderByte1 = @bitCast(bytes[1]);

            const compressed = b0.rsv1 != 0;
            if (b0.rsv2 != 0 or b0.rsv3 != 0) return error.ReservedBitsSet;
            if (compressed) {
                if (comptime !supports_permessage_deflate) return error.ReservedBitsSet;
                if (self.config.permessage_deflate == null) return error.ReservedBitsSet;
            }

            const opcode: Opcode = switch (b0.opcode) {
                0x0 => .continuation,
                0x1 => .text,
                0x2 => .binary,
                0x8 => .close,
                0x9 => .ping,
                0xA => .pong,
                else => return error.UnknownOpcode,
            };
            const fin = b0.fin != 0;
            const masked = b1.masked != 0;
            if (masked != expects_masked) return error.MaskBitInvalid;

            const header_len = neededHeaderLen(bytes[1]);
            if (bytes.len < header_len) return null;

            var payload_len: u64 = b1.payload_len;
            var idx: usize = 2;
            if (payload_len == 126) {
                payload_len = std.mem.readInt(u16, bytes[idx..][0..2], .big);
                if (payload_len < 126) return error.InvalidFrameLength;
                idx += 2;
            } else if (payload_len == 127) {
                if ((bytes[idx] & 0x80) != 0) return error.InvalidFrameLength;
                payload_len = std.mem.readInt(u64, bytes[idx..][0..8], .big);
                if (payload_len <= std.math.maxInt(u16)) return error.InvalidFrameLength;
                idx += 8;
            }

            if (payload_len > self.config.max_frame_payload_len) return error.FrameTooLarge;

            if (proto.isControl(opcode)) {
                if (!fin) return error.ControlFrameFragmented;
                if (compressed) return error.ReservedBitsSet;
                if (payload_len > control_payload_max_len) return error.ControlFrameTooLarge;
            } else switch (opcode) {
                .continuation => {
                    if (compressed) return error.ReservedBitsSet;
                    if (self.recv_fragment_opcode == null) return error.UnexpectedContinuation;
                },
                .text, .binary => {
                    if (self.recv_fragment_opcode != null) return error.ExpectedContinuation;
                },
                else => unreachable,
            }

            var mask: [mask_len]u8 = .{0} ** mask_len;
            if (masked) {
                const mask_u32 = std.mem.readInt(u32, bytes[idx..][0..mask_len], .big);
                std.mem.writeInt(u32, mask[0..], mask_u32, .big);
            }

            return .{
                .header = .{
                    .fin = fin,
                    .masked = masked,
                    .compressed = compressed,
                    .opcode = opcode,
                    .payload_len = payload_len,
                },
                .header_len = header_len,
                .mask = mask,
            };
        }

        fn discardRemainingMessage(self: *Self) (ProtocolError || Io.Reader.Error || Io.Writer.Error)!bool {
            var control_buf: [control_payload_max_len]u8 = undefined;

            while (self.recv_fragment_opcode != null) {
                const header = try self.beginFrame();
                if (!proto.isControl(header.opcode)) {
                    try self.discardFrame();
                    continue;
                }

                const payload = try self.readFrameAll(control_buf[0..]);
                if (try self.handleControlFrame(header.opcode, payload, auto_reply_close, true)) {
                    return true;
                }
            }
            return false;
        }

        fn writeControlFrame(self: *Self, opcode: Opcode, payload: []const u8) (ProtocolError || Io.Writer.Error)!void {
            if (payload.len > control_payload_max_len) return error.ControlFrameTooLarge;
            try self.writeFrame(opcode, payload, true, false);
        }

        fn flushAutoControlReply(self: *Self) (ProtocolError || Io.Writer.Error)!void {
            // `readMessage`/`discardRemainingMessage` stay in a blocking read loop after
            // auto-generated pong/close replies. Flush them immediately so the peer does
            // not deadlock waiting for that control frame. Any caller-buffered message
            // bytes piggyback on this flush as well, so a pending write is pushed out on
            // the next incoming ping without requiring a separate explicit flush first.
            try self.flushTimed();
        }

        fn failMessageTooLarge(self: *Self) (ProtocolError || Io.Reader.Error || Io.Writer.Error)!noreturn {
            if (try self.discardRemainingMessage()) return error.ConnectionClosed;
            return error.MessageTooLarge;
        }

        fn handleControlFrame(
            self: *Self,
            opcode: Opcode,
            payload: []const u8,
            comptime reply_close: bool,
            comptime flush_reply: bool,
        ) (ProtocolError || Io.Writer.Error)!bool {
            switch (opcode) {
                .ping => {
                    try self.autoReplyPing(payload, flush_reply);
                    return false;
                },
                .pong => return false,
                .close => {
                    try self.handleCloseFrame(payload, reply_close, flush_reply);
                    return true;
                },
                else => unreachable,
            }
        }

        fn autoReplyPing(self: *Self, payload: []const u8, comptime flush_reply: bool) (ProtocolError || Io.Writer.Error)!void {
            if (comptime !auto_pong) return;
            if (self.close_sent) return;
            try self.writePong(payload);
            if (comptime flush_reply) try self.flushAutoControlReply();
        }

        fn handleCloseFrame(
            self: *Self,
            payload: []const u8,
            comptime reply_close: bool,
            comptime flush_reply: bool,
        ) (ProtocolError || Io.Writer.Error)!void {
            self.close_received = true;
            self.recv_fragment_opcode = null;
            if (comptime supports_permessage_deflate) {
                self.recv_fragment_compressed = false;
            }
            const close_frame = try parseClosePayload(payload, validate_utf8);
            if (comptime reply_close) {
                if (!self.close_sent) {
                    try self.writeClose(close_frame.code, close_frame.reason);
                    if (comptime flush_reply) try self.flushAutoControlReply();
                }
            }
        }

        fn inflateMessage(self: *Self, compressed_payload: []const u8, dest: []u8) ProtocolError![]u8 {
            if (comptime supports_permessage_deflate and permessage_deflate_context_takeover) {
                if (self.shouldUseIncomingContextTakeover()) {
                    const inflated_takeover = self.inflateMessageTakeover(compressed_payload, dest) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.CounterTooLarge => return error.MessageTooLarge,
                        error.MessageTooLarge => return error.MessageTooLarge,
                        error.InflateFailed => return error.InvalidCompressedMessage,
                    };
                    if (inflated_takeover.len > self.config.max_message_payload_len) return error.MessageTooLarge;
                    return inflated_takeover;
                }
            }

            const inflated = flate_backend.inflateMessage(compressionAllocator(self), compressed_payload, dest) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.CounterTooLarge => return error.MessageTooLarge,
                error.MessageTooLarge => return error.MessageTooLarge,
                error.InflateFailed => return error.InvalidCompressedMessage,
            };
            if (inflated.len > self.config.max_message_payload_len) return error.MessageTooLarge;
            return inflated;
        }

        fn deflateMessage(self: *Self, payload: []const u8) ProtocolError![]u8 {
            if (comptime supports_permessage_deflate and permessage_deflate_context_takeover) {
                if (self.shouldUseOutgoingContextTakeover()) {
                    const takeover = try self.ensureSendTakeoverDeflater();
                    return takeover.deflateMessage(payload) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.CounterTooLarge => return error.MessageTooLarge,
                        error.DeflateFailed => return error.InvalidCompressedMessage,
                    };
                }
            }

            const pmd = self.config.permessage_deflate.?;
            return flate_backend.deflateMessage(
                pmd.allocator,
                payload,
                pmd.compression_level,
                outgoingFlushMode(static.role, pmd.negotiated),
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.CounterTooLarge => return error.MessageTooLarge,
                error.DeflateFailed => return error.InvalidCompressedMessage,
            };
        }

        fn compressionAllocator(self: *const Self) std.mem.Allocator {
            if (comptime !supports_permessage_deflate) unreachable;
            return self.config.permessage_deflate.?.allocator;
        }

        fn shouldUseOutgoingContextTakeover(self: *const Self) bool {
            if (comptime !supports_permessage_deflate) return false;
            const pmd = self.config.permessage_deflate orelse return false;
            return !outgoingNoContextTakeover(static.role, pmd.negotiated);
        }

        fn shouldUseIncomingContextTakeover(self: *const Self) bool {
            if (comptime !supports_permessage_deflate) return false;
            const pmd = self.config.permessage_deflate orelse return false;
            return !incomingNoContextTakeover(static.role, pmd.negotiated);
        }

        fn ensureSendTakeoverDeflater(self: *Self) ProtocolError!*flate_backend.TakeoverDeflater {
            if (comptime !supports_permessage_deflate or !permessage_deflate_context_takeover) unreachable;
            if (self.send_takeover == null) {
                self.send_takeover = undefined;
                errdefer self.send_takeover = null;
                const pmd = self.config.permessage_deflate.?;
                self.send_takeover.?.init(pmd.allocator, pmd.compression_level) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.CounterTooLarge => return error.MessageTooLarge,
                    error.DeflateFailed => return error.InvalidCompressedMessage,
                };
            }
            return &self.send_takeover.?;
        }

        fn ensureRecvTakeoverInflater(self: *Self) *flate_backend.TakeoverInflater {
            if (comptime !supports_permessage_deflate or !permessage_deflate_context_takeover) unreachable;
            if (self.recv_takeover == null) {
                self.recv_takeover = .{};
                self.recv_takeover.?.init();
            }
            return &self.recv_takeover.?;
        }

        fn inflateMessageTakeover(self: *Self, compressed_payload: []const u8, dest: []u8) flate_backend.InflateError![]u8 {
            if (comptime !supports_permessage_deflate or !permessage_deflate_context_takeover) unreachable;
            const inflater = self.ensureRecvTakeoverInflater();
            return inflater.inflateMessage(compressionAllocator(self), compressed_payload, dest);
        }

        fn validateOutgoingSequence(self: *Self, opcode: Opcode, fin: bool) ProtocolError!void {
            if (self.close_sent) return error.ConnectionClosed;

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

        fn noteConsumedFrame(self: *Self, header: FrameHeader) void {
            if (!header.fin) {
                if (proto.messageOpcode(header.opcode)) |message_opcode| {
                    self.recv_fragment_opcode = message_opcode;
                    if (comptime supports_permessage_deflate) {
                        self.recv_fragment_compressed = header.compressed;
                    }
                }
                return;
            }
            if (header.opcode == .continuation) {
                self.recv_fragment_opcode = null;
                if (comptime supports_permessage_deflate) {
                    self.recv_fragment_compressed = false;
                }
            } else if (proto.isData(header.opcode)) {
                if (comptime supports_permessage_deflate) {
                    self.recv_fragment_compressed = false;
                }
            }
        }

        fn finishActiveFrame(self: *Self) void {
            const header = self.recv_header;
            self.recv_active = false;
            self.recv_remaining = 0;
            if (comptime expects_masked) {
                self.recv_mask_offset = 0;
            }
            self.noteConsumedFrame(header);
        }
    };
}

pub const TypeWithHooks = ConnWithHooks;
pub const Default = Conn(.{});
pub const Server = Conn(.{ .role = .server });
pub const Client = Conn(.{ .role = .client });

fn validateUtf8IfEnabled(comptime enabled: bool, payload: []const u8) ProtocolError!void {
    if (comptime enabled) {
        if (!std.unicode.utf8ValidateSlice(payload)) return error.InvalidUtf8;
    }
}

fn outgoingFlushMode(comptime role: Role, negotiated: extensions.PerMessageDeflate) i32 {
    const no_context_takeover = outgoingNoContextTakeover(role, negotiated);
    return if (no_context_takeover) flate_backend.full_flush else flate_backend.sync_flush;
}

fn outgoingNoContextTakeover(comptime role: Role, negotiated: extensions.PerMessageDeflate) bool {
    return switch (role) {
        .server => negotiated.server_no_context_takeover,
        .client => negotiated.client_no_context_takeover,
    };
}

fn incomingNoContextTakeover(comptime role: Role, negotiated: extensions.PerMessageDeflate) bool {
    return switch (role) {
        .server => negotiated.client_no_context_takeover,
        .client => negotiated.server_no_context_takeover,
    };
}

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

fn neededHeaderLen(second: u8) usize {
    const len_code = second & 0x7f;
    return 2 +
        (if (len_code == 126) @as(usize, 2) else if (len_code == 127) @as(usize, 8) else @as(usize, 0)) +
        (if ((second & 0x80) != 0) @as(usize, 4) else @as(usize, 0));
}

// Apply the websocket XOR mask in-place, starting at the caller-provided frame
// offset so chunked reads and writes stay aligned with the 4-byte mask cycle.
fn applyMask(bytes: []u8, mask: [mask_len]u8, start_offset: usize) void {
    if (bytes.len == 0) return;

    const offset = start_offset & 3;
    var i: usize = 0;
    if (bytes.len >= 64) {
        const Vec = @Vector(16, u8);
        var repeated_mask_bytes_vec: [16]u8 = undefined;
        for (0..16) |j| {
            repeated_mask_bytes_vec[j] = mask[(offset + j) & 3];
        }
        const repeated_mask_vec: Vec = repeated_mask_bytes_vec;

        while (i + @sizeOf(Vec) <= bytes.len) : (i += @sizeOf(Vec)) {
            const ptr: *align(1) Vec = @ptrCast(bytes[i..].ptr);
            ptr.* ^= repeated_mask_vec;
        }
    } else {
        var repeated_mask_bytes_u64: [8]u8 = undefined;
        for (0..8) |j| {
            repeated_mask_bytes_u64[j] = mask[(offset + j) & 3];
        }
        const repeated_mask_u64 = std.mem.readInt(u64, repeated_mask_bytes_u64[0..], .little);

        while (i + 8 <= bytes.len) : (i += 8) {
            const value = std.mem.readInt(u64, bytes[i..][0..8], .little);
            std.mem.writeInt(u64, bytes[i..][0..8], value ^ repeated_mask_u64, .little);
        }
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
    mask: [mask_len]u8,
) !void {
    try test_support.appendTestFrame(Opcode, out, a, opcode, fin, masked, payload, mask);
}

const FlushTrackingWriter = struct {
    interface: Io.Writer,
    sink: []u8,
    flushed_end: usize = 0,
    flush_count: usize = 0,

    fn init(buffer: []u8, sink: []u8) FlushTrackingWriter {
        return .{
            .interface = .{
                .vtable = &.{
                    .drain = drain,
                    .flush = flush,
                    .rebase = rebase,
                },
                .buffer = buffer,
            },
            .sink = sink,
        };
    }

    fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const self: *FlushTrackingWriter = @fieldParentPtr("interface", w);
        try flush(w);

        for (data[0 .. data.len - 1]) |part| try self.append(part);
        const last = data[data.len - 1];
        for (0..splat) |_| try self.append(last);
        return Io.Writer.countSplat(data, splat);
    }

    fn flush(w: *Io.Writer) Io.Writer.Error!void {
        const self: *FlushTrackingWriter = @fieldParentPtr("interface", w);
        self.flush_count += 1;
        try self.append(w.buffer[0..w.end]);
        w.end = 0;
    }

    fn rebase(w: *Io.Writer, preserve: usize, capacity: usize) Io.Writer.Error!void {
        _ = capacity;
        if (preserve > w.end or preserve > w.buffer.len) return error.WriteFailed;
        const start = w.end - preserve;
        std.mem.copyForwards(u8, w.buffer[0..preserve], w.buffer[start..][0..preserve]);
        w.end = preserve;
    }

    fn append(self: *FlushTrackingWriter, bytes: []const u8) Io.Writer.Error!void {
        if (self.flushed_end + bytes.len > self.sink.len) return error.WriteFailed;
        @memcpy(self.sink[self.flushed_end..][0..bytes.len], bytes);
        self.flushed_end += bytes.len;
    }
};

const test_small_binary_payload = [_]u8{ 0xde, 0xad, 0xbe, 0xef, 0x17, 0x42, 0x99, 0x01 };

test "validateUtf8IfEnabled enforces comptime-enabled validation only" {
    const invalid_utf8 = [_]u8{ 0xC3, 0x28 };
    try validateUtf8IfEnabled(false, invalid_utf8[0..]);
    try std.testing.expectError(error.InvalidUtf8, validateUtf8IfEnabled(true, invalid_utf8[0..]));
}

test "neededHeaderLen covers base extended and masked layouts" {
    try std.testing.expectEqual(@as(usize, 2), neededHeaderLen(0x05));
    try std.testing.expectEqual(@as(usize, 6), neededHeaderLen(0x85));
    try std.testing.expectEqual(@as(usize, 4), neededHeaderLen(126));
    try std.testing.expectEqual(@as(usize, 8), neededHeaderLen(0xFE));
    try std.testing.expectEqual(@as(usize, 10), neededHeaderLen(127));
    try std.testing.expectEqual(@as(usize, 14), neededHeaderLen(0xFF));
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
    var conn = Conn(.{}).init(&reader, &writer, .{});

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
    var conn = Conn(.{}).init(&reader, &writer, .{});

    try std.testing.expectError(error.MaskBitInvalid, conn.beginFrame());
}

test "writeFrame writes unmasked server frame" {
    var out: [64]u8 = undefined;
    var writer = Io.Writer.fixed(out[0..]);
    var reader = Io.Reader.fixed(""[0..]);
    var conn = Conn(.{}).init(&reader, &writer, .{});

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
    var conn = Conn(.{}).init(&reader, &writer, .{});

    var msg_buf: [32]u8 = undefined;
    const message = try conn.readMessage(msg_buf[0..]);
    try std.testing.expectEqual(MessageOpcode.text, message.opcode);
    try std.testing.expectEqualStrings("Hello", message.payload);
    try std.testing.expectEqualSlices(u8, &.{ 0x8A, 0x01, '!' }, out[0..writer.end]);
}

test "readMessage flushes auto-pongs and pending buffered writes before blocking again" {
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(std.testing.allocator);
    try appendTestFrame(&wire, std.testing.allocator, .ping, true, true, "!", .{ 1, 2, 3, 4 });
    try appendTestFrame(&wire, std.testing.allocator, .binary, true, true, "go", .{ 5, 6, 7, 8 });

    var reader = Io.Reader.fixed(wire.items);
    var buffer: [32]u8 = undefined;
    var sink: [32]u8 = undefined;
    var writer = FlushTrackingWriter.init(buffer[0..], sink[0..]);
    var conn = Conn(.{}).init(&reader, &writer.interface, .{});

    try conn.writeText("ok");

    var msg_buf: [8]u8 = undefined;
    const msg = try conn.readMessage(msg_buf[0..]);
    try std.testing.expectEqual(MessageOpcode.binary, msg.opcode);
    try std.testing.expectEqualStrings("go", msg.payload);
    try std.testing.expect(writer.flush_count >= 1);
    try std.testing.expectEqualSlices(u8, &.{ 0x81, 0x02, 'o', 'k', 0x8A, 0x01, '!' }, writer.sink[0..writer.flushed_end]);
}

test "client writes masked frame" {
    var out: [64]u8 = undefined;
    var writer = Io.Writer.fixed(out[0..]);
    var reader = Io.Reader.fixed(""[0..]);
    var conn = Conn(.{ .role = .client }).init(&reader, &writer, .{});

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
    var conn = Conn(.{}).init(&reader, &writer, .{});

    var payload: [126]u8 = undefined;
    @memset(payload[0..], 'x');
    try std.testing.expectError(error.ControlFrameTooLarge, conn.writeFrame(.ping, payload[0..], true, false));
}

test "init produces distinct mask streams for different connections" {
    var out1: [64]u8 = undefined;
    var out2: [64]u8 = undefined;
    var writer1 = Io.Writer.fixed(out1[0..]);
    var writer2 = Io.Writer.fixed(out2[0..]);
    var reader1 = Io.Reader.fixed(""[0..]);
    var reader2 = Io.Reader.fixed(""[0..]);
    var conn1 = Conn(.{ .role = .client }).init(&reader1, &writer1, .{});
    var conn2 = Conn(.{ .role = .client }).init(&reader2, &writer2, .{});

    try conn1.writeBinary("ab");
    try conn2.writeBinary("ab");
    try std.testing.expect(!std.mem.eql(u8, out1[2..6], out2[2..6]));
}

test "flush forwards to writer" {
    var out: [16]u8 = undefined;
    var writer = Io.Writer.fixed(out[0..]);
    var reader = Io.Reader.fixed(""[0..]);
    var conn = Conn(.{}).init(&reader, &writer, .{});
    try conn.flush();
}

test "beginFrame rejects reserved bits and unknown opcode" {
    {
        const wire = [_]u8{ 0xC1, 0x80, 1, 2, 3, 4 };
        var reader = Io.Reader.fixed(wire[0..]);
        var sink: [0]u8 = .{};
        var writer = Io.Writer.fixed(sink[0..]);
        var conn = Conn(.{}).init(&reader, &writer, .{});
        try std.testing.expectError(error.ReservedBitsSet, conn.beginFrame());
    }
    {
        const wire = [_]u8{ 0x83, 0x80, 1, 2, 3, 4 };
        var reader = Io.Reader.fixed(wire[0..]);
        var sink: [0]u8 = .{};
        var writer = Io.Writer.fixed(sink[0..]);
        var conn = Conn(.{}).init(&reader, &writer, .{});
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
        var sink: [0]u8 = .{};
        var writer = Io.Writer.fixed(sink[0..]);
        var conn = Conn(.{}).init(&reader, &writer, .{});
        try std.testing.expectError(error.InvalidFrameLength, conn.beginFrame());
    }
    {
        var wire: std.ArrayList(u8) = .empty;
        defer wire.deinit(std.testing.allocator);
        try appendTestFrame(&wire, std.testing.allocator, .binary, true, true, "1234", .{ 1, 2, 3, 4 });
        var reader = Io.Reader.fixed(wire.items);
        var sink: [0]u8 = .{};
        var writer = Io.Writer.fixed(sink[0..]);
        var conn = Conn(.{}).init(&reader, &writer, .{ .max_frame_payload_len = 3 });
        try std.testing.expectError(error.FrameTooLarge, conn.beginFrame());
    }
    {
        const wire = [_]u8{
            0x82,
            0xFE,
            0x00,
            0x7D,
            1,
            2,
            3,
            4,
        };
        var reader = Io.Reader.fixed(wire[0..]);
        var sink: [0]u8 = .{};
        var writer = Io.Writer.fixed(sink[0..]);
        var conn = Conn(.{}).init(&reader, &writer, .{});
        try std.testing.expectError(error.InvalidFrameLength, conn.beginFrame());
    }
    {
        const wire = [_]u8{
            0x82,
            0xFF,
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
            0xFF,
            0xFF,
            1,
            2,
            3,
            4,
        };
        var reader = Io.Reader.fixed(wire[0..]);
        var sink: [0]u8 = .{};
        var writer = Io.Writer.fixed(sink[0..]);
        var conn = Conn(.{}).init(&reader, &writer, .{});
        try std.testing.expectError(error.InvalidFrameLength, conn.beginFrame());
    }
}

test "beginFrame enforces control frame rules and continuation sequencing" {
    {
        var wire: std.ArrayList(u8) = .empty;
        defer wire.deinit(std.testing.allocator);
        try appendTestFrame(&wire, std.testing.allocator, .ping, false, true, "", .{ 1, 2, 3, 4 });
        var reader = Io.Reader.fixed(wire.items);
        var sink: [0]u8 = .{};
        var writer = Io.Writer.fixed(sink[0..]);
        var conn = Conn(.{}).init(&reader, &writer, .{});
        try std.testing.expectError(error.ControlFrameFragmented, conn.beginFrame());
    }
    {
        var payload: [126]u8 = undefined;
        @memset(payload[0..], 'x');
        var wire: std.ArrayList(u8) = .empty;
        defer wire.deinit(std.testing.allocator);
        try appendTestFrame(&wire, std.testing.allocator, .ping, true, true, payload[0..], .{ 1, 2, 3, 4 });
        var reader = Io.Reader.fixed(wire.items);
        var sink: [0]u8 = .{};
        var writer = Io.Writer.fixed(sink[0..]);
        var conn = Conn(.{}).init(&reader, &writer, .{});
        try std.testing.expectError(error.ControlFrameTooLarge, conn.beginFrame());
    }
    {
        var wire: std.ArrayList(u8) = .empty;
        defer wire.deinit(std.testing.allocator);
        try appendTestFrame(&wire, std.testing.allocator, .continuation, true, true, "x", .{ 1, 2, 3, 4 });
        var reader = Io.Reader.fixed(wire.items);
        var sink: [0]u8 = .{};
        var writer = Io.Writer.fixed(sink[0..]);
        var conn = Conn(.{}).init(&reader, &writer, .{});
        try std.testing.expectError(error.UnexpectedContinuation, conn.beginFrame());
    }
    {
        var wire: std.ArrayList(u8) = .empty;
        defer wire.deinit(std.testing.allocator);
        try appendTestFrame(&wire, std.testing.allocator, .text, false, true, "hel", .{ 1, 2, 3, 4 });
        try appendTestFrame(&wire, std.testing.allocator, .binary, true, true, "bad", .{ 5, 6, 7, 8 });
        var reader = Io.Reader.fixed(wire.items);
        var sink: [0]u8 = .{};
        var writer = Io.Writer.fixed(sink[0..]);
        var conn = Conn(.{}).init(&reader, &writer, .{});
        _ = try conn.beginFrame();
        try conn.discardFrame();
        try std.testing.expectError(error.ExpectedContinuation, conn.beginFrame());
    }
}

test "beginFrame supports client role and extended lengths" {
    {
        const wire = [_]u8{ 0x82, 0x02, 'o', 'k' };
        var reader = Io.Reader.fixed(wire[0..]);
        var sink: [0]u8 = .{};
        var writer = Io.Writer.fixed(sink[0..]);
        var conn = Conn(.{ .role = .client }).init(&reader, &writer, .{});
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
        var sink: [0]u8 = .{};
        var writer = Io.Writer.fixed(sink[0..]);
        var conn = Conn(.{ .role = .client }).init(&reader, &writer, .{});
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
        var sink: [0]u8 = .{};
        var writer = Io.Writer.fixed(sink[0..]);
        var conn = Conn(.{ .role = .client }).init(&reader, &writer, .{});
        const header = try conn.beginFrame();
        try std.testing.expectEqual(@as(u64, 65536), header.payload_len);
    }
}

test "readFrameChunk and readFrameAll enforce active frame semantics" {
    var reader = Io.Reader.fixed(""[0..]);
    var sink: [0]u8 = .{};
    var writer = Io.Writer.fixed(sink[0..]);
    var conn = Conn(.{}).init(&reader, &writer, .{});
    var tmp: [4]u8 = undefined;

    try std.testing.expectError(error.NoActiveFrame, conn.readFrameChunk(tmp[0..]));
    try std.testing.expectError(error.NoActiveFrame, conn.readFrameAll(tmp[0..]));
    try std.testing.expectError(error.NoActiveFrame, conn.discardFrame());
}

test "readFrameChunk handles recv_remaining values larger than usize" {
    var reader = Io.Reader.fixed("ab"[0..]);
    var sink: [0]u8 = .{};
    var writer = Io.Writer.fixed(sink[0..]);
    var conn = Conn(.{}).init(&reader, &writer, .{});
    conn.recv_active = true;
    conn.recv_header = .{
        .fin = true,
        .masked = false,
        .opcode = .binary,
        .payload_len = std.math.maxInt(u64),
    };
    conn.recv_remaining = std.math.maxInt(u64);

    var buf: [2]u8 = undefined;
    const chunk = try conn.readFrameChunk(buf[0..]);
    try std.testing.expectEqualStrings("ab", chunk);
    try std.testing.expectEqual(std.math.maxInt(u64) - 2, conn.recv_remaining);
    try std.testing.expect(conn.recv_active);
}

test "beginFrameBorrowed returns FrameActive while a streamed frame is active" {
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(std.testing.allocator);
    try appendTestFrame(&wire, std.testing.allocator, .binary, true, true, "abc", .{ 1, 2, 3, 4 });

    var reader = Io.Reader.fixed(wire.items);
    var sink: [0]u8 = .{};
    var writer = Io.Writer.fixed(sink[0..]);
    var conn = Conn(.{}).init(&reader, &writer, .{});

    _ = try conn.beginFrame();
    try std.testing.expectError(error.FrameActive, conn.beginFrameBorrowed());
}

test "readFrameBorrowed returns null when the buffered reader cannot hold the frame" {
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(std.testing.allocator);
    try appendTestFrame(&wire, std.testing.allocator, .binary, true, true, "abc", .{ 1, 2, 3, 4 });

    var base_reader = Io.Reader.fixed(wire.items);
    var indirect_buffer: [6]u8 = undefined;
    var indirect = std.testing.ReaderIndirect.init(&base_reader, indirect_buffer[0..]);

    var sink: [0]u8 = .{};
    var writer = Io.Writer.fixed(sink[0..]);
    var conn = Conn(.{}).init(&indirect.interface, &writer, .{});

    try std.testing.expect((try conn.readFrameBorrowed()) == null);
}

test "readFrameChunk zero length does not consume payload and discardFrame drains current frame" {
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(std.testing.allocator);
    try appendTestFrame(&wire, std.testing.allocator, .binary, true, true, "abc", .{ 1, 2, 3, 4 });
    try appendTestFrame(&wire, std.testing.allocator, .text, true, true, "z", .{ 5, 6, 7, 8 });

    var reader = Io.Reader.fixed(wire.items);
    var sink: [0]u8 = .{};
    var writer = Io.Writer.fixed(sink[0..]);
    var conn = Conn(.{}).init(&reader, &writer, .{});

    _ = try conn.beginFrame();
    var empty: [0]u8 = .{};
    try std.testing.expectEqual(@as(usize, 0), (try conn.readFrameChunk(empty[0..])).len);

    var buf: [3]u8 = undefined;
    try std.testing.expectEqualStrings("abc", try conn.readFrameAll(buf[0..]));

    const next = try conn.readFrame(buf[0..]);
    try std.testing.expectEqual(Opcode.text, next.header.opcode);
    try std.testing.expectEqualStrings("z", next.payload);
}

test "readFrameChunk unmasks correctly across multiple chunk reads" {
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(std.testing.allocator);
    try appendTestFrame(&wire, std.testing.allocator, .binary, true, true, "hello", .{ 1, 2, 3, 4 });

    var reader = Io.Reader.fixed(wire.items);
    var sink: [0]u8 = .{};
    var writer = Io.Writer.fixed(sink[0..]);
    var conn = Conn(.{}).init(&reader, &writer, .{});

    _ = try conn.beginFrame();
    var first: [2]u8 = undefined;
    var second: [3]u8 = undefined;
    try std.testing.expectEqualStrings("he", try conn.readFrameChunk(first[0..]));
    try std.testing.expect(conn.recv_active);
    try std.testing.expectEqualStrings("llo", try conn.readFrameChunk(second[0..]));
    try std.testing.expect(!conn.recv_active);
}

test "readFrameAll rejects destination that is too small and zero payload frames work" {
    {
        var wire: std.ArrayList(u8) = .empty;
        defer wire.deinit(std.testing.allocator);
        try appendTestFrame(&wire, std.testing.allocator, .binary, true, true, "abcd", .{ 1, 2, 3, 4 });
        var reader = Io.Reader.fixed(wire.items);
        var sink: [0]u8 = .{};
        var writer = Io.Writer.fixed(sink[0..]);
        var conn = Conn(.{}).init(&reader, &writer, .{});
        _ = try conn.beginFrame();
        var buf: [3]u8 = undefined;
        try std.testing.expectError(error.MessageTooLarge, conn.readFrameAll(buf[0..]));
    }
    {
        var wire: std.ArrayList(u8) = .empty;
        defer wire.deinit(std.testing.allocator);
        try appendTestFrame(&wire, std.testing.allocator, .pong, true, true, "", .{ 1, 2, 3, 4 });
        var reader = Io.Reader.fixed(wire.items);
        var sink: [0]u8 = .{};
        var writer = Io.Writer.fixed(sink[0..]);
        var conn = Conn(.{}).init(&reader, &writer, .{});
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
        var conn = Conn(.{ .auto_pong = false }).init(&reader, &writer, .{});
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
        var conn = Conn(.{}).init(&reader, &writer, .{});
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
        var conn = Conn(.{ .auto_reply_close = false }).init(&reader, &writer, .{});
        var buf: [1]u8 = undefined;
        try std.testing.expectError(error.ConnectionClosed, conn.readMessage(buf[0..]));
        try std.testing.expect(conn.close_received);
        try std.testing.expect(!conn.close_sent);
        try std.testing.expectEqual(@as(usize, 0), writer.end);
    }
}

test "readMessage flushes auto-close replies and pending buffered writes" {
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(std.testing.allocator);
    const close_payload = [_]u8{ 0x03, 0xE8, 'b', 'y', 'e' };
    try appendTestFrame(&wire, std.testing.allocator, .close, true, true, close_payload[0..], .{ 1, 2, 3, 4 });

    var reader = Io.Reader.fixed(wire.items);
    var buffer: [32]u8 = undefined;
    var sink: [32]u8 = undefined;
    var writer = FlushTrackingWriter.init(buffer[0..], sink[0..]);
    var conn = Conn(.{}).init(&reader, &writer.interface, .{});

    try conn.writeText("ok");

    var msg_buf: [8]u8 = undefined;
    try std.testing.expectError(error.ConnectionClosed, conn.readMessage(msg_buf[0..]));
    try std.testing.expect(writer.flush_count >= 1);
    try std.testing.expectEqualSlices(u8, &.{ 0x81, 0x02, 'o', 'k', 0x88, 0x05, 0x03, 0xE8, 'b', 'y', 'e' }, writer.sink[0..writer.flushed_end]);
}

test "readMessage clears fragmented receive state when a close interrupts a message" {
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(std.testing.allocator);
    try appendTestFrame(&wire, std.testing.allocator, .text, false, true, "abc", .{ 1, 2, 3, 4 });
    try appendTestFrame(&wire, std.testing.allocator, .close, true, true, "", .{ 5, 6, 7, 8 });

    var reader = Io.Reader.fixed(wire.items);
    var out: [8]u8 = undefined;
    var writer = Io.Writer.fixed(out[0..]);
    var conn = Conn(.{}).init(&reader, &writer, .{});
    var buf: [8]u8 = undefined;

    try std.testing.expectError(error.ConnectionClosed, conn.readMessage(buf[0..]));
    try std.testing.expect(conn.close_received);
    try std.testing.expect(conn.recv_fragment_opcode == null);
    try std.testing.expectEqualSlices(u8, &.{ 0x88, 0x00 }, out[0..writer.end]);
}

test "readMessage ignores ping frames after a local close has already been sent" {
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(std.testing.allocator);
    try appendTestFrame(&wire, std.testing.allocator, .ping, true, true, "!", .{ 1, 2, 3, 4 });
    try appendTestFrame(&wire, std.testing.allocator, .close, true, true, "", .{ 5, 6, 7, 8 });

    var reader = Io.Reader.fixed(wire.items);
    var out: [8]u8 = undefined;
    var writer = Io.Writer.fixed(out[0..]);
    var conn = Conn(.{}).init(&reader, &writer, .{});
    try conn.writeClose(null, "");

    var buf: [1]u8 = undefined;
    try std.testing.expectError(error.ConnectionClosed, conn.readMessage(buf[0..]));
    try std.testing.expect(conn.close_received);
    try std.testing.expectEqualSlices(u8, &.{ 0x88, 0x00 }, out[0..writer.end]);
}

test "readMessage enforces utf8 and message size limits" {
    {
        const invalid_utf8 = [_]u8{ 0xC3, 0x28 };
        var wire: std.ArrayList(u8) = .empty;
        defer wire.deinit(std.testing.allocator);
        try appendTestFrame(&wire, std.testing.allocator, .text, true, true, invalid_utf8[0..], .{ 1, 2, 3, 4 });
        var reader = Io.Reader.fixed(wire.items);
        var sink: [0]u8 = .{};
        var writer = Io.Writer.fixed(sink[0..]);
        var conn = Conn(.{}).init(&reader, &writer, .{});
        var buf: [8]u8 = undefined;
        try std.testing.expectError(error.InvalidUtf8, conn.readMessage(buf[0..]));
    }
    {
        var wire: std.ArrayList(u8) = .empty;
        defer wire.deinit(std.testing.allocator);
        try appendTestFrame(&wire, std.testing.allocator, .text, false, true, "abc", .{ 1, 2, 3, 4 });
        try appendTestFrame(&wire, std.testing.allocator, .continuation, true, true, "de", .{ 5, 6, 7, 8 });
        var reader = Io.Reader.fixed(wire.items);
        var sink: [0]u8 = .{};
        var writer = Io.Writer.fixed(sink[0..]);
        var conn = Conn(.{}).init(&reader, &writer, .{ .max_message_payload_len = 4 });
        var buf: [8]u8 = undefined;
        try std.testing.expectError(error.MessageTooLarge, conn.readMessage(buf[0..]));
    }
}

test "readMessage drains oversized frames before returning MessageTooLarge" {
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(std.testing.allocator);
    try appendTestFrame(&wire, std.testing.allocator, .binary, true, true, "abcd", .{ 1, 2, 3, 4 });
    try appendTestFrame(&wire, std.testing.allocator, .text, true, true, "z", .{ 5, 6, 7, 8 });

    var reader = Io.Reader.fixed(wire.items);
    var sink: [0]u8 = .{};
    var writer = Io.Writer.fixed(sink[0..]);
    var conn = Conn(.{}).init(&reader, &writer, .{});

    var msg_buf: [3]u8 = undefined;
    try std.testing.expectError(error.MessageTooLarge, conn.readMessage(msg_buf[0..]));
    try std.testing.expect(!conn.recv_active);

    var frame_buf: [1]u8 = undefined;
    const next = try conn.readFrame(frame_buf[0..]);
    try std.testing.expectEqual(Opcode.text, next.header.opcode);
    try std.testing.expectEqualStrings("z", next.payload);
}

test "readMessage drains fragmented oversized messages and preserves next message boundary" {
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(std.testing.allocator);
    try appendTestFrame(&wire, std.testing.allocator, .text, false, true, "abc", .{ 1, 2, 3, 4 });
    try appendTestFrame(&wire, std.testing.allocator, .ping, true, true, "!", .{ 5, 6, 7, 8 });
    try appendTestFrame(&wire, std.testing.allocator, .continuation, true, true, "de", .{ 9, 10, 11, 12 });
    try appendTestFrame(&wire, std.testing.allocator, .binary, true, true, "ok", .{ 13, 14, 15, 16 });

    var reader = Io.Reader.fixed(wire.items);
    var out: [8]u8 = undefined;
    var writer = Io.Writer.fixed(out[0..]);
    var conn = Conn(.{}).init(&reader, &writer, .{});

    var msg_buf: [2]u8 = undefined;
    try std.testing.expectError(error.MessageTooLarge, conn.readMessage(msg_buf[0..]));
    try std.testing.expect(!conn.recv_active);
    try std.testing.expect(conn.recv_fragment_opcode == null);
    try std.testing.expectEqualSlices(u8, &.{ 0x8A, 0x01, '!' }, out[0..writer.end]);

    var frame_buf: [2]u8 = undefined;
    const next = try conn.readFrame(frame_buf[0..]);
    try std.testing.expectEqual(Opcode.binary, next.header.opcode);
    try std.testing.expectEqualStrings("ok", next.payload);
}

test "discardRemainingMessage flushes auto-pongs while draining oversized fragmented messages" {
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(std.testing.allocator);
    try appendTestFrame(&wire, std.testing.allocator, .text, false, true, "abc", .{ 1, 2, 3, 4 });
    try appendTestFrame(&wire, std.testing.allocator, .ping, true, true, "!", .{ 5, 6, 7, 8 });
    try appendTestFrame(&wire, std.testing.allocator, .continuation, true, true, "de", .{ 9, 10, 11, 12 });

    var reader = Io.Reader.fixed(wire.items);
    var buffer: [32]u8 = undefined;
    var sink: [32]u8 = undefined;
    var writer = FlushTrackingWriter.init(buffer[0..], sink[0..]);
    var conn = Conn(.{}).init(&reader, &writer.interface, .{});

    try conn.writeText("ok");

    var msg_buf: [2]u8 = undefined;
    try std.testing.expectError(error.MessageTooLarge, conn.readMessage(msg_buf[0..]));
    try std.testing.expect(writer.flush_count >= 1);
    try std.testing.expectEqualSlices(u8, &.{ 0x81, 0x02, 'o', 'k', 0x8A, 0x01, '!' }, writer.sink[0..writer.flushed_end]);
}

test "readMessage drains fragmented messages that exceed configured max size" {
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(std.testing.allocator);
    try appendTestFrame(&wire, std.testing.allocator, .text, false, true, "abc", .{ 1, 2, 3, 4 });
    try appendTestFrame(&wire, std.testing.allocator, .continuation, false, true, "de", .{ 5, 6, 7, 8 });
    try appendTestFrame(&wire, std.testing.allocator, .continuation, true, true, "f", .{ 9, 10, 11, 12 });
    try appendTestFrame(&wire, std.testing.allocator, .binary, true, true, "ok", .{ 13, 14, 15, 16 });

    var reader = Io.Reader.fixed(wire.items);
    var sink: [0]u8 = .{};
    var writer = Io.Writer.fixed(sink[0..]);
    var conn = Conn(.{}).init(&reader, &writer, .{ .max_message_payload_len = 4 });

    var msg_buf: [8]u8 = undefined;
    try std.testing.expectError(error.MessageTooLarge, conn.readMessage(msg_buf[0..]));
    try std.testing.expect(!conn.recv_active);
    try std.testing.expect(conn.recv_fragment_opcode == null);

    var frame_buf: [2]u8 = undefined;
    const next = try conn.readFrame(frame_buf[0..]);
    try std.testing.expectEqual(Opcode.binary, next.header.opcode);
    try std.testing.expectEqualStrings("ok", next.payload);
}

test "writeFrame supports extended lengths and sequencing rules" {
    {
        var payload: [126]u8 = undefined;
        @memset(payload[0..], 'a');
        var out: [256]u8 = undefined;
        var writer = Io.Writer.fixed(out[0..]);
        var reader = Io.Reader.fixed(""[0..]);
        var conn = Conn(.{}).init(&reader, &writer, .{});
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
        var conn = Conn(.{}).init(&reader, &writer, .{});
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
        var conn = Conn(.{}).init(&reader, &writer, .{});
        try conn.writeFrame(.text, "hel", false, false);
        try std.testing.expectError(error.FragmentWriteInProgress, conn.writeFrame(.binary, "x", true, false));
        try conn.writeFrame(.continuation, "lo", true, false);
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
        var conn = Conn(.{}).init(&reader, &writer, .{});
        try std.testing.expectError(error.UnexpectedContinuationWrite, conn.writeFrame(.continuation, "x", true, false));
        try std.testing.expectError(error.ControlFrameFragmented, conn.writeFrame(.ping, "", false, false));
    }
    {
        var out: [8]u8 = undefined;
        var writer = Io.Writer.fixed(out[0..]);
        var reader = Io.Reader.fixed(""[0..]);
        var conn = Conn(.{}).init(&reader, &writer, .{});
        try conn.writeFrame(.text, "", true, true);
        try std.testing.expectEqualSlices(u8, &.{ 0xC1, 0x00 }, out[0..writer.end]);
    }
    {
        var payload: [126]u8 = undefined;
        @memset(payload[0..], 'm');
        var out: [256]u8 = undefined;
        var writer = Io.Writer.fixed(out[0..]);
        var reader = Io.Reader.fixed(""[0..]);
        var conn = Conn(.{ .role = .client }).init(&reader, &writer, .{});
        try conn.writeBinary(payload[0..]);
        try std.testing.expectEqual(@as(u8, 0x82), out[0]);
        try std.testing.expectEqual(@as(u8, 0xFE), out[1]);
        try std.testing.expectEqual(@as(u8, 0), out[2]);
        try std.testing.expectEqual(@as(u8, 126), out[3]);
        try std.testing.expectEqual(@as(usize, 4 + 4 + 126), writer.end);
    }
}

test "writeText writePing writePong and writeClose validate inputs" {
    {
        const invalid_utf8 = [_]u8{ 0xC3, 0x28 };
        var out: [16]u8 = undefined;
        var writer = Io.Writer.fixed(out[0..]);
        var reader = Io.Reader.fixed(""[0..]);
        var conn = Conn(.{}).init(&reader, &writer, .{});
        try std.testing.expectError(error.InvalidUtf8, conn.writeText(invalid_utf8[0..]));
    }
    {
        var payload: [126]u8 = undefined;
        @memset(payload[0..], 'x');
        var out: [16]u8 = undefined;
        var writer = Io.Writer.fixed(out[0..]);
        var reader = Io.Reader.fixed(""[0..]);
        var conn = Conn(.{}).init(&reader, &writer, .{});
        try std.testing.expectError(error.ControlFrameTooLarge, conn.writePing(payload[0..]));
        try std.testing.expectError(error.ControlFrameTooLarge, conn.writePong(payload[0..]));
    }
    {
        var out: [256]u8 = undefined;
        var writer = Io.Writer.fixed(out[0..]);
        var reader = Io.Reader.fixed(""[0..]);
        var conn = Conn(.{}).init(&reader, &writer, .{});
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
    {
        var out: [64]u8 = undefined;
        var writer = Io.Writer.fixed(out[0..]);
        var reader = Io.Reader.fixed(""[0..]);
        var conn = Conn(.{}).init(&reader, &writer, .{});
        try conn.writeClose(null, "");
        try std.testing.expectError(error.ConnectionClosed, conn.writeText("x"));
        try std.testing.expectError(error.ConnectionClosed, conn.writeBinary("x"));
        try std.testing.expectError(error.ConnectionClosed, conn.writePing(""));
        try std.testing.expectError(error.ConnectionClosed, conn.writePong(""));
        try std.testing.expectError(error.ConnectionClosed, conn.writeClose(null, ""));
        try std.testing.expectEqualSlices(u8, &.{ 0x88, 0x00 }, out[0..writer.end]);
    }
}

test "client control writers emit masked frames" {
    var out: [64]u8 = undefined;
    var writer = Io.Writer.fixed(out[0..]);
    var reader = Io.Reader.fixed(""[0..]);
    var conn = Conn(.{ .role = .client }).init(&reader, &writer, .{});

    try conn.writePing("!");
    try conn.writePong("?");

    const written = out[0..writer.end];
    try std.testing.expectEqual(@as(u8, 0x89), written[0]);
    try std.testing.expectEqual(@as(u8, 0x81), written[1]);
    try std.testing.expectEqual(written[6], '!' ^ written[2]);
    try std.testing.expectEqual(@as(u8, 0x8A), written[7]);
    try std.testing.expectEqual(@as(u8, 0x81), written[8]);
    try std.testing.expectEqual(written[13], '?' ^ written[9]);
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
        const close = try parseClosePayload(&[_]u8{ 0x03, 0xE8 }, true);
        try std.testing.expectEqual(@as(?u16, 1000), close.code);
        try std.testing.expectEqual(@as(usize, 0), close.reason.len);
    }
    {
        const payload = [_]u8{ 0x03, 0xE8, 0xC3, 0x28 };
        const close = try parseClosePayload(payload[0..], false);
        try std.testing.expectEqual(@as(?u16, 1000), close.code);
        try std.testing.expectEqualSlices(u8, &.{ 0xC3, 0x28 }, close.reason);
    }
    try std.testing.expectError(error.InvalidUtf8, parseClosePayload(&[_]u8{ 0x03, 0xE8, 0xC3, 0x28 }, true));
}

test "readFrameBorrowed unmasks payload without a copy" {
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(std.testing.allocator);
    try appendTestFrame(&wire, std.testing.allocator, .text, true, true, "borrowed", .{ 1, 2, 3, 4 });

    var reader = Io.Reader.fixed(wire.items);
    var sink: [0]u8 = .{};
    var writer = Io.Writer.fixed(sink[0..]);
    var conn = Conn(.{}).init(&reader, &writer, .{});

    const frame = (try conn.readFrameBorrowed()).?;
    try std.testing.expectEqual(Opcode.text, frame.header.opcode);
    try std.testing.expect(frame.header.fin);
    try std.testing.expectEqualStrings("borrowed", frame.payload);
}

test "readMessageBorrowed returns unfragmented borrowed message and preserves fallback for fragmented data" {
    {
        var wire: std.ArrayList(u8) = .empty;
        defer wire.deinit(std.testing.allocator);
        try appendTestFrame(&wire, std.testing.allocator, .text, true, true, "hello", .{ 1, 2, 3, 4 });

        var reader = Io.Reader.fixed(wire.items);
        var sink: [0]u8 = .{};
        var writer = Io.Writer.fixed(sink[0..]);
        var conn = Conn(.{}).init(&reader, &writer, .{});

        const message = (try conn.readMessageBorrowed()).?;
        try std.testing.expectEqual(MessageOpcode.text, message.opcode);
        try std.testing.expectEqualStrings("hello", message.payload);
    }
    {
        var wire: std.ArrayList(u8) = .empty;
        defer wire.deinit(std.testing.allocator);
        try appendTestFrame(&wire, std.testing.allocator, .text, false, true, "hel", .{ 1, 2, 3, 4 });
        try appendTestFrame(&wire, std.testing.allocator, .continuation, true, true, "lo", .{ 5, 6, 7, 8 });

        var reader = Io.Reader.fixed(wire.items);
        var sink: [0]u8 = .{};
        var writer = Io.Writer.fixed(sink[0..]);
        var conn = Conn(.{}).init(&reader, &writer, .{});
        try std.testing.expect((try conn.readMessageBorrowed()) == null);

        var buf: [16]u8 = undefined;
        const message = try conn.readMessage(buf[0..]);
        try std.testing.expectEqual(MessageOpcode.text, message.opcode);
        try std.testing.expectEqualStrings("hello", message.payload);
    }
}

test "readFrameBorrowed handles empty payload control frames" {
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(std.testing.allocator);
    try appendTestFrame(&wire, std.testing.allocator, .ping, true, true, "", .{ 1, 2, 3, 4 });

    var reader = Io.Reader.fixed(wire.items);
    var sink: [0]u8 = .{};
    var writer = Io.Writer.fixed(sink[0..]);
    var conn = Conn(.{}).init(&reader, &writer, .{});

    const frame = (try conn.readFrameBorrowed()).?;
    try std.testing.expectEqual(Opcode.ping, frame.header.opcode);
    try std.testing.expectEqual(@as(usize, 0), frame.payload.len);
}

test "readFrameBorrowed supports unmasked client-role frames" {
    const wire = [_]u8{ 0x82, 0x02, 'o', 'k' };
    var reader = Io.Reader.fixed(wire[0..]);
    var sink: [0]u8 = .{};
    var writer = Io.Writer.fixed(sink[0..]);
    var conn = Conn(.{ .role = .client }).init(&reader, &writer, .{});

    const frame = (try conn.readFrameBorrowed()).?;
    try std.testing.expectEqual(Opcode.binary, frame.header.opcode);
    try std.testing.expectEqualStrings("ok", frame.payload);
}

test "readFrameBorrowed returns null for payload sizes that cannot fit in usize" {
    const wire = [_]u8{
        0x82,
        0xFF,
        0x7F,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        1,
        2,
        3,
        4,
    };
    var reader = Io.Reader.fixed(wire[0..]);
    var sink: [0]u8 = .{};
    var writer = Io.Writer.fixed(sink[0..]);
    var conn = Conn(.{}).init(&reader, &writer, .{});

    try std.testing.expect((try conn.readFrameBorrowed()) == null);
}

test "readMessage accepts empty text messages" {
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(std.testing.allocator);
    try appendTestFrame(&wire, std.testing.allocator, .text, true, true, "", .{ 1, 2, 3, 4 });

    var reader = Io.Reader.fixed(wire.items);
    var sink: [0]u8 = .{};
    var writer = Io.Writer.fixed(sink[0..]);
    var conn = Conn(.{}).init(&reader, &writer, .{});
    var buf: [1]u8 = undefined;

    const msg = try conn.readMessage(buf[0..]);
    try std.testing.expectEqual(MessageOpcode.text, msg.opcode);
    try std.testing.expectEqual(@as(usize, 0), msg.payload.len);
}

test "readMessage handles control frames interleaved with fragments" {
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(std.testing.allocator);
    try appendTestFrame(&wire, std.testing.allocator, .text, false, true, "he", .{ 1, 2, 3, 4 });
    try appendTestFrame(&wire, std.testing.allocator, .ping, true, true, "!", .{ 5, 6, 7, 8 });
    try appendTestFrame(&wire, std.testing.allocator, .continuation, true, true, "llo", .{ 9, 10, 11, 12 });

    var reader = Io.Reader.fixed(wire.items);
    var out: [8]u8 = undefined;
    var writer = Io.Writer.fixed(out[0..]);
    var conn = Conn(.{}).init(&reader, &writer, .{});
    var buf: [8]u8 = undefined;

    const msg = try conn.readMessage(buf[0..]);
    try std.testing.expectEqual(MessageOpcode.text, msg.opcode);
    try std.testing.expectEqualStrings("hello", msg.payload);
    try std.testing.expectEqualSlices(u8, &.{ 0x8A, 0x01, '!' }, out[0..writer.end]);
}

test "readMessage resumes fragmented messages after frame-level reads" {
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(std.testing.allocator);
    try appendTestFrame(&wire, std.testing.allocator, .text, false, true, "he", .{ 1, 2, 3, 4 });
    try appendTestFrame(&wire, std.testing.allocator, .continuation, true, true, "llo", .{ 5, 6, 7, 8 });

    var reader = Io.Reader.fixed(wire.items);
    var sink: [0]u8 = .{};
    var writer = Io.Writer.fixed(sink[0..]);
    var conn = Conn(.{}).init(&reader, &writer, .{});
    var frame_buf: [4]u8 = undefined;
    const frame = try conn.readFrame(frame_buf[0..]);
    try std.testing.expectEqual(Opcode.text, frame.header.opcode);
    try std.testing.expectEqualStrings("he", frame.payload);

    var msg_buf: [8]u8 = undefined;
    const msg = try conn.readMessage(msg_buf[0..]);
    try std.testing.expectEqual(MessageOpcode.text, msg.opcode);
    try std.testing.expectEqualStrings("llo", msg.payload);
}

test "permessage-deflate client/server roundtrip preserves message payloads" {
    const pmd_cfg: PerMessageDeflateConfig = .{
        .allocator = std.testing.allocator,
        .compress_outgoing = true,
    };

    var out: [1024]u8 = undefined;
    var client_writer = Io.Writer.fixed(out[0..]);
    var empty_reader = Io.Reader.fixed(""[0..]);
    var client = Conn(.{ .role = .client }).init(&empty_reader, &client_writer, .{
        .permessage_deflate = pmd_cfg,
    });

    const payload = "zwebsocket interop text payload with enough repetition to exercise permessage-deflate";
    try client.writeText(payload);

    var server_reader = Io.Reader.fixed(out[0..client_writer.end]);
    var sink: [0]u8 = .{};
    var server_writer = Io.Writer.fixed(sink[0..]);
    var server = Conn(.{}).init(&server_reader, &server_writer, .{
        .permessage_deflate = pmd_cfg,
    });
    var message_buf: [256]u8 = undefined;
    const message = try server.readMessage(message_buf[0..]);
    try std.testing.expectEqual(MessageOpcode.text, message.opcode);
    try std.testing.expectEqualStrings(payload, message.payload);
}

test "permessage-deflate roundtrip preserves incompressible binary payloads" {
    const pmd_cfg: PerMessageDeflateConfig = .{
        .allocator = std.testing.allocator,
        .compress_outgoing = true,
    };

    var binary_payload: [512]u8 = undefined;
    for (&binary_payload, 0..) |*b, i| {
        b.* = @truncate((i * 29 + 11) & 0xff);
    }

    var out: [4096]u8 = undefined;
    var client_writer = Io.Writer.fixed(out[0..]);
    var empty_reader = Io.Reader.fixed(""[0..]);
    var client = Conn(.{ .role = .client }).init(&empty_reader, &client_writer, .{
        .permessage_deflate = pmd_cfg,
    });
    try client.writeBinary(binary_payload[0..]);

    var server_reader = Io.Reader.fixed(out[0..client_writer.end]);
    var sink: [0]u8 = .{};
    var server_writer = Io.Writer.fixed(sink[0..]);
    var server = Conn(.{}).init(&server_reader, &server_writer, .{
        .permessage_deflate = pmd_cfg,
    });
    var message_buf: [1024]u8 = undefined;
    const message = try server.readMessage(message_buf[0..]);
    try std.testing.expectEqual(MessageOpcode.binary, message.opcode);
    try std.testing.expectEqualSlices(u8, binary_payload[0..], message.payload);
}

test "permessage-deflate context takeover roundtrip across multiple messages" {
    const TakeoverClient = Conn(.{
        .role = .client,
        .permessage_deflate_context_takeover = true,
        .permessage_deflate_min_payload_len = 1,
        .permessage_deflate_require_compression_gain = false,
    });
    const TakeoverServer = Conn(.{
        .role = .server,
        .permessage_deflate_context_takeover = true,
        .permessage_deflate_min_payload_len = 1,
        .permessage_deflate_require_compression_gain = false,
    });
    const negotiated: extensions.PerMessageDeflate = .{
        .server_no_context_takeover = false,
        .client_no_context_takeover = false,
    };
    const pmd_cfg: PerMessageDeflateConfig = .{
        .allocator = std.testing.allocator,
        .negotiated = negotiated,
        .compress_outgoing = true,
    };

    var wire: [2048]u8 = undefined;
    var client_writer = Io.Writer.fixed(wire[0..]);
    var empty_reader = Io.Reader.fixed(""[0..]);
    var client = TakeoverClient.init(&empty_reader, &client_writer, .{
        .permessage_deflate = pmd_cfg,
    });
    defer client.deinit();

    const m1 = "hello hello hello";
    const m2 = "hello hello hello again";
    try client.writeText(m1);
    try client.writeText(m2);

    var server_reader = Io.Reader.fixed(wire[0..client_writer.end]);
    var sink: [0]u8 = .{};
    var server_writer = Io.Writer.fixed(sink[0..]);
    var server = TakeoverServer.init(&server_reader, &server_writer, .{
        .permessage_deflate = pmd_cfg,
    });
    defer server.deinit();
    var message_buf: [256]u8 = undefined;

    const got1 = try server.readMessage(message_buf[0..]);
    try std.testing.expectEqual(MessageOpcode.text, got1.opcode);
    try std.testing.expectEqualStrings(m1, got1.payload);

    const got2 = try server.readMessage(message_buf[0..]);
    try std.testing.expectEqual(MessageOpcode.text, got2.opcode);
    try std.testing.expectEqualStrings(m2, got2.payload);
}

test "writeMessage skips compression below configured payload threshold" {
    const TunedConn = Conn(.{
        .permessage_deflate_min_payload_len = 32,
        .permessage_deflate_require_compression_gain = false,
    });
    var wire: [128]u8 = undefined;
    var writer = Io.Writer.fixed(wire[0..]);
    var empty_reader = Io.Reader.fixed(""[0..]);
    var conn = TunedConn.init(&empty_reader, &writer, .{
        .permessage_deflate = .{
            .allocator = std.testing.allocator,
            .compress_outgoing = true,
        },
    });

    try conn.writeText("tiny");
    try std.testing.expectEqual(@as(u8, 0x81), wire[0]);
    try std.testing.expectEqual(@as(u8, 4), wire[1]);
    try std.testing.expectEqualStrings("tiny", wire[2 .. 2 + 4]);
}

test "writeMessage skips non-beneficial compression when gain is required" {
    const TunedConn = Conn(.{
        .permessage_deflate_min_payload_len = 1,
        .permessage_deflate_require_compression_gain = true,
    });
    var wire: [256]u8 = undefined;
    var writer = Io.Writer.fixed(wire[0..]);
    var empty_reader = Io.Reader.fixed(""[0..]);
    var conn = TunedConn.init(&empty_reader, &writer, .{
        .permessage_deflate = .{
            .allocator = std.testing.allocator,
            .compress_outgoing = true,
        },
    });

    try conn.writeBinary(test_small_binary_payload[0..]);
    try std.testing.expectEqual(@as(u8, 0x82), wire[0]);
}

test "writeMessage keeps compressed output when takeover mutates compressor state" {
    const TakeoverConn = Conn(.{
        .role = .client,
        .permessage_deflate_context_takeover = true,
        .permessage_deflate_min_payload_len = 1,
        .permessage_deflate_require_compression_gain = true,
    });
    var wire: [256]u8 = undefined;
    var writer = Io.Writer.fixed(wire[0..]);
    var empty_reader = Io.Reader.fixed(""[0..]);
    var conn = TakeoverConn.init(&empty_reader, &writer, .{
        .permessage_deflate = .{
            .allocator = std.testing.allocator,
            .negotiated = .{
                .server_no_context_takeover = false,
                .client_no_context_takeover = false,
            },
            .compress_outgoing = true,
        },
    });
    defer conn.deinit();

    try conn.writeBinary(test_small_binary_payload[0..]);
    try std.testing.expectEqual(@as(u8, 0xC2), wire[0]);
}

test "writeMessage still applies gain-based fallback when takeover is negotiated off" {
    const TakeoverConn = Conn(.{
        .role = .client,
        .permessage_deflate_context_takeover = true,
        .permessage_deflate_min_payload_len = 1,
        .permessage_deflate_require_compression_gain = true,
    });
    var wire: [256]u8 = undefined;
    var writer = Io.Writer.fixed(wire[0..]);
    var empty_reader = Io.Reader.fixed(""[0..]);
    var conn = TakeoverConn.init(&empty_reader, &writer, .{
        .permessage_deflate = .{
            .allocator = std.testing.allocator,
            .negotiated = .{
                .server_no_context_takeover = true,
                .client_no_context_takeover = true,
            },
            .compress_outgoing = true,
        },
    });
    defer conn.deinit();

    try conn.writeBinary(test_small_binary_payload[0..]);
    try std.testing.expectEqual(@as(u8, 0x82), wire[0]);
}

test "writeMessage can force compression even without size gain" {
    const TunedConn = Conn(.{
        .permessage_deflate_min_payload_len = 1,
        .permessage_deflate_require_compression_gain = false,
    });
    var wire: [256]u8 = undefined;
    var writer = Io.Writer.fixed(wire[0..]);
    var empty_reader = Io.Reader.fixed(""[0..]);
    var conn = TunedConn.init(&empty_reader, &writer, .{
        .permessage_deflate = .{
            .allocator = std.testing.allocator,
            .compress_outgoing = true,
        },
    });

    try conn.writeBinary(test_small_binary_payload[0..]);
    try std.testing.expectEqual(@as(u8, 0xC2), wire[0]);
}

test "writeMessage does not compress by default even when permessage-deflate is configured" {
    const TunedConn = Conn(.{
        .permessage_deflate_min_payload_len = 1,
        .permessage_deflate_require_compression_gain = false,
    });
    const payload = "this payload is large enough to benefit from compression";

    var wire: [512]u8 = undefined;
    var writer = Io.Writer.fixed(wire[0..]);
    var empty_reader = Io.Reader.fixed(""[0..]);
    var conn = TunedConn.init(&empty_reader, &writer, .{
        .permessage_deflate = .{
            .allocator = std.testing.allocator,
            // `compress_outgoing` defaults to false.
        },
    });

    try conn.writeText(payload);
    try std.testing.expectEqual(@as(u8, 0x81), wire[0]);
}

test "beginFrame rejects compressed control frames even when permessage-deflate is enabled" {
    const wire = [_]u8{
        0xC9,
        0x80,
        0x01,
        0x02,
        0x03,
        0x04,
    };
    var reader = Io.Reader.fixed(wire[0..]);
    var sink: [0]u8 = .{};
    var writer = Io.Writer.fixed(sink[0..]);
    var conn = Conn(.{}).init(&reader, &writer, .{
        .permessage_deflate = .{
            .allocator = std.testing.allocator,
        },
    });
    try std.testing.expectError(error.ReservedBitsSet, conn.beginFrame());
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

test "internal role and compression helpers follow negotiated takeover policy" {
    const negotiated_takeover: extensions.PerMessageDeflate = .{
        .server_no_context_takeover = false,
        .client_no_context_takeover = false,
    };
    const negotiated_no_takeover: extensions.PerMessageDeflate = .{};

    try std.testing.expectEqual(@as(i32, flate_backend.sync_flush), outgoingFlushMode(.client, negotiated_takeover));
    try std.testing.expectEqual(@as(i32, flate_backend.full_flush), outgoingFlushMode(.client, negotiated_no_takeover));
    try std.testing.expect(!outgoingNoContextTakeover(.client, negotiated_takeover));
    try std.testing.expect(outgoingNoContextTakeover(.server, negotiated_no_takeover));
    try std.testing.expect(!incomingNoContextTakeover(.server, negotiated_takeover));
    try std.testing.expect(incomingNoContextTakeover(.client, negotiated_no_takeover));

    const TakeoverConn = Conn(.{
        .role = .client,
        .permessage_deflate_context_takeover = true,
        .permessage_deflate_min_payload_len = 1,
        .permessage_deflate_require_compression_gain = false,
    });
    var empty_reader = Io.Reader.fixed(""[0..]);
    var out: [256]u8 = undefined;
    var writer = Io.Writer.fixed(out[0..]);
    var conn = TakeoverConn.init(&empty_reader, &writer, .{
        .permessage_deflate = .{
            .allocator = std.testing.allocator,
            .negotiated = negotiated_takeover,
            .compress_outgoing = true,
        },
    });

    try std.testing.expect(conn.shouldUseOutgoingContextTakeover());
    try std.testing.expect(conn.shouldUseIncomingContextTakeover());

    const PlainConn = Conn(.{
        .role = .client,
        .permessage_deflate_context_takeover = true,
        .permessage_deflate_min_payload_len = 1,
        .permessage_deflate_require_compression_gain = false,
    });
    var plain_writer = Io.Writer.fixed(out[0..]);
    var plain_conn = PlainConn.init(&empty_reader, &plain_writer, .{
        .permessage_deflate = .{
            .allocator = std.testing.allocator,
            .negotiated = negotiated_no_takeover,
            .compress_outgoing = true,
        },
    });
    const compressed = try plain_conn.deflateMessage("hello hello hello again");
    defer std.testing.allocator.free(compressed);
    var inflated_buf: [64]u8 = undefined;
    const inflated = try plain_conn.inflateMessage(compressed, inflated_buf[0..]);
    try std.testing.expectEqualStrings("hello hello hello again", inflated);

    plain_conn.deinit();
    try std.testing.expect(plain_conn.send_takeover == null);
    try std.testing.expect(plain_conn.recv_takeover == null);
}

test "init normalizes sparse anonymous config literals and compiles out disabled fields" {
    const TrimmedConn = Conn(.{
        .runtime_hooks = false,
        .supports_permessage_deflate = false,
    });
    var empty_reader = Io.Reader.fixed(""[0..]);
    var sink: [0]u8 = .{};
    var writer = Io.Writer.fixed(sink[0..]);
    const trimmed = TrimmedConn.init(&empty_reader, &writer, .{
        .max_message_payload_len = 123,
    });

    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), trimmed.config.max_frame_payload_len);
    try std.testing.expectEqual(@as(usize, 123), trimmed.config.max_message_payload_len);
    try std.testing.expectEqual(void, @TypeOf(trimmed.config.permessage_deflate));
    try std.testing.expectEqual(void, @TypeOf(trimmed.config.timeouts));

    const FullConn = Conn(.{});
    const full = FullConn.init(&empty_reader, &writer, .{
        .max_frame_payload_len = 456,
        .timeouts = .{ .read_ns = 10, .flush_ns = 20 },
        .permessage_deflate = .{
            .allocator = std.testing.allocator,
            .negotiated = .{
                .server_no_context_takeover = true,
                .client_no_context_takeover = false,
            },
            .compress_outgoing = true,
        },
    });

    try std.testing.expectEqual(@as(u64, 456), full.config.max_frame_payload_len);
    try std.testing.expectEqual(@as(usize, std.math.maxInt(usize)), full.config.max_message_payload_len);
    try std.testing.expectEqual(@as(?u64, 10), full.config.timeouts.read_ns);
    try std.testing.expectEqual(@as(?u64, null), full.config.timeouts.write_ns);
    try std.testing.expectEqual(@as(?u64, 20), full.config.timeouts.flush_ns);
    try std.testing.expect(full.config.permessage_deflate != null);
    try std.testing.expectEqual(std.testing.allocator.ptr, full.config.permessage_deflate.?.allocator.ptr);
    try std.testing.expect(full.config.permessage_deflate.?.compress_outgoing);
    try std.testing.expect(full.config.permessage_deflate.?.negotiated.server_no_context_takeover);
    try std.testing.expect(!full.config.permessage_deflate.?.negotiated.client_no_context_takeover);
}

test "internal header parsing and fragment bookkeeping helpers behave directly" {
    var empty_reader = Io.Reader.fixed(""[0..]);
    var sink: [0]u8 = .{};
    var writer = Io.Writer.fixed(sink[0..]);
    var conn = Conn(.{}).init(&empty_reader, &writer, .{});

    try std.testing.expect((try conn.parseHeaderBytes(&.{0x81})) == null);
    try std.testing.expectError(error.ReservedBitsSet, conn.parseHeaderBytes(&.{ 0xC1, 0x80, 1, 2, 3, 4 }));

    var compressed_conn = Conn(.{}).init(&empty_reader, &writer, .{
        .permessage_deflate = .{
            .allocator = std.testing.allocator,
        },
    });
    const parsed = (try compressed_conn.parseHeaderBytes(&.{ 0xC1, 0x80, 1, 2, 3, 4 })).?;
    try std.testing.expect(parsed.header.compressed);
    try std.testing.expectEqual(Opcode.text, parsed.header.opcode);
    try std.testing.expectEqual(@as(usize, 6), parsed.header_len);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, parsed.mask[0..]);

    try conn.validateOutgoingSequence(.text, false);
    try std.testing.expectEqual(MessageOpcode.text, conn.send_fragment_opcode.?);
    try conn.validateOutgoingSequence(.continuation, true);
    try std.testing.expect(conn.send_fragment_opcode == null);

    conn.recv_active = true;
    conn.recv_header = .{
        .fin = false,
        .masked = true,
        .opcode = .text,
        .payload_len = 2,
    };
    conn.recv_remaining = 0;
    conn.finishActiveFrame();
    try std.testing.expect(!conn.recv_active);
    try std.testing.expectEqual(MessageOpcode.text, conn.recv_fragment_opcode.?);

    conn.recv_active = true;
    conn.recv_header = .{
        .fin = true,
        .masked = true,
        .opcode = .continuation,
        .payload_len = 1,
    };
    conn.recv_remaining = 0;
    conn.finishActiveFrame();
    try std.testing.expect(conn.recv_fragment_opcode == null);
    try std.testing.expect(!conn.recv_fragment_compressed);
}

test "internal discard helpers cover control flow directly" {
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(std.testing.allocator);
    try appendTestFrame(&wire, std.testing.allocator, .ping, true, true, "!", .{ 1, 2, 3, 4 });
    try appendTestFrame(&wire, std.testing.allocator, .continuation, true, true, "ok", .{ 5, 6, 7, 8 });
    var reader = Io.Reader.fixed(wire.items);
    var drain_out: [8]u8 = undefined;
    var drain_writer = Io.Writer.fixed(drain_out[0..]);
    var draining_conn = Conn(.{}).init(&reader, &drain_writer, .{});
    draining_conn.recv_fragment_opcode = .text;
    try std.testing.expect(!(try draining_conn.discardRemainingMessage()));
    try std.testing.expect(draining_conn.recv_fragment_opcode == null);
    try std.testing.expectEqualSlices(u8, &.{ 0x8A, 0x01, '!' }, drain_out[0..drain_writer.end]);

    wire.clearRetainingCapacity();
    try appendTestFrame(&wire, std.testing.allocator, .close, true, true, "", .{ 9, 10, 11, 12 });
    reader = Io.Reader.fixed(wire.items);
    drain_writer = Io.Writer.fixed(drain_out[0..]);
    draining_conn = Conn(.{}).init(&reader, &drain_writer, .{});
    draining_conn.recv_fragment_opcode = .binary;
    try std.testing.expect(try draining_conn.discardRemainingMessage());
    try std.testing.expect(draining_conn.close_received);
    try std.testing.expect(draining_conn.recv_fragment_opcode == null);
}

const TestClockState = struct {
    now_ns: u64 = 0,
    step_ns: u64,

    fn now(self: *@This()) u64 {
        const current = self.now_ns;
        self.now_ns += self.step_ns;
        return current;
    }
};

const TestDeadlineState = struct {
    read_calls: [8]?u64 = [_]?u64{null} ** 8,
    read_len: usize = 0,
    write_calls: [8]?u64 = [_]?u64{null} ** 8,
    write_len: usize = 0,
    flush_calls: [8]?u64 = [_]?u64{null} ** 8,
    flush_len: usize = 0,

    fn setRead(self: *@This(), deadline_ns: ?u64) void {
        self.read_calls[self.read_len] = deadline_ns;
        self.read_len += 1;
    }

    fn setWrite(self: *@This(), deadline_ns: ?u64) void {
        self.write_calls[self.write_len] = deadline_ns;
        self.write_len += 1;
    }

    fn setFlush(self: *@This(), deadline_ns: ?u64) void {
        self.flush_calls[self.flush_len] = deadline_ns;
        self.flush_len += 1;
    }
};

const TestHooks = struct {
    clock: ?*TestClockState = null,
    deadlines: ?*TestDeadlineState = null,
    fixed_now_ns: ?u64 = null,

    pub fn nowNs(self: *const @This()) u64 {
        if (self.clock) |clock| return clock.now();
        return self.fixed_now_ns orelse 0;
    }

    pub fn setReadDeadlineNs(self: *@This(), deadline_ns: ?u64) void {
        if (self.deadlines) |deadlines| deadlines.setRead(deadline_ns);
    }

    pub fn setWriteDeadlineNs(self: *@This(), deadline_ns: ?u64) void {
        if (self.deadlines) |deadlines| deadlines.setWrite(deadline_ns);
    }

    pub fn setFlushDeadlineNs(self: *@This(), deadline_ns: ?u64) void {
        if (self.deadlines) |deadlines| deadlines.setFlush(deadline_ns);
    }
};
test "read timeout returns Timeout" {
    var clock_state: TestClockState = .{
        .step_ns = 5,
    };
    const wire = [_]u8{ 0x81, 0x00 };
    var reader = Io.Reader.fixed(wire[0..]);
    var sink: [0]u8 = .{};
    var writer = Io.Writer.fixed(sink[0..]);
    var conn = ConnWithHooks(.{ .role = .client }, TestHooks).initWithHooks(&reader, &writer, .{
        .timeouts = .{
            .read_ns = 1,
        },
    }, .{
        .clock = &clock_state,
    });

    try std.testing.expectError(error.Timeout, conn.beginFrame());
}

test "deadline controller is set and cleared around timed reads and writes" {
    var deadline_state: TestDeadlineState = .{};

    const read_wire = [_]u8{ 0x81, 0x01, 'x' };
    var reader = Io.Reader.fixed(read_wire[0..]);
    var read_sink: [0]u8 = .{};
    var read_writer = Io.Writer.fixed(read_sink[0..]);
    var read_conn = ConnWithHooks(.{ .role = .client }, TestHooks).initWithHooks(&reader, &read_writer, .{
        .timeouts = .{
            .read_ns = 20,
        },
    }, .{
        .deadlines = &deadline_state,
        .fixed_now_ns = 10,
    });
    var read_buf: [4]u8 = undefined;
    _ = try read_conn.readFrame(read_buf[0..]);

    try std.testing.expect(deadline_state.read_len >= 2);
    try std.testing.expectEqual(@as(?u64, 30), deadline_state.read_calls[0]);
    try std.testing.expectEqual(@as(?u64, null), deadline_state.read_calls[deadline_state.read_len - 1]);

    var empty_reader = Io.Reader.fixed(""[0..]);
    var out: [16]u8 = undefined;
    var writer = Io.Writer.fixed(out[0..]);
    var write_conn = ConnWithHooks(.{}, TestHooks).initWithHooks(&empty_reader, &writer, .{
        .timeouts = .{
            .write_ns = 20,
            .flush_ns = 20,
        },
    }, .{
        .deadlines = &deadline_state,
        .fixed_now_ns = 10,
    });
    try write_conn.writeBinary("y");
    try write_conn.flush();

    try std.testing.expect(deadline_state.write_len >= 2);
    try std.testing.expectEqual(@as(?u64, 30), deadline_state.write_calls[0]);
    try std.testing.expectEqual(@as(?u64, null), deadline_state.write_calls[deadline_state.write_len - 1]);
    try std.testing.expect(deadline_state.flush_len >= 2);
    try std.testing.expectEqual(@as(?u64, 30), deadline_state.flush_calls[0]);
    try std.testing.expectEqual(@as(?u64, null), deadline_state.flush_calls[deadline_state.flush_len - 1]);
}

test "runtime_hooks false disables timeout hooks" {
    var clock_state: TestClockState = .{
        .step_ns = 5,
    };
    var deadline_state: TestDeadlineState = .{};

    const wire = [_]u8{ 0x81, 0x01, 'x' };
    var reader = Io.Reader.fixed(wire[0..]);
    var write_buf: [16]u8 = undefined;
    var writer = Io.Writer.fixed(write_buf[0..]);
    var conn = ConnWithHooks(.{
        .role = .client,
        .runtime_hooks = false,
    }, TestHooks).initWithHooks(&reader, &writer, .{
        .timeouts = .{
            .read_ns = 1,
            .write_ns = 1,
            .flush_ns = 1,
        },
    }, .{
        .clock = &clock_state,
        .deadlines = &deadline_state,
    });

    var frame_buf: [8]u8 = undefined;
    const frame = try conn.readFrame(frame_buf[0..]);
    try std.testing.expectEqual(Opcode.text, frame.header.opcode);
    try std.testing.expectEqualStrings("x", frame.payload);
    try conn.writeBinary("ok");
    try conn.flush();

    try std.testing.expectEqual(@as(usize, 0), deadline_state.read_len);
    try std.testing.expectEqual(@as(usize, 0), deadline_state.write_len);
    try std.testing.expectEqual(@as(usize, 0), deadline_state.flush_len);
}
