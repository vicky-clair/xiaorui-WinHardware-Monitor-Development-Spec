//! Linux 系统信息原生采集器（`/proc/cpuinfo`、`/proc/stat`、`/proc/meminfo`、`/proc/uptime`、
//! `/proc/diskstats`、`cpufreq`、`/sys/class/dmi/id`、`/sys/class/power_supply`）。
//! 普通用户权限即可完整运行，与 Windows `SystemSnapshot` 共享统一数据结构。
const std = @import("std");
const sensor = @import("../../core/sensor.zig");
const smbios = @import("../windows/smbios.zig");
const win_sys = @import("../windows/system_info.zig");

const CoreTimes = struct {
    total: u64 = 0,
    idle: u64 = 0,
};

pub const LinuxSystemInfoProvider = struct {
    cpu_name: [128]u8 = std.mem.zeroes([128]u8),
    cpu_name_len: usize = 0,
    logical_cores: u32 = 1,
    base_clock_mhz: u32 = 0,
    smbios_info: smbios.SmbiosData = .{},

    prev_total: CoreTimes = .{},
    has_prev_total: bool = false,
    prev_cores: [win_sys.MAX_LOGICAL_CORES]CoreTimes = [_]CoreTimes{.{}} ** win_sys.MAX_LOGICAL_CORES,
    prev_core_count: usize = 0,

    prev_disk_read_sec: u64 = 0,
    prev_disk_write_sec: u64 = 0,
    prev_disk_ios: u64 = 0,
    prev_disk_ns: i128 = 0,
    has_prev_disk: bool = false,

    pub fn init(allocator: std.mem.Allocator) LinuxSystemInfoProvider {
        _ = allocator;
        var self = LinuxSystemInfoProvider{};
        readProcCpuinfo(&self.cpu_name, &self.cpu_name_len, &self.logical_cores, &self.base_clock_mhz);
        self.smbios_info = readDmiSmbios();

        // 预热 /proc/stat 与 /proc/diskstats 基线，确保首次 collect 即可计算增量
        var dummy_cores: [win_sys.MAX_LOGICAL_CORES]f32 = undefined;
        _ = self.sampleProcStat(&dummy_cores);
        var dr: ?f64 = null;
        var dw: ?f64 = null;
        var di: ?f64 = null;
        self.sampleDiskStats(&dr, &dw, &di);

        return self;
    }

    pub fn deinit(self: *LinuxSystemInfoProvider) void {
        _ = self;
    }

    pub fn collect(self: *LinuxSystemInfoProvider) win_sys.SystemSnapshot {
        var snap = win_sys.SystemSnapshot{
            .collected_utc_ms = std.time.milliTimestamp(),
            .uptime_seconds = readProcUptime(),
            .cpu_name = self.cpu_name,
            .cpu_name_len = self.cpu_name_len,
            .logical_cores = self.logical_cores,
            .base_clock_mhz = self.base_clock_mhz,
            .smbios_info = self.smbios_info,
        };

        // 1. CPU 总体与每核使用率（/proc/stat）
        const stat_res = self.sampleProcStat(&snap.per_core_usage);
        snap.per_core_count = stat_res.core_count;
        if (stat_res.total_pct) |pct| {
            snap.cpu_usage_pct = pct;
            snap.cpu_usage_status = .ok;
            snap.cpu_usage_source = "linux:/proc/stat";
        } else {
            snap.cpu_usage_status = .unknown;
        }

        // 2. CPU 实时频率（优先 cpufreq scaling_cur_freq，回退 /proc/cpuinfo）
        if (readCpufreqMhz()) |mhz| {
            snap.cpu_clock_mhz = mhz;
            snap.cpu_clock_status = .ok;
            snap.cpu_clock_accuracy = .measured;
            snap.cpu_clock_source = "linux:cpufreq";
        } else if (self.base_clock_mhz > 0) {
            snap.cpu_clock_mhz = @floatFromInt(self.base_clock_mhz);
            snap.cpu_clock_status = .ok;
            snap.cpu_clock_accuracy = .derived;
            snap.cpu_clock_source = "linux:/proc/cpuinfo";
        }

        // 3. 内存使用情况（/proc/meminfo）
        readProcMeminfo(&snap);

        // 4. 实时磁盘总读写吞吐与 IOPS（/proc/diskstats）
        self.sampleDiskStats(&snap.disk_read_mbs, &snap.disk_write_mbs, &snap.disk_iops);

        // 5. 电源与电池状态（/sys/class/power_supply）
        snap.battery = readLinuxBattery();

        return snap;
    }

    fn sampleProcStat(self: *LinuxSystemInfoProvider, out_cores: *[win_sys.MAX_LOGICAL_CORES]f32) struct { total_pct: ?f64, core_count: usize } {
        var buf: [32 * 1024]u8 = undefined;
        const f = std.fs.openFileAbsolute("/proc/stat", .{}) catch return .{ .total_pct = null, .core_count = 0 };
        defer f.close();
        const n = f.readAll(&buf) catch return .{ .total_pct = null, .core_count = 0 };

        var total_pct: ?f64 = null;
        var core_count: usize = 0;

        var lines = std.mem.splitScalar(u8, buf[0..n], '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "cpu ")) {
                const cur = parseCpuStatLine(line);
                if (self.has_prev_total) {
                    const dt = cur.total -| self.prev_total.total;
                    const di = cur.idle -| self.prev_total.idle;
                    if (dt > 0) {
                        total_pct = std.math.clamp((@as(f64, @floatFromInt(dt -| di)) / @as(f64, @floatFromInt(dt))) * 100.0, 0.0, 100.0);
                    }
                }
                self.prev_total = cur;
                self.has_prev_total = true;
            } else if (std.mem.startsWith(u8, line, "cpu") and line.len > 3 and line[3] >= '0' and line[3] <= '9') {
                if (core_count >= win_sys.MAX_LOGICAL_CORES) continue;
                const cur = parseCpuStatLine(line);
                if (core_count < self.prev_core_count) {
                    const dt = cur.total -| self.prev_cores[core_count].total;
                    const di = cur.idle -| self.prev_cores[core_count].idle;
                    if (dt > 0) {
                        out_cores[core_count] = @floatCast(std.math.clamp((@as(f64, @floatFromInt(dt -| di)) / @as(f64, @floatFromInt(dt))) * 100.0, 0.0, 100.0));
                    } else {
                        out_cores[core_count] = 0.0;
                    }
                } else {
                    out_cores[core_count] = 0.0;
                }
                self.prev_cores[core_count] = cur;
                core_count += 1;
            }
        }
        self.prev_core_count = core_count;
        return .{ .total_pct = total_pct, .core_count = core_count };
    }

    fn sampleDiskStats(self: *LinuxSystemInfoProvider, read_mbs: *?f64, write_mbs: *?f64, iops: *?f64) void {
        var buf: [32 * 1024]u8 = undefined;
        const f = std.fs.openFileAbsolute("/proc/diskstats", .{}) catch return;
        defer f.close();
        const n = f.readAll(&buf) catch return;

        var total_read_sec: u64 = 0;
        var total_write_sec: u64 = 0;
        var total_ios: u64 = 0;

        var lines = std.mem.splitScalar(u8, buf[0..n], '\n');
        while (lines.next()) |line| {
            var toks = std.mem.tokenizeAny(u8, line, " \t");
            _ = toks.next() orelse continue; // major
            _ = toks.next() orelse continue; // minor
            const dev_name = toks.next() orelse continue;
            // 仅统计整盘（sdX / nvmeXnY / vdX），跳过分区与 loop 虚拟设备避免重复累加
            if (!isWholeDiskName(dev_name)) continue;

            const r_ios = std.fmt.parseInt(u64, toks.next() orelse continue, 10) catch continue;
            _ = toks.next() orelse continue; // reads merged
            const r_sec = std.fmt.parseInt(u64, toks.next() orelse continue, 10) catch continue;
            _ = toks.next() orelse continue; // ms reading
            const w_ios = std.fmt.parseInt(u64, toks.next() orelse continue, 10) catch continue;
            _ = toks.next() orelse continue; // writes merged
            const w_sec = std.fmt.parseInt(u64, toks.next() orelse continue, 10) catch continue;

            total_read_sec +|= r_sec;
            total_write_sec +|= w_sec;
            total_ios +|= (r_ios +| w_ios);
        }

        const now_ns = std.time.nanoTimestamp();
        if (self.has_prev_disk and now_ns > self.prev_disk_ns) {
            const dt_s = @as(f64, @floatFromInt(now_ns - self.prev_disk_ns)) / @as(f64, @floatFromInt(std.time.ns_per_s));
            if (dt_s >= 0.05) {
                const dr = total_read_sec -| self.prev_disk_read_sec;
                const dw = total_write_sec -| self.prev_disk_write_sec;
                const di = total_ios -| self.prev_disk_ios;
                read_mbs.* = (@as(f64, @floatFromInt(dr)) * 512.0 / (1024.0 * 1024.0)) / dt_s;
                write_mbs.* = (@as(f64, @floatFromInt(dw)) * 512.0 / (1024.0 * 1024.0)) / dt_s;
                iops.* = @as(f64, @floatFromInt(di)) / dt_s;
            }
        }
        self.prev_disk_read_sec = total_read_sec;
        self.prev_disk_write_sec = total_write_sec;
        self.prev_disk_ios = total_ios;
        self.prev_disk_ns = now_ns;
        self.has_prev_disk = true;
    }
};

fn isWholeDiskName(name: []const u8) bool {
    if (std.mem.startsWith(u8, name, "sd") or std.mem.startsWith(u8, name, "vd")) {
        if (name.len < 3) return false;
        const last = name[name.len - 1];
        return last >= 'a' and last <= 'z';
    }
    if (std.mem.startsWith(u8, name, "nvme")) {
        return std.mem.indexOfScalar(u8, name, 'p') == null;
    }
    return false;
}

fn parseCpuStatLine(line: []const u8) CoreTimes {
    var toks = std.mem.tokenizeAny(u8, line, " \t");
    _ = toks.next(); // label
    var vals: [10]u64 = [_]u64{0} ** 10;
    var i: usize = 0;
    while (toks.next()) |t| {
        if (i >= vals.len) break;
        vals[i] = std.fmt.parseInt(u64, t, 10) catch 0;
        i += 1;
    }
    var sum: u64 = 0;
    for (vals) |v| sum +|= v;
    return .{ .total = sum, .idle = vals[3] +| vals[4] }; // idle + iowait
}

fn readProcCpuinfo(name_out: *[128]u8, name_len: *usize, cores_out: *u32, base_mhz_out: *u32) void {
    var buf: [64 * 1024]u8 = undefined;
    const f = std.fs.openFileAbsolute("/proc/cpuinfo", .{}) catch return;
    defer f.close();
    const n = f.readAll(&buf) catch return;

    var core_cnt: u32 = 0;
    var lines = std.mem.splitScalar(u8, buf[0..n], '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "processor")) {
            core_cnt += 1;
        } else if (name_len.* == 0 and std.mem.startsWith(u8, line, "model name")) {
            if (std.mem.indexOfScalar(u8, line, ':')) |col| {
                const v = std.mem.trim(u8, line[col + 1 ..], " \t\r\n");
                const cn = @min(name_out.len, v.len);
                @memcpy(name_out[0..cn], v[0..cn]);
                name_len.* = cn;
            }
        } else if (base_mhz_out.* == 0 and std.mem.startsWith(u8, line, "cpu MHz")) {
            if (std.mem.indexOfScalar(u8, line, ':')) |col| {
                const v = std.mem.trim(u8, line[col + 1 ..], " \t\r\n");
                if (std.fmt.parseFloat(f64, v)) |mhz| {
                    if (mhz > 100.0) base_mhz_out.* = @intFromFloat(mhz);
                } else |_| {}
            }
        }
    }
    if (core_cnt > 0) cores_out.* = core_cnt;
}

fn readCpufreqMhz() ?f64 {
    var buf: [64]u8 = undefined;
    const f = std.fs.openFileAbsolute("/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq", .{}) catch return null;
    defer f.close();
    const n = f.readAll(&buf) catch return null;
    const s = std.mem.trim(u8, buf[0..n], " \t\r\n");
    const khz = std.fmt.parseFloat(f64, s) catch return null;
    return if (khz > 1000.0) khz / 1000.0 else null;
}

fn readProcUptime() u64 {
    var buf: [64]u8 = undefined;
    const f = std.fs.openFileAbsolute("/proc/uptime", .{}) catch return 0;
    defer f.close();
    const n = f.readAll(&buf) catch return 0;
    var toks = std.mem.tokenizeAny(u8, buf[0..n], " \t\r\n");
    const first = toks.next() orelse return 0;
    const secs = std.fmt.parseFloat(f64, first) catch return 0;
    return if (secs > 0) @intFromFloat(secs) else 0;
}

fn readProcMeminfo(snap: *win_sys.SystemSnapshot) void {
    var buf: [8192]u8 = undefined;
    const f = std.fs.openFileAbsolute("/proc/meminfo", .{}) catch {
        snap.mem_status = .transient_error;
        return;
    };
    defer f.close();
    const n = f.readAll(&buf) catch {
        snap.mem_status = .transient_error;
        return;
    };

    var total_kb: u64 = 0;
    var avail_kb: u64 = 0;
    var lines = std.mem.splitScalar(u8, buf[0..n], '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "MemTotal:")) {
            total_kb = parseMeminfoKb(line);
        } else if (std.mem.startsWith(u8, line, "MemAvailable:")) {
            avail_kb = parseMeminfoKb(line);
        }
    }
    if (total_kb > 0) {
        snap.mem_total_bytes = total_kb * 1024;
        snap.mem_avail_bytes = avail_kb * 1024;
        snap.mem_used_bytes = snap.mem_total_bytes -| snap.mem_avail_bytes;
        snap.mem_load_pct = (@as(f64, @floatFromInt(snap.mem_used_bytes)) / @as(f64, @floatFromInt(snap.mem_total_bytes))) * 100.0;
        snap.mem_status = .ok;
    } else {
        snap.mem_status = .transient_error;
    }
}

fn parseMeminfoKb(line: []const u8) u64 {
    const col = std.mem.indexOfScalar(u8, line, ':') orelse return 0;
    var toks = std.mem.tokenizeAny(u8, line[col + 1 ..], " \t\r\n");
    const num = toks.next() orelse return 0;
    return std.fmt.parseInt(u64, num, 10) catch 0;
}

fn readDmiSmbios() smbios.SmbiosData {
    var out = smbios.SmbiosData{};
    var b1: [96]u8 = undefined;
    if (readSysFile("/sys/class/dmi/id/board_vendor", &b1)) |v| {
        const cn = @min(out.board_manufacturer.len, v.len);
        @memcpy(out.board_manufacturer[0..cn], v[0..cn]);
        out.board_manufacturer_len = cn;
        out.available = true;
    }
    var b2: [96]u8 = undefined;
    if (readSysFile("/sys/class/dmi/id/board_name", &b2)) |v| {
        const cn = @min(out.board_product.len, v.len);
        @memcpy(out.board_product[0..cn], v[0..cn]);
        out.board_product_len = cn;
        out.available = true;
    }
    var b3: [64]u8 = undefined;
    if (readSysFile("/sys/class/dmi/id/board_version", &b3)) |v| {
        const cn = @min(out.board_version.len, v.len);
        @memcpy(out.board_version[0..cn], v[0..cn]);
        out.board_version_len = cn;
    }
    return out;
}

fn readLinuxBattery() win_sys.BatterySnapshot {
    var dir = std.fs.openDirAbsolute("/sys/class/power_supply", .{ .iterate = true }) catch return .{};
    defer dir.close();
    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (!std.mem.startsWith(u8, entry.name, "BAT")) continue;
        var cap_path: [128]u8 = undefined;
        const cp = std.fmt.bufPrint(&cap_path, "/sys/class/power_supply/{s}/capacity", .{entry.name}) catch continue;
        var st_path: [128]u8 = undefined;
        const sp = std.fmt.bufPrint(&st_path, "/sys/class/power_supply/{s}/status", .{entry.name}) catch continue;
        var cb: [32]u8 = undefined;
        var sb: [32]u8 = undefined;
        const pct: ?u8 = if (readSysFile(cp, &cb)) |cs| std.fmt.parseInt(u8, cs, 10) catch null else null;
        const status_s = readSysFile(sp, &sb) orelse "Unknown";
        return .{
            .has_battery = true,
            .ac_online = !std.mem.eql(u8, status_s, "Discharging"),
            .charge_pct = pct,
        };
    }
    return .{};
}

fn readSysFile(path: []const u8, buf: []u8) ?[]const u8 {
    const f = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer f.close();
    const n = f.readAll(buf) catch return null;
    const t = std.mem.trim(u8, buf[0..n], " \t\r\n\x00");
    return if (t.len > 0) t else null;
}
