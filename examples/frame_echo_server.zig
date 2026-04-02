const std = @import("std");
const zws = @import("zws");
const common = @import("zws_support_common");

const Io = common.Io;

const Config = struct {
    port: u16 = 9002,
    max_frame_payload_len: u64 = 128 * 1024,
};

fn usage(io: Io) !void {
    var buf: [640]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buf);
    try stdout.interface.writeAll(
        \\zws-frame-echo-server
        \\
        \\Usage:
        \\  zig build examples -Dexample=frame-echo-server -- [options]
        \\
        \\Options:
        \\  --port=9002
        \\  --max-frame=131072
        \\  --help
        \\
        \\This example stays on the frame API and echoes frames directly instead of
        \\reassembling full messages with `readMessage(...)`.
        \\
    );
    try stdout.interface.flush();
}

fn echoOne(conn: anytype, scratch: []u8) !bool {
    if (try conn.readFrameBorrowed()) |frame| {
        switch (frame.header.opcode) {
            .ping => try conn.writePong(frame.payload),
            .pong => {},
            .close => {
                const parsed = try zws.Conn.parseClosePayload(frame.payload, true);
                conn.writeClose(parsed.code, parsed.reason) catch |err| switch (err) {
                    error.ConnectionClosed => {},
                    else => return err,
                };
                return true;
            },
            else => try conn.writeFrame(frame.header.opcode, frame.payload, frame.header.fin, frame.header.compressed),
        }
        return false;
    }

    const frame = try conn.readFrame(scratch);
    switch (frame.header.opcode) {
        .ping => try conn.writePong(frame.payload),
        .pong => {},
        .close => {
            const parsed = try zws.Conn.parseClosePayload(frame.payload, true);
            conn.writeClose(parsed.code, parsed.reason) catch |err| switch (err) {
                error.ConnectionClosed => {},
                else => return err,
            };
            return true;
        },
        else => try conn.writeFrame(frame.header.opcode, frame.payload, frame.header.fin, frame.header.compressed),
    }
    return false;
}

fn handleConn(io: Io, stream: std.Io.net.Stream, cfg: Config) Io.Cancelable!void {
    defer stream.close(io);
    common.setTcpNoDelay(&stream);

    var read_buf: [64 * 1024]u8 = undefined;
    var write_buf: [16 * 1024]u8 = undefined;
    var scratch: [128 * 1024]u8 = undefined;

    var sr = stream.reader(io, &read_buf);
    var sw = stream.writer(io, &write_buf);

    const negotiated_permessage_deflate = zws.Handshake.upgrade(&sr.interface, &sw.interface) catch return;
    sw.interface.flush() catch return;

    var conn = zws.Conn.Server.init(&sr.interface, &sw.interface, .{
        .max_frame_payload_len = cfg.max_frame_payload_len,
        .permessage_deflate = if (negotiated_permessage_deflate) |pmd|
            .{
                .allocator = std.heap.smp_allocator,
                .negotiated = pmd,
                .compress_outgoing = true,
            }
        else
            null,
    });

    while (true) {
        const closed = echoOne(&conn, scratch[0..]) catch |err| switch (err) {
            error.EndOfStream, error.ConnectionClosed => return,
            else => {
                common.closeForProtocolError(&conn, &sw.interface, err);
                return;
            },
        };
        if (closed) return;
        sw.interface.flush() catch return;
    }
}

pub fn main(init: std.process.Init) !void {
    var cfg: Config = .{};

    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer it.deinit();
    _ = it.next();

    while (it.next()) |arg_z| {
        const arg: []const u8 = arg_z;
        if (std.mem.eql(u8, arg, "--help")) {
            try usage(init.io);
            return;
        }
        if (std.mem.eql(u8, arg, "--compression")) {
            continue;
        }
        if (common.parseKeyVal(arg)) |kv| {
            if (std.mem.eql(u8, kv.key, "port")) {
                cfg.port = try std.fmt.parseInt(u16, kv.val, 10);
            } else if (std.mem.eql(u8, kv.key, "max-frame")) {
                cfg.max_frame_payload_len = try std.fmt.parseInt(u64, kv.val, 10);
            } else {
                return error.UnknownArg;
            }
            continue;
        }
        return error.UnknownArg;
    }

    const addr: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(cfg.port) };
    var listener = try std.Io.net.IpAddress.listen(&addr, init.io, .{ .reuse_address = true });
    defer listener.deinit(init.io);

    var group: Io.Group = .init;
    defer group.cancel(init.io);

    while (true) {
        const stream = listener.accept(init.io) catch |err| switch (err) {
            error.SocketNotListening, error.Canceled => return,
            else => return,
        };
        group.concurrent(init.io, handleConn, .{ init.io, stream, cfg }) catch {
            stream.close(init.io);
        };
    }
}
