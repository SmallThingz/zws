const std = @import("std");
const scripts = @import("scripts.zig");

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const root = try std.process.currentPathAlloc(init.io, allocator);
    defer allocator.free(root);

    const env = init.environ_map;
    const conns = scripts.envInt(env, "CONNS", 16);
    const iters = scripts.envInt(env, "ITERS", 200_000);
    const warmup = scripts.envInt(env, "WARMUP", 10_000);
    const msg_size = scripts.envInt(env, "MSG_SIZE", 16);

    try scripts.runZwebsocketExternal(init.io, allocator, .{
        .port = 9001,
        .conns = conns,
        .iters = iters,
        .warmup = warmup,
        .msg_size = msg_size,
    }, root, init.minimal.environ);

    try scripts.runUwsExternal(init.io, allocator, .{
        .port = 9002,
        .conns = conns,
        .iters = iters,
        .warmup = warmup,
        .msg_size = msg_size,
    }, root, init.minimal.environ);
}
