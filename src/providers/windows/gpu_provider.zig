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
        // 1) 优先现代 DCH 驱动的 System32\nvml.dll；2) 回退老款 Quadro / Kepler 驱动的 NVSMI\nvml.dll
        const candidates = [_][:0]const u16{
            std.unicode.utf8ToUtf16LeStringLiteral("nvml.dll"),
            std.unicode.utf8ToUtf16LeStringLiteral("C:\\Program Files\\NVIDIA Corporation\\NVSMI\\nvml.dll"),
        };
        var hm_opt: ?win32.HMODULE = null;
        for (candidates) |dll| {
            if (win32.LoadLibraryW(dll)) |h| {
                hm_opt = h;
                break;
            }
        }
        const hm = hm_opt orelse return api;
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

// 动态 NVAPI 回退（加载系统 nvapi64.dll，覆盖老款 Kepler / Quadro K3000M / GTX 600-900 等无 NVML 或旧 WDDM 驱动显卡）
const NvThermalSensor = extern struct {
    controller: i32 = 0,
    default_min_temp: i32 = 0,
    default_max_temp: i32 = 0,
    current_temp: i32 = 0,
    target: i32 = 0,
};

const NvGpuThermalSettingsV1 = extern struct {
    version: u32 = @sizeOf(NvGpuThermalSettingsV1) | (1 << 16),
    count: u32 = 0,
    sensor: [3]NvThermalSensor = [_]NvThermalSensor{.{}} ** 3,
};

const NvUtilizationDomain = extern struct {
    present: u32 = 0,
    percentage: u32 = 0,
};

const NvGpuDynamicPstatesInfoEx = extern struct {
    version: u32 = @sizeOf(NvGpuDynamicPstatesInfoEx) | (1 << 16),
    flags: u32 = 0,
    utilization: [8]NvUtilizationDomain = [_]NvUtilizationDomain{.{}} ** 8,
};

const NvMemoryInfoV2 = extern struct {
    version: u32 = @sizeOf(NvMemoryInfoV2) | (2 << 16),
    dedicated_video_memory_kb: u32 = 0,
    available_dedicated_video_memory_kb: u32 = 0,
    system_video_memory_kb: u32 = 0,
    shared_system_memory_kb: u32 = 0,
    cur_available_dedicated_video_memory_kb: u32 = 0,
};

const NvapiQueryInterfaceFn = *const fn (u32) callconv(.c) ?*anyopaque;
const NvapiVoidFn = *const fn () callconv(.c) i32;
const NvapiEnumGpusFn = *const fn (*[64]?*anyopaque, *u32) callconv(.c) i32;
const NvapiGetNameFn = *const fn (?*anyopaque, *[64]u8) callconv(.c) i32;
const NvapiGetThermalFn = *const fn (?*anyopaque, u32, *NvGpuThermalSettingsV1) callconv(.c) i32;
const NvapiGetPstatesFn = *const fn (?*anyopaque, *NvGpuDynamicPstatesInfoEx) callconv(.c) i32;
const NvapiGetTachFn = *const fn (?*anyopaque, *u32) callconv(.c) i32;
const NvapiGetMemFn = *const fn (?*anyopaque, *NvMemoryInfoV2) callconv(.c) i32;

const NvapiApi = struct {
    hmod: ?win32.HMODULE = null,
    initialized: bool = false,
    unload_fn: ?NvapiVoidFn = null,
    enum_gpus: ?NvapiEnumGpusFn = null,
    get_name: ?NvapiGetNameFn = null,
    get_thermal: ?NvapiGetThermalFn = null,
    get_pstates: ?NvapiGetPstatesFn = null,
    get_tach: ?NvapiGetTachFn = null,
    get_mem: ?NvapiGetMemFn = null,

    fn query(comptime T: type, qi: NvapiQueryInterfaceFn, id: u32) ?T {
        const p = qi(id) orelse return null;
        return @ptrCast(@alignCast(p));
    }

    pub fn load() NvapiApi {
        var api = NvapiApi{};
        const dll = std.unicode.utf8ToUtf16LeStringLiteral("nvapi64.dll");
        const hm = win32.LoadLibraryW(dll) orelse return api;
        api.hmod = hm;

        const qi = loadSym(NvapiQueryInterfaceFn, hm, "nvapi_QueryInterface") orelse return api;
        const init_f = query(NvapiVoidFn, qi, 0x0150E828) orelse return api; // NvAPI_Initialize
        if (init_f() != 0) return api;

        api.initialized = true;
        api.unload_fn = query(NvapiVoidFn, qi, 0xD22BDD7E); // NvAPI_Unload
        api.enum_gpus = query(NvapiEnumGpusFn, qi, 0xE5AC921F); // NvAPI_EnumPhysicalGPUs
        api.get_name = query(NvapiGetNameFn, qi, 0xCEEE8E9F); // NvAPI_GPU_GetFullName
        api.get_thermal = query(NvapiGetThermalFn, qi, 0xE3640A56); // NvAPI_GPU_GetThermalSettings
        api.get_pstates = query(NvapiGetPstatesFn, qi, 0x189A1FDF); // NvAPI_GPU_GetDynamicPstatesInfoEx
        api.get_tach = query(NvapiGetTachFn, qi, 0x5F608315); // NvAPI_GPU_GetTachReading
        api.get_mem = query(NvapiGetMemFn, qi, 0x07F9B368); // NvAPI_GPU_GetMemoryInfo
        return api;
    }

    pub fn unload(self: *NvapiApi) void {
        if (self.initialized) {
            if (self.unload_fn) |u| _ = u();
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
    nvapi: NvapiApi,

    pub fn init() WinGpuProvider {
        const nvml = NvmlApi.load();
        // 仅在 NVML 不可用时按需加载 nvapi64.dll，减少额外句柄与内存占用
        const nvapi = if (!nvml.initialized) NvapiApi.load() else NvapiApi{};
        return .{
            .nvml = nvml,
            .nvapi = nvapi,
        };
    }

    pub fn deinit(self: *WinGpuProvider) void {
        self.nvml.unload();
        self.nvapi.unload();
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

        // 2. 若 NVML 未发现显卡，则通过动态 nvapi64.dll 回退采集老款 NVIDIA / Quadro（如 Kepler K3000M）
        if (snap.count == 0 and self.nvapi.initialized) {
            self.collectNvapi(&snap);
        }

        // 3. 通过 D3DKMT 补充风扇 RPM、小数温度精度，或作为非 NVIDIA GPU（AMD/Intel）的通用温度采集路线
        self.mergeD3dkmt(&snap);

        // 4. 若老显卡驱动（WDDM < 2.4）不支持 D3DKMT 温度且前面未扫到设备，通过 EnumDisplayDevicesW 保底显示真实显卡名（温度诚实标 N/A）
        if (snap.count == 0) {
            self.fallbackEnumDisplayAdapters(&snap);
        }
        return snap;
    }

    fn collectNvapi(self: *WinGpuProvider, snap: *GpuSnapshot) void {
        const enum_fn = self.nvapi.enum_gpus orelse return;
        var handles: [64]?*anyopaque = [_]?*anyopaque{null} ** 64;
        var gpu_count: u32 = 0;
        if (enum_fn(&handles, &gpu_count) != 0 or gpu_count == 0) return;

        const n = @min(@as(usize, gpu_count), MAX_GPUS);
        for (0..n) |i| {
            const h = handles[i] orelse continue;
            var g = GpuInfo{
                .vendor_id = 0x10DE,
                .temp_source = "nvapi",
            };

            if (self.nvapi.get_name) |gn| {
                var nb: [64]u8 = std.mem.zeroes([64]u8);
                if (gn(h, &nb) == 0) {
                    const sl = std.mem.sliceTo(&nb, 0);
                    const clen = @min(g.name.len, sl.len);
                    @memcpy(g.name[0..clen], sl[0..clen]);
                    g.name_len = clen;
                }
            }
            if (self.nvapi.get_thermal) |gt| {
                var ts = NvGpuThermalSettingsV1{};
                // NVAPI_THERMAL_TARGET_ALL = 15
                if (gt(h, 15, &ts) == 0 and ts.count > 0) {
                    const cnt = @min(@as(usize, ts.count), 3);
                    for (0..cnt) |ti| {
                        const t = ts.sensor[ti].current_temp;
                        if (t > 0 and t < 150) {
                            g.temp_c = @floatFromInt(t);
                            g.temp_status = .ok;
                            g.temp_source = "nvapi";
                            if (ts.sensor[ti].target == 1) break; // 优先核心温度
                        }
                    }
                }
            }
            if (self.nvapi.get_pstates) |gp| {
                var ps = NvGpuDynamicPstatesInfoEx{};
                if (gp(h, &ps) == 0 and (ps.utilization[0].present & 1) != 0 and ps.utilization[0].percentage <= 100) {
                    g.usage_pct = @floatFromInt(ps.utilization[0].percentage);
                }
            }
            if (self.nvapi.get_tach) |gtach| {
                var rpm: u32 = 0;
                if (gtach(h, &rpm) == 0 and rpm > 0 and rpm < 20000) {
                    g.fan_rpm = rpm;
                }
            }
            if (self.nvapi.get_mem) |gm| {
                var mi = NvMemoryInfoV2{};
                if (gm(h, &mi) == 0 and mi.dedicated_video_memory_kb > 0) {
                    g.mem_total_bytes = @as(u64, mi.dedicated_video_memory_kb) * 1024;
                    if (mi.cur_available_dedicated_video_memory_kb <= mi.dedicated_video_memory_kb) {
                        g.mem_used_bytes = @as(u64, mi.dedicated_video_memory_kb - mi.cur_available_dedicated_video_memory_kb) * 1024;
                    }
                }
            }

            if (snap.count < MAX_GPUS) {
                snap.gpus[snap.count] = g;
                snap.count += 1;
            }
        }
    }

    fn fallbackEnumDisplayAdapters(self: *WinGpuProvider, snap: *GpuSnapshot) void {
        _ = self;
        var dev_idx: win32.DWORD = 0;
        while (dev_idx < 16 and snap.count < MAX_GPUS) : (dev_idx += 1) {
            var dd = win32.DISPLAY_DEVICEW{};
            if (win32.EnumDisplayDevicesW(null, dev_idx, &dd, 0) == 0) break;
            if ((dd.StateFlags & win32.DISPLAY_DEVICE_MIRRORING_DRIVER) != 0) continue;
            if ((dd.StateFlags & win32.DISPLAY_DEVICE_ACTIVE) == 0) continue;

            var utf8_buf: [128]u8 = std.mem.zeroes([128]u8);
            const wlen = std.mem.indexOfScalar(u16, &dd.DeviceString, 0) orelse dd.DeviceString.len;
            const n = std.unicode.utf16LeToUtf8(&utf8_buf, dd.DeviceString[0..wlen]) catch 0;
            if (n == 0) continue;
            const name_slice = utf8_buf[0..n];

            // 去重同一块多输出显卡
            var dup = false;
            for (snap.gpus[0..snap.count]) |existing| {
                if (std.mem.eql(u8, existing.nameSlice(), name_slice)) {
                    dup = true;
                    break;
                }
            }
            if (dup) continue;

            var g = GpuInfo{
                .temp_status = .unsupported,
                .temp_source = "display-enum",
            };
            @memcpy(g.name[0..n], name_slice);
            g.name_len = n;
            if (std.mem.indexOf(u8, name_slice, "NVIDIA") != null) {
                g.vendor_id = 0x10DE;
            } else if (std.mem.indexOf(u8, name_slice, "AMD") != null or std.mem.indexOf(u8, name_slice, "Radeon") != null) {
                g.vendor_id = 0x1002;
            } else if (std.mem.indexOf(u8, name_slice, "Intel") != null) {
                g.vendor_id = 0x8086;
            }
            snap.gpus[snap.count] = g;
            snap.count += 1;
        }
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

        // 同步验证老款 NVIDIA 驱动回退链路（nvapi64.dll）在本机真实可用且无 ABI 错位
        var nvapi = NvapiApi.load();
        defer nvapi.unload();
        if (nvapi.initialized) {
            var fake_prov = WinGpuProvider{ .nvml = .{}, .nvapi = nvapi };
            var nv_snap = GpuSnapshot{};
            fake_prov.collectNvapi(&nv_snap);
            try std.testing.expect(nv_snap.count >= 1);
            try std.testing.expect(nv_snap.gpus[0].name_len > 0);
            try std.testing.expect(nv_snap.gpus[0].temp_c != null);
            try std.testing.expect(nv_snap.gpus[0].temp_c.? > 5.0 and nv_snap.gpus[0].temp_c.? < 130.0);
        }
    } else {
        // Linux 物理机或无头容器均安全运行不崩溃
        for (snap.slice()) |g| {
            try std.testing.expect(g.name_len > 0);
        }
    }
}
