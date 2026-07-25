const ValidatorStatus = @import("../llm/prefix_validator.zig").Status;

/// One step on the guided-decoding timeline. Plain data (no behavior) so any
/// renderer - terminal today, a websocket-fed web renderer later - can turn
/// the same sequence of events into its own presentation, and so events can
/// be serialized (e.g. to JSON) without extra plumbing.
pub const Event = union(enum) {
    prompt_sent: []const u8,
    response_received: []const u8,
    token_fed: struct { byte: u8, index: usize },
    validation_result: ValidatorStatus,
    query_matched: []const u8,
    query_rejected: []const u8,
    retrying: struct { attempt: usize, max_attempts: usize, reason: []const u8 },
    gave_up: struct { attempts: usize },
};
