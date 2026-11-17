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
    addLicenses(b, mod);

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
    // The C library links libc, so that its threads are pthreads. A host
    // program (for example the GTK app) uses libc threads, and Zig threads
    // without libc do not set up the thread state that libc expects.
    const c_mod = b.createModule(.{
        .root_source_file = b.path("src/c_api.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addLicenses(b, c_mod);
    // The Vulkan headers of the renderer (vendor/vulkan, Apache-2.0).
    c_mod.addIncludePath(b.path("vendor/vulkan/include"));
    const static_lib = b.addLibrary(.{ .name = "zslice", .linkage = .static, .root_module = c_mod });
    const shared_lib = b.addLibrary(.{ .name = "zslice", .linkage = .dynamic, .root_module = c_mod });
    const lib_step = b.step("lib", "Build the C library");
    lib_step.dependOn(&b.addInstallArtifact(static_lib, .{}).step);
    lib_step.dependOn(&b.addInstallArtifact(shared_lib, .{}).step);
    lib_step.dependOn(&b.addInstallHeaderFile(b.path("include/zslice.h"), "zslice.h").step);
    lib_step.dependOn(&b.addInstallHeaderFile(b.path("include/zslice-app.h"), "zslice-app.h").step);

    // The wasm module. It exports the C API. It has no threads.
    const wasm = b.addExecutable(.{
        .name = "zslice",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/c_api.zig"),
            .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding }),
            .optimize = if (optimize == .Debug) .ReleaseSmall else optimize,
        }),
    });
    addLicenses(b, wasm.root_module);
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    const wasm_step = b.step("wasm", "Build zslice.wasm into zig-out/web");
    const wasm_install = b.addInstallArtifact(wasm, .{ .dest_dir = .{ .override = .{ .custom = "web" } } });
    wasm_step.dependOn(&wasm_install.step);
    wasm_step.dependOn(&b.addInstallFileWithDir(b.path("web/zslice.mjs"), .{ .custom = "web" }, "zslice.mjs").step);

    // The web app (web/app): the page, its scripts, and zslice.wasm, in
    // zig-out/web/app. See web/app/README.md.
    const web_step = b.step("web", "Build the web app into zig-out/web/app");
    web_step.dependOn(&b.addInstallArtifact(wasm, .{ .dest_dir = .{ .override = .{ .custom = "web/app" } } }).step);
    web_step.dependOn(&b.addInstallDirectory(.{
        .source_dir = b.path("web/app"),
        .install_dir = .{ .custom = "web" },
        .install_subdir = "app",
        .exclude_extensions = &.{ ".md", ".mjs", ".py" },
    }).step);

    // Tests.
    const mod_tests = b.addTest(.{ .root_module = mod });
    // The C API tests link libc. The self-hosted Debug linker does not
    // handle a relocation in the glibc start files, so these use LLVM.
    const c_tests = b.addTest(.{ .root_module = c_mod, .use_llvm = true });
    const test_step = b.step("test", "Run the unit tests");
    test_step.dependOn(&b.addRunArtifact(mod_tests).step);
    test_step.dependOn(&b.addRunArtifact(c_tests).step);
    // The wasm module must also compile.
    test_step.dependOn(&wasm.step);
}

/// The license texts that the app core embeds for its Licenses screen
/// (see `licenses` in src/app.zig).
fn addLicenses(b: *std.Build, m: *std.Build.Module) void {
    const files = [_][2][]const u8{
        .{ "license_zslice", "LICENSE" },
        .{ "license_zig", "licenses/zig-std-MIT.txt" },
        .{ "license_musl", "licenses/musl-MIT.txt" },
        .{ "license_go", "licenses/go-BSD-3-Clause.txt" },
        .{ "license_arm", "licenses/arm-optimized-routines.txt" },
        .{ "license_boost", "licenses/boost-BSL-1.0.txt" },
    };
    for (files) |f| m.addAnonymousImport(f[0], .{ .root_source_file = b.path(f[1]) });
}
