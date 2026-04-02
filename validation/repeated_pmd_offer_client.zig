const std = @import("std");
const zws = @import("zws");
const common = @import("zws_support_common");

const Config = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 9100,
};

pub fn main(init: std.process.Init) !void {
    var cfg: Config = .{};

    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer it.deinit();
    _ = it.next();

    while (it.next()) |arg_z| {
        const arg: []const u8 = arg_z;
        if (common.parseKeyVal(arg)) |kv| {
            if (std.mem.eql(u8, kv.key, "host")) {
                cfg.host = kv.val;
            } else if (std.mem.eql(u8, kv.key, "port")) {
                cfg.port = try std.fmt.parseInt(u16, kv.val, 10);
            } else {
                return error.UnknownArg;
            }
            continue;
        }
        return error.UnknownArg;
    }

    const addr: std.Io.net.IpAddress = .{ .ip4 = try std.Io.net.Ip4Address.parse(cfg.host, cfg.port) };
    var stream = try std.Io.net.IpAddress.connect(&addr, init.io, .{ .mode = .stream });
    defer stream.close(init.io);
    common.setTcpNoDelay(&stream);

    var read_buf: [64 * 1024]u8 = undefined;
    var write_buf: [16 * 1024]u8 = undefined;
    var sr = stream.reader(init.io, &read_buf);
    var sw = stream.writer(init.io, &write_buf);

    const request = try std.fmt.allocPrint(
        init.gpa,
        "GET / HTTP/1.1\r\n" ++
            "Host: {s}:{d}\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
            "Sec-WebSocket-Version: 13\r\n" ++
            "Sec-WebSocket-Extensions: permessage-deflate, permessage-deflate; client_no_context_takeover\r\n" ++
            "\r\n",
        .{ cfg.host, cfg.port },
    );
    defer init.gpa.free(request);

    const reply = try common.performClientHandshake(&sr.interface, &sw.interface, request);
    const selected_extensions = reply.selected_extensions orelse return error.BadHandshake;
    if (!std.mem.eql(
        u8,
        "permessage-deflate; server_no_context_takeover; client_no_context_takeover",
        selected_extensions,
    )) return error.BadHandshake;

    const negotiated = (try zws.Extensions.parsePerMessageDeflateFirst(selected_extensions)) orelse return error.BadHandshake;
    var conn = zws.Conn.Client.init(&sr.interface, &sw.interface, .{
        .permessage_deflate = .{
            .allocator = init.gpa,
            .negotiated = negotiated,
            .compress_outgoing = true,
        },
    });

    try conn.writeText("repeat-offer-ok");
    try sw.interface.flush();

    var message_buf: [256]u8 = undefined;
    const echoed = try conn.readMessage(message_buf[0..]);
    if (echoed.opcode != .text) return error.UnexpectedOpcode;
    if (!std.mem.eql(u8, "repeat-offer-ok", echoed.payload)) return error.BadEcho;

    try conn.writeClose(1000, "");
    try sw.interface.flush();
    _ = conn.readMessage(message_buf[0..]) catch {};
}
