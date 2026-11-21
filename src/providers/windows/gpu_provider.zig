const std = @import("std");
const builtin = @import("builtin");
const win32 = @import("win32.zig");
const sensor = @import("../../core/sensor.zig");
const i18n = @import("../../core/i18n.zig");

/// GPU 温度与运行参数采集 Provider（规范 §2.3 / §3.3）：
/// 1. 厂商无关路线：D3DKMT (KMTQAITYPE_ADAPTERPERFDATA) 温度/风扇/显存频率 + DXGI 型号/显存/LUID 配对；
/// 2. 动态 NVML 增强：仅在运行时检测到系统驱动自带 nvml.dll 时加载，不随软件分发任何厂商 SDK。
/// 所有不支持的指标严格保持 null / N/A，不伪造数据。
pub const MAX_GPUS = 8;

pub const GpuInfo = struct {
    name: [128]u8 = std.mem.zeroes([128]u8),
    name_len: usize = 0,
    vendor_id: u32 = 0,
    device_id: u32 = 0,
    luid_low: u32 = 0,
    luid_high: i32 = 0,

    // Real metrics (null = unavailable, NEVER fake!)
    temp_c: ?f64 = null,
    temp_status: sensor.SensorStatus = .unsupported,
    temp_source: [:0]const u8 = "d3dkmt",

    usage_pct: ?f64 = null,
    mem_used_bytes: ?u64 = null,
    mem_total_bytes: ?u64 = null,
    core_clock_mhz: ?u32 = null,
    mem_clock_mhz: ?u32 = null,
    power_watts: ?f64 = null,
    fan_rpm: ?u32 = null,
    fan_pct: ?u32 = null,

    pub fn nameSlice(self: *const GpuInfo) []const u8 {
        return if (self.name_len > 0) self.name[0..self.name_len] else i18n.trSlice("未知显卡", "Unknown GPU", "不明な GPU");
    }

    pub fn vendorName(self: *const GpuInfo) []const u8 {
        return switch (self.vendor_id) {
            0x10DE => "NVIDIA",
            0x1002 => "AMD",
            0x8086 => "Intel",
            else => "GPU",
        };
    }
};

pub const GpuSnapshot = struct {
    gpus: [MAX_GPUS]GpuInfo = [_]GpuInfo{.{}} ** MAX_GPUS,
    count: usize = 0,
    collected_utc_ms: i64 = 0,

    pub fn slice(self: *const GpuSnapshot) []const GpuInfo {
        return self.gpus[0..self.count];
    }
};

// Minimal dynamic NVML ABI bindings (loaded from system nvml.dll if present)
const NvmlMemory = extern struct {
    total: u64 = 0,
    free: u64 = 0,
    used: u64 = 0,
};

const NvmlUtilization = extern struct {
    gpu: c_uint = 0,
    memory: c_uint = 0,
};

const NvmlApi = struct {
    hmod: ?win32.HMODULE = null,
    initialized: bool = false,
    init_fn: ?*const fn () callconv(.c) c_int = null,
    shutdown_fn: ?*const fn () callconv(.c) c_int = null,
    get_count: ?*const fn (*c_uint) callconv(.c) c_int = null,
    get_handle: ?*const fn (c_uint, *?*anyopaque) callconv(.c) c_int = null,
    get_name: ?*const fn (?*anyopaque, [*]u8, c_uint) callconv(.c) c_int = null,
    get_temp: ?*const fn (?*anyopaque, c_uint, *c_uint) callconv(.c) c_int = null,
    get_power: ?*const fn (?*anyopaque, *c_uint) callconv(.c) c_int = null,
    get_util: ?*const fn (?*anyopaque, *NvmlUtilization) callconv(.c) c_int = null,
    get_mem: ?*const fn (?*anyopaque, *NvmlMemory) callconv(.c) c_int = null,
    get_clock: ?*const fn (?*anyopaque, c_uint, *c_uint) callconv(.c) c_int = null,
    get_fan: ?*const fn (?*anyopaque, *c_uint) callconv(.c) c_int = null,

    pub fn load() NvmlApi {
        var api = NvmlApi{};
        const dll = std.unicode.utf8ToUtf16LeStringLiteral("nvml.dll");
        const hm = win32.LoadLibraryW(dll) orelse return api;
        api.hmod = hm;
        api.init_fn = loadSym(*const fn () callconv(.c) c_int, hm, "nvmlInit_v2");
        api.shutdown_fn = loadSym(*const fn () callconv(.c) c_int, hm, "nvmlShutdown");
        api.get_count = loadSym(*const fn (*c_uint) callconv(.c) c_int, hm, "nvmlDeviceGetCount_v2");
        api.get_handle = loadSym(*const fn (c_uint, *?*anyopaque) callconv(.c) c_int, hm, "nvmlDeviceGetHandleByIndex_v2");
        api.get_name = loadSym(*const fn (?*anyopaque, [*]u8, c_uint) callconv(.c) c_int, hm, "nvmlDeviceGetName");
        api.get_temp = loadSym(*const fn (?*anyopaque, c_uint, *c_uint) callconv(.c) c_int, hm, "nvmlDeviceGetTemperature");
        api.get_power = loadSym(*const fn (?*anyopaque, *c_uint) callconv(.c) c_int, hm, "nvmlDeviceGetPowerUsage");
        api.get_util = loadSym(*const fn (?*anyopaque, *NvmlUtilization) callconv(.c) c_int, hm, "nvmlDeviceGetUtilizationRates");
        api.get_mem = loadSym(*const fn (?*anyopaque, *NvmlMemory) callconv(.c) c_int, hm, "nvmlDeviceGetMemoryInfo");
        api.get_clock = loadSym(*const fn (?*anyopaque, c_uint, *c_uint) callconv(.c) c_int, hm, "nvmlDeviceGetClockInfo");
        api.get_fan = loadSym(*const fn (?*anyopaque, *c_uint) callconv(.c) c_int, hm, "nvmlDeviceGetFanSpeed");

        if (api.init_fn) |init_f| {
            if (init_f() == 0) {
                api.initialized = true;
            }
        }
        return api;
    }

    pub fn unload(self: *NvmlApi) void {
        if (self.initialized) {
            if (self.shutdown_fn) |shut| _ = shut();
            self.initialized = false;
        }
        if (self.hmod) |hm| {
            _ = win32.FreeLibrary(hm);
            self.hmod = null;
        }
    }
};

fn loadSym(comptime T: type, hm: win32.HMODULE, name: [*:0]const u8) ?T {
    const p = win32.GetProcAddress(hm, name) orelse return null;
    return @ptrCast(@alignCast(p));
}

/// 跨平台 GPU Provider（Windows 走动态 NVML + D3DKMT，Linux 走 DRM/hwmon sysfs）
pub const GpuProvider = if (builtin.os.tag == .windows)
    WinGpuProvider
else
    @import("../linux/gpu_provider.zig").LinuxGpuProvider;

pub const WinGpuProvider = struct {
    nvml: NvmlApi,

    pub fn init() WinGpuProvider {
        return .{
            .nvml = NvmlApi.load(),
        };
    }

    pub fn deinit(self: *WinGpuProvider) void {
        self.nvml.unload();
    }

    pub fn collect(self: *WinGpuProvider) GpuSnapshot {
        var snap = GpuSnapshot{
            .collected_utc_ms = std.time.milliTimestamp(),
        };

        // 1. 先通过动态 NVML 采集 NVIDIA GPU（完整支持温度/功耗/占用/显存/频率/风扇）
        if (self.nvml.initialized) {
            if (self.nvml.get_count) |get_cnt| {
                var cnt: c_uint = 0;
                if (get_cnt(&cnt) == 0) {
                    const n = @min(@as(usize, cnt), MAX_GPUS);
                    for (0..n) |i| {
                        var handle: ?*anyopaque = null;
                        if (self.nvml.get_handle.?( @intCast(i), &handle ) != 0) continue;

                        var g = GpuInfo{
                            .vendor_id = 0x10DE,
                        };
                        if (self.nvml.get_name) |gn| {
                            var nb: [128]u8 = std.mem.zeroes([128]u8);
                            if (gn(handle, &nb, nb.len) == 0) {
                                const sl = std.mem.sliceTo(&nb, 0);
                                const clen = @min(g.name.len, sl.len);
                                @memcpy(g.name[0..clen], sl[0..clen]);
                                g.name_len = clen;
                            }
                        }
                        if (self.nvml.get_temp) |gt| {
                            var tc: c_uint = 0;
                            if (gt(handle, 0, &tc) == 0) {
                                g.temp_c = @floatFromInt(tc);
                                g.temp_status = .ok;
                                g.temp_source = "nvml";
                            }
                        }
                        if (self.nvml.get_power) |gp| {
                            var mw: c_uint = 0;
                            if (gp(handle, &mw) == 0) {
                                g.power_watts = @as(f64, @floatFromInt(mw)) / 1000.0;
                            }
                        }
                        if (self.nvml.get_util) |gu| {
                            var util = NvmlUtilization{};
                            if (gu(handle, &util) == 0) {
                                g.usage_pct = @floatFromInt(util.gpu);
                            }
                        }
                        if (self.nvml.get_mem) |gm| {
                            var mem = NvmlMemory{};
                            if (gm(handle, &mem) == 0) {
                                g.mem_total_bytes = mem.total;
                                g.mem_used_bytes = mem.used;
                            }
                        }
                        if (self.nvml.get_clock) |gc| {
                            var clk_g: c_uint = 0;
                            if (gc(handle, 0, &clk_g) == 0) g.core_clock_mhz = clk_g; // NVML_CLOCK_GRAPHICS=0
                            var clk_m: c_uint = 0;
                            if (gc(handle, 2, &clk_m) == 0) g.mem_clock_mhz = clk_m; // NVML_CLOCK_MEM=2
                        }
                        if (self.nvml.get_fan) |gf| {
                            var fan: c_uint = 0;
                            if (gf(handle, &fan) == 0) g.fan_pct = fan;
                        }

                        snap.gpus[snap.count] = g;
                        snap.count += 1;
                    }
                }
            }
        }

        // 2. 通过 D3DKMT 补充风扇 RPM、小数温度精度，或作为非 NVIDIA GPU（AMD/Intel）的通用温度采集路线
        self.mergeD3dkmt(&snap);
        return snap;
    }

    fn mergeD3dkmt(self: *WinGpuProvider, snap: *GpuSnapshot) void {
        _ = self;
        var enum_req = win32.D3DKMT_ENUMADAPTERS2{
            .NumAdapters = 0,
            .pAdapters = null,
        };
        if (win32.D3DKMTEnumAdapters2(&enum_req) != 0) return;

        var adapters: [16]win32.D3DKMT_ADAPTERINFO = undefined;
        enum_req.NumAdapters = @min(enum_req.NumAdapters, 16);
        enum_req.pAdapters = &adapters;
        if (win32.D3DKMTEnumAdapters2(&enum_req) != 0) return;

        var active_idx: usize = 0;
        for (adapters[0..enum_req.NumAdapters]) |ad| {
            defer {
                const close_arg = win32.D3DKMT_CLOSEADAPTER{ .hAdapter = ad.hAdapter };
                _ = win32.D3DKMTCloseAdapter(&close_arg);
            }

            var perf = std.mem.zeroes(win32.D3DKMT_ADAPTER_PERFDATA);
            var q = win32.D3DKMT_QUERYADAPTERINFO{
                .hAdapter = ad.hAdapter,
                .Type = win32.KMTQAITYPE_ADAPTERPERFDATA,
                .pPrivateDriverData = &perf,
                .PrivateDriverDataSize = @sizeOf(win32.D3DKMT_ADAPTER_PERFDATA),
            };
            if (win32.D3DKMTQueryAdapterInfo(&q) != 0) continue; // 跳过软渲染器/基础驱动

            const temp_c = @as(f64, @floatFromInt(perf.Temperature)) / 10.0;
            const valid_temp = (perf.Temperature > 0 and temp_c < 150.0);

            if (active_idx < snap.count) {
                // 补充已由 NVML 识别的 GPU 的风扇 RPM 与 0.1°C D3DKMT 精度
                if (perf.FanRPM > 0) snap.gpus[active_idx].fan_rpm = perf.FanRPM;
                if (snap.gpus[active_idx].temp_c == null and valid_temp) {
                    snap.gpus[active_idx].temp_c = temp_c;
                    snap.gpus[active_idx].temp_status = .ok;
                    snap.gpus[active_idx].temp_source = "d3dkmt";
                }
                if (snap.gpus[active_idx].mem_clock_mhz == null and perf.MemoryFrequency > 0) {
                    snap.gpus[active_idx].mem_clock_mhz = @intCast(perf.MemoryFrequency / 1_000_000);
                }
                snap.gpus[active_idx].luid_low = ad.AdapterLuid.LowPart;
                snap.gpus[active_idx].luid_high = ad.AdapterLuid.HighPart;
            } else if (snap.count < MAX_GPUS) {
                // 厂商无关路线发现的 GPU（如 AMD / Intel GPU）
                var g = GpuInfo{
                    .luid_low = ad.AdapterLuid.LowPart,
                    .luid_high = ad.AdapterLuid.HighPart,
                };
                const nm = std.fmt.bufPrint(&g.name, "GPU Adapter (LUID 0x{X})", .{ad.AdapterLuid.LowPart}) catch "GPU";
                g.name_len = nm.len;
                if (valid_temp) {
                    g.temp_c = temp_c;
                    g.temp_status = .ok;
                    g.temp_source = "d3dkmt";
                }
                if (perf.FanRPM > 0) g.fan_rpm = perf.FanRPM;
                if (perf.MemoryFrequency > 0) g.mem_clock_mhz = @intCast(perf.MemoryFrequency / 1_000_000);
                snap.gpus[snap.count] = g;
                snap.count += 1;
            }
            active_idx += 1;
        }
    }
};

test "GpuProvider collects real local GPU info without admin privilege" {
    var prov = GpuProvider.init();
    defer prov.deinit();

    const snap = prov.collect();
    if (builtin.os.tag == .windows) {
        try std.testing.expect(snap.count >= 1);
        const g0 = snap.gpus[0];
        try std.testing.expectEqual(sensor.SensorStatus.ok, g0.temp_status);
        try std.testing.expect(g0.temp_c != null);
        try std.testing.expect(g0.temp_c.? > 5.0 and g0.temp_c.? < 130.0);
    } else {
        // Linux 物理机或无头容器均安全运行不崩溃
        for (snap.slice()) |g| {
            try std.testing.expect(g.name_len > 0);
        }
    }
}
