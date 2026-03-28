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

test "parseKeyVal handles valid and invalid argument shapes" {
    const parsed_port = parseKeyVal("--port=9001").?;
    try std.testing.expectEqualStrings("port", parsed_port.key);
    try std.testing.expectEqualStrings("9001", parsed_port.val);

    const parsed_empty = parseKeyVal("--empty=").?;
    try std.testing.expectEqualStrings("empty", parsed_empty.key);
    try std.testing.expectEqualStrings("", parsed_empty.val);

    try std.testing.expect(parseKeyVal("port=9001") == null);
    try std.testing.expect(parseKeyVal("--missing") == null);
}

test "trimCR and trimSpaces normalize header text" {
    try std.testing.expectEqualStrings("line", trimCR("line\r"));
    try std.testing.expectEqualStrings("line", trimCR("line"));
    try std.testing.expectEqualStrings("value", trimSpaces(" \tvalue\t "));
    try std.testing.expectEqualStrings("", trimSpaces(" \t "));
}

test "assignHandshakeHeader maps known websocket headers case-insensitively" {
    var req: zws.ServerHandshakeRequest = .{
        .method = "GET",
        .is_http_11 = true,
    };
    assignHandshakeHeader(&req, "CoNnEcTiOn", "Upgrade");
    assignHandshakeHeader(&req, "upgrade", "websocket");
    assignHandshakeHeader(&req, "SEC-WEBSOCKET-KEY", "dGhlIHNhbXBsZSBub25jZQ==");
    assignHandshakeHeader(&req, "sec-websocket-version", "13");
    assignHandshakeHeader(&req, "sec-websocket-protocol", "chat");
    assignHandshakeHeader(&req, "sec-websocket-extensions", "permessage-deflate");
    assignHandshakeHeader(&req, "origin", "https://example.com");
    assignHandshakeHeader(&req, "host", "example.com");
    assignHandshakeHeader(&req, "x-unknown", "ignored");

    try std.testing.expectEqualStrings("Upgrade", req.connection.?);
    try std.testing.expectEqualStrings("websocket", req.upgrade.?);
    try std.testing.expectEqualStrings("dGhlIHNhbXBsZSBub25jZQ==", req.sec_websocket_key.?);
    try std.testing.expectEqualStrings("13", req.sec_websocket_version.?);
    try std.testing.expectEqualStrings("chat", req.sec_websocket_protocol.?);
    try std.testing.expectEqualStrings("permessage-deflate", req.sec_websocket_extensions.?);
    try std.testing.expectEqualStrings("https://example.com", req.origin.?);
    try std.testing.expectEqualStrings("example.com", req.host.?);
}

test "parseHandshakeRequest parses request line and websocket headers" {
    const raw =
        "GET /chat HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "Connection: keep-alive, Upgrade\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
        "Sec-WebSocket-Version: 13\r\n" ++
        "\r\n";
    var reader = Io.Reader.fixed(raw);
    const req = try parseHandshakeRequest(&reader);
    try std.testing.expectEqualStrings("GET", req.method);
    try std.testing.expect(req.is_http_11);
    try std.testing.expectEqualStrings("example.com", req.host.?);
    try std.testing.expectEqualStrings("keep-alive, Upgrade", req.connection.?);
    try std.testing.expectEqualStrings("websocket", req.upgrade.?);
    try std.testing.expectEqualStrings("dGhlIHNhbXBsZSBub25jZQ==", req.sec_websocket_key.?);
    try std.testing.expectEqualStrings("13", req.sec_websocket_version.?);
}

test "parseHandshakeRequest rejects malformed input" {
    {
        var reader = Io.Reader.fixed("GET /chat HTTP/1.1\r\nbad-header\r\n\r\n");
        try std.testing.expectError(error.BadRequest, parseHandshakeRequest(&reader));
    }
    {
        var reader = Io.Reader.fixed("BROKEN\r\n\r\n");
        try std.testing.expectError(error.BadRequest, parseHandshakeRequest(&reader));
    }
}

test "buildClientHandshakeRequest toggles permessage-deflate header" {
    const req_plain = try buildClientHandshakeRequest(std.testing.allocator, "example.com", "/ws", false);
    defer std.testing.allocator.free(req_plain);
    try std.testing.expect(std.mem.indexOf(u8, req_plain, "Sec-WebSocket-Extensions:") == null);

    const req_compressed = try buildClientHandshakeRequest(std.testing.allocator, "example.com", "/ws", true);
    defer std.testing.allocator.free(req_compressed);
    try std.testing.expect(std.mem.indexOf(u8, req_compressed, "Sec-WebSocket-Extensions: permessage-deflate") != null);
}

test "performClientHandshake validates status and accept key" {
    const request = "GET / HTTP/1.1\r\n\r\n";
    const ok_reply =
        "HTTP/1.1 101 Switching Protocols\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n" ++
        "Sec-WebSocket-Extensions: permessage-deflate\r\n" ++
        "\r\n";
    var reader_ok = Io.Reader.fixed(ok_reply);
    var out_ok: [128]u8 = undefined;
    var writer_ok = Io.Writer.fixed(out_ok[0..]);
    const reply = try performClientHandshake(&reader_ok, &writer_ok, request);
    try std.testing.expectEqualStrings("permessage-deflate", reply.selected_extensions.?);
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", reply.accept_key.?);
    try std.testing.expectEqualStrings(request, out_ok[0..writer_ok.end]);

    const bad_accept_reply =
        "HTTP/1.1 101 Switching Protocols\r\n" ++
        "Sec-WebSocket-Accept: invalid\r\n" ++
        "\r\n";
    var reader_bad_accept = Io.Reader.fixed(bad_accept_reply);
    var out_bad_accept: [64]u8 = undefined;
    var writer_bad_accept = Io.Writer.fixed(out_bad_accept[0..]);
    try std.testing.expectError(error.BadHandshake, performClientHandshake(&reader_bad_accept, &writer_bad_accept, request));

    const bad_status_reply =
        "HTTP/1.1 200 OK\r\n" ++
        "\r\n";
    var reader_bad_status = Io.Reader.fixed(bad_status_reply);
    var out_bad_status: [64]u8 = undefined;
    var writer_bad_status = Io.Writer.fixed(out_bad_status[0..]);
    try std.testing.expectError(error.BadHandshake, performClientHandshake(&reader_bad_status, &writer_bad_status, request));
}

test "closeForProtocolError maps protocol failures to close frames" {
    var empty_reader = Io.Reader.fixed(""[0..]);
    var out: [64]u8 = undefined;
    var writer = Io.Writer.fixed(out[0..]);
    var conn = zws.ServerConn.init(&empty_reader, &writer, .{});

    closeForProtocolError(&conn, &writer, error.InvalidUtf8);
    try std.testing.expectEqual(@as(usize, 4), writer.end);
    try std.testing.expectEqual(@as(u8, 0x88), out[0]);
    try std.testing.expectEqual(@as(u8, 0x02), out[1]);
    try std.testing.expectEqual(@as(u8, 0x03), out[2]);
    try std.testing.expectEqual(@as(u8, 0xEF), out[3]);

    var empty_reader_2 = Io.Reader.fixed(""[0..]);
    var out_2: [16]u8 = undefined;
    var writer_2 = Io.Writer.fixed(out_2[0..]);
    var conn_2 = zws.ServerConn.init(&empty_reader_2, &writer_2, .{});
    closeForProtocolError(&conn_2, &writer_2, error.OutOfMemory);
    try std.testing.expectEqual(@as(usize, 0), writer_2.end);
}
