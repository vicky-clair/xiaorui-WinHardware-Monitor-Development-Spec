//! WinHardware Monitor 主程序入口（支持 Windows 10/11 x64 与 Linux x86_64）。
//! 支持桌面 GUI 与无界面 CLI 双运行形态：
//! - 默认启动桌面 GUI（带单实例保障、深/浅双主题与渲染节能）；
//! - 传入 `--cli` / `--info` / `--bench <cpu|mem|disk|all>` 时直接进入无界面硬件监测与基准测试模式（无需 X11/OpenGL）。
const std = @import("std");
const SingleInstance = @import("platform/single_instance.zig").SingleInstance;
const window = @import("gui/window.zig");
const cli = @import("cli.zig");
const i18n = @import("core/i18n.zig");

pub fn main() !void {
    // 通用内存分配器：退出时由 defer 自动检查资源释放
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 解析命令行参数
    var smoke_test = false;
    var wait_mutex = false;
    var is_autostart = false;
    var run_cli = false;
    var cli_opts = cli.CliOptions{};

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next(); // 跳过程序自身路径
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--smoke-test")) {
            smoke_test = true;
        } else if (std.mem.eql(u8, arg, "--wait-mutex")) {
            wait_mutex = true;
        } else if (std.mem.eql(u8, arg, "--autostart")) {
            is_autostart = true;
        } else if (std.mem.eql(u8, arg, "--cli") or std.mem.eql(u8, arg, "--info")) {
            run_cli = true;
            cli_opts.show_info = true;
        } else if (std.mem.eql(u8, arg, "--bench")) {
            run_cli = true;
            cli_opts.bench_target = args.next() orelse "all";
        } else if (std.mem.eql(u8, arg, "--duration")) {
            if (args.next()) |v| cli_opts.duration_s = std.fmt.parseInt(u32, v, 10) catch 10;
        } else if (std.mem.eql(u8, arg, "--threads")) {
            if (args.next()) |v| cli_opts.threads = std.fmt.parseInt(u32, v, 10) catch 0;
        } else if (std.mem.eql(u8, arg, "--mem-mb")) {
            if (args.next()) |v| cli_opts.mem_mb = std.fmt.parseInt(u32, v, 10) catch 128;
        } else if (std.mem.eql(u8, arg, "--disk-mb")) {
            if (args.next()) |v| cli_opts.disk_mb = std.fmt.parseInt(u32, v, 10) catch 128;
        } else if (std.mem.eql(u8, arg, "--cutoff-c")) {
            if (args.next()) |v| cli_opts.cutoff_c = std.fmt.parseFloat(f64, v) catch 90.0;
        } else if (std.mem.eql(u8, arg, "--disk-dir")) {
            if (args.next()) |v| cli_opts.disk_dir = v;
        } else if (std.mem.eql(u8, arg, "--no-gentle")) {
            cli_opts.gentle_mode = false;
        } else if (std.mem.eql(u8, arg, "--lang")) {
            if (args.next()) |v| i18n.setLanguage(i18n.Language.fromCode(v));
        }
    }

    // 无界面 CLI 硬件信息与准确基准测试模式（适用于 Linux 服务器 / SSH / 自动化验收）
    if (run_cli) {
        try cli.runCli(allocator, cli_opts);
        return;
    }

    // 单实例保障（规范 §2.6；管理员重启时允许最多等待 3 秒旧进程释放互斥体）
    var single = SingleInstance{};
    defer single.release();
    if (!smoke_test) {
        var attempts: usize = if (wait_mutex) 30 else 1;
        var acquired = false;
        while (attempts > 0) : (attempts -= 1) {
            if (single.acquire() == .primary) {
                acquired = true;
                break;
            }
            if (wait_mutex) {
                std.Thread.sleep(100 * std.time.ns_per_ms);
            }
        }
        if (!acquired) {
            SingleInstance.activateExistingWindow();
            return;
        }
    }

    // 开机自启时短暂等待 Windows 资源管理器（托盘）与显卡 OpenGL 驱动就绪，避免登录瞬间启动失败或漏挂托盘
    if (is_autostart and !smoke_test) {
        std.Thread.sleep(2000 * std.time.ns_per_ms);
    }

    try window.runMainWindow(allocator, .{
        .smoke_test = smoke_test,
        .start_minimized = is_autostart,
        .single_instance = if (smoke_test) null else &single,
    });
}
