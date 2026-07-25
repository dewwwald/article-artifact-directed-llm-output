/// How a node's result combines with the running result of the nodes before it in the same array.
pub const Operand = enum { AND, OR };

/// EQUALS/NOT_EQUALS compare the resolved value against `value` directly.
/// CONTAINS/NOT_CONTAINS check substring (for strings) or membership (for arrays).
/// NOT_EQUALS replaces the originally-sketched ISNOT: it's the negation of EQUALS,
/// with NOT_CONTAINS as the matching negation of CONTAINS.
pub const Action = enum { EQUALS, NOT_EQUALS, CONTAINS, NOT_CONTAINS };

pub const Node = struct {
    /// Ignored on the first node in an array, so it's fine for it to be
    /// omitted there entirely - defaults to AND rather than requiring a
    /// meaningless value be spelled out.
    operand: Operand = .AND,
    action: Action,
    path: []const u8,
    value: []const u8,
    /// Nested AST evaluated against each element when `path` resolves to an array.
    /// A path like "$.name" here is applied relative to each array element, i.e.
    /// equivalent to "$.[].name" against the parent object.
    then: ?[]const Node = null,
};

pub const Ast = []const Node;
