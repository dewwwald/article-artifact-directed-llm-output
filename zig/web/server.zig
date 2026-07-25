const std = @import("std");
const net = std.Io.net;
const http = std.http;
const json = std.json;

const Item = @import("../db/entity/item.zig").Item;
const ItemCrudService = @import("../db/repository/item_crud_service.zig").ItemCrudService;
const query = @import("../query.zig");

const Bus = @import("../render/renderer.zig").Bus;
const TerminalRenderer = @import("../render/terminal_renderer.zig").TerminalRenderer;
const WebsocketRenderer = @import("../render/websocket_renderer.zig").WebsocketRenderer;

const index_html = @embedFile("index.html");

/// Serves the chat UI at `/` and a chat session over a websocket at `/ws`.
/// Connections are handled concurrently: a browser opens the page connection
/// (which may stay keep-alive) and a separate websocket connection at
/// roughly the same time, so a sequential accept loop would get stuck
/// babysitting the first one and never reach the second.
pub fn run(allocator: std.mem.Allocator, io: std.Io, items: ItemCrudService, port: u16) !void {
    var address = try net.IpAddress.parseIp4("127.0.0.1", port);
    var tcp_server = try address.listen(io, .{ .reuse_address = true });
    defer tcp_server.deinit(io);

    std.debug.print("web ui listening at http://127.0.0.1:{d}/\n", .{port});

    var group: std.Io.Group = .init;
    defer group.cancel(io);

    while (true) {
        const stream = try tcp_server.accept(io);
        group.concurrent(io, handleConnection, .{ allocator, io, stream, items }) catch |err| {
            std.debug.print("unable to spawn connection handler: {t}\n", .{err});
            var s = stream;
            s.close(io);
        };
    }
}

/// Entry point for `group.concurrent`, which requires a `void`-returning
/// function - errors are logged here instead of propagated.
fn handleConnection(allocator: std.mem.Allocator, io: std.Io, stream: net.Stream, items: ItemCrudService) void {
    serveConnection(allocator, io, stream, items) catch |err| {
        std.debug.print("connection error: {t}\n", .{err});
    };
}

fn serveConnection(allocator: std.mem.Allocator, io: std.Io, stream: net.Stream, items: ItemCrudService) !void {
    var s = stream;
    defer s.close(io);

    var send_buf: [8192]u8 = undefined;
    var recv_buf: [8192]u8 = undefined;
    var conn_reader = stream.reader(io, &recv_buf);
    var conn_writer = stream.writer(io, &send_buf);
    var http_server: http.Server = .init(&conn_reader.interface, &conn_writer.interface);

    while (true) {
        var request = http_server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => return,
            else => return err,
        };
        switch (request.upgradeRequested()) {
            .websocket => |opt_key| {
                const key = opt_key orelse return error.MissingWebSocketKey;
                var ws = try request.respondWebSocket(.{ .key = key });
                try ws.flush();
                return serveChatSession(allocator, io, &ws, items);
            },
            .none => {
                if (std.mem.eql(u8, request.head.target, "/")) {
                    try request.respond(index_html, .{
                        .extra_headers = &.{.{ .name = "content-type", .value = "text/html; charset=utf-8" }},
                    });
                } else {
                    try request.respond("not found", .{ .status = .not_found });
                }
            },
            .other => try request.respond("unsupported upgrade", .{ .status = .bad_request }),
        }
    }
}

fn serveChatSession(allocator: std.mem.Allocator, io: std.Io, ws: *http.Server.WebSocket, items: ItemCrudService) !void {
    while (true) {
        const msg = ws.readSmallMessage() catch |err| switch (err) {
            error.ConnectionClose => return,
            else => return err,
        };
        if (msg.opcode != .text) continue;

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const qalloc = arena.allocator();

        handlePrompt(qalloc, io, ws, items, msg.data) catch |err| {
            sendError(qalloc, ws, @errorName(err)) catch {};
        };
    }
}

fn handlePrompt(allocator: std.mem.Allocator, io: std.Io, ws: *http.Server.WebSocket, items: ItemCrudService, message: []const u8) !void {
    const parsed = try json.parseFromSlice(struct { prompt: []const u8 }, allocator, message, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const rows = try items.all(allocator);

    var terminal = TerminalRenderer{ .io = io, .delay_ms = 15 };
    var ws_renderer = WebsocketRenderer{ .ws = ws, .allocator = allocator };
    var bus: Bus = .{};
    defer bus.deinit(allocator);
    try bus.subscribe(allocator, terminal.renderer());
    try bus.subscribe(allocator, ws_renderer.renderer());

    try query.run(allocator, io, &bus, rows, parsed.value.prompt);
}

fn sendError(allocator: std.mem.Allocator, ws: *http.Server.WebSocket, message: []const u8) !void {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try json.Stringify.value(.{ .@"error" = message }, .{}, &aw.writer);
    try ws.writeMessage(aw.writer.buffered(), .text);
}
