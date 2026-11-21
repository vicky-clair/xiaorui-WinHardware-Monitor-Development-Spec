const std = @import("std");
const toml = @import("../utils/toml.zig");
const state_mod = @import("../app/state.zig");
const i18n = @import("../core/i18n.zig");

/// 完整应用配置（对应 config/default.toml 与规范 §2.6 / §5.3 / §8）
pub const AppConfig = struct {
    // [general]
    language: [16]u8 = initFixed(16, "zh-CN"),
    language_len: usize = 5,
    theme_mode: state_mod.ThemeMode = .dark,
    temp_unit: state_mod.TemperatureUnit = .celsius,
    start_with_windows: bool = false,
    close_behavior: state_mod.CloseBehavior = .minimize_to_tray,
    minimize_behavior: state_mod.MinimizeBehavior = .minimize_to_taskbar,
    enable_extension_helper: bool = false,

    // [polling]
    system_interval_ms: u32 = 2000,
    gpu_interval_ms: u32 = 2000,
    disk_temp_interval_ms: u32 = 10000,
    smart_interval_ms: u32 = 60000, // 规范 §5.3：最低不低于 30000ms
    battery_smart_multiplier: u32 = 5,
    allow_wake_standby_disk: bool = false,
    allow_wake_dgpu: bool = false,
    ioctl_timeout_ms: u32 = 5000,

    // [storage]
    db_flush_interval_s: u32 = 60,
    retain_1m_days: u32 = 7,
    retain_15m_days: u32 = 30,
    retain_smart_days: u32 = 90,

    // [alerts]
    alerts_enabled: bool = true,
    desktop_notifications: bool = true,
    notify_on_recovery: bool = true,
    alert_duration_s: u32 = 30,
    alert_hysteresis_c: i32 = 5,
    alert_suppress_minutes: u32 = 30,

    // [alerts.thresholds]
    cpu_caution_c: i32 = 80,
    cpu_warning_c: i32 = 90,
    gpu_caution_c: i32 = 80,
    gpu_warning_c: i32 = 90,
    ssd_caution_c: i32 = 60,
    ssd_warning_c: i32 = 70,
    hdd_caution_c: i32 = 50,
    hdd_warning_c: i32 = 55,
    nvme_percentage_used_caution: u32 = 80,
    nvme_percentage_used_warning: u32 = 100,
    ssd_life_left_warning: u32 = 10,

    pub fn fromToml(allocator: std.mem.Allocator, content: []const u8) AppConfig {
        var cfg = AppConfig{};
        var doc = toml.Document.parse(allocator, content) catch return cfg;
        defer doc.deinit();

        if (doc.getString("general", "language")) |lang| {
            const n = @min(lang.len, cfg.language.len);
            @memcpy(cfg.language[0..n], lang[0..n]);
            cfg.language_len = n;
        }
        if (doc.getString("general", "theme")) |th| {
            cfg.theme_mode = if (std.mem.eql(u8, th, "light")) .light else .dark;
        }
        if (doc.getString("general", "temperature_unit")) |tu| {
            if (std.mem.eql(u8, tu, "F")) cfg.temp_unit = .fahrenheit else cfg.temp_unit = .celsius;
        }
        if (doc.getBool("general", "start_with_windows")) |v| cfg.start_with_windows = v;
        if (doc.getString("general", "close_behavior")) |cb| {
            cfg.close_behavior = if (std.mem.eql(u8, cb, "exit_app")) .exit_app else .minimize_to_tray;
        }
        if (doc.getString("general", "minimize_behavior")) |mb| {
            cfg.minimize_behavior = if (std.mem.eql(u8, mb, "minimize_to_tray")) .minimize_to_tray else .minimize_to_taskbar;
        }
        if (doc.getBool("general", "enable_extension_helper")) |v| cfg.enable_extension_helper = v;

        if (doc.getInt("polling", "system_interval_ms")) |v| cfg.system_interval_ms = clampU32(v, 500, 60000);
        if (doc.getInt("polling", "gpu_interval_ms")) |v| cfg.gpu_interval_ms = clampU32(v, 500, 60000);
        if (doc.getInt("polling", "disk_temp_interval_ms")) |v| cfg.disk_temp_interval_ms = clampU32(v, 2000, 300000);
        if (doc.getInt("polling", "smart_interval_ms")) |v| cfg.smart_interval_ms = clampU32(v, 30000, 3600000);
        if (doc.getInt("polling", "battery_smart_multiplier")) |v| cfg.battery_smart_multiplier = clampU32(v, 1, 20);
        if (doc.getBool("polling", "allow_wake_standby_disk")) |v| cfg.allow_wake_standby_disk = v;
        if (doc.getBool("polling", "allow_wake_dgpu")) |v| cfg.allow_wake_dgpu = v;
        if (doc.getInt("polling", "ioctl_timeout_ms")) |v| cfg.ioctl_timeout_ms = clampU32(v, 1000, 30000);

        if (doc.getInt("storage", "db_flush_interval_s")) |v| cfg.db_flush_interval_s = clampU32(v, 10, 600);
        if (doc.getInt("storage", "retain_1m_days")) |v| cfg.retain_1m_days = clampU32(v, 1, 90);
        if (doc.getInt("storage", "retain_15m_days")) |v| cfg.retain_15m_days = clampU32(v, 1, 365);
        if (doc.getInt("storage", "retain_smart_days")) |v| cfg.retain_smart_days = clampU32(v, 7, 1095);

        if (doc.getBool("alerts", "enabled")) |v| cfg.alerts_enabled = v;
        if (doc.getBool("alerts", "desktop_notifications")) |v| cfg.desktop_notifications = v;
        if (doc.getBool("alerts", "notify_on_recovery")) |v| cfg.notify_on_recovery = v;
        if (doc.getInt("alerts", "duration_s")) |v| cfg.alert_duration_s = clampU32(v, 0, 600);
        if (doc.getInt("alerts", "hysteresis_c")) |v| cfg.alert_hysteresis_c = clampI32(v, 1, 25);
        if (doc.getInt("alerts", "suppress_minutes")) |v| cfg.alert_suppress_minutes = clampU32(v, 1, 1440);

        if (doc.getInt("alerts.thresholds", "cpu_caution_c")) |v| cfg.cpu_caution_c = clampI32(v, 40, 120);
        if (doc.getInt("alerts.thresholds", "cpu_warning_c")) |v| cfg.cpu_warning_c = clampI32(v, 45, 130);
        if (doc.getInt("alerts.thresholds", "gpu_caution_c")) |v| cfg.gpu_caution_c = clampI32(v, 40, 120);
        if (doc.getInt("alerts.thresholds", "gpu_warning_c")) |v| cfg.gpu_warning_c = clampI32(v, 45, 130);
        if (doc.getInt("alerts.thresholds", "ssd_caution_c")) |v| cfg.ssd_caution_c = clampI32(v, 30, 100);
        if (doc.getInt("alerts.thresholds", "ssd_warning_c")) |v| cfg.ssd_warning_c = clampI32(v, 35, 110);
        if (doc.getInt("alerts.thresholds", "hdd_caution_c")) |v| cfg.hdd_caution_c = clampI32(v, 30, 80);
        if (doc.getInt("alerts.thresholds", "hdd_warning_c")) |v| cfg.hdd_warning_c = clampI32(v, 35, 90);
        if (doc.getInt("alerts.thresholds", "nvme_percentage_used_caution")) |v| cfg.nvme_percentage_used_caution = clampU32(v, 1, 255);
        if (doc.getInt("alerts.thresholds", "nvme_percentage_used_warning")) |v| cfg.nvme_percentage_used_warning = clampU32(v, 1, 255);
        if (doc.getInt("alerts.thresholds", "ssd_life_left_warning")) |v| cfg.ssd_life_left_warning = clampU32(v, 1, 100);

        return cfg;
    }

    pub fn toToml(self: *const AppConfig, allocator: std.mem.Allocator) ![]u8 {
        var doc = toml.Document.init(allocator);
        defer doc.deinit();

        try doc.put("general", "language", .{ .string = self.language[0..self.language_len] });
        try doc.put("general", "theme", .{ .string = if (self.theme_mode == .light) "light" else "dark" });
        try doc.put("general", "temperature_unit", .{ .string = if (self.temp_unit == .fahrenheit) "F" else "C" });
        try doc.put("general", "start_with_windows", .{ .boolean = self.start_with_windows });
        try doc.put("general", "close_behavior", .{ .string = if (self.close_behavior == .exit_app) "exit_app" else "minimize_to_tray" });
        try doc.put("general", "minimize_behavior", .{ .string = if (self.minimize_behavior == .minimize_to_tray) "minimize_to_tray" else "minimize_to_taskbar" });
        try doc.put("general", "enable_extension_helper", .{ .boolean = self.enable_extension_helper });

        try doc.put("polling", "system_interval_ms", .{ .int = self.system_interval_ms });
        try doc.put("polling", "gpu_interval_ms", .{ .int = self.gpu_interval_ms });
        try doc.put("polling", "disk_temp_interval_ms", .{ .int = self.disk_temp_interval_ms });
        try doc.put("polling", "smart_interval_ms", .{ .int = self.smart_interval_ms });
        try doc.put("polling", "battery_smart_multiplier", .{ .int = self.battery_smart_multiplier });
        try doc.put("polling", "allow_wake_standby_disk", .{ .boolean = self.allow_wake_standby_disk });
        try doc.put("polling", "allow_wake_dgpu", .{ .boolean = self.allow_wake_dgpu });
        try doc.put("polling", "ioctl_timeout_ms", .{ .int = self.ioctl_timeout_ms });

        try doc.put("storage", "db_flush_interval_s", .{ .int = self.db_flush_interval_s });
        try doc.put("storage", "retain_1m_days", .{ .int = self.retain_1m_days });
        try doc.put("storage", "retain_15m_days", .{ .int = self.retain_15m_days });
        try doc.put("storage", "retain_smart_days", .{ .int = self.retain_smart_days });

        try doc.put("alerts", "enabled", .{ .boolean = self.alerts_enabled });
        try doc.put("alerts", "desktop_notifications", .{ .boolean = self.desktop_notifications });
        try doc.put("alerts", "notify_on_recovery", .{ .boolean = self.notify_on_recovery });
        try doc.put("alerts", "duration_s", .{ .int = self.alert_duration_s });
        try doc.put("alerts", "hysteresis_c", .{ .int = self.alert_hysteresis_c });
        try doc.put("alerts", "suppress_minutes", .{ .int = self.alert_suppress_minutes });

        try doc.put("alerts.thresholds", "cpu_caution_c", .{ .int = self.cpu_caution_c });
        try doc.put("alerts.thresholds", "cpu_warning_c", .{ .int = self.cpu_warning_c });
        try doc.put("alerts.thresholds", "gpu_caution_c", .{ .int = self.gpu_caution_c });
        try doc.put("alerts.thresholds", "gpu_warning_c", .{ .int = self.gpu_warning_c });
        try doc.put("alerts.thresholds", "ssd_caution_c", .{ .int = self.ssd_caution_c });
        try doc.put("alerts.thresholds", "ssd_warning_c", .{ .int = self.ssd_warning_c });
        try doc.put("alerts.thresholds", "hdd_caution_c", .{ .int = self.hdd_caution_c });
        try doc.put("alerts.thresholds", "hdd_warning_c", .{ .int = self.hdd_warning_c });
        try doc.put("alerts.thresholds", "nvme_percentage_used_caution", .{ .int = self.nvme_percentage_used_caution });
        try doc.put("alerts.thresholds", "nvme_percentage_used_warning", .{ .int = self.nvme_percentage_used_warning });
        try doc.put("alerts.thresholds", "ssd_life_left_warning", .{ .int = self.ssd_life_left_warning });

        return doc.serialize(allocator);
    }

    pub fn loadFileOrDefault(allocator: std.mem.Allocator, abs_path: []const u8) AppConfig {
        const file = std.fs.openFileAbsolute(abs_path, .{}) catch return AppConfig{};
        defer file.close();
        const bytes = file.readToEndAlloc(allocator, 512 * 1024) catch return AppConfig{};
        defer allocator.free(bytes);
        return AppConfig.fromToml(allocator, bytes);
    }

    pub fn saveFile(self: *const AppConfig, allocator: std.mem.Allocator, abs_path: []const u8) !void {
        const text = try self.toToml(allocator);
        defer allocator.free(text);
        const file = try std.fs.createFileAbsolute(abs_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(text);
    }

    pub fn applyToState(self: *const AppConfig, st: *state_mod.AppState) void {
        st.language = i18n.Language.fromCode(self.language[0..self.language_len]);
        i18n.setLanguage(st.language);
        st.theme_mode = self.theme_mode;
        st.close_behavior = self.close_behavior;
        st.minimize_behavior = self.minimize_behavior;
        st.temp_unit = self.temp_unit;
        st.start_with_windows = self.start_with_windows;
        st.extension_enabled = self.enable_extension_helper;
    }

    pub fn syncFromState(self: *AppConfig, st: *const state_mod.AppState) void {
        const code = st.language.code();
        const n = @min(self.language.len, code.len);
        @memcpy(self.language[0..n], code[0..n]);
        self.language_len = n;
        self.theme_mode = st.theme_mode;
        self.close_behavior = st.close_behavior;
        self.minimize_behavior = st.minimize_behavior;
        self.temp_unit = st.temp_unit;
        self.start_with_windows = st.start_with_windows;
        self.enable_extension_helper = st.extension_enabled;
    }
};

fn initFixed(comptime N: usize, s: []const u8) [N]u8 {
    var out = std.mem.zeroes([N]u8);
    const n = @min(N, s.len);
    @memcpy(out[0..n], s[0..n]);
    return out;
}

fn clampU32(val: i64, lo: u32, hi: u32) u32 {
    if (val < lo) return lo;
    if (val > hi) return hi;
    return @intCast(val);
}

fn clampI32(val: i64, lo: i32, hi: i32) i32 {
    if (val < lo) return lo;
    if (val > hi) return hi;
    return @intCast(val);
}

test "AppConfig round-trip serialization, trilingual language persistence, and safe SMART interval clamping" {
    var cfg = AppConfig{};
    cfg.language = initFixed(16, "ja-JP");
    cfg.language_len = 5;
    cfg.theme_mode = .light;
    cfg.temp_unit = .fahrenheit;
    cfg.close_behavior = .exit_app;
    cfg.system_interval_ms = 1000;
    cfg.smart_interval_ms = 120000;
    cfg.cpu_warning_c = 95;

    const text = try cfg.toToml(std.testing.allocator);
    defer std.testing.allocator.free(text);

    const parsed = AppConfig.fromToml(std.testing.allocator, text);
    try std.testing.expectEqualStrings("ja-JP", parsed.language[0..parsed.language_len]);
    try std.testing.expectEqual(i18n.Language.ja_jp, i18n.Language.fromCode(parsed.language[0..parsed.language_len]));
    try std.testing.expectEqual(state_mod.ThemeMode.light, parsed.theme_mode);
    try std.testing.expectEqual(state_mod.TemperatureUnit.fahrenheit, parsed.temp_unit);
    try std.testing.expectEqual(state_mod.CloseBehavior.exit_app, parsed.close_behavior);
    try std.testing.expectEqual(@as(u32, 1000), parsed.system_interval_ms);
    try std.testing.expectEqual(@as(u32, 120000), parsed.smart_interval_ms);
    try std.testing.expectEqual(@as(i32, 95), parsed.cpu_warning_c);

    // 验证 en-US 同步到 AppState 后再回写
    var st = state_mod.AppState{};
    st.language = .en_us;
    var cfg_en = AppConfig{};
    cfg_en.syncFromState(&st);
    try std.testing.expectEqualStrings("en-US", cfg_en.language[0..cfg_en.language_len]);
    i18n.setLanguage(.zh_cn);

    // 规范 §5.3：SMART 最短采集间隔不得低于 30 秒
    const too_fast = AppConfig.fromToml(std.testing.allocator, "[polling]\nsmart_interval_ms = 5000\n");
    try std.testing.expectEqual(@as(u32, 30000), too_fast.smart_interval_ms);

    // 损坏文件安全回退默认值
    const corrupt = AppConfig.fromToml(std.testing.allocator, "[[broken syntax");
    try std.testing.expectEqual(@as(u32, 2000), corrupt.system_interval_ms);
}
