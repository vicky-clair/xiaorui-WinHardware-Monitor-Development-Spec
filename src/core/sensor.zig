const std = @import("std");

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
            .ok => "正常",
            .unsupported => "不支持",
            .access_denied => "权限不足",
            .requires_extension => "需要扩展组件",
            .transient_error => "读取失败",
            .timeout => "读取超时",
            .device_standby => "设备休眠",
            .device_removed => "设备已移除",
            .stale => "数据过期",
            .unknown => "未知",
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
            .measured => "实测值",
            .derived => "计算值",
            .estimated => "估算值",
            .unknown => "未知",
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
            .normal => "正常",
            .caution => "注意",
            .warning => "警告",
            .critical => "严重",
            .unknown => "未知",
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
