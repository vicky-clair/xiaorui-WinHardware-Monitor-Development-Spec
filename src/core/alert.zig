const std = @import("std");
const sensor = @import("sensor.zig");
const HealthLevel = sensor.HealthLevel;
const health_rules = @import("health_rules.zig");
const i18n = @import("i18n.zig");

/// 规范 §8 告警引擎：
/// - 温度持续时间防抖（默认 30 秒，避免瞬时尖峰误报）
/// - 回差恢复（默认 5°C，避免阈值附近抖动）
/// - 重复告警抑制（默认 30 分钟内同一规则与设备不重复弹窗）
/// - 磁盘健康规则直接由 §2.5.5 规则表驱动，每条告警必含规则 ID 与可读证据
pub const MAX_TRACKERS = 32;
pub const MAX_ALERT_HISTORY = 128;

pub const AlertConfig = struct {
    enabled: bool = true,
    notify_on_recovery: bool = true,
    duration_s: u32 = 30,
    hysteresis_c: f64 = 5.0,
    suppress_minutes: u32 = 30,
};

pub const AlertEvent = struct {
    rule_id: [32]u8 = std.mem.zeroes([32]u8),
    rule_id_len: usize = 0,
    device_id: [32]u8 = std.mem.zeroes([32]u8),
    device_id_len: usize = 0,
    level: HealthLevel = .caution,
    is_recovery: bool = false,
    acknowledged: bool = false,
    timestamp_utc_ms: i64 = 0,
    message: [160]u8 = std.mem.zeroes([160]u8),
    message_len: usize = 0,

    pub fn ruleIdSlice(self: *const AlertEvent) []const u8 {
        return self.rule_id[0..self.rule_id_len];
    }
    pub fn deviceIdSlice(self: *const AlertEvent) []const u8 {
        return self.device_id[0..self.device_id_len];
    }
    pub fn messageSlice(self: *const AlertEvent) []const u8 {
        return self.message[0..self.message_len];
    }
};

const TempTracker = struct {
    in_use: bool = false,
    rule_id: [32]u8 = std.mem.zeroes([32]u8),
    rule_id_len: usize = 0,
    device_id: [32]u8 = std.mem.zeroes([32]u8),
    device_id_len: usize = 0,

    above_since_ms: ?i64 = null,
    active: bool = false,
    active_level: HealthLevel = .normal,
    last_notified_ms: i64 = 0,
};

pub const AlertEngine = struct {
    cfg: AlertConfig = .{},
    trackers: [MAX_TRACKERS]TempTracker = [_]TempTracker{.{}} ** MAX_TRACKERS,
    history: [MAX_ALERT_HISTORY]AlertEvent = [_]AlertEvent{.{}} ** MAX_ALERT_HISTORY,
    history_count: usize = 0,
    pending_notify: ?AlertEvent = null,

    pub fn activeCount(self: *const AlertEngine) u32 {
        var c: u32 = 0;
        for (self.trackers) |t| {
            if (t.in_use and t.active) c += 1;
        }
        return c;
    }

    pub fn historySlice(self: *const AlertEngine) []const AlertEvent {
        return self.history[0..self.history_count];
    }

    pub fn acknowledgeAll(self: *AlertEngine) void {
        for (self.history[0..self.history_count]) |*h| {
            h.acknowledged = true;
        }
    }

    pub fn takePendingNotification(self: *AlertEngine) ?AlertEvent {
        const ev = self.pending_notify;
        self.pending_notify = null;
        return ev;
    }

    /// 评估单个温度传感器（遵循：持续时间防抖 + 回差恢复 + 抑制窗口）
    pub fn evaluateTemperature(
        self: *AlertEngine,
        device_id: []const u8,
        device_label: []const u8,
        temp_c: f64,
        caution_c: f64,
        warning_c: f64,
        now_utc_ms: i64,
    ) ?AlertEvent {
        if (!self.cfg.enabled) return null;

        const rule_id = "TEMP-HIGH";
        const tr = self.getOrCreateTracker(rule_id, device_id) orelse return null;

        const target_level: HealthLevel = if (temp_c >= warning_c)
            .warning
        else if (temp_c >= caution_c)
            .caution
        else
            .normal;

        if (target_level != .normal) {
            if (tr.above_since_ms == null) {
                tr.above_since_ms = now_utc_ms;
            }
            const elapsed_ms = now_utc_ms - tr.above_since_ms.?;
            const required_ms: i64 = @as(i64, self.cfg.duration_s) * 1000;

            if (elapsed_ms >= required_ms) {
                const suppress_ms: i64 = @as(i64, self.cfg.suppress_minutes) * 60 * 1000;
                const escalated = @intFromEnum(target_level) > @intFromEnum(tr.active_level);
                const should_notify = !tr.active or escalated or (now_utc_ms - tr.last_notified_ms >= suppress_ms);

                tr.active = true;
                tr.active_level = target_level;
                if (should_notify) {
                    tr.last_notified_ms = now_utc_ms;
                    const thr = if (target_level == .warning) warning_c else caution_c;
                    const ev = makeEvent(
                        rule_id,
                        device_id,
                        target_level,
                        false,
                        now_utc_ms,
                        "{s} {s} {d:.1}°C >= {d:.0}°C ({d}s)",
                        .{
                            device_label,
                            i18n.trSlice("温度持续超限", "temperature exceeded threshold", "温度が閾値を超過"),
                            temp_c,
                            thr,
                            self.cfg.duration_s,
                        },
                    );
                    self.pushHistory(ev);
                    self.pending_notify = ev;
                    return ev;
                }
            }
        } else {
            // 低于阈值：若当前处于活动告警，必须低于 (caution_c - hysteresis_c) 才恢复（回差防抖）
            if (tr.active) {
                if (temp_c <= caution_c - self.cfg.hysteresis_c) {
                    tr.active = false;
                    tr.active_level = .normal;
                    tr.above_since_ms = null;
                    if (self.cfg.notify_on_recovery) {
                        const ev = makeEvent(
                            rule_id,
                            device_id,
                            .normal,
                            true,
                            now_utc_ms,
                            "{s} {s} ({d:.1}°C <= {d:.0}°C)",
                            .{
                                device_label,
                                i18n.trSlice("温度已恢复正常", "temperature recovered", "温度が正常に回復"),
                                temp_c,
                                caution_c - self.cfg.hysteresis_c,
                            },
                        );
                        self.pushHistory(ev);
                        self.pending_notify = ev;
                        return ev;
                    }
                }
            } else {
                tr.above_since_ms = null;
            }
        }
        return null;
    }

    /// 评估磁盘健康规则命中（规范 §8.2）
    pub fn evaluateDiskAssessment(
        self: *AlertEngine,
        device_id: []const u8,
        assessment: *const health_rules.HealthAssessment,
        now_utc_ms: i64,
    ) void {
        if (!self.cfg.enabled) return;
        const suppress_ms: i64 = @as(i64, self.cfg.suppress_minutes) * 60 * 1000;

        for (assessment.slice()) |hit| {
            if (@intFromEnum(hit.level) < @intFromEnum(HealthLevel.caution)) continue;
            const tr = self.getOrCreateTracker(hit.rule_id, device_id) orelse continue;
            const should_notify = !tr.active or (now_utc_ms - tr.last_notified_ms >= suppress_ms);
            tr.active = true;
            tr.active_level = hit.level;
            if (should_notify) {
                tr.last_notified_ms = now_utc_ms;
                const ev = makeEvent(hit.rule_id, device_id, hit.level, false, now_utc_ms, "{s}", .{hit.evidenceSlice()});
                self.pushHistory(ev);
                self.pending_notify = ev;
            }
        }
    }

    fn getOrCreateTracker(self: *AlertEngine, rule_id: []const u8, device_id: []const u8) ?*TempTracker {
        for (&self.trackers) |*t| {
            if (t.in_use and
                std.mem.eql(u8, t.rule_id[0..t.rule_id_len], rule_id) and
                std.mem.eql(u8, t.device_id[0..t.device_id_len], device_id))
            {
                return t;
            }
        }
        for (&self.trackers) |*t| {
            if (!t.in_use) {
                t.* = .{ .in_use = true };
                const rn = @min(t.rule_id.len, rule_id.len);
                @memcpy(t.rule_id[0..rn], rule_id[0..rn]);
                t.rule_id_len = rn;
                const dn = @min(t.device_id.len, device_id.len);
                @memcpy(t.device_id[0..dn], device_id[0..dn]);
                t.device_id_len = dn;
                return t;
            }
        }
        return null;
    }

    fn pushHistory(self: *AlertEngine, ev: AlertEvent) void {
        if (self.history_count < MAX_ALERT_HISTORY) {
            // 新记录插在最前便于按时间倒序展示
            var i: usize = self.history_count;
            while (i > 0) : (i -= 1) {
                self.history[i] = self.history[i - 1];
            }
            self.history[0] = ev;
            self.history_count += 1;
        } else {
            var i: usize = MAX_ALERT_HISTORY - 1;
            while (i > 0) : (i -= 1) {
                self.history[i] = self.history[i - 1];
            }
            self.history[0] = ev;
        }
    }
};

fn makeEvent(
    rule_id: []const u8,
    device_id: []const u8,
    level: HealthLevel,
    is_recovery: bool,
    ts_ms: i64,
    comptime fmt: []const u8,
    args: anytype,
) AlertEvent {
    var ev = AlertEvent{
        .level = level,
        .is_recovery = is_recovery,
        .timestamp_utc_ms = ts_ms,
    };
    const rn = @min(ev.rule_id.len, rule_id.len);
    @memcpy(ev.rule_id[0..rn], rule_id[0..rn]);
    ev.rule_id_len = rn;
    const dn = @min(ev.device_id.len, device_id.len);
    @memcpy(ev.device_id[0..dn], device_id[0..dn]);
    ev.device_id_len = dn;
    const msg = std.fmt.bufPrint(&ev.message, fmt, args) catch "";
    ev.message_len = msg.len;
    return ev;
}

pub const TempThresholdPair = struct {
    caution: f64,
    warning: f64,
};

/// 温度阈值优先级（规范 §8.1）：设备报告阈值 > 默认值
pub fn resolveNvmeTempThresholds(wctemp_c: ?i32, cctemp_c: ?i32, default_caution: i32, default_warning: i32) TempThresholdPair {
    if (wctemp_c != null and cctemp_c != null and wctemp_c.? > 0 and cctemp_c.? > wctemp_c.?) {
        return .{ .caution = @floatFromInt(wctemp_c.?), .warning = @floatFromInt(cctemp_c.?) };
    }
    return .{ .caution = @floatFromInt(default_caution), .warning = @floatFromInt(default_warning) };
}

test "AlertEngine enforces 30s duration debounce, 5C hysteresis recovery, and repeat suppression" {
    var eng = AlertEngine{};
    const t0: i64 = 1_700_000_000_000;

    // 0s & 29s above 80C: must NOT trigger yet
    try std.testing.expect(eng.evaluateTemperature("gpu0", "RTX 2060", 82.0, 80.0, 90.0, t0) == null);
    try std.testing.expect(eng.evaluateTemperature("gpu0", "RTX 2060", 83.0, 80.0, 90.0, t0 + 29_000) == null);
    try std.testing.expectEqual(@as(u32, 0), eng.activeCount());

    // 30s: triggers caution alert
    const fired = eng.evaluateTemperature("gpu0", "RTX 2060", 83.0, 80.0, 90.0, t0 + 30_000);
    try std.testing.expect(fired != null);
    try std.testing.expectEqual(HealthLevel.caution, fired.?.level);
    try std.testing.expectEqual(@as(u32, 1), eng.activeCount());

    // 1 minute later still 83C: suppressed within 30 min window
    try std.testing.expect(eng.evaluateTemperature("gpu0", "RTX 2060", 83.0, 80.0, 90.0, t0 + 90_000) == null);

    // Drops to 77C (only 3C below 80C < 5C hysteresis): must stay active!
    try std.testing.expect(eng.evaluateTemperature("gpu0", "RTX 2060", 77.0, 80.0, 90.0, t0 + 120_000) == null);
    try std.testing.expectEqual(@as(u32, 1), eng.activeCount());

    // Drops to 74.5C (<= 80 - 5): recovers and emits recovery notification!
    const rec = eng.evaluateTemperature("gpu0", "RTX 2060", 74.5, 80.0, 90.0, t0 + 150_000);
    try std.testing.expect(rec != null);
    try std.testing.expect(rec.?.is_recovery);
    try std.testing.expectEqual(@as(u32, 0), eng.activeCount());
}

test "resolveNvmeTempThresholds prioritizes device WCTEMP/CCTEMP over fixed defaults" {
    const dev = resolveNvmeTempThresholds(80, 85, 60, 70);
    try std.testing.expectApproxEqAbs(@as(f64, 80.0), dev.caution, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 85.0), dev.warning, 1e-6);

    const def = resolveNvmeTempThresholds(null, null, 60, 70);
    try std.testing.expectApproxEqAbs(@as(f64, 60.0), def.caution, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 70.0), def.warning, 1e-6);
}
