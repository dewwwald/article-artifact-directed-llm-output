const std = @import("std");
const json = std.json;

const Item = @import("db/entity/item.zig").Item;
const Node = @import("ast/entity/node.zig").Node;
const ast_matcher = @import("ast/matcher.zig");
const ast_doc = @import("ast/doc.zig");
const ast_schema = @import("ast/schema.zig");
const ast_json_schema = @import("ast/json_schema.zig");
const llm_client = @import("llm/client.zig");
const Validator = @import("llm/prefix_validator.zig").Validator;

const Bus = @import("render/renderer.zig").Bus;

/// Builds {"items": [{"name": ..., "price": ...}, ...]} from the loaded rows,
/// matching the shape the AST paths expect.
fn itemsToJson(allocator: std.mem.Allocator, rows: []const Item) !json.Value {
    var arr: json.Array = .init(allocator);
    for (rows) |row| {
        var obj: json.ObjectMap = .{};
        try obj.put(allocator, "name", .{ .string = row.name });
        try obj.put(allocator, "price", .{ .integer = row.price });
        try arr.append(.{ .object = obj });
    }
    var root: json.ObjectMap = .{};
    try root.put(allocator, "items", .{ .array = arr });
    return .{ .object = root };
}

/// Tells the model exactly which fields exist on the data it's querying.
/// Without this, the AST doc and JSON Schema only describe the AST's own
/// grammar (operand/action/path/value/then) - neither says anything about
/// the data model, so a prompt like "cost 50" has nothing to map "cost" onto
/// except whatever field names happen to appear in the doc's illustrative
/// example. Derived from `Item`'s own fields so it can't drift out of sync.
fn dataSchemaHint(allocator: std.mem.Allocator) ![]u8 {
    const fields = std.meta.fields(Item);
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;

    try w.writeAll("The data being queried is {\"items\": [...]}, where each item has exactly these fields (no others exist): ");
    inline for (fields, 0..) |field, i| {
        if (i > 0) try w.writeAll(", ");
        try w.print("\"{s}\"", .{field.name});
    }
    try w.writeAll(
        \\. Map the user's wording onto exactly these field names, never a synonym (e.g. "cost" or "amount" both mean the "price" field).
        \\
        \\Because the root object's only key is "items" (an array), your query MUST have exactly one top-level Node with "path": "$.items[]", and EVERY actual filtering condition on a field MUST be its own Node inside that top-level Node's "then" array (paths like "$.
    );
    if (fields.len > 0) try w.print("{s}", .{fields[0].name});
    try w.writeAll(
        \\"). Never put a field check directly in the top-level array - that only checks the raw array/item against a value, which can never match.
        \\
        \\WRONG (never do this - "$.items[]" and "$.
    );
    if (fields.len > 1) try w.print("{s}", .{fields[1].name}) else if (fields.len > 0) try w.print("{s}", .{fields[0].name});
    try w.writeAll(
        \\" as separate top-level entries):
        \\[{"operand": "AND", "action": "EQUALS", "path": "$.items[]", "value": "
    );
    if (fields.len > 0) try w.print("{s}", .{"gadget"});
    try w.writeAll("\"}, {\"operand\": \"AND\", \"action\": \"EQUALS\", \"path\": \"$.");
    if (fields.len > 1) try w.print("{s}", .{fields[1].name});
    try w.writeAll(
        \\", "value": "50"}]
        \\
        \\RIGHT (one top-level node, conditions nested in "then"):
        \\[{"operand": "AND", "action": "EQUALS", "path": "$.items[]", "value": "", "then": [
    );
    inline for (fields, 0..) |field, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("\n  {{\"operand\": \"AND\", \"action\": \"EQUALS\", \"path\": \"$.{s}\", \"value\": \"...\"}}", .{field.name});
    }
    try w.writeAll("\n]}]");
    return allocator.dupe(u8, w.buffered());
}

const AttemptResult = union(enum) {
    valid: []const u8,
    rejected: struct { content: []const u8, reason: []const u8 },
};

/// Sends one prompt to the LLM and re-feeds the response through the prefix
/// validator one byte at a time (post-hoc validation, not true token-level
/// constrained decoding - LM Studio only hands us the finished response, so
/// there's no token left to steer by the time we can check it). Every step
/// is published to the render bus rather than printed directly.
fn attemptOnce(allocator: std.mem.Allocator, io: std.Io, bus: *Bus, doc: []const u8, prompt: []const u8, response_schema: json.Value) !AttemptResult {
    const content = try llm_client.chat(allocator, io, .{}, doc, prompt, response_schema);
    try bus.publish(.{ .response_received = content });

    var validator = try Validator.init(allocator, ast_schema.node);
    defer validator.deinit();

    for (content, 0..) |byte, i| {
        try bus.publish(.{ .token_fed = .{ .byte = byte, .index = i } });
        const status = try validator.feed(&.{byte});
        try bus.publish(.{ .validation_result = status });
        if (status == .invalid) return .{ .rejected = .{ .content = content, .reason = status.invalid } };
    }
    const final = try validator.finish();
    try bus.publish(.{ .validation_result = final });
    return switch (final) {
        .valid_complete => .{ .valid = content },
        .valid_incomplete => .{ .rejected = .{ .content = content, .reason = "response ended mid-document" } },
        .invalid => |reason| .{ .rejected = .{ .content = content, .reason = reason } },
    };
}

/// Builds a follow-up prompt describing exactly why the previous response
/// was rejected, so the model gets a chance to correct itself. This is
/// "guided" only in the retry-with-feedback sense, not true constrained
/// decoding: the model regenerates the whole response from scratch.
fn buildRetryPrompt(allocator: std.mem.Allocator, original_prompt: []const u8, previous_content: []const u8, reason: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\Original request: {s}
        \\
        \\Your previous response was:
        \\{s}
        \\
        \\That response was rejected for this reason: {s}
        \\
        \\Respond again with ONLY a corrected JSON array that fixes this exact problem and satisfies the schema.
    , .{ original_prompt, previous_content, reason });
}

/// Prints an AST back out as JSON, the same shape it's targeting when
/// asking an LLM to generate one. Server-side debug log only.
fn printQuery(allocator: std.mem.Allocator, ast: []const Node) !void {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try json.Stringify.value(ast, .{ .whitespace = .indent_2 }, &aw.writer);
    std.debug.print("query:\n{s}\n", .{aw.writer.buffered()});
}

/// Tries (up to `max_attempts` times, feeding back the specific rejection
/// reason on each retry) to get a schema-valid Ast back from the LLM for
/// `user_prompt`. Once it gets one, parses it, prints it, and runs it
/// against `rows` (freshly re-read from the db by the caller, so items added
/// since the process started are visible) to report which ones actually
/// matched. Every step is published to `bus` so any subscribed renderer
/// (terminal, websocket, ...) can present it.
pub fn run(allocator: std.mem.Allocator, io: std.Io, bus: *Bus, rows: []const Item, user_prompt: []const u8) !void {
    try bus.publish(.{ .prompt_sent = user_prompt });

    const data = try itemsToJson(allocator, rows);
    const ast_doc_text = try ast_doc.generate(allocator);
    const data_hint = try dataSchemaHint(allocator);
    const doc = try std.fmt.allocPrint(allocator, "{s}\n\n{s}", .{ ast_doc_text, data_hint });
    const schema = try ast_json_schema.generate(allocator);
    defer schema.deinit();
    const max_attempts = 3;

    var prompt = user_prompt;
    var attempt: usize = 1;
    while (true) : (attempt += 1) {
        var reason: []const u8 = undefined;
        var bad_content: []const u8 = undefined;

        switch (try attemptOnce(allocator, io, bus, doc, prompt, schema.value)) {
            .valid => |content| {
                // Schema-valid JSON can still be semantically unusable - e.g. a
                // path that doesn't start with "$" or resolves against nothing.
                // Treat that the same as a validator rejection and retry, rather
                // than letting it crash the request.
                if (reportMatches(allocator, bus, rows, data, content)) |_| {
                    return;
                } else |err| {
                    reason = try std.fmt.allocPrint(allocator, "the query could not be run against the data: {s}", .{@errorName(err)});
                    bad_content = content;
                }
            },
            .rejected => |r| {
                reason = r.reason;
                bad_content = r.content;
            },
        }

        try bus.publish(.{ .query_rejected = reason });
        if (attempt >= max_attempts) {
            try bus.publish(.{ .gave_up = .{ .attempts = attempt } });
            return;
        }
        try bus.publish(.{ .retrying = .{ .attempt = attempt + 1, .max_attempts = max_attempts, .reason = reason } });
        prompt = try buildRetryPrompt(allocator, user_prompt, bad_content, reason);
    }
}

fn reportMatches(allocator: std.mem.Allocator, bus: *Bus, rows: []const Item, data: json.Value, content: []const u8) !void {
    const parsed_ast = try json.parseFromSlice([]Node, allocator, content, .{});
    defer parsed_ast.deinit();

    try printQuery(allocator, parsed_ast.value);

    const matching = try ast_matcher.filterIndices(allocator, parsed_ast.value, data);
    std.debug.print("matching items:\n", .{});

    var summary: std.Io.Writer.Allocating = .init(allocator);
    defer summary.deinit();
    if (matching.len == 0) {
        try summary.writer.writeAll("No items matched.");
    } else {
        try summary.writer.print("Found {d} item(s):", .{matching.len});
        for (matching) |i| {
            try summary.writer.print("\n- {s}: {d}", .{ rows[i].name, rows[i].price });
            std.debug.print("  - {s}: {d}\n", .{ rows[i].name, rows[i].price });
        }
    }
    try bus.publish(.{ .query_matched = summary.writer.buffered() });
}
