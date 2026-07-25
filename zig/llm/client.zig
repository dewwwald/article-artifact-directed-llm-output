const std = @import("std");
const json = std.json;

pub const ChatOptions = struct {
    base_url: []const u8 = "http://127.0.0.1:1234",
    model: []const u8 = "google/gemma-4-e4b",
};

/// Sends a single-turn chat completion request to an OpenAI-compatible
/// endpoint (LM Studio's local server) and returns the assistant's message
/// content as newly allocated bytes. Non-streaming: the whole response is
/// read before returning.
///
/// `response_schema` is passed through as `response_format: {type:
/// "json_schema", ...}`, which LM Studio uses to constrain token generation
/// directly (grammar-based sampling), not just as a hint - so this is real
/// guided decoding, on top of which we still validate the result ourselves
/// since structured output isn't guaranteed reliable on small models.
pub fn chat(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: ChatOptions,
    system_prompt: []const u8,
    user_prompt: []const u8,
    response_schema: json.Value,
) ![]u8 {
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    var body_writer: std.Io.Writer.Allocating = .init(allocator);
    defer body_writer.deinit();
    try json.Stringify.value(.{
        .model = options.model,
        .messages = &.{
            .{ .role = "system", .content = system_prompt },
            .{ .role = "user", .content = user_prompt },
        },
        .stream = false,
        .response_format = .{
            .type = "json_schema",
            .json_schema = .{
                .name = "ast",
                .strict = true,
                .schema = response_schema,
            },
        },
    }, .{}, &body_writer.writer);

    const url = try std.fmt.allocPrint(allocator, "{s}/v1/chat/completions", .{options.base_url});
    defer allocator.free(url);

    var response_writer: std.Io.Writer.Allocating = .init(allocator);
    defer response_writer.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = body_writer.writer.buffered(),
        .headers = .{ .content_type = .{ .override = "application/json" } },
        .response_writer = &response_writer.writer,
    });
    if (result.status != .ok) return error.UnexpectedResponseStatus;

    const parsed = try json.parseFromSlice(json.Value, allocator, response_writer.writer.buffered(), .{});
    defer parsed.deinit();

    const content = parsed.value.object.get("choices").?
        .array.items[0].object.get("message").?
        .object.get("content").?.string;
    return allocator.dupe(u8, content);
}
