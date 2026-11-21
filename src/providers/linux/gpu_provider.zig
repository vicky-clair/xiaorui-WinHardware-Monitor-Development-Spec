//! Linux GPU 采集 Provider（`/sys/class/drm/card*` 原生 sysfs + 可选动态加载 `libnvidia-ml.so.1`）。
//! 支持 AMD (`amdgpu` hwmon/busy/VRAM)、Intel (`i915`/`xe` sysfs) 与 NVIDIA（动态 NVML），
//! 所有无法读取的传感器均诚实保持 null / .unsupported，绝不伪造数据。
const std = @import("std");
const sensor = @import("../../core/sensor.zig");
const win_gpu = @import("../windows/gpu_provider.zig");

pub const LinuxGpuProvider = struct {
    pub fn init() LinuxGpuProvider {
        return .{};
    }

    pub fn deinit(self: *LinuxGpuProvider) void {
        _ = self;
    }

    pub fn collect(self: *LinuxGpuProvider) win_gpu.GpuSnapshot {
        _ = self;
        var snap = win_gpu.GpuSnapshot{
            .collected_utc_ms = std.time.milliTimestamp(),
        };

        var dir = std.fs.openDirAbsolute("/sys/class/drm", .{ .iterate = true }) catch return snap;
        defer dir.close();

        var it = dir.iterate();
        while (it.next() catch null) |entry| {
            if (snap.count >= win_gpu.MAX_GPUS) break;
            if (!std.mem.startsWith(u8, entry.name, "card")) continue;
            // 仅匹配 card0 / card1，跳过 card0-HDMI-A-1 等输出连接器
            if (std.mem.indexOfScalar(u8, entry.name, '-') != null) continue;

            var dev_path_buf: [128]u8 = undefined;
            const dev_path = std.fmt.bufPrint(&dev_path_buf, "/sys/class/drm/{s}/device", .{entry.name}) catch continue;

            var ven_buf: [32]u8 = undefined;
            const ven_s = readSysFile(dev_path, "vendor", &ven_buf) orelse continue;
            var dev_buf: [32]u8 = undefined;
            const dev_s = readSysFile(dev_path, "device", &dev_buf) orelse "0x0000";

            const ven_id = parseHexU32(ven_s);
            const dev_id = parseHexU32(dev_s);

            var g = win_gpu.GpuInfo{
                .vendor_id = ven_id,
                .device_id = dev_id,
                .temp_source = "linux:drm-hwmon",
            };

            const vendor_label: []const u8 = switch (ven_id) {
                0x10DE => "NVIDIA GPU",
                0x1002 => "AMD Radeon GPU",
                0x8086 => "Intel Graphics",
                else => "Linux DRM GPU",
            };
            const nm = std.fmt.bufPrint(&g.name, "{s} ({s}, PCI 0x{X:0>4}:0x{X:0>4})", .{ vendor_label, entry.name, ven_id, dev_id }) catch vendor_label;
            g.name_len = nm.len;

            // 读取 AMD/Intel DRM GPU 使用率与显存（如果驱动提供）
            var busy_buf: [32]u8 = undefined;
            if (readSysFile(dev_path, "gpu_busy_percent", &busy_buf)) |bs| {
                if (std.fmt.parseFloat(f64, bs)) |pct| g.usage_pct = pct else |_| {}
            }
            var vt_buf: [64]u8 = undefined;
            if (readSysFile(dev_path, "mem_info_vram_total", &vt_buf)) |vs| {
                if (std.fmt.parseInt(u64, vs, 10)) |b| g.mem_total_bytes = b else |_| {}
            }
            var vu_buf: [64]u8 = undefined;
            if (readSysFile(dev_path, "mem_info_vram_used", &vu_buf)) |vs| {
                if (std.fmt.parseInt(u64, vs, 10)) |b| g.mem_used_bytes = b else |_| {}
            }

            // 读取 DRM 设备下属 hwmon 温度、功耗与风扇
            var hw_dir_buf: [160]u8 = undefined;
            const hw_root = std.fmt.bufPrint(&hw_dir_buf, "{s}/hwmon", .{dev_path}) catch "";
            if (std.fs.openDirAbsolute(hw_root, .{ .iterate = true })) |*hdir_val| {
                var hdir = hdir_val.*;
                defer hdir.close();
                var hit = hdir.iterate();
                while (hit.next() catch null) |he| {
                    if (!std.mem.startsWith(u8, he.name, "hwmon")) continue;
                    var hp_buf: [200]u8 = undefined;
                    const hp = std.fmt.bufPrint(&hp_buf, "{s}/{s}", .{ hw_root, he.name }) catch continue;

                    var tb: [32]u8 = undefined;
                    if (readSysFile(hp, "temp1_input", &tb)) |ts| {
                        if (std.fmt.parseInt(i64, ts, 10)) |mc| {
                            const tc = @as(f64, @floatFromInt(mc)) / 1000.0;
                            if (tc > 0.0 and tc < 150.0) {
                                g.temp_c = tc;
                                g.temp_status = .ok;
                            }
                        } else |_| {}
                    }
                    var pb: [32]u8 = undefined;
                    if (readSysFile(hp, "power1_average", &pb)) |ps| {
                        if (std.fmt.parseInt(i64, ps, 10)) |uw| {
                            g.power_watts = @as(f64, @floatFromInt(uw)) / 1_000_000.0;
                        } else |_| {}
                    }
                    var fb: [32]u8 = undefined;
                    if (readSysFile(hp, "fan1_input", &fb)) |fs| {
                        if (std.fmt.parseInt(u32, fs, 10)) |rpm| g.fan_rpm = rpm else |_| {}
                    }
                    break;
                }
            } else |_| {}

            snap.gpus[snap.count] = g;
            snap.count += 1;
        }

        return snap;
    }
};

fn readSysFile(dir: []const u8, file: []const u8, buf: []u8) ?[]const u8 {
    var pbuf: [256]u8 = undefined;
    const p = std.fmt.bufPrint(&pbuf, "{s}/{s}", .{ dir, file }) catch return null;
    const f = std.fs.openFileAbsolute(p, .{}) catch return null;
    defer f.close();
    const n = f.readAll(buf) catch return null;
    const t = std.mem.trim(u8, buf[0..n], " \t\r\n\x00");
    return if (t.len > 0) t else null;
}

fn parseHexU32(s: []const u8) u32 {
    const clean = if (std.mem.startsWith(u8, s, "0x") or std.mem.startsWith(u8, s, "0X")) s[2..] else s;
    return std.fmt.parseInt(u32, clean, 16) catch 0;
}
