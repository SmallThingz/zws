const std = @import("std");
const Io = std.Io;
const extensions = @import("extensions.zig");
const observe = @import("observe.zig");

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
    enable_permessage_deflate: bool = false,
    permessage_deflate: extensions.PerMessageDeflate = .{},
    extra_headers: []const Header = &.{},
    observer: ?observe.Observer = null,
};

pub const ServerHandshakeResponse = struct {
    accept_key: [28]u8,
    selected_subprotocol: ?[]const u8,
    selected_extensions: ?[]const u8 = null,
    permessage_deflate: ?extensions.PerMessageDeflate = null,
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
    if (!std.mem.eql(u8, req.method, "GET")) return rejectHandshake(opts.observer, error.MethodNotGet);
    if (!req.is_http_11) return rejectHandshake(opts.observer, error.HttpVersionNotSupported);

    const connection = req.connection orelse return rejectHandshake(opts.observer, error.MissingConnectionHeader);
    if (!containsTokenIgnoreCase(connection, "upgrade")) return rejectHandshake(opts.observer, error.InvalidConnectionHeader);

    const upgrade = req.upgrade orelse return rejectHandshake(opts.observer, error.MissingUpgradeHeader);
    if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, upgrade, " \t"), "websocket")) {
        return rejectHandshake(opts.observer, error.InvalidUpgradeHeader);
    }

    const key = std.mem.trim(u8, req.sec_websocket_key orelse return rejectHandshake(opts.observer, error.MissingWebSocketKey), " \t");
    const version = req.sec_websocket_version orelse return rejectHandshake(opts.observer, error.MissingWebSocketVersion);
    if (!std.mem.eql(u8, std.mem.trim(u8, version, " \t"), "13")) {
        return rejectHandshake(opts.observer, error.UnsupportedWebSocketVersion);
    }

    if (opts.reject_extensions and req.sec_websocket_extensions != null) {
        return rejectHandshake(opts.observer, error.ExtensionsNotSupported);
    }

    var negotiated_permessage_deflate: ?extensions.PerMessageDeflate = null;
    if (opts.enable_permessage_deflate) {
        if (req.sec_websocket_extensions) |header_value| {
            const offered = extensions.parsePerMessageDeflate(header_value) catch {
                return rejectHandshake(opts.observer, error.ExtensionsNotSupported);
            };
            if (offered != null) {
                negotiated_permessage_deflate = opts.permessage_deflate;
            }
        }
    }

    if (opts.selected_subprotocol) |selected| {
        const offered = req.sec_websocket_protocol orelse return rejectHandshake(opts.observer, error.SubprotocolNotOffered);
        if (!subprotocolWasOffered(offered, selected)) return rejectHandshake(opts.observer, error.SubprotocolNotOffered);
    }

    const accept_key = computeAcceptKey(key) catch |err| {
        return rejectHandshake(opts.observer, err);
    };

    const response: ServerHandshakeResponse = .{
        .accept_key = accept_key,
        .selected_subprotocol = opts.selected_subprotocol,
        .selected_extensions = if (negotiated_permessage_deflate) |pmd| pmd.responseHeaderValue() else null,
        .permessage_deflate = negotiated_permessage_deflate,
        .extra_headers = opts.extra_headers,
    };
    if (opts.observer) |observer| {
        observer.emit(.{ .handshake_accepted = .{
            .selected_subprotocol = response.selected_subprotocol != null,
            .permessage_deflate = response.permessage_deflate != null,
            .extra_headers_len = response.extra_headers.len,
        } });
    }
    return response;
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

    if (response.selected_extensions) |selected_extensions| {
        try writer.writeAll("sec-websocket-extensions: ");
        try writer.writeAll(selected_extensions);
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

fn rejectHandshake(observer: ?observe.Observer, err: HandshakeError) HandshakeError {
    if (observer) |o| {
        o.emit(.{ .handshake_rejected = .{ .name = @errorName(err) } });
    }
    return err;
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

test "subprotocolWasOffered matches exact token only" {
    try std.testing.expect(subprotocolWasOffered("chat, superchat", "chat"));
    try std.testing.expect(subprotocolWasOffered("chat, superchat", "superchat"));
    try std.testing.expect(subprotocolWasOffered(" chat , , superchat ", "chat"));
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

test "acceptServerHandshake trims websocket key before validation" {
    var req = validRequest();
    req.sec_websocket_key = " \tdGhlIHNhbXBsZSBub25jZQ== \t";

    const response = try acceptServerHandshake(req, .{});
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", response.accept_key[0..]);
}

test "acceptServerHandshake allows extensions unless configured to reject them" {
    var req = validRequest();
    req.sec_websocket_extensions = "permessage-deflate";

    const response = try acceptServerHandshake(req, .{});
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", response.accept_key[0..]);
    try std.testing.expect(response.permessage_deflate == null);
}

test "acceptServerHandshake negotiates permessage-deflate when enabled and offered" {
    var req = validRequest();
    req.sec_websocket_extensions = "permessage-deflate; client_max_window_bits, x-test";

    const response = try acceptServerHandshake(req, .{
        .enable_permessage_deflate = true,
    });
    try std.testing.expectEqualStrings(
        "permessage-deflate; server_no_context_takeover; client_no_context_takeover",
        response.selected_extensions.?,
    );
    try std.testing.expect(response.permessage_deflate != null);
}

test "acceptServerHandshake rejects malformed permessage-deflate offers when negotiation is enabled" {
    var req = validRequest();
    req.sec_websocket_extensions = "permessage-deflate; server_max_window_bits=99";

    try std.testing.expectError(error.ExtensionsNotSupported, acceptServerHandshake(req, .{
        .enable_permessage_deflate = true,
    }));
}

test "acceptServerHandshake accepts connection token with extra commas and spaces" {
    var req = validRequest();
    req.connection = "keep-alive, , Upgrade ,";

    const response = try acceptServerHandshake(req, .{});
    try std.testing.expect(response.selected_subprotocol == null);
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
        .selected_extensions = null,
        .permessage_deflate = null,
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

test "writeServerHandshakeResponse preserves header order for subprotocol and extras" {
    var out: [384]u8 = undefined;
    var writer = Io.Writer.fixed(out[0..]);
    try writeServerHandshakeResponse(&writer, .{
        .accept_key = ("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=").*,
        .selected_subprotocol = "chat",
        .selected_extensions = "permessage-deflate; server_no_context_takeover; client_no_context_takeover",
        .permessage_deflate = .{},
        .extra_headers = &.{
            .{ .name = "x-first", .value = "1" },
            .{ .name = "x-second", .value = "2" },
        },
    });

    try std.testing.expectEqualStrings(
        "HTTP/1.1 101 Switching Protocols\r\n" ++
            "upgrade: websocket\r\n" ++
            "connection: Upgrade\r\n" ++
            "sec-websocket-accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n" ++
            "sec-websocket-protocol: chat\r\n" ++
            "sec-websocket-extensions: permessage-deflate; server_no_context_takeover; client_no_context_takeover\r\n" ++
            "x-first: 1\r\n" ++
            "x-second: 2\r\n" ++
            "\r\n",
        out[0..writer.end],
    );
}

test "serverHandshake propagates writer errors" {
    var out: [8]u8 = undefined;
    var writer = Io.Writer.fixed(out[0..]);
    try std.testing.expectError(error.WriteFailed, serverHandshake(&writer, validRequest(), .{}));
}

test "rejectHandshake emits through the observer and returns the original error" {
    const State = struct {
        event: ?observe.Event = null,

        fn onEvent(ctx: ?*anyopaque, event: observe.Event) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.event = event;
        }
    };

    var state: State = .{};
    const observer: observe.Observer = .{
        .ctx = &state,
        .on_event_fn = State.onEvent,
    };
    try std.testing.expectEqual(error.ExtensionsNotSupported, rejectHandshake(observer, error.ExtensionsNotSupported));
    switch (state.event.?) {
        .handshake_rejected => |event| try std.testing.expectEqualStrings("ExtensionsNotSupported", event.name),
        else => return error.TestExpectedEqual,
    }
}

test "handshake observer sees accepted and rejected outcomes" {
    const State = struct {
        events: [2]observe.Event = undefined,
        len: usize = 0,

        fn onEvent(ctx: ?*anyopaque, event: observe.Event) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.events[self.len] = event;
            self.len += 1;
        }
    };

    var accepted_state: State = .{};
    _ = try acceptServerHandshake(validRequest(), .{
        .observer = .{
            .ctx = &accepted_state,
            .on_event_fn = State.onEvent,
        },
    });
    try std.testing.expectEqual(@as(usize, 1), accepted_state.len);
    switch (accepted_state.events[0]) {
        .handshake_accepted => |event| {
            try std.testing.expect(!event.selected_subprotocol);
            try std.testing.expect(!event.permessage_deflate);
            try std.testing.expectEqual(@as(usize, 0), event.extra_headers_len);
        },
        else => return error.TestExpectedEqual,
    }

    var rejected_req = validRequest();
    rejected_req.method = "POST";
    var rejected_state: State = .{};
    try std.testing.expectError(error.MethodNotGet, acceptServerHandshake(rejected_req, .{
        .observer = .{
            .ctx = &rejected_state,
            .on_event_fn = State.onEvent,
        },
    }));
    try std.testing.expectEqual(@as(usize, 1), rejected_state.len);
    switch (rejected_state.events[0]) {
        .handshake_rejected => |event| try std.testing.expectEqualStrings("MethodNotGet", event.name),
        else => return error.TestExpectedEqual,
    }
}
