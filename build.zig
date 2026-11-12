const std = @import("std");
const Translator = @import("translate_c").Translator;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zmx = b.dependency("zmx", .{
        .target = target,
        .optimize = optimize,
    });

    const sqlite = b.dependency("sqlite", .{});

    const sqlite_c: Translator = .init(b.dependency("translate_c", .{}), .{
        .c_source_file = sqlite.path("sqlite3.h"),
        .target = target,
        .optimize = optimize,
    });

    const root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zmx", .module = zmx.module("zmx") },
            .{ .name = "sqlite", .module = sqlite_c.mod },
        },
    });

    root.addCSourceFile(.{
        .file = sqlite.path("sqlite3.c"),
        .flags = &.{ "-DSQLITE_DQS=0", "-DSQLITE_THREADSAFE=0", "-DSQLITE_OMIT_LOAD_EXTENSION" },
    });

    const exe = b.addExecutable(.{
        .name = "drako",
        .root_module = root,
    });

    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run drako").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = root });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);
}
