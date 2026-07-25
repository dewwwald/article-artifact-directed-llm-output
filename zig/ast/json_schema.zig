const std = @import("std");
const json = std.json;

/// A standard JSON Schema (distinct from ast/schema.zig's bespoke shape,
/// which is built for our own incremental validator) describing an Ast, for
/// passing to an LLM's response_format so it constrains token generation
/// directly via grammar-based sampling, rather than us only checking after
/// the fact.
pub fn generate(allocator: std.mem.Allocator) !json.Parsed(json.Value) {
    const text =
        \\{
        \\  "type": "array",
        \\  "items": { "$ref": "#/$defs/node" },
        \\  "$defs": {
        \\    "node": {
        \\      "type": "object",
        \\      "properties": {
        \\        "operand": { "type": "string", "enum": ["AND", "OR"] },
        \\        "action": { "type": "string", "enum": ["EQUALS", "NOT_EQUALS", "CONTAINS", "NOT_CONTAINS"] },
        \\        "path": { "type": "string" },
        \\        "value": { "type": "string" },
        \\        "then": {
        \\          "anyOf": [
        \\            { "type": "null" },
        \\            { "type": "array", "items": { "$ref": "#/$defs/node" } }
        \\          ]
        \\        }
        \\      },
        \\      "required": ["operand", "action", "path", "value"],
        \\      "additionalProperties": false
        \\    }
        \\  }
        \\}
    ;
    return json.parseFromSlice(json.Value, allocator, text, .{});
}
