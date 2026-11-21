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
const i18n = @import("core/i18n.zig");

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
    try w.print("{s} ({s} | {s})\n", .{
        i18n.trSlice(
            "WinHardware Monitor V2.0 — 跨平台硬件检测与测试 CLI",
            "WinHardware Monitor V2.0 — Cross-Platform Hardware CLI",
            "WinHardware Monitor V2.0 — ハードウェア監視・テスト CLI",
        ),
        @tagName(builtin.os.tag),
        i18n.current().nativeName(),
    });
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

    try w.print("\n[{s}]\n", .{i18n.trSlice("处理器 CPU", "Processor (CPU)", "プロセッサ (CPU)")});
    try w.print("  {s}: {s}\n", .{ i18n.trSlice("型号", "Model", "モデル"), sys.cpuNameSlice() });
    try w.print("  {s}: {d} | {s}: {?d:.1}% ({s}) | {s}: {?d:.0} MHz ({s})\n", .{
        i18n.trSlice("逻辑核心", "Logical Cores", "論理コア"),
        sys.logical_cores,
        i18n.trSlice("使用率", "Usage", "使用率"),
        sys.cpu_usage_pct,
        sys.cpu_usage_source,
        i18n.trSlice("频率", "Clock", "クロック"),
        sys.cpu_clock_mhz,
        sys.cpu_clock_source,
    });
    if (hwmon_snap.cpu_package_temp_c) |ct| {
        try w.print("  {s}: {d:.1} °C (hwmon)\n", .{ i18n.trSlice("CPU 封装温度", "CPU Package Temp", "CPU パッケージ温度"), ct });
    } else {
        try w.print("  {s}: N/A\n", .{i18n.trSlice("CPU 封装温度", "CPU Package Temp", "CPU パッケージ温度")});
    }

    try w.print("\n[{s}]\n", .{i18n.trSlice("内存与主板", "Memory & Motherboard", "メモリ・マザーボード")});
    const used_mb = sys.mem_used_bytes / (1024 * 1024);
    const total_mb = sys.mem_total_bytes / (1024 * 1024);
    try w.print("  {s}: {d} / {d} MB ({?d:.1}%)\n", .{ i18n.trSlice("物理内存", "Physical Memory", "物理メモリ"), used_mb, total_mb, sys.mem_load_pct });
    if (sys.smbios_info.available) {
        try w.print("  {s}: {s} {s} ({s})\n", .{
            i18n.trSlice("主板", "Motherboard", "マザーボード"),
            sys.smbios_info.boardManufacturer(),
            sys.smbios_info.boardProduct(),
            sys.smbios_info.boardVersion(),
        });
    }
    try w.print("  {s}: {d}s | {s}: R {?d:.1} MB/s / W {?d:.1} MB/s ({?d:.0} IOPS)\n", .{
        i18n.trSlice("系统运行时间", "Uptime", "稼働時間"),
        sys.uptime_seconds,
        i18n.trSlice("实时磁盘 I/O", "Live Disk I/O", "リアルタイム Disk I/O"),
        sys.disk_read_mbs,
        sys.disk_write_mbs,
        sys.disk_iops,
    });

    try w.print("\n[{s} ({d})]\n", .{ i18n.trSlice("显卡 GPU", "Graphics (GPU)", "グラフィック (GPU)"), gpu.count });
    for (gpu.slice(), 0..) |g, gi| {
        try w.print("  GPU #{d}: {s} | {s}: {?d:.1} °C ({s}) | {s}: {?d:.1} W | {s}: {?d} RPM\n", .{
            gi,
            g.nameSlice(),
            i18n.trSlice("温度", "Temp", "温度"),
            g.temp_c,
            g.temp_status.labelZh(),
            i18n.trSlice("功耗", "Power", "電力"),
            g.power_watts,
            i18n.trSlice("风扇", "Fan", "ファン"),
            g.fan_rpm,
        });
    }

    if (hwmon_snap.sensor_count > 0) {
        try w.print("\n[{s} ({d})]\n", .{ i18n.trSlice("内核 hwmon 传感器", "Kernel hwmon Sensors", "カーネル hwmon センサー"), hwmon_snap.sensor_count });
        for (hwmon_snap.sensors[0..hwmon_snap.sensor_count]) |s| {
            try w.print("  - {s} / {s} ({s}): {d:.1} {s}\n", .{
                s.hardwareSlice(), s.nameSlice(), s.sensorTypeSlice(), s.value, s.unitSlice(),
            });
        }
    }

    // 2. 枚举物理磁盘 + SMART + 21 条健康规则评估
    const inv = storage_enum.enumeratePhysicalDisks();
    try w.print("\n[{s} ({d})]\n", .{ i18n.trSlice("物理磁盘与 SMART 健康", "Physical Disks & SMART Health", "物理ディスク・SMART 健康状態"), inv.count });
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
                try w.print("  Disk {d}: {s} ({d:.1} GB, {s}, ID={s}) | {s}={s} | {s}={?d}°C | {s}={d}% | POH={d}h\n", .{
                    d.drive_index,
                    model,
                    cap_gb,
                    d.bus_type.name(),
                    d.stable_id.slice(),
                    i18n.trSlice("健康", "Health", "健康"),
                    ass.overall.labelZh(),
                    i18n.trSlice("温度", "Temp", "温度"),
                    nv.composite_temp_c,
                    i18n.trSlice("磨损", "Used", "消耗"),
                    nv.percentage_used,
                    nv.power_on_hours,
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
                try w.print("  Disk {d}: {s} ({d:.1} GB, {s}, ID={s}) | {s}={s} | {s}={?d}°C | Attrs={d} | POH={?d}h\n", .{
                    d.drive_index,
                    model,
                    cap_gb,
                    d.bus_type.name(),
                    d.stable_id.slice(),
                    i18n.trSlice("健康", "Health", "健康"),
                    ass.overall.labelZh(),
                    i18n.trSlice("温度", "Temp", "温度"),
                    ad.temperatureCelsius(),
                    ad.attr_count,
                    ad.powerOnHours(),
                });
                for (ass.slice()) |h| {
                    try w.print("    ! [{s}] {s}\n", .{ h.rule_id, h.evidenceSlice() });
                }
            } else {
                try w.print("  Disk {d}: {s} ({d:.1} GB, {s}, ID={s}) | SMART={s} (err={?d})\n", .{
                    d.drive_index, model, cap_gb, d.bus_type.name(), d.stable_id.slice(), ad.status.labelZh(), ad.error_code,
                });
            }
        } else {
            try w.print("  Disk {d}: {s} ({d:.1} GB, {s}) | {s}={s} ({s})\n", .{
                d.drive_index,
                model,
                cap_gb,
                d.bus_type.name(),
                i18n.trSlice("健康", "Health", "健康"),
                i18n.trSlice("未知", "Unknown", "不明"),
                d.support.labelZh(),
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
            try w.print("\n[1/3] {s} ({d}T, {d}s, cutoff {d:.0}°C)...\n", .{
                benchmarks.TestKind.cpu_stress.labelZh(), cfg.cpu_threads, cfg.duration_s, cfg.thermal_cutoff_c,
            });
            try w.flush();
            if (runner.startCpuStress(cfg)) {
                waitWithThermalGuard(&runner);
                const snap = runner.copySnapshot();
                try w.print("  {s}: {s} | {d:.2} MOPS | Errors={d} | Peak={?d:.1}°C\n", .{
                    i18n.trSlice("结果", "Result", "結果"), snap.outcome.labelZh(), snap.cpu_score_mops, snap.error_count, snap.peak_temp_c,
                });
            }
        }

        if (run_all or std.ascii.eqlIgnoreCase(opts.bench_target, "mem")) {
            try w.print("\n[2/3] {s} ({d} MB)...\n", .{ benchmarks.TestKind.memory_verify.labelZh(), cfg.mem_size_mb });
            try w.flush();
            if (runner.startMemoryVerify(cfg, sys.mem_avail_bytes)) {
                waitWithThermalGuard(&runner);
                const snap = runner.copySnapshot();
                try w.print("  {s}: {s} | {d}/4 | W {d:.2} GB/s | R+Verify {d:.2} GB/s | Errors={d}\n", .{
                    i18n.trSlice("结果", "Result", "結果"), snap.outcome.labelZh(), snap.mem_passes_done, snap.mem_write_gbs, snap.mem_read_gbs, snap.error_count,
                });
            }
        }

        if (run_all or std.ascii.eqlIgnoreCase(opts.bench_target, "disk")) {
            var paths = try paths_mod.AppPaths.resolve(allocator);
            defer paths.deinit();
            paths.ensureDirectories();
            try w.print("\n[3/3] {s} ({d} MB -> {s})...\n", .{ benchmarks.TestKind.disk_bench.labelZh(), cfg.disk_file_mb, paths.logs_dir });
            try w.flush();
            if (runner.startDiskBench(cfg, paths.logs_dir)) {
                waitWithThermalGuard(&runner);
                const snap = runner.copySnapshot();
                try w.print("  {s}: {s} | SEQ1M W {d:.1} MB/s / R {d:.1} MB/s | RND4K R {d:.1} MB/s ({d:.0} IOPS, {d:.1} us)\n", .{
                    i18n.trSlice("结果", "Result", "結果"), snap.outcome.labelZh(), snap.disk_seq_write_mbs, snap.disk_seq_read_mbs, snap.disk_rnd4k_read_mbs, snap.disk_rnd4k_read_iops, snap.disk_rnd4k_avg_lat_us,
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
