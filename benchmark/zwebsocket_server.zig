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
        \\  zwebsocket-bench-server [--port=9001] [--pipeline=1] [--msg-size=16]
        \\
    , .{});
}

fn flushIfBuffered(w: *Io.Writer) Io.Writer.Error!void {
    if (w.buffered().len != 0) try w.flush();
}

fn responseFrameLen(payload_len: usize) usize {
    const header_len: usize = if (payload_len <= 125)
        2
    else if (payload_len <= std.math.maxInt(u16))
        4
    else
        10;
    return header_len + payload_len;
}

fn handleConn(io: Io, stream: std.Io.net.Stream, pipeline: usize, msg_size: usize) Io.Cancelable!void {
    defer stream.close(io);
    common.setTcpNoDelay(&stream);

    const write_buf_len: usize = if (pipeline > 1)
        @min(@max(responseFrameLen(msg_size) * pipeline, @as(usize, 64)), @as(usize, 16 * 1024))
    else
        64;
    const flush_every: usize = if (pipeline > 1) pipeline else 1;

    const read_buf_len: usize = if (pipeline > 1) 4 * 1024 else 512;
    var read_storage: [4 * 1024]u8 = undefined;
    var write_storage: [16 * 1024]u8 = undefined;

    var sr = stream.reader(io, read_storage[0..read_buf_len]);
    var sw = stream.writer(io, write_storage[0..write_buf_len]);

    const req = common.parseHandshakeRequest(&sr.interface) catch return;
    _ = zws.serverHandshake(&sw.interface, req, .{}) catch return;
    sw.interface.flush() catch return;

    var conn = BenchConn.init(&sr.interface, &sw.interface, .{});

    var payload_buf: [64 * 1024]u8 = undefined;
    var buffered_frames: usize = 0;
    while (true) {
        const echoed = conn.echoFrame(payload_buf[0..]) catch |err| switch (err) {
            error.EndOfStream => return,
            else => return,
        };
        if (echoed.opcode == .close) {
            sw.interface.flush() catch {};
            return;
        }
        buffered_frames += 1;
        if (buffered_frames >= flush_every or sr.interface.buffered().len == 0) {
            flushIfBuffered(&sw.interface) catch return;
            buffered_frames = 0;
        }
    }
}

pub fn main(init: std.process.Init) !void {
    var port: u16 = 9001;
    var pipeline: usize = 1;
    var msg_size: usize = 16;

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
            } else if (std.mem.eql(u8, kv.key, "pipeline")) {
                pipeline = try std.fmt.parseInt(usize, kv.val, 10);
            } else if (std.mem.eql(u8, kv.key, "msg-size")) {
                msg_size = try std.fmt.parseInt(usize, kv.val, 10);
            } else {
                return error.UnknownArg;
            }
            continue;
        }
        return error.UnknownArg;
    }
    if (pipeline == 0) return error.InvalidPipeline;

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
        group.concurrent(init.io, handleConn, .{ init.io, stream, pipeline, msg_size }) catch {
            stream.close(init.io);
        };
    }
}
