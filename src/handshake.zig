const std = @import("std");
const Io = std.Io;
const extensions = @import("extensions.zig");

pub const Error = error{
    BadRequest,
    MethodNotGet,
    HttpVersionNotSupported,
    MissingConnectionHeader,
    MissingUpgradeHeader,
    MissingWebSocketKey,
    MissingWebSocketVersion,
    InvalidConnectionHeader,
    InvalidUpgradeHeader,
    InvalidWebSocketKey,
    UnsupportedWebSocketVersion,
    ExtensionsNotSupported,
};

const websocket_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

const Request = struct {
    method: []const u8,
    is_http_11: bool,
    connection: ?[]const u8 = null,
    upgrade: ?[]const u8 = null,
    sec_websocket_key: ?[]const u8 = null,
    sec_websocket_version: ?[]const u8 = null,
    sec_websocket_extensions: ?[]const u8 = null,
};

const Accepted = struct {
    accept_key: [28]u8,
    permessage_deflate: ?extensions.PerMessageDeflate = null,
};

fn trimCR(line: []const u8) []const u8 {
    if (line.len != 0 and line[line.len - 1] == '\r') return line[0 .. line.len - 1];
    return line;
}

fn trimSpaces(value: []const u8) []const u8 {
    return std.mem.trim(u8, value, " \t");
}

fn containsTokenIgnoreCase(value: []const u8, wanted: []const u8) bool {
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |part| {
        if (std.ascii.eqlIgnoreCase(trimSpaces(part), wanted)) return true;
    }
    return false;
}

fn validateClientKey(key: []const u8) bool {
    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(key) catch return false;
    if (decoded_len != 16) return false;

    var decoded: [16]u8 = undefined;
    std.base64.standard.Decoder.decode(decoded[0..], key) catch return false;
    return true;
}

fn assignHeader(req: *Request, name: []const u8, value: []const u8) void {
    if (std.ascii.eqlIgnoreCase(name, "connection")) {
        req.connection = value;
    } else if (std.ascii.eqlIgnoreCase(name, "upgrade")) {
        req.upgrade = value;
    } else if (std.ascii.eqlIgnoreCase(name, "sec-websocket-key")) {
        req.sec_websocket_key = value;
    } else if (std.ascii.eqlIgnoreCase(name, "sec-websocket-version")) {
        req.sec_websocket_version = value;
    } else if (std.ascii.eqlIgnoreCase(name, "sec-websocket-extensions")) {
        req.sec_websocket_extensions = value;
    }
}

fn parseRequest(reader: *Io.Reader) (Error || Io.Reader.Error)!Request {
    const line0_incl = reader.takeDelimiterInclusive('\n') catch |err| switch (err) {
        error.StreamTooLong => return error.BadRequest,
        error.EndOfStream => return error.EndOfStream,
        error.ReadFailed => return error.ReadFailed,
    };
    const line0 = trimCR(line0_incl[0 .. line0_incl.len - 1]);

    const sp1 = std.mem.indexOfScalar(u8, line0, ' ') orelse return error.BadRequest;
    const sp2_rel = std.mem.indexOfScalar(u8, line0[sp1 + 1 ..], ' ') orelse return error.BadRequest;
    const sp2 = sp1 + 1 + sp2_rel;

    var req: Request = .{
        .method = line0[0..sp1],
        .is_http_11 = std.mem.eql(u8, line0[sp2 + 1 ..], "HTTP/1.1"),
    };

    while (true) {
        const line_incl = reader.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.StreamTooLong => return error.BadRequest,
            error.EndOfStream => return error.EndOfStream,
            error.ReadFailed => return error.ReadFailed,
        };
        const line = trimCR(line_incl[0 .. line_incl.len - 1]);
        if (line.len == 0) break;

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.BadRequest;
        assignHeader(&req, line[0..colon], trimSpaces(line[colon + 1 ..]));
    }

    return req;
}

fn negotiatedPerMessageDeflateForOffer(
    requested: extensions.PerMessageDeflate,
    preferred: extensions.PerMessageDeflate,
) extensions.PerMessageDeflate {
    return .{
        .server_no_context_takeover = preferred.server_no_context_takeover,
        .client_no_context_takeover = preferred.client_no_context_takeover and requested.client_no_context_takeover,
    };
}

fn perMessageDeflateOfferScore(
    requested: extensions.PerMessageDeflate,
    preferred: extensions.PerMessageDeflate,
) usize {
    var score: usize = 0;
    if (preferred.client_no_context_takeover and requested.client_no_context_takeover) score += 1;
    return score;
}

fn negotiatePerMessageDeflate(header_value: ?[]const u8) Error!?extensions.PerMessageDeflate {
    const offered = header_value orelse return null;
    if (!extensions.offersPerMessageDeflate(offered)) return null;

    const preferred: extensions.PerMessageDeflate = .{};
    var offers = extensions.parsePerMessageDeflate(offered);
    var negotiated: ?extensions.PerMessageDeflate = null;
    var best_score: usize = 0;
    while (offers.next() catch return error.ExtensionsNotSupported) |requested| {
        const candidate = negotiatedPerMessageDeflateForOffer(requested, preferred);
        const score = perMessageDeflateOfferScore(requested, preferred);
        if (negotiated == null or score > best_score) {
            negotiated = candidate;
            best_score = score;
        }
    }
    return negotiated;
}

fn acceptRequest(req: Request) Error!Accepted {
    if (!std.mem.eql(u8, req.method, "GET")) return error.MethodNotGet;
    if (!req.is_http_11) return error.HttpVersionNotSupported;

    const connection = req.connection orelse return error.MissingConnectionHeader;
    if (!containsTokenIgnoreCase(connection, "upgrade")) return error.InvalidConnectionHeader;

    const upgrade_header = req.upgrade orelse return error.MissingUpgradeHeader;
    if (!std.ascii.eqlIgnoreCase(trimSpaces(upgrade_header), "websocket")) return error.InvalidUpgradeHeader;

    const key = trimSpaces(req.sec_websocket_key orelse return error.MissingWebSocketKey);
    const version = trimSpaces(req.sec_websocket_version orelse return error.MissingWebSocketVersion);
    if (!std.mem.eql(u8, version, "13")) return error.UnsupportedWebSocketVersion;

    const accept_key = try computeAcceptKey(key);
    return .{
        .accept_key = accept_key,
        .permessage_deflate = try negotiatePerMessageDeflate(req.sec_websocket_extensions),
    };
}

fn writeResponse(
    writer: *Io.Writer,
    accept_key: [28]u8,
    permessage_deflate: ?extensions.PerMessageDeflate,
) Io.Writer.Error!void {
    try writer.writeAll("HTTP/1.1 101 Switching Protocols\r\n");
    try writer.writeAll("upgrade: websocket\r\n");
    try writer.writeAll("connection: Upgrade\r\n");
    try writer.writeAll("sec-websocket-accept: ");
    try writer.writeAll(accept_key[0..]);
    try writer.writeAll("\r\n");

    if (permessage_deflate) |pmd| {
        try writer.writeAll("sec-websocket-extensions: ");
        try writer.writeAll(pmd.responseHeaderValue());
        try writer.writeAll("\r\n");
    }

    try writer.writeAll("\r\n");
}

pub fn computeAcceptKey(client_key: []const u8) Error![28]u8 {
    if (!validateClientKey(client_key)) return error.InvalidWebSocketKey;

    var sha1 = std.crypto.hash.Sha1.init(.{});
    sha1.update(client_key);
    sha1.update(websocket_guid);

    var digest: [20]u8 = undefined;
    sha1.final(&digest);

    var out: [28]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(out[0..], digest[0..]);
    return out;
}

pub fn upgrade(
    reader: *Io.Reader,
    writer: *Io.Writer,
) (Error || Io.Reader.Error || Io.Writer.Error)!?extensions.PerMessageDeflate {
    const accepted = try acceptRequest(try parseRequest(reader));
    try writeResponse(writer, accepted.accept_key, accepted.permessage_deflate);
    return accepted.permessage_deflate;
}

fn validRequest(comptime extra_headers: []const u8) []const u8 {
    return "GET /chat HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "Connection: keep-alive, Upgrade\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
        "Sec-WebSocket-Version: 13\r\n" ++
        extra_headers ++
        "\r\n";
}

test "computeAcceptKey matches RFC example" {
    const got = try computeAcceptKey("dGhlIHNhbXBsZSBub25jZQ==");
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", got[0..]);
}

test "containsTokenIgnoreCase ignores ASCII case and whitespace" {
    try std.testing.expect(containsTokenIgnoreCase("keep-alive, Upgrade", "upgrade"));
    try std.testing.expect(containsTokenIgnoreCase(" keep-alive ,\tUPGRADE ", "upgrade"));
    try std.testing.expect(containsTokenIgnoreCase("keep-alive,, Upgrade ,", "upgrade"));
    try std.testing.expect(!containsTokenIgnoreCase("upgrader", "upgrade"));
    try std.testing.expect(!containsTokenIgnoreCase("", "upgrade"));
}

test "validateClientKey enforces valid base64 and 16 decoded bytes" {
    try std.testing.expect(validateClientKey("dGhlIHNhbXBsZSBub25jZQ=="));
    try std.testing.expect(!validateClientKey("!!!!"));
    try std.testing.expect(!validateClientKey("dGVzdA=="));
    try std.testing.expect(!validateClientKey("dGhlIHNhbXBsZSBub25jZQ"));
}

test "parseRequest parses the upgrade request and trims header whitespace" {
    var reader = Io.Reader.fixed(validRequest(
        "Connection:  keep-alive, Upgrade \r\n" ++
            "Upgrade:  websocket \r\n",
    ));
    const req = try parseRequest(&reader);
    try std.testing.expectEqualStrings("GET", req.method);
    try std.testing.expect(req.is_http_11);
    try std.testing.expectEqualStrings("keep-alive, Upgrade", req.connection.?);
    try std.testing.expectEqualStrings("websocket", req.upgrade.?);
    try std.testing.expectEqualStrings("dGhlIHNhbXBsZSBub25jZQ==", req.sec_websocket_key.?);
    try std.testing.expectEqualStrings("13", req.sec_websocket_version.?);
}

test "parseRequest rejects malformed request lines and headers" {
    {
        var reader = Io.Reader.fixed("BROKEN\r\n\r\n");
        try std.testing.expectError(error.BadRequest, parseRequest(&reader));
    }
    {
        var reader = Io.Reader.fixed("GET / HTTP/1.1\r\nbroken-header\r\n\r\n");
        try std.testing.expectError(error.BadRequest, parseRequest(&reader));
    }
}

test "computeAcceptKey rejects invalid client keys" {
    try std.testing.expectError(error.InvalidWebSocketKey, computeAcceptKey("invalid"));
}

test "acceptRequest validates a basic websocket upgrade" {
    var reader = Io.Reader.fixed(validRequest(""));
    const accepted = try acceptRequest(try parseRequest(&reader));
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", accepted.accept_key[0..]);
    try std.testing.expect(accepted.permessage_deflate == null);
}

test "acceptRequest trims websocket key before validation" {
    var reader = Io.Reader.fixed(
        "GET /chat HTTP/1.1\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Sec-WebSocket-Key:  dGhlIHNhbXBsZSBub25jZQ== \r\n" ++
            "Sec-WebSocket-Version: 13\r\n" ++
            "\r\n",
    );
    const accepted = try acceptRequest(try parseRequest(&reader));
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", accepted.accept_key[0..]);
}

test "acceptRequest ignores non-websocket extension offers" {
    var reader = Io.Reader.fixed(validRequest("Sec-WebSocket-Extensions: x-test\r\n"));
    const accepted = try acceptRequest(try parseRequest(&reader));
    try std.testing.expect(accepted.permessage_deflate == null);
}

test "acceptRequest negotiates permessage-deflate when offered" {
    var reader = Io.Reader.fixed(validRequest("Sec-WebSocket-Extensions: permessage-deflate; client_no_context_takeover\r\n"));
    const accepted = try acceptRequest(try parseRequest(&reader));
    try std.testing.expectEqualDeep(
        extensions.PerMessageDeflate{
            .server_no_context_takeover = true,
            .client_no_context_takeover = true,
        },
        accepted.permessage_deflate.?,
    );
}

test "acceptRequest rejects malformed permessage-deflate offers" {
    var reader = Io.Reader.fixed(validRequest("Sec-WebSocket-Extensions: permessage-deflate; server_max_window_bits=99\r\n"));
    try std.testing.expectError(error.ExtensionsNotSupported, acceptRequest(try parseRequest(&reader)));
}

test "acceptRequest accepts repeated permessage-deflate offers as alternatives" {
    var reader = Io.Reader.fixed(validRequest(
        "Sec-WebSocket-Extensions: permessage-deflate, permessage-deflate; client_no_context_takeover\r\n",
    ));
    const accepted = try acceptRequest(try parseRequest(&reader));
    try std.testing.expectEqualDeep(
        extensions.PerMessageDeflate{
            .server_no_context_takeover = true,
            .client_no_context_takeover = true,
        },
        accepted.permessage_deflate.?,
    );
}

test "acceptRequest reports all validation errors" {
    {
        const req: Request = .{ .method = "POST", .is_http_11 = true };
        try std.testing.expectError(error.MethodNotGet, acceptRequest(req));
    }
    {
        const req: Request = .{ .method = "GET", .is_http_11 = false };
        try std.testing.expectError(error.HttpVersionNotSupported, acceptRequest(req));
    }
    {
        const req: Request = .{ .method = "GET", .is_http_11 = true };
        try std.testing.expectError(error.MissingConnectionHeader, acceptRequest(req));
    }
    {
        const req: Request = .{ .method = "GET", .is_http_11 = true, .connection = "close" };
        try std.testing.expectError(error.InvalidConnectionHeader, acceptRequest(req));
    }
    {
        const req: Request = .{ .method = "GET", .is_http_11 = true, .connection = "Upgrade" };
        try std.testing.expectError(error.MissingUpgradeHeader, acceptRequest(req));
    }
    {
        const req: Request = .{ .method = "GET", .is_http_11 = true, .connection = "Upgrade", .upgrade = "h2c" };
        try std.testing.expectError(error.InvalidUpgradeHeader, acceptRequest(req));
    }
    {
        const req: Request = .{ .method = "GET", .is_http_11 = true, .connection = "Upgrade", .upgrade = "websocket" };
        try std.testing.expectError(error.MissingWebSocketKey, acceptRequest(req));
    }
    {
        const req: Request = .{
            .method = "GET",
            .is_http_11 = true,
            .connection = "Upgrade",
            .upgrade = "websocket",
            .sec_websocket_key = "invalid",
            .sec_websocket_version = "13",
        };
        try std.testing.expectError(error.InvalidWebSocketKey, acceptRequest(req));
    }
    {
        const req: Request = .{
            .method = "GET",
            .is_http_11 = true,
            .connection = "Upgrade",
            .upgrade = "websocket",
            .sec_websocket_key = "dGhlIHNhbXBsZSBub25jZQ==",
        };
        try std.testing.expectError(error.MissingWebSocketVersion, acceptRequest(req));
    }
    {
        const req: Request = .{
            .method = "GET",
            .is_http_11 = true,
            .connection = "Upgrade",
            .upgrade = "websocket",
            .sec_websocket_key = "dGhlIHNhbXBsZSBub25jZQ==",
            .sec_websocket_version = "12",
        };
        try std.testing.expectError(error.UnsupportedWebSocketVersion, acceptRequest(req));
    }
}

test "upgrade writes the server response without optional headers when extensions are absent" {
    var reader = Io.Reader.fixed(validRequest(""));
    var out: [256]u8 = undefined;
    var writer = Io.Writer.fixed(out[0..]);
    const negotiated = try upgrade(&reader, &writer);
    try std.testing.expect(negotiated == null);
    try std.testing.expectEqualStrings(
        "HTTP/1.1 101 Switching Protocols\r\n" ++
            "upgrade: websocket\r\n" ++
            "connection: Upgrade\r\n" ++
            "sec-websocket-accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n" ++
            "\r\n",
        out[0..writer.end],
    );
}

test "upgrade writes the negotiated permessage-deflate header" {
    var reader = Io.Reader.fixed(validRequest(
        "Sec-WebSocket-Extensions: permessage-deflate; client_no_context_takeover\r\n",
    ));
    var out: [384]u8 = undefined;
    var writer = Io.Writer.fixed(out[0..]);
    const negotiated = (try upgrade(&reader, &writer)).?;
    try std.testing.expectEqualDeep(
        extensions.PerMessageDeflate{
            .server_no_context_takeover = true,
            .client_no_context_takeover = true,
        },
        negotiated,
    );
    try std.testing.expectEqualStrings(
        "HTTP/1.1 101 Switching Protocols\r\n" ++
            "upgrade: websocket\r\n" ++
            "connection: Upgrade\r\n" ++
            "sec-websocket-accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n" ++
            "sec-websocket-extensions: permessage-deflate; server_no_context_takeover; client_no_context_takeover\r\n" ++
            "\r\n",
        out[0..writer.end],
    );
}

test "upgrade propagates writer errors" {
    var reader = Io.Reader.fixed(validRequest(""));
    var out: [8]u8 = undefined;
    var writer = Io.Writer.fixed(out[0..]);
    try std.testing.expectError(error.WriteFailed, upgrade(&reader, &writer));
}
