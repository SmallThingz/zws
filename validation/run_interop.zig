const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;

const Args = struct {
    server_bin: []const u8,
    client_bin: []const u8,
    repeated_client_bin: []const u8,
    port_base: u16 = 9100,
};

const node_peer_code =
    \\const process = require('node:process');
    \\const { WebSocket, WebSocketServer } = require('ws');
    \\
    \\function parseArgs(argv) {
    \\  const args = {
    \\    mode: null,
    \\    port: 9100,
    \\    url: 'ws://127.0.0.1:9100/',
    \\    compression: false,
    \\  };
    \\  for (const arg of argv) {
    \\    if (arg === 'server' || arg === 'client') {
    \\      args.mode = arg;
    \\    } else if (arg === '--compression') {
    \\      args.compression = true;
    \\    } else if (arg.startsWith('--port=')) {
    \\      args.port = Number(arg.slice('--port='.length));
    \\    } else if (arg.startsWith('--url=')) {
    \\      args.url = arg.slice('--url='.length);
    \\    } else {
    \\      throw new Error(`unknown arg: ${arg}`);
    \\    }
    \\  }
    \\  if (!args.mode) throw new Error('missing mode');
    \\  return args;
    \\}
    \\
    \\function waitForEvent(target, event) {
    \\  return new Promise((resolve, reject) => {
    \\    const onEvent = (...values) => { cleanup(); resolve(values); };
    \\    const onError = (err) => { cleanup(); reject(err); };
    \\    const cleanup = () => {
    \\      target.off(event, onEvent);
    \\      target.off('error', onError);
    \\    };
    \\    target.once(event, onEvent);
    \\    target.once('error', onError);
    \\  });
    \\}
    \\
    \\async function runClient(args) {
    \\  const ws = new WebSocket(args.url, { perMessageDeflate: args.compression });
    \\  await waitForEvent(ws, 'open');
    \\
    \\  const textPayload = 'zwebsocket interop text payload with enough repetition to exercise permessage-deflate';
    \\  ws.send(textPayload);
    \\  {
    \\    const [data, isBinary] = await waitForEvent(ws, 'message');
    \\    if (isBinary || data.toString() !== textPayload) throw new Error('text echo mismatch');
    \\  }
    \\
    \\  const binaryPayload = Buffer.alloc(256);
    \\  for (let i = 0; i < binaryPayload.length; i += 1) binaryPayload[i] = (i * 13 + 7) & 0xff;
    \\  ws.send(binaryPayload, { binary: true });
    \\  {
    \\    const [data, isBinary] = await waitForEvent(ws, 'message');
    \\    const received = Buffer.isBuffer(data) ? data : Buffer.from(data);
    \\    if (!isBinary || !received.equals(binaryPayload)) throw new Error('binary echo mismatch');
    \\  }
    \\
    \\  ws.close(1000);
    \\  await waitForEvent(ws, 'close');
    \\}
    \\
    \\function runServer(args) {
    \\  const server = new WebSocketServer({
    \\    port: args.port,
    \\    perMessageDeflate: args.compression,
    \\  });
    \\  server.on('connection', (ws) => {
    \\    ws.on('message', (data, isBinary) => {
    \\      ws.send(data, { binary: isBinary });
    \\    });
    \\  });
    \\}
    \\
    \\const args = parseArgs(process.argv.slice(1));
    \\if (args.mode === 'server') {
    \\  runServer(args);
    \\} else {
    \\  runClient(args).catch((err) => {
    \\    console.error(err.stack || String(err));
    \\    process.exit(1);
    \\  });
    \\}
;

const aiohttp_peer_code =
    \\import argparse
    \\import asyncio
    \\import aiohttp
    \\from aiohttp import web, WSMsgType
    \\
    \\TEXT_PAYLOAD = "zwebsocket interop text payload with enough repetition to exercise permessage-deflate"
    \\BINARY_PAYLOAD = bytes(((i * 13 + 7) & 0xFF) for i in range(256))
    \\
    \\async def run_client(url: str, compression: bool) -> None:
    \\    compress = 15 if compression else 0
    \\    timeout = aiohttp.ClientTimeout(total=None)
    \\    async with aiohttp.ClientSession(timeout=timeout) as session:
    \\        async with session.ws_connect(url, compress=compress, max_msg_size=4 * 1024 * 1024) as ws:
    \\            await ws.send_str(TEXT_PAYLOAD)
    \\            msg = await ws.receive()
    \\            if msg.type is not WSMsgType.TEXT or msg.data != TEXT_PAYLOAD:
    \\                raise RuntimeError("text echo mismatch")
    \\
    \\            await ws.send_bytes(BINARY_PAYLOAD)
    \\            msg = await ws.receive()
    \\            if msg.type is not WSMsgType.BINARY or bytes(msg.data) != BINARY_PAYLOAD:
    \\                raise RuntimeError("binary echo mismatch")
    \\
    \\            await ws.close()
    \\
    \\async def echo_handler(request: web.Request) -> web.WebSocketResponse:
    \\    compression = request.app["compression"]
    \\    ws = web.WebSocketResponse(compress=compression, max_msg_size=4 * 1024 * 1024)
    \\    await ws.prepare(request)
    \\
    \\    async for msg in ws:
    \\        if msg.type is WSMsgType.TEXT:
    \\            await ws.send_str(msg.data)
    \\        elif msg.type is WSMsgType.BINARY:
    \\            await ws.send_bytes(msg.data)
    \\        elif msg.type in (WSMsgType.CLOSE, WSMsgType.CLOSING, WSMsgType.CLOSED):
    \\            break
    \\        elif msg.type is WSMsgType.ERROR:
    \\            raise ws.exception() or RuntimeError("websocket error")
    \\    return ws
    \\
    \\async def run_server(port: int, compression: bool) -> None:
    \\    app = web.Application()
    \\    app["compression"] = compression
    \\    app.router.add_get("/", echo_handler)
    \\
    \\    runner = web.AppRunner(app)
    \\    await runner.setup()
    \\    site = web.TCPSite(runner, "127.0.0.1", port)
    \\    await site.start()
    \\    await asyncio.Future()
    \\
    \\def parse_args() -> argparse.Namespace:
    \\    parser = argparse.ArgumentParser()
    \\    sub = parser.add_subparsers(dest="mode", required=True)
    \\
    \\    server = sub.add_parser("server")
    \\    server.add_argument("--port", type=int, default=9100)
    \\    server.add_argument("--compression", action="store_true")
    \\
    \\    client = sub.add_parser("client")
    \\    client.add_argument("--url", default="ws://127.0.0.1:9100/")
    \\    client.add_argument("--compression", action="store_true")
    \\    return parser.parse_args()
    \\
    \\async def main() -> None:
    \\    args = parse_args()
    \\    if args.mode == "server":
    \\        await run_server(args.port, args.compression)
    \\    else:
    \\        await run_client(args.url, args.compression)
    \\
    \\if __name__ == "__main__":
    \\    asyncio.run(main())
;

fn parseArgs(init: std.process.Init) !Args {
    var out: Args = .{
        .server_bin = "",
        .client_bin = "",
        .repeated_client_bin = "",
    };

    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer it.deinit();
    _ = it.next();

    while (it.next()) |arg_z| {
        const arg: []const u8 = arg_z;
        const kv = parseKeyVal(arg) orelse return error.UnknownArg;
        if (std.mem.eql(u8, kv.key, "server-bin")) {
            out.server_bin = kv.val;
        } else if (std.mem.eql(u8, kv.key, "client-bin")) {
            out.client_bin = kv.val;
        } else if (std.mem.eql(u8, kv.key, "repeated-client-bin")) {
            out.repeated_client_bin = kv.val;
        } else if (std.mem.eql(u8, kv.key, "port-base")) {
            out.port_base = try std.fmt.parseInt(u16, kv.val, 10);
        } else {
            return error.UnknownArg;
        }
    }

    if (out.server_bin.len == 0 or out.client_bin.len == 0 or out.repeated_client_bin.len == 0) {
        return error.MissingRequiredArg;
    }
    return out;
}

fn parseKeyVal(arg: []const u8) ?struct { key: []const u8, val: []const u8 } {
    if (!std.mem.startsWith(u8, arg, "--")) return null;
    const eq = std.mem.indexOfScalar(u8, arg, '=') orelse return null;
    return .{ .key = arg[2..eq], .val = arg[eq + 1 ..] };
}

fn fileExists(io: std.Io, path: []const u8) bool {
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return false;
    file.close(io);
    return true;
}

fn ensureNodeDeps(io: std.Io, allocator: std.mem.Allocator, root: []const u8, validation_dir: []const u8) !void {
    const ws_pkg = try std.fs.path.join(allocator, &.{ validation_dir, "node_modules", "ws", "package.json" });
    defer allocator.free(ws_pkg);
    if (fileExists(io, ws_pkg)) return;
    try runChecked(io, &.{ "npm", "install", "--prefix", validation_dir }, root, null);
}

fn runChecked(
    io: std.Io,
    argv: []const []const u8,
    cwd: ?[]const u8,
    env_map: ?*const std.process.Environ.Map,
) !void {
    const cwd_opt: std.process.Child.Cwd = if (cwd) |p| .{ .path = p } else .inherit;
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = cwd_opt,
        .environ_map = env_map,
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    defer if (child.id != null) terminateChild(io, &child);

    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) return error.ProcessFailed,
        else => return error.ProcessFailed,
    }
}

fn spawnServer(io: std.Io, argv: []const []const u8, cwd: ?[]const u8) !std.process.Child {
    const cwd_opt: std.process.Child.Cwd = if (cwd) |p| .{ .path = p } else .inherit;
    return try std.process.spawn(io, .{
        .argv = argv,
        .cwd = cwd_opt,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .inherit,
    });
}

fn spawnChild(
    io: std.Io,
    argv: []const []const u8,
    cwd: ?[]const u8,
    env_map: ?*const std.process.Environ.Map,
) !std.process.Child {
    const cwd_opt: std.process.Child.Cwd = if (cwd) |p| .{ .path = p } else .inherit;
    return try std.process.spawn(io, .{
        .argv = argv,
        .cwd = cwd_opt,
        .environ_map = env_map,
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    });
}

fn childCleanupPosix(child: *std.process.Child) void {
    if (child.stdin) |stdin| {
        _ = std.posix.system.close(stdin.handle);
        child.stdin = null;
    }
    if (child.stdout) |stdout| {
        _ = std.posix.system.close(stdout.handle);
        child.stdout = null;
    }
    if (child.stderr) |stderr| {
        _ = std.posix.system.close(stderr.handle);
        child.stderr = null;
    }
    child.id = null;
}

fn statusToTerm(status: u32) std.process.Child.Term {
    return if (std.posix.W.IFEXITED(status))
        .{ .exited = std.posix.W.EXITSTATUS(status) }
    else if (std.posix.W.IFSIGNALED(status))
        .{ .signal = std.posix.W.TERMSIG(status) }
    else if (std.posix.W.IFSTOPPED(status))
        .{ .stopped = std.posix.W.STOPSIG(status) }
    else
        .{ .unknown = status };
}

fn tryCollectChildTerm(io: std.Io, child: *std.process.Child) !?std.process.Child.Term {
    if (child.id == null) return null;

    if (builtin.os.tag == .windows) {
        const zero_timeout: windows.LARGE_INTEGER = 0;
        return switch (windows.ntdll.NtWaitForSingleObject(child.id.?, .FALSE, &zero_timeout)) {
            windows.NTSTATUS.WAIT_0 => try child.wait(io),
            .TIMEOUT, .USER_APC, .ALERTED => null,
            else => |status| windows.unexpectedStatus(status),
        };
    }

    var status: if (builtin.link_libc) c_int else u32 = undefined;
    while (true) {
        const rc = std.posix.system.waitpid(child.id.?, &status, std.posix.W.NOHANG);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return null;
                childCleanupPosix(child);
                return statusToTerm(@bitCast(status));
            },
            .INTR => continue,
            .CHILD => return error.ProcessFailed,
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }
}

fn terminateChild(io: std.Io, child: *std.process.Child) void {
    if (child.id == null) return;
    if (builtin.os.tag == .windows) {
        child.kill(io) catch {};
        _ = child.wait(io) catch {};
        child.id = null;
        return;
    }
    if (child.id) |pid| std.posix.kill(pid, .TERM) catch {};
    _ = child.wait(io) catch {};
    child.id = null;
}

fn waitForPort(io: std.Io, port: u16, timeout_ms: u64) !void {
    const start = std.Io.Timestamp.now(io, .awake);
    const deadline = start.addDuration(std.Io.Duration.fromMilliseconds(@intCast(timeout_ms)));
    while (std.Io.Timestamp.now(io, .awake).nanoseconds < deadline.nanoseconds) {
        const addr: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(port) };
        if (std.Io.net.IpAddress.connect(&addr, io, .{ .mode = .stream })) |stream| {
            stream.close(io);
            return;
        } else |_| {}
        try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .awake);
    }
    return error.PortWaitTimedOut;
}

fn termFailed(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code != 0,
        else => true,
    };
}

fn runCheckedTimed(
    io: std.Io,
    argv: []const []const u8,
    cwd: ?[]const u8,
    env_map: ?*const std.process.Environ.Map,
    timeout_ms: u64,
) !void {
    var child = try spawnChild(io, argv, cwd, env_map);

    const start = std.Io.Timestamp.now(io, .awake);
    const deadline = start.addDuration(std.Io.Duration.fromMilliseconds(@intCast(timeout_ms)));
    while (std.Io.Timestamp.now(io, .awake).nanoseconds < deadline.nanoseconds) {
        if (try tryCollectChildTerm(io, &child)) |term| {
            if (termFailed(term)) return error.ProcessFailed;
            return;
        }
        try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .awake);
    }

    child.kill(io);
    return error.ProcessTimedOut;
}

const Scenario = struct {
    name: []const u8,
    port: u16,
    server_cmd: []const []const u8,
    server_cwd: ?[]const u8,
    client_cmd: []const []const u8,
    client_cwd: ?[]const u8,
};

fn runScenario(io: std.Io, scenario: Scenario) !void {
    var stdout_buf: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);
    try stdout.interface.print("[interop] {s}\n", .{scenario.name});

    var server = try spawnServer(io, scenario.server_cmd, scenario.server_cwd);
    defer terminateChild(io, &server);

    waitForPort(io, scenario.port, 10_000) catch |err| {
        if (try tryCollectChildTerm(io, &server)) |term| {
            if (termFailed(term)) return error.ProcessFailed;
        }
        return err;
    };
    try runCheckedTimed(io, scenario.client_cmd, scenario.client_cwd, null, 30_000);

    if (try tryCollectChildTerm(io, &server)) |term| {
        if (termFailed(term)) return error.ProcessFailed;
    }
}

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try parseArgs(init);
    const root = try std.process.currentPathAlloc(init.io, allocator);
    const validation_dir = try std.fs.path.join(allocator, &.{ root, "validation" });
    try ensureNodeDeps(init.io, allocator, root, validation_dir);

    const node = "node";
    const python = "python3";

    const node_client_url_0 = try std.fmt.allocPrint(allocator, "--url=ws://127.0.0.1:{d}/", .{args.port_base});
    const node_client_url_1 = try std.fmt.allocPrint(allocator, "--url=ws://127.0.0.1:{d}/", .{args.port_base + 1});
    const aiohttp_client_url_2 = try std.fmt.allocPrint(allocator, "--url=ws://127.0.0.1:{d}/", .{args.port_base + 2});
    const aiohttp_client_url_3 = try std.fmt.allocPrint(allocator, "--url=ws://127.0.0.1:{d}/", .{args.port_base + 3});
    const port_0 = try std.fmt.allocPrint(allocator, "--port={d}", .{args.port_base});
    const port_1 = try std.fmt.allocPrint(allocator, "--port={d}", .{args.port_base + 1});
    const port_2 = try std.fmt.allocPrint(allocator, "--port={d}", .{args.port_base + 2});
    const port_3 = try std.fmt.allocPrint(allocator, "--port={d}", .{args.port_base + 3});
    const port_4 = try std.fmt.allocPrint(allocator, "--port={d}", .{args.port_base + 4});
    const port_5 = try std.fmt.allocPrint(allocator, "--port={d}", .{args.port_base + 5});
    const port_6 = try std.fmt.allocPrint(allocator, "--port={d}", .{args.port_base + 6});
    const port_7 = try std.fmt.allocPrint(allocator, "--port={d}", .{args.port_base + 7});
    const port_8 = try std.fmt.allocPrint(allocator, "--port={d}", .{args.port_base + 8});

    const scenarios = [_]Scenario{
        .{
            .name = "node-ws client -> zwebsocket server",
            .port = args.port_base,
            .server_cmd = &.{ args.server_bin, port_0 },
            .server_cwd = root,
            .client_cmd = &.{ node, "-e", node_peer_code, "client", node_client_url_0 },
            .client_cwd = validation_dir,
        },
        .{
            .name = "node-ws client -> zwebsocket server (permessage-deflate)",
            .port = args.port_base + 1,
            .server_cmd = &.{ args.server_bin, port_1, "--compression" },
            .server_cwd = root,
            .client_cmd = &.{ node, "-e", node_peer_code, "client", node_client_url_1, "--compression" },
            .client_cwd = validation_dir,
        },
        .{
            .name = "aiohttp client -> zwebsocket server",
            .port = args.port_base + 2,
            .server_cmd = &.{ args.server_bin, port_2 },
            .server_cwd = root,
            .client_cmd = &.{ python, "-c", aiohttp_peer_code, "client", aiohttp_client_url_2 },
            .client_cwd = validation_dir,
        },
        .{
            .name = "aiohttp client -> zwebsocket server (permessage-deflate)",
            .port = args.port_base + 3,
            .server_cmd = &.{ args.server_bin, port_3, "--compression" },
            .server_cwd = root,
            .client_cmd = &.{ python, "-c", aiohttp_peer_code, "client", aiohttp_client_url_3, "--compression" },
            .client_cwd = validation_dir,
        },
        .{
            .name = "raw client with repeated permessage-deflate offers -> zwebsocket server",
            .port = args.port_base + 4,
            .server_cmd = &.{ args.server_bin, port_4, "--compression" },
            .server_cwd = root,
            .client_cmd = &.{ args.repeated_client_bin, port_4 },
            .client_cwd = root,
        },
        .{
            .name = "zwebsocket client -> node-ws server",
            .port = args.port_base + 5,
            .server_cmd = &.{ node, "-e", node_peer_code, "server", port_5 },
            .server_cwd = validation_dir,
            .client_cmd = &.{ args.client_bin, port_5 },
            .client_cwd = root,
        },
        .{
            .name = "zwebsocket client -> node-ws server (permessage-deflate)",
            .port = args.port_base + 6,
            .server_cmd = &.{ node, "-e", node_peer_code, "server", port_6, "--compression" },
            .server_cwd = validation_dir,
            .client_cmd = &.{ args.client_bin, port_6, "--compression" },
            .client_cwd = root,
        },
        .{
            .name = "zwebsocket client -> aiohttp server",
            .port = args.port_base + 7,
            .server_cmd = &.{ python, "-c", aiohttp_peer_code, "server", port_7 },
            .server_cwd = validation_dir,
            .client_cmd = &.{ args.client_bin, port_7 },
            .client_cwd = root,
        },
        .{
            .name = "zwebsocket client -> aiohttp server (permessage-deflate)",
            .port = args.port_base + 8,
            .server_cmd = &.{ python, "-c", aiohttp_peer_code, "server", port_8, "--compression" },
            .server_cwd = validation_dir,
            .client_cmd = &.{ args.client_bin, port_8, "--compression" },
            .client_cwd = root,
        },
    };

    for (scenarios) |scenario| {
        try runScenario(init.io, scenario);
    }

    var stdout_buf: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_buf);
    try stdout.interface.writeAll("[interop] all scenarios passed\n");
}
