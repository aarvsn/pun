// pun — a BYOK, security-first AI coding agent, written in Zig.
// build.zig: build script for `pun`, `pun-test`, and modules.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- Main `pun` executable (CLI + TUI) ---
    const exe = b.addExecutable(.{
        .name = "pun",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.linkLibC(); // for std.http TLS via system libssl
    b.installArtifact(exe);

    // --- Run step ---
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run pun");
    run_step.dependOn(&run_cmd.step);

    // --- Tests ---
    const tests = b.addTest(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    tests.linkLibC();
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // --- fmt / lint ---
    const fmt_step = b.addFmt(.{
        .paths = &.{
            "src",
            "build.zig",
            "build.zig.zon",
        },
    });
    b.step("fmt", "Format source").dependOn(&fmt_step.step);
}
