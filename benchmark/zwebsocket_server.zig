const std = @import("std");
const zws = @import("zwebsocket");
const common = @import("zws_support_common");

const Io = std.Io;
const BenchConn = zws.ConnType(.{
    .role = .server,
    .auto_pong = false,
    .auto_reply_close = false,
    .validate_utf8 = false,
    .runtime_hooks = false,
});

fn usage() void {
    std.debug.print(
        \\zwebsocket-bench-server
        \\
        \\Usage:
        \\  zwebsocket-bench-server [--port=9001]
        \\
    , .{});
}

fn flushIfBuffered(w: *Io.Writer) Io.Writer.Error!void {
    if (w.buffered().len != 0) try w.flush();
}

fn handleConn(io: Io, stream: std.Io.net.Stream) Io.Cancelable!void {
    defer stream.close(io);
    common.setTcpNoDelay(&stream);

    var read_buf: [4 * 1024]u8 = undefined;
    var write_buf: [64]u8 = undefined;

    var sr = stream.reader(io, &read_buf);
    var sw = stream.writer(io, &write_buf);

    const req = common.parseHandshakeRequest(&sr.interface) catch return;
    _ = zws.serverHandshake(&sw.interface, req, .{}) catch return;
    sw.interface.flush() catch return;

    var conn = BenchConn.init(&sr.interface, &sw.interface, .{});

    var payload_buf: [64 * 1024]u8 = undefined;
    while (true) {
        const echoed = conn.echoFrame(payload_buf[0..]) catch |err| switch (err) {
            error.EndOfStream => return,
            else => return,
        };
        if (echoed.opcode == .close) {
            sw.interface.flush() catch {};
            return;
        }
        flushIfBuffered(&sw.interface) catch return;
    }
}

pub fn main(init: std.process.Init) !void {
    var port: u16 = 9001;

    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer it.deinit();
    _ = it.next();

    while (it.next()) |arg_z| {
        const arg: []const u8 = arg_z;
        if (std.mem.eql(u8, arg, "--help")) {
            usage();
            return;
        }
        if (common.parseKeyVal(arg)) |kv| {
            if (std.mem.eql(u8, kv.key, "port")) {
                port = try std.fmt.parseInt(u16, kv.val, 10);
            } else {
                return error.UnknownArg;
            }
            continue;
        }
        return error.UnknownArg;
    }

    const addr: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(port) };
    var listener = try std.Io.net.IpAddress.listen(&addr, init.io, .{ .reuse_address = true });
    defer listener.deinit(init.io);

    var group: Io.Group = .init;
    defer group.cancel(init.io);

    while (true) {
        const stream = listener.accept(init.io) catch |err| switch (err) {
            error.SocketNotListening => return,
            error.Canceled => return,
            else => return,
        };
        group.concurrent(init.io, handleConn, .{ init.io, stream }) catch {
            stream.close(init.io);
        };
    }
}
