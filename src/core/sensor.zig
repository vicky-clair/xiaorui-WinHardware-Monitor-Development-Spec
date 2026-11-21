const std = @import("std");
const i18n = @import("i18n.zig");

/// 规范 §3.1 传感器状态枚举（严格区分有效 0 与各类失败原因）
pub const SensorStatus = enum(u8) {
    ok,
    unsupported,
    access_denied,
    requires_extension,
    transient_error,
    timeout,
    device_standby,
    device_removed,
    stale,
    unknown,

    pub fn labelZh(self: SensorStatus) [:0]const u8 {
        return switch (self) {
            .ok => i18n.tr("正常", "OK", "正常"),
            .unsupported => i18n.tr("不支持", "Unsupported", "非対応"),
            .access_denied => i18n.tr("权限不足", "Access Denied", "権限不足"),
            .requires_extension => i18n.tr("需要扩展组件", "Extension Required", "拡張が必要"),
            .transient_error => i18n.tr("读取失败", "Read Error", "読取失敗"),
            .timeout => i18n.tr("读取超时", "Timeout", "タイムアウト"),
            .device_standby => i18n.tr("设备休眠", "Standby", "スリープ中"),
            .device_removed => i18n.tr("设备已移除", "Removed", "切断済み"),
            .stale => i18n.tr("数据过期", "Stale", "古いデータ"),
            .unknown => i18n.tr("未知", "Unknown", "不明"),
        };
    }
};

/// 规范 §3.1 数据准确度分类
pub const SensorAccuracy = enum(u8) {
    measured, // 传感器实测
    derived, // 由实测值计算
    estimated, // 估算（不得参与健康判定）
    unknown,

    pub fn labelZh(self: SensorAccuracy) [:0]const u8 {
        return switch (self) {
            .measured => i18n.tr("实测值", "Measured", "実測値"),
            .derived => i18n.tr("计算值", "Derived", "算出値"),
            .estimated => i18n.tr("估算值", "Estimated", "推定値"),
            .unknown => i18n.tr("未知", "Unknown", "不明"),
        };
    }
};

/// 规范 §2.5.5 健康状态五级枚举
pub const HealthLevel = enum(u8) {
    unknown = 0,
    normal = 1,
    caution = 2,
    warning = 3,
    critical = 4,

    pub fn labelZh(self: HealthLevel) [:0]const u8 {
        return switch (self) {
            .normal => i18n.tr("正常", "Healthy", "正常"),
            .caution => i18n.tr("注意", "Caution", "注意"),
            .warning => i18n.tr("警告", "Warning", "警告"),
            .critical => i18n.tr("严重", "Critical", "危険"),
            .unknown => i18n.tr("未知", "Unknown", "不明"),
        };
    }

    pub fn max(a: HealthLevel, b: HealthLevel) HealthLevel {
        return if (@intFromEnum(a) >= @intFromEnum(b)) a else b;
    }
};

/// 内部统一基础单位
pub const SensorUnit = enum(u8) {
    celsius,
    percent,
    mhz,
    watts,
    rpm,
    volts,
    bytes,
    hours,
    count,
    none,

    pub fn symbol(self: SensorUnit) [:0]const u8 {
        return switch (self) {
            .celsius => "°C",
            .percent => "%",
            .mhz => "MHz",
            .watts => "W",
            .rpm => "RPM",
            .volts => "V",
            .bytes => "B",
            .hours => "h",
            .count => "",
            .none => "",
        };
    }
};

pub const SensorReading = struct {
    sensor_id: []const u8,
    device_id: []const u8,
    name: []const u8,
    value: ?f64,
    unit: SensorUnit,
    timestamp_utc_ms: i64,
    source: []const u8,
    status: SensorStatus,
    accuracy: SensorAccuracy,
    error_code: ?u32 = null,

    pub fn isValid(self: SensorReading) bool {
        return self.status == .ok and self.value != null;
    }
};

test "SensorStatus distinguishes valid zero from failure" {
    const zero_reading = SensorReading{
        .sensor_id = "disk0:media_errors",
        .device_id = "disk0",
        .name = "Media Errors",
        .value = 0.0,
        .unit = .count,
        .timestamp_utc_ms = 1700000000000,
        .source = "nvme:log02",
        .status = .ok,
        .accuracy = .measured,
    };
    try std.testing.expect(zero_reading.isValid());
    try std.testing.expectEqual(@as(?f64, 0.0), zero_reading.value);

    const denied = SensorReading{
        .sensor_id = "disk1:temp",
        .device_id = "disk1",
        .name = "Temperature",
        .value = null,
        .unit = .celsius,
        .timestamp_utc_ms = 1700000000000,
        .source = "ata:smart",
        .status = .access_denied,
        .accuracy = .unknown,
        .error_code = 5,
    };
    try std.testing.expect(!denied.isValid());
    try std.testing.expectEqual(@as(?u32, 5), denied.error_code);
}

test "HealthLevel ordering and max" {
    try std.testing.expectEqual(HealthLevel.critical, HealthLevel.max(.warning, .critical));
    try std.testing.expectEqual(HealthLevel.warning, HealthLevel.max(.caution, .warning));
    try std.testing.expectEqual(HealthLevel.normal, HealthLevel.max(.unknown, .normal));
}
