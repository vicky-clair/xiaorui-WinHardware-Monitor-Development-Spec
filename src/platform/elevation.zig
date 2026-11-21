const std = @import("std");
const builtin = @import("builtin");
const win32 = @import("../providers/windows/win32.zig");

/// 显式管理员提权重启（规范 §1.2 / §9：禁止静默提权，仅由用户点击触发 UAC）。
/// 传入 --wait-mutex 参数，让新提权实例平滑等待旧进程释放单实例互斥体。
pub fn relaunchAsAdministrator(parent_hwnd: ?win32.HWND) bool {
    if (builtin.os.tag != .windows) return false;
    var exe_path: [1024]u16 = std.mem.zeroes([1024]u16);
    const len = win32.GetModuleFileNameW(null, @ptrCast(&exe_path), exe_path.len - 1);
    if (len == 0 or len >= exe_path.len) return false;
    exe_path[len] = 0;

    const verb = std.unicode.utf8ToUtf16LeStringLiteral("runas");
    const params = std.unicode.utf8ToUtf16LeStringLiteral("--wait-mutex");
    const res = win32.ShellExecuteW(
        parent_hwnd,
        verb,
        @ptrCast(&exe_path),
        params,
        null,
        win32.SW_SHOWNORMAL,
    );
    return if (res) |h| @intFromPtr(h) > 32 else false;
}

/// 显式按需启动独立隔离的 LibreHardwareMonitor 辅助进程（MPL-2.0，需用户点击触发 UAC）。
/// 优先在主程序同目录查找 `WinHardwareMonitor.LhmHelper.exe`。
pub fn launchLhmHelperAsAdministrator(allocator: std.mem.Allocator, parent_hwnd: ?win32.HWND) enum { launched, not_found, cancelled } {
    if (builtin.os.tag != .windows) return .not_found;
    var exe_w: [1024]u16 = std.mem.zeroes([1024]u16);
    const len = win32.GetModuleFileNameW(null, @ptrCast(&exe_w), exe_w.len - 1);
    if (len == 0 or len >= exe_w.len) return .not_found;

    const exe_utf8 = std.unicode.utf16LeToUtf8Alloc(allocator, exe_w[0..len]) catch return .not_found;
    defer allocator.free(exe_utf8);

    const exe_dir = std.fs.path.dirname(exe_utf8) orelse return .not_found;

    const candidates = [_][]const u8{
        "WinHardwareMonitor.LhmHelper.exe",
        "helpers\\lhm_bridge\\WinHardwareMonitor.LhmHelper.exe",
    };

    for (candidates) |rel| {
        const full = std.fs.path.join(allocator, &.{ exe_dir, rel }) catch continue;
        defer allocator.free(full);

        std.fs.accessAbsolute(full, .{}) catch continue;

        const full_w = std.unicode.utf8ToUtf16LeAllocZ(allocator, full) catch continue;
        defer allocator.free(full_w);
        const dir_w = std.unicode.utf8ToUtf16LeAllocZ(allocator, exe_dir) catch null;
        defer if (dir_w) |dw| allocator.free(dw);

        const verb = std.unicode.utf8ToUtf16LeStringLiteral("runas");
        const helper_params = std.unicode.utf8ToUtf16LeStringLiteral("--from-host");
        const res = win32.ShellExecuteW(
            parent_hwnd,
            verb,
            full_w.ptr,
            helper_params,
            if (dir_w) |dw| dw.ptr else null,
            win32.SW_HIDE,
        );
        if (res) |h| {
            if (@intFromPtr(h) > 32) return .launched;
        }
        return .cancelled;
    }

    return .not_found;
}
