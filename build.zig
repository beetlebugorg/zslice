const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The Zig module, for Zig programs that embed zslice.
    const mod = b.addModule("zslice", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // The command line tool.
    const exe = b.addExecutable(.{
        .name = "zslice",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zslice", .module = mod }},
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the command line tool");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    // The C library: static and shared, with the header.
    const c_mod = b.createModule(.{
        .root_source_file = b.path("src/c_api.zig"),
        .target = target,
        .optimize = optimize,
    });
    const static_lib = b.addLibrary(.{ .name = "zslice", .linkage = .static, .root_module = c_mod });
    const shared_lib = b.addLibrary(.{ .name = "zslice", .linkage = .dynamic, .root_module = c_mod });
    const lib_step = b.step("lib", "Build the C library");
    lib_step.dependOn(&b.addInstallArtifact(static_lib, .{}).step);
    lib_step.dependOn(&b.addInstallArtifact(shared_lib, .{}).step);
    lib_step.dependOn(&b.addInstallHeaderFile(b.path("include/zslice.h"), "zslice.h").step);

    // The wasm module. It exports the C API. It has no threads.
    const wasm = b.addExecutable(.{
        .name = "zslice",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/c_api.zig"),
            .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding }),
            .optimize = if (optimize == .Debug) .ReleaseSmall else optimize,
        }),
    });
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    const wasm_step = b.step("wasm", "Build zslice.wasm into zig-out/web");
    const wasm_install = b.addInstallArtifact(wasm, .{ .dest_dir = .{ .override = .{ .custom = "web" } } });
    wasm_step.dependOn(&wasm_install.step);
    wasm_step.dependOn(&b.addInstallFileWithDir(b.path("web/zslice.mjs"), .{ .custom = "web" }, "zslice.mjs").step);

    // Tests.
    const mod_tests = b.addTest(.{ .root_module = mod });
    const c_tests = b.addTest(.{ .root_module = c_mod });
    const test_step = b.step("test", "Run the unit tests");
    test_step.dependOn(&b.addRunArtifact(mod_tests).step);
    test_step.dependOn(&b.addRunArtifact(c_tests).step);
}
