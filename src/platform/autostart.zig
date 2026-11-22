const std = @import("std");
const builtin = @import("builtin");
const win32 = @import("../providers/windows/win32.zig");

/// 跨平台开机自启管理：
/// - Windows：写入 HKCU\Software\Microsoft\Windows\CurrentVersion\Run\WinHardwareMonitor（带 --autostart 参数），
///   并同步重置 Windows 10/11 StartupApproved\Run 启用标志，避免被任务管理器历史禁用态静默拦截；
/// - Linux：写入 ~/.config/autostart/winhardware-monitor.desktop。
const RUN_SUBKEY = std.unicode.utf8ToUtf16LeStringLiteral("Software\\Microsoft\\Windows\\CurrentVersion\\Run");
const APPROVED_SUBKEY = std.unicode.utf8ToUtf16LeStringLiteral("Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\StartupApproved\\Run");
const VALUE_NAME = std.unicode.utf8ToUtf16LeStringLiteral("WinHardwareMonitor");
const AUTOSTART_ARG = std.unicode.utf8ToUtf16LeStringLiteral(" --autostart");

pub const AutoStartStatus = enum(u8) {
    disabled,
    enabled,
    blocked_by_os, // HKCU\Run 已写入，但在 Windows 任务管理器 StartupApproved 中被禁用
};

pub fn setAutoStart(enabled: bool) bool {
    if (builtin.os.tag != .windows) {
        return setLinuxAutoStart(enabled);
    }
    return setWindowsRunValue(VALUE_NAME, enabled);
}

fn setWindowsRunValue(val_name: win32.LPCWSTR, enabled: bool) bool {
    var key: win32.HKEY = undefined;
    if (win32.RegCreateKeyExW(
        win32.HKEY_CURRENT_USER,
        RUN_SUBKEY,
        0,
        null,
        0,
        win32.KEY_SET_VALUE,
        null,
        &key,
        null,
    ) != 0) {
        return false;
    }
    defer _ = win32.RegCloseKey(key);

    if (!enabled) {
        const res = win32.RegDeleteValueW(key, val_name);
        // 0 = 成功，2 = ERROR_FILE_NOT_FOUND（本来就未设置，也视为成功）
        return res == 0 or res == 2;
    }

    var exe_w: [1024]u16 = std.mem.zeroes([1024]u16);
    const len = win32.GetModuleFileNameW(null, @ptrCast(&exe_w), exe_w.len - 20);
    if (len == 0 or len >= exe_w.len - 20) return false;

    // 拼接 "<exe_path>" --autostart，安全兼容含空格或中文的安装目录
    var cmd_w: [1060]u16 = std.mem.zeroes([1060]u16);
    var pos: usize = 0;
    cmd_w[pos] = '"';
    pos += 1;
    @memcpy(cmd_w[pos .. pos + len], exe_w[0..len]);
    pos += len;
    cmd_w[pos] = '"';
    pos += 1;
    @memcpy(cmd_w[pos .. pos + AUTOSTART_ARG.len], AUTOSTART_ARG);
    pos += AUTOSTART_ARG.len;
    cmd_w[pos] = 0;

    const byte_len: win32.DWORD = @intCast((pos + 1) * @sizeOf(u16));
    if (win32.RegSetValueExW(
        key,
        val_name,
        0,
        win32.REG_SZ,
        @ptrCast(&cmd_w),
        byte_len,
    ) != 0) {
        return false;
    }

    // 同步确保 Windows 10/11 StartupApproved\Run 中未被置为禁用（0x02 = 启用）
    ensureStartupApprovedEnabled(val_name);
    return true;
}

fn ensureStartupApprovedEnabled(val_name: win32.LPCWSTR) void {
    var key: win32.HKEY = undefined;
    if (win32.RegCreateKeyExW(
        win32.HKEY_CURRENT_USER,
        APPROVED_SUBKEY,
        0,
        null,
        0,
        win32.KEY_SET_VALUE,
        null,
        &key,
        null,
    ) != 0) {
        return;
    }
    defer _ = win32.RegCloseKey(key);

    // Windows 10/11 StartupApproved 启用态标准 12 字节结构：首字节 0x02（启用）+ 11 字节 0
    const enabled_blob = [_]u8{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    _ = win32.RegSetValueExW(key, val_name, 0, win32.REG_BINARY, &enabled_blob, enabled_blob.len);
}

pub fn queryAutoStartStatus() AutoStartStatus {
    if (builtin.os.tag != .windows) {
        return if (isLinuxAutoStartEnabled()) .enabled else .disabled;
    }
    if (!queryWindowsRunExists(VALUE_NAME)) return .disabled;
    if (isDisabledInStartupApproved(VALUE_NAME)) return .blocked_by_os;
    return .enabled;
}

pub fn isAutoStartEnabled() bool {
    return queryAutoStartStatus() == .enabled;
}

fn queryWindowsRunExists(val_name: win32.LPCWSTR) bool {
    var key: win32.HKEY = undefined;
    if (win32.RegOpenKeyExW(win32.HKEY_CURRENT_USER, RUN_SUBKEY, 0, win32.KEY_READ, &key) != 0) {
        return false;
    }
    defer _ = win32.RegCloseKey(key);

    var val_type: win32.DWORD = 0;
    var size: win32.DWORD = 0;
    return win32.RegQueryValueExW(key, val_name, null, &val_type, null, &size) == 0 and val_type == win32.REG_SZ and size > 2;
}

fn isDisabledInStartupApproved(val_name: win32.LPCWSTR) bool {
    var key: win32.HKEY = undefined;
    if (win32.RegOpenKeyExW(win32.HKEY_CURRENT_USER, APPROVED_SUBKEY, 0, win32.KEY_READ, &key) != 0) {
        return false;
    }
    defer _ = win32.RegCloseKey(key);

    var blob: [16]u8 = std.mem.zeroes([16]u8);
    var size: win32.DWORD = blob.len;
    var val_type: win32.DWORD = 0;
    if (win32.RegQueryValueExW(key, val_name, null, &val_type, &blob, &size) != 0) {
        return false;
    }
    // Windows 约定：首字节为奇数（常见 0x03）表示被任务管理器禁用，偶数（0x02/0x06）表示启用
    return size >= 1 and (blob[0] & 0x01) != 0;
}

fn isLinuxAutoStartEnabled() bool {
    const home = std.posix.getenv("HOME") orelse return false;
    var file_buf: [576]u8 = undefined;
    const file_path = std.fmt.bufPrint(&file_buf, "{s}/.config/autostart/winhardware-monitor.desktop", .{home}) catch return false;
    std.fs.accessAbsolute(file_path, .{}) catch return false;
    return true;
}

fn setLinuxAutoStart(enabled: bool) bool {
    const home = std.posix.getenv("HOME") orelse return false;
    var dir_buf: [512]u8 = undefined;
    const dir_path = std.fmt.bufPrint(&dir_buf, "{s}/.config/autostart", .{home}) catch return false;
    var file_buf: [576]u8 = undefined;
    const file_path = std.fmt.bufPrint(&file_buf, "{s}/winhardware-monitor.desktop", .{dir_path}) catch return false;

    if (!enabled) {
        std.fs.deleteFileAbsolute(file_path) catch {};
        return true;
    }

    var cfg_buf: [512]u8 = undefined;
    if (std.fmt.bufPrint(&cfg_buf, "{s}/.config", .{home})) |cp| {
        std.fs.makeDirAbsolute(cp) catch {};
    } else |_| {}
    std.fs.makeDirAbsolute(dir_path) catch {};

    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_path = std.fs.selfExePath(&exe_buf) catch "winhardware-monitor";
    const f = std.fs.createFileAbsolute(file_path, .{ .truncate = true }) catch return false;
    defer f.close();
    var body_buf: [1024]u8 = undefined;
    const body = std.fmt.bufPrint(&body_buf,
        \\[Desktop Entry]
        \\Type=Application
        \\Name=WinHardware Monitor
        \\Exec={s} --autostart
        \\X-GNOME-Autostart-enabled=true
        \\
    , .{exe_path}) catch return false;
    f.writeAll(body) catch return false;
    return true;
}

test "Windows autostart registry write, StartupApproved check, and cleanup round-trip" {
    if (builtin.os.tag != .windows) return;
    const test_val = std.unicode.utf8ToUtf16LeStringLiteral("WinHardwareMonitor_UnitTestOnly");
    // Ensure clean start
    _ = setWindowsRunValue(test_val, false);
    try std.testing.expect(!queryWindowsRunExists(test_val));

    // Write & verify
    try std.testing.expect(setWindowsRunValue(test_val, true));
    try std.testing.expect(queryWindowsRunExists(test_val));
    try std.testing.expect(!isDisabledInStartupApproved(test_val));

    // Clean up both Run and StartupApproved test keys
    try std.testing.expect(setWindowsRunValue(test_val, false));
    try std.testing.expect(!queryWindowsRunExists(test_val));
    var akey: win32.HKEY = undefined;
    if (win32.RegOpenKeyExW(win32.HKEY_CURRENT_USER, APPROVED_SUBKEY, 0, win32.KEY_SET_VALUE, &akey) == 0) {
        _ = win32.RegDeleteValueW(akey, test_val);
        _ = win32.RegCloseKey(akey);
    }
}
