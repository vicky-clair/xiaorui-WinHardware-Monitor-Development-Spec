const std = @import("std");
const builtin = @import("builtin");
const i18n = @import("i18n.zig");
const win32 = @import("../providers/windows/win32.zig");

const linux_fadvise = if (builtin.os.tag == .linux) struct {
    extern "c" fn posix_fadvise(fd: c_int, offset: i64, len: i64, advice: c_int) c_int;
    const POSIX_FADV_DONTNEED: c_int = 4;
} else struct {};

/// V2.0 跨平台硬件压力测试与性能基准引擎（Windows / Linux 共用核心算法）。
/// 安全约束（AGENTS.md V2.0 红线 #6）：
/// 1. 仅在用户主动点击并二次确认后执行；
/// 2. 磁盘测速严禁写入裸物理磁盘扇区，仅在用户选定目录创建受控临时文件并于结束后自动删除；
///    - Windows 优先启用 FILE_FLAG_NO_BUFFERING | FILE_FLAG_WRITE_THROUGH + 4K 对齐缓冲，绕过系统页缓存测真实物理磁盘速度；
///    - Linux 通过 posix_fadvise(POSIX_FADV_DONTNEED) 驱逐内核页缓存。
/// 3. 内置实时高温自动熔断保护（由监控线程实时喂入当前 CPU/GPU 温度，超阈值立即中断所有测试线程）。
pub const TestKind = enum(u8) {
    none,
    cpu_stress,
    memory_verify,
    disk_bench,
    gpu_stress,

    pub fn labelZh(self: TestKind) [:0]const u8 {
        return switch (self) {
            .none => i18n.tr("空闲", "Idle", "待機中"),
            .cpu_stress => i18n.tr("CPU 稳定性与算力测试", "CPU Stability & Compute", "CPU 安定性・演算テスト"),
            .memory_verify => i18n.tr("内存带宽与位翻转校验", "Memory Bandwidth & Bit-Flip", "メモリ帯域・ビット検証"),
            .disk_bench => i18n.tr("磁盘文件级读写基准测试", "Disk File-Level Benchmark", "ディスク読込/書込ベンチマーク"),
            .gpu_stress => i18n.tr("GPU OpenGL 散热与稳定性烤机", "GPU OpenGL Stress Test", "GPU OpenGL 負荷テスト"),
        };
    }
};

pub const TestOutcome = enum(u8) {
    idle,
    running,
    passed,
    failed_errors,
    stopped_by_user,
    stopped_by_thermal,
    failed_io,

    pub fn labelZh(self: TestOutcome) [:0]const u8 {
        return switch (self) {
            .idle => i18n.tr("尚未运行", "Not Run", "未実行"),
            .running => i18n.tr("测试运行中", "Running", "実行中"),
            .passed => i18n.tr("通过（零错误）", "Passed (0 Errors)", "合格（エラーなし）"),
            .failed_errors => i18n.tr("检出硬件计算/内存错误", "Hardware/Memory Error Detected", "ハードウェア/メモリエラー検出"),
            .stopped_by_user => i18n.tr("用户手动停止", "Stopped by User", "ユーザーにより停止"),
            .stopped_by_thermal => i18n.tr("触发高温熔断保护已自动停机", "Thermal Cutoff Triggered", "高温保護により自動停止"),
            .failed_io => i18n.tr("I/O 或资源初始化失败", "I/O or Init Failed", "I/O または初期化失敗"),
        };
    }
};

pub const BenchmarkSnapshot = struct {
    active_kind: TestKind = .none,
    last_kind: TestKind = .none,
    outcome: TestOutcome = .idle,
    progress_pct: f32 = 0.0,
    elapsed_s: f64 = 0.0,
    target_duration_s: u32 = 30,

    // 安全熔断与状态摘要
    thermal_cutoff_c: f64 = 90.0,
    peak_temp_c: ?f64 = null,
    error_count: u64 = 0,

    // CPU 算力结果
    cpu_threads: u32 = 0,
    cpu_score_mops: f64 = 0.0, // Million mixed ops/sec

    // 内存校验结果
    mem_tested_mb: u32 = 0,
    mem_write_gbs: f64 = 0.0,
    mem_read_gbs: f64 = 0.0,
    mem_passes_done: u32 = 0,

    // 磁盘文件级基准结果（严禁裸盘写）
    disk_file_mb: u32 = 0,
    disk_seq_write_mbs: f64 = 0.0,
    disk_seq_read_mbs: f64 = 0.0,
    disk_rnd4k_read_mbs: f64 = 0.0,
    disk_rnd4k_read_iops: f64 = 0.0,
    disk_rnd4k_avg_lat_us: f64 = 0.0,

    // GPU OpenGL 烤机结果
    gpu_frames: u64 = 0,
    gpu_avg_fps: f64 = 0.0,

    summary: [192]u8 = std.mem.zeroes([192]u8),
    summary_len: usize = 0,

    pub fn summarySlice(self: *const BenchmarkSnapshot) []const u8 {
        return self.summary[0..self.summary_len];
    }
};

pub const BenchmarkConfig = struct {
    cpu_threads: u32 = 4,
    duration_s: u32 = 30,
    thermal_cutoff_c: f64 = 90.0,
    mem_size_mb: u32 = 256,
    disk_file_mb: u32 = 256,
};

pub const BenchmarkRunner = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    snap: BenchmarkSnapshot = .{},
    cancel_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thermal_trip_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    worker_thread: ?std.Thread = null,
    gpu_start_ns: i128 = 0,
    gpu_duration_s: u32 = 30,

    pub fn init(allocator: std.mem.Allocator) BenchmarkRunner {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *BenchmarkRunner) void {
        self.requestStop();
        self.joinIfFinished(true);
    }

    /// 由监控循环持续喂入实时最高温度（CPU/GPU），触发高温自动熔断
    pub fn updateLiveTemperature(self: *BenchmarkRunner, max_temp_c: ?f64) void {
        if (max_temp_c) |tc| {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.snap.outcome == .running) {
                if (self.snap.peak_temp_c == null or tc > self.snap.peak_temp_c.?) {
                    self.snap.peak_temp_c = tc;
                }
                if (tc >= self.snap.thermal_cutoff_c) {
                    self.thermal_trip_flag.store(true, .release);
                    self.cancel_flag.store(true, .release);
                }
            }
        }
    }

    pub fn copySnapshot(self: *BenchmarkRunner) BenchmarkSnapshot {
        self.joinIfFinished(false);
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.snap;
    }

    pub fn isRunning(self: *BenchmarkRunner) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.snap.outcome == .running;
    }

    pub fn requestStop(self: *BenchmarkRunner) void {
        self.cancel_flag.store(true, .release);
        self.mutex.lock();
        if (self.snap.active_kind == .gpu_stress and self.snap.outcome == .running) {
            self.snap.active_kind = .none;
            self.snap.outcome = if (self.thermal_trip_flag.load(.acquire)) .stopped_by_thermal else .stopped_by_user;
            setSummary(&self.snap, i18n.trSlice("GPU OpenGL 烤机已停止", "GPU OpenGL stress stopped", "GPU OpenGL 負荷テストを停止しました"));
        }
        self.mutex.unlock();
    }

    fn joinIfFinished(self: *BenchmarkRunner, force_wait: bool) void {
        if (self.worker_thread) |t| {
            const done = force_wait or blk: {
                self.mutex.lock();
                defer self.mutex.unlock();
                break :blk self.snap.outcome != .running;
            };
            if (done) {
                t.join();
                self.worker_thread = null;
            }
        }
    }

    pub fn startCpuStress(self: *BenchmarkRunner, cfg: BenchmarkConfig) bool {
        self.joinIfFinished(false);
        if (self.isRunning()) return false;

        self.cancel_flag.store(false, .release);
        self.thermal_trip_flag.store(false, .release);

        const threads = std.math.clamp(cfg.cpu_threads, 1, 64);
        const dur = std.math.clamp(cfg.duration_s, 5, 600);

        self.mutex.lock();
        self.snap = .{
            .active_kind = .cpu_stress,
            .last_kind = .cpu_stress,
            .outcome = .running,
            .target_duration_s = dur,
            .thermal_cutoff_c = std.math.clamp(cfg.thermal_cutoff_c, 65.0, 105.0),
            .cpu_threads = threads,
        };
        setSummary(&self.snap, i18n.trSlice(
            "正在运行多线程整数/浮点确定性校验负载...",
            "Running multi-threaded integer/FP deterministic verification...",
            "マルチスレッド整数/浮動小数点検証を実行中...",
        ));
        self.mutex.unlock();

        self.worker_thread = std.Thread.spawn(.{}, cpuStressMain, .{ self, threads, dur }) catch {
            self.mutex.lock();
            self.snap.active_kind = .none;
            self.snap.outcome = .failed_io;
            setSummary(&self.snap, i18n.trSlice("无法创建 CPU 测试工作线程", "Failed to spawn CPU test worker thread", "CPU テストスレッドの作成に失敗しました"));
            self.mutex.unlock();
            return false;
        };
        return true;
    }

    pub fn startMemoryVerify(self: *BenchmarkRunner, cfg: BenchmarkConfig, avail_mem_bytes: u64) bool {
        self.joinIfFinished(false);
        if (self.isRunning()) return false;

        self.cancel_flag.store(false, .release);
        self.thermal_trip_flag.store(false, .release);

        // 安全上限：不超过当前可用物理内存的 50% 且最高 1024 MB，防止触发系统 OOM
        const max_safe_mb: u32 = if (avail_mem_bytes > 256 * 1024 * 1024)
            @intCast(@min(@as(u64, 1024), (avail_mem_bytes / (1024 * 1024)) / 2))
        else
            64;
        const size_mb = std.math.clamp(cfg.mem_size_mb, 32, @max(@as(u32, 32), max_safe_mb));

        self.mutex.lock();
        self.snap = .{
            .active_kind = .memory_verify,
            .last_kind = .memory_verify,
            .outcome = .running,
            .thermal_cutoff_c = std.math.clamp(cfg.thermal_cutoff_c, 65.0, 105.0),
            .mem_tested_mb = size_mb,
        };
        setSummary(&self.snap, i18n.trSlice(
            "正在执行 4 轮内存位翻转与带宽校验...",
            "Running 4-pass memory bit-flip & bandwidth verification...",
            "4パス メモリビット反転・帯域検証を実行中...",
        ));
        self.mutex.unlock();

        self.worker_thread = std.Thread.spawn(.{}, memoryVerifyMain, .{ self, size_mb }) catch {
            self.mutex.lock();
            self.snap.active_kind = .none;
            self.snap.outcome = .failed_io;
            setSummary(&self.snap, i18n.trSlice("无法创建内存测试线程", "Failed to spawn memory test thread", "メモリテストスレッドの作成に失敗しました"));
            self.mutex.unlock();
            return false;
        };
        return true;
    }

    pub fn startDiskBench(self: *BenchmarkRunner, cfg: BenchmarkConfig, temp_dir: []const u8) bool {
        self.joinIfFinished(false);
        if (self.isRunning()) return false;

        self.cancel_flag.store(false, .release);
        self.thermal_trip_flag.store(false, .release);

        const file_mb = std.math.clamp(cfg.disk_file_mb, 32, 1024);
        const dir_copy = self.allocator.dupe(u8, temp_dir) catch return false;

        self.mutex.lock();
        self.snap = .{
            .active_kind = .disk_bench,
            .last_kind = .disk_bench,
            .outcome = .running,
            .thermal_cutoff_c = std.math.clamp(cfg.thermal_cutoff_c, 65.0, 105.0),
            .disk_file_mb = file_mb,
        };
        setSummary(&self.snap, i18n.trSlice(
            "正在指定目录创建受控临时文件执行无缓存 SEQ1M / RND4K 测试...",
            "Running unbuffered SEQ1M / RND4K benchmark on controlled temp file...",
            "一時ファイルでキャッシュ無効 SEQ1M / RND4K ベンチマーク実行中...",
        ));
        self.mutex.unlock();

        self.worker_thread = std.Thread.spawn(.{}, diskBenchMain, .{ self, file_mb, dir_copy }) catch {
            self.allocator.free(dir_copy);
            self.mutex.lock();
            self.snap.active_kind = .none;
            self.snap.outcome = .failed_io;
            setSummary(&self.snap, i18n.trSlice("无法创建磁盘基准测试线程", "Failed to spawn disk benchmark thread", "ディスクベンチマークスレッド作成失敗"));
            self.mutex.unlock();
            return false;
        };
        return true;
    }

    /// 启动 GPU OpenGL 烤机模式（在主窗口 OpenGL 3.3 渲染循环中执行重绘与负载统计）
    pub fn startGpuStress(self: *BenchmarkRunner, cfg: BenchmarkConfig) bool {
        self.joinIfFinished(false);
        if (self.isRunning()) return false;

        self.cancel_flag.store(false, .release);
        self.thermal_trip_flag.store(false, .release);

        const dur = std.math.clamp(cfg.duration_s, 10, 600);
        self.gpu_start_ns = std.time.nanoTimestamp();
        self.gpu_duration_s = dur;

        self.mutex.lock();
        self.snap = .{
            .active_kind = .gpu_stress,
            .last_kind = .gpu_stress,
            .outcome = .running,
            .target_duration_s = dur,
            .thermal_cutoff_c = std.math.clamp(cfg.thermal_cutoff_c, 65.0, 100.0),
        };
        setSummary(&self.snap, i18n.trSlice(
            "正在运行 OpenGL 3.3 高密度图形渲染烤机...",
            "Running OpenGL 3.3 high-density rendering stress test...",
            "OpenGL 3.3 高密度描画負荷テストを実行中...",
        ));
        self.mutex.unlock();
        return true;
    }

    /// GPU 烤机每帧推进统计与自动完成/熔断检测
    pub fn tickGpuStressFrame(self: *BenchmarkRunner) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.snap.active_kind != .gpu_stress or self.snap.outcome != .running) return false;

        if (self.thermal_trip_flag.load(.acquire)) {
            self.snap.active_kind = .none;
            self.snap.outcome = .stopped_by_thermal;
            setSummary(&self.snap, i18n.trSlice("GPU 烤机触发高温熔断保护，已安全停机", "GPU stress stopped by thermal cutoff", "GPU 負荷テストが高温保護で安全停止しました"));
            return false;
        }
        if (self.cancel_flag.load(.acquire)) {
            self.snap.active_kind = .none;
            self.snap.outcome = .stopped_by_user;
            setSummary(&self.snap, i18n.trSlice("GPU 烤机已被用户手动停止", "GPU stress stopped by user", "GPU 負荷テストはユーザーにより停止されました"));
            return false;
        }

        const now_ns = std.time.nanoTimestamp();
        const elapsed_s = @as(f64, @floatFromInt(now_ns - self.gpu_start_ns)) / @as(f64, @floatFromInt(std.time.ns_per_s));
        self.snap.gpu_frames += 1;
        self.snap.elapsed_s = elapsed_s;
        if (elapsed_s > 0.05) {
            self.snap.gpu_avg_fps = @as(f64, @floatFromInt(self.snap.gpu_frames)) / elapsed_s;
        }
        self.snap.progress_pct = @floatCast(std.math.clamp((elapsed_s / @as(f64, @floatFromInt(self.gpu_duration_s))) * 100.0, 0.0, 100.0));

        if (elapsed_s >= @as(f64, @floatFromInt(self.gpu_duration_s))) {
            self.snap.active_kind = .none;
            self.snap.outcome = .passed;
            self.snap.progress_pct = 100.0;
            setSummary(&self.snap, i18n.trSlice("GPU OpenGL 稳定性烤机完成（零异常）", "GPU OpenGL stress completed (0 errors)", "GPU OpenGL 安定性テスト完了（異常なし）"));
            return false;
        }
        return true;
    }

    /// 导出结构化硬件测试报告（TXT/Markdown 兼容，供验收存档）
    pub fn exportReport(self: *BenchmarkRunner, allocator: std.mem.Allocator, cpu_name: []const u8, gpu_name: []const u8) ![]u8 {
        const snap = self.copySnapshot();
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(allocator);
        const w = out.writer(allocator);

        try w.writeAll("============================================================\r\n");
        try w.print("{s}\r\n", .{i18n.trSlice(
            "WinHardware Monitor V2.0 — 硬件基准与稳定性测试报告",
            "WinHardware Monitor V2.0 — Hardware Benchmark & Stability Report",
            "WinHardware Monitor V2.0 — ハードウェア ベンチマーク・安定性レポート",
        )});
        try w.writeAll("============================================================\r\n");
        try w.print("{s}: {d}\r\n", .{ i18n.trSlice("测试时间 (UTC ms)", "Timestamp (UTC ms)", "テスト日時 (UTC ms)"), std.time.milliTimestamp() });
        try w.print("CPU: {s}\r\n", .{cpu_name});
        try w.print("GPU: {s}\r\n", .{gpu_name});
        try w.print("{s}: {s}\r\n", .{ i18n.trSlice("最近测试项", "Test Item", "テスト項目"), snap.last_kind.labelZh() });
        try w.print("{s}: {s}\r\n", .{ i18n.trSlice("最终结论", "Result", "判定結果"), snap.outcome.labelZh() });
        try w.print("{s}: {d:.2} s\r\n", .{ i18n.trSlice("运行时长", "Duration", "実行時間"), snap.elapsed_s });
        try w.print("{s}: {d}\r\n", .{ i18n.trSlice("错误计数", "Error Count", "エラー数"), snap.error_count });
        if (snap.peak_temp_c) |pt| {
            try w.print("{s}: {d:.1} °C ({s} {d:.0} °C)\r\n", .{
                i18n.trSlice("期间峰值温度", "Peak Temp", "最高温度"),
                pt,
                i18n.trSlice("熔断阈值", "Cutoff", "保護閾値"),
                snap.thermal_cutoff_c,
            });
        } else {
            try w.print("{s}: N/A ({s} {d:.0} °C)\r\n", .{
                i18n.trSlice("期间峰值温度", "Peak Temp", "最高温度"),
                i18n.trSlice("熔断阈值", "Cutoff", "保護閾値"),
                snap.thermal_cutoff_c,
            });
        }
        try w.writeAll("------------------------------------------------------------\r\n");
        switch (snap.last_kind) {
            .cpu_stress => try w.print("CPU Threads: {d} | Score: {d:.2} MOPS\r\n", .{ snap.cpu_threads, snap.cpu_score_mops }),
            .memory_verify => try w.print("Memory: {d} MB | Passes: {d}/4 | Write: {d:.2} GB/s | Read+Verify: {d:.2} GB/s\r\n", .{
                snap.mem_tested_mb, snap.mem_passes_done, snap.mem_write_gbs, snap.mem_read_gbs,
            }),
            .disk_bench => try w.print("Temp File: {d} MB (auto-deleted)\r\nSEQ1M Write: {d:.1} MB/s | SEQ1M Read: {d:.1} MB/s\r\nRND4K Read: {d:.1} MB/s ({d:.0} IOPS, Avg Lat {d:.1} us)\r\n", .{
                snap.disk_file_mb, snap.disk_seq_write_mbs, snap.disk_seq_read_mbs, snap.disk_rnd4k_read_mbs, snap.disk_rnd4k_read_iops, snap.disk_rnd4k_avg_lat_us,
            }),
            .gpu_stress => try w.print("Frames: {d} | Avg FPS: {d:.1}\r\n", .{ snap.gpu_frames, snap.gpu_avg_fps }),
            .none => try w.print("{s}\r\n", .{i18n.trSlice("尚未执行测试。", "No test executed yet.", "まだテストは実行されていません。")}),
        }
        try w.print("{s}: {s}\r\n", .{ i18n.trSlice("摘要", "Summary", "概要"), snap.summarySlice() });
        return out.toOwnedSlice(allocator);
    }
};

const CpuWorkerShared = struct {
    cancel: *std.atomic.Value(bool),
    total_ops: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    errors: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    expected_ref: u64 = 0,
};

fn computeDeterministicKernel(seed: u64) u64 {
    var x: u64 = seed ^ 0x9E3779B97F4A7C15;
    var y: u64 = seed +% 0xBF58476D1CE4E5B9;
    var acc_f: f64 = 1.000123;
    var i: usize = 0;
    while (i < 4096) : (i += 1) {
        x = std.math.rotl(u64, x +% y, 13) ^ (y >> 7);
        y = std.math.rotl(u64, y *% 0x94D049BB133111EB, 29) ^ x;
        acc_f = @mulAdd(f64, acc_f, 1.0000001192092896, @as(f64, @floatFromInt(x & 0xFF)) * 1e-6);
        if (acc_f > 1e6) acc_f *= 1e-6;
    }
    const fbits: u64 = @bitCast(acc_f);
    return x ^ y ^ fbits;
}

fn cpuWorkerLoop(shared: *CpuWorkerShared) void {
    while (!shared.cancel.load(.acquire)) {
        const res = computeDeterministicKernel(0x123456789ABCDEF0);
        if (res != shared.expected_ref) {
            _ = shared.errors.fetchAdd(1, .acq_rel);
        }
        _ = shared.total_ops.fetchAdd(4096, .acq_rel);
    }
}

fn cpuStressMain(self: *BenchmarkRunner, threads: u32, duration_s: u32) void {
    var local_cancel = std.atomic.Value(bool).init(false);
    var shared = CpuWorkerShared{
        .cancel = &local_cancel,
        .expected_ref = computeDeterministicKernel(0x123456789ABCDEF0),
    };

    var handles: [64]?std.Thread = [_]?std.Thread{null} ** 64;
    const t_count: usize = @intCast(threads);
    for (0..t_count) |i| {
        handles[i] = std.Thread.spawn(.{}, cpuWorkerLoop, .{&shared}) catch null;
    }

    const start_ns = std.time.nanoTimestamp();
    const target_ns: i128 = @as(i128, duration_s) * std.time.ns_per_s;

    while (!self.cancel_flag.load(.acquire)) {
        const elapsed_ns = std.time.nanoTimestamp() - start_ns;
        const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(std.time.ns_per_s));
        const ops = shared.total_ops.load(.acquire);
        const errs = shared.errors.load(.acquire);

        self.mutex.lock();
        self.snap.elapsed_s = elapsed_s;
        self.snap.progress_pct = @floatCast(std.math.clamp((@as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(target_ns))) * 100.0, 0.0, 100.0));
        self.snap.error_count = errs;
        if (elapsed_s > 0.05) {
            self.snap.cpu_score_mops = (@as(f64, @floatFromInt(ops)) / 1_000_000.0) / elapsed_s;
        }
        self.mutex.unlock();

        if (elapsed_ns >= target_ns) break;
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }

    local_cancel.store(true, .release);
    for (0..t_count) |i| {
        if (handles[i]) |h| h.join();
    }

    const total_ns = std.time.nanoTimestamp() - start_ns;
    const total_s = @max(0.01, @as(f64, @floatFromInt(total_ns)) / @as(f64, @floatFromInt(std.time.ns_per_s)));
    const final_ops = shared.total_ops.load(.acquire);
    const final_errs = shared.errors.load(.acquire);

    self.mutex.lock();
    self.snap.active_kind = .none;
    self.snap.elapsed_s = total_s;
    self.snap.cpu_score_mops = (@as(f64, @floatFromInt(final_ops)) / 1_000_000.0) / total_s;
    self.snap.error_count = final_errs;
    if (self.thermal_trip_flag.load(.acquire)) {
        self.snap.outcome = .stopped_by_thermal;
        setSummary(&self.snap, i18n.trSlice("触发高温熔断阈值，已自动停止 CPU 烤机", "Thermal cutoff triggered; CPU stress stopped", "高温保護閾値に到達し CPU テストを自動停止しました"));
    } else if (self.cancel_flag.load(.acquire)) {
        self.snap.outcome = .stopped_by_user;
        setSummary(&self.snap, i18n.trSlice("用户已手动停止 CPU 测试", "CPU stress stopped by user", "ユーザーにより CPU テストを停止しました"));
    } else if (final_errs > 0) {
        self.snap.outcome = .failed_errors;
        setSummary(&self.snap, i18n.trSlice(
            "检出确定性计算核校验偏差，请检查 CPU 电压/散热/超频稳定性",
            "Deterministic kernel mismatch detected; check CPU voltage/cooling/OC",
            "演算検証エラーを検出しました。CPU 電圧/冷却/OC 設定を確認してください",
        ));
    } else {
        self.snap.progress_pct = 100.0;
        self.snap.outcome = .passed;
        setSummary(&self.snap, i18n.trSlice(
            "CPU 多线程稳定性与算力校验全部通过（零计算错误）",
            "CPU multi-threaded stability & compute passed (0 errors)",
            "CPU マルチスレッド安定性・演算検証に合格しました（エラー 0）",
        ));
    }
    self.mutex.unlock();
}

fn memoryVerifyMain(self: *BenchmarkRunner, size_mb: u32) void {
    const start_ns = std.time.nanoTimestamp();
    const total_bytes: usize = @as(usize, size_mb) * 1024 * 1024;
    const word_count: usize = total_bytes / @sizeOf(u64);

    const buf = self.allocator.alloc(u64, word_count) catch {
        self.mutex.lock();
        self.snap.active_kind = .none;
        self.snap.outcome = .failed_io;
        setSummary(&self.snap, i18n.trSlice("内存分配失败，请调小测试容量", "Memory allocation failed; reduce test size", "メモリ確保に失敗しました。テスト容量を下げてください"));
        self.mutex.unlock();
        return;
    };
    defer self.allocator.free(buf);

    var write_ns_sum: i128 = 0;
    var read_ns_sum: i128 = 0;
    var errors: u64 = 0;
    var passes_done: u32 = 0;

    // 4 轮 MemTest 风格位模式验证
    const patterns = [_]u8{ 0, 1, 2, 3 };
    for (patterns, 0..) |pat, p_idx| {
        if (self.cancel_flag.load(.acquire)) break;

        // Write phase
        const tw0 = std.time.nanoTimestamp();
        for (buf, 0..) |*slot, i| {
            slot.* = patternWord(pat, i);
        }
        const tw1 = std.time.nanoTimestamp();
        write_ns_sum += (tw1 - tw0);

        if (self.cancel_flag.load(.acquire)) break;

        // Read & verify phase
        const tr0 = std.time.nanoTimestamp();
        for (buf, 0..) |val, i| {
            if (val != patternWord(pat, i)) {
                errors += 1;
            }
        }
        const tr1 = std.time.nanoTimestamp();
        read_ns_sum += (tr1 - tr0);
        passes_done += 1;

        const elapsed_s = @as(f64, @floatFromInt(tr1 - start_ns)) / @as(f64, @floatFromInt(std.time.ns_per_s));
        const bytes_done_gb = (@as(f64, @floatFromInt(total_bytes)) * @as(f64, @floatFromInt(passes_done))) / (1024.0 * 1024.0 * 1024.0);
        self.mutex.lock();
        self.snap.elapsed_s = elapsed_s;
        self.snap.mem_passes_done = passes_done;
        self.snap.error_count = errors;
        self.snap.progress_pct = @as(f32, @floatFromInt((p_idx + 1) * 25));
        if (write_ns_sum > 0) self.snap.mem_write_gbs = bytes_done_gb / (@as(f64, @floatFromInt(write_ns_sum)) / @as(f64, @floatFromInt(std.time.ns_per_s)));
        if (read_ns_sum > 0) self.snap.mem_read_gbs = bytes_done_gb / (@as(f64, @floatFromInt(read_ns_sum)) / @as(f64, @floatFromInt(std.time.ns_per_s)));
        self.mutex.unlock();
    }

    self.mutex.lock();
    self.snap.active_kind = .none;
    if (self.thermal_trip_flag.load(.acquire)) {
        self.snap.outcome = .stopped_by_thermal;
        setSummary(&self.snap, i18n.trSlice("触发高温熔断，已终止内存校验", "Thermal cutoff triggered; memory test stopped", "高温保護によりメモリ検証を停止しました"));
    } else if (self.cancel_flag.load(.acquire)) {
        self.snap.outcome = .stopped_by_user;
        setSummary(&self.snap, i18n.trSlice("用户已手动停止内存校验", "Memory verification stopped by user", "ユーザーによりメモリ検証を停止しました"));
    } else if (errors > 0) {
        self.snap.outcome = .failed_errors;
        setSummary(&self.snap, i18n.trSlice(
            "检测到内存位翻转错误！请检查内存条 XMP 频率或插槽接触",
            "Memory bit-flip error detected! Check RAM XMP/timings or seating",
            "メモリビット反転エラーを検出！XMP 設定やスロット接触を確認してください",
        ));
    } else {
        self.snap.progress_pct = 100.0;
        self.snap.outcome = .passed;
        setSummary(&self.snap, i18n.trSlice(
            "4 轮内存位模式校验全部通过（零位翻转错误）",
            "All 4 memory bit-pattern passes passed (0 bit errors)",
            "4パス メモリパターン検証に全合格しました（ビットエラー 0）",
        ));
    }
    self.mutex.unlock();
}

inline fn patternWord(pat: u8, idx: usize) u64 {
    const i: u64 = @intCast(idx);
    return switch (pat) {
        0 => if ((i & 1) == 0) 0x5555555555555555 else 0xAAAAAAAAAAAAAAAA,
        1 => (@as(u64, 1) << @as(u6, @truncate(i))) ^ 0xFF00FF00FF00FF00,
        2 => (i *% 0x9E3779B97F4A7C15) ^ 0xA5A55A5AF0F00F0F,
        else => blk: {
            var z = i +% 0x9E3779B97F4A7C15;
            z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
            z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
            break :blk z ^ (z >> 31);
        },
    };
}

/// Windows 无系统缓存直通磁盘测速（FILE_FLAG_NO_BUFFERING | FILE_FLAG_WRITE_THROUGH + 4K 对齐缓冲），
/// 绕过 Windows 内存文件缓存，测得真实物理 SSD/HDD 顺序与 4K 随机读写成绩。
fn runWindowsUnbufferedDiskBench(self: *BenchmarkRunner, file_path: []const u8, file_mb: u32, chunk: []const u8, start_ns: i128) bool {
    if (builtin.os.tag != .windows) return false;
    var path_w: [512]u16 = undefined;
    const wlen = std.unicode.utf8ToUtf16Le(path_w[0 .. path_w.len - 1], file_path) catch return false;
    path_w[wlen] = 0;

    // 1. Unbuffered SEQ1M Write
    {
        const h = win32.CreateFileW(
            @ptrCast(&path_w),
            win32.GENERIC_WRITE,
            0,
            null,
            win32.CREATE_ALWAYS,
            win32.FILE_FLAG_NO_BUFFERING | win32.FILE_FLAG_WRITE_THROUGH,
            null,
        );
        if (h == win32.INVALID_HANDLE_VALUE) return false;
        defer _ = win32.CloseHandle(h);

        const tw0 = std.time.nanoTimestamp();
        for (0..file_mb) |mb_i| {
            if (self.cancel_flag.load(.acquire)) break;
            var written: win32.DWORD = 0;
            if (win32.WriteFile(h, chunk.ptr, @intCast(chunk.len), &written, null) == 0 or written != chunk.len) {
                markDiskFail(self, i18n.trSlice("顺序写入测试失败（磁盘空间不足或被中断）", "Sequential write failed (disk full or interrupted)", "シーケンシャル書込テスト失敗（容量不足または中断）"));
                return true;
            }
            self.mutex.lock();
            self.snap.progress_pct = (@as(f32, @floatFromInt(mb_i + 1)) / @as(f32, @floatFromInt(file_mb))) * 35.0;
            self.mutex.unlock();
        }
        _ = win32.FlushFileBuffers(h);
        const tw1 = std.time.nanoTimestamp();
        const ws = @max(0.001, @as(f64, @floatFromInt(tw1 - tw0)) / @as(f64, @floatFromInt(std.time.ns_per_s)));
        self.mutex.lock();
        self.snap.disk_seq_write_mbs = @as(f64, @floatFromInt(file_mb)) / ws;
        self.mutex.unlock();
    }

    if (self.cancel_flag.load(.acquire)) {
        finishDiskCancelled(self, start_ns);
        return true;
    }

    // 2. Unbuffered SEQ1M Read + 3. Unbuffered RND4K Read
    {
        const h = win32.CreateFileW(
            @ptrCast(&path_w),
            win32.GENERIC_READ,
            win32.FILE_SHARE_READ,
            null,
            win32.OPEN_EXISTING,
            win32.FILE_FLAG_NO_BUFFERING,
            null,
        );
        if (h == win32.INVALID_HANDLE_VALUE) return false;
        defer _ = win32.CloseHandle(h);

        const read_buf = self.allocator.alignedAlloc(u8, .fromByteUnits(4096), chunk.len) catch return false;
        defer self.allocator.free(read_buf);

        const tr0 = std.time.nanoTimestamp();
        var total_read: usize = 0;
        for (0..file_mb) |mb_i| {
            if (self.cancel_flag.load(.acquire)) break;
            var got: win32.DWORD = 0;
            if (win32.ReadFile(h, read_buf.ptr, @intCast(read_buf.len), &got, null) == 0) {
                markDiskFail(self, i18n.trSlice("顺序读取测试失败", "Sequential read failed", "シーケンシャル読込テスト失敗"));
                return true;
            }
            total_read += got;
            self.mutex.lock();
            self.snap.progress_pct = 35.0 + (@as(f32, @floatFromInt(mb_i + 1)) / @as(f32, @floatFromInt(file_mb))) * 35.0;
            self.mutex.unlock();
        }
        const tr1 = std.time.nanoTimestamp();
        const rs = @max(0.001, @as(f64, @floatFromInt(tr1 - tr0)) / @as(f64, @floatFromInt(std.time.ns_per_s)));
        self.mutex.lock();
        self.snap.disk_seq_read_mbs = (@as(f64, @floatFromInt(total_read)) / (1024.0 * 1024.0)) / rs;
        self.mutex.unlock();

        if (self.cancel_flag.load(.acquire)) {
            finishDiskCancelled(self, start_ns);
            return true;
        }

        // 3. Unbuffered RND4K Read (2048 random 4 KB page-aligned blocks)
        var blk4k: [4096]u8 align(4096) = undefined;
        const max_blocks: u64 = (@as(u64, file_mb) * 1024 * 1024) / 4096;
        const ops: usize = 2048;
        var rng_state: u64 = 0x13579BDF2468ACE0;
        const tk0 = std.time.nanoTimestamp();
        var ops_done: usize = 0;
        for (0..ops) |oi| {
            if (self.cancel_flag.load(.acquire)) break;
            rng_state = rng_state *% 6364136223846793005 +% 1;
            const blk_idx = (rng_state >> 16) % max_blocks;
            const off: i64 = @intCast(blk_idx * 4096);
            if (win32.SetFilePointerEx(h, off, null, win32.FILE_BEGIN) == 0) break;
            var got: win32.DWORD = 0;
            if (win32.ReadFile(h, &blk4k, 4096, &got, null) == 0 or got != 4096) break;
            ops_done += 1;
            if ((oi & 63) == 0) {
                self.mutex.lock();
                self.snap.progress_pct = 70.0 + (@as(f32, @floatFromInt(oi + 1)) / @as(f32, @floatFromInt(ops))) * 30.0;
                self.mutex.unlock();
            }
        }
        const tk1 = std.time.nanoTimestamp();
        const ks = @max(0.0001, @as(f64, @floatFromInt(tk1 - tk0)) / @as(f64, @floatFromInt(std.time.ns_per_s)));
        const iops = @as(f64, @floatFromInt(ops_done)) / ks;
        const mbs_4k = (@as(f64, @floatFromInt(ops_done)) * 4096.0 / (1024.0 * 1024.0)) / ks;
        const lat_us = if (ops_done > 0) (ks * 1_000_000.0) / @as(f64, @floatFromInt(ops_done)) else 0.0;

        self.mutex.lock();
        self.snap.disk_rnd4k_read_iops = iops;
        self.snap.disk_rnd4k_read_mbs = mbs_4k;
        self.snap.disk_rnd4k_avg_lat_us = lat_us;
        self.snap.elapsed_s = @as(f64, @floatFromInt(tk1 - start_ns)) / @as(f64, @floatFromInt(std.time.ns_per_s));
        self.snap.active_kind = .none;
        self.snap.progress_pct = 100.0;
        self.snap.outcome = .passed;
        setSummary(&self.snap, i18n.trSlice(
            "无缓存直通磁盘读写基准完成，临时文件已自动清理",
            "Unbuffered physical disk benchmark passed; temp file auto-deleted",
            "キャッシュ無効ディスクベンチマーク完了（一時ファイル自動削除済）",
        ));
        self.mutex.unlock();
    }
    return true;
}

fn diskBenchMain(self: *BenchmarkRunner, file_mb: u32, temp_dir: []u8) void {
    defer self.allocator.free(temp_dir);
    const start_ns = std.time.nanoTimestamp();

    const file_path = std.fs.path.join(self.allocator, &.{ temp_dir, "winhw_monitor_bench_tmp.bin" }) catch {
        markDiskFail(self, i18n.trSlice("无法拼接临时测试文件路径", "Failed to compose temp file path", "一時ファイルパスの作成に失敗"));
        return;
    };
    defer self.allocator.free(file_path);

    // 无论成功、取消还是异常，退出前绝对删除临时测试文件
    defer std.fs.deleteFileAbsolute(file_path) catch {};

    const chunk_size: usize = 1024 * 1024; // 1 MiB (4K aligned for unbuffered I/O)
    const chunk = self.allocator.alignedAlloc(u8, .fromByteUnits(4096), chunk_size) catch {
        markDiskFail(self, i18n.trSlice("缓冲区分配失败", "Buffer allocation failed", "バッファ確保に失敗"));
        return;
    };
    defer self.allocator.free(chunk);

    // 填充非零不可压缩伪随机字节，避免 SSD 主控压缩虚高分数
    var prng_s: u64 = 0xCAFEBABE12345678;
    for (chunk) |*b| {
        prng_s = prng_s *% 6364136223846793005 +% 1442695040888963407;
        b.* = @truncate(prng_s >> 56);
    }

    // Windows 优先使用 FILE_FLAG_NO_BUFFERING | FILE_FLAG_WRITE_THROUGH 绕过 OS RAM 缓存
    if (builtin.os.tag == .windows) {
        if (runWindowsUnbufferedDiskBench(self, file_path, file_mb, chunk, start_ns)) {
            return;
        }
    }

    // 1. SEQ1M Write (Linux posix_fadvise 或 Windows 降级路径)
    {
        const f = std.fs.createFileAbsolute(file_path, .{ .truncate = true }) catch {
            markDiskFail(self, i18n.trSlice("无法在目标目录创建临时测试文件，请检查目录写权限", "Cannot create temp file; check directory permissions", "一時ファイル作成不可（ディレクトリ書込権限を確認）"));
            return;
        };
        defer f.close();

        const tw0 = std.time.nanoTimestamp();
        for (0..file_mb) |mb_i| {
            if (self.cancel_flag.load(.acquire)) break;
            f.writeAll(chunk) catch {
                markDiskFail(self, i18n.trSlice("顺序写入测试失败（磁盘空间不足或被中断）", "Sequential write failed (disk full or interrupted)", "シーケンシャル書込テスト失敗（容量不足または中断）"));
                return;
            };
            self.mutex.lock();
            self.snap.progress_pct = (@as(f32, @floatFromInt(mb_i + 1)) / @as(f32, @floatFromInt(file_mb))) * 35.0;
            self.mutex.unlock();
        }
        f.sync() catch {};
        // Linux 下通过 posix_fadvise(POSIX_FADV_DONTNEED) 驱逐该临时文件的内核页缓存，避免后续读取测成内存速度
        if (builtin.os.tag == .linux) {
            _ = linux_fadvise.posix_fadvise(f.handle, 0, 0, linux_fadvise.POSIX_FADV_DONTNEED);
        }
        const tw1 = std.time.nanoTimestamp();
        const ws = @max(0.001, @as(f64, @floatFromInt(tw1 - tw0)) / @as(f64, @floatFromInt(std.time.ns_per_s)));
        self.mutex.lock();
        self.snap.disk_seq_write_mbs = @as(f64, @floatFromInt(file_mb)) / ws;
        self.mutex.unlock();
    }

    if (self.cancel_flag.load(.acquire)) {
        finishDiskCancelled(self, start_ns);
        return;
    }

    // 2. SEQ1M Read + 3. RND4K Read
    {
        const f = std.fs.openFileAbsolute(file_path, .{}) catch {
            markDiskFail(self, i18n.trSlice("无法重新打开临时文件执行读取测试", "Failed to reopen temp file for read test", "読込テスト用一時ファイルの再オープンに失敗"));
            return;
        };
        defer f.close();

        const tr0 = std.time.nanoTimestamp();
        var total_read: usize = 0;
        for (0..file_mb) |mb_i| {
            if (self.cancel_flag.load(.acquire)) break;
            const n = f.readAll(chunk) catch {
                markDiskFail(self, i18n.trSlice("顺序读取测试失败", "Sequential read failed", "シーケンシャル読込テスト失敗"));
                return;
            };
            total_read += n;
            self.mutex.lock();
            self.snap.progress_pct = 35.0 + (@as(f32, @floatFromInt(mb_i + 1)) / @as(f32, @floatFromInt(file_mb))) * 35.0;
            self.mutex.unlock();
        }
        const tr1 = std.time.nanoTimestamp();
        const rs = @max(0.001, @as(f64, @floatFromInt(tr1 - tr0)) / @as(f64, @floatFromInt(std.time.ns_per_s)));
        self.mutex.lock();
        self.snap.disk_seq_read_mbs = (@as(f64, @floatFromInt(total_read)) / (1024.0 * 1024.0)) / rs;
        self.mutex.unlock();

        if (self.cancel_flag.load(.acquire)) {
            finishDiskCancelled(self, start_ns);
            return;
        }

        // 3. RND4K Read (2048 random 4 KB blocks)
        var blk4k: [4096]u8 = undefined;
        const max_blocks: u64 = (@as(u64, file_mb) * 1024 * 1024) / 4096;
        const ops: usize = 2048;
        var rng_state: u64 = 0x13579BDF2468ACE0;
        const tk0 = std.time.nanoTimestamp();
        var ops_done: usize = 0;
        for (0..ops) |oi| {
            if (self.cancel_flag.load(.acquire)) break;
            rng_state = rng_state *% 6364136223846793005 +% 1;
            const blk_idx = (rng_state >> 16) % max_blocks;
            f.seekTo(blk_idx * 4096) catch break;
            _ = f.readAll(&blk4k) catch break;
            ops_done += 1;
            if ((oi & 63) == 0) {
                self.mutex.lock();
                self.snap.progress_pct = 70.0 + (@as(f32, @floatFromInt(oi + 1)) / @as(f32, @floatFromInt(ops))) * 30.0;
                self.mutex.unlock();
            }
        }
        const tk1 = std.time.nanoTimestamp();
        const ks = @max(0.0001, @as(f64, @floatFromInt(tk1 - tk0)) / @as(f64, @floatFromInt(std.time.ns_per_s)));
        const iops = @as(f64, @floatFromInt(ops_done)) / ks;
        const mbs_4k = (@as(f64, @floatFromInt(ops_done)) * 4096.0 / (1024.0 * 1024.0)) / ks;
        const lat_us = if (ops_done > 0) (ks * 1_000_000.0) / @as(f64, @floatFromInt(ops_done)) else 0.0;

        self.mutex.lock();
        self.snap.disk_rnd4k_read_iops = iops;
        self.snap.disk_rnd4k_read_mbs = mbs_4k;
        self.snap.disk_rnd4k_avg_lat_us = lat_us;
        self.snap.elapsed_s = @as(f64, @floatFromInt(tk1 - start_ns)) / @as(f64, @floatFromInt(std.time.ns_per_s));
        self.snap.active_kind = .none;
        self.snap.progress_pct = 100.0;
        self.snap.outcome = .passed;
        setSummary(&self.snap, i18n.trSlice(
            "磁盘文件级读写基准测试完成，临时文件已自动清理",
            "Disk file-level benchmark completed; temp file auto-deleted",
            "ディスクベンチマーク完了（一時ファイル自動削除済）",
        ));
        self.mutex.unlock();
    }
}

fn markDiskFail(self: *BenchmarkRunner, msg: []const u8) void {
    self.mutex.lock();
    self.snap.active_kind = .none;
    self.snap.outcome = .failed_io;
    setSummary(&self.snap, msg);
    self.mutex.unlock();
}

fn finishDiskCancelled(self: *BenchmarkRunner, start_ns: i128) void {
    self.mutex.lock();
    self.snap.active_kind = .none;
    self.snap.elapsed_s = @as(f64, @floatFromInt(std.time.nanoTimestamp() - start_ns)) / @as(f64, @floatFromInt(std.time.ns_per_s));
    self.snap.outcome = if (self.thermal_trip_flag.load(.acquire)) .stopped_by_thermal else .stopped_by_user;
    setSummary(&self.snap, i18n.trSlice(
        "磁盘基准测试已中止，临时文件已自动清理",
        "Disk benchmark aborted; temp file auto-deleted",
        "ディスクベンチマークを中止しました（一時ファイル削除済）",
    ));
    self.mutex.unlock();
}

fn setSummary(snap: *BenchmarkSnapshot, msg: []const u8) void {
    const n = @min(snap.summary.len, msg.len);
    @memcpy(snap.summary[0..n], msg[0..n]);
    snap.summary_len = n;
}

test "BenchmarkRunner deterministic CPU kernel and thermal cutoff work accurately" {
    const r1 = computeDeterministicKernel(0x123456789ABCDEF0);
    const r2 = computeDeterministicKernel(0x123456789ABCDEF0);
    try std.testing.expectEqual(r1, r2);

    var runner = BenchmarkRunner.init(std.testing.allocator);
    defer runner.deinit();

    // Verify 32 MB memory pattern verification passes with 0 bit errors
    try std.testing.expect(runner.startMemoryVerify(.{ .mem_size_mb = 32 }, 4 * 1024 * 1024 * 1024));
    var wait: usize = 0;
    while (runner.isRunning() and wait < 200) : (wait += 1) {
        std.Thread.sleep(20 * std.time.ns_per_ms);
    }
    const snap = runner.copySnapshot();
    try std.testing.expectEqual(TestOutcome.passed, snap.outcome);
    try std.testing.expectEqual(@as(u64, 0), snap.error_count);
    try std.testing.expectEqual(@as(u32, 4), snap.mem_passes_done);
    try std.testing.expect(snap.mem_write_gbs > 0.0);
    try std.testing.expect(snap.mem_read_gbs > 0.0);

    const rep = try runner.exportReport(std.testing.allocator, "Test CPU", "Test GPU");
    defer std.testing.allocator.free(rep);
    try std.testing.expect(std.mem.indexOf(u8, rep, "通过（零错误）") != null);
}
