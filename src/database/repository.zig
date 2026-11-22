const std = @import("std");
const sqlite = @import("sqlite.zig");

/// 规范 §5.2 / §5.3 本地历史数据库、迁移、分级降采样（1m / 15m）与损坏自动恢复。
pub const CURRENT_SCHEMA_VERSION: i64 = 1;

pub const TelemetryPoint = struct {
    bucket_utc_ms: i64 = 0,
    min_val: f64 = 0.0,
    avg_val: f64 = 0.0,
    max_val: f64 = 0.0,
    sample_count: i64 = 0,
};

pub const AlertRecord = struct {
    id: i64 = 0,
    rule_id: [32]u8 = std.mem.zeroes([32]u8),
    rule_id_len: usize = 0,
    device_id: [32]u8 = std.mem.zeroes([32]u8),
    device_id_len: usize = 0,
    level: u8 = 0,
    message: [160]u8 = std.mem.zeroes([160]u8),
    message_len: usize = 0,
    triggered_utc_ms: i64 = 0,
    resolved_utc_ms: i64 = 0,
    acknowledged: bool = false,

    pub fn ruleIdSlice(self: *const AlertRecord) []const u8 {
        return self.rule_id[0..self.rule_id_len];
    }
    pub fn deviceIdSlice(self: *const AlertRecord) []const u8 {
        return self.device_id[0..self.device_id_len];
    }
    pub fn messageSlice(self: *const AlertRecord) []const u8 {
        return self.message[0..self.message_len];
    }
};

/// V2.2 硬件基准测试历史记录（用于清灰/调 XMP/换盘前后成绩对比）
pub const BenchmarkHistoryRecord = struct {
    id: i64 = 0,
    timestamp_utc_ms: i64 = 0,
    test_kind: [24]u8 = std.mem.zeroes([24]u8),
    test_kind_len: usize = 0,
    outcome: [24]u8 = std.mem.zeroes([24]u8),
    outcome_len: usize = 0,
    duration_s: f64 = 0.0,
    error_count: u64 = 0,
    peak_temp_c: ?f64 = null,
    primary_metric: [96]u8 = std.mem.zeroes([96]u8),
    primary_metric_len: usize = 0,
    secondary_metric: [96]u8 = std.mem.zeroes([96]u8),
    secondary_metric_len: usize = 0,

    pub fn testKindSlice(self: *const BenchmarkHistoryRecord) []const u8 {
        return self.test_kind[0..self.test_kind_len];
    }
    pub fn outcomeSlice(self: *const BenchmarkHistoryRecord) []const u8 {
        return self.outcome[0..self.outcome_len];
    }
    pub fn primarySlice(self: *const BenchmarkHistoryRecord) []const u8 {
        return self.primary_metric[0..self.primary_metric_len];
    }
    pub fn secondarySlice(self: *const BenchmarkHistoryRecord) []const u8 {
        return self.secondary_metric[0..self.secondary_metric_len];
    }
};

pub const OpenResult = struct {
    repo: Repository,
    recovered_from_corruption: bool = false,
};

pub const Repository = struct {
    db: sqlite.Database,

    pub fn openWithRecovery(allocator: std.mem.Allocator, abs_path: []const u8) !OpenResult {
        const path_z = try allocator.dupeZ(u8, abs_path);
        defer allocator.free(path_z);

        if (tryOpenAndVerify(path_z)) |repo| {
            return .{ .repo = repo, .recovered_from_corruption = false };
        } else |_| {
            // 规范 §5.3 第 5 条：数据库损坏时重命名备份并重建，绝不阻断 GUI 启动
            const ts = std.time.timestamp();
            const backup_path = try std.fmt.allocPrint(allocator, "{s}.corrupt.{d}", .{ abs_path, ts });
            defer allocator.free(backup_path);
            std.fs.renameAbsolute(abs_path, backup_path) catch {
                std.fs.deleteFileAbsolute(abs_path) catch {};
            };

            const repo = try tryOpenAndVerify(path_z);
            return .{ .repo = repo, .recovered_from_corruption = true };
        }
    }

    pub fn openInMemory() !Repository {
        return tryOpenAndVerify(":memory:");
    }

    pub fn close(self: *Repository) void {
        self.db.close();
    }

    fn tryOpenAndVerify(path_z: [:0]const u8) !Repository {
        var db = try sqlite.Database.open(path_z);
        errdefer db.close();

        // 完整性快速检测
        var chk = try db.prepare("PRAGMA quick_check;");
        defer chk.finalize();
        if (try chk.step()) {
            const res = chk.columnText(0);
            if (!std.mem.eql(u8, res, "ok")) {
                return error.DatabaseCorrupted;
            }
        }

        var repo = Repository{ .db = db };
        try repo.migrate();
        return repo;
    }

    fn migrate(self: *Repository) !void {
        try self.db.exec(
            \\CREATE TABLE IF NOT EXISTS schema_version (
            \\  version INTEGER PRIMARY KEY,
            \\  migrated_utc_ms INTEGER NOT NULL
            \\);
        );

        var cur_ver: i64 = 0;
        {
            var st = try self.db.prepare("SELECT COALESCE(MAX(version), 0) FROM schema_version;");
            defer st.finalize();
            if (try st.step()) cur_ver = st.columnInt64(0);
        }

        if (cur_ver < 1) {
            try self.db.exec("BEGIN TRANSACTION;");
            errdefer self.db.exec("ROLLBACK;") catch {};

            try self.db.exec(
                \\CREATE TABLE IF NOT EXISTS devices (
                \\  device_id TEXT PRIMARY KEY,
                \\  device_type TEXT NOT NULL,
                \\  model TEXT NOT NULL,
                \\  first_seen_utc_ms INTEGER NOT NULL,
                \\  last_seen_utc_ms INTEGER NOT NULL
                \\);
                \\CREATE TABLE IF NOT EXISTS sensors (
                \\  sensor_id TEXT PRIMARY KEY,
                \\  device_id TEXT NOT NULL,
                \\  name TEXT NOT NULL,
                \\  unit TEXT NOT NULL,
                \\  source TEXT NOT NULL
                \\);
                \\CREATE TABLE IF NOT EXISTS telemetry_1m (
                \\  sensor_id TEXT NOT NULL,
                \\  bucket_utc_ms INTEGER NOT NULL,
                \\  min_val REAL NOT NULL,
                \\  avg_val REAL NOT NULL,
                \\  max_val REAL NOT NULL,
                \\  sample_count INTEGER NOT NULL,
                \\  PRIMARY KEY (sensor_id, bucket_utc_ms)
                \\);
                \\CREATE TABLE IF NOT EXISTS telemetry_15m (
                \\  sensor_id TEXT NOT NULL,
                \\  bucket_utc_ms INTEGER NOT NULL,
                \\  min_val REAL NOT NULL,
                \\  avg_val REAL NOT NULL,
                \\  max_val REAL NOT NULL,
                \\  sample_count INTEGER NOT NULL,
                \\  PRIMARY KEY (sensor_id, bucket_utc_ms)
                \\);
                \\CREATE TABLE IF NOT EXISTS disk_smart (
                \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
                \\  device_id TEXT NOT NULL,
                \\  collected_utc_ms INTEGER NOT NULL,
                \\  bus_type TEXT NOT NULL,
                \\  health_level INTEGER NOT NULL,
                \\  temp_c INTEGER,
                \\  summary_text TEXT NOT NULL,
                \\  has_alert INTEGER NOT NULL DEFAULT 0
                \\);
                \\CREATE TABLE IF NOT EXISTS disk_baseline (
                \\  device_id TEXT PRIMARY KEY,
                \\  recorded_utc_ms INTEGER NOT NULL,
                \\  nvme_media_errors_text TEXT NOT NULL DEFAULT '0',
                \\  ata_05 INTEGER NOT NULL DEFAULT 0,
                \\  ata_c6 INTEGER NOT NULL DEFAULT 0,
                \\  ata_bb INTEGER NOT NULL DEFAULT 0,
                \\  ata_c7 INTEGER NOT NULL DEFAULT 0
                \\);
                \\CREATE TABLE IF NOT EXISTS alerts (
                \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
                \\  rule_id TEXT NOT NULL,
                \\  device_id TEXT NOT NULL,
                \\  level INTEGER NOT NULL,
                \\  message TEXT NOT NULL,
                \\  triggered_utc_ms INTEGER NOT NULL,
                \\  resolved_utc_ms INTEGER NOT NULL DEFAULT 0,
                \\  acknowledged INTEGER NOT NULL DEFAULT 0
                \\);
                \\CREATE INDEX IF NOT EXISTS idx_t1m_bucket ON telemetry_1m(bucket_utc_ms);
                \\CREATE INDEX IF NOT EXISTS idx_t15m_bucket ON telemetry_15m(bucket_utc_ms);
                \\CREATE INDEX IF NOT EXISTS idx_smart_dev ON disk_smart(device_id, collected_utc_ms);
                \\CREATE INDEX IF NOT EXISTS idx_alerts_ts ON alerts(triggered_utc_ms DESC);
            );

            var ins = try self.db.prepare("INSERT OR REPLACE INTO schema_version (version, migrated_utc_ms) VALUES (?, ?);");
            defer ins.finalize();
            try ins.bindInt64(1, CURRENT_SCHEMA_VERSION);
            try ins.bindInt64(2, std.time.milliTimestamp());
            _ = try ins.step();

            try self.db.exec("COMMIT;");
        }

        // V2.2 幂等补充基准测试历史表（完全兼容旧版 schema_version=1 数据库）
        try self.db.exec(
            \\CREATE TABLE IF NOT EXISTS benchmark_history (
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  timestamp_utc_ms INTEGER NOT NULL,
            \\  test_kind TEXT NOT NULL,
            \\  outcome TEXT NOT NULL,
            \\  duration_s REAL NOT NULL,
            \\  error_count INTEGER NOT NULL DEFAULT 0,
            \\  peak_temp_c REAL,
            \\  primary_metric TEXT NOT NULL,
            \\  secondary_metric TEXT NOT NULL DEFAULT ''
            \\);
            \\CREATE INDEX IF NOT EXISTS idx_bench_ts ON benchmark_history(timestamp_utc_ms DESC);
        );
    }

    pub const Telemetry1mRow = struct {
        sensor_id: []const u8,
        bucket_utc_ms: i64,
        min_val: f64,
        avg_val: f64,
        max_val: f64,
        sample_count: i64,
    };

    pub fn insertTelemetry1mBatch(self: *Repository, rows: []const Telemetry1mRow) !void {
        if (rows.len == 0) return;
        try self.db.exec("BEGIN TRANSACTION;");
        errdefer self.db.exec("ROLLBACK;") catch {};

        var stmt = try self.db.prepare(
            \\INSERT OR REPLACE INTO telemetry_1m
            \\  (sensor_id, bucket_utc_ms, min_val, avg_val, max_val, sample_count)
            \\VALUES (?, ?, ?, ?, ?, ?);
        );
        defer stmt.finalize();

        for (rows) |r| {
            _ = sqlite.c.sqlite3_reset(stmt.stmt);
            try stmt.bindText(1, r.sensor_id);
            try stmt.bindInt64(2, r.bucket_utc_ms);
            try stmt.bindDouble(3, r.min_val);
            try stmt.bindDouble(4, r.avg_val);
            try stmt.bindDouble(5, r.max_val);
            try stmt.bindInt64(6, r.sample_count);
            _ = try stmt.step();
        }
        try self.db.exec("COMMIT;");
    }

    /// 规范 §5.3：1 分钟聚合降采样至 15 分钟聚合，并清理过期数据（含告警关联的 SMART 永久保留）
    pub fn downsampleAndPrune(self: *Repository, now_utc_ms: i64, retain_1m_days: u32, retain_15m_days: u32, retain_smart_days: u32) !void {
        const ms_per_day: i64 = 86_400_000;
        const cutoff_1m = now_utc_ms - @as(i64, retain_1m_days) * ms_per_day;
        const cutoff_15m = now_utc_ms - @as(i64, retain_15m_days) * ms_per_day;
        const cutoff_smart = now_utc_ms - @as(i64, retain_smart_days) * ms_per_day;

        try self.db.exec("BEGIN TRANSACTION;");
        errdefer self.db.exec("ROLLBACK;") catch {};

        // 1. 将所有 1m 数据聚合更新至 15m 表（15m = 900_000 ms）
        try self.db.exec(
            \\INSERT OR REPLACE INTO telemetry_15m (sensor_id, bucket_utc_ms, min_val, avg_val, max_val, sample_count)
            \\SELECT sensor_id,
            \\       (bucket_utc_ms / 900000) * 900000 AS b15,
            \\       MIN(min_val),
            \\       SUM(avg_val * sample_count) / SUM(sample_count),
            \\       MAX(max_val),
            \\       SUM(sample_count)
            \\FROM telemetry_1m
            \\GROUP BY sensor_id, b15;
        );

        // 2. 按保留期限清理 1m / 15m / 非告警 SMART 快照
        {
            var d1 = try self.db.prepare("DELETE FROM telemetry_1m WHERE bucket_utc_ms < ?;");
            defer d1.finalize();
            try d1.bindInt64(1, cutoff_1m);
            _ = try d1.step();
        }
        {
            var d15 = try self.db.prepare("DELETE FROM telemetry_15m WHERE bucket_utc_ms < ?;");
            defer d15.finalize();
            try d15.bindInt64(1, cutoff_15m);
            _ = try d15.step();
        }
        {
            var ds = try self.db.prepare("DELETE FROM disk_smart WHERE collected_utc_ms < ? AND has_alert = 0;");
            defer ds.finalize();
            try ds.bindInt64(1, cutoff_smart);
            _ = try ds.step();
        }

        try self.db.exec("COMMIT;");
    }

    pub fn querySeries(self: *Repository, sensor_id: []const u8, since_utc_ms: i64, use_15m: bool, out: []TelemetryPoint) !usize {
        const sql: [:0]const u8 = if (use_15m)
            "SELECT bucket_utc_ms, min_val, avg_val, max_val, sample_count FROM telemetry_15m WHERE sensor_id = ? AND bucket_utc_ms >= ? ORDER BY bucket_utc_ms ASC;"
        else
            "SELECT bucket_utc_ms, min_val, avg_val, max_val, sample_count FROM telemetry_1m WHERE sensor_id = ? AND bucket_utc_ms >= ? ORDER BY bucket_utc_ms ASC;";

        var st = try self.db.prepare(sql);
        defer st.finalize();
        try st.bindText(1, sensor_id);
        try st.bindInt64(2, since_utc_ms);

        var count: usize = 0;
        while (count < out.len and try st.step()) {
            out[count] = .{
                .bucket_utc_ms = st.columnInt64(0),
                .min_val = st.columnDouble(1),
                .avg_val = st.columnDouble(2),
                .max_val = st.columnDouble(3),
                .sample_count = st.columnInt64(4),
            };
            count += 1;
        }
        return count;
    }

    pub fn insertAlert(self: *Repository, rule_id: []const u8, device_id: []const u8, level: u8, message: []const u8, triggered_utc_ms: i64) !void {
        var st = try self.db.prepare("INSERT INTO alerts (rule_id, device_id, level, message, triggered_utc_ms) VALUES (?, ?, ?, ?, ?);");
        defer st.finalize();
        try st.bindText(1, rule_id);
        try st.bindText(2, device_id);
        try st.bindInt64(3, level);
        try st.bindText(4, message);
        try st.bindInt64(5, triggered_utc_ms);
        _ = try st.step();
    }

    pub fn queryRecentAlerts(self: *Repository, out: []AlertRecord) !usize {
        var st = try self.db.prepare("SELECT id, rule_id, device_id, level, message, triggered_utc_ms, resolved_utc_ms, acknowledged FROM alerts ORDER BY triggered_utc_ms DESC LIMIT 100;");
        defer st.finalize();
        var count: usize = 0;
        while (count < out.len and try st.step()) {
            var rec = AlertRecord{
                .id = st.columnInt64(0),
                .level = @intCast(@max(0, @min(4, st.columnInt64(3)))),
                .triggered_utc_ms = st.columnInt64(5),
                .resolved_utc_ms = st.columnInt64(6),
                .acknowledged = st.columnInt64(7) != 0,
            };
            copyInto(&rec.rule_id, &rec.rule_id_len, st.columnText(1));
            copyInto(&rec.device_id, &rec.device_id_len, st.columnText(2));
            copyInto(&rec.message, &rec.message_len, st.columnText(4));
            out[count] = rec;
            count += 1;
        }
        return count;
    }

    pub fn insertBenchmarkHistory(
        self: *Repository,
        timestamp_utc_ms: i64,
        test_kind: []const u8,
        outcome: []const u8,
        duration_s: f64,
        error_count: u64,
        peak_temp_c: ?f64,
        primary_metric: []const u8,
        secondary_metric: []const u8,
    ) !void {
        var st = try self.db.prepare(
            \\INSERT INTO benchmark_history
            \\  (timestamp_utc_ms, test_kind, outcome, duration_s, error_count, peak_temp_c, primary_metric, secondary_metric)
            \\VALUES (?, ?, ?, ?, ?, ?, ?, ?);
        );
        defer st.finalize();
        try st.bindInt64(1, timestamp_utc_ms);
        try st.bindText(2, test_kind);
        try st.bindText(3, outcome);
        try st.bindDouble(4, duration_s);
        try st.bindInt64(5, @intCast(@min(error_count, std.math.maxInt(i64))));
        if (peak_temp_c) |pt| {
            try st.bindDouble(6, pt);
        } else {
            _ = sqlite.c.sqlite3_bind_null(st.stmt, 6);
        }
        try st.bindText(7, primary_metric);
        try st.bindText(8, secondary_metric);
        _ = try st.step();
    }

    pub fn queryRecentBenchmarks(self: *Repository, out: []BenchmarkHistoryRecord) !usize {
        var st = try self.db.prepare(
            \\SELECT id, timestamp_utc_ms, test_kind, outcome, duration_s, error_count, peak_temp_c, primary_metric, secondary_metric
            \\FROM benchmark_history
            \\ORDER BY timestamp_utc_ms DESC, id DESC
            \\LIMIT 16;
        );
        defer st.finalize();
        var count: usize = 0;
        while (count < out.len and try st.step()) {
            const has_temp = sqlite.c.sqlite3_column_type(st.stmt, 6) != sqlite.c.SQLITE_NULL;
            var rec = BenchmarkHistoryRecord{
                .id = st.columnInt64(0),
                .timestamp_utc_ms = st.columnInt64(1),
                .duration_s = st.columnDouble(4),
                .error_count = @intCast(@max(0, st.columnInt64(5))),
                .peak_temp_c = if (has_temp) st.columnDouble(6) else null,
            };
            copyInto(&rec.test_kind, &rec.test_kind_len, st.columnText(2));
            copyInto(&rec.outcome, &rec.outcome_len, st.columnText(3));
            copyInto(&rec.primary_metric, &rec.primary_metric_len, st.columnText(7));
            copyInto(&rec.secondary_metric, &rec.secondary_metric_len, st.columnText(8));
            out[count] = rec;
            count += 1;
        }
        return count;
    }
};

fn copyInto(dest: []u8, out_len: *usize, src: []const u8) void {
    const n = @min(dest.len, src.len);
    @memcpy(dest[0..n], src[0..n]);
    out_len.* = n;
}

test "Repository schema migration, 1m->15m downsampling, retention pruning, and alert preservation" {
    var repo = try Repository.openInMemory();
    defer repo.close();

    const base: i64 = 1_700_000_000_000;
    // Align to 15-minute boundary
    const b0 = @divTrunc(base, 900_000) * 900_000;
    try repo.insertTelemetry1mBatch(&.{
        .{ .sensor_id = "gpu0:temp", .bucket_utc_ms = b0, .min_val = 40.0, .avg_val = 42.0, .max_val = 44.0, .sample_count = 30 },
        .{ .sensor_id = "gpu0:temp", .bucket_utc_ms = b0 + 60_000, .min_val = 42.0, .avg_val = 46.0, .max_val = 50.0, .sample_count = 30 },
    });

    // Insert old SMART snapshots: one normal (should prune), one alert-linked (must survive!)
    try repo.db.exec("INSERT INTO disk_smart (device_id, collected_utc_ms, bus_type, health_level, temp_c, summary_text, has_alert) VALUES ('d0', 1000, 'NVMe', 1, 39, 'normal', 0);");
    try repo.db.exec("INSERT INTO disk_smart (device_id, collected_utc_ms, bus_type, health_level, temp_c, summary_text, has_alert) VALUES ('d0', 1000, 'NVMe', 4, 78, 'critical', 1);");

    try repo.downsampleAndPrune(b0 + 10 * 86_400_000, 7, 30, 90);

    // 1m row older than 7 days should be pruned, while 15m aggregated row must remain!
    var pts1: [8]TelemetryPoint = undefined;
    try std.testing.expectEqual(@as(usize, 0), try repo.querySeries("gpu0:temp", 0, false, &pts1));

    var pts15: [8]TelemetryPoint = undefined;
    const n15 = try repo.querySeries("gpu0:temp", 0, true, &pts15);
    try std.testing.expectEqual(@as(usize, 1), n15);
    try std.testing.expectApproxEqAbs(@as(f64, 40.0), pts15[0].min_val, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 44.0), pts15[0].avg_val, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 50.0), pts15[0].max_val, 1e-6);

    // Verify alert-linked SMART snapshot survived pruning while normal old one was removed
    var st = try repo.db.prepare("SELECT COUNT(*) FROM disk_smart;");
    defer st.finalize();
    try std.testing.expect(try st.step());
    try std.testing.expectEqual(@as(i64, 1), st.columnInt64(0));
}

test "Repository openWithRecovery recovers automatically from corrupted database file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "corrupt_test.db" });
    defer std.testing.allocator.free(db_path);

    // Write garbage bytes to simulate corrupted SQLite file
    {
        const f = try std.fs.createFileAbsolute(db_path, .{});
        defer f.close();
        try f.writeAll("THIS IS NOT A VALID SQLITE DATABASE HEADER!!!");
    }

    var res = try Repository.openWithRecovery(std.testing.allocator, db_path);
    defer res.repo.close();
    try std.testing.expect(res.recovered_from_corruption);
}

test "Repository benchmark_history persists and retrieves comparison records" {
    var repo = try Repository.openInMemory();
    defer repo.close();

    try repo.insertBenchmarkHistory(1_700_000_001_000, "cpu_stress", "passed", 15.2, 0, 68.5, "1T 42.1 / MT 340.5 MOPS (8.1x)", "Drop 1.2%");
    try repo.insertBenchmarkHistory(1_700_000_002_000, "disk_bench", "passed", 8.4, 0, null, "SEQ W520/R780 MB/s", "RND4K R4100/W3200 IOPS");

    var rows: [8]BenchmarkHistoryRecord = undefined;
    const n = try repo.queryRecentBenchmarks(&rows);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("disk_bench", rows[0].testKindSlice());
    try std.testing.expect(rows[0].peak_temp_c == null);
    try std.testing.expectEqualStrings("cpu_stress", rows[1].testKindSlice());
    try std.testing.expectApproxEqAbs(@as(f64, 68.5), rows[1].peak_temp_c.?, 1e-6);
}
