// Define a basic spec for an AST that defines AND OR operations on data
// - use array and in those a map of "operand" enum (AND, OR), "action" enum (EQUALS, CONTAINS, ISNOT)
// and "path"; "$.json.formatted[0].path"
// - Is not contains and another AST definition set but not ISNOT
// - Given a json object the ast will search the json object using the operands to compute if the object matches
// when a array is defined on the path $.[] for example it will iterate over all array items.
// - AST can be nested so that path $.[] will have a subsequent check on a then keyword
// that will nest a json path meaning $.name on then would be $.[].name where the as might perform an AND OR operation matching and not matching something.

// RFC create a spec ckecker that will lint the 0-n to determine if the AST is correctly formatted.

// Building an LLM integration here where we use LM studio gemma with a system prompt to generate from a user prompt a thing they want to match that fits the ast. We will give dummy json data and the ast will then compile

const std = @import("std");

const db_connection = @import("db/connection.zig");
const ItemCrudService = @import("db/repository/item_crud_service.zig").ItemCrudService;
const web_server = @import("web/server.zig");

/// Seeds the two original demo rows the first time the table is empty,
/// so a fresh items.db behaves like the old hardcoded example.
fn seedIfEmpty(service: ItemCrudService) !void {
    if (try service.count() > 0) return;
    try service.create("widget", 5);
    try service.create("gadget", 50);
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var db = try db_connection.open("items.db");
    defer db.deinit();

    const items = ItemCrudService.init(&db);
    try items.ensureTable();
    try seedIfEmpty(items);

    var threaded = std.Io.Threaded.init(gpa.allocator(), .{});
    defer threaded.deinit();
    const io = threaded.io();

    try web_server.run(allocator, io, items, 8080);
}

test {
    _ = @import("db/repository/item_crud_service.zig");
    _ = @import("ast/matcher.zig");
    _ = @import("llm/prefix_validator.zig");
    _ = @import("ast/doc.zig");
    _ = @import("ast/json_schema.zig");
}
