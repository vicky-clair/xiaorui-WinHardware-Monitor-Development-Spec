const std = @import("std");
const win32 = @import("win32.zig");

/// Windows PDH 性能计数器封装（使用 PdhAddEnglishCounterW 兼容全语言 Windows）。
/// 采集：
/// - `\Processor Information(_Total)\% Processor Utility`（Win11 任务管理器算法）
/// - `\Processor Information(_Total)\% Processor Performance`（用于计算 CPU 频率）
/// - `\PhysicalDisk(_Total)\Disk Read Bytes/sec`、`Disk Write Bytes/sec`、`Disk Transfers/sec`（实时存储吞吐与 IOPS）
pub const PdhCpuCollector = struct {
    query: win32.PDH_HQUERY = null,
    c_utility: win32.PDH_HCOUNTER = null,
    c_perf: win32.PDH_HCOUNTER = null,
    c_disk_read_bps: win32.PDH_HCOUNTER = null,
    c_disk_write_bps: win32.PDH_HCOUNTER = null,
    c_disk_iops: win32.PDH_HCOUNTER = null,
    primed: bool = false,

    pub const Sample = struct {
        utility_pct: ?f64 = null,
        perf_pct: ?f64 = null,
        disk_read_mbs: ?f64 = null,
        disk_write_mbs: ?f64 = null,
        disk_iops: ?f64 = null,
    };

    pub fn init() PdhCpuCollector {
        var self = PdhCpuCollector{};
        if (win32.PdhOpenQueryW(null, 0, &self.query) != 0) {
            self.query = null;
            return self;
        }
        const util_path = std.unicode.utf8ToUtf16LeStringLiteral("\\Processor Information(_Total)\\% Processor Utility");
        const perf_path = std.unicode.utf8ToUtf16LeStringLiteral("\\Processor Information(_Total)\\% Processor Performance");
        const dr_path = std.unicode.utf8ToUtf16LeStringLiteral("\\PhysicalDisk(_Total)\\Disk Read Bytes/sec");
        const dw_path = std.unicode.utf8ToUtf16LeStringLiteral("\\PhysicalDisk(_Total)\\Disk Write Bytes/sec");
        const di_path = std.unicode.utf8ToUtf16LeStringLiteral("\\PhysicalDisk(_Total)\\Disk Transfers/sec");

        if (win32.PdhAddEnglishCounterW(self.query, util_path, 0, &self.c_utility) != 0) self.c_utility = null;
        if (win32.PdhAddEnglishCounterW(self.query, perf_path, 0, &self.c_perf) != 0) self.c_perf = null;
        if (win32.PdhAddEnglishCounterW(self.query, dr_path, 0, &self.c_disk_read_bps) != 0) self.c_disk_read_bps = null;
        if (win32.PdhAddEnglishCounterW(self.query, dw_path, 0, &self.c_disk_write_bps) != 0) self.c_disk_write_bps = null;
        if (win32.PdhAddEnglishCounterW(self.query, di_path, 0, &self.c_disk_iops) != 0) self.c_disk_iops = null;

        if (win32.PdhCollectQueryData(self.query) == 0) {
            self.primed = true;
        }
        return self;
    }

    pub fn deinit(self: *PdhCpuCollector) void {
        if (self.query != null) {
            _ = win32.PdhCloseQuery(self.query);
            self.query = null;
            self.c_utility = null;
            self.c_perf = null;
            self.c_disk_read_bps = null;
            self.c_disk_write_bps = null;
            self.c_disk_iops = null;
        }
    }

    pub fn sample(self: *PdhCpuCollector) Sample {
        var out = Sample{};
        if (self.query == null) return out;
        if (win32.PdhCollectQueryData(self.query) != 0) return out;
        if (!self.primed) {
            self.primed = true;
            return out;
        }

        if (readCounter(self.c_utility, win32.PDH_FMT_DOUBLE)) |v| {
            out.utility_pct = std.math.clamp(v, 0.0, 100.0);
        }
        if (readCounter(self.c_perf, win32.PDH_FMT_DOUBLE | win32.PDH_FMT_NOCAP100)) |v| {
            if (v > 0.0 and v < 500.0) out.perf_pct = v;
        }
        if (readCounter(self.c_disk_read_bps, win32.PDH_FMT_DOUBLE)) |v| {
            if (v >= 0.0) out.disk_read_mbs = v / (1024.0 * 1024.0);
        }
        if (readCounter(self.c_disk_write_bps, win32.PDH_FMT_DOUBLE)) |v| {
            if (v >= 0.0) out.disk_write_mbs = v / (1024.0 * 1024.0);
        }
        if (readCounter(self.c_disk_iops, win32.PDH_FMT_DOUBLE)) |v| {
            if (v >= 0.0) out.disk_iops = v;
        }
        return out;
    }

    fn readCounter(counter: win32.PDH_HCOUNTER, flags: win32.DWORD) ?f64 {
        if (counter == null) return null;
        var val = win32.PDH_FMT_COUNTERVALUE{};
        if (win32.PdhGetFormattedCounterValue(counter, flags, null, &val) == 0 and val.CStatus == 0) {
            return val.doubleValue;
        }
        return null;
    }
};
