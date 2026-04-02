const std = @import("std");
const zws = @import("zwebsocket");
const common = @import("zws_support_common");

const Io = std.Io;

const Mode = enum {
    sync,
    async,
};

const BenchConnSync = zws.Conn.Type(.{
    .role = .server,
    .auto_pong = true,
    .auto_reply_close = true,
    .validate_utf8 = false,
    .runtime_hooks = false,
    .supports_permessage_deflate = false,
});

const BenchConnSyncDeadline = zws.Conn.Type(.{
    .role = .server,
    .auto_pong = true,
    .auto_reply_close = true,
    .validate_utf8 = false,
    .runtime_hooks = true,
    .supports_permessage_deflate = false,
});

const BenchConnAsync = BenchConnSync;
const BenchConnAsyncDeadline = BenchConnSyncDeadline;

const handler_sync_opts: zws.Handler.Options = .{
    .execution = .sequential,
    .auto_flush = true,
    .close_on_handler_error = true,
    .message_buffer_len = 64 * 1024,
    .stage_buffer_len = 64 * 1024,
};

const handler_async_opts: zws.Handler.Options = .{
    .execution = .async,
    .auto_flush = true,
    .close_on_handler_error = true,
    .async_max_inflight = 16,
    .message_buffer_len = 64 * 1024,
    .stage_buffer_len = 64 * 1024,
};

const Config = struct {
    port: u16 = 9001,
    pipeline: usize = 1,
    msg_size: usize = 16,
    deadline_ms: usize = 0,
    mode: Mode = .sync,
};

fn usage(io: Io) !void {
    var buf: [384]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buf);
    try stdout.interface.writeAll(
        \\zwebsocket-bench-server
        \\
        \\Usage:
        \\  zwebsocket-bench-server [--port=9001] [--pipeline=1] [--msg-size=16] [--mode=sync|async] [--deadline-ms=0]
        \\
    );
    try stdout.interface.flush();
}

fn timeoutsFromDeadlineMs(deadline_ms: usize) zws.Observe.TimeoutConfig {
    if (deadline_ms == 0) return .{};
    const budget_ns = std.math.mul(u64, @as(u64, @intCast(deadline_ms)), std.time.ns_per_ms) catch std.math.maxInt(u64);
    return .{
        .read_ns = budget_ns,
        .write_ns = budget_ns,
        .flush_ns = budget_ns,
    };
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

fn connConfig(cfg: Config) zws.Conn.Config {
    return .{
        .timeouts = timeoutsFromDeadlineMs(cfg.deadline_ms),
    };
}

fn EchoHandler(comptime handler_opts: zws.Handler.Options, comptime ConnType: type) type {
    return struct {
        fn handle(ctx: *zws.Handler.SliceContext(handler_opts, ConnType, u8)) struct {
            opcode: zws.Protocol.MessageOpcode,
            body: []const u8,
        } {
            return .{
                .opcode = ctx.message.opcode,
                .body = ctx.message.payload,
            };
        }
    };
}

fn handleConnWithHandler(
    comptime ConnType: type,
    comptime handler_opts: zws.Handler.Options,
    io: Io,
    stream: std.Io.net.Stream,
    cfg: Config,
) Io.Cancelable!void {
    defer stream.close(io);
    common.setTcpNoDelay(&stream);

    const read_buf_len: usize = if (cfg.pipeline > 1) 4 * 1024 else 256;
    const write_buf_len: usize = if (handler_opts.execution == .async)
        0
    else if (cfg.pipeline > 1)
        @min(@max(responseFrameLen(cfg.msg_size) * cfg.pipeline, @as(usize, 64)), @as(usize, 16 * 1024))
    else
        64;

    var read_storage: [4 * 1024]u8 = undefined;
    var write_storage: [16 * 1024]u8 = undefined;

    var sr = stream.reader(io, read_storage[0..read_buf_len]);
    var sw = stream.writer(io, write_storage[0..write_buf_len]);

    _ = zws.Handshake.upgrade(&sr.interface, &sw.interface) catch return;
    sw.interface.flush() catch return;

    var conn = ConnType.init(&sr.interface, &sw.interface, connConfig(cfg));
    var scratch = zws.Handler.Scratch(handler_opts).init();
    var state: u8 = 0;

    zws.Handler.run(handler_opts, io, &conn, &state, &scratch, EchoHandler(handler_opts, ConnType).handle) catch |err| switch (err) {
        error.EndOfStream, error.ConnectionClosed => return,
        else => {
            common.closeForProtocolError(&conn, &sw.interface, err);
            return;
        },
    };
}

fn handleConnSync(io: Io, stream: std.Io.net.Stream, cfg: Config) Io.Cancelable!void {
    return handleConnWithHandler(BenchConnSync, handler_sync_opts, io, stream, cfg);
}

fn handleConnSyncDeadline(io: Io, stream: std.Io.net.Stream, cfg: Config) Io.Cancelable!void {
    return handleConnWithHandler(BenchConnSyncDeadline, handler_sync_opts, io, stream, cfg);
}

fn handleConnAsync(io: Io, stream: std.Io.net.Stream, cfg: Config) Io.Cancelable!void {
    return handleConnWithHandler(BenchConnAsync, handler_async_opts, io, stream, cfg);
}

fn handleConnAsyncDeadline(io: Io, stream: std.Io.net.Stream, cfg: Config) Io.Cancelable!void {
    return handleConnWithHandler(BenchConnAsyncDeadline, handler_async_opts, io, stream, cfg);
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
        if (common.parseKeyVal(arg)) |kv| {
            if (std.mem.eql(u8, kv.key, "port")) {
                cfg.port = try std.fmt.parseInt(u16, kv.val, 10);
            } else if (std.mem.eql(u8, kv.key, "pipeline")) {
                cfg.pipeline = try std.fmt.parseInt(usize, kv.val, 10);
            } else if (std.mem.eql(u8, kv.key, "msg-size")) {
                cfg.msg_size = try std.fmt.parseInt(usize, kv.val, 10);
            } else if (std.mem.eql(u8, kv.key, "deadline-ms")) {
                cfg.deadline_ms = try std.fmt.parseInt(usize, kv.val, 10);
            } else if (std.mem.eql(u8, kv.key, "mode")) {
                cfg.mode = std.meta.stringToEnum(Mode, kv.val) orelse return error.UnknownArg;
            } else {
                return error.UnknownArg;
            }
            continue;
        }
        return error.UnknownArg;
    }
    if (cfg.pipeline == 0) return error.InvalidPipeline;

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
        switch (cfg.mode) {
            .sync => {
                if (cfg.deadline_ms == 0) {
                    group.concurrent(init.io, handleConnSync, .{ init.io, stream, cfg }) catch {
                        stream.close(init.io);
                    };
                } else {
                    group.concurrent(init.io, handleConnSyncDeadline, .{ init.io, stream, cfg }) catch {
                        stream.close(init.io);
                    };
                }
            },
            .async => {
                if (cfg.deadline_ms == 0) {
                    group.concurrent(init.io, handleConnAsync, .{ init.io, stream, cfg }) catch {
                        stream.close(init.io);
                    };
                } else {
                    group.concurrent(init.io, handleConnAsyncDeadline, .{ init.io, stream, cfg }) catch {
                        stream.close(init.io);
                    };
                }
            },
        }
    }
}
