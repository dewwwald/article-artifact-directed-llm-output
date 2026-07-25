const sqlite = @import("sqlite");

pub fn open(path: [:0]const u8) !sqlite.Db {
    return sqlite.Db.init(.{
        .mode = sqlite.Db.Mode{ .File = path },
        .open_flags = .{ .write = true, .create = true },
        .threading_mode = .Serialized,
    });
}
