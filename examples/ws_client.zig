const std = @import("std");
const zws = @import("zwebsocket");
const common = @import("zws_support_common");

const Io = common.Io;

const Config = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 9001,
    path: []const u8 = "/",
    compression: bool = false,
    message: []const u8 = "hello from zwebsocket",
};

fn usage() void {
    std.debug.print(
        \\zwebsocket-client
        \\
        \\Usage:
        \\  zig build example-client -- [options]
        \\
        \\Options:
        \\  --host=127.0.0.1
        \\  --port=9001
        \\  --path=/
        \\  --message=hello
        \\  --compression
        \\  --help
        \\
        \\This example performs the HTTP websocket client handshake manually and
        \\then switches to `zws.ClientConn` for frame/message I/O.
        \\
    , .{});
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
        if (common.parseKeyVal(arg)) |kv| {
            if (std.mem.eql(u8, kv.key, "host")) {
                cfg.host = kv.val;
            } else if (std.mem.eql(u8, kv.key, "port")) {
                cfg.port = try std.fmt.parseInt(u16, kv.val, 10);
            } else if (std.mem.eql(u8, kv.key, "path")) {
                cfg.path = kv.val;
            } else if (std.mem.eql(u8, kv.key, "message")) {
                cfg.message = kv.val;
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

    const request = try common.buildClientHandshakeRequest(init.gpa, cfg.host, cfg.path, cfg.compression);
    defer init.gpa.free(request);
    const reply = try common.performClientHandshake(&sr.interface, &sw.interface, request);

    const negotiated_permessage_deflate = if (reply.selected_extensions) |header|
        try zws.parsePerMessageDeflateFirst(header)
    else
        null;
    var conn = zws.ClientConn.init(&sr.interface, &sw.interface, .{
        .permessage_deflate = if (negotiated_permessage_deflate) |pmd|
            .{
                .allocator = init.gpa,
                .negotiated = pmd,
                .compress_outgoing = true,
            }
        else
            null,
    });

    try conn.writeText(cfg.message);
    try sw.interface.flush();

    var message_buf: [128 * 1024]u8 = undefined;
    const echoed = try conn.readMessage(message_buf[0..]);
    if (echoed.opcode != .text) return error.UnexpectedOpcode;
    std.debug.print("echoed text: {s}\n", .{echoed.payload});

    try conn.writePing("demo");
    try sw.interface.flush();
    const pong = try conn.readFrame(message_buf[0..]);
    if (pong.header.opcode != .pong) return error.UnexpectedOpcode;
    std.debug.print("pong payload: {s}\n", .{pong.payload});

    try conn.writeClose(1000, "done");
    try sw.interface.flush();
    _ = conn.readMessage(message_buf[0..]) catch {};
}
