const std = @import("std");
const builtin = @import("builtin");
const win32 = @import("../providers/windows/win32.zig");

/// 跨平台单实例保障（规范 §2.6：Windows 使用命名互斥体，Linux 使用 `/tmp` POSIX flock 文件锁）。
pub const SingleInstance = struct {
    mutex: ?win32.HANDLE = null,
    lock_fd: ?std.posix.fd_t = null,

    pub const MUTEX_NAME = std.unicode.utf8ToUtf16LeStringLiteral("Local\\WinHardwareMonitor_SingleInstance_v1");
    pub const WINDOW_TITLE = std.unicode.utf8ToUtf16LeStringLiteral("WinHardware Monitor");

    pub const AcquireResult = enum {
        primary,
        already_running,
    };

    pub fn acquire(self: *SingleInstance) AcquireResult {
        if (builtin.os.tag == .windows) {
            return self.acquireNamed(MUTEX_NAME);
        }
        return self.acquirePosixLock("/tmp/winhardware-monitor-single-instance.lock");
    }

    pub fn acquireNamed(self: *SingleInstance, name: win32.LPCWSTR) AcquireResult {
        if (builtin.os.tag != .windows) {
            return self.acquirePosixLock("/tmp/winhardware-monitor-unit-test.lock");
        }
        const handle = win32.CreateMutexW(null, 1, name);
        if (handle == null) return .primary;
        if (win32.GetLastError() == win32.ERROR_ALREADY_EXISTS) {
            _ = win32.CloseHandle(handle.?);
            return .already_running;
        }
        self.mutex = handle;
        return .primary;
    }

    fn acquirePosixLock(self: *SingleInstance, path: []const u8) AcquireResult {
        if (builtin.os.tag == .windows) return .primary;
        const file = std.fs.createFileAbsolute(path, .{ .truncate = false, .read = true }) catch return .primary;
        const fd = file.handle;
        std.posix.flock(fd, std.posix.LOCK.EX | std.posix.LOCK.NB) catch {
            std.posix.close(fd);
            return .already_running;
        };
        self.lock_fd = fd;
        return .primary;
    }

    pub fn activateExistingWindow() void {
        if (builtin.os.tag != .windows) return;
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
        if (builtin.os.tag == .windows) {
            if (self.mutex) |h| {
                _ = win32.ReleaseMutex(h);
                _ = win32.CloseHandle(h);
                self.mutex = null;
            }
        } else {
            if (self.lock_fd) |fd| {
                std.posix.flock(fd, std.posix.LOCK.UN) catch {};
                std.posix.close(fd);
                self.lock_fd = null;
            }
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
