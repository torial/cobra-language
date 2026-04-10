const std = @import("std");
pub fn build(b: *std.Build) void {
    const target   = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zgui_dep = b.dependency("zgui", .{
        .target   = target,
        .optimize = optimize,
        .backend  = .glfw_opengl3,
    });
    const zglfw_dep = b.dependency("zglfw", .{
        .target   = target,
        .optimize = optimize,
    });
    const zopengl_dep = b.dependency("zopengl", .{
        .target = target,
    });
    const app_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target           = target,
        .optimize         = optimize,
    });
    app_mod.addImport("zgui",    zgui_dep.module("root"));
    app_mod.addImport("zglfw",   zglfw_dep.module("root"));
    app_mod.addImport("zopengl", zopengl_dep.module("root"));
    const exe = b.addExecutable(.{
        .name        = "app",
        .root_module = app_mod,
    });
    exe.linkLibrary(zgui_dep.artifact("imgui"));
    exe.linkLibrary(zglfw_dep.artifact("glfw"));
    b.installArtifact(exe);
    const run_step = b.addRunArtifact(exe);
    b.step("run", "Run the app").dependOn(&run_step.step);
}
