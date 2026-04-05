pub const packages = struct {
    pub const @"../../earley" = struct {
        pub const build_root = "C:\\projects\\cobra-language\\zig-compiler\\../../earley";
        pub const build_zig = @import("../../earley");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
        };
    };
};

pub const root_deps: []const struct { []const u8, []const u8 } = &.{
    .{ "earley", "../../earley" },
};
