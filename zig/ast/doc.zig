const std = @import("std");

/// Plain-text description of the Ast JSON shape, meant to be appended to an
/// LLM prompt so it knows what it's targeting. Returned as owned bytes
/// (rather than a typed value) so it can just as easily be written to a
/// file or stored as a blob/text column in a db later.
pub fn generate(allocator: std.mem.Allocator) ![]u8 {
    return allocator.dupe(u8,
        \\Generate a JSON array of "Node" objects representing a search AST. Respond with ONLY the JSON array: no prose, no markdown code fences.
        \\
        \\Each Node object has exactly these keys:
        \\  "operand": "AND" | "OR" - how this node combines with the previous one in the array. On the first node in an array, always set this to "AND" (never null, never omitted).
        \\  "action": "EQUALS" | "NOT_EQUALS" | "CONTAINS" | "NOT_CONTAINS"
        \\  "path": a JSONPath-like string, e.g. "$.name" or "$.items[]". "[]" means "iterate every array element" and must be the LAST part of the path - never put anything after it (not "$.items[].name"); use "then" instead to check fields on each element.
        \\  "value": a string to compare against
        \\  "then": optional; a nested array of Node objects applied to each element when "path" ends in "[]"
        \\
        \\Example:
        \\[{"operand": "AND", "action": "EQUALS", "path": "$.items[]", "value": "", "then": [
        \\  {"operand": "AND", "action": "EQUALS", "path": "$.name", "value": "gadget"}
        \\]}]
    );
}