const std = @import("std");
const common = @import("zws_support_common");

const Io = std.Io;

const Config = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 9001,
    path: []const u8 = "/",
    conns: usize = 1,
    iters: u64 = 200_000,
    warmup: u64 = 10_000,
    pipeline: usize = 1,
    msg_size: usize = 16,
    quiet: bool = false,
    binary: bool = true,
    rate_file: ?[]const u8 = null,
};

const ConnResult = struct {
    completed: u64 = 0,
    err: ?anyerror = null,
};

const ConnState = struct {
    stream: std.Io.net.Stream = undefined,
    read_buf: []u8 = &.{},
    write_buf: []u8 = &.{},
    result: ConnResult = .{},
};

fn usage() void {
    std.debug.print(
        \\zwebsocket-bench
        \\
        \\Usage:
        \\  zig build bench -Doptimize=ReleaseFast -- [options]
        \\
        \\Options:
        \\  --host=127.0.0.1   IPv4 literal
        \\  --port=9001        Port
        \\  --path=/           WebSocket path
        \\  --conns=1          Concurrent connections
        \\  --iters=200000     Messages per connection
        \\  --warmup=10000     Warmup messages per connection
        \\  --pipeline=1       In-flight frames per connection
        \\  --msg-size=16      Payload bytes per message
        \\  --text             Use text frames (default is binary)
        \\  --quiet            Print a single summary line
        \\  --rate-file=PATH   Write msg/s as a single float line
        \\  --help             Show this help
        \\
    , .{});
}

fn discardExact(r: *Io.Reader, n: usize) !void {
    var remaining = n;
    while (remaining != 0) {
        const got = try r.discard(.limited(remaining));
        if (got == 0) return error.EndOfStream;
        remaining -= got;
    }
}

fn payloadFill(payload: []u8) void {
    for (payload, 0..) |*b, i| {
        b.* = @truncate((i * 17 + 31) & 0xff);
    }
}

fn buildHandshakeRequest(a: std.mem.Allocator, host: []const u8, path: []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        a,
        "GET {s} HTTP/1.1\r\n" ++
            "Host: {s}\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
            "Sec-WebSocket-Version: 13\r\n" ++
            "\r\n",
        .{ path, host },
    );
}

fn frameHeaderLen(payload_len: usize, masked: bool) usize {
    const base: usize = if (payload_len <= 125)
        2
    else if (payload_len <= std.math.maxInt(u16))
        4
    else
        10;
    const mask_len: usize = if (masked) 4 else 0;
    return base + mask_len;
}

fn buildClientFrame(a: std.mem.Allocator, payload: []const u8, binary: bool) ![]u8 {
    const header_len = frameHeaderLen(payload.len, true);
    const out = try a.alloc(u8, header_len + payload.len);

    const opcode: u8 = if (binary) 0x2 else 0x1;
    const mask = [_]u8{ 0x11, 0x22, 0x33, 0x44 };
    var idx: usize = 0;
    out[idx] = 0x80 | opcode;
    idx += 1;

    if (payload.len <= 125) {
        out[idx] = 0x80 | @as(u8, @intCast(payload.len));
        idx += 1;
    } else if (payload.len <= std.math.maxInt(u16)) {
        out[idx] = 0x80 | 126;
        idx += 1;
        std.mem.writeInt(u16, out[idx..][0..2], @as(u16, @intCast(payload.len)), .big);
        idx += 2;
    } else {
        out[idx] = 0x80 | 127;
        idx += 1;
        std.mem.writeInt(u64, out[idx..][0..8], payload.len, .big);
        idx += 8;
    }

    @memcpy(out[idx..][0..4], mask[0..]);
    idx += 4;

    for (payload, 0..) |b, i| {
        out[idx + i] = b ^ mask[i & 3];
    }
    return out;
}

fn performHandshake(sr: *Io.Reader, sw: *Io.Writer, handshake_request: []const u8) !void {
    try sw.writeAll(handshake_request);
    try sw.flush();

    const status_line_incl = try sr.takeDelimiterInclusive('\n');
    const status_line = common.trimCR(status_line_incl[0 .. status_line_incl.len - 1]);
    if (!std.mem.startsWith(u8, status_line, "HTTP/1.1 101")) return error.BadHandshake;

    while (true) {
        const line0_incl = try sr.takeDelimiterInclusive('\n');
        const line0 = line0_incl[0 .. line0_incl.len - 1];
        const line = common.trimCR(line0);
        if (line.len == 0) break;
    }
}

fn runBatch(sw: *Io.Writer, sr: *Io.Reader, frame_bytes: []const u8, response_bytes: usize, batch: usize) !void {
    var sent: usize = 0;
    while (sent < batch) : (sent += 1) {
        try sw.writeAll(frame_bytes);
    }
    try sw.flush();

    var received: usize = 0;
    while (received < batch) : (received += 1) {
        try discardExact(sr, response_bytes);
    }
}

fn warmConnection(
    io: Io,
    state: *ConnState,
    handshake_request: []const u8,
    frame_bytes: []const u8,
    response_bytes: usize,
    warmup: u64,
    pipeline: usize,
) !void {
    var sr = state.stream.reader(io, state.read_buf);
    var sw = state.stream.writer(io, state.write_buf);

    try performHandshake(&sr.interface, &sw.interface, handshake_request);

    var i: u64 = 0;
    while (i < warmup) {
        const batch = @min(warmup - i, pipeline);
        try runBatch(&sw.interface, &sr.interface, frame_bytes, response_bytes, batch);
        i += batch;
    }
}

fn benchConn(io: Io, state: *ConnState, frame_bytes: []const u8, response_bytes: usize, iters: u64, pipeline: usize) Io.Cancelable!void {
    var sr = state.stream.reader(io, state.read_buf);
    var sw = state.stream.writer(io, state.write_buf);
    defer state.stream.close(io);

    var i: u64 = 0;
    while (i < iters) {
        const batch = @min(iters - i, pipeline);
        runBatch(&sw.interface, &sr.interface, frame_bytes, response_bytes, batch) catch |err| {
            state.result.err = err;
            return;
        };
        state.result.completed += batch;
        i += batch;
    }
}

fn connectAndWarmup(
    a: std.mem.Allocator,
    io: Io,
    address: std.Io.net.IpAddress,
    states: []ConnState,
    handshake_request: []const u8,
    frame_bytes: []const u8,
    response_bytes: usize,
    warmup: u64,
    pipeline: usize,
) !void {
    for (states) |*st| {
        st.read_buf = try a.alloc(u8, 64 * 1024);
        st.write_buf = try a.alloc(u8, 4096);
        st.stream = try std.Io.net.IpAddress.connect(&address, io, .{ .mode = .stream });
        common.setTcpNoDelay(&st.stream);
        try warmConnection(io, st, handshake_request, frame_bytes, response_bytes, warmup, pipeline);
    }
}

fn freeStates(a: std.mem.Allocator, states: []ConnState) void {
    for (states) |*st| {
        if (st.read_buf.len != 0) a.free(st.read_buf);
        if (st.write_buf.len != 0) a.free(st.write_buf);
        st.* = undefined;
    }
}

pub fn main(init: std.process.Init) !void {
    var cfg: Config = .{};

    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer it.deinit();
    _ = it.next();

    while (it.next()) |arg_z| {
        const arg: []const u8 = arg_z;
        if (std.mem.eql(u8, arg, "--help")) {
            usage();
            return;
        }
        if (std.mem.eql(u8, arg, "--quiet")) {
            cfg.quiet = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--text")) {
            cfg.binary = false;
            continue;
        }
        if (common.parseKeyVal(arg)) |kv| {
            if (std.mem.eql(u8, kv.key, "host")) {
                cfg.host = kv.val;
            } else if (std.mem.eql(u8, kv.key, "port")) {
                cfg.port = try std.fmt.parseInt(u16, kv.val, 10);
            } else if (std.mem.eql(u8, kv.key, "path")) {
                cfg.path = kv.val;
            } else if (std.mem.eql(u8, kv.key, "conns")) {
                cfg.conns = try std.fmt.parseInt(usize, kv.val, 10);
            } else if (std.mem.eql(u8, kv.key, "iters")) {
                cfg.iters = try std.fmt.parseInt(u64, kv.val, 10);
            } else if (std.mem.eql(u8, kv.key, "warmup")) {
                cfg.warmup = try std.fmt.parseInt(u64, kv.val, 10);
            } else if (std.mem.eql(u8, kv.key, "pipeline")) {
                cfg.pipeline = try std.fmt.parseInt(usize, kv.val, 10);
            } else if (std.mem.eql(u8, kv.key, "msg-size")) {
                cfg.msg_size = try std.fmt.parseInt(usize, kv.val, 10);
            } else if (std.mem.eql(u8, kv.key, "rate-file")) {
                cfg.rate_file = kv.val;
            } else {
                return error.UnknownArg;
            }
            continue;
        }
        return error.UnknownArg;
    }
    if (cfg.pipeline == 0) return error.InvalidPipeline;

    const a = init.gpa;
    const address: std.Io.net.IpAddress = .{ .ip4 = try std.Io.net.Ip4Address.parse(cfg.host, cfg.port) };

    const handshake_request = try buildHandshakeRequest(a, cfg.host, cfg.path);
    defer a.free(handshake_request);

    const payload = try a.alloc(u8, cfg.msg_size);
    defer a.free(payload);
    payloadFill(payload);

    const frame_bytes = try buildClientFrame(a, payload, cfg.binary);
    defer a.free(frame_bytes);

    const response_bytes = frameHeaderLen(payload.len, false) + payload.len;

    const states = try a.alloc(ConnState, cfg.conns);
    defer a.free(states);
    @memset(states, .{});
    defer freeStates(a, states);

    try connectAndWarmup(a, init.io, address, states, handshake_request, frame_bytes, response_bytes, cfg.warmup, cfg.pipeline);

    var group: Io.Group = .init;
    defer group.cancel(init.io);

    const start = Io.Clock.Timestamp.now(init.io, .awake);
    for (states) |*st| {
        try group.concurrent(init.io, benchConn, .{ init.io, st, frame_bytes, response_bytes, cfg.iters, cfg.pipeline });
    }
    group.await(init.io) catch {};
    const end = Io.Clock.Timestamp.now(init.io, .awake);

    var total_ok: u64 = 0;
    var first_err: ?anyerror = null;
    for (states) |st| {
        total_ok += st.result.completed;
        if (first_err == null and st.result.err != null) first_err = st.result.err;
    }
    if (first_err) |err| return err;

    const elapsed_ns: u128 = @intCast(start.durationTo(end).raw.nanoseconds);
    const msgs_per_sec = (@as(f64, @floatFromInt(total_ok)) * @as(f64, 1_000_000_000.0)) / @as(f64, @floatFromInt(elapsed_ns));
    const payload_mib_per_sec = (msgs_per_sec * @as(f64, @floatFromInt(cfg.msg_size))) / (1024.0 * 1024.0);
    const label = init.environ_map.get("BENCH_LABEL") orelse "zwebsocket";

    if (cfg.quiet) {
        std.debug.print("{s}: {d:.2} msg/s, {d:.2} MiB/s\n", .{ label, msgs_per_sec, payload_mib_per_sec });
    } else {
        std.debug.print(
            "label={s} total_msgs={d} elapsed_ns={d} msg_per_sec={d:.2} payload_mib_per_sec={d:.2}\n",
            .{ label, total_ok, elapsed_ns, msgs_per_sec, payload_mib_per_sec },
        );
    }

    if (cfg.rate_file) |path| {
        const file = try std.Io.Dir.createFileAbsolute(init.io, path, .{ .truncate = true });
        defer file.close(init.io);

        var buf: [64]u8 = undefined;
        var writer = file.writer(init.io, &buf);
        try writer.interface.print("{d:.2}\n", .{msgs_per_sec});
        try writer.interface.flush();
    }
}
