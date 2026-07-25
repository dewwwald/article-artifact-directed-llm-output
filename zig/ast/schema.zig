const Operand = @import("entity/node.zig").Operand;
const Action = @import("entity/node.zig").Action;

pub const EnumField = struct {
    key: []const u8,
    values: []const []const u8,
};

/// Describes the JSON shape of an Ast (an array of Node objects) so a
/// streaming validator can check LLM output against it without the
/// validator needing to know anything about the Node/Segment types itself.
/// This value is meant to be injected into whatever validates against it
/// (see llm/prefix_validator.zig).
pub const Schema = struct {
    /// Every key a Node object may have.
    object_keys: []const []const u8,
    /// Keys whose string value must be exactly one of a fixed set of values.
    enum_fields: []const EnumField,
    /// Keys whose string value may be anything.
    open_string_keys: []const []const u8,
    /// Keys whose value is either `null` or a nested array of Node objects.
    nested_array_keys: []const []const u8,
};

// Kept in sync manually with ast/entity/node.zig; this guards against silent
// drift if a variant is ever added there without updating the values below.
comptime {
    if (@typeInfo(Operand).@"enum".fields.len != 2) @compileError("Operand changed, update ast/schema.zig");
    if (@typeInfo(Action).@"enum".fields.len != 4) @compileError("Action changed, update ast/schema.zig");
}

pub const node: Schema = .{
    .object_keys = &.{ "operand", "action", "path", "value", "then" },
    .enum_fields = &.{
        .{ .key = "operand", .values = &.{ "AND", "OR" } },
        .{ .key = "action", .values = &.{ "EQUALS", "NOT_EQUALS", "CONTAINS", "NOT_CONTAINS" } },
    },
    .open_string_keys = &.{ "path", "value" },
    .nested_array_keys = &.{"then"},
};