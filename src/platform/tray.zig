const std = @import("std");
const win32 = @import("../providers/windows/win32.zig");

/// Windows 系统托盘管理（规范 §2.6）。
/// 若当前桌面会话未挂载 Shell_TrayWnd（如无头或 Explorer 重启期间），静默降级不崩溃，
/// 并在收到 TaskbarCreated 消息时自动重新注册。
pub const TrayIcon = struct {
    hwnd: ?win32.HWND = null,
    uid: win32.UINT = 1,
    callback_msg: win32.UINT = win32.WM_APP + 100,
    added: bool = false,

    pub const MENU_OPEN: usize = 1001;
    pub const MENU_TOGGLE_PAUSE: usize = 1002;
    pub const MENU_EXIT: usize = 1003;

    pub fn attach(self: *TrayIcon, hwnd: win32.HWND, tooltip_utf8: []const u8) bool {
        self.hwnd = hwnd;
        return self.recreate(tooltip_utf8);
    }

    pub fn recreate(self: *TrayIcon, tooltip_utf8: []const u8) bool {
        const hwnd = self.hwnd orelse return false;
        const tray_cls = std.unicode.utf8ToUtf16LeStringLiteral("Shell_TrayWnd");
        if (win32.FindWindowW(tray_cls, null) == null) {
            self.added = false;
            return false;
        }

        var nid = win32.NOTIFYICONDATAW{
            .hWnd = hwnd,
            .uID = self.uid,
            .uFlags = win32.NIF_ICON | win32.NIF_TIP | win32.NIF_MESSAGE,
            .uCallbackMessage = self.callback_msg,
            .hIcon = win32.LoadIconW(null, win32.IDI_APPLICATION),
        };
        copyUtf8ToUtf16Buf(&nid.szTip, tooltip_utf8);

        self.added = win32.Shell_NotifyIconW(win32.NIM_ADD, &nid) != 0;
        return self.added;
    }

    pub fn updateTooltip(self: *TrayIcon, tooltip_utf8: []const u8) void {
        if (!self.added) return;
        const hwnd = self.hwnd orelse return;
        var nid = win32.NOTIFYICONDATAW{
            .hWnd = hwnd,
            .uID = self.uid,
            .uFlags = win32.NIF_TIP,
        };
        copyUtf8ToUtf16Buf(&nid.szTip, tooltip_utf8);
        _ = win32.Shell_NotifyIconW(win32.NIM_MODIFY, &nid);
    }

    /// 托盘气泡通知（规范 §2.6 V1 保底桌面通知）
    pub fn showBalloon(self: *TrayIcon, title_utf8: []const u8, body_utf8: []const u8, info_flags: win32.DWORD) void {
        if (!self.added) return;
        const hwnd = self.hwnd orelse return;
        var nid = win32.NOTIFYICONDATAW{
            .hWnd = hwnd,
            .uID = self.uid,
            .uFlags = win32.NIF_INFO,
            .dwInfoFlags = info_flags,
        };
        copyUtf8ToUtf16Buf(&nid.szInfoTitle, title_utf8);
        copyUtf8ToUtf16Buf(&nid.szInfo, body_utf8);
        _ = win32.Shell_NotifyIconW(win32.NIM_MODIFY, &nid);
    }

    pub fn showContextMenu(self: *TrayIcon, paused: bool) ?usize {
        const hwnd = self.hwnd orelse return null;
        const menu = win32.CreatePopupMenu() orelse return null;
        defer _ = win32.DestroyMenu(menu);

        const open_lbl = std.unicode.utf8ToUtf16LeStringLiteral("打开主窗口");
        const pause_lbl = std.unicode.utf8ToUtf16LeStringLiteral("暂停采集");
        const exit_lbl = std.unicode.utf8ToUtf16LeStringLiteral("退出程序");

        _ = win32.AppendMenuW(menu, win32.MF_STRING, MENU_OPEN, open_lbl);
        _ = win32.AppendMenuW(menu, win32.MF_STRING | (if (paused) win32.MF_CHECKED else 0), MENU_TOGGLE_PAUSE, pause_lbl);
        _ = win32.AppendMenuW(menu, win32.MF_SEPARATOR, 0, null);
        _ = win32.AppendMenuW(menu, win32.MF_STRING, MENU_EXIT, exit_lbl);

        var pt: win32.POINT = .{};
        _ = win32.GetCursorPos(&pt);
        _ = win32.SetForegroundWindow(hwnd);

        const cmd = win32.TrackPopupMenu(
            menu,
            win32.TPM_RIGHTBUTTON | win32.TPM_RETURNCMD | win32.TPM_NONOTIFY,
            pt.x,
            pt.y,
            0,
            hwnd,
            null,
        );
        _ = win32.PostMessageW(hwnd, 0, 0, 0);
        if (cmd <= 0) return null;
        return @intCast(cmd);
    }

    pub fn detach(self: *TrayIcon) void {
        if (!self.added) return;
        if (self.hwnd) |hwnd| {
            var nid = win32.NOTIFYICONDATAW{
                .hWnd = hwnd,
                .uID = self.uid,
            };
            _ = win32.Shell_NotifyIconW(win32.NIM_DELETE, &nid);
        }
        self.added = false;
    }
};

pub fn copyUtf8ToUtf16Buf(dest: []u16, src: []const u8) void {
    @memset(dest, 0);
    if (dest.len == 0) return;
    const max_chars = dest.len - 1;
    var i: usize = 0;
    var view = std.unicode.Utf8View.initUnchecked(src);
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp <= 0xFFFF) {
            if (i >= max_chars) break;
            dest[i] = @intCast(cp);
            i += 1;
        } else {
            if (i + 1 >= max_chars) break;
            const adjusted = cp - 0x10000;
            dest[i] = @intCast(0xD800 + (adjusted >> 10));
            dest[i + 1] = @intCast(0xDC00 + (adjusted & 0x3FF));
            i += 2;
        }
    }
    dest[i] = 0;
}

test "copyUtf8ToUtf16Buf handles Chinese strings and truncation safely" {
    var buf: [8]u16 = undefined;
    copyUtf8ToUtf16Buf(&buf, "硬件监控工具长标题测试");
    try std.testing.expectEqual(@as(u16, 0), buf[7]);
    try std.testing.expect(buf[0] != 0);
}
