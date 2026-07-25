const std = @import("std");
const Event = @import("event.zig").Event;

/// A sink for timeline events. `render` returns an error so a future
/// implementation that needs it (e.g. sending over a websocket) doesn't
/// require changing this interface - a renderer that can't fail (like the
/// terminal one) just never returns one.
pub const Renderer = struct {
    ptr: *anyopaque,
    renderFn: *const fn (ptr: *anyopaque, event: Event) anyerror!void,

    pub fn render(self: Renderer, event: Event) !void {
        return self.renderFn(self.ptr, event);
    }
};

/// Fans a published event out to every subscribed renderer. Swapping or
/// adding a renderer (terminal, websocket, ...) never touches the code that
/// publishes events - it only ever depends on this bus.
pub const Bus = struct {
    renderers: std.ArrayList(Renderer) = .empty,

    pub fn deinit(self: *Bus, allocator: std.mem.Allocator) void {
        self.renderers.deinit(allocator);
    }

    pub fn subscribe(self: *Bus, allocator: std.mem.Allocator, renderer: Renderer) !void {
        try self.renderers.append(allocator, renderer);
    }

    pub fn publish(self: *Bus, event: Event) !void {
        for (self.renderers.items) |r| try r.render(event);
    }
};
