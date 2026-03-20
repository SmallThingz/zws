const std = @import("std");

const conn = @import("conn.zig");
const handshake = @import("handshake.zig");
const proto = @import("protocol.zig");
const ServerConn = conn.Conn(.{ .role = .server });
const ClientConn = conn.Conn(.{ .role = .client });

pub const CompatError = error{HeaderBufferTooSmall};

pub const RunnerAdapterOptions = struct {
    close_code: u16 = @intFromEnum(proto.CloseCode.internal_error),
    close_reason: []const u8 = "",
    read_buffer_len: usize = 64,
    write_buffer_len: usize = 128,
};

pub const UpgradeHeaders = struct {
    connection: ?[]const u8 = null,
    upgrade: ?[]const u8 = null,
    sec_websocket_key: ?[]const u8 = null,
    sec_websocket_version: ?[]const u8 = null,
    sec_websocket_protocol: ?[]const u8 = null,
    sec_websocket_extensions: ?[]const u8 = null,
    origin: ?[]const u8 = null,
    host: ?[]const u8 = null,
};

pub fn requestFromHeaders(
    method: []const u8,
    is_http_11: bool,
    headers: UpgradeHeaders,
) handshake.ServerHandshakeRequest {
    return .{
        .method = method,
        .is_http_11 = is_http_11,
        .connection = headers.connection,
        .upgrade = headers.upgrade,
        .sec_websocket_key = headers.sec_websocket_key,
        .sec_websocket_version = headers.sec_websocket_version,
        .sec_websocket_protocol = headers.sec_websocket_protocol,
        .sec_websocket_extensions = headers.sec_websocket_extensions,
        .origin = headers.origin,
        .host = headers.host,
    };
}

pub fn requestFromZhttp(req: anytype) handshake.ServerHandshakeRequest {
    const req_ptr = switch (@typeInfo(@TypeOf(req))) {
        .pointer => req,
        else => &req,
    };
    return requestFromHeaders(req_ptr.method, req_ptr.base.version == .http11, .{
        .connection = req_ptr.header(.connection),
        .upgrade = req_ptr.header(.upgrade),
        .sec_websocket_key = req_ptr.header(.sec_websocket_key),
        .sec_websocket_version = req_ptr.header(.sec_websocket_version),
        .sec_websocket_protocol = req_ptr.header(.sec_websocket_protocol),
        .sec_websocket_extensions = req_ptr.header(.sec_websocket_extensions),
        .origin = req_ptr.header(.origin),
        .host = req_ptr.header(.host),
    });
}

pub fn acceptZhttpUpgrade(
    req: anytype,
    opts: handshake.ServerHandshakeOptions,
) handshake.HandshakeError!handshake.ServerHandshakeResponse {
    return handshake.acceptServerHandshake(requestFromZhttp(req), opts);
}

pub fn responseHeaderCount(response: handshake.ServerHandshakeResponse) usize {
    return 3 +
        @as(usize, @intFromBool(response.selected_subprotocol != null)) +
        @as(usize, @intFromBool(response.selected_extensions != null)) +
        response.extra_headers.len;
}

pub fn fillResponseHeaders(
    comptime HeaderT: type,
    dest: []HeaderT,
    response: handshake.ServerHandshakeResponse,
) CompatError![]const HeaderT {
    const needed = responseHeaderCount(response);
    if (dest.len < needed) return error.HeaderBufferTooSmall;

    var len: usize = 0;
    dest[len] = .{ .name = "connection", .value = "Upgrade" };
    len += 1;
    dest[len] = .{ .name = "upgrade", .value = "websocket" };
    len += 1;
    dest[len] = .{ .name = "sec-websocket-accept", .value = response.accept_key[0..] };
    len += 1;

    if (response.selected_subprotocol) |subprotocol| {
        dest[len] = .{ .name = "sec-websocket-protocol", .value = subprotocol };
        len += 1;
    }

    if (response.selected_extensions) |selected_extensions| {
        dest[len] = .{ .name = "sec-websocket-extensions", .value = selected_extensions };
        len += 1;
    }

    for (response.extra_headers) |header| {
        dest[len] = .{ .name = header.name, .value = header.value };
        len += 1;
    }

    return dest[0..len];
}

pub fn makeUpgradeResponse(
    comptime ResT: type,
    comptime HeaderT: type,
    dest: []HeaderT,
    response: handshake.ServerHandshakeResponse,
) CompatError!ResT {
    return .{
        .status = .switching_protocols,
        .headers = try fillResponseHeaders(HeaderT, dest, response),
    };
}

pub fn adaptZhttpRunner(comptime Runner: type, comptime opts: RunnerAdapterOptions) type {
    const Io = std.Io;
    const Allocator = std.mem.Allocator;
    const Stream = std.Io.net.Stream;
    const run_info = @typeInfo(@TypeOf(Runner.run));
    if (run_info != .@"fn") @compileError(@typeName(Runner) ++ ".run must be a function");
    const params = run_info.@"fn".params;
    if (opts.read_buffer_len == 0) @compileError("RunnerAdapterOptions.read_buffer_len must be > 0");
    if (opts.write_buffer_len == 0) @compileError("RunnerAdapterOptions.write_buffer_len must be > 0");

    const RunnerData = if (@hasDecl(Runner, "Data")) Runner.Data else void;

    const Common = struct {
        fn callAndHandle(io: Io, stream: Stream, result: anytype) void {
            const Result = @TypeOf(result);
            switch (@typeInfo(Result)) {
                .void => {},
                .error_union => {
                    _ = result catch {
                        sendInternalErrorClose(io, stream);
                    };
                },
                else => @compileError(@typeName(Runner) ++ ".run may only return void or !void"),
            }
        }

        fn sendInternalErrorClose(io: Io, stream: Stream) void {
            var owned_stream = stream;
            var read_buf: [opts.read_buffer_len]u8 = undefined;
            var write_buf: [opts.write_buffer_len]u8 = undefined;
            var reader = owned_stream.reader(io, &read_buf);
            var writer = owned_stream.writer(io, &write_buf);
            var ws = ServerConn.init(&reader.interface, &writer.interface, .{});
            ws.writeClose(opts.close_code, opts.close_reason) catch {};
            ws.flush() catch {};
        }
    };

    return switch (params.len) {
        3 => struct {
            pub fn run(io: Io, gpa: Allocator, stream: Stream) void {
                Common.callAndHandle(io, stream, @call(.auto, Runner.run, .{ io, gpa, stream }));
            }
        },
        4 => blk: {
            const p0 = params[0].type orelse @compileError(@typeName(Runner) ++ ".run first param must be typed");
            const p3 = params[3].type orelse @compileError(@typeName(Runner) ++ ".run fourth param must be typed");
            if (p0 == Io) break :blk struct {
                pub const Data = Runner.Data;

                pub fn initData() Data {
                    if (@hasDecl(Runner, "initData")) return Runner.initData();
                    return std.mem.zeroInit(Data, .{});
                }

                pub fn deinitData(gpa: Allocator, data: *Data) void {
                    if (@hasDecl(Runner, "deinitData")) Runner.deinitData(gpa, data);
                }

                pub fn run(io: Io, gpa: Allocator, stream: Stream, data: p3) void {
                    Common.callAndHandle(io, stream, @call(.auto, Runner.run, .{ io, gpa, stream, data }));
                }
            };
            break :blk struct {
                pub fn run(ctx: p0, io: Io, gpa: Allocator, stream: Stream) void {
                    Common.callAndHandle(io, stream, @call(.auto, Runner.run, .{ ctx, io, gpa, stream }));
                }
            };
        },
        5 => blk: {
            const p0 = params[0].type orelse @compileError(@typeName(Runner) ++ ".run first param must be typed");
            const p4 = params[4].type orelse @compileError(@typeName(Runner) ++ ".run fifth param must be typed");
            _ = RunnerData;
            break :blk struct {
                pub const Data = Runner.Data;

                pub fn initData() Data {
                    if (@hasDecl(Runner, "initData")) return Runner.initData();
                    return std.mem.zeroInit(Data, .{});
                }

                pub fn deinitData(gpa: Allocator, data: *Data) void {
                    if (@hasDecl(Runner, "deinitData")) Runner.deinitData(gpa, data);
                }

                pub fn run(ctx: p0, io: Io, gpa: Allocator, stream: Stream, data: p4) void {
                    Common.callAndHandle(io, stream, @call(.auto, Runner.run, .{ ctx, io, gpa, stream, data }));
                }
            };
        },
        else => @compileError(@typeName(Runner) ++ ".run must match a supported zhttp upgrade runner form"),
    };
}

fn openLoopbackPair(io: std.Io) !struct { client: std.Io.net.Stream, server: std.Io.net.Stream } {
    const addr0: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
    var listener = try std.Io.net.IpAddress.listen(addr0, io, .{ .reuse_address = true });
    defer listener.deinit(io);

    const port: u16 = listener.socket.address.getPort();
    const addr: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(port) };
    const client = try std.Io.net.IpAddress.connect(addr, io, .{ .mode = .stream });
    errdefer client.close(io);
    const server = try listener.accept(io);
    return .{ .client = client, .server = server };
}

fn expectClientClose(io: std.Io, stream: std.Io.net.Stream, expected_code: ?u16, expected_reason: []const u8) !void {
    var owned_stream = stream;
    var read_buf: [256]u8 = undefined;
    var write_buf: [64]u8 = undefined;
    var reader = owned_stream.reader(io, &read_buf);
    var writer = owned_stream.writer(io, &write_buf);
    var ws = ClientConn.init(&reader.interface, &writer.interface, .{});
    var frame_buf: [128]u8 = undefined;
    const frame = try ws.readFrame(frame_buf[0..]);
    try std.testing.expectEqual(proto.Opcode.close, frame.header.opcode);
    const parsed = try conn.parseClosePayload(frame.payload, true);
    try std.testing.expectEqual(expected_code, parsed.code);
    try std.testing.expectEqualStrings(expected_reason, parsed.reason);
}

fn expectClientText(io: std.Io, stream: std.Io.net.Stream, expected_text: []const u8) !void {
    var owned_stream = stream;
    var read_buf: [256]u8 = undefined;
    var write_buf: [64]u8 = undefined;
    var reader = owned_stream.reader(io, &read_buf);
    var writer = owned_stream.writer(io, &write_buf);
    var ws = ClientConn.init(&reader.interface, &writer.interface, .{});
    var frame_buf: [256]u8 = undefined;
    const frame = try ws.readFrame(frame_buf[0..]);
    try std.testing.expectEqual(proto.Opcode.text, frame.header.opcode);
    try std.testing.expectEqualStrings(expected_text, frame.payload);
}

test "requestFromHeaders maps zhttp header captures into a handshake request" {
    const req = requestFromHeaders("GET", true, .{
        .connection = "Upgrade",
        .upgrade = "websocket",
        .sec_websocket_key = "dGhlIHNhbXBsZSBub25jZQ==",
        .sec_websocket_version = "13",
        .sec_websocket_protocol = "chat",
        .origin = "https://example.com",
    });

    try std.testing.expectEqualStrings("GET", req.method);
    try std.testing.expect(req.is_http_11);
    try std.testing.expectEqualStrings("Upgrade", req.connection.?);
    try std.testing.expectEqualStrings("websocket", req.upgrade.?);
    try std.testing.expectEqualStrings("chat", req.sec_websocket_protocol.?);
    try std.testing.expectEqualStrings("https://example.com", req.origin.?);
}

test "requestFromHeaders preserves http version flag and missing optional headers" {
    const req = requestFromHeaders("GET", false, .{});

    try std.testing.expectEqualStrings("GET", req.method);
    try std.testing.expect(!req.is_http_11);
    try std.testing.expect(req.connection == null);
    try std.testing.expect(req.upgrade == null);
    try std.testing.expect(req.sec_websocket_key == null);
}

test "requestFromZhttp accepts value and pointer request shapes" {
    const FakeReq = struct {
        method: []const u8,
        base: struct { version: enum { http10, http11 } },
        connection: ?[]const u8 = null,
        upgrade: ?[]const u8 = null,
        sec_websocket_key: ?[]const u8 = null,
        sec_websocket_version: ?[]const u8 = null,

        pub fn header(self: *const @This(), comptime field: @EnumLiteral()) ?[]const u8 {
            return switch (field) {
                .connection => self.connection,
                .upgrade => self.upgrade,
                .sec_websocket_key => self.sec_websocket_key,
                .sec_websocket_version => self.sec_websocket_version,
                .sec_websocket_protocol, .sec_websocket_extensions, .origin, .host => null,
                else => unreachable,
            };
        }
    };

    const req: FakeReq = .{
        .method = "GET",
        .base = .{ .version = .http11 },
        .connection = "Upgrade",
        .upgrade = "websocket",
        .sec_websocket_key = "dGhlIHNhbXBsZSBub25jZQ==",
        .sec_websocket_version = "13",
    };

    const from_value = requestFromZhttp(req);
    const from_ptr = requestFromZhttp(&req);

    try std.testing.expectEqualStrings("GET", from_value.method);
    try std.testing.expect(from_value.is_http_11);
    try std.testing.expectEqualStrings(from_value.sec_websocket_key.?, from_ptr.sec_websocket_key.?);
}

test "requestFromZhttp reads all supported header accessors and http version" {
    const FakeReq = struct {
        method: []const u8,
        base: struct { version: enum { http10, http11 } },
        connection: ?[]const u8 = null,
        upgrade: ?[]const u8 = null,
        sec_websocket_key: ?[]const u8 = null,
        sec_websocket_version: ?[]const u8 = null,
        sec_websocket_protocol: ?[]const u8 = null,
        sec_websocket_extensions: ?[]const u8 = null,
        origin: ?[]const u8 = null,
        host: ?[]const u8 = null,

        pub fn header(self: *const @This(), comptime field: @EnumLiteral()) ?[]const u8 {
            return switch (field) {
                .connection => self.connection,
                .upgrade => self.upgrade,
                .sec_websocket_key => self.sec_websocket_key,
                .sec_websocket_version => self.sec_websocket_version,
                .sec_websocket_protocol => self.sec_websocket_protocol,
                .sec_websocket_extensions => self.sec_websocket_extensions,
                .origin => self.origin,
                .host => self.host,
                else => unreachable,
            };
        }
    };

    const req: FakeReq = .{
        .method = "GET",
        .base = .{ .version = .http10 },
        .connection = "Upgrade",
        .upgrade = "websocket",
        .sec_websocket_key = "dGhlIHNhbXBsZSBub25jZQ==",
        .sec_websocket_version = "13",
        .sec_websocket_protocol = "chat",
        .sec_websocket_extensions = "permessage-deflate",
        .origin = "https://example.com",
        .host = "example.com",
    };

    const converted = requestFromZhttp(req);
    try std.testing.expect(!converted.is_http_11);
    try std.testing.expectEqualStrings("chat", converted.sec_websocket_protocol.?);
    try std.testing.expectEqualStrings("permessage-deflate", converted.sec_websocket_extensions.?);
    try std.testing.expectEqualStrings("https://example.com", converted.origin.?);
    try std.testing.expectEqualStrings("example.com", converted.host.?);
}

test "acceptZhttpUpgrade and makeUpgradeResponse match zhttp route needs" {
    const FakeReq = struct {
        method: []const u8,
        base: struct { version: enum { http10, http11 } },
        connection: ?[]const u8 = null,
        upgrade: ?[]const u8 = null,
        sec_websocket_key: ?[]const u8 = null,
        sec_websocket_version: ?[]const u8 = null,
        sec_websocket_protocol: ?[]const u8 = null,
        sec_websocket_extensions: ?[]const u8 = null,

        pub fn header(self: *const @This(), comptime field: @EnumLiteral()) ?[]const u8 {
            return switch (field) {
                .connection => self.connection,
                .upgrade => self.upgrade,
                .sec_websocket_key => self.sec_websocket_key,
                .sec_websocket_version => self.sec_websocket_version,
                .sec_websocket_protocol => self.sec_websocket_protocol,
                .sec_websocket_extensions => self.sec_websocket_extensions,
                .origin, .host => null,
                else => unreachable,
            };
        }
    };
    const FakeHeader = struct {
        name: []const u8,
        value: []const u8,
    };
    const FakeRes = struct {
        status: std.http.Status = .ok,
        headers: []const FakeHeader = &.{},
        body: []const u8 = "",
        close: bool = false,
    };

    const req: FakeReq = .{
        .method = "GET",
        .base = .{ .version = .http11 },
        .connection = "keep-alive, Upgrade",
        .upgrade = "websocket",
        .sec_websocket_key = "dGhlIHNhbXBsZSBub25jZQ==",
        .sec_websocket_version = "13",
        .sec_websocket_protocol = "chat, superchat",
        .sec_websocket_extensions = "permessage-deflate",
    };

    const accepted = try acceptZhttpUpgrade(req, .{
        .selected_subprotocol = "chat",
        .enable_permessage_deflate = true,
        .extra_headers = &.{
            .{ .name = "x-trace-id", .value = "abc123" },
        },
    });
    var headers: [6]FakeHeader = undefined;
    const res = try makeUpgradeResponse(FakeRes, FakeHeader, headers[0..], accepted);

    try std.testing.expectEqual(std.http.Status.switching_protocols, res.status);
    try std.testing.expectEqual(@as(usize, 6), res.headers.len);
    try std.testing.expectEqualStrings("connection", res.headers[0].name);
    try std.testing.expectEqualStrings("Upgrade", res.headers[0].value);
    try std.testing.expectEqualStrings("upgrade", res.headers[1].name);
    try std.testing.expectEqualStrings("websocket", res.headers[1].value);
    try std.testing.expectEqualStrings("sec-websocket-accept", res.headers[2].name);
    try std.testing.expectEqualStrings("sec-websocket-protocol", res.headers[3].name);
    try std.testing.expectEqualStrings("chat", res.headers[3].value);
    try std.testing.expectEqualStrings("sec-websocket-extensions", res.headers[4].name);
    try std.testing.expectEqualStrings(
        "permessage-deflate; server_no_context_takeover; client_no_context_takeover",
        res.headers[4].value,
    );
    try std.testing.expectEqualStrings("x-trace-id", res.headers[5].name);
    try std.testing.expectEqualStrings("abc123", res.headers[5].value);
}

test "responseHeaderCount and fillResponseHeaders handle optional headers being absent" {
    const Header = struct {
        name: []const u8,
        value: []const u8,
    };
    const response: handshake.ServerHandshakeResponse = .{
        .accept_key = ("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=").*,
        .selected_subprotocol = null,
        .selected_extensions = null,
        .permessage_deflate = null,
        .extra_headers = &.{},
    };
    var headers: [3]Header = undefined;

    try std.testing.expectEqual(@as(usize, 3), responseHeaderCount(response));
    const filled = try fillResponseHeaders(Header, headers[0..], response);
    try std.testing.expectEqual(@as(usize, 3), filled.len);
    try std.testing.expectEqualStrings("connection", filled[0].name);
    try std.testing.expectEqualStrings("upgrade", filled[1].name);
    try std.testing.expectEqualStrings("sec-websocket-accept", filled[2].name);
}

test "responseHeaderCount includes subprotocol and extra headers" {
    try std.testing.expectEqual(@as(usize, 7), responseHeaderCount(.{
        .accept_key = ("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=").*,
        .selected_subprotocol = "chat",
        .selected_extensions = "permessage-deflate; server_no_context_takeover; client_no_context_takeover",
        .permessage_deflate = .{},
        .extra_headers = &.{
            .{ .name = "x-a", .value = "1" },
            .{ .name = "x-b", .value = "2" },
        },
    }));
}

test "acceptZhttpUpgrade propagates handshake validation errors" {
    const FakeReq = struct {
        method: []const u8,
        base: struct { version: enum { http10, http11 } },
        connection: ?[]const u8 = null,
        upgrade: ?[]const u8 = null,
        sec_websocket_key: ?[]const u8 = null,
        sec_websocket_version: ?[]const u8 = null,

        pub fn header(self: *const @This(), comptime field: @EnumLiteral()) ?[]const u8 {
            return switch (field) {
                .connection => self.connection,
                .upgrade => self.upgrade,
                .sec_websocket_key => self.sec_websocket_key,
                .sec_websocket_version => self.sec_websocket_version,
                .sec_websocket_protocol, .sec_websocket_extensions, .origin, .host => null,
                else => unreachable,
            };
        }
    };
    const req: FakeReq = .{
        .method = "POST",
        .base = .{ .version = .http11 },
        .connection = "Upgrade",
        .upgrade = "websocket",
        .sec_websocket_key = "dGhlIHNhbXBsZSBub25jZQ==",
        .sec_websocket_version = "13",
    };

    try std.testing.expectError(error.MethodNotGet, acceptZhttpUpgrade(req, .{}));
}

test "fillResponseHeaders rejects too-small header buffers" {
    var headers: [3]struct {
        name: []const u8,
        value: []const u8,
    } = undefined;

    try std.testing.expectError(error.HeaderBufferTooSmall, fillResponseHeaders(
        @TypeOf(headers[0]),
        headers[0..],
        .{
            .accept_key = ("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=").*,
            .selected_subprotocol = "chat",
            .selected_extensions = null,
            .permessage_deflate = null,
            .extra_headers = &.{},
        },
    ));
}

test "makeUpgradeResponse propagates header buffer sizing errors" {
    const Header = struct {
        name: []const u8,
        value: []const u8,
    };
    const Res = struct {
        status: std.http.Status = .ok,
        headers: []const Header = &.{},
        body: []const u8 = "",
        close: bool = false,
    };
    var headers: [3]Header = undefined;

    try std.testing.expectError(error.HeaderBufferTooSmall, makeUpgradeResponse(
        Res,
        Header,
        headers[0..],
        .{
            .accept_key = ("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=").*,
            .selected_subprotocol = "chat",
            .selected_extensions = null,
            .permessage_deflate = null,
            .extra_headers = &.{},
        },
    ));
}

test "adaptZhttpRunner catches runner errors and sends close 1011" {
    const Runner = struct {
        pub fn run(_: std.Io, _: std.mem.Allocator, _: std.Io.net.Stream) !void {
            return error.TestRunnerFailure;
        }
    };
    const Wrapped = adaptZhttpRunner(Runner, .{});

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const pair = try openLoopbackPair(io);
    defer pair.client.close(io);
    defer pair.server.close(io);

    Wrapped.run(io, std.testing.allocator, pair.server);
    try expectClientClose(io, pair.client, @intFromEnum(proto.CloseCode.internal_error), "");
}

test "adaptZhttpRunner forwards data runners and data hooks" {
    const Runner = struct {
        pub const Data = struct {
            value: u8 = 0,
        };

        var deinit_value: ?u8 = null;

        pub fn initData() Data {
            return .{ .value = 7 };
        }

        pub fn deinitData(_: std.mem.Allocator, data: *const Data) void {
            deinit_value = data.value;
        }

        pub fn run(io: std.Io, _: std.mem.Allocator, stream: std.Io.net.Stream, data: *const Data) !void {
            var owned_stream = stream;
            var read_buf: [64]u8 = undefined;
            var write_buf: [128]u8 = undefined;
            var reader = owned_stream.reader(io, &read_buf);
            var writer = owned_stream.writer(io, &write_buf);
            var ws = ServerConn.init(&reader.interface, &writer.interface, .{});
            var msg: [8]u8 = undefined;
            const text = try std.fmt.bufPrint(msg[0..], "{d}", .{data.value});
            try ws.writeText(text);
            try ws.flush();
        }
    };
    const Wrapped = adaptZhttpRunner(Runner, .{});

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const pair = try openLoopbackPair(io);
    defer pair.client.close(io);
    defer pair.server.close(io);

    var data = Wrapped.initData();

    try std.testing.expectEqual(@as(u8, 0), Runner.deinit_value orelse 0);
    Wrapped.run(io, std.testing.allocator, pair.server, &data);
    try expectClientText(io, pair.client, "7");
    comptime {
        if (Wrapped.Data != Runner.Data) @compileError("adapter must preserve Data type");
    }
    Wrapped.deinitData(std.testing.allocator, &data);
    try std.testing.expectEqual(@as(?u8, 7), Runner.deinit_value);
}

test "adaptZhttpRunner forwards ctx runners" {
    const Ctx = struct {
        value: []const u8,
    };
    const Runner = struct {
        pub fn run(ctx: *Ctx, io: std.Io, _: std.mem.Allocator, stream: std.Io.net.Stream) !void {
            var owned_stream = stream;
            var read_buf: [64]u8 = undefined;
            var write_buf: [128]u8 = undefined;
            var reader = owned_stream.reader(io, &read_buf);
            var writer = owned_stream.writer(io, &write_buf);
            var ws = ServerConn.init(&reader.interface, &writer.interface, .{});
            try ws.writeText(ctx.value);
            try ws.flush();
        }
    };
    const Wrapped = adaptZhttpRunner(Runner, .{});

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const pair = try openLoopbackPair(io);
    defer pair.client.close(io);
    defer pair.server.close(io);

    var ctx: Ctx = .{ .value = "ctx" };
    Wrapped.run(&ctx, io, std.testing.allocator, pair.server);
    try expectClientText(io, pair.client, "ctx");
}

test "adaptZhttpRunner forwards ctx plus data runners" {
    const Ctx = struct {
        prefix: []const u8,
    };
    const Runner = struct {
        pub const Data = struct {
            suffix: []const u8 = "",
        };

        pub fn initData() Data {
            return .{ .suffix = "tail" };
        }

        pub fn run(ctx: *Ctx, io: std.Io, _: std.mem.Allocator, stream: std.Io.net.Stream, data: *const Data) !void {
            var owned_stream = stream;
            var read_buf: [64]u8 = undefined;
            var write_buf: [128]u8 = undefined;
            var reader = owned_stream.reader(io, &read_buf);
            var writer = owned_stream.writer(io, &write_buf);
            var ws = ServerConn.init(&reader.interface, &writer.interface, .{});
            var msg: [32]u8 = undefined;
            const text = try std.fmt.bufPrint(msg[0..], "{s}-{s}", .{ ctx.prefix, data.suffix });
            try ws.writeText(text);
            try ws.flush();
        }
    };
    const Wrapped = adaptZhttpRunner(Runner, .{});

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const pair = try openLoopbackPair(io);
    defer pair.client.close(io);
    defer pair.server.close(io);

    var ctx: Ctx = .{ .prefix = "head" };
    var data = Wrapped.initData();
    Wrapped.run(&ctx, io, std.testing.allocator, pair.server, &data);
    try expectClientText(io, pair.client, "head-tail");
}

test "adaptZhttpRunner supports void-return runners" {
    const Runner = struct {
        var seen = false;

        pub fn run(_: std.Io, _: std.mem.Allocator, _: std.Io.net.Stream) void {
            seen = true;
        }
    };
    const Wrapped = adaptZhttpRunner(Runner, .{});

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const pair = try openLoopbackPair(io);
    defer pair.client.close(io);
    defer pair.server.close(io);

    Wrapped.run(io, std.testing.allocator, pair.server);
    try std.testing.expect(Runner.seen);
}
