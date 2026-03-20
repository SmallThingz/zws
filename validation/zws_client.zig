const std = @import("std");
const zws = @import("zwebsocket");
const builtin = @import("builtin");

const Io = std.Io;

const Config = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 9001,
    path: []const u8 = "/",
    compression: bool = false,
};

const HandshakeReply = struct {
    selected_extensions: ?[]const u8 = null,
    accept_key: ?[]const u8 = null,
};

fn usage() void {
    std.debug.print(
        \\zwebsocket-interop-client
        \\
        \\Usage:
        \\  zig build interop-client -- [options]
        \\
        \\Options:
        \\  --host=127.0.0.1
        \\  --port=9001
        \\  --path=/
        \\  --compression
        \\  --help
        \\
    , .{});
}

fn parseKeyVal(arg: []const u8) ?struct { key: []const u8, val: []const u8 } {
    if (!std.mem.startsWith(u8, arg, "--")) return null;
    const eq = std.mem.indexOfScalar(u8, arg, '=') orelse return null;
    return .{ .key = arg[2..eq], .val = arg[eq + 1 ..] };
}

fn trimCR(line: []const u8) []const u8 {
    if (line.len != 0 and line[line.len - 1] == '\r') return line[0 .. line.len - 1];
    return line;
}

fn trimSpaces(s: []const u8) []const u8 {
    var a: usize = 0;
    var b: usize = s.len;
    while (a < b and (s[a] == ' ' or s[a] == '\t')) a += 1;
    while (b > a and (s[b - 1] == ' ' or s[b - 1] == '\t')) b -= 1;
    return s[a..b];
}

fn setTcpNoDelay(stream: *const std.Io.net.Stream) void {
    if (builtin.os.tag != .linux) return;
    const linux = std.os.linux;
    var one: i32 = 1;
    std.posix.setsockopt(
        stream.socket.handle,
        @intCast(linux.IPPROTO.TCP),
        linux.TCP.NODELAY,
        std.mem.asBytes(&one),
    ) catch {};
}

fn buildHandshakeRequest(a: std.mem.Allocator, host: []const u8, path: []const u8, compression: bool) ![]const u8 {
    return std.fmt.allocPrint(
        a,
        "GET {s} HTTP/1.1\r\n" ++
            "Host: {s}\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
            "Sec-WebSocket-Version: 13\r\n" ++
            "{s}" ++
            "\r\n",
        .{
            path,
            host,
            if (compression)
                "Sec-WebSocket-Extensions: permessage-deflate; client_no_context_takeover; server_no_context_takeover\r\n"
            else
                "",
        },
    );
}

fn performHandshake(sr: *Io.Reader, sw: *Io.Writer, request: []const u8) !HandshakeReply {
    try sw.writeAll(request);
    try sw.flush();

    const status_line_incl = try sr.takeDelimiterInclusive('\n');
    const status_line = trimCR(status_line_incl[0 .. status_line_incl.len - 1]);
    if (!std.mem.startsWith(u8, status_line, "HTTP/1.1 101")) return error.BadHandshake;

    var reply: HandshakeReply = .{};
    while (true) {
        const line_incl = try sr.takeDelimiterInclusive('\n');
        const line = trimCR(line_incl[0 .. line_incl.len - 1]);
        if (line.len == 0) break;

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.BadHandshake;
        const name = line[0..colon];
        const value = trimSpaces(line[colon + 1 ..]);
        if (std.ascii.eqlIgnoreCase(name, "sec-websocket-accept")) {
            reply.accept_key = value;
        } else if (std.ascii.eqlIgnoreCase(name, "sec-websocket-extensions")) {
            reply.selected_extensions = value;
        }
    }

    const expected = try zws.computeAcceptKey("dGhlIHNhbXBsZSBub25jZQ==");
    if (reply.accept_key == null or !std.mem.eql(u8, reply.accept_key.?, expected[0..])) {
        return error.BadHandshake;
    }
    return reply;
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
        if (std.mem.eql(u8, arg, "--compression")) {
            cfg.compression = true;
            continue;
        }
        if (parseKeyVal(arg)) |kv| {
            if (std.mem.eql(u8, kv.key, "host")) {
                cfg.host = kv.val;
            } else if (std.mem.eql(u8, kv.key, "port")) {
                cfg.port = try std.fmt.parseInt(u16, kv.val, 10);
            } else if (std.mem.eql(u8, kv.key, "path")) {
                cfg.path = kv.val;
            } else {
                return error.UnknownArg;
            }
            continue;
        }
        return error.UnknownArg;
    }

    const addr: std.Io.net.IpAddress = .{ .ip4 = try std.Io.net.Ip4Address.parse(cfg.host, cfg.port) };
    var stream = try std.Io.net.IpAddress.connect(addr, init.io, .{ .mode = .stream });
    defer stream.close(init.io);
    setTcpNoDelay(&stream);

    var read_buf: [64 * 1024]u8 = undefined;
    var write_buf: [16 * 1024]u8 = undefined;
    var sr = stream.reader(init.io, &read_buf);
    var sw = stream.writer(init.io, &write_buf);

    const request = try buildHandshakeRequest(init.gpa, cfg.host, cfg.path, cfg.compression);
    defer init.gpa.free(request);
    const reply = try performHandshake(&sr.interface, &sw.interface, request);

    const negotiated_permessage_deflate = if (reply.selected_extensions) |header|
        try zws.parsePerMessageDeflate(header)
    else
        null;
    const conn_cfg: zws.Config = .{
        .permessage_deflate = if (negotiated_permessage_deflate) |pmd|
            .{
                .allocator = init.gpa,
                .negotiated = pmd,
            }
        else
            null,
    };
    var conn = zws.ClientConn.init(&sr.interface, &sw.interface, conn_cfg);

    const text_payload =
        "zwebsocket interop text payload with enough repetition to exercise permessage-deflate";
    try conn.writeText(text_payload);
    try sw.interface.flush();

    var message_buf: [128 * 1024]u8 = undefined;
    {
        const message = try conn.readMessage(message_buf[0..]);
        if (message.opcode != .text) return error.UnexpectedOpcode;
        if (!std.mem.eql(u8, text_payload, message.payload)) return error.BadEcho;
    }

    var binary_payload: [256]u8 = undefined;
    for (&binary_payload, 0..) |*b, i| b.* = @truncate((i * 13 + 7) & 0xff);
    try conn.writeBinary(binary_payload[0..]);
    try sw.interface.flush();
    {
        const message = try conn.readMessage(message_buf[0..]);
        if (message.opcode != .binary) return error.UnexpectedOpcode;
        if (!std.mem.eql(u8, binary_payload[0..], message.payload)) return error.BadEcho;
    }

    try conn.writeClose(1000, "");
    try sw.interface.flush();
    _ = conn.readMessage(message_buf[0..]) catch {};
}
