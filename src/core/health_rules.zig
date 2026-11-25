const std = @import("std");
const sensor = @import("sensor.zig");
const HealthLevel = sensor.HealthLevel;
const nvme = @import("../collectors/storage/nvme_smart.zig");
const ata = @import("../collectors/storage/ata_smart.zig");
const i18n = @import("i18n.zig");

/// 与 data/drive_attributes.toml 中 category = "ssd_life" 同步登记的 SSD 剩余寿命属性 ID 列表（单元测试强制一致性校验）
pub const SSD_LIFE_ATTR_IDS = [_]u8{ 0xE7, 0xE9 };

/// 规范 §2.5.5 磁盘健康判定引擎与基线机制。
/// 严格遵守红线 #3/#4：
/// - 仅允许触发规范 §2.5.5 登记的 21 条编号规则，不得新增未登记逻辑；
/// - 禁止将 SMART 属性简单相加拼凑所谓“健康百分比”；
/// - 每条触发规则必须携带规则 ID、级别和可读证据数值。
pub const MAX_TRIGGERED_RULES = 24;

pub const RuleHit = struct {
    rule_id: [:0]const u8 = "",
    level: HealthLevel = .normal,
    evidence: [128]u8 = std.mem.zeroes([128]u8),
    evidence_len: usize = 0,

    pub fn evidenceSlice(self: *const RuleHit) []const u8 {
        return self.evidence[0..self.evidence_len];
    }
};

pub const HealthAssessment = struct {
    overall: HealthLevel = .unknown,
    hits: [MAX_TRIGGERED_RULES]RuleHit = [_]RuleHit{.{}} ** MAX_TRIGGERED_RULES,
    hit_count: usize = 0,
    counter_decreased_note: bool = false,

    pub fn addHit(self: *HealthAssessment, rule_id: [:0]const u8, level: HealthLevel, comptime fmt: []const u8, args: anytype) void {
        self.overall = HealthLevel.max(self.overall, level);
        if (self.hit_count >= MAX_TRIGGERED_RULES) return;
        var hit = RuleHit{
            .rule_id = rule_id,
            .level = level,
        };
        const s = std.fmt.bufPrint(&hit.evidence, fmt, args) catch "";
        hit.evidence_len = s.len;
        self.hits[self.hit_count] = hit;
        self.hit_count += 1;
    }

    pub fn slice(self: *const HealthAssessment) []const RuleHit {
        return self.hits[0..self.hit_count];
    }
};

pub const RuleThresholds = struct {
    nvme_used_caution: u32 = 80,
    nvme_used_warning: u32 = 100,
    ssd_life_left_warning: u32 = 10,
};

/// 规范 §2.5.5 基线记录（首次识别磁盘时记录，支持用户重设基线）
pub const DiskBaseline = struct {
    initialized: bool = false,
    recorded_utc_ms: i64 = 0,

    // NVMe 计数型基线
    nvme_media_errors: u128 = 0,

    // ATA 计数型基线
    ata_05_raw: u64 = 0,
    ata_c6_raw: u64 = 0,
    ata_bb_raw: u64 = 0,
    ata_c7_raw: u64 = 0,

    pub fn captureFromNvme(data: *const nvme.NvmeSmartData) DiskBaseline {
        return .{
            .initialized = true,
            .recorded_utc_ms = std.time.milliTimestamp(),
            .nvme_media_errors = data.media_errors,
        };
    }

    pub fn captureFromAta(data: *const ata.AtaSmartData) DiskBaseline {
        return .{
            .initialized = true,
            .recorded_utc_ms = std.time.milliTimestamp(),
            .ata_05_raw = if (data.findAttr(0x05)) |a| a.rawU48() else 0,
            .ata_c6_raw = if (data.findAttr(0xC6)) |a| a.rawU48() else 0,
            .ata_bb_raw = if (data.findAttr(0xBB)) |a| a.rawU48() else 0,
            .ata_c7_raw = if (data.findAttr(0xC7)) |a| a.rawU48() else 0,
        };
    }
};

/// 评估 NVMe SMART（规范 §2.5.5 全部 10 条 NVMe 规则）
pub fn evaluateNvme(data: *const nvme.NvmeSmartData, baseline: ?*const DiskBaseline, cfg: RuleThresholds) HealthAssessment {
    var out = HealthAssessment{};
    if (data.status != .ok) {
        out.overall = .unknown;
        return out;
    }
    out.overall = .normal;

    const cw = data.critical_warning;
    if ((cw & (1 << 0)) != 0) {
        out.addHit("NVME-CW-SPARE", .critical, "{s}", .{i18n.trSlice(
            "Critical Warning bit 0 置位（可用备用空间低于阈值）",
            "Critical Warning bit 0 set (available spare below threshold)",
            "Critical Warning ビット0検出（予備領域が閾値未満）",
        )});
    }
    if ((cw & (1 << 1)) != 0) {
        out.addHit("NVME-CW-TEMP", .warning, "{s}", .{i18n.trSlice(
            "Critical Warning bit 1 置位（温度超出设备安全范围）",
            "Critical Warning bit 1 set (temperature outside safe range)",
            "Critical Warning ビット1検出（温度が許容範囲外）",
        )});
    }
    if ((cw & (1 << 2)) != 0) {
        out.addHit("NVME-CW-RELIABILITY", .critical, "{s}", .{i18n.trSlice(
            "Critical Warning bit 2 置位（NVM 子系统可靠性显著下降）",
            "Critical Warning bit 2 set (NVM subsystem reliability degraded)",
            "Critical Warning ビット2検出（NVM信頼性低下）",
        )});
    }
    if ((cw & (1 << 3)) != 0) {
        out.addHit("NVME-CW-READONLY", .critical, "{s}", .{i18n.trSlice(
            "Critical Warning bit 3 置位（介质已进入只读保护模式）",
            "Critical Warning bit 3 set (media placed in read-only mode)",
            "Critical Warning ビット3検出（メディア読取専用モード）",
        )});
    }
    if ((cw & (1 << 4)) != 0) {
        out.addHit("NVME-CW-BACKUP", .warning, "{s}", .{i18n.trSlice(
            "Critical Warning bit 4 置位（易失性写缓存备份设备失效）",
            "Critical Warning bit 4 set (volatile memory backup device failed)",
            "Critical Warning ビット4検出（キャッシュ保護装置異常）",
        )});
    }

    if (data.available_spare < data.available_spare_threshold) {
        out.addHit("NVME-SPARE", .critical, "{s}: {d}% < {d}%", .{
            i18n.trSlice("可用备用空间低于阈值", "Available spare below threshold", "予備領域が閾値未満"),
            data.available_spare,
            data.available_spare_threshold,
        });
    }

    if (data.media_errors > 0) {
        out.addHit("NVME-MEDIA", .caution, "{s}: {d}", .{
            i18n.trSlice("介质与数据完整性错误", "Media & data integrity errors", "メディア・整合性エラー"),
            data.media_errors,
        });
    }
    if (baseline) |bl| {
        if (bl.initialized) {
            if (data.media_errors > bl.nvme_media_errors) {
                out.addHit("NVME-MEDIA-INC", .warning, "{s}: {d} -> {d}", .{
                    i18n.trSlice("介质错误相对基线增加", "Media errors increased vs baseline", "メディアエラーが基準値から増加"),
                    bl.nvme_media_errors,
                    data.media_errors,
                });
            } else if (data.media_errors < bl.nvme_media_errors) {
                out.counter_decreased_note = true;
            }
        }
    }

    if (data.percentage_used >= cfg.nvme_used_warning) {
        out.addHit("NVME-USED-2", .warning, "{s}: {d}% >= {d}%", .{
            i18n.trSlice("预计寿命使用率达到警告阈值", "Percentage used reached warning threshold", "寿命消費率が警告閾値に到達"),
            data.percentage_used,
            cfg.nvme_used_warning,
        });
    } else if (data.percentage_used >= cfg.nvme_used_caution) {
        out.addHit("NVME-USED-1", .caution, "{s}: {d}% >= {d}%", .{
            i18n.trSlice("预计寿命使用率达到注意阈值", "Percentage used reached caution threshold", "寿命消費率が注意閾値に到達"),
            data.percentage_used,
            cfg.nvme_used_caution,
        });
    }

    return out;
}

/// 评估 ATA/SATA SMART（规范 §2.5.5 全部 11 条 ATA/SATA SSD 规则）
pub fn evaluateAta(data: *const ata.AtaSmartData, baseline: ?*const DiskBaseline, cfg: RuleThresholds) HealthAssessment {
    var out = HealthAssessment{};
    if (data.status != .ok or data.attr_count == 0) {
        out.overall = .unknown;
        return out;
    }
    out.overall = .normal;

    if (data.smart_status_checked and data.smart_status_failed) {
        out.addHit("ATA-STATUS", .critical, "{s}", .{i18n.trSlice(
            "SMART RETURN STATUS 报告设备阈值超限",
            "SMART RETURN STATUS reported threshold exceeded",
            "SMART RETURN STATUS が閾値超過を報告",
        )});
    }

    // ATA-PREFAIL & ATA-OLDAGE
    for (data.attrs[0..data.attr_count]) |a| {
        if (a.has_threshold and a.threshold != 0 and a.current <= a.threshold) {
            if (a.isPrefail()) {
                out.addHit("ATA-PREFAIL", .critical, "Prefail 0x{X:0>2}({s}) {d} <= {d}", .{
                    a.id,
                    ata.AtaAttribute.knownNameZh(a.id),
                    a.current,
                    a.threshold,
                });
            } else {
                out.addHit("ATA-OLDAGE", .caution, "Old-age 0x{X:0>2}({s}) {d} <= {d}", .{
                    a.id,
                    ata.AtaAttribute.knownNameZh(a.id),
                    a.current,
                    a.threshold,
                });
            }
        }
    }

    // 05 Reallocated Sectors Count
    if (data.findAttr(0x05)) |a05| {
        const raw = a05.rawU48();
        if (raw > 0) {
            out.addHit("ATA-05", .caution, "05 {s} = {d}", .{ ata.AtaAttribute.knownNameZh(0x05), raw });
        }
        if (baseline) |bl| if (bl.initialized) {
            if (raw > bl.ata_05_raw) {
                out.addHit("ATA-05-INC", .warning, "05 {s}: {d} -> {d}", .{
                    i18n.trSlice("重映射扇区增加", "Reallocated sectors increased", "代替処理セクタ増加"),
                    bl.ata_05_raw,
                    raw,
                });
            } else if (raw < bl.ata_05_raw) {
                out.counter_decreased_note = true;
            }
        };
    }

    // C5 Current Pending Sector
    if (data.findAttr(0xC5)) |ac5| {
        const raw = ac5.rawU48();
        if (raw > 0) {
            out.addHit("ATA-C5", .warning, "C5 {s} = {d}", .{ ata.AtaAttribute.knownNameZh(0xC5), raw });
        }
    }

    // C6 Offline Uncorrectable
    if (data.findAttr(0xC6)) |ac6| {
        const raw = ac6.rawU48();
        if (raw > 0) {
            out.addHit("ATA-C6", .warning, "C6 {s} = {d}", .{ ata.AtaAttribute.knownNameZh(0xC6), raw });
        }
        if (baseline) |bl| if (bl.initialized) {
            if (raw > bl.ata_c6_raw) {
                out.addHit("ATA-C6-INC", .critical, "C6 {s}: {d} -> {d}", .{
                    i18n.trSlice("离线不可校正扇区增加", "Offline uncorrectable increased", "回復不能セクタ増加"),
                    bl.ata_c6_raw,
                    raw,
                });
            } else if (raw < bl.ata_c6_raw) {
                out.counter_decreased_note = true;
            }
        };
    }

    // BB Reported Uncorrectable Errors
    if (data.findAttr(0xBB)) |abb| {
        const raw = abb.rawU48();
        if (baseline) |bl| if (bl.initialized) {
            if (raw > bl.ata_bb_raw) {
                out.addHit("ATA-BB", .caution, "BB {s}: {d} -> {d}", .{
                    i18n.trSlice("不可校正错误增加", "Uncorrectable errors increased", "回復不能エラー増加"),
                    bl.ata_bb_raw,
                    raw,
                });
            } else if (raw < bl.ata_bb_raw) {
                out.counter_decreased_note = true;
            }
        };
    }

    // C7 UDMA CRC Error Count（规范特别说明：提示检查线缆接口，不判定为盘片损坏）
    if (data.findAttr(0xC7)) |ac7| {
        const raw = ac7.rawU48();
        if (baseline) |bl| if (bl.initialized) {
            if (raw > bl.ata_c7_raw) {
                out.addHit("ATA-C7-INC", .caution, "C7 {s} ({d} -> {d})", .{
                    i18n.trSlice("接口 CRC 错误增加，请检查数据线/接口", "CRC errors increased; check cable/port", "CRCエラー増加（ケーブル/端子を確認）"),
                    bl.ata_c7_raw,
                    raw,
                });
            } else if (raw < bl.ata_c7_raw) {
                out.counter_decreased_note = true;
            }
        };
    }

    // SSD-LIFE（按 data/drive_attributes.toml 中 category = "ssd_life" 登记表驱动查找）
    var life_attr: ?ata.AtaAttribute = null;
    for (SSD_LIFE_ATTR_IDS) |life_id| {
        if (data.findAttr(life_id)) |a| {
            life_attr = a;
            break;
        }
    }
    if (life_attr) |la| {
        if (la.current > 0 and la.current < cfg.ssd_life_left_warning) {
            out.addHit("SSD-LIFE", .warning, "{s} 0x{X:0>2}: {d}% < {d}%", .{
                i18n.trSlice("SSD 寿命指标偏低", "SSD life left low", "SSD 残り寿命低下"),
                la.id,
                la.current,
                cfg.ssd_life_left_warning,
            });
        }
    }

    return out;
}

fn hasRule(res: *const HealthAssessment, id: []const u8) bool {
    for (res.slice()) |h| {
        if (std.mem.eql(u8, h.rule_id, id)) return true;
    }
    return false;
}

test "All 10 NVMe health rules (§2.5.5) trigger accurately with exact rule IDs" {
    const cfg = RuleThresholds{};

    // Healthy NVMe
    var d = nvme.NvmeSmartData{
        .status = .ok,
        .available_spare = 100,
        .available_spare_threshold = 10,
        .percentage_used = 18,
    };
    const ok_res = evaluateNvme(&d, null, cfg);
    try std.testing.expectEqual(HealthLevel.normal, ok_res.overall);
    try std.testing.expectEqual(@as(usize, 0), ok_res.hit_count);

    // Unavailable data => unknown (never normal!)
    var bad_stat = d;
    bad_stat.status = .access_denied;
    try std.testing.expectEqual(HealthLevel.unknown, evaluateNvme(&bad_stat, null, cfg).overall);

    // Critical Warning bits 0..4 + spare + media + media_inc + used-2
    d.critical_warning = 0x1F;
    d.available_spare = 5;
    d.media_errors = 3;
    d.percentage_used = 105;
    const bl = DiskBaseline{ .initialized = true, .nvme_media_errors = 1 };
    const r = evaluateNvme(&d, &bl, cfg);
    try std.testing.expectEqual(HealthLevel.critical, r.overall);
    try std.testing.expect(hasRule(&r, "NVME-CW-SPARE"));
    try std.testing.expect(hasRule(&r, "NVME-CW-TEMP"));
    try std.testing.expect(hasRule(&r, "NVME-CW-RELIABILITY"));
    try std.testing.expect(hasRule(&r, "NVME-CW-READONLY"));
    try std.testing.expect(hasRule(&r, "NVME-CW-BACKUP"));
    try std.testing.expect(hasRule(&r, "NVME-SPARE"));
    try std.testing.expect(hasRule(&r, "NVME-MEDIA"));
    try std.testing.expect(hasRule(&r, "NVME-MEDIA-INC"));
    try std.testing.expect(hasRule(&r, "NVME-USED-2"));

    // NVME-USED-1 caution band (80..99)
    var d_used = nvme.NvmeSmartData{ .status = .ok, .available_spare = 100, .available_spare_threshold = 10, .percentage_used = 82 };
    const r_u1 = evaluateNvme(&d_used, null, cfg);
    try std.testing.expectEqual(HealthLevel.caution, r_u1.overall);
    try std.testing.expect(hasRule(&r_u1, "NVME-USED-1"));
}

test "All 11 ATA/SATA SSD health rules (§2.5.5) trigger accurately with baseline" {
    const cfg = RuleThresholds{};
    var d = ata.AtaSmartData{
        .status = .ok,
        .smart_status_checked = true,
        .smart_status_failed = true,
        .attr_count = 8,
    };
    d.attrs[0] = .{ .id = 0x05, .flags = 0x0033, .current = 30, .threshold = 36, .has_threshold = true, .raw_bytes = .{ 5, 0, 0, 0, 0, 0 } };
    d.attrs[1] = .{ .id = 0x09, .flags = 0x0032, .current = 10, .threshold = 20, .has_threshold = true };
    d.attrs[2] = .{ .id = 0xC5, .raw_bytes = .{ 2, 0, 0, 0, 0, 0 } };
    d.attrs[3] = .{ .id = 0xC6, .raw_bytes = .{ 4, 0, 0, 0, 0, 0 } };
    d.attrs[4] = .{ .id = 0xBB, .raw_bytes = .{ 3, 0, 0, 0, 0, 0 } };
    d.attrs[5] = .{ .id = 0xC7, .raw_bytes = .{ 12, 0, 0, 0, 0, 0 } };
    d.attrs[6] = .{ .id = 0xE7, .current = 8 };
    d.attrs[7] = .{ .id = 0xC2, .raw_bytes = .{ 38, 0, 0, 0, 0, 0 } };

    const bl = DiskBaseline{
        .initialized = true,
        .ata_05_raw = 2,
        .ata_c6_raw = 1,
        .ata_bb_raw = 0,
        .ata_c7_raw = 10,
    };

    const r = evaluateAta(&d, &bl, cfg);
    try std.testing.expectEqual(HealthLevel.critical, r.overall);
    try std.testing.expect(hasRule(&r, "ATA-STATUS"));
    try std.testing.expect(hasRule(&r, "ATA-PREFAIL"));
    try std.testing.expect(hasRule(&r, "ATA-OLDAGE"));
    try std.testing.expect(hasRule(&r, "ATA-05"));
    try std.testing.expect(hasRule(&r, "ATA-05-INC"));
    try std.testing.expect(hasRule(&r, "ATA-C5"));
    try std.testing.expect(hasRule(&r, "ATA-C6"));
    try std.testing.expect(hasRule(&r, "ATA-C6-INC"));
    try std.testing.expect(hasRule(&r, "ATA-BB"));
    try std.testing.expect(hasRule(&r, "ATA-C7-INC"));
    try std.testing.expect(hasRule(&r, "SSD-LIFE"));
}

test "SSD-LIFE attribute IDs stay synchronized with data/drive_attributes.toml" {
    const toml = @import("../utils/toml.zig");
    const file = std.fs.cwd().openFile("data/drive_attributes.toml", .{}) catch return;
    defer file.close();
    const content = try file.readToEndAlloc(std.testing.allocator, 64 * 1024);
    defer std.testing.allocator.free(content);

    var doc = try toml.Document.parse(std.testing.allocator, content);
    defer doc.deinit();

    // 校验每个登记在 SSD_LIFE_ATTR_IDS 中的属性在 data/drive_attributes.toml 均标记为 category = "ssd_life"
    for (SSD_LIFE_ATTR_IDS) |attr_id| {
        var sec_buf: [16]u8 = undefined;
        const sec = try std.fmt.bufPrint(&sec_buf, "attr_{X:0>2}", .{attr_id});
        try std.testing.expectEqual(@as(?i64, attr_id), doc.getInt(sec, "id"));
        const cat = doc.getString(sec, "category");
        try std.testing.expect(cat != null and std.mem.eql(u8, cat.?, "ssd_life"));
    }
}
