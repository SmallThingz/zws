const std = @import("std");
const zws = @import("zwebsocket");
const builtin = @import("builtin");

pub const Io = std.Io;
pub const ClientHandshakeReply = struct {
    selected_extensions: ?[]const u8 = null,
    accept_key: ?[]const u8 = null,
};

pub fn parseKeyVal(arg: []const u8) ?struct { key: []const u8, val: []const u8 } {
    if (!std.mem.startsWith(u8, arg, "--")) return null;
    const eq = std.mem.indexOfScalar(u8, arg, '=') orelse return null;
    return .{ .key = arg[2..eq], .val = arg[eq + 1 ..] };
}

pub fn trimCR(line: []const u8) []const u8 {
    if (line.len != 0 and line[line.len - 1] == '\r') return line[0 .. line.len - 1];
    return line;
}

pub fn trimSpaces(s: []const u8) []const u8 {
    var a: usize = 0;
    var b: usize = s.len;
    while (a < b and (s[a] == ' ' or s[a] == '\t')) a += 1;
    while (b > a and (s[b - 1] == ' ' or s[b - 1] == '\t')) b -= 1;
    return s[a..b];
}

pub fn setTcpNoDelay(stream: *const std.Io.net.Stream) void {
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

pub fn assignHandshakeHeader(req: *zws.ServerHandshakeRequest, name: []const u8, value: []const u8) void {
    if (std.ascii.eqlIgnoreCase(name, "connection")) {
        req.connection = value;
    } else if (std.ascii.eqlIgnoreCase(name, "upgrade")) {
        req.upgrade = value;
    } else if (std.ascii.eqlIgnoreCase(name, "sec-websocket-key")) {
        req.sec_websocket_key = value;
    } else if (std.ascii.eqlIgnoreCase(name, "sec-websocket-version")) {
        req.sec_websocket_version = value;
    } else if (std.ascii.eqlIgnoreCase(name, "sec-websocket-protocol")) {
        req.sec_websocket_protocol = value;
    } else if (std.ascii.eqlIgnoreCase(name, "sec-websocket-extensions")) {
        req.sec_websocket_extensions = value;
    } else if (std.ascii.eqlIgnoreCase(name, "origin")) {
        req.origin = value;
    } else if (std.ascii.eqlIgnoreCase(name, "host")) {
        req.host = value;
    }
}

pub fn parseHandshakeRequest(r: *Io.Reader) !zws.ServerHandshakeRequest {
    const line0_incl = try r.takeDelimiterInclusive('\n');
    const line0 = line0_incl[0 .. line0_incl.len - 1];
    const request_line = trimCR(line0);

    const sp1 = std.mem.indexOfScalar(u8, request_line, ' ') orelse return error.BadRequest;
    const sp2_rel = std.mem.indexOfScalar(u8, request_line[sp1 + 1 ..], ' ') orelse return error.BadRequest;
    const sp2 = sp1 + 1 + sp2_rel;

    var req: zws.ServerHandshakeRequest = .{
        .method = request_line[0..sp1],
        .is_http_11 = std.mem.eql(u8, request_line[sp2 + 1 ..], "HTTP/1.1"),
    };

    while (true) {
        const line_incl = try r.takeDelimiterInclusive('\n');
        const line = trimCR(line_incl[0 .. line_incl.len - 1]);
        if (line.len == 0) break;

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.BadRequest;
        assignHandshakeHeader(&req, line[0..colon], trimSpaces(line[colon + 1 ..]));
    }

    return req;
}

pub fn closeForProtocolError(conn: *zws.ServerConn, writer: *Io.Writer, err: anyerror) void {
    const close_code: ?u16 = switch (err) {
        error.MessageTooLarge, error.FrameTooLarge => 1009,
        error.InvalidUtf8 => 1007,
        error.InvalidCompressedMessage,
        error.InvalidClosePayload,
        error.InvalidCloseCode,
        error.ReservedBitsSet,
        error.UnknownOpcode,
        error.InvalidFrameLength,
        error.MaskBitInvalid,
        error.UnexpectedContinuation,
        error.ExpectedContinuation,
        error.ControlFrameFragmented,
        error.ControlFrameTooLarge,
        => 1002,
        else => null,
    };
    if (close_code) |code| {
        conn.writeClose(code, "") catch {};
        writer.flush() catch {};
    }
}

pub fn buildClientHandshakeRequest(
    allocator: std.mem.Allocator,
    host: []const u8,
    path: []const u8,
    compression: bool,
) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
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

pub fn performClientHandshake(sr: *Io.Reader, sw: *Io.Writer, request: []const u8) !ClientHandshakeReply {
    try sw.writeAll(request);
    try sw.flush();

    const status_line_incl = try sr.takeDelimiterInclusive('\n');
    const status_line = trimCR(status_line_incl[0 .. status_line_incl.len - 1]);
    if (!std.mem.startsWith(u8, status_line, "HTTP/1.1 101")) return error.BadHandshake;

    var reply: ClientHandshakeReply = .{};
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
