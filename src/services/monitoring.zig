const std = @import("std");
const system_info = @import("../providers/windows/system_info.zig");
const gpu_provider = @import("../providers/windows/gpu_provider.zig");
const lhm_client = @import("../providers/libre_hardware_monitor/client.zig");
const storage_enum = @import("../collectors/storage/enumerate.zig");
const nvme_smart = @import("../collectors/storage/nvme_smart.zig");
const ata_smart = @import("../collectors/storage/ata_smart.zig");
const health_rules = @import("../core/health_rules.zig");
const alert_mod = @import("../core/alert.zig");
const device_id = @import("../core/device_id.zig");
const sensor = @import("../core/sensor.zig");
const sensor_stats = @import("../core/sensor_stats.zig");
const telemetry = @import("../core/telemetry.zig");
const repository = @import("../database/repository.zig");

/// 后台硬件监控服务（严格遵守规范红线 #10：GUI 主线程不得执行阻塞式硬件查询）
/// 维护固定容量内存环形缓冲区（1800 点 = 2s × 1 小时）并通过互斥锁发布只读快照。
pub const HISTORY_CAPACITY: usize = 1800;

pub const DiskRuntimeState = struct {
    device: storage_enum.DiskDevice = .{},
    nvme: nvme_smart.NvmeSmartData = .{},
    ata: ata_smart.AtaSmartData = .{},
    temp_desc: nvme_smart.StorageTempDescriptor = .{},
    baseline: health_rules.DiskBaseline = .{},
    assessment: health_rules.HealthAssessment = .{},

    pub fn effectiveTempC(self: *const DiskRuntimeState) ?i32 {
        if (self.nvme.status == .ok and self.nvme.composite_temp_c != null) return self.nvme.composite_temp_c;
        if (self.temp_desc.available and self.temp_desc.temp_c != null) return self.temp_desc.temp_c;
        if (self.ata.status == .ok) return self.ata.temperatureCelsius();
        return null;
    }

    pub fn effectiveTempStatus(self: *const DiskRuntimeState) sensor.SensorStatus {
        if (self.effectiveTempC() != null) return .ok;
        if (self.device.support.isUnsupported()) return .unsupported;
        if (self.device.support == .nvme_native) return self.nvme.status;
        return self.ata.status;
    }

    pub fn effectivePowerOnHours(self: *const DiskRuntimeState) ?u64 {
        if (self.nvme.status == .ok) return @intCast(@min(self.nvme.power_on_hours, std.math.maxInt(u64)));
        if (self.ata.status == .ok) return self.ata.powerOnHours();
        return null;
    }
};

pub const SharedTelemetry = struct {
    system: system_info.SystemSnapshot = .{},
    has_system_sample: bool = false,
    gpu: gpu_provider.GpuSnapshot = .{},
    has_gpu_sample: bool = false,
    extension: lhm_client.ExtensionSnapshot = .{},
    disks: storage_enum.DiskInventory = .{},
    disk_states: [storage_enum.MAX_DISKS]DiskRuntimeState = [_]DiskRuntimeState{.{}} ** storage_enum.MAX_DISKS,
    disk_count: usize = 0,
    has_disk_inventory: bool = false,
    sample_seq: u64 = 0,

    cpu_usage_history: telemetry.RingBuffer(HISTORY_CAPACITY) = .{},
    cpu_temp_history: telemetry.RingBuffer(HISTORY_CAPACITY) = .{},
    mem_usage_history: telemetry.RingBuffer(HISTORY_CAPACITY) = .{},
    gpu_temp_history: telemetry.RingBuffer(HISTORY_CAPACITY) = .{},
    gpu_power_history: telemetry.RingBuffer(HISTORY_CAPACITY) = .{},
    disk0_temp_history: telemetry.RingBuffer(HISTORY_CAPACITY) = .{},

    // P6: 数据库状态
    db_active: bool = false,
    db_recovered: bool = false,
    db_flush_count: u64 = 0,

    // P7: 告警状态快照
    active_alert_count: u32 = 0,
    alert_history: [alert_mod.MAX_ALERT_HISTORY]alert_mod.AlertEvent = [_]alert_mod.AlertEvent{.{}} ** alert_mod.MAX_ALERT_HISTORY,
    alert_history_count: usize = 0,

    // V2: HWiNFO64 风格全传感器 Min / Avg / Max 统计表
    sensor_stats: sensor_stats.SensorStatsTable = .{},

    // V2.2: 最近基准测试历史成绩（SQLite 持久化，用于优化前后对比）
    bench_history: [16]repository.BenchmarkHistoryRecord = [_]repository.BenchmarkHistoryRecord{.{}} ** 16,
    bench_history_count: usize = 0,
};

const BucketAccum = struct {
    min_v: f64 = std.math.inf(f64),
    max_v: f64 = -std.math.inf(f64),
    sum: f64 = 0.0,
    count: i64 = 0,

    fn add(self: *BucketAccum, v: f64) void {
        if (v < self.min_v) self.min_v = v;
        if (v > self.max_v) self.max_v = v;
        self.sum += v;
        self.count += 1;
    }

    fn reset(self: *BucketAccum) void {
        self.* = .{};
    }

    fn avg(self: BucketAccum) f64 {
        return if (self.count > 0) self.sum / @as(f64, @floatFromInt(self.count)) else 0.0;
    }
};

const BaselineEntry = struct {
    id: device_id.StableId = .{},
    baseline: health_rules.DiskBaseline = .{},
};

pub const MonitoringService = struct {
    allocator: std.mem.Allocator,
    db_path: ?[]const u8 = null,
    mutex: std.Thread.Mutex = .{},
    shared: SharedTelemetry = .{},
    latest_seq_atomic: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    pending_bench_save: ?repository.BenchmarkHistoryRecord = null,
    alerts: alert_mod.AlertEngine = .{},
    pending_notification: ?alert_mod.AlertEvent = null,
    stop_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    paused_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    rescan_disks_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    allow_wake_standby: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    extension_enabled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    interval_ms: std.atomic.Value(u32) = std.atomic.Value(u32).init(2000),
    smart_interval_ms: std.atomic.Value(u32) = std.atomic.Value(u32).init(60000),
    cpu_caution_c: f64 = 80.0,
    cpu_warning_c: f64 = 90.0,
    gpu_caution_c: f64 = 80.0,
    gpu_warning_c: f64 = 90.0,
    ssd_caution_c: i32 = 60,
    ssd_warning_c: i32 = 70,
    hdd_caution_c: i32 = 50,
    hdd_warning_c: i32 = 55,
    retain_1m_days: u32 = 7,
    retain_15m_days: u32 = 30,
    retain_smart_days: u32 = 90,
    rule_thresholds: health_rules.RuleThresholds = .{},
    baselines: [storage_enum.MAX_DISKS]BaselineEntry = [_]BaselineEntry{.{}} ** storage_enum.MAX_DISKS,
    baseline_count: usize = 0,
    thread: ?std.Thread = null,

    pub fn init(allocator: std.mem.Allocator, db_path: ?[]const u8, system_interval_ms: u32, smart_interval_ms: u32, allow_wake: bool) MonitoringService {
        var svc = MonitoringService{
            .allocator = allocator,
            .db_path = db_path,
        };
        svc.interval_ms.store(@max(system_interval_ms, 500), .release);
        svc.smart_interval_ms.store(@max(smart_interval_ms, 30000), .release);
        svc.allow_wake_standby.store(allow_wake, .release);
        return svc;
    }

    pub fn acknowledgeAllAlerts(self: *MonitoringService) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.alerts.acknowledgeAll();
        self.syncAlertsLocked();
        self.shared.sample_seq += 1;
        self.latest_seq_atomic.store(self.shared.sample_seq, .release);
    }

    pub fn takePendingNotification(self: *MonitoringService) ?alert_mod.AlertEvent {
        self.mutex.lock();
        defer self.mutex.unlock();
        const ev = self.pending_notification;
        self.pending_notification = null;
        return ev;
    }

    fn syncAlertsLocked(self: *MonitoringService) void {
        self.shared.active_alert_count = self.alerts.activeCount();
        self.shared.alert_history = self.alerts.history;
        self.shared.alert_history_count = self.alerts.history_count;
    }

    pub fn start(self: *MonitoringService) !void {
        self.stop_flag.store(false, .release);
        self.rescan_disks_flag.store(true, .release);
        self.thread = try std.Thread.spawn(.{}, workerMain, .{self});
    }

    pub fn stop(self: *MonitoringService) void {
        self.stop_flag.store(true, .release);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    pub fn setPaused(self: *MonitoringService, paused: bool) void {
        self.paused_flag.store(paused, .release);
    }

    pub fn setIntervalMs(self: *MonitoringService, ms: u32) void {
        self.interval_ms.store(std.math.clamp(ms, 500, 60000), .release);
    }

    pub fn setSmartIntervalMs(self: *MonitoringService, ms: u32) void {
        self.smart_interval_ms.store(std.math.clamp(ms, 30000, 3600000), .release);
    }

    pub fn setAllowWakeStandby(self: *MonitoringService, allow: bool) void {
        self.allow_wake_standby.store(allow, .release);
    }

    pub fn setExtensionEnabled(self: *MonitoringService, enabled: bool) void {
        self.extension_enabled.store(enabled, .release);
    }

    pub fn requestExtensionShutdown(self: *MonitoringService) bool {
        const client = lhm_client.LhmClient{ .allocator = self.allocator, .enabled = true };
        return client.requestShutdown();
    }

    pub fn resetSensorStats(self: *MonitoringService) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.shared.sensor_stats.resetStats();
        self.shared.sample_seq += 1;
        self.latest_seq_atomic.store(self.shared.sample_seq, .release);
    }

    pub fn triggerDiskRescan(self: *MonitoringService) void {
        self.rescan_disks_flag.store(true, .release);
    }

    /// 异步登记一条已完成的基准测试成绩（立即更新内存列表，并由后台线程安全写入 SQLite）
    pub fn recordBenchmarkHistory(self: *MonitoringService, rec: repository.BenchmarkHistoryRecord) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        // 插入到内存列表头部（最新在前）
        var i: usize = @min(self.shared.bench_history_count, self.shared.bench_history.len - 1);
        while (i > 0) : (i -= 1) {
            self.shared.bench_history[i] = self.shared.bench_history[i - 1];
        }
        self.shared.bench_history[0] = rec;
        if (self.shared.bench_history_count < self.shared.bench_history.len) {
            self.shared.bench_history_count += 1;
        }
        self.pending_bench_save = rec;
        self.shared.sample_seq += 1;
        self.latest_seq_atomic.store(self.shared.sample_seq, .release);
    }

    /// 规范 §2.5.5：用户确认告警后以当前值为新基线
    pub fn resetBaselineForDisk(self: *MonitoringService, idx: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (idx >= self.shared.disk_count) return;
        const ds = &self.shared.disk_states[idx];
        if (ds.nvme.status == .ok) {
            ds.baseline = health_rules.DiskBaseline.captureFromNvme(&ds.nvme);
            self.upsertBaselineLocked(ds.device.stable_id, ds.baseline);
            ds.assessment = health_rules.evaluateNvme(&ds.nvme, &ds.baseline, self.rule_thresholds);
            ds.device.health = ds.assessment.overall;
        } else if (ds.ata.status == .ok) {
            ds.baseline = health_rules.DiskBaseline.captureFromAta(&ds.ata);
            self.upsertBaselineLocked(ds.device.stable_id, ds.baseline);
            ds.assessment = health_rules.evaluateAta(&ds.ata, &ds.baseline, self.rule_thresholds);
            ds.device.health = ds.assessment.overall;
        }
        self.shared.sample_seq += 1;
        self.latest_seq_atomic.store(self.shared.sample_seq, .release);
    }

    /// 非阻塞拷贝后台快照（GUI 主线程专用：即使后台正在采集硬件或写入 SQLite，也绝不阻塞渲染帧）
    pub fn tryCopySnapshot(self: *MonitoringService, out: *SharedTelemetry) bool {
        if (!self.mutex.tryLock()) return false;
        defer self.mutex.unlock();
        out.* = self.shared;
        return true;
    }

    /// 低占用零冗余快照拷贝：仅当后台发布了新样本序号时才尝试加锁拷贝，避免 60 FPS 空转 memcpy (~280KB/帧)
    pub fn tryCopySnapshotIfChanged(self: *MonitoringService, out: *SharedTelemetry, last_seq: *u64) bool {
        const cur = self.latest_seq_atomic.load(.acquire);
        if (cur == last_seq.*) return false;
        if (!self.mutex.tryLock()) return false;
        defer self.mutex.unlock();
        out.* = self.shared;
        last_seq.* = self.shared.sample_seq;
        return true;
    }

    pub fn latestSeqAtomic(self: *const MonitoringService) u64 {
        return self.latest_seq_atomic.load(.acquire);
    }

    pub fn latestSeq(self: *MonitoringService) u64 {
        return self.latest_seq_atomic.load(.acquire);
    }

    fn findBaselineLocked(self: *const MonitoringService, id: device_id.StableId) ?health_rules.DiskBaseline {
        for (self.baselines[0..self.baseline_count]) |b| {
            if (b.id.eql(id)) return b.baseline;
        }
        return null;
    }

    fn upsertBaselineLocked(self: *MonitoringService, id: device_id.StableId, bl: health_rules.DiskBaseline) void {
        for (self.baselines[0..self.baseline_count]) |*b| {
            if (b.id.eql(id)) {
                b.baseline = bl;
                return;
            }
        }
        if (self.baseline_count < self.baselines.len) {
            self.baselines[self.baseline_count] = .{ .id = id, .baseline = bl };
            self.baseline_count += 1;
        }
    }

    fn pollAllDisksSmart(self: *MonitoringService, inv: *const storage_enum.DiskInventory, elapsed_s: f64) void {
        const allow_wake = self.allow_wake_standby.load(.acquire);
        const next_states = self.allocator.create([storage_enum.MAX_DISKS]DiskRuntimeState) catch return;
        defer self.allocator.destroy(next_states);
        next_states.* = [_]DiskRuntimeState{.{}} ** storage_enum.MAX_DISKS;

        for (inv.slice(), 0..) |dev, i| {
            var ds = DiskRuntimeState{ .device = dev };
            ds.temp_desc = nvme_smart.readStorageTemperature(dev.drive_index);

            if (dev.support.isUnsupported()) {
                ds.assessment = .{ .overall = .unknown };
            } else if (dev.support == .nvme_native) {
                ds.nvme = nvme_smart.readNvmeSmart(dev.drive_index);
                if (ds.nvme.status == .ok) {
                    self.mutex.lock();
                    const existing_bl = self.findBaselineLocked(dev.stable_id);
                    const bl = existing_bl orelse blk: {
                        const fresh = health_rules.DiskBaseline.captureFromNvme(&ds.nvme);
                        self.upsertBaselineLocked(dev.stable_id, fresh);
                        break :blk fresh;
                    };
                    const thr = self.rule_thresholds;
                    self.mutex.unlock();

                    ds.baseline = bl;
                    ds.assessment = health_rules.evaluateNvme(&ds.nvme, &ds.baseline, thr);
                } else {
                    ds.assessment = .{ .overall = .unknown };
                }
            } else {
                // SATA / USB SAT (标准 ATA + 标准只读 T10 SAT 透传 + CHECK POWER MODE 保护)
                ds.ata = ata_smart.readAtaSmartWithMode(dev.drive_index, allow_wake, dev.support == .usb_sat);
                if (ds.ata.status == .ok) {
                    self.mutex.lock();
                    const existing_bl = self.findBaselineLocked(dev.stable_id);
                    const bl = existing_bl orelse blk: {
                        const fresh = health_rules.DiskBaseline.captureFromAta(&ds.ata);
                        self.upsertBaselineLocked(dev.stable_id, fresh);
                        break :blk fresh;
                    };
                    const thr = self.rule_thresholds;
                    self.mutex.unlock();

                    ds.baseline = bl;
                    ds.assessment = health_rules.evaluateAta(&ds.ata, &ds.baseline, thr);
                } else {
                    ds.assessment = .{ .overall = .unknown };
                }
            }

            ds.device.health = ds.assessment.overall;
            ds.device.temperature_c = ds.effectiveTempC();
            ds.device.temp_status = ds.effectiveTempStatus();
            next_states[i] = ds;
        }

        self.mutex.lock();
        self.shared.disks = inv.*;
        self.shared.disk_states = next_states.*;
        self.shared.disk_count = inv.count;
        self.shared.has_disk_inventory = true;
        if (inv.count > 0) {
            if (next_states[0].effectiveTempC()) |t0| {
                self.shared.disk0_temp_history.push(elapsed_s, @floatFromInt(t0));
            }
        }
        self.shared.sample_seq += 1;
        self.latest_seq_atomic.store(self.shared.sample_seq, .release);
        self.mutex.unlock();
    }

    fn workerMain(self: *MonitoringService) void {
        var provider = system_info.SystemInfoProvider.init(self.allocator);
        defer provider.deinit();

        var gpu_prov = gpu_provider.GpuProvider.init();
        defer gpu_prov.deinit();

        var ext_client = lhm_client.LhmClient{
            .allocator = self.allocator,
            .enabled = self.extension_enabled.load(.acquire),
        };

        // P6: 在后台工作线程中打开本地 SQLite 数据库（带损坏自动恢复，不阻塞 UI）
        var repo_opt: ?repository.Repository = null;
        if (self.db_path) |path| {
            if (repository.Repository.openWithRecovery(self.allocator, path)) |opened| {
                repo_opt = opened.repo;
                var loaded_hist: [16]repository.BenchmarkHistoryRecord = [_]repository.BenchmarkHistoryRecord{.{}} ** 16;
                const hist_n = repo_opt.?.queryRecentBenchmarks(&loaded_hist) catch 0;
                self.mutex.lock();
                self.shared.db_active = true;
                self.shared.db_recovered = opened.recovered_from_corruption;
                self.shared.bench_history = loaded_hist;
                self.shared.bench_history_count = hist_n;
                self.shared.sample_seq += 1;
                self.latest_seq_atomic.store(self.shared.sample_seq, .release);
                self.mutex.unlock();
            } else |_| {}
        }
        defer if (repo_opt) |*r| r.close();

        var acc_cpu = BucketAccum{};
        var acc_mem = BucketAccum{};
        var acc_gpu_temp = BucketAccum{};
        var acc_disk_temp = BucketAccum{};
        var last_flush_ms: i64 = std.time.milliTimestamp();
        var last_prune_ms: i64 = last_flush_ms;

        const start_ns = std.time.nanoTimestamp();
        var last_smart_ns: i128 = 0;
        var last_disk_temp_ns: i128 = 0;
        var cached_inv = storage_enum.DiskInventory{};

        sleepInterruptible(&self.stop_flag, &self.rescan_disks_flag, 150);

        while (!self.stop_flag.load(.acquire)) {
            const now_ns = std.time.nanoTimestamp();
            const now_utc_ms = std.time.milliTimestamp();
            const elapsed_s: f64 = @as(f64, @floatFromInt(now_ns - start_ns)) / @as(f64, @floatFromInt(std.time.ns_per_s));

            const need_rescan = self.rescan_disks_flag.swap(false, .acq_rel);
            const smart_period_ns: i128 = @as(i128, self.smart_interval_ms.load(.acquire)) * std.time.ns_per_ms;
            const smart_due = (last_smart_ns == 0) or (now_ns - last_smart_ns >= smart_period_ns);

            if (need_rescan) {
                cached_inv = storage_enum.enumeratePhysicalDisks();
            }

            if (!self.paused_flag.load(.acquire)) {
                // 1. 磁盘 SMART 采集 + 磁盘健康与温度告警评估
                if (need_rescan or smart_due) {
                    self.pollAllDisksSmart(&cached_inv, elapsed_s);
                    last_smart_ns = now_ns;
                    last_disk_temp_ns = now_ns;

                    self.mutex.lock();
                    for (self.shared.disk_states[0..self.shared.disk_count]) |ds| {
                        self.alerts.evaluateDiskAssessment(ds.device.stable_id.slice(), &ds.assessment, now_utc_ms);
                        if (ds.effectiveTempC()) |tc| {
                            const thr: alert_mod.TempThresholdPair = if (ds.device.support == .nvme_native)
                                alert_mod.resolveNvmeTempThresholds(ds.nvme.wctemp_c, ds.nvme.cctemp_c, self.ssd_caution_c, self.ssd_warning_c)
                            else
                                .{ .caution = @floatFromInt(self.hdd_caution_c), .warning = @floatFromInt(self.hdd_warning_c) };
                            var lbl_buf: [64]u8 = undefined;
                            const lbl = std.fmt.bufPrint(&lbl_buf, "Disk {d}", .{ds.device.drive_index}) catch "Disk";
                            _ = self.alerts.evaluateTemperature(ds.device.stable_id.slice(), lbl, @floatFromInt(tc), thr.caution, thr.warning, now_utc_ms);
                        }
                    }
                    if (self.alerts.takePendingNotification()) |ev| {
                        self.pending_notification = ev;
                        if (repo_opt) |*r| {
                            r.insertAlert(ev.ruleIdSlice(), ev.deviceIdSlice(), @intFromEnum(ev.level), ev.messageSlice(), ev.timestamp_utc_ms) catch {};
                        }
                    }
                    self.syncAlertsLocked();
                    self.mutex.unlock();
                } else if (now_ns - last_disk_temp_ns >= 10 * std.time.ns_per_s and cached_inv.count > 0) {
                    const t0 = nvme_smart.readStorageTemperature(cached_inv.disks[0].drive_index);
                    if (t0.available and t0.temp_c != null) {
                        acc_disk_temp.add(@floatFromInt(t0.temp_c.?));
                        self.mutex.lock();
                        if (self.shared.disk_count > 0) {
                            self.shared.disk_states[0].temp_desc = t0;
                            self.shared.disk_states[0].device.temperature_c = t0.temp_c;
                            self.shared.disk0_temp_history.push(elapsed_s, @floatFromInt(t0.temp_c.?));
                            self.shared.sample_seq += 1;
                            self.latest_seq_atomic.store(self.shared.sample_seq, .release);
                        }
                        self.mutex.unlock();
                    }
                    last_disk_temp_ns = now_ns;
                }

                // 2. 系统 CPU / 内存采集 + GPU 温度与运行参数采集 + 可选 LHM 扩展组件采集 + 告警与 1 分钟聚合
                const snap = provider.collect();
                const gpu_snap = gpu_prov.collect();
                ext_client.enabled = self.extension_enabled.load(.acquire);
                const ext_snap = ext_client.poll();

                if (snap.cpu_usage_pct) |cpu| acc_cpu.add(cpu);
                if (snap.mem_load_pct) |mem| acc_mem.add(mem);
                if (gpu_snap.count > 0) {
                    if (gpu_snap.gpus[0].temp_c) |gt| acc_gpu_temp.add(gt);
                }

                self.mutex.lock();
                self.shared.system = snap;
                self.shared.has_system_sample = true;
                self.shared.gpu = gpu_snap;
                self.shared.has_gpu_sample = true;
                self.shared.extension = ext_snap;
                self.shared.sample_seq += 1;
                if (snap.cpu_usage_pct) |cpu| {
                    self.shared.cpu_usage_history.push(elapsed_s, cpu);
                    self.shared.sensor_stats.record("CPU", "cpu.usage", "%", cpu);
                }
                if (snap.cpu_clock_mhz) |clk| {
                    self.shared.sensor_stats.record("CPU", "cpu.clock", "MHz", clk);
                }
                if (ext_snap.connected) {
                    if (ext_snap.cpu_package_temp_c) |ct| {
                        self.shared.cpu_temp_history.push(elapsed_s, ct);
                        self.shared.sensor_stats.record("CPU", "cpu.pkg_temp", "C", ct);
                        _ = self.alerts.evaluateTemperature("cpu0", "CPU Package", ct, self.cpu_caution_c, self.cpu_warning_c, now_utc_ms);
                    }
                    if (ext_snap.cpu_package_power_w) |pw| {
                        self.shared.sensor_stats.record("CPU", "cpu.pkg_power", "W", pw);
                    }
                    for (ext_snap.sensors[0..ext_snap.sensor_count]) |es| {
                        self.shared.sensor_stats.record("cat:ext", es.nameSlice(), es.unitSlice(), es.value);
                    }
                }
                if (snap.mem_load_pct) |mem| {
                    self.shared.mem_usage_history.push(elapsed_s, mem);
                    self.shared.sensor_stats.record("cat:memory", "mem.usage", "%", mem);
                }
                if (snap.disk_read_mbs) |dr| self.shared.sensor_stats.record("cat:storage_io", "io.read", "MB/s", dr);
                if (snap.disk_write_mbs) |dw| self.shared.sensor_stats.record("cat:storage_io", "io.write", "MB/s", dw);
                if (snap.disk_iops) |di| self.shared.sensor_stats.record("cat:storage_io", "io.iops", "IOPS", di);
                if (snap.battery.has_battery) {
                    if (snap.battery.charge_pct) |bp| {
                        self.shared.sensor_stats.record("cat:power", "power.battery", "%", @floatFromInt(bp));
                    }
                }
                for (self.shared.disk_states[0..self.shared.disk_count]) |ds| {
                    if (ds.effectiveTempC()) |tc| {
                        var dn_buf: [64]u8 = undefined;
                        const dn = std.fmt.bufPrint(&dn_buf, "disk.temp.{d}", .{ds.device.drive_index}) catch "disk.temp.0";
                        self.shared.sensor_stats.record("cat:disk", dn, "C", @floatFromInt(tc));
                    }
                }
                if (gpu_snap.count > 0) {
                    if (gpu_snap.gpus[0].temp_c) |gt| {
                        self.shared.gpu_temp_history.push(elapsed_s, gt);
                        self.shared.sensor_stats.record("GPU", "gpu.temp", "C", gt);
                        _ = self.alerts.evaluateTemperature("gpu0", gpu_snap.gpus[0].nameSlice(), gt, self.gpu_caution_c, self.gpu_warning_c, now_utc_ms);
                    }
                    if (gpu_snap.gpus[0].power_watts) |gp| {
                        self.shared.gpu_power_history.push(elapsed_s, gp);
                        self.shared.sensor_stats.record("GPU", "gpu.power", "W", gp);
                    }
                    if (gpu_snap.gpus[0].usage_pct) |gu| self.shared.sensor_stats.record("GPU", "gpu.usage", "%", gu);
                    if (gpu_snap.gpus[0].fan_rpm) |fr| self.shared.sensor_stats.record("GPU", "gpu.fan", "RPM", @floatFromInt(fr));
                }
                if (self.alerts.takePendingNotification()) |ev| {
                    self.pending_notification = ev;
                    if (repo_opt) |*r| {
                        r.insertAlert(ev.ruleIdSlice(), ev.deviceIdSlice(), @intFromEnum(ev.level), ev.messageSlice(), ev.timestamp_utc_ms) catch {};
                    }
                }
                self.syncAlertsLocked();
                self.latest_seq_atomic.store(self.shared.sample_seq, .release);
                self.mutex.unlock();

                // 3. P6/V2.2: 落盘待保存的基准测试历史 + 每 60 秒批量事务写入 1 分钟聚合数据至 SQLite
                if (repo_opt) |*r| {
                    var save_rec: ?repository.BenchmarkHistoryRecord = null;
                    self.mutex.lock();
                    save_rec = self.pending_bench_save;
                    self.pending_bench_save = null;
                    self.mutex.unlock();
                    if (save_rec) |rec| {
                        r.insertBenchmarkHistory(
                            rec.timestamp_utc_ms,
                            rec.testKindSlice(),
                            rec.outcomeSlice(),
                            rec.duration_s,
                            rec.error_count,
                            rec.peak_temp_c,
                            rec.primarySlice(),
                            rec.secondarySlice(),
                        ) catch {};
                    }
                    if (now_utc_ms - last_flush_ms >= 60_000) {
                        const bucket = @divTrunc(now_utc_ms, 60_000) * 60_000;
                        var batch: [4]repository.Repository.Telemetry1mRow = undefined;
                        var bcnt: usize = 0;
                        if (acc_cpu.count > 0) {
                            batch[bcnt] = .{ .sensor_id = "cpu:usage", .bucket_utc_ms = bucket, .min_val = acc_cpu.min_v, .avg_val = acc_cpu.avg(), .max_val = acc_cpu.max_v, .sample_count = acc_cpu.count };
                            bcnt += 1;
                            acc_cpu.reset();
                        }
                        if (acc_mem.count > 0) {
                            batch[bcnt] = .{ .sensor_id = "mem:usage", .bucket_utc_ms = bucket, .min_val = acc_mem.min_v, .avg_val = acc_mem.avg(), .max_val = acc_mem.max_v, .sample_count = acc_mem.count };
                            bcnt += 1;
                            acc_mem.reset();
                        }
                        if (acc_gpu_temp.count > 0) {
                            batch[bcnt] = .{ .sensor_id = "gpu0:temp", .bucket_utc_ms = bucket, .min_val = acc_gpu_temp.min_v, .avg_val = acc_gpu_temp.avg(), .max_val = acc_gpu_temp.max_v, .sample_count = acc_gpu_temp.count };
                            bcnt += 1;
                            acc_gpu_temp.reset();
                        }
                        if (acc_disk_temp.count > 0) {
                            batch[bcnt] = .{ .sensor_id = "disk0:temp", .bucket_utc_ms = bucket, .min_val = acc_disk_temp.min_v, .avg_val = acc_disk_temp.avg(), .max_val = acc_disk_temp.max_v, .sample_count = acc_disk_temp.count };
                            bcnt += 1;
                            acc_disk_temp.reset();
                        }
                        if (bcnt > 0) {
                            r.insertTelemetry1mBatch(batch[0..bcnt]) catch {};
                            self.mutex.lock();
                            self.shared.db_flush_count += 1;
                            self.mutex.unlock();
                        }
                        last_flush_ms = now_utc_ms;
                    }

                    // 每 15 分钟后台执行一次降采样与过期清理
                    if (now_utc_ms - last_prune_ms >= 900_000) {
                        r.downsampleAndPrune(now_utc_ms, self.retain_1m_days, self.retain_15m_days, self.retain_smart_days) catch {};
                        last_prune_ms = now_utc_ms;
                    }
                }
            }

            const wait_ms = self.interval_ms.load(.acquire);
            sleepInterruptible(&self.stop_flag, &self.rescan_disks_flag, wait_ms);
        }
    }
};

fn sleepInterruptible(stop_flag: *std.atomic.Value(bool), wake_flag: *std.atomic.Value(bool), total_ms: u32) void {
    var remaining: u32 = total_ms;
    while (remaining > 0 and !stop_flag.load(.acquire) and !wake_flag.load(.acquire)) {
        const chunk: u32 = @min(remaining, 100);
        std.Thread.sleep(@as(u64, chunk) * std.time.ns_per_ms);
        remaining -= chunk;
    }
}
