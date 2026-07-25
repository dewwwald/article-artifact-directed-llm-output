const std = @import("std");
const json = std.json;
const Schema = @import("../ast/schema.zig").Schema;

/// Result of feeding another chunk of (possibly LLM-generated) text into a
/// Validator. `valid_incomplete` is not an error: an unclosed `{` at the
/// start of a document is exactly this state, expected right up until the
/// document actually closes.
pub const Status = union(enum) {
    valid_incomplete,
    valid_complete,
    invalid: []const u8,
};

const FrameKind = enum {
    /// Nothing seen yet; expects the single outer array_begin.
    top,
    /// Inside an array of Node objects; expects object_begin or array_end.
    array,
    /// Inside a Node object; expects a string key or object_end. Accumulates
    /// partial key text in `buf` across chunks.
    key,
    /// Inside a Node object, reading the string value for an enum-constrained
    /// key (operand/action). Accumulates partial value text in `buf` and
    /// checks it against `enum_values`.
    val_enum,
    /// Inside a Node object, reading the string value for an open key
    /// (path/value). Any content is accepted.
    val_open,
    /// Inside a Node object, expecting `null` or a nested array for "then".
    val_then,
};

const max_key_len = 16;

const Frame = struct {
    kind: FrameKind,
    buf: [max_key_len]u8 = undefined,
    len: u8 = 0,
    enum_values: []const []const u8 = &.{},

    fn reset(self: *Frame) void {
        self.len = 0;
    }

    fn append(self: *Frame, bytes: []const u8) error{Overflow}!void {
        if (self.len + bytes.len > self.buf.len) return error.Overflow;
        @memcpy(self.buf[self.len..][0..bytes.len], bytes);
        self.len += @intCast(bytes.len);
    }

    fn text(self: *const Frame) []const u8 {
        return self.buf[0..self.len];
    }
};

fn isPrefixOfAny(candidate: []const u8, options: []const []const u8) bool {
    for (options) |opt| {
        if (candidate.len <= opt.len and std.mem.eql(u8, candidate, opt[0..candidate.len])) return true;
    }
    return false;
}

fn findExact(candidate: []const u8, options: []const []const u8) bool {
    for (options) |opt| {
        if (std.mem.eql(u8, candidate, opt)) return true;
    }
    return false;
}

/// Streams JSON text (as it might arrive character-by-character or
/// token-by-token from an LLM) through std.json.Scanner for JSON-syntax
/// validity, and layers Node-schema validation (known keys, enum-constrained
/// values) on top, so guided decoding can reject an impossible next
/// character before the model ever finishes generating it.
pub const Validator = struct {
    allocator: std.mem.Allocator,
    schema: Schema,
    scanner: json.Scanner,
    stack: std.ArrayList(Frame),
    done: bool = false,

    pub fn init(allocator: std.mem.Allocator, schema: Schema) !Validator {
        var stack: std.ArrayList(Frame) = .empty;
        try stack.append(allocator, .{ .kind = .top });
        return .{
            .allocator = allocator,
            .schema = schema,
            .scanner = json.Scanner.initStreaming(allocator),
            .stack = stack,
        };
    }

    pub fn deinit(self: *Validator) void {
        self.scanner.deinit();
        self.stack.deinit(self.allocator);
    }

    /// Feed the next chunk of generated text (a single character, a token,
    /// or any other slice) and get back whether the document is still a
    /// valid prefix, already complete, or has diverged from the schema.
    pub fn feed(self: *Validator, chunk: []const u8) !Status {
        self.scanner.feedInput(chunk);
        return self.pump();
    }

    /// Call once generation has stopped, to confirm the document actually
    /// closed rather than merely being a valid-so-far prefix.
    pub fn finish(self: *Validator) !Status {
        self.scanner.endInput();
        return self.pump();
    }

    fn top(self: *Validator) *Frame {
        return &self.stack.items[self.stack.items.len - 1];
    }

    fn push(self: *Validator, frame: Frame) !void {
        try self.stack.append(self.allocator, frame);
    }

    fn pop(self: *Validator) void {
        _ = self.stack.pop();
    }

    fn invalid(comptime reason: []const u8) Status {
        return .{ .invalid = reason };
    }

    fn pump(self: *Validator) !Status {
        while (true) {
            const token = self.scanner.next() catch |err| switch (err) {
                error.BufferUnderrun => return .valid_incomplete,
                error.SyntaxError, error.UnexpectedEndOfInput => return invalid("invalid JSON syntax"),
                else => |e| return e,
            };
            if (token == .end_of_document) {
                return if (self.done) .valid_complete else invalid("unexpected end of input");
            }
            if (try self.handle(token)) |status| return status;
        }
    }

    fn handle(self: *Validator, token: json.Token) !?Status {
        switch (self.top().kind) {
            .top => {
                if (token != .array_begin) return invalid("expected the AST to start with '['");
                try self.push(.{ .kind = .array });
                return null;
            },
            .array => return self.handleArray(token),
            .key => return self.handleKey(token),
            .val_enum => return self.handleValEnum(token),
            .val_open => return self.handleValOpen(token),
            .val_then => return self.handleValThen(token),
        }
    }

    fn handleArray(self: *Validator, token: json.Token) !?Status {
        switch (token) {
            .array_end => {
                self.pop();
                switch (self.top().kind) {
                    .top => self.done = true,
                    .val_then => {
                        self.top().kind = .key;
                        self.top().reset();
                    },
                    else => unreachable,
                }
                return null;
            },
            .object_begin => {
                try self.push(.{ .kind = .key });
                return null;
            },
            else => return invalid("expected a Node object or ']'"),
        }
    }

    fn handleKey(self: *Validator, token: json.Token) !?Status {
        switch (token) {
            .object_end => {
                self.pop();
                return null;
            },
            .partial_string => |chunk| {
                self.top().append(chunk) catch return invalid("unrecognized key");
                if (!isPrefixOfAny(self.top().text(), self.schema.object_keys)) return invalid("unrecognized key");
                return null;
            },
            .string => |chunk| {
                self.top().append(chunk) catch return invalid("unrecognized key");
                const key = self.top().text();
                if (!findExact(key, self.schema.object_keys)) return invalid("unrecognized key");
                try self.resolveKey(key);
                return null;
            },
            else => return invalid("expected a string key"),
        }
    }

    fn resolveKey(self: *Validator, key: []const u8) !void {
        for (self.schema.enum_fields) |field| {
            if (std.mem.eql(u8, key, field.key)) {
                self.top().kind = .val_enum;
                self.top().reset();
                self.top().enum_values = field.values;
                return;
            }
        }
        if (findExact(key, self.schema.open_string_keys)) {
            self.top().kind = .val_open;
            return;
        }
        if (findExact(key, self.schema.nested_array_keys)) {
            self.top().kind = .val_then;
            return;
        }
        unreachable; // key was already checked against object_keys
    }

    fn handleValEnum(self: *Validator, token: json.Token) !?Status {
        switch (token) {
            .partial_string => |chunk| {
                self.top().append(chunk) catch return invalid("value not in enum");
                if (!isPrefixOfAny(self.top().text(), self.top().enum_values)) return invalid("value not in enum");
                return null;
            },
            .string => |chunk| {
                self.top().append(chunk) catch return invalid("value not in enum");
                if (!findExact(self.top().text(), self.top().enum_values)) return invalid("value not in enum");
                self.top().kind = .key;
                self.top().reset();
                return null;
            },
            else => return invalid("expected a string value"),
        }
    }

    fn handleValOpen(self: *Validator, token: json.Token) !?Status {
        switch (token) {
            .partial_string => return null,
            .string => {
                self.top().kind = .key;
                self.top().reset();
                return null;
            },
            else => return invalid("expected a string value"),
        }
    }

    fn handleValThen(self: *Validator, token: json.Token) !?Status {
        switch (token) {
            .null => {
                self.top().kind = .key;
                self.top().reset();
                return null;
            },
            .array_begin => {
                try self.push(.{ .kind = .array });
                return null;
            },
            else => return invalid("'then' must be an array or null"),
        }
    }
};

fn expectStatuses(schema: Schema, chunks: []const []const u8, expected: []const std.meta.Tag(Status)) !void {
    const allocator = std.testing.allocator;
    var validator = try Validator.init(allocator, schema);
    defer validator.deinit();

    for (chunks, expected) |chunk, want| {
        const status = try validator.feed(chunk);
        try std.testing.expectEqual(want, std.meta.activeTag(status));
    }
}

const node_schema = @import("../ast/schema.zig").node;

test "a lone open brace is a valid, incomplete prefix" {
    try expectStatuses(node_schema, &.{"["}, &.{.valid_incomplete});
}

test "full simple ast is valid and completes" {
    const allocator = std.testing.allocator;
    var validator = try Validator.init(allocator, node_schema);
    defer validator.deinit();

    const text =
        \\[{"operand": "AND", "action": "EQUALS", "path": "$.name", "value": "widget"}]
    ;
    _ = try validator.feed(text);
    const status = try validator.finish();
    try std.testing.expectEqual(.valid_complete, std.meta.activeTag(status));
}

test "streaming the same document one byte at a time stays valid throughout" {
    const allocator = std.testing.allocator;
    var validator = try Validator.init(allocator, node_schema);
    defer validator.deinit();

    const text =
        \\[{"operand": "AND", "action": "CONTAINS", "path": "$.tags[]", "value": "sale", "then": null}]
    ;
    for (text) |byte| {
        const status = try validator.feed(&.{byte});
        try std.testing.expect(std.meta.activeTag(status) != .invalid);
    }
    const status = try validator.finish();
    try std.testing.expectEqual(.valid_complete, std.meta.activeTag(status));
}

test "unknown key is rejected as soon as it diverges" {
    const allocator = std.testing.allocator;
    var validator = try Validator.init(allocator, node_schema);
    defer validator.deinit();

    _ = try validator.feed("[{\"opera");
    const status = try validator.feed("tion");
    try std.testing.expectEqual(.invalid, std.meta.activeTag(status));
}

test "enum value outside the allowed set is rejected once it diverges" {
    const allocator = std.testing.allocator;
    var validator = try Validator.init(allocator, node_schema);
    defer validator.deinit();

    // "A" is still a valid prefix of "AND" here, so this stays valid...
    const first = try validator.feed("[{\"operand\": \"A");
    try std.testing.expect(std.meta.activeTag(first) != .invalid);

    // ...but "AX" isn't a prefix of "AND" or "OR", so this must reject.
    const second = try validator.feed("X");
    try std.testing.expectEqual(.invalid, std.meta.activeTag(second));
}

test "nested then array is validated with the same rules" {
    const allocator = std.testing.allocator;
    var validator = try Validator.init(allocator, node_schema);
    defer validator.deinit();

    const text =
        \\[{"operand": "AND", "action": "EQUALS", "path": "$.items[]", "value": "", "then": [
        \\  {"operand": "AND", "action": "EQUALS", "path": "$.name", "value": "gadget"}
        \\]}]
    ;
    _ = try validator.feed(text);
    const status = try validator.finish();
    try std.testing.expectEqual(.valid_complete, std.meta.activeTag(status));
}
