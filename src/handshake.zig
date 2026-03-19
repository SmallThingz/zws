const std = @import("std");
const Io = std.Io;

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const ServerHandshakeRequest = struct {
    method: []const u8,
    is_http_11: bool,
    connection: ?[]const u8 = null,
    upgrade: ?[]const u8 = null,
    sec_websocket_key: ?[]const u8 = null,
    sec_websocket_version: ?[]const u8 = null,
    sec_websocket_protocol: ?[]const u8 = null,
    sec_websocket_extensions: ?[]const u8 = null,
    origin: ?[]const u8 = null,
    host: ?[]const u8 = null,
};

pub const ServerHandshakeOptions = struct {
    selected_subprotocol: ?[]const u8 = null,
    reject_extensions: bool = false,
    extra_headers: []const Header = &.{},
};

pub const ServerHandshakeResponse = struct {
    accept_key: [28]u8,
    selected_subprotocol: ?[]const u8,
    extra_headers: []const Header,
};

pub const HandshakeError = error{
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
    SubprotocolNotOffered,
};

const websocket_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

fn containsTokenIgnoreCase(value: []const u8, wanted: []const u8) bool {
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |part| {
        const token = std.mem.trim(u8, part, " \t");
        if (std.ascii.eqlIgnoreCase(token, wanted)) return true;
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

fn subprotocolWasOffered(offered: []const u8, selected: []const u8) bool {
    var it = std.mem.splitScalar(u8, offered, ',');
    while (it.next()) |part| {
        const token = std.mem.trim(u8, part, " \t");
        if (std.mem.eql(u8, token, selected)) return true;
    }
    return false;
}

pub fn computeAcceptKey(client_key: []const u8) HandshakeError![28]u8 {
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

pub fn acceptServerHandshake(
    req: ServerHandshakeRequest,
    opts: ServerHandshakeOptions,
) HandshakeError!ServerHandshakeResponse {
    if (!std.mem.eql(u8, req.method, "GET")) return error.MethodNotGet;
    if (!req.is_http_11) return error.HttpVersionNotSupported;

    const connection = req.connection orelse return error.MissingConnectionHeader;
    if (!containsTokenIgnoreCase(connection, "upgrade")) return error.InvalidConnectionHeader;

    const upgrade = req.upgrade orelse return error.MissingUpgradeHeader;
    if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, upgrade, " \t"), "websocket")) {
        return error.InvalidUpgradeHeader;
    }

    const key = req.sec_websocket_key orelse return error.MissingWebSocketKey;
    const version = req.sec_websocket_version orelse return error.MissingWebSocketVersion;
    if (!std.mem.eql(u8, std.mem.trim(u8, version, " \t"), "13")) {
        return error.UnsupportedWebSocketVersion;
    }

    if (opts.reject_extensions and req.sec_websocket_extensions != null) {
        return error.ExtensionsNotSupported;
    }

    if (opts.selected_subprotocol) |selected| {
        const offered = req.sec_websocket_protocol orelse return error.SubprotocolNotOffered;
        if (!subprotocolWasOffered(offered, selected)) return error.SubprotocolNotOffered;
    }

    return .{
        .accept_key = try computeAcceptKey(key),
        .selected_subprotocol = opts.selected_subprotocol,
        .extra_headers = opts.extra_headers,
    };
}

pub fn writeServerHandshakeResponse(
    writer: *Io.Writer,
    response: ServerHandshakeResponse,
) Io.Writer.Error!void {
    try writer.writeAll("HTTP/1.1 101 Switching Protocols\r\n");
    try writer.writeAll("upgrade: websocket\r\n");
    try writer.writeAll("connection: Upgrade\r\n");
    try writer.writeAll("sec-websocket-accept: ");
    try writer.writeAll(response.accept_key[0..]);
    try writer.writeAll("\r\n");

    if (response.selected_subprotocol) |subprotocol| {
        try writer.writeAll("sec-websocket-protocol: ");
        try writer.writeAll(subprotocol);
        try writer.writeAll("\r\n");
    }

    for (response.extra_headers) |header| {
        try writer.writeAll(header.name);
        try writer.writeAll(": ");
        try writer.writeAll(header.value);
        try writer.writeAll("\r\n");
    }

    try writer.writeAll("\r\n");
}

pub fn serverHandshake(
    writer: *Io.Writer,
    req: ServerHandshakeRequest,
    opts: ServerHandshakeOptions,
) (HandshakeError || Io.Writer.Error)!ServerHandshakeResponse {
    const response = try acceptServerHandshake(req, opts);
    try writeServerHandshakeResponse(writer, response);
    return response;
}

fn validRequest() ServerHandshakeRequest {
    return .{
        .method = "GET",
        .is_http_11 = true,
        .connection = "keep-alive, Upgrade",
        .upgrade = " websocket ",
        .sec_websocket_key = "dGhlIHNhbXBsZSBub25jZQ==",
        .sec_websocket_version = " 13 ",
        .sec_websocket_protocol = "chat, superchat",
        .host = "example.com",
    };
}

test "computeAcceptKey matches RFC example" {
    const got = try computeAcceptKey("dGhlIHNhbXBsZSBub25jZQ==");
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", got[0..]);
}

test "containsTokenIgnoreCase ignores ASCII case and whitespace" {
    try std.testing.expect(containsTokenIgnoreCase("keep-alive, Upgrade", "upgrade"));
    try std.testing.expect(containsTokenIgnoreCase(" keep-alive ,\tUPGRADE ", "upgrade"));
    try std.testing.expect(!containsTokenIgnoreCase("upgrader", "upgrade"));
    try std.testing.expect(!containsTokenIgnoreCase("", "upgrade"));
}

test "validateClientKey enforces valid base64 and 16 decoded bytes" {
    try std.testing.expect(validateClientKey("dGhlIHNhbXBsZSBub25jZQ=="));
    try std.testing.expect(!validateClientKey("!!!!"));
    try std.testing.expect(!validateClientKey("dGVzdA=="));
    try std.testing.expect(!validateClientKey("dGhlIHNhbXBsZSBub25jZQ"));
}

test "subprotocolWasOffered matches exact token only" {
    try std.testing.expect(subprotocolWasOffered("chat, superchat", "chat"));
    try std.testing.expect(subprotocolWasOffered("chat, superchat", "superchat"));
    try std.testing.expect(!subprotocolWasOffered("chatty, superchat", "chat"));
    try std.testing.expect(!subprotocolWasOffered("", "chat"));
}

test "computeAcceptKey rejects invalid client keys" {
    try std.testing.expectError(error.InvalidWebSocketKey, computeAcceptKey("invalid"));
}

test "acceptServerHandshake accepts trimmed valid request without subprotocol selection" {
    const response = try acceptServerHandshake(validRequest(), .{});
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", response.accept_key[0..]);
    try std.testing.expect(response.selected_subprotocol == null);
    try std.testing.expectEqual(@as(usize, 0), response.extra_headers.len);
}

test "acceptServerHandshake reports all validation errors" {
    {
        var req = validRequest();
        req.method = "POST";
        try std.testing.expectError(error.MethodNotGet, acceptServerHandshake(req, .{}));
    }
    {
        var req = validRequest();
        req.is_http_11 = false;
        try std.testing.expectError(error.HttpVersionNotSupported, acceptServerHandshake(req, .{}));
    }
    {
        var req = validRequest();
        req.connection = null;
        try std.testing.expectError(error.MissingConnectionHeader, acceptServerHandshake(req, .{}));
    }
    {
        var req = validRequest();
        req.connection = "keep-alive";
        try std.testing.expectError(error.InvalidConnectionHeader, acceptServerHandshake(req, .{}));
    }
    {
        var req = validRequest();
        req.upgrade = null;
        try std.testing.expectError(error.MissingUpgradeHeader, acceptServerHandshake(req, .{}));
    }
    {
        var req = validRequest();
        req.upgrade = "h2c";
        try std.testing.expectError(error.InvalidUpgradeHeader, acceptServerHandshake(req, .{}));
    }
    {
        var req = validRequest();
        req.sec_websocket_key = null;
        try std.testing.expectError(error.MissingWebSocketKey, acceptServerHandshake(req, .{}));
    }
    {
        var req = validRequest();
        req.sec_websocket_key = "short";
        try std.testing.expectError(error.InvalidWebSocketKey, acceptServerHandshake(req, .{}));
    }
    {
        var req = validRequest();
        req.sec_websocket_version = null;
        try std.testing.expectError(error.MissingWebSocketVersion, acceptServerHandshake(req, .{}));
    }
    {
        var req = validRequest();
        req.sec_websocket_version = "12";
        try std.testing.expectError(error.UnsupportedWebSocketVersion, acceptServerHandshake(req, .{}));
    }
    {
        var req = validRequest();
        req.sec_websocket_extensions = "permessage-deflate";
        try std.testing.expectError(error.ExtensionsNotSupported, acceptServerHandshake(req, .{
            .reject_extensions = true,
        }));
    }
    {
        var req = validRequest();
        req.sec_websocket_protocol = null;
        try std.testing.expectError(error.SubprotocolNotOffered, acceptServerHandshake(req, .{
            .selected_subprotocol = "chat",
        }));
    }
}

test "acceptServerHandshake requires exact offered subprotocol token" {
    var req = validRequest();
    req.sec_websocket_protocol = " chat , superchat ";
    const response = try acceptServerHandshake(req, .{
        .selected_subprotocol = "superchat",
        .extra_headers = &.{.{ .name = "x-extra", .value = "1" }},
    });
    try std.testing.expectEqualStrings("superchat", response.selected_subprotocol.?);
    try std.testing.expectEqual(@as(usize, 1), response.extra_headers.len);
    try std.testing.expectError(error.SubprotocolNotOffered, acceptServerHandshake(req, .{
        .selected_subprotocol = "CHAT",
    }));
}

test "server handshake validates and writes response" {
    var out: [512]u8 = undefined;
    var writer = Io.Writer.fixed(out[0..]);
    _ = try serverHandshake(&writer, validRequest(), .{
        .selected_subprotocol = "chat",
        .extra_headers = &.{.{ .name = "x-test", .value = "1" }},
    });

    const got = out[0..writer.end];
    try std.testing.expect(std.mem.indexOf(u8, got, "HTTP/1.1 101 Switching Protocols\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "sec-websocket-accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "sec-websocket-protocol: chat\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "x-test: 1\r\n") != null);
}

test "writeServerHandshakeResponse omits optional headers when absent" {
    var out: [256]u8 = undefined;
    var writer = Io.Writer.fixed(out[0..]);
    try writeServerHandshakeResponse(&writer, .{
        .accept_key = ("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=").*,
        .selected_subprotocol = null,
        .extra_headers = &.{},
    });

    try std.testing.expectEqualStrings(
        "HTTP/1.1 101 Switching Protocols\r\n" ++
            "upgrade: websocket\r\n" ++
            "connection: Upgrade\r\n" ++
            "sec-websocket-accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n" ++
            "\r\n",
        out[0..writer.end],
    );
}

test "serverHandshake propagates writer errors" {
    var out: [8]u8 = undefined;
    var writer = Io.Writer.fixed(out[0..]);
    try std.testing.expectError(error.WriteFailed, serverHandshake(&writer, validRequest(), .{}));
}
