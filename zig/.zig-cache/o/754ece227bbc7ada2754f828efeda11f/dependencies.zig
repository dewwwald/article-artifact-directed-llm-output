pub const packages = struct {
    pub const @"N-V-__8AAH-mpwB7g3MnqYU-ooUBF1t99RP27dZ9addtMVXD" = struct {
        pub const build_root = "/Users/dewaldlaubscher/Projects/directed-llm-output/zig/zig-pkg/N-V-__8AAH-mpwB7g3MnqYU-ooUBF1t99RP27dZ9addtMVXD";
        pub const deps: []const struct { []const u8, []const u8 } = &.{};
    };
    pub const @"sqlite-3.48.0-F2R_azCQDgBGaWDIX4g2vxKpuqzYEQOOfAeJGMNocPu0" = struct {
        pub const build_root = "/Users/dewaldlaubscher/Projects/directed-llm-output/zig/zig-pkg/sqlite-3.48.0-F2R_azCQDgBGaWDIX4g2vxKpuqzYEQOOfAeJGMNocPu0";
        pub const build_zig = @import("sqlite-3.48.0-F2R_azCQDgBGaWDIX4g2vxKpuqzYEQOOfAeJGMNocPu0");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
            .{ "sqlite", "N-V-__8AAH-mpwB7g3MnqYU-ooUBF1t99RP27dZ9addtMVXD" },
        };
    };
};

pub const root_deps: []const struct { []const u8, []const u8 } = &.{
    .{ "sqlite", "sqlite-3.48.0-F2R_azCQDgBGaWDIX4g2vxKpuqzYEQOOfAeJGMNocPu0" },
};
