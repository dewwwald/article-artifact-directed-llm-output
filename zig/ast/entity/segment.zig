/// A path segment: an optional field name to step into, followed by either
/// a fixed array index or a `[]` wildcard that yields every element.
pub const Segment = struct {
    name: ?[]const u8,
    index: ?usize = null,
    wildcard: bool = false,
};
