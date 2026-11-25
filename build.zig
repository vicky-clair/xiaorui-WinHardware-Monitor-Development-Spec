//! WinHardware Monitor 构建脚本（锁定 Zig 0.15.2，目标平台 Windows 10/11 x64）。
//! 负责静态编译 SQLite 3.53.2、链接 zgui (Dear ImGui + ImPlot) / zglfw / zopengl、
//! 构建主桌面程序（Windows GUI 子系统无黑框）、P0 验证工具以及全部单元测试。
const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 锁定第三方依赖（版本与提交哈希记录在 build.zig.zon）
    const zglfw_dep = b.dependency("zglfw", .{
        .target = target,
        .optimize = optimize,
    });
    const zopengl_dep = b.dependency("zopengl", .{
        .target = target,
    });
    const zgui_dep = b.dependency("zgui", .{
        .target = target,
        .optimize = optimize,
        .backend = .glfw_opengl3,
        .with_implot = true,
        .shared = false,
    });
    const sqlite3_dep = b.dependency("sqlite3", .{});

    // 将 SQLite amalgamation C 源码编译为静态库（线程安全、禁用动态扩展加载）
    const sqlite_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    sqlite_mod.addIncludePath(sqlite3_dep.path(""));
    sqlite_mod.addCSourceFile(.{
        .file = sqlite3_dep.path("sqlite3.c"),
        .flags = &.{
            "-DSQLITE_THREADSAFE=1",
            "-DSQLITE_ENABLE_FTS5=0",
            "-DSQLITE_OMIT_LOAD_EXTENSION=1",
            "-DSQLITE_DQS=0",
            "-fno-sanitize=undefined",
        },
    });
    const sqlite_lib = b.addLibrary(.{
        .name = "sqlite3",
        .linkage = .static,
        .root_module = sqlite_mod,
    });

    // 主桌面程序（winhardware-monitor.exe）
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    wireModules(exe_mod, zgui_dep, zglfw_dep, zopengl_dep, sqlite3_dep, sqlite_lib);

    const exe = b.addExecutable(.{
        .name = "winhardware-monitor",
        .root_module = exe_mod,
    });
    // 使用 Windows GUI 子系统，双击启动时不弹出多余的黑色终端窗口
    if (target.result.os.tag == .windows) {
        exe.subsystem = .Windows;
    }
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "运行 WinHardware Monitor 主程序");
    run_step.dependOn(&run_cmd.step);

    // P0 命令行硬件与技术栈自检工具（仅 Windows 目标构建）
    if (target.result.os.tag == .windows) {
        const verify_mod = b.createModule(.{
            .root_source_file = b.path("src/verify_p0.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        wireModules(verify_mod, zgui_dep, zglfw_dep, zopengl_dep, sqlite3_dep, sqlite_lib);

        const verify_exe = b.addExecutable(.{
            .name = "verify-p0",
            .root_module = verify_mod,
        });
        b.installArtifact(verify_exe);

        const verify_run = b.addRunArtifact(verify_exe);
        verify_run.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            verify_run.addArgs(args);
        }
        const verify_step = b.step("verify-p0", "运行 P0 硬件接口与权限自检工具");
        verify_step.dependOn(&verify_run.step);
    }

    // 全模块自动化单元测试（zig build test，Windows / Linux 跨平台运行）
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/root_tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.addIncludePath(sqlite3_dep.path(""));
    test_mod.linkLibrary(sqlite_lib);
    linkPlatformLibs(test_mod, false);

    const unit_tests = b.addTest(.{
        .root_module = test_mod,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "运行全部单元测试");
    test_step.dependOn(&run_unit_tests.step);
}

fn wireModules(
    mod: *std.Build.Module,
    zgui_dep: *std.Build.Dependency,
    zglfw_dep: *std.Build.Dependency,
    zopengl_dep: *std.Build.Dependency,
    sqlite3_dep: *std.Build.Dependency,
    sqlite_lib: *std.Build.Step.Compile,
) void {
    mod.addImport("zgui", zgui_dep.module("root"));
    mod.addImport("zglfw", zglfw_dep.module("root"));
    mod.addImport("zopengl", zopengl_dep.module("root"));
    mod.addIncludePath(sqlite3_dep.path(""));

    mod.linkLibrary(zgui_dep.artifact("imgui"));
    mod.linkLibrary(zglfw_dep.artifact("glfw"));
    mod.linkLibrary(sqlite_lib);

    linkPlatformLibs(mod, true);
}

fn linkPlatformLibs(mod: *std.Build.Module, with_gui: bool) void {
    if (mod.resolved_target) |t| {
        if (t.result.os.tag == .windows) {
            mod.linkSystemLibrary("user32", .{});
            mod.linkSystemLibrary("gdi32", .{});
            mod.linkSystemLibrary("shell32", .{});
            mod.linkSystemLibrary("advapi32", .{});
            mod.linkSystemLibrary("opengl32", .{});
            mod.linkSystemLibrary("pdh", .{});
            mod.linkSystemLibrary("dxgi", .{});
            mod.linkSystemLibrary("ole32", .{});
            mod.linkSystemLibrary("setupapi", .{});
            mod.linkSystemLibrary("cfgmgr32", .{});
            mod.linkSystemLibrary("powrprof", .{});
            mod.linkSystemLibrary("dwmapi", .{});
            mod.linkSystemLibrary("ntdll", .{});
        } else if (t.result.os.tag == .linux) {
            // Linux 下 zglfw 在运行时通过 dlopen 动态加载 libX11 / libGL / libEGL 等图形库，
            // 仅 zglfw 静态库声明了 -lX11；当在 Linux 宿主机使用 -Dtarget=x86_64-linux-gnu.2.17 锁定低版本 glibc 时，
            // 补充 Debian/Ubuntu (/usr/lib/x86_64-linux-gnu) 与 Fedora/RHEL (/usr/lib64) 库搜索路径以完成链接（实际运行时零 X11 硬依赖）。
            _ = with_gui;
            if (builtin.os.tag == .linux and !t.query.isNative()) {
                mod.addLibraryPath(.{ .cwd_relative = "/usr/lib/x86_64-linux-gnu" });
                mod.addLibraryPath(.{ .cwd_relative = "/usr/lib64" });
                mod.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
            }
            mod.linkSystemLibrary("m", .{});
            mod.linkSystemLibrary("pthread", .{});
            mod.linkSystemLibrary("dl", .{});
        }
    }
}
