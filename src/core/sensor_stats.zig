const std = @import("std");

/// HWiNFO64 风格全局传感器统计表（跨平台核心层，不依赖任何 OS API）。
/// 维护全部活跃传感器的当前值 / 最小值 / 平均值 / 最大值与采样次数，支持一键清零与 CSV 导出。
pub const MAX_STAT_SENSORS = 128;

pub const SensorStatEntry = struct {
    category: [32]u8 = std.mem.zeroes([32]u8),
    category_len: usize = 0,
    name: [64]u8 = std.mem.zeroes([64]u8),
    name_len: usize = 0,
    unit: [12]u8 = std.mem.zeroes([12]u8),
    unit_len: usize = 0,

    current: f64 = 0.0,
    min_val: f64 = 0.0,
    max_val: f64 = 0.0,
    sum_val: f64 = 0.0,
    count: u64 = 0,

    pub fn categorySlice(self: *const SensorStatEntry) []const u8 {
        return self.category[0..self.category_len];
    }
    pub fn nameSlice(self: *const SensorStatEntry) []const u8 {
        return self.name[0..self.name_len];
    }
    pub fn unitSlice(self: *const SensorStatEntry) []const u8 {
        return self.unit[0..self.unit_len];
    }
    pub fn avg(self: *const SensorStatEntry) f64 {
        return if (self.count > 0) self.sum_val / @as(f64, @floatFromInt(self.count)) else self.current;
    }
};

pub const SensorStatsTable = struct {
    entries: [MAX_STAT_SENSORS]SensorStatEntry = [_]SensorStatEntry{.{}} ** MAX_STAT_SENSORS,
    count: usize = 0,

    pub fn record(self: *SensorStatsTable, category: []const u8, name: []const u8, unit: []const u8, value: f64) void {
        if (std.math.isNan(value) or std.math.isInf(value)) return;

        for (self.entries[0..self.count]) |*e| {
            if (std.mem.eql(u8, e.categorySlice(), category) and std.mem.eql(u8, e.nameSlice(), name)) {
                e.current = value;
                if (e.count == 0) {
                    e.min_val = value;
                    e.max_val = value;
                } else {
                    if (value < e.min_val) e.min_val = value;
                    if (value > e.max_val) e.max_val = value;
                }
                e.sum_val += value;
                e.count += 1;
                return;
            }
        }

        if (self.count >= MAX_STAT_SENSORS) return;
        var e = SensorStatEntry{
            .current = value,
            .min_val = value,
            .max_val = value,
            .sum_val = value,
            .count = 1,
        };
        copyFixed(&e.category, &e.category_len, category);
        copyFixed(&e.name, &e.name_len, name);
        copyFixed(&e.unit, &e.unit_len, unit);
        self.entries[self.count] = e;
        self.count += 1;
    }

    /// 一键重置所有传感器的 Min / Avg / Max 统计基线（保留当前值）
    pub fn resetStats(self: *SensorStatsTable) void {
        for (self.entries[0..self.count]) |*e| {
            e.min_val = e.current;
            e.max_val = e.current;
            e.sum_val = e.current;
            e.count = 1;
        }
    }

    pub fn slice(self: *const SensorStatsTable) []const SensorStatEntry {
        return self.entries[0..self.count];
    }

    /// 导出标准 UTF-8 CSV 报表（含 UTF-8 BOM 兼容 Excel 中文打开）
    pub fn exportCsv(self: *const SensorStatsTable, allocator: std.mem.Allocator) ![]u8 {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(allocator);
        const w = out.writer(allocator);

        // UTF-8 BOM for clean Chinese display in Excel
        try w.writeAll("\xEF\xBB\xBFCategory,Sensor,Unit,Current,Min,Avg,Max,Samples\r\n");
        for (self.entries[0..self.count]) |*e| {
            try w.print("\"{s}\",\"{s}\",\"{s}\",{d:.2},{d:.2},{d:.2},{d:.2},{d}\r\n", .{
                e.categorySlice(),
                e.nameSlice(),
                e.unitSlice(),
                e.current,
                e.min_val,
                e.avg(),
                e.max_val,
                e.count,
            });
        }
        return out.toOwnedSlice(allocator);
    }
};

fn copyFixed(dest: []u8, out_len: *usize, src: []const u8) void {
    const n = @min(dest.len, src.len);
    @memcpy(dest[0..n], src[0..n]);
    out_len.* = n;
}

test "SensorStatsTable tracks min/avg/max, resets cleanly, and exports CSV" {
    var tbl = SensorStatsTable{};
    tbl.record("CPU", "CPU Usage", "%", 20.0);
    tbl.record("CPU", "CPU Usage", "%", 80.0);
    tbl.record("CPU", "CPU Usage", "%", 50.0);
    tbl.record("GPU", "GPU Temp", "C", 45.5);

    try std.testing.expectEqual(@as(usize, 2), tbl.count);
    const e0 = tbl.entries[0];
    try std.testing.expectApproxEqAbs(@as(f64, 50.0), e0.current, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 20.0), e0.min_val, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 80.0), e0.max_val, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 50.0), e0.avg(), 1e-6);

    const csv = try tbl.exportCsv(std.testing.allocator);
    defer std.testing.allocator.free(csv);
    try std.testing.expect(std.mem.indexOf(u8, csv, "\"CPU\",\"CPU Usage\",\"%\",50.00,20.00,50.00,80.00,3") != null);

    tbl.resetStats();
    try std.testing.expectApproxEqAbs(@as(f64, 50.0), tbl.entries[0].min_val, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 50.0), tbl.entries[0].max_val, 1e-6);
    try std.testing.expectEqual(@as(u64, 1), tbl.entries[0].count);
}
