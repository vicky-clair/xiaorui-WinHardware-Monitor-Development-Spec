const std = @import("std");
const builtin = @import("builtin");
const win32 = @import("../providers/windows/win32.zig");

/// 规范 §5.1 文件存放位置解析（支持安装版 %LOCALAPPDATA% 与便携版 portable.flag，全程支持中文/空格路径）
pub const AppPaths = struct {
    allocator: std.mem.Allocator,
    is_portable: bool,
    base_dir: []u8,
    config_dir: []u8,
    data_dir: []u8,
    logs_dir: []u8,
    settings_file: []u8,
    db_file: []u8,

    /// 释放全部动态分配的路径字符串内存
    pub fn deinit(self: *AppPaths) void {
        self.allocator.free(self.base_dir);
        self.allocator.free(self.config_dir);
        self.allocator.free(self.data_dir);
        self.allocator.free(self.logs_dir);
        self.allocator.free(self.settings_file);
        self.allocator.free(self.db_file);
    }

    /// 自动检测部署模式：程序同级目录存在 portable.flag 则进入便携模式，否则存入系统用户数据目录
    pub fn resolve(allocator: std.mem.Allocator) !AppPaths {
        const exe_dir = try getExeDirUtf8(allocator);
        defer allocator.free(exe_dir);

        const flag_path = try std.fs.path.join(allocator, &.{ exe_dir, "portable.flag" });
        defer allocator.free(flag_path);

        const portable = blk: {
            std.fs.accessAbsolute(flag_path, .{}) catch break :blk false;
            break :blk true;
        };

        if (portable) {
            return buildFromBase(allocator, exe_dir, true);
        }

        const local_app_data = getLocalAppDataUtf8(allocator) catch null;
        if (local_app_data) |lad| {
            defer allocator.free(lad);
            const app_base = try std.fs.path.join(allocator, &.{ lad, "WinHardwareMonitor" });
            defer allocator.free(app_base);
            return buildFromBase(allocator, app_base, false);
        }

        // 若环境变量异常，安全回退到 exe 目录
        return buildFromBase(allocator, exe_dir, true);
    }

    pub fn buildFromBase(allocator: std.mem.Allocator, base: []const u8, portable: bool) !AppPaths {
        const base_dir = try allocator.dupe(u8, base);
        errdefer allocator.free(base_dir);
        const config_dir = try std.fs.path.join(allocator, &.{ base_dir, "config" });
        errdefer allocator.free(config_dir);
        const data_dir = try std.fs.path.join(allocator, &.{ base_dir, "data" });
        errdefer allocator.free(data_dir);
        const logs_dir = try std.fs.path.join(allocator, &.{ base_dir, "logs" });
        errdefer allocator.free(logs_dir);
        const settings_file = try std.fs.path.join(allocator, &.{ config_dir, "settings.toml" });
        errdefer allocator.free(settings_file);
        const db_file = try std.fs.path.join(allocator, &.{ data_dir, "monitor.db" });
        errdefer allocator.free(db_file);

        return .{
            .allocator = allocator,
            .is_portable = portable,
            .base_dir = base_dir,
            .config_dir = config_dir,
            .data_dir = data_dir,
            .logs_dir = logs_dir,
            .settings_file = settings_file,
            .db_file = db_file,
        };
    }

    /// 确保 config / data / logs 子目录已就绪（目录已存在时安全跳过）
    pub fn ensureDirectories(self: *const AppPaths) void {
        std.fs.makeDirAbsolute(self.base_dir) catch {};
        std.fs.makeDirAbsolute(self.config_dir) catch {};
        std.fs.makeDirAbsolute(self.data_dir) catch {};
        std.fs.makeDirAbsolute(self.logs_dir) catch {};
    }
};

/// 获取当前可执行文件所在目录的 UTF-8 绝对路径（Windows 经宽字符 API 转换以完整支持中文路径）
fn getExeDirUtf8(allocator: std.mem.Allocator) ![]u8 {
    if (builtin.os.tag == .windows) {
        var wbuf: [1024]u16 = undefined;
        const len = win32.GetModuleFileNameW(null, @ptrCast(&wbuf), wbuf.len - 1);
        if (len == 0 or len >= wbuf.len) return error.ModulePathFailed;
        const full_utf8 = try std.unicode.utf16LeToUtf8Alloc(allocator, wbuf[0..len]);
        defer allocator.free(full_utf8);
        const dir = std.fs.path.dirname(full_utf8) orelse ".";
        return allocator.dupe(u8, dir);
    }
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_path = std.fs.selfExePath(&buf) catch return allocator.dupe(u8, ".");
    const dir = std.fs.path.dirname(exe_path) orelse ".";
    return allocator.dupe(u8, dir);
}

fn getLocalAppDataUtf8(allocator: std.mem.Allocator) ![]u8 {
    if (builtin.os.tag == .windows) {
        const key = std.unicode.utf8ToUtf16LeStringLiteral("LOCALAPPDATA");
        var wbuf: [1024]u16 = undefined;
        const len = win32.GetEnvironmentVariableW(key, @ptrCast(&wbuf), wbuf.len - 1);
        if (len == 0 or len >= wbuf.len) return error.EnvNotFound;
        return std.unicode.utf16LeToUtf8Alloc(allocator, wbuf[0..len]);
    }
    if (std.posix.getenv("XDG_DATA_HOME")) |xdg| {
        if (xdg.len > 0) return allocator.dupe(u8, xdg);
    }
    if (std.posix.getenv("HOME")) |home| {
        if (home.len > 0) return std.fs.path.join(allocator, &.{ home, ".local", "share" });
    }
    return error.EnvNotFound;
}

test "AppPaths builds portable and installed layouts with Chinese paths" {
    const sample_base = if (builtin.os.tag == .windows) "C:\\测试目录\\WinHardware Monitor" else "/tmp/测试目录/WinHardware Monitor";
    var p = try AppPaths.buildFromBase(std.testing.allocator, sample_base, true);
    defer p.deinit();
    try std.testing.expect(p.is_portable);
    const exp_cfg = if (builtin.os.tag == .windows) "config\\settings.toml" else "config/settings.toml";
    const exp_db = if (builtin.os.tag == .windows) "data\\monitor.db" else "data/monitor.db";
    try std.testing.expect(std.mem.endsWith(u8, p.settings_file, exp_cfg));
    try std.testing.expect(std.mem.endsWith(u8, p.db_file, exp_db));
}
