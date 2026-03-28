const std = @import("std");
const zws = @import("zwebsocket");
const common = @import("zws_support_common");

const Io = common.Io;

const Config = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 9001,
    path: []const u8 = "/",
    compression: bool = false,
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
        try zws.parsePerMessageDeflate(header)
    else
        null;
    const conn_cfg: zws.Config = .{
        .permessage_deflate = if (negotiated_permessage_deflate) |pmd|
            .{
                .allocator = init.gpa,
                .negotiated = pmd,
                .compress_outgoing = true,
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
