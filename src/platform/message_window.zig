const std = @import("std");
const builtin = @import("builtin");
const win32 = @import("../providers/windows/win32.zig");
const TrayIcon = @import("tray.zig").TrayIcon;

/// 隐藏顶层消息窗口（规范 §2.6）：
/// 统一接收系统托盘交互、TaskbarCreated、WM_DEVICECHANGE（热插拔）、WM_POWERBROADCAST（睡眠/唤醒/S0ix）。
pub const PendingEvents = struct {
    restore_window: bool = false,
    toggle_pause: bool = false,
    request_exit: bool = false,
    device_changed: bool = false,
    power_suspended: bool = false,
    power_resumed: bool = false,
    device_change_count: u64 = 0,
    power_resume_count: u64 = 0,
};

pub const MessageWindow = struct {
    hwnd: ?win32.HWND = null,
    class_atom: win32.ATOM = 0,
    hinst: ?win32.HINSTANCE = null,
    taskbar_created_msg: win32.UINT = 0,
    tray: TrayIcon = .{},
    events: PendingEvents = .{},
    monitoring_paused: bool = false,
    tooltip_buf: [128]u8 = std.mem.zeroes([128]u8),
    tooltip_len: usize = 0,

    const CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("WinHardwareMonitor_HiddenMsgWnd_v1");
    const TASKBAR_MSG_NAME = std.unicode.utf8ToUtf16LeStringLiteral("TaskbarCreated");

    /// 注册窗口类并创建不可见的顶层消息窗口，同时挂载系统托盘图标
    pub fn init(self: *MessageWindow) !void {
        if (builtin.os.tag != .windows) return;
        self.hinst = @ptrCast(win32.GetModuleHandleW(null));
        self.taskbar_created_msg = win32.RegisterWindowMessageW(TASKBAR_MSG_NAME);

        var wc = win32.WNDCLASSEXW{
            .lpfnWndProc = wndProc,
            .hInstance = self.hinst,
            .lpszClassName = CLASS_NAME,
        };
        self.class_atom = win32.RegisterClassExW(&wc);
        if (self.class_atom == 0) return error.RegisterClassFailed;

        // 必须是顶层隐藏窗口（hWndParent = null）才能接收 WM_DEVICECHANGE / WM_POWERBROADCAST / 托盘消息
        const hwnd = win32.CreateWindowExW(
            0,
            CLASS_NAME,
            CLASS_NAME,
            0,
            0,
            0,
            0,
            0,
            null,
            null,
            self.hinst,
            null,
        ) orelse {
            _ = win32.UnregisterClassW(CLASS_NAME, self.hinst);
            self.class_atom = 0;
            return error.CreateMessageWindowFailed;
        };
        self.hwnd = hwnd;
        _ = win32.SetWindowLongPtrW(hwnd, win32.GWLP_USERDATA, @intCast(@intFromPtr(self)));

        const default_tip = "WinHardware Monitor — 硬件温度与磁盘健康监控";
        self.setTooltipCache(default_tip);
        _ = self.tray.attach(hwnd, default_tip);
    }

    /// 卸载托盘图标并销毁隐藏消息窗口及窗口类
    pub fn deinit(self: *MessageWindow) void {
        if (builtin.os.tag != .windows) return;
        self.tray.detach();
        if (self.hwnd) |hwnd| {
            _ = win32.SetWindowLongPtrW(hwnd, win32.GWLP_USERDATA, 0);
            _ = win32.DestroyWindow(hwnd);
            self.hwnd = null;
        }
        if (self.class_atom != 0) {
            _ = win32.UnregisterClassW(CLASS_NAME, self.hinst);
            self.class_atom = 0;
        }
    }

    /// 非阻塞轮询并分发当前隐藏窗口消息队列中的所有 Win32 事件
    pub fn pumpMessages(self: *MessageWindow) void {
        if (builtin.os.tag != .windows) return;
        const hwnd = self.hwnd orelse return;
        var msg: win32.MSG = .{};
        while (win32.PeekMessageW(&msg, hwnd, 0, 0, win32.PM_REMOVE) != 0) {
            _ = win32.TranslateMessage(&msg);
            _ = win32.DispatchMessageW(&msg);
        }
    }

    /// 更新系统托盘悬停提示文本并缓存（供 Explorer 重启重建托盘图标时复用）
    pub fn setTooltip(self: *MessageWindow, tip: []const u8) void {
        self.setTooltipCache(tip);
        self.tray.updateTooltip(tip);
    }

    fn setTooltipCache(self: *MessageWindow, tip: []const u8) void {
        const n = @min(tip.len, self.tooltip_buf.len);
        @memcpy(self.tooltip_buf[0..n], tip[0..n]);
        self.tooltip_len = n;
    }

    /// Win32 消息回调函数：分发 Explorer 重建、托盘左右键、设备热插拔与电源状态事件
    fn wndProc(hwnd: win32.HWND, msg: win32.UINT, wp: win32.WPARAM, lp: win32.LPARAM) callconv(.winapi) win32.LRESULT {
        const raw_ptr = win32.GetWindowLongPtrW(hwnd, win32.GWLP_USERDATA);
        if (raw_ptr != 0) {
            const self: *MessageWindow = @ptrFromInt(@as(usize, @intCast(raw_ptr)));

            if (self.taskbar_created_msg != 0 and msg == self.taskbar_created_msg) {
                _ = self.tray.recreate(self.tooltip_buf[0..self.tooltip_len]);
                return 0;
            }

            if (msg == self.tray.callback_msg) {
                const mouse_msg: win32.UINT = @intCast(lp & 0xFFFF);
                if (mouse_msg == win32.WM_LBUTTONUP or mouse_msg == win32.WM_LBUTTONDBLCLK) {
                    self.events.restore_window = true;
                } else if (mouse_msg == win32.WM_RBUTTONUP or mouse_msg == win32.WM_CONTEXTMENU) {
                    if (self.tray.showContextMenu(self.monitoring_paused)) |cmd| {
                        switch (cmd) {
                            TrayIcon.MENU_OPEN => self.events.restore_window = true,
                            TrayIcon.MENU_TOGGLE_PAUSE => self.events.toggle_pause = true,
                            TrayIcon.MENU_EXIT => self.events.request_exit = true,
                            else => {},
                        }
                    }
                }
                return 0;
            }

            if (msg == win32.WM_DEVICECHANGE) {
                self.events.device_changed = true;
                self.events.device_change_count += 1;
                return 0;
            }

            if (msg == win32.WM_POWERBROADCAST) {
                switch (wp) {
                    win32.PBT_APMSUSPEND => self.events.power_suspended = true,
                    win32.PBT_APMRESUMEAUTOMATIC, win32.PBT_APMRESUMESUSPEND => {
                        self.events.power_resumed = true;
                        self.events.power_resume_count += 1;
                    },
                    win32.PBT_POWERSETTINGCHANGE => {
                        // Modern Standby (S0ix) 电源状态变更时标记检查
                        self.events.power_resumed = true;
                    },
                    else => {},
                }
                return 1;
            }
        }
        return win32.DefWindowProcW(hwnd, msg, wp, lp);
    }
};
