const std = @import("std");
const zws = @import("zwebsocket");
const builtin = @import("builtin");

const Io = std.Io;
const BenchConn = zws.ConnType(.{
    .role = .server,
    .auto_pong = false,
    .auto_reply_close = false,
    .validate_utf8 = false,
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

fn parseKeyVal(arg: []const u8) ?struct { key: []const u8, val: []const u8 } {
    if (!std.mem.startsWith(u8, arg, "--")) return null;
    const eq = std.mem.indexOfScalar(u8, arg, '=') orelse return null;
    return .{ .key = arg[2..eq], .val = arg[eq + 1 ..] };
}

fn trimCR(line: []const u8) []const u8 {
    if (line.len != 0 and line[line.len - 1] == '\r') return line[0 .. line.len - 1];
    return line;
}

fn trimSpaces(s: []const u8) []const u8 {
    var a: usize = 0;
    var b: usize = s.len;
    while (a < b and (s[a] == ' ' or s[a] == '\t')) a += 1;
    while (b > a and (s[b - 1] == ' ' or s[b - 1] == '\t')) b -= 1;
    return s[a..b];
}

fn assignHandshakeHeader(req: *zws.ServerHandshakeRequest, name: []const u8, value: []const u8) void {
    if (std.ascii.eqlIgnoreCase(name, "connection")) {
        req.connection = value;
    } else if (std.ascii.eqlIgnoreCase(name, "upgrade")) {
        req.upgrade = value;
    } else if (std.ascii.eqlIgnoreCase(name, "sec-websocket-key")) {
        req.sec_websocket_key = value;
    } else if (std.ascii.eqlIgnoreCase(name, "sec-websocket-version")) {
        req.sec_websocket_version = value;
    } else if (std.ascii.eqlIgnoreCase(name, "sec-websocket-protocol")) {
        req.sec_websocket_protocol = value;
    } else if (std.ascii.eqlIgnoreCase(name, "sec-websocket-extensions")) {
        req.sec_websocket_extensions = value;
    } else if (std.ascii.eqlIgnoreCase(name, "origin")) {
        req.origin = value;
    } else if (std.ascii.eqlIgnoreCase(name, "host")) {
        req.host = value;
    }
}

fn flushIfBuffered(w: *Io.Writer) Io.Writer.Error!void {
    if (w.buffered().len != 0) try w.flush();
}

fn setTcpNoDelay(stream: *const std.Io.net.Stream) void {
    if (builtin.os.tag != .linux) return;
    const linux = std.os.linux;
    var one: i32 = 1;
    std.posix.setsockopt(
        stream.socket.handle,
        @intCast(linux.IPPROTO.TCP),
        linux.TCP.NODELAY,
        std.mem.asBytes(&one),
    ) catch {};
}

fn parseHandshakeRequest(r: *Io.Reader) !zws.ServerHandshakeRequest {
    const line0_incl = try r.takeDelimiterInclusive('\n');
    const line0 = line0_incl[0 .. line0_incl.len - 1];
    const request_line = trimCR(line0);

    const sp1 = std.mem.indexOfScalar(u8, request_line, ' ') orelse return error.BadRequest;
    const sp2_rel = std.mem.indexOfScalar(u8, request_line[sp1 + 1 ..], ' ') orelse return error.BadRequest;
    const sp2 = sp1 + 1 + sp2_rel;

    var req: zws.ServerHandshakeRequest = .{
        .method = request_line[0..sp1],
        .is_http_11 = std.mem.eql(u8, request_line[sp2 + 1 ..], "HTTP/1.1"),
    };

    while (true) {
        const line_incl = try r.takeDelimiterInclusive('\n');
        const line = trimCR(line_incl[0 .. line_incl.len - 1]);
        if (line.len == 0) break;

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.BadRequest;
        const name = line[0..colon];
        const value = trimSpaces(line[colon + 1 ..]);

        assignHandshakeHeader(&req, name, value);
    }

    return req;
}

fn handleConn(io: Io, stream: std.Io.net.Stream) Io.Cancelable!void {
    defer stream.close(io);
    setTcpNoDelay(&stream);

    var read_buf: [4 * 1024]u8 = undefined;
    var write_buf: [64]u8 = undefined;

    var sr = stream.reader(io, &read_buf);
    var sw = stream.writer(io, &write_buf);

    const req = parseHandshakeRequest(&sr.interface) catch return;
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
        if (parseKeyVal(arg)) |kv| {
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
