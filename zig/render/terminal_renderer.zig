const std = @import("std");
const Event = @import("event.zig").Event;
const Renderer = @import("renderer.zig").Renderer;

/// Prints each event on the timeline with a small delay after it, so the
/// sequence of steps reads as it happens rather than dumping all at once.
pub const TerminalRenderer = struct {
    io: std.Io,
    delay_ms: i64 = 40,

    pub fn renderer(self: *TerminalRenderer) Renderer {
        return .{ .ptr = self, .renderFn = render };
    }

    fn render(ptr: *anyopaque, event: Event) !void {
        const self: *TerminalRenderer = @ptrCast(@alignCast(ptr));
        switch (event) {
            .prompt_sent => |prompt| std.debug.print("[timeline] prompt sent: \"{s}\"\n", .{prompt}),
            .guided_prompt_sent => |p| std.debug.print("[timeline] guided prompt built for attempt {d} (system: {d} bytes, user: {d} bytes)\n", .{ p.attempt, p.system.len, p.user.len }),
            .response_received => |resp| std.debug.print("[timeline] llm response received ({d} bytes)\n", .{resp.len}),
            .token_fed => |t| std.debug.print("[timeline] token {d}: '{c}'\n", .{ t.index, t.byte }),
            .validation_result => |status| switch (status) {
                .valid_incomplete => std.debug.print("[timeline]   -> valid so far\n", .{}),
                .valid_complete => std.debug.print("[timeline]   -> complete and valid\n", .{}),
                .invalid => |reason| std.debug.print("[timeline]   -> REJECTED: {s}\n", .{reason}),
            },
            .query_matched => |summary| std.debug.print("[timeline] matched: {s}\n", .{summary}),
            .query_rejected => |reason| std.debug.print("[timeline] rejected: {s}\n", .{reason}),
            .retrying => |r| std.debug.print("[timeline] retry {d}/{d}: telling the model it was rejected because: {s}\n", .{ r.attempt, r.max_attempts, r.reason }),
            .gave_up => |g| std.debug.print("[timeline] gave up after {d} attempt(s)\n", .{g.attempts}),
        }
        try std.Io.sleep(self.io, .fromMilliseconds(self.delay_ms), .real);
    }
};
