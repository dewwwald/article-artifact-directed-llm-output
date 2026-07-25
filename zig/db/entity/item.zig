/// An item's data: name and price. Mirrors one row of the `items` table.
pub const Item = struct {
    name: []const u8,
    price: i64,
};
