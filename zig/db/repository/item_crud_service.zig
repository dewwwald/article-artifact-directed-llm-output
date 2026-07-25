const std = @import("std");
const sqlite = @import("sqlite");
const Item = @import("../entity/item.zig").Item;

/// Raw-SQL CRUD access for the `items` table. No ORM: every statement is
/// hand-written and run directly through sqlite.Db, the zig-sqlite
/// equivalent of a raw-PDO repository.
pub const ItemCrudService = struct {
    db: *sqlite.Db,

    pub fn init(db: *sqlite.Db) ItemCrudService {
        return .{ .db = db };
    }

    pub fn ensureTable(self: ItemCrudService) !void {
        try self.db.exec(
            \\CREATE TABLE IF NOT EXISTS items(
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  name TEXT NOT NULL,
            \\  price INTEGER NOT NULL
            \\)
        , .{}, .{});
    }

    pub fn count(self: ItemCrudService) !i64 {
        return (try self.db.one(i64, "SELECT COUNT(*) FROM items", .{}, .{})) orelse 0;
    }

    /// Create.
    pub fn create(self: ItemCrudService, name: []const u8, price: i64) !void {
        try self.db.exec("INSERT INTO items(name, price) VALUES(?, ?)", .{}, .{ .name = name, .price = price });
    }

    /// Read (single row by id).
    pub fn find(self: ItemCrudService, allocator: std.mem.Allocator, id: i64) !?Item {
        return self.db.oneAlloc(Item, allocator, "SELECT name, price FROM items WHERE id = ?", .{}, .{ .id = id });
    }

    /// Read (all rows).
    pub fn all(self: ItemCrudService, allocator: std.mem.Allocator) ![]Item {
        var stmt = try self.db.prepare("SELECT name, price FROM items ORDER BY id");
        defer stmt.deinit();
        return stmt.all(Item, allocator, .{}, .{});
    }

    /// Update.
    pub fn update(self: ItemCrudService, id: i64, name: []const u8, price: i64) !void {
        try self.db.exec("UPDATE items SET name = ?, price = ? WHERE id = ?", .{}, .{ .name = name, .price = price, .id = id });
    }

    /// Delete.
    pub fn delete(self: ItemCrudService, id: i64) !void {
        try self.db.exec("DELETE FROM items WHERE id = ?", .{}, .{ .id = id });
    }
};

fn testDb() !sqlite.Db {
    return sqlite.Db.init(.{
        .mode = .Memory,
        .open_flags = .{ .write = true, .create = true },
        .threading_mode = .Serialized,
    });
}

test "create, all, update and delete round-trip" {
    const allocator = std.testing.allocator;
    var db = try testDb();
    defer db.deinit();

    const service = ItemCrudService.init(&db);
    try service.ensureTable();
    try std.testing.expectEqual(@as(i64, 0), try service.count());

    try service.create("widget", 5);
    try service.create("gadget", 50);
    try std.testing.expectEqual(@as(i64, 2), try service.count());

    const rows = try service.all(allocator);
    defer allocator.free(rows);
    defer for (rows) |row| allocator.free(row.name);
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqualStrings("widget", rows[0].name);
    try std.testing.expectEqual(@as(i64, 50), rows[1].price);

    const found = try service.find(allocator, 1);
    try std.testing.expect(found != null);
    defer allocator.free(found.?.name);
    try std.testing.expectEqualStrings("widget", found.?.name);

    try service.update(1, "widget-pro", 15);
    const updated = try service.find(allocator, 1);
    try std.testing.expect(updated != null);
    defer allocator.free(updated.?.name);
    try std.testing.expectEqualStrings("widget-pro", updated.?.name);
    try std.testing.expectEqual(@as(i64, 15), updated.?.price);

    try service.delete(1);
    try std.testing.expectEqual(@as(i64, 1), try service.count());
    try std.testing.expectEqual(@as(?Item, null), try service.find(allocator, 1));
}
