//! WinHardware Monitor 主程序入口（Windows 10/11 x64）。
//! 负责解析启动参数（`--smoke-test` 冒烟测试、`--wait-mutex` 管理员重启平滑接管）、
//! 执行单实例命名互斥体检测，并在通过后启动主渲染窗口与后台硬件监控线程。
const std = @import("std");
const SingleInstance = @import("platform/single_instance.zig").SingleInstance;
const window = @import("gui/window.zig");

pub fn main() !void {
    // 通用内存分配器：退出时由 defer 自动检查资源释放
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 解析命令行参数
    var smoke_test = false;
    var wait_mutex = false;
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next(); // 跳过程序自身路径
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--smoke-test")) {
            smoke_test = true;
        } else if (std.mem.eql(u8, arg, "--wait-mutex")) {
            wait_mutex = true;
        }
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
            // 已有实例在运行时将其主窗口激活到前台，然后直接退出
            SingleInstance.activateExistingWindow();
            return;
        }
    }

    try window.runMainWindow(allocator, .{
        .smoke_test = smoke_test,
        .single_instance = if (smoke_test) null else &single,
    });
}
