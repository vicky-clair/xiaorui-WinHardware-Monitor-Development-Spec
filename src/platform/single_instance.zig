const std = @import("std");
const win32 = @import("../providers/windows/win32.zig");

/// 单实例互斥体（规范 §2.6）。
/// 再次启动时定位已运行实例的窗口并激活到前台，随后安全退出。
pub const SingleInstance = struct {
    mutex: ?win32.HANDLE = null,

    pub const MUTEX_NAME = std.unicode.utf8ToUtf16LeStringLiteral("Local\\WinHardwareMonitor_SingleInstance_v1");
    pub const WINDOW_TITLE = std.unicode.utf8ToUtf16LeStringLiteral("WinHardware Monitor");

    pub const AcquireResult = enum {
        primary,
        already_running,
    };

    pub fn acquire(self: *SingleInstance) AcquireResult {
        return self.acquireNamed(MUTEX_NAME);
    }

    pub fn acquireNamed(self: *SingleInstance, name: win32.LPCWSTR) AcquireResult {
        const handle = win32.CreateMutexW(null, 1, name);
        if (handle == null) return .primary;
        if (win32.GetLastError() == win32.ERROR_ALREADY_EXISTS) {
            _ = win32.CloseHandle(handle.?);
            return .already_running;
        }
        self.mutex = handle;
        return .primary;
    }

    pub fn activateExistingWindow() void {
        if (win32.FindWindowW(null, WINDOW_TITLE)) |hwnd| {
            if (win32.IsIconic(hwnd) != 0) {
                _ = win32.ShowWindow(hwnd, win32.SW_RESTORE);
            } else {
                _ = win32.ShowWindow(hwnd, win32.SW_SHOW);
            }
            _ = win32.SetForegroundWindow(hwnd);
        }
    }

    pub fn release(self: *SingleInstance) void {
        if (self.mutex) |h| {
            _ = win32.ReleaseMutex(h);
            _ = win32.CloseHandle(h);
            self.mutex = null;
        }
    }
};

test "SingleInstance prevents duplicate acquisition and releases cleanly" {
    const test_mutex = std.unicode.utf8ToUtf16LeStringLiteral("Local\\WinHardwareMonitor_UnitTest_SingleInstance_v1");
    var first = SingleInstance{};
    defer first.release();

    try std.testing.expectEqual(SingleInstance.AcquireResult.primary, first.acquireNamed(test_mutex));

    var second = SingleInstance{};
    defer second.release();
    try std.testing.expectEqual(SingleInstance.AcquireResult.already_running, second.acquireNamed(test_mutex));

    first.release();

    var third = SingleInstance{};
    defer third.release();
    try std.testing.expectEqual(SingleInstance.AcquireResult.primary, third.acquireNamed(test_mutex));
}
