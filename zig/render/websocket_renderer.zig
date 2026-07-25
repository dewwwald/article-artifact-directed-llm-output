const std = @import("std");
const json = std.json;
const Event = @import("event.zig").Event;
const Renderer = @import("renderer.zig").Renderer;

/// Forwards each event to a browser over an already-upgraded websocket
/// connection, wrapped as {"event": <Event>} so the page can tell timeline
/// events apart from the chat-reply messages sent alongside them.
pub const WebsocketRenderer = struct {
    ws: *std.http.Server.WebSocket,
    allocator: std.mem.Allocator,

    pub fn renderer(self: *WebsocketRenderer) Renderer {
        return .{ .ptr = self, .renderFn = render };
    }

    fn render(ptr: *anyopaque, event: Event) !void {
        const self: *WebsocketRenderer = @ptrCast(@alignCast(ptr));

        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        try json.Stringify.value(.{ .event = event }, .{}, &aw.writer);

        self.ws.writeMessage(aw.writer.buffered(), .text) catch |err| switch (err) {
            error.WriteFailed => return, // the browser went away; drop the event
        };
    }
};
