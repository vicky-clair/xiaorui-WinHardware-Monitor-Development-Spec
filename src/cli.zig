//! 跨平台无界面 CLI 硬件检测与准确基准测试入口（Windows & Linux 通用）。
//! 支持在无桌面的 Linux 服务器 / SSH 终端下运行实时硬件监测与准确烤机测试：
//!   --cli / --info          输出完整真实硬件信息、传感器温度、物理磁盘与 21 条健康规则评估
//!   --bench <cpu|mem|disk|all>  执行准确硬件稳定性与性能测试（内置高温熔断保护）
//!   --duration <秒>         CPU 测试时长（默认 10 秒）
//!   --threads <数>          CPU 测试线程数（默认全部逻辑核心）
//!   --mem-mb <MB>           内存位翻转校验容量（默认 128 MB）
//!   --disk-mb <MB>          磁盘文件级测试大小（默认 128 MB，仅受控临时文件并自动清理）
//!   --cutoff-c <°C>         高温自动熔断阈值（默认 90°C）
const std = @import("std");
const builtin = @import("builtin");
const system_info = @import("providers/windows/system_info.zig");
const gpu_provider = @import("providers/windows/gpu_provider.zig");
const storage_enum = @import("collectors/storage/enumerate.zig");
const nvme_smart = @import("collectors/storage/nvme_smart.zig");
const ata_smart = @import("collectors/storage/ata_smart.zig");
const health_rules = @import("core/health_rules.zig");
const benchmarks = @import("core/benchmarks.zig");
const paths_mod = @import("platform/paths.zig");

pub const CliOptions = struct {
    show_info: bool = false,
    bench_target: []const u8 = "",
    duration_s: u32 = 10,
    threads: u32 = 0,
    mem_mb: u32 = 128,
    disk_mb: u32 = 128,
    cutoff_c: f64 = 90.0,
};

pub fn runCli(allocator: std.mem.Allocator, opts: CliOptions) !void {
    var out_buf: [4096]u8 = undefined;
    var stdout_w = std.fs.File.stdout().writer(&out_buf);
    const w = &stdout_w.interface;
    defer w.flush() catch {};

    try w.print("============================================================\n", .{});
    try w.print("WinHardware Monitor V2.0 — 跨平台硬件检测与测试 CLI ({s})\n", .{@tagName(builtin.os.tag)});
    try w.print("============================================================\n", .{});

    // 1. 采集真实系统、传感器、GPU 与物理磁盘信息
    var sys_prov = system_info.SystemInfoProvider.init(allocator);
    defer sys_prov.deinit();
    std.Thread.sleep(250 * std.time.ns_per_ms);
    const sys = sys_prov.collect();

    var gpu_prov = gpu_provider.GpuProvider.init();
    defer gpu_prov.deinit();
    const gpu = gpu_prov.collect();

    const hwmon_snap = if (builtin.os.tag == .linux)
        @import("providers/linux/hwmon.zig").collectHwmonSnapshot()
    else
        @import("providers/libre_hardware_monitor/client.zig").ExtensionSnapshot{};

    try w.print("\n[处理器 CPU]\n", .{});
    try w.print("  型号: {s}\n", .{sys.cpuNameSlice()});
    try w.print("  逻辑核心: {d} | 使用率: {?d:.1}% ({s}) | 频率: {?d:.0} MHz ({s})\n", .{
        sys.logical_cores,
        sys.cpu_usage_pct,
        sys.cpu_usage_source,
        sys.cpu_clock_mhz,
        sys.cpu_clock_source,
    });
    if (hwmon_snap.cpu_package_temp_c) |ct| {
        try w.print("  CPU 封装温度: {d:.1} °C (原生内核 hwmon)\n", .{ct});
    } else {
        try w.print("  CPU 封装温度: N/A\n", .{});
    }

    try w.print("\n[内存与主板]\n", .{});
    const used_mb = sys.mem_used_bytes / (1024 * 1024);
    const total_mb = sys.mem_total_bytes / (1024 * 1024);
    try w.print("  物理内存: {d} / {d} MB ({?d:.1}%)\n", .{ used_mb, total_mb, sys.mem_load_pct });
    if (sys.smbios_info.available) {
        try w.print("  主板: {s} {s} ({s})\n", .{
            sys.smbios_info.boardManufacturer(),
            sys.smbios_info.boardProduct(),
            sys.smbios_info.boardVersion(),
        });
    }
    try w.print("  系统已运行: {d} 秒 | 实时磁盘吞吐: 读 {?d:.1} MB/s / 写 {?d:.1} MB/s ({?d:.0} IOPS)\n", .{
        sys.uptime_seconds,
        sys.disk_read_mbs,
        sys.disk_write_mbs,
        sys.disk_iops,
    });

    try w.print("\n[显卡 GPU ({d} 个)]\n", .{gpu.count});
    for (gpu.slice(), 0..) |g, gi| {
        try w.print("  GPU #{d}: {s} | 温度: {?d:.1} °C ({s}) | 功耗: {?d:.1} W | 风扇: {?d} RPM\n", .{
            gi, g.nameSlice(), g.temp_c, g.temp_status.labelZh(), g.power_watts, g.fan_rpm,
        });
    }

    if (hwmon_snap.sensor_count > 0) {
        try w.print("\n[内核 hwmon 传感器 ({d} 项)]\n", .{hwmon_snap.sensor_count});
        for (hwmon_snap.sensors[0..hwmon_snap.sensor_count]) |s| {
            try w.print("  - {s} / {s} ({s}): {d:.1} {s}\n", .{
                s.hardwareSlice(), s.nameSlice(), s.sensorTypeSlice(), s.value, s.unitSlice(),
            });
        }
    }

    // 2. 枚举物理磁盘 + SMART + 21 条健康规则评估
    const inv = storage_enum.enumeratePhysicalDisks();
    try w.print("\n[物理磁盘与 SMART 健康 ({d} 块)]\n", .{inv.count});
    const thr = health_rules.RuleThresholds{};
    for (inv.slice()) |d| {
        var mb: [160]u8 = undefined;
        const model = d.modelDisplay(&mb);
        const cap_gb: f64 = if (d.capacity_bytes) |b| @as(f64, @floatFromInt(b)) / 1_000_000_000.0 else 0.0;

        if (d.support == .nvme_native) {
            const nv = nvme_smart.readNvmeSmart(d.drive_index);
            if (nv.status == .ok) {
                const bl = health_rules.DiskBaseline.captureFromNvme(&nv);
                const ass = health_rules.evaluateNvme(&nv, &bl, thr);
                try w.print("  Disk {d}: {s} ({d:.1} GB, {s}, ID={s}) | 健康={s} | 温度={?d}°C | 磨损={d}% | 通电={d}h\n", .{
                    d.drive_index, model, cap_gb, d.bus_type.name(), d.stable_id.slice(), ass.overall.labelZh(), nv.composite_temp_c, nv.percentage_used, nv.power_on_hours,
                });
            } else {
                try w.print("  Disk {d}: {s} ({d:.1} GB, {s}, ID={s}) | SMART={s} (err={?d})\n", .{
                    d.drive_index, model, cap_gb, d.bus_type.name(), d.stable_id.slice(), nv.status.labelZh(), nv.error_code,
                });
            }
        } else if (!d.support.isUnsupported()) {
            const ad = ata_smart.readAtaSmartWithMode(d.drive_index, false, d.support == .usb_sat);
            if (ad.status == .ok) {
                const bl = health_rules.DiskBaseline.captureFromAta(&ad);
                const ass = health_rules.evaluateAta(&ad, &bl, thr);
                try w.print("  Disk {d}: {s} ({d:.1} GB, {s}, ID={s}) | 健康={s} | 温度={?d}°C | 属性={d}项 | 通电={?d}h\n", .{
                    d.drive_index, model, cap_gb, d.bus_type.name(), d.stable_id.slice(), ass.overall.labelZh(), ad.temperatureCelsius(), ad.attr_count, ad.powerOnHours(),
                });
                for (ass.slice()) |h| {
                    try w.print("    ! 规则命中 [{s}] {s}\n", .{ h.rule_id, h.evidenceSlice() });
                }
            } else {
                try w.print("  Disk {d}: {s} ({d:.1} GB, {s}, ID={s}) | SMART={s} (err={?d})\n", .{
                    d.drive_index, model, cap_gb, d.bus_type.name(), d.stable_id.slice(), ad.status.labelZh(), ad.error_code,
                });
            }
        } else {
            try w.print("  Disk {d}: {s} ({d:.1} GB, {s}) | 健康=未知 ({s})\n", .{
                d.drive_index, model, cap_gb, d.bus_type.name(), d.support.labelZh(),
            });
        }
    }

    // 3. 若指定了 --bench，则执行准确硬件测试并实时联动高温熔断
    if (opts.bench_target.len > 0) {
        var runner = benchmarks.BenchmarkRunner.init(allocator);
        defer runner.deinit();

        const run_all = std.ascii.eqlIgnoreCase(opts.bench_target, "all");
        const cfg = benchmarks.BenchmarkConfig{
            .cpu_threads = if (opts.threads > 0) opts.threads else @max(sys.logical_cores, 1),
            .duration_s = opts.duration_s,
            .thermal_cutoff_c = opts.cutoff_c,
            .mem_size_mb = opts.mem_mb,
            .disk_file_mb = opts.disk_mb,
        };

        if (run_all or std.ascii.eqlIgnoreCase(opts.bench_target, "cpu")) {
            try w.print("\n[基准测试 1/3] 启动 CPU 确定性算力与稳定性校验 ({d} 线程, {d}s, 熔断 {d:.0}°C)...\n", .{ cfg.cpu_threads, cfg.duration_s, cfg.thermal_cutoff_c });
            try w.flush();
            if (runner.startCpuStress(cfg)) {
                waitWithThermalGuard(&runner);
                const snap = runner.copySnapshot();
                try w.print("  结果: {s} | 算力: {d:.2} MOPS | 错误: {d} | 峰值温度: {?d:.1}°C\n", .{
                    snap.outcome.labelZh(), snap.cpu_score_mops, snap.error_count, snap.peak_temp_c,
                });
            }
        }

        if (run_all or std.ascii.eqlIgnoreCase(opts.bench_target, "mem")) {
            try w.print("\n[基准测试 2/3] 启动 4 轮内存位翻转与带宽校验 ({d} MB)...\n", .{cfg.mem_size_mb});
            try w.flush();
            if (runner.startMemoryVerify(cfg, sys.mem_avail_bytes)) {
                waitWithThermalGuard(&runner);
                const snap = runner.copySnapshot();
                try w.print("  结果: {s} | 轮数: {d}/4 | 写入: {d:.2} GB/s | 回读校验: {d:.2} GB/s | 位错误: {d}\n", .{
                    snap.outcome.labelZh(), snap.mem_passes_done, snap.mem_write_gbs, snap.mem_read_gbs, snap.error_count,
                });
            }
        }

        if (run_all or std.ascii.eqlIgnoreCase(opts.bench_target, "disk")) {
            var paths = try paths_mod.AppPaths.resolve(allocator);
            defer paths.deinit();
            paths.ensureDirectories();
            try w.print("\n[基准测试 3/3] 启动文件级磁盘 SEQ1M / RND4K 基准 ({d} MB 临时文件于 {s}，结束后自动删除)...\n", .{ cfg.disk_file_mb, paths.logs_dir });
            try w.flush();
            if (runner.startDiskBench(cfg, paths.logs_dir)) {
                waitWithThermalGuard(&runner);
                const snap = runner.copySnapshot();
                try w.print("  结果: {s} | SEQ1M 写 {d:.1} MB/s / 读 {d:.1} MB/s | RND4K 读 {d:.1} MB/s ({d:.0} IOPS, 延迟 {d:.1} us)\n", .{
                    snap.outcome.labelZh(), snap.disk_seq_write_mbs, snap.disk_seq_read_mbs, snap.disk_rnd4k_read_mbs, snap.disk_rnd4k_read_iops, snap.disk_rnd4k_avg_lat_us,
                });
            }
        }
    }

    try w.print("\n============================================================\n", .{});
}

fn waitWithThermalGuard(runner: *benchmarks.BenchmarkRunner) void {
    while (runner.isRunning()) {
        if (builtin.os.tag == .linux) {
            const hw = @import("providers/linux/hwmon.zig").collectHwmonSnapshot();
            runner.updateLiveTemperature(hw.cpu_package_temp_c);
        }
        std.Thread.sleep(200 * std.time.ns_per_ms);
    }
}
