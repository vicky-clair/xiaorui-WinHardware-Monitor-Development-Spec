const std = @import("std");
const builtin = @import("builtin");
const win32 = @import("../providers/windows/win32.zig");

/// 跨平台开机自启管理（Windows 写入 HKCU\...\Run；Linux 写入 ~/.config/autostart/winhardware-monitor.desktop）。
const RUN_SUBKEY = std.unicode.utf8ToUtf16LeStringLiteral("Software\\Microsoft\\Windows\\CurrentVersion\\Run");
const VALUE_NAME = std.unicode.utf8ToUtf16LeStringLiteral("WinHardwareMonitor");

pub fn setAutoStart(enabled: bool) bool {
    if (builtin.os.tag != .windows) {
        return setLinuxAutoStart(enabled);
    }
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
        const res = win32.RegDeleteValueW(key, VALUE_NAME);
        // 0 = 成功，2 = ERROR_FILE_NOT_FOUND（本来就未设置，也视为成功）
        return res == 0 or res == 2;
    }

    var exe_w: [1024]u16 = std.mem.zeroes([1024]u16);
    const len = win32.GetModuleFileNameW(null, @ptrCast(&exe_w), exe_w.len - 4);
    if (len == 0 or len >= exe_w.len - 4) return false;

    // 加双引号包裹路径，安全兼容含空格或中文的安装目录
    var quoted: [1028]u16 = std.mem.zeroes([1028]u16);
    quoted[0] = '"';
    @memcpy(quoted[1 .. 1 + len], exe_w[0..len]);
    quoted[1 + len] = '"';
    quoted[2 + len] = 0;

    const byte_len: win32.DWORD = @intCast((len + 3) * @sizeOf(u16));
    return win32.RegSetValueExW(
        key,
        VALUE_NAME,
        0,
        win32.REG_SZ,
        @ptrCast(&quoted),
        byte_len,
    ) == 0;
}

pub fn isAutoStartEnabled() bool {
    if (builtin.os.tag != .windows) return false;
    var key: win32.HKEY = undefined;
    if (win32.RegOpenKeyExW(win32.HKEY_CURRENT_USER, RUN_SUBKEY, 0, win32.KEY_READ, &key) != 0) {
        return false;
    }
    defer _ = win32.RegCloseKey(key);

    var val_type: win32.DWORD = 0;
    var size: win32.DWORD = 0;
    return win32.RegQueryValueExW(key, VALUE_NAME, null, &val_type, null, &size) == 0 and val_type == win32.REG_SZ and size > 2;
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
        \\Exec={s}
        \\X-GNOME-Autostart-enabled=true
        \\
    , .{exe_path}) catch return false;
    f.writeAll(body) catch return false;
    return true;
}
