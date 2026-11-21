const std = @import("std");
const builtin = @import("builtin");
const win32 = @import("win32.zig");
const smbios = @import("smbios.zig");
const pdh = @import("pdh.zig");
const sensor = @import("../../core/sensor.zig");
const i18n = @import("../../core/i18n.zig");

pub const MAX_LOGICAL_CORES = 64;

/// 电池与电源状态（台式机无电池时 has_battery = false，绝不伪造电量）
pub const BatterySnapshot = struct {
    has_battery: bool = false,
    ac_online: bool = true,
    charge_pct: ?u8 = null,
    life_time_sec: ?u32 = null,
};

/// Windows 系统信息（CPU 总体/每核、内存、磁盘吞吐、电池、SMBIOS、运行时间）统一快照
pub const SystemSnapshot = struct {
    collected_utc_ms: i64 = 0,
    uptime_seconds: u64 = 0,

    // CPU
    cpu_name: [128]u8 = std.mem.zeroes([128]u8),
    cpu_name_len: usize = 0,
    logical_cores: u32 = 0,
    base_clock_mhz: u32 = 0,

    cpu_usage_pct: ?f64 = null,
    cpu_usage_status: sensor.SensorStatus = .unknown,
    cpu_usage_source: [:0]const u8 = "pdh:% Processor Utility",

    cpu_clock_mhz: ?f64 = null,
    cpu_clock_status: sensor.SensorStatus = .unknown,
    cpu_clock_accuracy: sensor.SensorAccuracy = .derived,
    cpu_clock_source: [:0]const u8 = "pdh:% Processor Performance",

    // 每核逻辑处理器实时使用率（NtQuerySystemInformation）
    per_core_usage: [MAX_LOGICAL_CORES]f32 = [_]f32{0.0} ** MAX_LOGICAL_CORES,
    per_core_count: usize = 0,

    // 实时存储总吞吐与 IOPS（PDH PhysicalDisk _Total）
    disk_read_mbs: ?f64 = null,
    disk_write_mbs: ?f64 = null,
    disk_iops: ?f64 = null,

    // 电池 / 供电状态
    battery: BatterySnapshot = .{},

    // Memory
    mem_total_bytes: u64 = 0,
    mem_used_bytes: u64 = 0,
    mem_avail_bytes: u64 = 0,
    mem_load_pct: ?f64 = null,
    mem_status: sensor.SensorStatus = .unknown,

    // SMBIOS (主板与内存插槽，仅启动采集一次，缓存复用)
    smbios_info: smbios.SmbiosData = .{},

    pub fn cpuNameSlice(self: *const SystemSnapshot) []const u8 {
        if (self.cpu_name_len == 0) return i18n.trSlice("未知处理器", "Unknown CPU", "不明な CPU");
        return self.cpu_name[0..self.cpu_name_len];
    }
};

/// 跨平台系统信息采集器类型分发（Windows 走 Win32/PDH/SMBIOS，Linux 走 /proc & /sys）
pub const SystemInfoProvider = if (builtin.os.tag == .windows)
    WinSystemInfoProvider
else
    @import("../linux/system_info.zig").LinuxSystemInfoProvider;

pub const WinSystemInfoProvider = struct {
    pdh_cpu: pdh.PdhCpuCollector,
    prev_idle: u64 = 0,
    prev_kernel: u64 = 0,
    prev_user: u64 = 0,
    has_prev_times: bool = false,

    prev_core_info: [MAX_LOGICAL_CORES]win32.SYSTEM_PROCESSOR_PERFORMANCE_INFORMATION =
        [_]win32.SYSTEM_PROCESSOR_PERFORMANCE_INFORMATION{.{}} ** MAX_LOGICAL_CORES,
    prev_core_count: usize = 0,

    // 静态信息缓存（无需每次轮询重读注册表/SMBIOS）
    cpu_name: [128]u8 = std.mem.zeroes([128]u8),
    cpu_name_len: usize = 0,
    logical_cores: u32 = 0,
    base_clock_mhz: u32 = 0,
    smbios_info: smbios.SmbiosData = .{},

    pub fn init(allocator: std.mem.Allocator) WinSystemInfoProvider {
        var self = WinSystemInfoProvider{
            .pdh_cpu = pdh.PdhCpuCollector.init(),
        };

        var sys_info = win32.SYSTEM_INFO{};
        win32.GetSystemInfo(&sys_info);
        self.logical_cores = sys_info.dwNumberOfProcessors;

        readCpuRegistry(&self.cpu_name, &self.cpu_name_len, &self.base_clock_mhz);
        self.smbios_info = smbios.queryLocal(allocator);

        if (self.base_clock_mhz == 0 and self.smbios_info.cpu_current_speed_mhz > 0) {
            self.base_clock_mhz = self.smbios_info.cpu_current_speed_mhz;
        }

        // Prime GetSystemTimes baseline
        var idle: win32.FILETIME = undefined;
        var kernel: win32.FILETIME = undefined;
        var user: win32.FILETIME = undefined;
        if (win32.GetSystemTimes(&idle, &kernel, &user) != 0) {
            self.prev_idle = idle.toU64();
            self.prev_kernel = kernel.toU64();
            self.prev_user = user.toU64();
            self.has_prev_times = true;
        }

        // Prime per-core NtQuerySystemInformation baseline
        var dummy_usage: [MAX_LOGICAL_CORES]f32 = undefined;
        _ = self.samplePerCoreUsage(&dummy_usage);

        return self;
    }

    pub fn deinit(self: *WinSystemInfoProvider) void {
        self.pdh_cpu.deinit();
    }

    pub fn collect(self: *WinSystemInfoProvider) SystemSnapshot {
        var snap = SystemSnapshot{
            .collected_utc_ms = std.time.milliTimestamp(),
            .uptime_seconds = win32.GetTickCount64() / 1000,
            .cpu_name = self.cpu_name,
            .cpu_name_len = self.cpu_name_len,
            .logical_cores = self.logical_cores,
            .base_clock_mhz = self.base_clock_mhz,
            .smbios_info = self.smbios_info,
        };

        // 1. CPU 使用率、计算频率与实时存储吞吐（优先 PDH，回退 GetSystemTimes）
        const pdh_sample = self.pdh_cpu.sample();
        const gst_pct = self.sampleGetSystemTimes();

        if (pdh_sample.utility_pct) |u| {
            snap.cpu_usage_pct = u;
            snap.cpu_usage_status = .ok;
            snap.cpu_usage_source = "pdh:% Processor Utility";
        } else if (gst_pct) |g| {
            snap.cpu_usage_pct = g;
            snap.cpu_usage_status = .ok;
            snap.cpu_usage_source = "win32:GetSystemTimes";
        } else {
            snap.cpu_usage_status = .transient_error;
        }

        if (pdh_sample.perf_pct) |perf| {
            if (self.base_clock_mhz > 0) {
                snap.cpu_clock_mhz = @as(f64, @floatFromInt(self.base_clock_mhz)) * (perf / 100.0);
                snap.cpu_clock_status = .ok;
                snap.cpu_clock_accuracy = .derived;
                snap.cpu_clock_source = "pdh:% Processor Performance";
            }
        } else if (self.base_clock_mhz > 0) {
            snap.cpu_clock_mhz = @floatFromInt(self.base_clock_mhz);
            snap.cpu_clock_status = .ok;
            snap.cpu_clock_accuracy = .derived;
            snap.cpu_clock_source = "registry:~MHz";
        }

        snap.disk_read_mbs = pdh_sample.disk_read_mbs;
        snap.disk_write_mbs = pdh_sample.disk_write_mbs;
        snap.disk_iops = pdh_sample.disk_iops;

        // 2. 每核逻辑处理器实时使用率
        snap.per_core_count = self.samplePerCoreUsage(&snap.per_core_usage);

        // 3. 电池 / 供电状态
        snap.battery = queryBatteryStatus();

        // 4. 物理内存状态（GlobalMemoryStatusEx）
        var mem = win32.MEMORYSTATUSEX{};
        if (win32.GlobalMemoryStatusEx(&mem) != 0 and mem.ullTotalPhys > 0) {
            snap.mem_total_bytes = mem.ullTotalPhys;
            snap.mem_avail_bytes = mem.ullAvailPhys;
            snap.mem_used_bytes = mem.ullTotalPhys -| mem.ullAvailPhys;
            snap.mem_load_pct = (@as(f64, @floatFromInt(snap.mem_used_bytes)) / @as(f64, @floatFromInt(mem.ullTotalPhys))) * 100.0;
            snap.mem_status = .ok;
        } else {
            snap.mem_status = .transient_error;
        }

        return snap;
    }

    fn samplePerCoreUsage(self: *WinSystemInfoProvider, out_pct: *[MAX_LOGICAL_CORES]f32) usize {
        var cur: [MAX_LOGICAL_CORES]win32.SYSTEM_PROCESSOR_PERFORMANCE_INFORMATION =
            [_]win32.SYSTEM_PROCESSOR_PERFORMANCE_INFORMATION{.{}} ** MAX_LOGICAL_CORES;
        var ret_len: win32.ULONG = 0;
        const status = win32.NtQuerySystemInformation(
            win32.SystemProcessorPerformanceInformation,
            &cur,
            @sizeOf(@TypeOf(cur)),
            &ret_len,
        );
        if (status < 0 or ret_len == 0) return 0;

        const count = @min(
            @as(usize, ret_len / @sizeOf(win32.SYSTEM_PROCESSOR_PERFORMANCE_INFORMATION)),
            MAX_LOGICAL_CORES,
        );

        if (self.prev_core_count == count and count > 0) {
            for (0..count) |i| {
                const d_idle = cur[i].IdleTime - self.prev_core_info[i].IdleTime;
                const d_kernel = cur[i].KernelTime - self.prev_core_info[i].KernelTime;
                const d_user = cur[i].UserTime - self.prev_core_info[i].UserTime;
                const total = d_kernel + d_user;
                if (total > 0) {
                    const busy = @max(@as(i64, 0), total - d_idle);
                    const pct = (@as(f64, @floatFromInt(busy)) / @as(f64, @floatFromInt(total))) * 100.0;
                    out_pct[i] = @floatCast(std.math.clamp(pct, 0.0, 100.0));
                } else {
                    out_pct[i] = 0.0;
                }
            }
        } else {
            @memset(out_pct[0..count], 0.0);
        }

        @memcpy(self.prev_core_info[0..count], cur[0..count]);
        self.prev_core_count = count;
        return count;
    }

    fn sampleGetSystemTimes(self: *WinSystemInfoProvider) ?f64 {
        var idle: win32.FILETIME = undefined;
        var kernel: win32.FILETIME = undefined;
        var user: win32.FILETIME = undefined;
        if (win32.GetSystemTimes(&idle, &kernel, &user) == 0) return null;

        const cur_idle = idle.toU64();
        const cur_kernel = kernel.toU64();
        const cur_user = user.toU64();

        if (!self.has_prev_times) {
            self.prev_idle = cur_idle;
            self.prev_kernel = cur_kernel;
            self.prev_user = cur_user;
            self.has_prev_times = true;
            return null;
        }

        const d_idle = cur_idle -| self.prev_idle;
        const d_kernel = cur_kernel -| self.prev_kernel;
        const d_user = cur_user -| self.prev_user;

        self.prev_idle = cur_idle;
        self.prev_kernel = cur_kernel;
        self.prev_user = cur_user;

        const total = d_kernel + d_user;
        if (total == 0) return null;
        const busy = total -| d_idle;
        return std.math.clamp((@as(f64, @floatFromInt(busy)) / @as(f64, @floatFromInt(total))) * 100.0, 0.0, 100.0);
    }
};

fn queryBatteryStatus() BatterySnapshot {
    var ps = win32.SYSTEM_POWER_STATUS{};
    if (win32.GetSystemPowerStatus(&ps) == 0) return .{};

    const no_bat = (ps.BatteryFlag == 128 or ps.BatteryFlag == 255);
    return .{
        .has_battery = !no_bat,
        .ac_online = (ps.ACLineStatus != 0),
        .charge_pct = if (!no_bat and ps.BatteryLifePercent <= 100) ps.BatteryLifePercent else null,
        .life_time_sec = if (!no_bat and ps.BatteryLifeTime != 0xFFFFFFFF) ps.BatteryLifeTime else null,
    };
}

fn readCpuRegistry(name_out: *[128]u8, name_len: *usize, base_mhz_out: *u32) void {
    const subkey = std.unicode.utf8ToUtf16LeStringLiteral("HARDWARE\\DESCRIPTION\\System\\CentralProcessor\\0");
    var hkey: win32.HKEY = undefined;
    if (win32.RegOpenKeyExW(win32.HKEY_LOCAL_MACHINE, subkey, 0, win32.KEY_READ, &hkey) != 0) return;
    defer _ = win32.RegCloseKey(hkey);

    const val_name = std.unicode.utf8ToUtf16LeStringLiteral("ProcessorNameString");
    var wbuf: [128]u16 = std.mem.zeroes([128]u16);
    var cb: win32.DWORD = @sizeOf(@TypeOf(wbuf));
    var rtype: win32.DWORD = 0;
    if (win32.RegQueryValueExW(hkey, val_name, null, &rtype, @ptrCast(&wbuf), &cb) == 0 and rtype == win32.REG_SZ) {
        const wchars = @min(cb / 2, wbuf.len);
        const nul = std.mem.indexOfScalar(u16, wbuf[0..wchars], 0) orelse wchars;
        var tmp: [256]u8 = undefined;
        if (std.unicode.utf16LeToUtf8(&tmp, wbuf[0..nul])) |u8_len| {
            const trimmed = std.mem.trim(u8, tmp[0..u8_len], " \t\r\n");
            const n = @min(name_out.len, trimmed.len);
            @memcpy(name_out[0..n], trimmed[0..n]);
            name_len.* = n;
        } else |_| {}
    }

    const mhz_name = std.unicode.utf8ToUtf16LeStringLiteral("~MHz");
    var mhz_val: win32.DWORD = 0;
    var mhz_cb: win32.DWORD = @sizeOf(win32.DWORD);
    if (win32.RegQueryValueExW(hkey, mhz_name, null, &rtype, @ptrCast(&mhz_val), &mhz_cb) == 0 and rtype == win32.REG_DWORD) {
        base_mhz_out.* = mhz_val;
    }
}

test "SystemInfoProvider reads real local Windows CPU, per-core usage, memory, and SMBIOS" {
    var prov = SystemInfoProvider.init(std.testing.allocator);
    defer prov.deinit();

    try std.testing.expect(prov.logical_cores >= 1);
    try std.testing.expect(prov.cpu_name_len > 0);

    std.Thread.sleep(150 * std.time.ns_per_ms);
    const snap = prov.collect();
    try std.testing.expectEqual(sensor.SensorStatus.ok, snap.mem_status);
    try std.testing.expect(snap.mem_total_bytes > 0);
    try std.testing.expect(snap.uptime_seconds > 0);
    try std.testing.expectEqual(sensor.SensorStatus.ok, snap.cpu_usage_status);
    try std.testing.expect(snap.cpu_usage_pct != null);
    try std.testing.expect(snap.per_core_count >= 1);
}
