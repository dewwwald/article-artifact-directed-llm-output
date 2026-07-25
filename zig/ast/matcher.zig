const std = @import("std");
const json = std.json;
const Node = @import("entity/node.zig").Node;
const Ast = @import("entity/node.zig").Ast;
const Segment = @import("entity/segment.zig").Segment;

const ResolveError = error{ InvalidPath, UnsupportedPath };

const Resolved = union(enum) {
    none,
    single: json.Value,
    many: []const json.Value,
};

fn parseSegments(allocator: std.mem.Allocator, path: []const u8) !std.ArrayList(Segment) {
    var segments: std.ArrayList(Segment) = .empty;
    errdefer segments.deinit(allocator);

    var rest = path;
    if (rest.len == 0 or rest[0] != '$') return ResolveError.InvalidPath;
    rest = rest[1..];

    var it = std.mem.splitScalar(u8, rest, '.');
    while (it.next()) |token| {
        if (token.len == 0) continue;

        var name: ?[]const u8 = null;
        var index: ?usize = null;
        var wildcard = false;

        if (std.mem.indexOfScalar(u8, token, '[')) |bracket_start| {
            if (bracket_start > 0) name = token[0..bracket_start];
            const bracket_end = std.mem.indexOfScalar(u8, token, ']') orelse return ResolveError.InvalidPath;
            const inner = token[bracket_start + 1 .. bracket_end];
            if (inner.len == 0) {
                wildcard = true;
            } else {
                index = std.fmt.parseInt(usize, inner, 10) catch return ResolveError.InvalidPath;
            }
        } else {
            name = token;
        }

        try segments.append(allocator, .{ .name = name, .index = index, .wildcard = wildcard });
    }

    return segments;
}

fn resolvePath(allocator: std.mem.Allocator, root: json.Value, path: []const u8) !Resolved {
    var segments = try parseSegments(allocator, path);
    defer segments.deinit(allocator);

    var current = root;
    for (segments.items, 0..) |seg, i| {
        const is_last = i == segments.items.len - 1;

        if (seg.name) |name| {
            switch (current) {
                .object => |obj| current = obj.get(name) orelse return .none,
                else => return .none,
            }
        }

        if (seg.wildcard) {
            if (!is_last) return ResolveError.UnsupportedPath;
            return switch (current) {
                .array => |arr| .{ .many = arr.items },
                else => .none,
            };
        } else if (seg.index) |idx| {
            switch (current) {
                .array => |arr| {
                    if (idx >= arr.items.len) return .none;
                    current = arr.items[idx];
                },
                else => return .none,
            }
        }
    }

    return .{ .single = current };
}

fn valueEquals(value: json.Value, target: []const u8) bool {
    var buf: [64]u8 = undefined;
    return switch (value) {
        .string, .number_string => |s| std.mem.eql(u8, s, target),
        .integer => |n| blk: {
            const s = std.fmt.bufPrint(&buf, "{d}", .{n}) catch break :blk false;
            break :blk std.mem.eql(u8, s, target);
        },
        .float => |f| blk: {
            const s = std.fmt.bufPrint(&buf, "{d}", .{f}) catch break :blk false;
            break :blk std.mem.eql(u8, s, target);
        },
        .bool => |b| std.mem.eql(u8, if (b) "true" else "false", target),
        .null => std.mem.eql(u8, "null", target),
        else => false,
    };
}

fn valueContains(value: json.Value, target: []const u8) bool {
    return switch (value) {
        .string, .number_string => |s| std.mem.indexOf(u8, s, target) != null,
        .array => |arr| blk: {
            for (arr.items) |item| {
                if (valueEquals(item, target)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

fn matchLeaf(node: Node, value: json.Value) bool {
    return switch (node.action) {
        .EQUALS => valueEquals(value, node.value),
        .NOT_EQUALS => !valueEquals(value, node.value),
        .CONTAINS => valueContains(value, node.value),
        .NOT_CONTAINS => !valueContains(value, node.value),
    };
}

const MatchError = ResolveError || std.mem.Allocator.Error;

fn matchNode(allocator: std.mem.Allocator, node: Node, data: json.Value) MatchError!bool {
    const resolved = try resolvePath(allocator, data, node.path);
    return switch (resolved) {
        .none => false,
        .single => |v| matchLeaf(node, v),
        .many => |items| blk: {
            // Existential: the node matches if any array element matches
            // (either the nested `then` AST, or this node's own leaf check).
            for (items) |item| {
                const item_matches = if (node.then) |nested|
                    try matches(allocator, nested, item)
                else
                    matchLeaf(node, item);
                if (item_matches) break :blk true;
            }
            break :blk false;
        },
    };
}

/// Evaluate an AST (array of nodes) against a dynamic JSON value, folding
/// node results left-to-right with each node's `operand`. The first node's
/// operand is ignored since there is no prior result to combine with.
pub fn matches(allocator: std.mem.Allocator, ast: Ast, data: json.Value) MatchError!bool {
    var result = true;
    for (ast, 0..) |node, i| {
        const node_result = try matchNode(allocator, node, data);
        if (i == 0) {
            result = node_result;
        } else {
            result = switch (node.operand) {
                .AND => result and node_result,
                .OR => result or node_result,
            };
        }
    }
    return result;
}

fn parseJson(allocator: std.mem.Allocator, text: []const u8) !json.Parsed(json.Value) {
    return json.parseFromSlice(json.Value, allocator, text, .{});
}

/// Unlike `matches` (which only answers "does anything satisfy this AST"),
/// this answers "which array elements satisfy it": it resolves the first
/// node's `path` to an array and returns the indices of the elements that
/// pass that node's check (its nested `then` AST if present, otherwise its
/// own leaf check). Returns an empty slice if the AST is empty or its path
/// doesn't resolve to an array.
pub fn filterIndices(allocator: std.mem.Allocator, ast: Ast, data: json.Value) MatchError![]usize {
    var out: std.ArrayList(usize) = .empty;
    errdefer out.deinit(allocator);
    if (ast.len == 0) return out.toOwnedSlice(allocator);

    const node = ast[0];
    const resolved = try resolvePath(allocator, data, node.path);
    const items = switch (resolved) {
        .many => |items| items,
        else => return out.toOwnedSlice(allocator),
    };

    for (items, 0..) |item, i| {
        const item_matches = if (node.then) |nested|
            try matches(allocator, nested, item)
        else
            matchLeaf(node, item);
        if (item_matches) try out.append(allocator, i);
    }
    return out.toOwnedSlice(allocator);
}

test "EQUALS matches a scalar field" {
    const allocator = std.testing.allocator;
    const parsed = try parseJson(allocator, "{\"name\": \"widget\"}");
    defer parsed.deinit();

    const ast = [_]Node{
        .{ .operand = .AND, .action = .EQUALS, .path = "$.name", .value = "widget" },
    };
    try std.testing.expect(try matches(allocator, &ast, parsed.value));
}

test "NOT_EQUALS negates EQUALS" {
    const allocator = std.testing.allocator;
    const parsed = try parseJson(allocator, "{\"name\": \"widget\"}");
    defer parsed.deinit();

    const ast = [_]Node{
        .{ .operand = .AND, .action = .NOT_EQUALS, .path = "$.name", .value = "gadget" },
    };
    try std.testing.expect(try matches(allocator, &ast, parsed.value));
}

test "CONTAINS matches substring and array membership" {
    const allocator = std.testing.allocator;
    const parsed = try parseJson(allocator, "{\"desc\": \"a red widget\", \"tags\": [\"sale\", \"new\"]}");
    defer parsed.deinit();

    const ast = [_]Node{
        .{ .operand = .AND, .action = .CONTAINS, .path = "$.desc", .value = "red" },
        .{ .operand = .AND, .action = .CONTAINS, .path = "$.tags", .value = "new" },
    };
    try std.testing.expect(try matches(allocator, &ast, parsed.value));
}

test "NOT_CONTAINS negates CONTAINS" {
    const allocator = std.testing.allocator;
    const parsed = try parseJson(allocator, "{\"tags\": [\"sale\", \"new\"]}");
    defer parsed.deinit();

    const ast = [_]Node{
        .{ .operand = .AND, .action = .NOT_CONTAINS, .path = "$.tags", .value = "clearance" },
    };
    try std.testing.expect(try matches(allocator, &ast, parsed.value));
}

test "AND requires every node to match" {
    const allocator = std.testing.allocator;
    const parsed = try parseJson(allocator, "{\"name\": \"widget\", \"price\": 10}");
    defer parsed.deinit();

    const ast = [_]Node{
        .{ .operand = .AND, .action = .EQUALS, .path = "$.name", .value = "widget" },
        .{ .operand = .AND, .action = .EQUALS, .path = "$.price", .value = "999" },
    };
    try std.testing.expect(!try matches(allocator, &ast, parsed.value));
}

test "OR matches if either node matches" {
    const allocator = std.testing.allocator;
    const parsed = try parseJson(allocator, "{\"name\": \"widget\", \"price\": 10}");
    defer parsed.deinit();

    const ast = [_]Node{
        .{ .operand = .AND, .action = .EQUALS, .path = "$.name", .value = "gadget" },
        .{ .operand = .OR, .action = .EQUALS, .path = "$.price", .value = "10" },
    };
    try std.testing.expect(try matches(allocator, &ast, parsed.value));
}

test "wildcard array iterates items with a leaf check" {
    const allocator = std.testing.allocator;
    const parsed = try parseJson(allocator, "{\"items\": [\"a\", \"b\", \"c\"]}");
    defer parsed.deinit();

    const ast = [_]Node{
        .{ .operand = .AND, .action = .EQUALS, .path = "$.items[]", .value = "b" },
    };
    try std.testing.expect(try matches(allocator, &ast, parsed.value));
}

test "wildcard array with nested then AST checks each object element" {
    const allocator = std.testing.allocator;
    const parsed = try parseJson(allocator,
        \\{"items": [{"name": "widget", "price": 5}, {"name": "gadget", "price": 50}]}
    );
    defer parsed.deinit();

    const ast = [_]Node{
        .{
            .operand = .AND,
            .action = .EQUALS,
            .path = "$.items[]",
            .value = "",
            .then = &[_]Node{
                .{ .operand = .AND, .action = .EQUALS, .path = "$.name", .value = "gadget" },
                .{ .operand = .AND, .action = .EQUALS, .path = "$.price", .value = "50" },
            },
        },
    };
    try std.testing.expect(try matches(allocator, &ast, parsed.value));
}

test "filterIndices returns which items matched, not just whether any did" {
    const allocator = std.testing.allocator;
    const parsed = try parseJson(allocator,
        \\{"items": [{"name": "widget", "price": 5}, {"name": "gadget", "price": 50}, {"name": "gadget", "price": 5}]}
    );
    defer parsed.deinit();

    const ast = [_]Node{
        .{
            .operand = .AND,
            .action = .EQUALS,
            .path = "$.items[]",
            .value = "",
            .then = &[_]Node{
                .{ .operand = .AND, .action = .EQUALS, .path = "$.name", .value = "gadget" },
                .{ .operand = .AND, .action = .EQUALS, .path = "$.price", .value = "50" },
            },
        },
    };
    const indices = try filterIndices(allocator, &ast, parsed.value);
    defer allocator.free(indices);
    try std.testing.expectEqualSlices(usize, &.{1}, indices);
}

test "missing path does not match" {
    const allocator = std.testing.allocator;
    const parsed = try parseJson(allocator, "{\"name\": \"widget\"}");
    defer parsed.deinit();

    const ast = [_]Node{
        .{ .operand = .AND, .action = .EQUALS, .path = "$.missing", .value = "anything" },
    };
    try std.testing.expect(!try matches(allocator, &ast, parsed.value));
}
