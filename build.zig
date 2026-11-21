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
    // -Dcompiler-rt puts the compiler-rt of Zig (std/compiler_rt, MIT, as
    // the rest of the Zig standard library) in the static library: the
    // helpers of f128 math that std.json and std.fmt.parseFloat call. The
    // Apple linker has no libgcc to give them, so macos/build-core.sh sets it.
    if (b.option(bool, "compiler-rt", "Bundle compiler-rt in the static library") orelse false) static_lib.bundle_compiler_rt = true;
    const shared_lib = b.addLibrary(.{ .name = "zslice", .linkage = .dynamic, .root_module = c_mod });
    const lib_step = b.step("lib", "Build the C library");
    lib_step.dependOn(&b.addInstallArtifact(static_lib, .{}).step);
    // On Windows the static library and the import library of a DLL have
    // the same name, zslice.lib. The Windows shell links the static one.
    if (target.result.os.tag != .windows) lib_step.dependOn(&b.addInstallArtifact(shared_lib, .{}).step);
    lib_step.dependOn(&b.addInstallHeaderFile(b.path("include/zslice.h"), "zslice.h").step);
    lib_step.dependOn(&b.addInstallHeaderFile(b.path("include/zslice-app.h"), "zslice-app.h").step);

    // The wasm module. It exports the C API. It has no threads.
    // -Dwasm-optimize sets its optimize mode. -Dwasm-cpu sets its CPU
    // features, for example -Dwasm-cpu=baseline+simd128+bulk_memory.
    const wasm_optimize = b.option(std.builtin.OptimizeMode, "wasm-optimize", "The optimize mode of the wasm module") orelse
        (if (optimize == .Debug) .ReleaseFast else optimize);
    const wasm_cpu = b.option([]const u8, "wasm-cpu", "The CPU model and features of the wasm module") orelse "baseline";
    // The debug data is 7 MB of a ReleaseFast module. -Dwasm-strip=false
    // keeps it, for a profile with function names.
    const wasm_strip = b.option(bool, "wasm-strip", "Leave the debug data out of the wasm module (default: true)") orelse true;
    const wasm = addWasm(b, "zslice", wasm_optimize, wasm_cpu, wasm_strip, false);
    const wasm_step = b.step("wasm", "Build zslice.wasm into zig-out/web");
    const wasm_install = b.addInstallArtifact(wasm, .{ .dest_dir = .{ .override = .{ .custom = "web" } } });
    wasm_step.dependOn(&wasm_install.step);
    wasm_step.dependOn(&b.addInstallFileWithDir(b.path("web/zslice.mjs"), .{ .custom = "web" }, "zslice.mjs").step);

    // The wasm module with threads (zslice-mt.wasm), for a page that is
    // cross-origin isolated. It imports a shared memory. See
    // web/app/README.md.
    const wasm_mt = addWasm(b, "zslice-mt", wasm_optimize, b.fmt("{s}+atomics+bulk_memory", .{wasm_cpu}), wasm_strip, true);

    // The web app (web/app): the page, its scripts, and zslice.wasm, in
    // zig-out/web/app. See web/app/README.md.
    const web_step = b.step("web", "Build the web app into zig-out/web/app");
    web_step.dependOn(&b.addInstallArtifact(wasm, .{ .dest_dir = .{ .override = .{ .custom = "web/app" } } }).step);
    web_step.dependOn(&b.addInstallArtifact(wasm_mt, .{ .dest_dir = .{ .override = .{ .custom = "web/app" } } }).step);
    web_step.dependOn(&b.addInstallDirectory(.{
        .source_dir = b.path("web/app"),
        .install_dir = .{ .custom = "web" },
        .install_subdir = "app",
        .exclude_extensions = &.{ ".md", ".mjs", ".py" },
    }).step);
    // The printer library: the picker loads it when it opens (the wasm
    // module does not embed it).
    web_step.dependOn(&b.addInstallFileWithDir(b.path("src/printers/library.txt"), .{ .custom = "web/app" }, "printers.txt").step);
    // The module of the G-code viewer (web/view). The site is the docs
    // folder with this folder on top, so the viewer page of the docs runs
    // its demo from these files: zslice-view.js, view.js, gl.js, wasm.js,
    // input.js, and zslice.wasm.
    web_step.dependOn(&b.addInstallFileWithDir(b.path("web/view/zslice-view.js"), .{ .custom = "web/app" }, "zslice-view.js").step);
    // The bed models of the printers: the page loads the files of the
    // current printer from beds/ (see web/app/README.md).
    web_step.dependOn(&b.addInstallDirectory(.{
        .source_dir = b.path("src/printers/beds"),
        .install_dir = .{ .custom = "web/app" },
        .install_subdir = "beds",
    }).step);

    // The embeddable G-code viewer (web/view) in zig-out/web/view: its
    // module, the files of the web app that it uses, zslice.wasm (no
    // threads), and an example page. See docs/embedding/viewer.md.
    const view_step = b.step("web-view", "Build the embeddable G-code viewer into zig-out/web/view");
    const view_dir: std.Build.InstallDir = .{ .custom = "web/view" };
    view_step.dependOn(&b.addInstallArtifact(wasm, .{ .dest_dir = .{ .override = view_dir } }).step);
    for ([_][]const u8{ "web/view/zslice-view.js", "web/view/example.html", "web/app/view.js", "web/app/gl.js", "web/app/wasm.js", "web/app/input.js", "LICENSE" }) |f| {
        view_step.dependOn(&b.addInstallFileWithDir(b.path(f), view_dir, std.fs.path.basename(f)).step);
    }

    // Tests.
    // -Dtest-filter=TEXT runs only the tests with TEXT in their name.
    const filter = b.option([]const u8, "test-filter", "Run only the tests with this text in their name");
    const filters: []const []const u8 = if (filter) |f| b.allocator.dupe([]const u8, &.{f}) catch @panic("OOM") else &.{};
    const mod_tests = b.addTest(.{ .root_module = mod, .filters = filters });
    // The C API tests link libc. The self-hosted Debug linker does not
    // handle a relocation in the glibc start files, so these use LLVM.
    const c_tests = b.addTest(.{ .root_module = c_mod, .use_llvm = true, .filters = filters });
    const test_step = b.step("test", "Run the unit tests");
    test_step.dependOn(&b.addRunArtifact(mod_tests).step);
    test_step.dependOn(&b.addRunArtifact(c_tests).step);
    // The wasm module must also compile.
    test_step.dependOn(&wasm.step);
}

/// The memory limits of the wasm module with threads. A shared memory
/// needs a maximum. wasm.js makes the memory with the same numbers.
const wasm_mt_initial = 64 << 20;
// The most memory of the web app: 4 GiB, the limit of wasm32 (65536 pages).
const wasm_mt_max = 4 << 30;

/// A wasm module of the C API. `threads`: with atomics and a shared memory
/// that the host makes (see src/parallel.zig).
fn addWasm(b: *std.Build, name: []const u8, optimize: std.builtin.OptimizeMode, cpu: []const u8, strip: bool, threads: bool) *std.Build.Step.Compile {
    const query = std.Target.Query.parse(.{ .arch_os_abi = "wasm32-freestanding", .cpu_features = cpu }) catch @panic("bad -Dwasm-cpu");
    const wasm = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/c_api.zig"),
            .target = b.resolveTargetQuery(query),
            .optimize = optimize,
            .single_threaded = !threads,
            .strip = strip,
        }),
    });
    addLicenses(b, wasm.root_module);
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    if (threads) {
        wasm.shared_memory = true;
        wasm.import_memory = true;
        wasm.initial_memory = wasm_mt_initial;
        wasm.max_memory = wasm_mt_max;
    }
    return wasm;
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
        .{ "license_lgpl", "licenses/lgpl-3.0.txt" },
        .{ "license_gpl", "licenses/gpl-3.0.txt" },
        .{ "license_ofl_inter", "licenses/ofl-1.1-inter.txt" },
    };
    for (files) |f| m.addAnonymousImport(f[0], .{ .root_source_file = b.path(f[1]) });
}
