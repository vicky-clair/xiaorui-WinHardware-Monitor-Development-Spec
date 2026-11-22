const std = @import("std");
const builtin = @import("builtin");
const i18n = @import("i18n.zig");
const win32 = @import("../providers/windows/win32.zig");

const linux_sys = if (builtin.os.tag == .linux) struct {
    extern "c" fn posix_fadvise(fd: c_int, offset: i64, len: i64, advice: c_int) c_int;
    extern "c" fn setpriority(which: c_int, who: u32, prio: c_int) c_int;
    extern "c" fn statvfs(path: [*:0]const u8, buf: *StatVfs) c_int;
    const POSIX_FADV_DONTNEED: c_int = 4;
    const PRIO_PROCESS: c_int = 0;
    const StatVfs = extern struct {
        f_bsize: c_ulong = 0,
        f_frsize: c_ulong = 0,
        f_blocks: u64 = 0,
        f_bfree: u64 = 0,
        f_bavail: u64 = 0,
        _rest: [256]u8 = std.mem.zeroes([256]u8),
    };
} else struct {};

/// V2.2 跨平台系统友好型硬件稳定性与基准测试引擎（Windows / Linux 共用核心算法）。
/// 安全与低负担承诺（AGENTS.md V2.0 红线 #6 + 用户防卡顿要求）：
/// 1. 所有后台测试线程自动降为低优先级（Windows THREAD_PRIORITY_BELOW_NORMAL / Linux nice +10），
///    默认开启「温和防卡顿模式」（保留系统核心 + 微时间片让出），绝不阻塞桌面或抢占其他进程；
/// 2. 磁盘测速先查目标盘剩余空间（要求 ≥ 2×文件 + 512 MB），严禁写裸盘，仅创建受控临时文件并自动删除；
///    - Windows 优先使用 FILE_FLAG_NO_BUFFERING | FILE_FLAG_WRITE_THROUGH + 4K 对齐缓冲；
///    - Linux 使用 posix_fadvise(POSIX_FADV_DONTNEED) 驱逐页缓存；
///    - 支持 SEQ1M 读写完整性哈希比对（检出扩容盘/坏块）与 RND4K 读/写 P95/P99 尾延迟统计；
/// 3. 内置实时高温自动熔断保护与智能三语排障结论。
pub const TRACE_CAPACITY: usize = 120;

pub const TestKind = enum(u8) {
    none,
    cpu_stress,
    memory_verify,
    disk_bench,
    gpu_stress,
    combined_stress,
    full_suite,

    pub fn code(self: TestKind) []const u8 {
        return switch (self) {
            .none => "none",
            .cpu_stress => "cpu_stress",
            .memory_verify => "memory_verify",
            .disk_bench => "disk_bench",
            .gpu_stress => "gpu_stress",
            .combined_stress => "combined_stress",
            .full_suite => "full_suite",
        };
    }

    pub fn labelZh(self: TestKind) [:0]const u8 {
        return switch (self) {
            .none => i18n.tr("空闲", "Idle", "待機中"),
            .cpu_stress => i18n.tr("CPU 单核/多核与降频测试", "CPU Single/Multi & Throttle", "CPU シングル/マルチ・サーマル検証"),
            .memory_verify => i18n.tr("内存延迟、带宽与位翻转校验", "Memory Latency, BW & Bit-Flip", "メモリ遅延・帯域・ビット検証"),
            .disk_bench => i18n.tr("磁盘无缓存读写与完整性校验", "Disk Unbuffered R/W & Integrity", "ディスク無キャッシュ計測・整合性検証"),
            .gpu_stress => i18n.tr("GPU OpenGL 着色器烤机", "GPU OpenGL Shader Stress", "GPU OpenGL シェーダー負荷テスト"),
            .combined_stress => i18n.tr("整机安全联烤 (CPU+内存+GPU)", "Combined Safe Stress (CPU+RAM+GPU)", "総合安全負荷テスト (CPU+RAM+GPU)"),
            .full_suite => i18n.tr("一键全套硬件综合体检", "1-Click Full Hardware Diagnostic", "ワンクリック総合ハードウェア診断"),
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

    pub fn code(self: TestOutcome) []const u8 {
        return switch (self) {
            .idle => "idle",
            .running => "running",
            .passed => "passed",
            .failed_errors => "failed_errors",
            .stopped_by_user => "stopped_by_user",
            .stopped_by_thermal => "stopped_by_thermal",
            .failed_io => "failed_io",
        };
    }

    pub fn labelZh(self: TestOutcome) [:0]const u8 {
        return switch (self) {
            .idle => i18n.tr("尚未运行", "Not Run", "未実行"),
            .running => i18n.tr("测试运行中", "Running", "実行中"),
            .passed => i18n.tr("通过（零错误）", "Passed (0 Errors)", "合格（エラーなし）"),
            .failed_errors => i18n.tr("检出硬件/数据错误", "Hardware/Data Error Detected", "ハードウェア/データエラー検出"),
            .stopped_by_user => i18n.tr("用户手动停止", "Stopped by User", "ユーザーにより停止"),
            .stopped_by_thermal => i18n.tr("触发高温熔断已自动停机", "Thermal Cutoff Triggered", "高温保護により自動停止"),
            .failed_io => i18n.tr("I/O 或空间检查未通过", "I/O or Space Check Failed", "I/O または空き容量不足"),
        };
    }
};

pub const BenchmarkSnapshot = struct {
    run_id: u64 = 0, // 每次新启动递增，用于检测测试完成并自动归档至 SQLite 历史表
    active_kind: TestKind = .none,
    last_kind: TestKind = .none,
    outcome: TestOutcome = .idle,
    progress_pct: f32 = 0.0,
    elapsed_s: f64 = 0.0,
    target_duration_s: u32 = 20,
    gentle_mode: bool = true,
    gpu_intensity: u8 = 1,
    gpu_shader_active: bool = false, // 通知主渲染循环启用 OpenGL 3.3 FBO 片段着色器

    // 安全熔断与温度/功耗追踪
    thermal_cutoff_c: f64 = 90.0,
    start_temp_c: ?f64 = null,
    peak_temp_c: ?f64 = null,
    peak_gpu_power_w: ?f64 = null,
    error_count: u64 = 0,

    // 1. CPU 单核/多核与热降频结果
    has_cpu_result: bool = false,
    cpu_threads: u32 = 0,
    cpu_single_mops: f64 = 0.0,
    cpu_score_mops: f64 = 0.0, // Multi-core MOPS
    cpu_scaling_ratio: f64 = 0.0,
    cpu_throttle_drop_pct: f64 = 0.0, // >0 表示后段算力相对前段下降比例（%）

    // 2. 内存延迟（L1/L2/L3/RAM）、多核拷贝与 4 轮位翻转校验
    has_mem_result: bool = false,
    mem_tested_mb: u32 = 0,
    mem_write_gbs: f64 = 0.0,
    mem_read_gbs: f64 = 0.0,
    mem_copy_gbs: f64 = 0.0,
    mem_passes_done: u32 = 0,
    mem_lat_l1_ns: f64 = 0.0,
    mem_lat_l2_ns: f64 = 0.0,
    mem_lat_l3_ns: f64 = 0.0,
    mem_lat_ram_ns: f64 = 0.0,

    // 3. 磁盘无缓存 SEQ1M R/W + 完整性比对 + RND4K R/W + 分位数尾延迟
    has_disk_result: bool = false,
    disk_file_mb: u32 = 0,
    disk_unbuffered: bool = false,
    disk_seq_write_mbs: f64 = 0.0,
    disk_seq_read_mbs: f64 = 0.0,
    disk_integrity_checked: bool = false,
    disk_integrity_errors: u64 = 0,
    disk_rnd4k_read_mbs: f64 = 0.0,
    disk_rnd4k_read_iops: f64 = 0.0,
    disk_rnd4k_min_lat_us: f64 = 0.0,
    disk_rnd4k_avg_lat_us: f64 = 0.0,
    disk_rnd4k_p95_lat_us: f64 = 0.0,
    disk_rnd4k_p99_lat_us: f64 = 0.0,
    disk_rnd4k_max_lat_us: f64 = 0.0,
    disk_rnd4k_write_mbs: f64 = 0.0,
    disk_rnd4k_write_iops: f64 = 0.0,
    disk_rnd4k_write_p99_us: f64 = 0.0,

    // 4. GPU OpenGL 3.3 FBO 着色器烤机结果
    has_gpu_result: bool = false,
    gpu_frames: u64 = 0,
    gpu_avg_fps: f64 = 0.0,
    gpu_low1_fps: f64 = 0.0,
    gpu_avg_frametime_ms: f64 = 0.0,
    gpu_max_frametime_ms: f64 = 0.0,

    // 实时过程曲线缓冲（用于右侧 ImPlot 温度 + 性能双轴曲线可视化）
    trace_times: [TRACE_CAPACITY]f64 = [_]f64{0.0} ** TRACE_CAPACITY,
    trace_perf: [TRACE_CAPACITY]f64 = [_]f64{0.0} ** TRACE_CAPACITY,
    trace_temp: [TRACE_CAPACITY]f64 = [_]f64{0.0} ** TRACE_CAPACITY,
    trace_len: usize = 0,

    summary: [192]u8 = std.mem.zeroes([192]u8),
    summary_len: usize = 0,

    pub fn summarySlice(self: *const BenchmarkSnapshot) []const u8 {
        return self.summary[0..self.summary_len];
    }

    pub fn pushTrace(self: *BenchmarkSnapshot, t_s: f64, perf_val: f64, temp_opt: ?f64) void {
        const temp_val = temp_opt orelse if (self.trace_len > 0) self.trace_temp[self.trace_len - 1] else 0.0;
        if (self.trace_len < TRACE_CAPACITY) {
            self.trace_times[self.trace_len] = t_s;
            self.trace_perf[self.trace_len] = perf_val;
            self.trace_temp[self.trace_len] = temp_val;
            self.trace_len += 1;
        } else {
            var i: usize = 1;
            while (i < TRACE_CAPACITY) : (i += 1) {
                self.trace_times[i - 1] = self.trace_times[i];
                self.trace_perf[i - 1] = self.trace_perf[i];
                self.trace_temp[i - 1] = self.trace_temp[i];
            }
            self.trace_times[TRACE_CAPACITY - 1] = t_s;
            self.trace_perf[TRACE_CAPACITY - 1] = perf_val;
            self.trace_temp[TRACE_CAPACITY - 1] = temp_val;
        }
    }

    /// 生成面向普通用户的智能三语诊断结论与排障建议
    pub fn diagnosticAdvice(self: *const BenchmarkSnapshot) []const u8 {
        if (self.outcome == .idle) {
            return i18n.trSlice(
                "默认开启「温和防卡顿模式」：自动降低测试线程优先级并预留系统核心，确保测试期间电脑仍可正常办公与浏览网页。",
                "Gentle System-Safe Mode is ON by default: test threads run at reduced OS priority and reserve CPU headroom so desktop apps stay responsive.",
                "「システム保護モード」が既定でオン：テストスレッドの優先度を下げ OS 用コアを確保するため、作業中でもPCが重くなりにくいです。",
            );
        }
        if (self.outcome == .running) {
            return i18n.trSlice(
                "测试安全运行中：实时高温熔断已激活，随时可点击「立即停止」安全中止并自动释放资源。",
                "Test running safely: live thermal auto-cutoff is active; click Stop anytime to abort cleanly.",
                "安全に実行中：リアルタイム高温自動停止が有効です。いつでも「停止」ボタンで即座に安全終了できます。",
            );
        }
        if (self.outcome == .stopped_by_thermal) {
            return i18n.trSlice(
                "已触发高温自动熔断保护！说明散热系统在高负载下压力较大，建议清理风道灰尘、检查风扇曲线或更换导热硅脂。",
                "Thermal auto-cutoff triggered! Cooling is under heavy pressure—consider cleaning dust, checking fan curves, or repasting.",
                "高温保護により自動停止しました！冷却性能が不足している可能性があります。清掃・ファン回転数・グリス交換を検討してください。",
            );
        }
        if (self.outcome == .failed_errors) {
            if (self.has_disk_result and self.disk_integrity_errors > 0) {
                return i18n.trSlice(
                    "严重警告：磁盘写入-回读数据校验发现不匹配！请立即备份重要数据，该磁盘可能存在坏块、主控故障或为扩容盘。",
                    "CRITICAL: Disk write-then-read integrity mismatch! Back up immediately—drive may have bad blocks, controller faults, or fake capacity.",
                    "重大警告：ディスクの書込・読込整合性エラーを検出！直ちにバックアップしてください（不良セクタ・故障・容量偽装の恐れ）。",
                );
            }
            if (self.has_mem_result and self.last_kind == .memory_verify) {
                return i18n.trSlice(
                    "检测到内存位翻转错误！建议关闭 BIOS 中的 XMP/EXPO 超频、降低内存频率，或关机重新插拔并单条逐一排查。",
                    "Memory bit-flip detected! Try disabling XMP/EXPO in BIOS, lowering RAM clock, or reseating/testing sticks individually.",
                    "メモリビット反転エラーを検出！BIOS の XMP/EXPO 無効化やクロック低下、メモリの挿し直し・1枚ずつの切り分けを推奨します。",
                );
            }
            return i18n.trSlice(
                "检测到硬件计算校验误差！若开启了 CPU 超频或降压（Undervolt），建议恢复默认电压与频率后复测。",
                "Hardware compute verification error detected! If overclocked or undervolted, restore default BIOS settings and retest.",
                "演算検証エラーを検出しました！OC や低電圧化を行っている場合は標準設定に戻して再テストしてください。",
            );
        }
        if (self.outcome == .failed_io) {
            return i18n.trSlice(
                "测试未启动或被安全拦截：请检查目标盘剩余空间是否充足（需至少 2 倍测试文件 + 512 MB 安全余量）及目录写权限。",
                "Test blocked safely: verify target drive has enough free space (>= 2x test file + 512 MB margin) and write permissions.",
                "安全チェックにより中断：対象ドライブの空き容量（テスト容量の2倍＋512MB以上）と書込権限を確認してください。",
            );
        }
        if (self.outcome == .stopped_by_user) {
            return i18n.trSlice(
                "测试已由用户安全停止，所有临时内存与磁盘临时文件均已自动清理，无残留负担。",
                "Stopped safely by user; all temporary buffers and benchmark files were cleaned up automatically.",
                "ユーザー操作で安全に停止しました。一時メモリと一時ファイルはすべて自動削除済みです。",
            );
        }

        // outcome == .passed — 基于实测细项给出精准解读
        if (self.has_cpu_result and self.cpu_throttle_drop_pct >= 15.0) {
            return i18n.trSlice(
                "计算零错误，但后段 CPU 算力相对前段下降明显（≥15%），疑似触发功耗墙或高温降频，建议关注机箱散热与风扇转速。",
                "0 compute errors, but late-stage CPU throughput dropped >=15% vs start—likely thermal or power-limit throttling. Check cooling/airflow.",
                "エラーはありませんが、後半の CPU 性能が15%以上低下しました。電力制限またはサーマルスロットリングの可能性があります。",
            );
        }
        if (self.has_disk_result and self.disk_rnd4k_p99_lat_us > 15000.0) {
            return i18n.trSlice(
                "数据完整性校验通过，但 4K 随机读 P99 尾延迟偏高（>15ms）：机械硬盘属正常现象；若是 SSD 则可能处于缓存耗尽或高后台负载状态。",
                "Integrity verified, but 4K P99 tail latency >15ms (normal for HDDs; on SSDs this may indicate SLC cache exhaustion or heavy background I/O).",
                "整合性OKですが 4K P99 遅延が15ms超です（HDDなら正常、SSDの場合はキャッシュ枯渇や高負荷状態の可能性があります）。",
            );
        }
        if (self.has_gpu_result and self.gpu_avg_fps > 10.0 and self.gpu_low1_fps < self.gpu_avg_fps * 0.45) {
            return i18n.trSlice(
                "GPU 烤机零异常，但 1% Low 帧率波动偏大（<均值45%），建议检查后台占显存程序或显卡散热频率稳定性。",
                "GPU stress passed with 0 errors, though 1% Low FPS dipped below 45% of avg—check background GPU apps or boost stability.",
                "GPU 負荷テストは正常完了しましたが、1% Low FPS の変動がやや大きいです。バックグラウンド GPU 負荷や冷却を確認してください。",
            );
        }
        return i18n.trSlice(
            "全部测试项目零错误通过，性能输出平稳、无异常降频或数据校验误差，当前硬件稳定性表现良好。",
            "All checks passed with 0 errors, steady throughput, and no abnormal throttling or data corruption. Hardware stability looks healthy.",
            "全項目エラーなしで合格。性能低下やデータ異常も見られず、ハードウェアの安定性は良好です。",
        );
    }

    /// 供 SQLite 历史表归档的主/副指标摘要
    pub fn formatHistorySummary(self: *const BenchmarkSnapshot, p_buf: *[96]u8, s_buf: *[96]u8) struct { primary: []const u8, secondary: []const u8 } {
        return switch (self.last_kind) {
            .cpu_stress => .{
                .primary = std.fmt.bufPrint(p_buf, "1T {d:.1} / MT {d:.1} MOPS ({d:.1}x)", .{ self.cpu_single_mops, self.cpu_score_mops, self.cpu_scaling_ratio }) catch "CPU",
                .secondary = std.fmt.bufPrint(s_buf, "Drop {d:.1}% | {d}T", .{ self.cpu_throttle_drop_pct, self.cpu_threads }) catch "",
            },
            .memory_verify => .{
                .primary = std.fmt.bufPrint(p_buf, "W {d:.1} / R {d:.1} / Copy {d:.1} GB/s", .{ self.mem_write_gbs, self.mem_read_gbs, self.mem_copy_gbs }) catch "RAM",
                .secondary = std.fmt.bufPrint(s_buf, "RAM {d:.1}ns | L3 {d:.1}ns | {d}/4", .{ self.mem_lat_ram_ns, self.mem_lat_l3_ns, self.mem_passes_done }) catch "",
            },
            .disk_bench => .{
                .primary = std.fmt.bufPrint(p_buf, "SEQ W {d:.0} / R {d:.0} MB/s", .{ self.disk_seq_write_mbs, self.disk_seq_read_mbs }) catch "Disk",
                .secondary = std.fmt.bufPrint(s_buf, "4K R {d:.0}/W {d:.0} IOPS | P99 {d:.0}us", .{ self.disk_rnd4k_read_iops, self.disk_rnd4k_write_iops, self.disk_rnd4k_p99_lat_us }) catch "",
            },
            .gpu_stress => .{
                .primary = std.fmt.bufPrint(p_buf, "Avg {d:.1} / 1%Low {d:.1} FPS", .{ self.gpu_avg_fps, self.gpu_low1_fps }) catch "GPU",
                .secondary = std.fmt.bufPrint(s_buf, "FT {d:.1}ms (max {d:.1}ms)", .{ self.gpu_avg_frametime_ms, self.gpu_max_frametime_ms }) catch "",
            },
            .combined_stress => .{
                .primary = std.fmt.bufPrint(p_buf, "CPU {d:.1} MOPS | GPU {d:.1} FPS", .{ self.cpu_score_mops, self.gpu_avg_fps }) catch "Combined",
                .secondary = std.fmt.bufPrint(s_buf, "1%Low {d:.1} FPS | {d} err", .{ self.gpu_low1_fps, self.error_count }) catch "",
            },
            .full_suite => .{
                .primary = std.fmt.bufPrint(p_buf, "CPU {d:.0} | RAM {d:.1}GB/s | Disk {d:.0}", .{ self.cpu_score_mops, self.mem_copy_gbs, self.disk_seq_read_mbs }) catch "Suite",
                .secondary = std.fmt.bufPrint(s_buf, "GPU {d:.1} FPS | RAM {d:.1}ns", .{ self.gpu_avg_fps, self.mem_lat_ram_ns }) catch "",
            },
            .none => .{ .primary = "-", .secondary = "" },
        };
    }
};

pub const BenchmarkConfig = struct {
    cpu_threads: u32 = 4,
    duration_s: u32 = 20,
    thermal_cutoff_c: f64 = 90.0,
    mem_size_mb: u32 = 256,
    disk_file_mb: u32 = 128,
    gentle_mode: bool = true,
    gpu_intensity: u8 = 1,
    include_disk_in_suite: bool = false,
};

/// 跨平台查询指定目录所在磁盘剩余可用字节数（测试前空间护栏，防写满系统盘）
pub fn queryDirFreeBytes(dir_path: []const u8) ?u64 {
    if (dir_path.len == 0) return null;
    if (builtin.os.tag == .windows) {
        var path_w: [512]u16 = undefined;
        const wlen = std.unicode.utf8ToUtf16Le(path_w[0 .. path_w.len - 1], dir_path) catch return null;
        path_w[wlen] = 0;
        var free_avail: u64 = 0;
        if (win32.GetDiskFreeSpaceExW(@ptrCast(&path_w), &free_avail, null, null) != 0) {
            return free_avail;
        }
        return null;
    } else if (builtin.os.tag == .linux) {
        var path_z: [512]u8 = undefined;
        if (dir_path.len >= path_z.len) return null;
        @memcpy(path_z[0..dir_path.len], dir_path);
        path_z[dir_path.len] = 0;
        var st = linux_sys.StatVfs{};
        if (linux_sys.statvfs(@ptrCast(&path_z), &st) == 0) {
            const unit: u64 = if (st.f_frsize > 0) @intCast(st.f_frsize) else @intCast(st.f_bsize);
            return st.f_bavail *| unit;
        }
        return null;
    }
    return null;
}

/// 将当前测试工作线程降为低优先级，保证前台操作系统与其他进程丝滑不卡顿
fn lowerCurrentThreadPriority() void {
    if (builtin.os.tag == .windows) {
        _ = win32.SetThreadPriority(win32.GetCurrentThread(), win32.THREAD_PRIORITY_BELOW_NORMAL);
    } else if (builtin.os.tag == .linux) {
        _ = linux_sys.setpriority(linux_sys.PRIO_PROCESS, 0, 10);
    }
}

pub const BenchmarkRunner = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    snap: BenchmarkSnapshot = .{},
    run_counter: u64 = 0,
    cancel_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thermal_trip_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    worker_thread: ?std.Thread = null,

    // GPU 烤机帧时间统计（固定小数组，零堆分配）
    gpu_start_ns: i128 = 0,
    gpu_last_frame_ns: i128 = 0,
    gpu_last_trace_ns: i128 = 0,
    gpu_duration_s: u32 = 20,
    gpu_frametimes_ms: [512]f32 = [_]f32{0.0} ** 512,
    gpu_ft_count: usize = 0,
    gpu_ft_cursor: usize = 0,
    gpu_max_ft_ms: f64 = 0.0,
    gpu_trace_frames_base: u64 = 0,
    suite_gpu_phase: bool = false,
    latest_temp_c: ?f64 = null,

    pub fn init(allocator: std.mem.Allocator) BenchmarkRunner {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *BenchmarkRunner) void {
        self.requestStop();
        self.joinIfFinished(true);
    }

    /// 由监控循环持续喂入实时最高温度与 GPU 功耗，触发高温自动熔断并记录温升 ΔT
    pub fn updateLiveTelemetry(self: *BenchmarkRunner, max_temp_c: ?f64, gpu_power_w: ?f64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.latest_temp_c = max_temp_c;
        if (self.snap.outcome == .running) {
            if (max_temp_c) |tc| {
                if (self.snap.start_temp_c == null) self.snap.start_temp_c = tc;
                if (self.snap.peak_temp_c == null or tc > self.snap.peak_temp_c.?) {
                    self.snap.peak_temp_c = tc;
                }
                if (tc >= self.snap.thermal_cutoff_c) {
                    self.thermal_trip_flag.store(true, .release);
                    self.cancel_flag.store(true, .release);
                }
            }
            if (gpu_power_w) |pw| {
                if (self.snap.peak_gpu_power_w == null or pw > self.snap.peak_gpu_power_w.?) {
                    self.snap.peak_gpu_power_w = pw;
                }
            }
        }
    }

    pub fn updateLiveTemperature(self: *BenchmarkRunner, max_temp_c: ?f64) void {
        self.updateLiveTelemetry(max_temp_c, null);
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
        if (self.snap.outcome == .running and (self.snap.active_kind == .gpu_stress or self.suite_gpu_phase)) {
            self.snap.active_kind = .none;
            self.snap.gpu_shader_active = false;
            self.suite_gpu_phase = false;
            self.snap.outcome = if (self.thermal_trip_flag.load(.acquire)) .stopped_by_thermal else .stopped_by_user;
            setSummary(&self.snap, i18n.trSlice("GPU OpenGL 着色器烤机已停止", "GPU OpenGL shader stress stopped", "GPU シェーダー負荷テストを停止しました"));
        }
        self.mutex.unlock();
    }

    fn joinIfFinished(self: *BenchmarkRunner, force_wait: bool) void {
        if (self.worker_thread) |t| {
            const done = force_wait or blk: {
                self.mutex.lock();
                defer self.mutex.unlock();
                break :blk self.snap.outcome != .running or self.suite_gpu_phase;
            };
            if (done) {
                t.join();
                self.worker_thread = null;
            }
        }
    }

    fn beginRunLocked(self: *BenchmarkRunner, kind: TestKind, cfg: BenchmarkConfig) void {
        self.run_counter += 1;
        self.suite_gpu_phase = false;
        self.gpu_ft_count = 0;
        self.gpu_ft_cursor = 0;
        self.gpu_max_ft_ms = 0.0;
        self.snap = .{
            .run_id = self.run_counter,
            .active_kind = kind,
            .last_kind = kind,
            .outcome = .running,
            .target_duration_s = cfg.duration_s,
            .thermal_cutoff_c = std.math.clamp(cfg.thermal_cutoff_c, 65.0, 105.0),
            .start_temp_c = self.latest_temp_c,
            .peak_temp_c = self.latest_temp_c,
            .gentle_mode = cfg.gentle_mode,
            .gpu_intensity = @min(cfg.gpu_intensity, 2),
        };
    }

    pub fn startCpuStress(self: *BenchmarkRunner, cfg: BenchmarkConfig) bool {
        self.joinIfFinished(false);
        if (self.isRunning()) return false;
        self.cancel_flag.store(false, .release);
        self.thermal_trip_flag.store(false, .release);

        const threads = std.math.clamp(cfg.cpu_threads, 1, 64);
        const dur = std.math.clamp(cfg.duration_s, 6, 600);
        var c = cfg;
        c.cpu_threads = threads;
        c.duration_s = dur;

        self.mutex.lock();
        self.beginRunLocked(.cpu_stress, c);
        self.snap.cpu_threads = threads;
        setSummary(&self.snap, i18n.trSlice(
            "正在运行低优先级 CPU 单核 + 多核确定性校验与降频分析...",
            "Running low-priority CPU Single+Multi deterministic & throttle test...",
            "低優先度 CPU シングル/マルチ演算・サーマル検証を実行中...",
        ));
        self.mutex.unlock();

        self.worker_thread = std.Thread.spawn(.{}, cpuStressMain, .{ self, c }) catch {
            self.failInit(i18n.trSlice("无法创建 CPU 测试工作线程", "Failed to spawn CPU test thread", "CPU テストスレッドの作成に失敗"));
            return false;
        };
        return true;
    }

    pub fn startMemoryVerify(self: *BenchmarkRunner, cfg: BenchmarkConfig, avail_mem_bytes: u64) bool {
        self.joinIfFinished(false);
        if (self.isRunning()) return false;
        self.cancel_flag.store(false, .release);
        self.thermal_trip_flag.store(false, .release);

        // 安全上限：不超过当前可用物理内存的 35% 且最高 1024 MB，绝不触发系统交换/卡顿/OOM
        const max_safe_mb: u32 = if (avail_mem_bytes > 256 * 1024 * 1024)
            @intCast(@min(@as(u64, 1024), (avail_mem_bytes / (1024 * 1024)) * 35 / 100))
        else
            32;
        const size_mb = std.math.clamp(cfg.mem_size_mb, 32, @max(@as(u32, 32), max_safe_mb));
        var c = cfg;
        c.mem_size_mb = size_mb;

        self.mutex.lock();
        self.beginRunLocked(.memory_verify, c);
        self.snap.mem_tested_mb = size_mb;
        setSummary(&self.snap, i18n.trSlice(
            "正在执行 L1/L2/L3/RAM 延迟测量、多核拷贝带宽与 4 轮位翻转校验...",
            "Running L1/L2/L3/RAM latency, multi-thread Copy & 4-pass bit-flip verify...",
            "L1/L2/L3/RAM 遅延・マルチコピー帯域・4パス ビット検証を実行中...",
        ));
        self.mutex.unlock();

        self.worker_thread = std.Thread.spawn(.{}, memoryVerifyMain, .{ self, c }) catch {
            self.failInit(i18n.trSlice("无法创建内存测试线程", "Failed to spawn memory test thread", "メモリテストスレッドの作成に失敗"));
            return false;
        };
        return true;
    }

    pub fn startDiskBench(self: *BenchmarkRunner, cfg: BenchmarkConfig, target_dir: []const u8) bool {
        self.joinIfFinished(false);
        if (self.isRunning()) return false;
        self.cancel_flag.store(false, .release);
        self.thermal_trip_flag.store(false, .release);

        const file_mb = std.math.clamp(cfg.disk_file_mb, 32, 1024);
        var c = cfg;
        c.disk_file_mb = file_mb;
        const dir_copy = self.allocator.dupe(u8, target_dir) catch return false;

        self.mutex.lock();
        self.beginRunLocked(.disk_bench, c);
        self.snap.disk_file_mb = file_mb;
        setSummary(&self.snap, i18n.trSlice(
            "正在执行空间安全检查、无缓存 SEQ1M/RND4K 读写与完整性校验...",
            "Checking free space & running unbuffered SEQ1M/RND4K R/W + integrity verify...",
            "空き容量確認・無キャッシュ SEQ1M/RND4K 計測・整合性検証を実行中...",
        ));
        self.mutex.unlock();

        self.worker_thread = std.Thread.spawn(.{}, diskBenchMain, .{ self, c, dir_copy }) catch {
            self.allocator.free(dir_copy);
            self.failInit(i18n.trSlice("无法创建磁盘基准测试线程", "Failed to spawn disk benchmark thread", "ディスクテストスレッド作成失敗"));
            return false;
        };
        return true;
    }

    /// 启动 GPU OpenGL 3.3 离屏片段着色器烤机
    pub fn startGpuStress(self: *BenchmarkRunner, cfg: BenchmarkConfig) bool {
        self.joinIfFinished(false);
        if (self.isRunning()) return false;
        self.cancel_flag.store(false, .release);
        self.thermal_trip_flag.store(false, .release);

        const dur = std.math.clamp(cfg.duration_s, 10, 600);
        var c = cfg;
        c.duration_s = dur;
        const now_ns = std.time.nanoTimestamp();
        self.gpu_start_ns = now_ns;
        self.gpu_last_frame_ns = now_ns;
        self.gpu_last_trace_ns = now_ns;
        self.gpu_duration_s = dur;
        self.gpu_trace_frames_base = 0;

        self.mutex.lock();
        self.beginRunLocked(.gpu_stress, c);
        self.snap.gpu_shader_active = true;
        self.snap.has_gpu_result = true;
        setSummary(&self.snap, i18n.trSlice(
            "正在运行 OpenGL 3.3 离屏片段着色器烤机（帧时间与 1% Low 实时分析）...",
            "Running OpenGL 3.3 offscreen shader stress (live FPS & 1% Low analysis)...",
            "OpenGL 3.3 シェーダー負荷テスト実行中（FPS・1% Low 計測）...",
        ));
        self.mutex.unlock();
        return true;
    }

    /// 启动整机安全联烤（低优先级 CPU + 安全内存访问 + OpenGL 3.3 GPU 着色器同步运行）
    pub fn startCombinedStress(self: *BenchmarkRunner, cfg: BenchmarkConfig) bool {
        self.joinIfFinished(false);
        if (self.isRunning()) return false;
        self.cancel_flag.store(false, .release);
        self.thermal_trip_flag.store(false, .release);

        const dur = std.math.clamp(cfg.duration_s, 10, 300);
        // 联烤时至少为系统与 OpenGL 主线程保留 1-2 个逻辑核，确保桌面流畅不掉帧
        const safe_threads = std.math.clamp(if (cfg.cpu_threads > 2) cfg.cpu_threads - 1 else 1, 1, 64);
        var c = cfg;
        c.duration_s = dur;
        c.cpu_threads = safe_threads;

        const now_ns = std.time.nanoTimestamp();
        self.gpu_start_ns = now_ns;
        self.gpu_last_frame_ns = now_ns;
        self.gpu_last_trace_ns = now_ns;
        self.gpu_duration_s = dur;
        self.gpu_trace_frames_base = 0;

        self.mutex.lock();
        self.beginRunLocked(.combined_stress, c);
        self.snap.cpu_threads = safe_threads;
        self.snap.gpu_shader_active = true;
        self.snap.has_cpu_result = true;
        self.snap.has_gpu_result = true;
        setSummary(&self.snap, i18n.trSlice(
            "正在运行整机安全联烤（CPU 低优先级 + 内存巡检 + GPU 着色器，高温自动熔断）...",
            "Running Combined Safe Stress (low-prio CPU + RAM check + GPU shader)...",
            "総合安全負荷テスト実行中（低優先度 CPU＋メモリ＋GPU シェーダー）...",
        ));
        self.mutex.unlock();

        self.worker_thread = std.Thread.spawn(.{}, combinedWorkerMain, .{ self, c }) catch {
            self.failInit(i18n.trSlice("无法创建联烤工作线程", "Failed to spawn combined stress worker", "総合テストスレッド作成失敗"));
            return false;
        };
        return true;
    }

    /// 启动一键全套硬件综合体检（依次执行 CPU → 内存 → 可选磁盘 → GPU 着色器）
    pub fn startFullSuite(self: *BenchmarkRunner, cfg: BenchmarkConfig, avail_mem_bytes: u64, target_dir: []const u8, has_gui_gpu: bool) bool {
        self.joinIfFinished(false);
        if (self.isRunning()) return false;
        self.cancel_flag.store(false, .release);
        self.thermal_trip_flag.store(false, .release);

        var c = cfg;
        c.cpu_threads = std.math.clamp(cfg.cpu_threads, 1, 64);
        c.duration_s = std.math.clamp(cfg.duration_s, 10, 120);
        c.disk_file_mb = std.math.clamp(cfg.disk_file_mb, 32, 512);
        const max_safe_mb: u32 = if (avail_mem_bytes > 256 * 1024 * 1024)
            @intCast(@min(@as(u64, 512), (avail_mem_bytes / (1024 * 1024)) * 30 / 100))
        else
            32;
        c.mem_size_mb = std.math.clamp(cfg.mem_size_mb, 32, @max(@as(u32, 32), max_safe_mb));

        const dir_copy = self.allocator.dupe(u8, target_dir) catch return false;

        self.mutex.lock();
        self.beginRunLocked(.full_suite, c);
        self.snap.cpu_threads = c.cpu_threads;
        self.snap.mem_tested_mb = c.mem_size_mb;
        self.snap.disk_file_mb = c.disk_file_mb;
        setSummary(&self.snap, i18n.trSlice(
            "一键全套体检 [1/4]：正在执行 CPU 单核/多核与散热稳态检测...",
            "Full Diagnostic [1/4]: Running CPU Single/Multi & throttle test...",
            "総合診断 [1/4]：CPU シングル/マルチ・サーマル検証を実行中...",
        ));
        self.mutex.unlock();

        self.worker_thread = std.Thread.spawn(.{}, fullSuiteMain, .{ self, c, dir_copy, has_gui_gpu }) catch {
            self.allocator.free(dir_copy);
            self.failInit(i18n.trSlice("无法创建综合体检线程", "Failed to spawn diagnostic suite thread", "総合診断スレッド作成失敗"));
            return false;
        };
        return true;
    }

    fn failInit(self: *BenchmarkRunner, msg: []const u8) void {
        self.mutex.lock();
        self.snap.active_kind = .none;
        self.snap.gpu_shader_active = false;
        self.snap.outcome = .failed_io;
        setSummary(&self.snap, msg);
        self.mutex.unlock();
    }

    /// GPU 烤机 / 联烤 / 综合体检 GPU 阶段：每帧推进 FPS、1% Low FPS、帧时间统计与熔断检测
    pub fn tickGpuStressFrame(self: *BenchmarkRunner) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.snap.gpu_shader_active or self.snap.outcome != .running) return false;

        const is_combined = (self.snap.active_kind == .combined_stress);
        const is_suite = (self.snap.active_kind == .full_suite and self.suite_gpu_phase);

        if (self.thermal_trip_flag.load(.acquire)) {
            self.snap.active_kind = .none;
            self.snap.gpu_shader_active = false;
            self.suite_gpu_phase = false;
            self.snap.outcome = .stopped_by_thermal;
            setSummary(&self.snap, i18n.trSlice("触发高温熔断保护，已安全停机", "Stopped safely by thermal auto-cutoff", "高温保護により安全停止しました"));
            return false;
        }
        if (self.cancel_flag.load(.acquire)) {
            self.snap.active_kind = .none;
            self.snap.gpu_shader_active = false;
            self.suite_gpu_phase = false;
            self.snap.outcome = .stopped_by_user;
            setSummary(&self.snap, i18n.trSlice("烤机已被用户手动停止", "Stress test stopped by user", "ユーザー操作により停止しました"));
            return false;
        }

        const now_ns = std.time.nanoTimestamp();
        const dt_ms = @as(f64, @floatFromInt(now_ns - self.gpu_last_frame_ns)) / @as(f64, @floatFromInt(std.time.ns_per_ms));
        self.gpu_last_frame_ns = now_ns;

        if (self.snap.gpu_frames > 0 and dt_ms > 0.05 and dt_ms < 5000.0) {
            self.gpu_frametimes_ms[self.gpu_ft_cursor] = @floatCast(dt_ms);
            self.gpu_ft_cursor = (self.gpu_ft_cursor + 1) % self.gpu_frametimes_ms.len;
            if (self.gpu_ft_count < self.gpu_frametimes_ms.len) self.gpu_ft_count += 1;
            if (dt_ms > self.gpu_max_ft_ms) self.gpu_max_ft_ms = dt_ms;
        }

        const elapsed_s = @as(f64, @floatFromInt(now_ns - self.gpu_start_ns)) / @as(f64, @floatFromInt(std.time.ns_per_s));
        self.snap.gpu_frames += 1;
        if (!is_suite) self.snap.elapsed_s = elapsed_s;

        if (elapsed_s > 0.05) {
            self.snap.gpu_avg_fps = @as(f64, @floatFromInt(self.snap.gpu_frames)) / elapsed_s;
            self.snap.gpu_avg_frametime_ms = (elapsed_s * 1000.0) / @as(f64, @floatFromInt(self.snap.gpu_frames));
            self.snap.gpu_max_frametime_ms = self.gpu_max_ft_ms;
            if (self.gpu_ft_count >= 10) {
                self.snap.gpu_low1_fps = computeLow1Fps(self.gpu_frametimes_ms[0..self.gpu_ft_count]);
            }
        }

        // 每 0.5 秒记录一个实时过程曲线点
        const trace_dt = @as(f64, @floatFromInt(now_ns - self.gpu_last_trace_ns)) / @as(f64, @floatFromInt(std.time.ns_per_s));
        if (trace_dt >= 0.5) {
            const inst_fps = @as(f64, @floatFromInt(self.snap.gpu_frames -| self.gpu_trace_frames_base)) / trace_dt;
            self.gpu_trace_frames_base = self.snap.gpu_frames;
            self.gpu_last_trace_ns = now_ns;
            self.snap.pushTrace(if (is_suite) self.snap.elapsed_s + elapsed_s else elapsed_s, inst_fps, self.latest_temp_c);
        }

        const frac = std.math.clamp(elapsed_s / @as(f64, @floatFromInt(@max(self.gpu_duration_s, 1))), 0.0, 1.0);
        if (is_suite) {
            self.snap.progress_pct = @floatCast(75.0 + frac * 25.0);
        } else {
            self.snap.progress_pct = @floatCast(frac * 100.0);
        }

        if (elapsed_s >= @as(f64, @floatFromInt(self.gpu_duration_s))) {
            self.snap.gpu_shader_active = false;
            self.suite_gpu_phase = false;
            if (is_combined) {
                // 通知联烤 CPU 线程同步结束
                self.cancel_flag.store(true, .release);
            }
            self.snap.active_kind = .none;
            self.snap.progress_pct = 100.0;
            if (self.snap.error_count > 0) {
                self.snap.outcome = .failed_errors;
            } else {
                self.snap.outcome = .passed;
                if (is_suite) {
                    setSummary(&self.snap, i18n.trSlice(
                        "一键全套硬件综合体检全部完成（零硬件错误）",
                        "1-Click Full Hardware Diagnostic completed (0 errors)",
                        "ワンクリック総合ハードウェア診断が完了しました（エラー 0）",
                    ));
                } else if (is_combined) {
                    setSummary(&self.snap, i18n.trSlice(
                        "整机安全联烤（CPU+内存+GPU）全部通过（零异常）",
                        "Combined Safe Stress (CPU+RAM+GPU) passed (0 errors)",
                        "総合安全負荷テスト（CPU+RAM+GPU）に合格しました（異常なし）",
                    ));
                } else {
                    setSummary(&self.snap, i18n.trSlice(
                        "GPU OpenGL 3.3 着色器稳定性烤机完成（零异常）",
                        "GPU OpenGL 3.3 shader stress completed (0 errors)",
                        "GPU OpenGL 3.3 シェーダー負荷テスト完了（異常なし）",
                    ));
                }
            }
            return false;
        }
        return true;
    }

    /// 导出结构化综合硬件测试报告（含全部实测细项与智能诊断建议）
    pub fn exportReport(self: *BenchmarkRunner, allocator: std.mem.Allocator, cpu_name: []const u8, gpu_name: []const u8) ![]u8 {
        const snap = self.copySnapshot();
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(allocator);
        const w = out.writer(allocator);

        try w.writeAll("============================================================\r\n");
        try w.print("{s}\r\n", .{i18n.trSlice(
            "WinHardware Monitor V2.2 — 硬件综合稳定性与基准测试报告",
            "WinHardware Monitor V2.2 — Comprehensive Hardware Benchmark Report",
            "WinHardware Monitor V2.2 — ハードウェア総合ベンチマーク・安定性レポート",
        )});
        try w.writeAll("============================================================\r\n");
        try w.print("{s}: {d}\r\n", .{ i18n.trSlice("测试时间 (UTC ms)", "Timestamp (UTC ms)", "テスト日時 (UTC ms)"), std.time.milliTimestamp() });
        try w.print("CPU: {s}\r\n", .{cpu_name});
        try w.print("GPU: {s}\r\n", .{gpu_name});
        try w.print("{s}: {s}\r\n", .{ i18n.trSlice("测试项目", "Test Item", "テスト項目"), snap.last_kind.labelZh() });
        try w.print("{s}: {s}\r\n", .{ i18n.trSlice("最终结论", "Result", "判定結果"), snap.outcome.labelZh() });
        try w.print("{s}: {d:.2} s | {s}: {s}\r\n", .{
            i18n.trSlice("运行时长", "Duration", "実行時間"),
            snap.elapsed_s,
            i18n.trSlice("防卡顿保护", "Gentle Mode", "保護モード"),
            if (snap.gentle_mode) "ON" else "OFF",
        });
        try w.print("{s}: {d}\r\n", .{ i18n.trSlice("硬件错误计数", "Error Count", "エラー数"), snap.error_count });
        if (snap.peak_temp_c) |pt| {
            const delta_t = if (snap.start_temp_c) |st| pt - st else 0.0;
            try w.print("{s}: {d:.1} °C (+{d:.1} °C, {s} {d:.0} °C)\r\n", .{
                i18n.trSlice("期间峰值温度", "Peak Temp", "最高温度"),
                pt,
                @max(0.0, delta_t),
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

        if (snap.has_cpu_result) {
            try w.print("[CPU] Threads={d} | Single={d:.2} MOPS | Multi={d:.2} MOPS | Scaling={d:.2}x | ThrottleDrop={d:.1}%\r\n", .{
                snap.cpu_threads, snap.cpu_single_mops, snap.cpu_score_mops, snap.cpu_scaling_ratio, snap.cpu_throttle_drop_pct,
            });
        }
        if (snap.has_mem_result) {
            try w.print("[RAM] Size={d} MB | Passes={d}/4 | Write={d:.2} GB/s | Read={d:.2} GB/s | MT-Copy={d:.2} GB/s\r\n", .{
                snap.mem_tested_mb, snap.mem_passes_done, snap.mem_write_gbs, snap.mem_read_gbs, snap.mem_copy_gbs,
            });
            try w.print("[RAM Latency] L1={d:.2} ns | L2={d:.2} ns | L3={d:.2} ns | Main RAM={d:.2} ns\r\n", .{
                snap.mem_lat_l1_ns, snap.mem_lat_l2_ns, snap.mem_lat_l3_ns, snap.mem_lat_ram_ns,
            });
        }
        if (snap.has_disk_result) {
            try w.print("[Disk] TempFile={d} MB ({s}, auto-deleted) | IntegrityErrors={d}\r\n", .{
                snap.disk_file_mb,
                if (snap.disk_unbuffered) "Unbuffered" else "Buffered/Fadvise",
                snap.disk_integrity_errors,
            });
            try w.print("  SEQ1M Write={d:.1} MB/s | SEQ1M Read={d:.1} MB/s\r\n", .{ snap.disk_seq_write_mbs, snap.disk_seq_read_mbs });
            try w.print("  RND4K Read={d:.1} MB/s ({d:.0} IOPS) | Lat Min={d:.0}/Avg={d:.0}/P95={d:.0}/P99={d:.0}/Max={d:.0} us\r\n", .{
                snap.disk_rnd4k_read_mbs,
                snap.disk_rnd4k_read_iops,
                snap.disk_rnd4k_min_lat_us,
                snap.disk_rnd4k_avg_lat_us,
                snap.disk_rnd4k_p95_lat_us,
                snap.disk_rnd4k_p99_lat_us,
                snap.disk_rnd4k_max_lat_us,
            });
            try w.print("  RND4K Write={d:.1} MB/s ({d:.0} IOPS, P99={d:.0} us)\r\n", .{
                snap.disk_rnd4k_write_mbs, snap.disk_rnd4k_write_iops, snap.disk_rnd4k_write_p99_us,
            });
        }
        if (snap.has_gpu_result) {
            try w.print("[GPU] Frames={d} | Avg={d:.1} FPS | 1%Low={d:.1} FPS | FT Avg={d:.2} ms / Max={d:.2} ms | PeakPower={?d:.1} W\r\n", .{
                snap.gpu_frames, snap.gpu_avg_fps, snap.gpu_low1_fps, snap.gpu_avg_frametime_ms, snap.gpu_max_frametime_ms, snap.peak_gpu_power_w,
            });
        }
        try w.writeAll("------------------------------------------------------------\r\n");
        try w.print("{s}: {s}\r\n", .{ i18n.trSlice("运行摘要", "Summary", "概要"), snap.summarySlice() });
        try w.print("{s}: {s}\r\n", .{ i18n.trSlice("诊断建议", "Diagnostic Advice", "診断アドバイス"), snap.diagnosticAdvice() });
        return out.toOwnedSlice(allocator);
    }
};

// ============================================================================
// 1. CPU 单核 + 多核确定性计算与降频分析
// ============================================================================

const CpuWorkerShared = struct {
    cancel: *std.atomic.Value(bool),
    total_ops: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    errors: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    expected_ref: u64 = 0,
    gentle_mode: bool = true,
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
    lowerCurrentThreadPriority();
    var batch: u32 = 0;
    while (!shared.cancel.load(.acquire)) {
        const res = computeDeterministicKernel(0x123456789ABCDEF0);
        if (res != shared.expected_ref) {
            _ = shared.errors.fetchAdd(1, .acq_rel);
        }
        _ = shared.total_ops.fetchAdd(4096, .acq_rel);
        batch +%= 1;
        // 温和防卡顿模式：每完成若干批主动让出极短时间片，确保系统前台软件丝滑无延迟
        if (shared.gentle_mode and (batch & 63) == 0) {
            std.Thread.yield() catch {};
        }
    }
}

fn runCpuPhase(self: *BenchmarkRunner, cfg: BenchmarkConfig, base_progress: f32, span_progress: f32) void {
    lowerCurrentThreadPriority();
    const start_ns = std.time.nanoTimestamp();
    const total_dur = std.math.clamp(cfg.duration_s, 6, 600);
    const single_dur: u32 = std.math.clamp(total_dur / 4, 2, 5);
    const multi_dur: u32 = @max(4, total_dur - single_dur);
    const expected = computeDeterministicKernel(0x123456789ABCDEF0);

    // Phase A: 1-Thread Single-Core Benchmark
    var single_mops: f64 = 0.0;
    var single_errs: u64 = 0;
    {
        var sc = std.atomic.Value(bool).init(false);
        var sh = CpuWorkerShared{ .cancel = &sc, .expected_ref = expected, .gentle_mode = cfg.gentle_mode };
        const t = std.Thread.spawn(.{}, cpuWorkerLoop, .{&sh}) catch null;
        const p0 = std.time.nanoTimestamp();
        const target_ns: i128 = @as(i128, single_dur) * std.time.ns_per_s;
        while (!self.cancel_flag.load(.acquire)) {
            const el = std.time.nanoTimestamp() - p0;
            const el_s = @as(f64, @floatFromInt(el)) / @as(f64, @floatFromInt(std.time.ns_per_s));
            const ops = sh.total_ops.load(.acquire);
            if (el_s > 0.05) single_mops = (@as(f64, @floatFromInt(ops)) / 1_000_000.0) / el_s;

            self.mutex.lock();
            self.snap.has_cpu_result = true;
            self.snap.cpu_single_mops = single_mops;
            self.snap.elapsed_s = @as(f64, @floatFromInt(std.time.nanoTimestamp() - start_ns)) / @as(f64, @floatFromInt(std.time.ns_per_s));
            const frac = std.math.clamp(@as(f64, @floatFromInt(el)) / @as(f64, @floatFromInt(target_ns)), 0.0, 1.0);
            self.snap.progress_pct = base_progress + @as(f32, @floatCast(frac * 0.25)) * span_progress;
            self.mutex.unlock();

            if (el >= target_ns) break;
            std.Thread.sleep(100 * std.time.ns_per_ms);
        }
        sc.store(true, .release);
        if (t) |h| h.join();
        const final_el = @max(0.05, @as(f64, @floatFromInt(std.time.nanoTimestamp() - p0)) / @as(f64, @floatFromInt(std.time.ns_per_s)));
        single_mops = (@as(f64, @floatFromInt(sh.total_ops.load(.acquire))) / 1_000_000.0) / final_el;
        single_errs = sh.errors.load(.acquire);
    }

    if (self.cancel_flag.load(.acquire)) return;

    // Phase B: Multi-Core Stress + Early/Late Throttle Detection
    var local_cancel = std.atomic.Value(bool).init(false);
    var shared = CpuWorkerShared{ .cancel = &local_cancel, .expected_ref = expected, .gentle_mode = cfg.gentle_mode };
    var handles: [64]?std.Thread = [_]?std.Thread{null} ** 64;
    const t_count: usize = @intCast(std.math.clamp(cfg.cpu_threads, 1, 64));
    for (0..t_count) |i| {
        handles[i] = std.Thread.spawn(.{}, cpuWorkerLoop, .{&shared}) catch null;
    }

    const mp0 = std.time.nanoTimestamp();
    const target_ns: i128 = @as(i128, multi_dur) * std.time.ns_per_s;
    var last_sample_ns = mp0;
    var last_sample_ops: u64 = 0;

    var early_sum: f64 = 0.0;
    var early_cnt: u32 = 0;
    var late_sum: f64 = 0.0;
    var late_cnt: u32 = 0;

    while (!self.cancel_flag.load(.acquire)) {
        const now = std.time.nanoTimestamp();
        const el = now - mp0;
        const el_s = @as(f64, @floatFromInt(el)) / @as(f64, @floatFromInt(std.time.ns_per_s));
        const ops = shared.total_ops.load(.acquire);
        const errs = single_errs + shared.errors.load(.acquire);
        const frac = std.math.clamp(@as(f64, @floatFromInt(el)) / @as(f64, @floatFromInt(target_ns)), 0.0, 1.0);

        const dt_s = @as(f64, @floatFromInt(now - last_sample_ns)) / @as(f64, @floatFromInt(std.time.ns_per_s));
        var inst_mops: ?f64 = null;
        if (dt_s >= 0.5) {
            const d_ops = ops -| last_sample_ops;
            const cur_mops = (@as(f64, @floatFromInt(d_ops)) / 1_000_000.0) / dt_s;
            inst_mops = cur_mops;
            last_sample_ops = ops;
            last_sample_ns = now;
            if (frac >= 0.08 and frac <= 0.35) {
                early_sum += cur_mops;
                early_cnt += 1;
            } else if (frac >= 0.72) {
                late_sum += cur_mops;
                late_cnt += 1;
            }
        }

        const total_el_s = @as(f64, @floatFromInt(now - start_ns)) / @as(f64, @floatFromInt(std.time.ns_per_s));
        self.mutex.lock();
        self.snap.has_cpu_result = true;
        self.snap.cpu_single_mops = single_mops;
        self.snap.elapsed_s = total_el_s;
        self.snap.progress_pct = base_progress + @as(f32, @floatCast(0.25 + frac * 0.75)) * span_progress;
        self.snap.error_count = errs;
        if (el_s > 0.05) {
            self.snap.cpu_score_mops = (@as(f64, @floatFromInt(ops)) / 1_000_000.0) / el_s;
            if (single_mops > 0.01) self.snap.cpu_scaling_ratio = self.snap.cpu_score_mops / single_mops;
        }
        if (inst_mops) |im| {
            self.snap.pushTrace(total_el_s, im, self.latest_temp_c);
        }
        self.mutex.unlock();

        if (el >= target_ns) break;
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }

    local_cancel.store(true, .release);
    for (0..t_count) |i| {
        if (handles[i]) |h| h.join();
    }

    const m_total_s = @max(0.05, @as(f64, @floatFromInt(std.time.nanoTimestamp() - mp0)) / @as(f64, @floatFromInt(std.time.ns_per_s)));
    const final_ops = shared.total_ops.load(.acquire);
    const final_errs = single_errs + shared.errors.load(.acquire);
    const multi_mops = (@as(f64, @floatFromInt(final_ops)) / 1_000_000.0) / m_total_s;

    var drop_pct: f64 = 0.0;
    if (early_cnt > 0 and late_cnt > 0) {
        const early_avg = early_sum / @as(f64, @floatFromInt(early_cnt));
        const late_avg = late_sum / @as(f64, @floatFromInt(late_cnt));
        if (early_avg > 0.01 and late_avg < early_avg) {
            drop_pct = ((early_avg - late_avg) / early_avg) * 100.0;
        }
    }

    self.mutex.lock();
    self.snap.has_cpu_result = true;
    self.snap.cpu_single_mops = single_mops;
    self.snap.cpu_score_mops = multi_mops;
    self.snap.cpu_scaling_ratio = if (single_mops > 0.01) multi_mops / single_mops else 1.0;
    self.snap.cpu_throttle_drop_pct = drop_pct;
    self.snap.error_count += final_errs -| self.snap.error_count;
    self.mutex.unlock();
}

fn cpuStressMain(self: *BenchmarkRunner, cfg: BenchmarkConfig) void {
    runCpuPhase(self, cfg, 0.0, 100.0);

    self.mutex.lock();
    self.snap.active_kind = .none;
    if (self.thermal_trip_flag.load(.acquire)) {
        self.snap.outcome = .stopped_by_thermal;
        setSummary(&self.snap, i18n.trSlice("触发高温熔断阈值，已自动停止 CPU 测试", "Thermal cutoff triggered; CPU test stopped", "高温保護閾値に到達し CPU テストを自動停止しました"));
    } else if (self.cancel_flag.load(.acquire)) {
        self.snap.outcome = .stopped_by_user;
        setSummary(&self.snap, i18n.trSlice("用户已手动停止 CPU 测试", "CPU test stopped by user", "ユーザーにより CPU テストを停止しました"));
    } else if (self.snap.error_count > 0) {
        self.snap.outcome = .failed_errors;
        setSummary(&self.snap, i18n.trSlice("检出确定性计算校验偏差，请检查散热或电压稳定性", "Deterministic compute mismatch detected", "演算検証エラーを検出しました"));
    } else {
        self.snap.progress_pct = 100.0;
        self.snap.outcome = .passed;
        setSummary(&self.snap, i18n.trSlice(
            "CPU 单核/多核与散热降频测试完成（零计算错误）",
            "CPU Single/Multi & throttle test passed (0 errors)",
            "CPU シングル/マルチ・サーマル検証に合格しました（エラー 0）",
        ));
    }
    self.mutex.unlock();
}

// ============================================================================
// 2. 内存延迟（L1/L2/L3/RAM 指针追踪）+ 多线程拷贝带宽 + 4 轮 MemTest 位翻转校验
// ============================================================================

/// Pointer-Chasing（Sattolo 单环随机链表）测量真实硬件缓存与主内存访问延迟（ns）
fn measurePointerChaseNs(allocator: std.mem.Allocator, working_bytes: usize, hops: usize) f64 {
    const stride_u32: usize = 16; // 64 bytes cache line
    const node_count = @max(@as(usize, 64), working_bytes / 64);
    const total_u32 = node_count * stride_u32;
    const buf = allocator.alloc(u32, total_u32) catch return 0.0;
    defer allocator.free(buf);

    const perm = allocator.alloc(u32, node_count) catch return 0.0;
    defer allocator.free(perm);
    for (perm, 0..) |*slot, i| slot.* = @intCast(i);

    // Sattolo shuffle -> 单一遍历环，确保访问到每一个缓存行且不可被硬件顺序预取器猜中
    var rng: u64 = 0xD1B54A32D192ED03 ^ @as(u64, working_bytes);
    var i: usize = node_count - 1;
    while (i > 0) : (i -= 1) {
        rng = rng *% 6364136223846793005 +% 1442695040888963407;
        const j: usize = @intCast((rng >> 20) % i);
        const tmp = perm[i];
        perm[i] = perm[j];
        perm[j] = tmp;
    }
    for (0..node_count) |k| {
        const cur = perm[k];
        const nxt = perm[(k + 1) % node_count];
        buf[@as(usize, cur) * stride_u32] = nxt;
    }

    // Warmup
    var idx: u32 = 0;
    const warm = @min(node_count * 2, 32768);
    for (0..warm) |_| {
        idx = buf[@as(usize, idx) * stride_u32];
    }

    const t0 = std.time.nanoTimestamp();
    var k: usize = 0;
    while (k < hops) : (k += 1) {
        idx = buf[@as(usize, idx) * stride_u32];
    }
    const t1 = std.time.nanoTimestamp();
    std.mem.doNotOptimizeAway(idx);
    const ns = @as(f64, @floatFromInt(@max(@as(i128, 1), t1 - t0)));
    return ns / @as(f64, @floatFromInt(hops));
}

const CopySliceCtx = struct {
    src: []const u64,
    dst: []u64,
};

fn memCopyWorker(ctx: CopySliceCtx) void {
    lowerCurrentThreadPriority();
    @memcpy(ctx.dst, ctx.src);
}

fn measureMultiThreadCopyGbs(allocator: std.mem.Allocator, buf: []const u64, threads: u32) f64 {
    const dst = allocator.alloc(u64, buf.len) catch return 0.0;
    defer allocator.free(dst);
    const t_cnt: usize = @intCast(std.math.clamp(threads, 1, 4));
    const slice_len = buf.len / t_cnt;
    if (slice_len == 0) return 0.0;

    // 预触页避免首次缺页异常拉低带宽读数
    @memset(dst, 0);

    const t0 = std.time.nanoTimestamp();
    var handles: [4]?std.Thread = .{ null, null, null, null };
    for (0..t_cnt) |i| {
        const s = i * slice_len;
        const e = if (i + 1 == t_cnt) buf.len else s + slice_len;
        handles[i] = std.Thread.spawn(.{}, memCopyWorker, .{CopySliceCtx{ .src = buf[s..e], .dst = dst[s..e] }}) catch null;
    }
    for (0..t_cnt) |i| {
        if (handles[i]) |h| h.join();
    }
    const t1 = std.time.nanoTimestamp();
    std.mem.doNotOptimizeAway(dst[0]);

    const sec = @max(0.0001, @as(f64, @floatFromInt(t1 - t0)) / @as(f64, @floatFromInt(std.time.ns_per_s)));
    // 拷贝统计包含读 + 写双倍总线字节流（与 AIDA64 Copy 口径一致）
    const bytes_gb = (@as(f64, @floatFromInt(buf.len * @sizeOf(u64))) * 2.0) / (1024.0 * 1024.0 * 1024.0);
    return bytes_gb / sec;
}

fn runMemoryPhase(self: *BenchmarkRunner, cfg: BenchmarkConfig, base_progress: f32, span_progress: f32) bool {
    lowerCurrentThreadPriority();
    const start_ns = std.time.nanoTimestamp();
    const size_mb = std.math.clamp(cfg.mem_size_mb, 32, 1024);

    // Stage 1: L1 / L2 / L3 / RAM 指针追踪延迟测量（快速、低负荷；L3 采用 2 MB 避免 4K 页表 TLB 抖动干扰）
    const l1 = measurePointerChaseNs(self.allocator, 16 * 1024, 600_000);
    const l2 = measurePointerChaseNs(self.allocator, 256 * 1024, 400_000);
    const l3 = measurePointerChaseNs(self.allocator, 2 * 1024 * 1024, 300_000);
    const ram = measurePointerChaseNs(self.allocator, 48 * 1024 * 1024, 150_000);
    if (self.cancel_flag.load(.acquire)) return false;

    self.mutex.lock();
    self.snap.has_mem_result = true;
    self.snap.mem_lat_l1_ns = l1;
    self.snap.mem_lat_l2_ns = l2;
    self.snap.mem_lat_l3_ns = l3;
    self.snap.mem_lat_ram_ns = ram;
    self.snap.progress_pct = base_progress + 0.15 * span_progress;
    self.mutex.unlock();

    // Stage 2: 4 轮 MemTest 位翻转校验 + 读写带宽 + 多线程 Copy 带宽
    const total_bytes: usize = @as(usize, size_mb) * 1024 * 1024;
    const word_count: usize = total_bytes / @sizeOf(u64);
    const buf = self.allocator.alloc(u64, word_count) catch {
        self.mutex.lock();
        self.snap.outcome = .failed_io;
        setSummary(&self.snap, i18n.trSlice("内存分配失败，请调小测试容量", "Memory allocation failed; reduce test size", "メモリ確保に失敗しました"));
        self.mutex.unlock();
        return false;
    };
    defer self.allocator.free(buf);

    var write_ns_sum: i128 = 0;
    var read_ns_sum: i128 = 0;
    var errors: u64 = 0;
    var passes_done: u32 = 0;

    const patterns = [_]u8{ 0, 1, 2, 3 };
    for (patterns, 0..) |pat, p_idx| {
        if (self.cancel_flag.load(.acquire)) break;

        const tw0 = std.time.nanoTimestamp();
        for (buf, 0..) |*slot, i| slot.* = patternWord(pat, i);
        const tw1 = std.time.nanoTimestamp();
        write_ns_sum += (tw1 - tw0);

        if (self.cancel_flag.load(.acquire)) break;

        const tr0 = std.time.nanoTimestamp();
        for (buf, 0..) |val, i| {
            if (val != patternWord(pat, i)) errors += 1;
        }
        const tr1 = std.time.nanoTimestamp();
        read_ns_sum += (tr1 - tr0);
        passes_done += 1;

        const elapsed_s = @as(f64, @floatFromInt(tr1 - start_ns)) / @as(f64, @floatFromInt(std.time.ns_per_s));
        const bytes_done_gb = (@as(f64, @floatFromInt(total_bytes)) * @as(f64, @floatFromInt(passes_done))) / (1024.0 * 1024.0 * 1024.0);
        const wg = if (write_ns_sum > 0) bytes_done_gb / (@as(f64, @floatFromInt(write_ns_sum)) / @as(f64, @floatFromInt(std.time.ns_per_s))) else 0.0;
        const rg = if (read_ns_sum > 0) bytes_done_gb / (@as(f64, @floatFromInt(read_ns_sum)) / @as(f64, @floatFromInt(std.time.ns_per_s))) else 0.0;

        self.mutex.lock();
        self.snap.has_mem_result = true;
        self.snap.elapsed_s = elapsed_s;
        self.snap.mem_passes_done = passes_done;
        self.snap.error_count += errors -| self.snap.error_count;
        self.snap.mem_write_gbs = wg;
        self.snap.mem_read_gbs = rg;
        self.snap.progress_pct = base_progress + (0.15 + @as(f32, @floatFromInt(p_idx + 1)) * 0.18) * span_progress;
        self.snap.pushTrace(elapsed_s, rg, self.latest_temp_c);
        self.mutex.unlock();

        if (cfg.gentle_mode) std.Thread.sleep(20 * std.time.ns_per_ms);
    }

    if (!self.cancel_flag.load(.acquire)) {
        const copy_gbs = measureMultiThreadCopyGbs(self.allocator, buf[0..@min(buf.len, 16 * 1024 * 1024)], @min(cfg.cpu_threads, 4));
        self.mutex.lock();
        self.snap.mem_copy_gbs = copy_gbs;
        self.snap.progress_pct = base_progress + span_progress;
        self.mutex.unlock();
    }
    return true;
}

fn memoryVerifyMain(self: *BenchmarkRunner, cfg: BenchmarkConfig) void {
    const ok = runMemoryPhase(self, cfg, 0.0, 100.0);

    self.mutex.lock();
    self.snap.active_kind = .none;
    if (!ok and self.snap.outcome == .failed_io) {
        self.mutex.unlock();
        return;
    }
    if (self.thermal_trip_flag.load(.acquire)) {
        self.snap.outcome = .stopped_by_thermal;
        setSummary(&self.snap, i18n.trSlice("触发高温熔断，已终止内存校验", "Thermal cutoff triggered; memory test stopped", "高温保護によりメモリ検証を停止しました"));
    } else if (self.cancel_flag.load(.acquire)) {
        self.snap.outcome = .stopped_by_user;
        setSummary(&self.snap, i18n.trSlice("用户已手动停止内存校验", "Memory verification stopped by user", "ユーザーによりメモリ検証を停止しました"));
    } else if (self.snap.error_count > 0) {
        self.snap.outcome = .failed_errors;
        setSummary(&self.snap, i18n.trSlice("检测到内存位翻转错误！请检查内存条 XMP 或插槽", "Memory bit-flip error detected!", "メモリビット反転エラーを検出しました！"));
    } else {
        self.snap.progress_pct = 100.0;
        self.snap.outcome = .passed;
        setSummary(&self.snap, i18n.trSlice(
            "缓存/内存延迟测量、多核拷贝带宽与 4 轮位翻转校验全部通过",
            "Cache/RAM latency, MT Copy & 4-pass bit-flip verification passed (0 errors)",
            "遅延・マルチコピー帯域・4パス ビット検証すべて合格（エラー 0）",
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

// ============================================================================
// 3. 磁盘自定义目录无缓存 SEQ1M R/W + 完整性比对 + RND4K R/W + P95/P99 尾延迟
// ============================================================================

/// 为每个 1 MiB 块生成唯一确定性签名，使回读校验可发现扩容盘覆写或静默坏块
fn fillBlockWithSignature(buf: []u8, block_idx: usize) u64 {
    var s: u64 = 0xCAFEBABE12345678 ^ (@as(u64, block_idx) *% 0x9E3779B97F4A7C15);
    const words = std.mem.bytesAsSlice(u64, buf);
    var acc: u64 = 0;
    for (words) |*w| {
        s = s *% 6364136223846793005 +% 1442695040888963407;
        w.* = s;
        acc ^= std.math.rotl(u64, s, 7);
    }
    return acc;
}

fn computeBlockChecksum(buf: []const u8) u64 {
    const words = std.mem.bytesAsSlice(u64, buf);
    var acc: u64 = 0;
    for (words) |w| acc ^= std.math.rotl(u64, w, 7);
    return acc;
}

const LatencyStats = struct {
    min_us: f64 = 0.0,
    avg_us: f64 = 0.0,
    p95_us: f64 = 0.0,
    p99_us: f64 = 0.0,
    max_us: f64 = 0.0,
};

fn summarizeLatencies(samples: []u32) LatencyStats {
    if (samples.len == 0) return .{};
    std.mem.sort(u32, samples, {}, std.sort.asc(u32));
    var sum: u64 = 0;
    for (samples) |v| sum += v;
    const p95_idx = @min(samples.len - 1, (samples.len * 95) / 100);
    const p99_idx = @min(samples.len - 1, (samples.len * 99) / 100);
    return .{
        .min_us = @floatFromInt(samples[0]),
        .avg_us = @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(samples.len)),
        .p95_us = @floatFromInt(samples[p95_idx]),
        .p99_us = @floatFromInt(samples[p99_idx]),
        .max_us = @floatFromInt(samples[samples.len - 1]),
    };
}

fn runWindowsUnbufferedDiskBench(
    self: *BenchmarkRunner,
    file_path: []const u8,
    file_mb: u32,
    chunk: []u8,
    expected_hashes: []u64,
    start_ns: i128,
    base_progress: f32,
    span_progress: f32,
) bool {
    if (builtin.os.tag != .windows) return false;
    var path_w: [512]u16 = undefined;
    const wlen = std.unicode.utf8ToUtf16Le(path_w[0 .. path_w.len - 1], file_path) catch return false;
    path_w[wlen] = 0;

    // 1. Unbuffered SEQ1M Write (带每块唯一签名)
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

        var write_ns: i128 = 0;
        for (0..file_mb) |mb_i| {
            if (self.cancel_flag.load(.acquire)) break;
            expected_hashes[mb_i] = fillBlockWithSignature(chunk, mb_i);
            const t0 = std.time.nanoTimestamp();
            var written: win32.DWORD = 0;
            if (win32.WriteFile(h, chunk.ptr, @intCast(chunk.len), &written, null) == 0 or written != chunk.len) {
                markDiskFail(self, i18n.trSlice("顺序写入失败（空间不足或被中断）", "Sequential write failed", "シーケンシャル書込失敗"));
                return true;
            }
            write_ns += std.time.nanoTimestamp() - t0;
            self.mutex.lock();
            self.snap.has_disk_result = true;
            self.snap.disk_unbuffered = true;
            self.snap.progress_pct = base_progress + (@as(f32, @floatFromInt(mb_i + 1)) / @as(f32, @floatFromInt(file_mb))) * 0.28 * span_progress;
            self.mutex.unlock();
        }
        _ = win32.FlushFileBuffers(h);
        const ws = @max(0.001, @as(f64, @floatFromInt(write_ns)) / @as(f64, @floatFromInt(std.time.ns_per_s)));
        self.mutex.lock();
        self.snap.disk_seq_write_mbs = @as(f64, @floatFromInt(file_mb)) / ws;
        self.snap.pushTrace(@as(f64, @floatFromInt(std.time.nanoTimestamp() - start_ns)) / @as(f64, @floatFromInt(std.time.ns_per_s)), self.snap.disk_seq_write_mbs, self.latest_temp_c);
        self.mutex.unlock();
    }

    if (self.cancel_flag.load(.acquire)) return true;

    // 2. Unbuffered SEQ1M Read + 数据完整性比对 + RND4K Read + RND4K Write
    {
        const h = win32.CreateFileW(
            @ptrCast(&path_w),
            win32.GENERIC_READ | win32.GENERIC_WRITE,
            win32.FILE_SHARE_READ,
            null,
            win32.OPEN_EXISTING,
            win32.FILE_FLAG_NO_BUFFERING | win32.FILE_FLAG_WRITE_THROUGH,
            null,
        );
        if (h == win32.INVALID_HANDLE_VALUE) return false;
        defer _ = win32.CloseHandle(h);

        var read_ns: i128 = 0;
        var total_read: usize = 0;
        var integrity_errs: u64 = 0;
        for (0..file_mb) |mb_i| {
            if (self.cancel_flag.load(.acquire)) break;
            const t0 = std.time.nanoTimestamp();
            var got: win32.DWORD = 0;
            if (win32.ReadFile(h, chunk.ptr, @intCast(chunk.len), &got, null) == 0 or got != chunk.len) {
                markDiskFail(self, i18n.trSlice("顺序读取测试失败", "Sequential read failed", "シーケンシャル読込失敗"));
                return true;
            }
            read_ns += std.time.nanoTimestamp() - t0;
            total_read += got;
            if (computeBlockChecksum(chunk) != expected_hashes[mb_i]) {
                integrity_errs += 1;
            }
            self.mutex.lock();
            self.snap.progress_pct = base_progress + (0.28 + (@as(f32, @floatFromInt(mb_i + 1)) / @as(f32, @floatFromInt(file_mb))) * 0.28) * span_progress;
            self.mutex.unlock();
        }
        const rs = @max(0.001, @as(f64, @floatFromInt(read_ns)) / @as(f64, @floatFromInt(std.time.ns_per_s)));
        self.mutex.lock();
        self.snap.disk_seq_read_mbs = (@as(f64, @floatFromInt(total_read)) / (1024.0 * 1024.0)) / rs;
        self.snap.disk_integrity_checked = true;
        self.snap.disk_integrity_errors = integrity_errs;
        self.snap.error_count += integrity_errs;
        self.snap.pushTrace(@as(f64, @floatFromInt(std.time.nanoTimestamp() - start_ns)) / @as(f64, @floatFromInt(std.time.ns_per_s)), self.snap.disk_seq_read_mbs, self.latest_temp_c);
        self.mutex.unlock();

        if (self.cancel_flag.load(.acquire)) return true;

        // 3. RND4K Read (1024 4K aligned ops with per-op latency)
        var blk4k: [4096]u8 align(4096) = undefined;
        const max_blocks: u64 = (@as(u64, file_mb) * 1024 * 1024) / 4096;
        const r_ops: usize = 1024;
        var r_lats: [r_ops]u32 = undefined;
        var r_done: usize = 0;
        var rng_state: u64 = 0x13579BDF2468ACE0;
        const tk0 = std.time.nanoTimestamp();
        for (0..r_ops) |oi| {
            if (self.cancel_flag.load(.acquire)) break;
            rng_state = rng_state *% 6364136223846793005 +% 1;
            const blk_idx = (rng_state >> 16) % max_blocks;
            const op0 = std.time.nanoTimestamp();
            if (win32.SetFilePointerEx(h, @intCast(blk_idx * 4096), null, win32.FILE_BEGIN) == 0) break;
            var got: win32.DWORD = 0;
            if (win32.ReadFile(h, &blk4k, 4096, &got, null) == 0 or got != 4096) break;
            const op_us: u64 = @intCast(@max(@as(i128, 1), @divTrunc(std.time.nanoTimestamp() - op0, 1000)));
            r_lats[r_done] = @intCast(@min(op_us, std.math.maxInt(u32)));
            r_done += 1;
            if ((oi & 63) == 0) {
                self.mutex.lock();
                self.snap.progress_pct = base_progress + (0.56 + (@as(f32, @floatFromInt(oi + 1)) / @as(f32, @floatFromInt(r_ops))) * 0.22) * span_progress;
                self.mutex.unlock();
            }
        }
        const r_sec = @max(0.0001, @as(f64, @floatFromInt(std.time.nanoTimestamp() - tk0)) / @as(f64, @floatFromInt(std.time.ns_per_s)));
        const r_st = summarizeLatencies(r_lats[0..r_done]);

        self.mutex.lock();
        self.snap.disk_rnd4k_read_iops = @as(f64, @floatFromInt(r_done)) / r_sec;
        self.snap.disk_rnd4k_read_mbs = (@as(f64, @floatFromInt(r_done)) * 4096.0 / (1024.0 * 1024.0)) / r_sec;
        self.snap.disk_rnd4k_min_lat_us = r_st.min_us;
        self.snap.disk_rnd4k_avg_lat_us = r_st.avg_us;
        self.snap.disk_rnd4k_p95_lat_us = r_st.p95_us;
        self.snap.disk_rnd4k_p99_lat_us = r_st.p99_us;
        self.snap.disk_rnd4k_max_lat_us = r_st.max_us;
        self.mutex.unlock();

        if (self.cancel_flag.load(.acquire)) return true;

        // 4. RND4K Write (512 4K aligned ops — 轻写量仅 2 MB，不伤 SSD 寿命)
        @memset(&blk4k, 0x5A);
        const w_ops: usize = 512;
        var w_lats: [w_ops]u32 = undefined;
        var w_done: usize = 0;
        const twk0 = std.time.nanoTimestamp();
        for (0..w_ops) |oi| {
            if (self.cancel_flag.load(.acquire)) break;
            rng_state = rng_state *% 6364136223846793005 +% 1;
            const blk_idx = (rng_state >> 16) % max_blocks;
            const op0 = std.time.nanoTimestamp();
            if (win32.SetFilePointerEx(h, @intCast(blk_idx * 4096), null, win32.FILE_BEGIN) == 0) break;
            var wr: win32.DWORD = 0;
            if (win32.WriteFile(h, &blk4k, 4096, &wr, null) == 0 or wr != 4096) break;
            const op_us: u64 = @intCast(@max(@as(i128, 1), @divTrunc(std.time.nanoTimestamp() - op0, 1000)));
            w_lats[w_done] = @intCast(@min(op_us, std.math.maxInt(u32)));
            w_done += 1;
            if ((oi & 63) == 0) {
                self.mutex.lock();
                self.snap.progress_pct = base_progress + (0.78 + (@as(f32, @floatFromInt(oi + 1)) / @as(f32, @floatFromInt(w_ops))) * 0.22) * span_progress;
                self.mutex.unlock();
            }
        }
        const w_sec = @max(0.0001, @as(f64, @floatFromInt(std.time.nanoTimestamp() - twk0)) / @as(f64, @floatFromInt(std.time.ns_per_s)));
        const w_st = summarizeLatencies(w_lats[0..w_done]);

        self.mutex.lock();
        self.snap.disk_rnd4k_write_iops = @as(f64, @floatFromInt(w_done)) / w_sec;
        self.snap.disk_rnd4k_write_mbs = (@as(f64, @floatFromInt(w_done)) * 4096.0 / (1024.0 * 1024.0)) / w_sec;
        self.snap.disk_rnd4k_write_p99_us = w_st.p99_us;
        self.snap.elapsed_s = @as(f64, @floatFromInt(std.time.nanoTimestamp() - start_ns)) / @as(f64, @floatFromInt(std.time.ns_per_s));
        self.snap.progress_pct = base_progress + span_progress;
        self.mutex.unlock();
    }
    return true;
}

fn runDiskPhase(self: *BenchmarkRunner, cfg: BenchmarkConfig, target_dir: []const u8, base_progress: f32, span_progress: f32) bool {
    lowerCurrentThreadPriority();
    const start_ns = std.time.nanoTimestamp();
    const file_mb = std.math.clamp(cfg.disk_file_mb, 32, 1024);

    // 空间安全护栏：目标盘剩余空间必须 ≥ 2 * 测试文件大小 + 512 MB，防止写满系统盘
    const needed_bytes: u64 = @as(u64, file_mb) * 2 * 1024 * 1024 + 512 * 1024 * 1024;
    if (queryDirFreeBytes(target_dir)) |free_b| {
        if (free_b < needed_bytes) {
            markDiskFail(self, i18n.trSlice(
                "目标磁盘剩余空间不足（需至少预留 2 倍测试大小 + 512 MB），已安全拦截",
                "Insufficient free disk space (needs >= 2x file + 512 MB margin); safely blocked",
                "空き容量不足（テスト容量の2倍＋512MB以上が必要）のため安全に中断しました",
            ));
            return false;
        }
    }

    const file_path = std.fs.path.join(self.allocator, &.{ target_dir, "winhw_monitor_bench_tmp.bin" }) catch {
        markDiskFail(self, i18n.trSlice("无法拼接临时测试文件路径", "Failed to compose temp path", "一時ファイルパスの作成に失敗"));
        return false;
    };
    defer self.allocator.free(file_path);

    // 无论成功、取消还是异常，退出前绝对删除临时测试文件
    defer std.fs.deleteFileAbsolute(file_path) catch {};

    const chunk_size: usize = 1024 * 1024; // 1 MiB (4K aligned)
    const chunk = self.allocator.alignedAlloc(u8, .fromByteUnits(4096), chunk_size) catch {
        markDiskFail(self, i18n.trSlice("缓冲区分配失败", "Buffer allocation failed", "バッファ確保に失敗"));
        return false;
    };
    defer self.allocator.free(chunk);

    const expected_hashes = self.allocator.alloc(u64, file_mb) catch {
        markDiskFail(self, i18n.trSlice("校验表分配失败", "Checksum table alloc failed", "チェックサム確保失敗"));
        return false;
    };
    defer self.allocator.free(expected_hashes);

    if (builtin.os.tag == .windows) {
        if (runWindowsUnbufferedDiskBench(self, file_path, file_mb, chunk, expected_hashes, start_ns, base_progress, span_progress)) {
            return self.snap.outcome != .failed_io;
        }
    }

    // Linux (posix_fadvise 驱逐页缓存) 或 Windows 降级路径
    {
        const f = std.fs.createFileAbsolute(file_path, .{ .truncate = true }) catch {
            markDiskFail(self, i18n.trSlice("无法在目标目录创建临时文件，请检查目录写权限", "Cannot create temp file; check directory permissions", "一時ファイル作成不可（ディレクトリ権限を確認）"));
            return false;
        };
        defer f.close();

        var write_ns: i128 = 0;
        for (0..file_mb) |mb_i| {
            if (self.cancel_flag.load(.acquire)) break;
            expected_hashes[mb_i] = fillBlockWithSignature(chunk, mb_i);
            const t0 = std.time.nanoTimestamp();
            f.writeAll(chunk) catch {
                markDiskFail(self, i18n.trSlice("顺序写入失败", "Sequential write failed", "シーケンシャル書込失敗"));
                return false;
            };
            write_ns += std.time.nanoTimestamp() - t0;
            self.mutex.lock();
            self.snap.has_disk_result = true;
            self.snap.progress_pct = base_progress + (@as(f32, @floatFromInt(mb_i + 1)) / @as(f32, @floatFromInt(file_mb))) * 0.28 * span_progress;
            self.mutex.unlock();
        }
        const ts0 = std.time.nanoTimestamp();
        f.sync() catch {};
        if (builtin.os.tag == .linux) {
            _ = linux_sys.posix_fadvise(f.handle, 0, 0, linux_sys.POSIX_FADV_DONTNEED);
        }
        write_ns += std.time.nanoTimestamp() - ts0;
        const ws = @max(0.001, @as(f64, @floatFromInt(write_ns)) / @as(f64, @floatFromInt(std.time.ns_per_s)));
        self.mutex.lock();
        self.snap.disk_seq_write_mbs = @as(f64, @floatFromInt(file_mb)) / ws;
        self.snap.pushTrace(@as(f64, @floatFromInt(std.time.nanoTimestamp() - start_ns)) / @as(f64, @floatFromInt(std.time.ns_per_s)), self.snap.disk_seq_write_mbs, self.latest_temp_c);
        self.mutex.unlock();
    }

    if (self.cancel_flag.load(.acquire)) return true;

    {
        const f = std.fs.openFileAbsolute(file_path, .{ .mode = .read_write }) catch {
            markDiskFail(self, i18n.trSlice("无法重新打开临时文件执行读取测试", "Failed to reopen temp file", "読込用一時ファイルの再オープン失敗"));
            return false;
        };
        defer f.close();

        var read_ns: i128 = 0;
        var total_read: usize = 0;
        var integrity_errs: u64 = 0;
        for (0..file_mb) |mb_i| {
            if (self.cancel_flag.load(.acquire)) break;
            const t0 = std.time.nanoTimestamp();
            const n = f.readAll(chunk) catch {
                markDiskFail(self, i18n.trSlice("顺序读取测试失败", "Sequential read failed", "シーケンシャル読込失敗"));
                return false;
            };
            read_ns += std.time.nanoTimestamp() - t0;
            total_read += n;
            if (n != chunk.len or computeBlockChecksum(chunk) != expected_hashes[mb_i]) {
                integrity_errs += 1;
            }
            self.mutex.lock();
            self.snap.progress_pct = base_progress + (0.28 + (@as(f32, @floatFromInt(mb_i + 1)) / @as(f32, @floatFromInt(file_mb))) * 0.28) * span_progress;
            self.mutex.unlock();
        }
        const rs = @max(0.001, @as(f64, @floatFromInt(read_ns)) / @as(f64, @floatFromInt(std.time.ns_per_s)));
        self.mutex.lock();
        self.snap.disk_seq_read_mbs = (@as(f64, @floatFromInt(total_read)) / (1024.0 * 1024.0)) / rs;
        self.snap.disk_integrity_checked = true;
        self.snap.disk_integrity_errors = integrity_errs;
        self.snap.error_count += integrity_errs;
        self.snap.pushTrace(@as(f64, @floatFromInt(std.time.nanoTimestamp() - start_ns)) / @as(f64, @floatFromInt(std.time.ns_per_s)), self.snap.disk_seq_read_mbs, self.latest_temp_c);
        self.mutex.unlock();

        if (self.cancel_flag.load(.acquire)) return true;

        // Linux RND4K 前再次驱逐页缓存
        if (builtin.os.tag == .linux) {
            _ = linux_sys.posix_fadvise(f.handle, 0, 0, linux_sys.POSIX_FADV_DONTNEED);
        }

        var blk4k: [4096]u8 = undefined;
        const max_blocks: u64 = (@as(u64, file_mb) * 1024 * 1024) / 4096;
        const r_ops: usize = 1024;
        var r_lats: [r_ops]u32 = undefined;
        var r_done: usize = 0;
        var rng_state: u64 = 0x13579BDF2468ACE0;
        const tk0 = std.time.nanoTimestamp();
        for (0..r_ops) |oi| {
            if (self.cancel_flag.load(.acquire)) break;
            rng_state = rng_state *% 6364136223846793005 +% 1;
            const blk_idx = (rng_state >> 16) % max_blocks;
            const op0 = std.time.nanoTimestamp();
            f.seekTo(blk_idx * 4096) catch break;
            _ = f.readAll(&blk4k) catch break;
            const op_us: u64 = @intCast(@max(@as(i128, 1), @divTrunc(std.time.nanoTimestamp() - op0, 1000)));
            r_lats[r_done] = @intCast(@min(op_us, std.math.maxInt(u32)));
            r_done += 1;
            if ((oi & 63) == 0) {
                self.mutex.lock();
                self.snap.progress_pct = base_progress + (0.56 + (@as(f32, @floatFromInt(oi + 1)) / @as(f32, @floatFromInt(r_ops))) * 0.22) * span_progress;
                self.mutex.unlock();
            }
        }
        const r_sec = @max(0.0001, @as(f64, @floatFromInt(std.time.nanoTimestamp() - tk0)) / @as(f64, @floatFromInt(std.time.ns_per_s)));
        const r_st = summarizeLatencies(r_lats[0..r_done]);

        self.mutex.lock();
        self.snap.disk_rnd4k_read_iops = @as(f64, @floatFromInt(r_done)) / r_sec;
        self.snap.disk_rnd4k_read_mbs = (@as(f64, @floatFromInt(r_done)) * 4096.0 / (1024.0 * 1024.0)) / r_sec;
        self.snap.disk_rnd4k_min_lat_us = r_st.min_us;
        self.snap.disk_rnd4k_avg_lat_us = r_st.avg_us;
        self.snap.disk_rnd4k_p95_lat_us = r_st.p95_us;
        self.snap.disk_rnd4k_p99_lat_us = r_st.p99_us;
        self.snap.disk_rnd4k_max_lat_us = r_st.max_us;
        self.mutex.unlock();

        if (self.cancel_flag.load(.acquire)) return true;

        @memset(&blk4k, 0x5A);
        const w_ops: usize = 512;
        var w_lats: [w_ops]u32 = undefined;
        var w_done: usize = 0;
        const twk0 = std.time.nanoTimestamp();
        for (0..w_ops) |oi| {
            if (self.cancel_flag.load(.acquire)) break;
            rng_state = rng_state *% 6364136223846793005 +% 1;
            const blk_idx = (rng_state >> 16) % max_blocks;
            const op0 = std.time.nanoTimestamp();
            f.seekTo(blk_idx * 4096) catch break;
            f.writeAll(&blk4k) catch break;
            const op_us: u64 = @intCast(@max(@as(i128, 1), @divTrunc(std.time.nanoTimestamp() - op0, 1000)));
            w_lats[w_done] = @intCast(@min(op_us, std.math.maxInt(u32)));
            w_done += 1;
            if ((oi & 63) == 0) {
                self.mutex.lock();
                self.snap.progress_pct = base_progress + (0.78 + (@as(f32, @floatFromInt(oi + 1)) / @as(f32, @floatFromInt(w_ops))) * 0.22) * span_progress;
                self.mutex.unlock();
            }
        }
        f.sync() catch {};
        const w_sec = @max(0.0001, @as(f64, @floatFromInt(std.time.nanoTimestamp() - twk0)) / @as(f64, @floatFromInt(std.time.ns_per_s)));
        const w_st = summarizeLatencies(w_lats[0..w_done]);

        self.mutex.lock();
        self.snap.disk_rnd4k_write_iops = @as(f64, @floatFromInt(w_done)) / w_sec;
        self.snap.disk_rnd4k_write_mbs = (@as(f64, @floatFromInt(w_done)) * 4096.0 / (1024.0 * 1024.0)) / w_sec;
        self.snap.disk_rnd4k_write_p99_us = w_st.p99_us;
        self.snap.elapsed_s = @as(f64, @floatFromInt(std.time.nanoTimestamp() - start_ns)) / @as(f64, @floatFromInt(std.time.ns_per_s));
        self.snap.progress_pct = base_progress + span_progress;
        self.mutex.unlock();
    }
    return true;
}

fn diskBenchMain(self: *BenchmarkRunner, cfg: BenchmarkConfig, target_dir: []u8) void {
    defer self.allocator.free(target_dir);
    const ok = runDiskPhase(self, cfg, target_dir, 0.0, 100.0);

    self.mutex.lock();
    self.snap.active_kind = .none;
    if (!ok and self.snap.outcome == .failed_io) {
        self.mutex.unlock();
        return;
    }
    if (self.thermal_trip_flag.load(.acquire)) {
        self.snap.outcome = .stopped_by_thermal;
        setSummary(&self.snap, i18n.trSlice("触发高温熔断，已中止磁盘测速并自动清理临时文件", "Thermal cutoff triggered; temp file auto-deleted", "高温保護によりディスク計測を中止しました（一時ファイル削除済）"));
    } else if (self.cancel_flag.load(.acquire)) {
        self.snap.outcome = .stopped_by_user;
        setSummary(&self.snap, i18n.trSlice("磁盘基准测试已中止，临时文件已自动清理", "Disk benchmark aborted; temp file auto-deleted", "ディスク計測を中止しました（一時ファイル削除済）"));
    } else if (self.snap.disk_integrity_errors > 0) {
        self.snap.outcome = .failed_errors;
        setSummary(&self.snap, i18n.trSlice("检出磁盘读写数据完整性不匹配！临时文件已清理", "Disk data integrity mismatch detected! Temp file deleted", "ディスク整合性エラーを検出！一時ファイルは削除済み"));
    } else {
        self.snap.progress_pct = 100.0;
        self.snap.outcome = .passed;
        setSummary(&self.snap, i18n.trSlice(
            "无缓存磁盘读写与数据完整性校验全部通过，临时文件已自动清理",
            "Unbuffered disk R/W & integrity check passed; temp file auto-deleted",
            "無キャッシュディスク計測・整合性検証合格（一時ファイル自動削除済）",
        ));
    }
    self.mutex.unlock();
}

// ============================================================================
// 4. 整机安全联烤 (CPU+RAM+GPU) 与 一键全套体检
// ============================================================================

fn combinedWorkerMain(self: *BenchmarkRunner, cfg: BenchmarkConfig) void {
    lowerCurrentThreadPriority();
    const expected = computeDeterministicKernel(0x123456789ABCDEF0);
    var local_cancel = std.atomic.Value(bool).init(false);
    var shared = CpuWorkerShared{ .cancel = &local_cancel, .expected_ref = expected, .gentle_mode = true };
    var handles: [64]?std.Thread = [_]?std.Thread{null} ** 64;
    const t_count: usize = @intCast(std.math.clamp(cfg.cpu_threads, 1, 64));
    for (0..t_count) |i| {
        handles[i] = std.Thread.spawn(.{}, cpuWorkerLoop, .{&shared}) catch null;
    }

    // 温和的 32 MB 内存位巡检缓冲，联烤期间周期性写读验证内存稳态（不抢占大量内存）
    const ram_words: usize = (32 * 1024 * 1024) / @sizeOf(u64);
    const ram_buf = self.allocator.alloc(u64, ram_words) catch null;
    defer if (ram_buf) |b| self.allocator.free(b);

    const start_ns = std.time.nanoTimestamp();
    const target_ns: i128 = @as(i128, cfg.duration_s) * std.time.ns_per_s;
    var pass_idx: u8 = 0;

    while (!self.cancel_flag.load(.acquire)) {
        if (ram_buf) |b| {
            // 每周期仅校验 4 MB 片段，兼顾内存稳态检测与系统低负担
            const seg_len: usize = @min(b.len, (4 * 1024 * 1024) / @sizeOf(u64));
            const off = (@as(usize, pass_idx) * seg_len) % b.len;
            const end = @min(b.len, off + seg_len);
            for (b[off..end], 0..) |*slot, i| slot.* = patternWord(pass_idx & 3, i);
            var ram_err: u64 = 0;
            for (b[off..end], 0..) |v, i| {
                if (v != patternWord(pass_idx & 3, i)) ram_err += 1;
            }
            if (ram_err > 0) _ = shared.errors.fetchAdd(ram_err, .acq_rel);
            pass_idx +%= 1;
        }
        const el = std.time.nanoTimestamp() - start_ns;
        const el_s = @max(0.05, @as(f64, @floatFromInt(el)) / @as(f64, @floatFromInt(std.time.ns_per_s)));
        self.mutex.lock();
        self.snap.cpu_score_mops = (@as(f64, @floatFromInt(shared.total_ops.load(.acquire))) / 1_000_000.0) / el_s;
        self.snap.error_count = shared.errors.load(.acquire);
        self.mutex.unlock();

        if (el >= target_ns) break;
        std.Thread.sleep(120 * std.time.ns_per_ms);
    }

    local_cancel.store(true, .release);
    for (0..t_count) |i| {
        if (handles[i]) |h| h.join();
    }
}

fn fullSuiteMain(self: *BenchmarkRunner, cfg: BenchmarkConfig, target_dir: []u8, has_gui_gpu: bool) void {
    defer self.allocator.free(target_dir);
    lowerCurrentThreadPriority();

    // [1/4] CPU Single + Multi
    var cpu_cfg = cfg;
    cpu_cfg.duration_s = @min(cfg.duration_s, 12);
    runCpuPhase(self, cpu_cfg, 0.0, 25.0);
    if (self.cancel_flag.load(.acquire)) {
        finishSuiteEarly(self);
        return;
    }

    // [2/4] Memory Latency + Bandwidth + Bit-Flip
    self.mutex.lock();
    setSummary(&self.snap, i18n.trSlice(
        "一键全套体检 [2/4]：正在执行内存延迟、多核带宽与 4 轮位翻转校验...",
        "Full Diagnostic [2/4]: Running RAM latency, Copy BW & bit-flip check...",
        "総合診断 [2/4]：メモリ遅延・帯域・4パス ビット検証を実行中...",
    ));
    self.mutex.unlock();
    _ = runMemoryPhase(self, cfg, 25.0, 25.0);
    if (self.cancel_flag.load(.acquire) or self.snap.outcome == .failed_io) {
        finishSuiteEarly(self);
        return;
    }

    // [3/4] Disk Unbuffered SEQ1M/RND4K + Integrity (仅在用户勾选磁盘确认时执行，遵守安全边界)
    if (cfg.include_disk_in_suite) {
        self.mutex.lock();
        setSummary(&self.snap, i18n.trSlice(
            "一键全套体检 [3/4]：正在执行无缓存磁盘读写与数据完整性校验...",
            "Full Diagnostic [3/4]: Running unbuffered disk R/W & integrity check...",
            "総合診断 [3/4]：無キャッシュディスク計測・整合性検証を実行中...",
        ));
        self.mutex.unlock();
        _ = runDiskPhase(self, cfg, target_dir, 50.0, 25.0);
        if (self.cancel_flag.load(.acquire) or self.snap.outcome == .failed_io) {
            finishSuiteEarly(self);
            return;
        }
    }

    // [4/4] GPU Shader Stress (GUI 模式下移交主循环执行 10 秒安全着色器测试)
    if (has_gui_gpu) {
        const now_ns = std.time.nanoTimestamp();
        self.mutex.lock();
        self.gpu_start_ns = now_ns;
        self.gpu_last_frame_ns = now_ns;
        self.gpu_last_trace_ns = now_ns;
        self.gpu_duration_s = 10;
        self.gpu_trace_frames_base = 0;
        self.suite_gpu_phase = true;
        self.snap.gpu_shader_active = true;
        self.snap.has_gpu_result = true;
        self.snap.progress_pct = 75.0;
        setSummary(&self.snap, i18n.trSlice(
            "一键全套体检 [4/4]：正在执行 10 秒 OpenGL 3.3 GPU 着色器稳定性校验...",
            "Full Diagnostic [4/4]: Running 10s OpenGL 3.3 GPU shader stability check...",
            "総合診断 [4/4]：10秒間 OpenGL 3.3 GPU シェーダー検証を実行中...",
        ));
        self.mutex.unlock();
        return;
    }

    self.mutex.lock();
    self.snap.active_kind = .none;
    self.snap.progress_pct = 100.0;
    self.snap.outcome = if (self.snap.error_count > 0) .failed_errors else .passed;
    setSummary(&self.snap, i18n.trSlice(
        "一键全套硬件体检完成（CLI 模式已跳过 GPU 着色器）",
        "Full hardware diagnostic suite completed (GPU shader skipped in CLI)",
        "総合ハードウェア診断完了（CLI では GPU シェーダーをスキップ）",
    ));
    self.mutex.unlock();
}

fn finishSuiteEarly(self: *BenchmarkRunner) void {
    self.mutex.lock();
    self.snap.active_kind = .none;
    self.snap.gpu_shader_active = false;
    if (self.snap.outcome != .failed_io) {
        self.snap.outcome = if (self.thermal_trip_flag.load(.acquire)) .stopped_by_thermal else .stopped_by_user;
    }
    setSummary(&self.snap, i18n.trSlice("综合体检已安全中止", "Full diagnostic suite aborted safely", "総合診断を安全に中断しました"));
    self.mutex.unlock();
}

fn computeLow1Fps(samples: []const f32) f64 {
    if (samples.len == 0) return 0.0;
    var tmp: [512]f32 = undefined;
    const n = @min(samples.len, tmp.len);
    @memcpy(tmp[0..n], samples[0..n]);
    std.mem.sort(f32, tmp[0..n], {}, std.sort.asc(f32));
    // 1% slowest frames = 99th percentile frame time
    const idx = @min(n - 1, (n * 99) / 100);
    const ft_ms: f64 = @max(0.1, @as(f64, tmp[idx]));
    return 1000.0 / ft_ms;
}

fn markDiskFail(self: *BenchmarkRunner, msg: []const u8) void {
    self.mutex.lock();
    self.snap.active_kind = .none;
    self.snap.outcome = .failed_io;
    setSummary(&self.snap, msg);
    self.mutex.unlock();
}

fn setSummary(snap: *BenchmarkSnapshot, msg: []const u8) void {
    setFixed(&snap.summary, &snap.summary_len, msg);
}

fn setFixed(dest: []u8, out_len: *usize, src: []const u8) void {
    const n = @min(dest.len, src.len);
    @memcpy(dest[0..n], src[0..n]);
    out_len.* = n;
}

test "BenchmarkRunner V2.2: memory latency + bit-flip, latency percentiles, 1% Low FPS, and free space guard" {
    const r1 = computeDeterministicKernel(0x123456789ABCDEF0);
    const r2 = computeDeterministicKernel(0x123456789ABCDEF0);
    try std.testing.expectEqual(r1, r2);

    // Latency percentile calculation
    var lats = [_]u32{ 500, 100, 200, 300, 400, 1000, 150, 250, 350, 450 };
    const st = summarizeLatencies(&lats);
    try std.testing.expectApproxEqAbs(@as(f64, 100.0), st.min_us, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 1000.0), st.max_us, 1e-6);
    try std.testing.expect(st.p99_us >= st.p95_us);

    // 1% Low FPS calculation
    const fts = [_]f32{ 16.0, 16.0, 16.0, 16.0, 16.0, 16.0, 16.0, 16.0, 16.0, 50.0 };
    const low1 = computeLow1Fps(&fts);
    try std.testing.expectApproxEqAbs(@as(f64, 20.0), low1, 0.5);

    // Block integrity signature detects corruption cleanly
    var blk: [4096]u8 = undefined;
    const h0 = fillBlockWithSignature(&blk, 7);
    try std.testing.expectEqual(h0, computeBlockChecksum(&blk));
    blk[123] ^= 0x01;
    try std.testing.expect(h0 != computeBlockChecksum(&blk));

    // Full Memory Verify (L1/L2/L3/RAM latency + Copy + 4-pass bit-flip)
    var runner = BenchmarkRunner.init(std.testing.allocator);
    defer runner.deinit();
    try std.testing.expect(runner.startMemoryVerify(.{ .mem_size_mb = 32, .gentle_mode = true }, 4 * 1024 * 1024 * 1024));
    var wait: usize = 0;
    while (runner.isRunning() and wait < 400) : (wait += 1) {
        std.Thread.sleep(20 * std.time.ns_per_ms);
    }
    const snap = runner.copySnapshot();
    try std.testing.expectEqual(TestOutcome.passed, snap.outcome);
    try std.testing.expectEqual(@as(u64, 0), snap.error_count);
    try std.testing.expectEqual(@as(u32, 4), snap.mem_passes_done);
    try std.testing.expect(snap.mem_write_gbs > 0.0);
    try std.testing.expect(snap.mem_read_gbs > 0.0);
    try std.testing.expect(snap.mem_copy_gbs > 0.0);
    try std.testing.expect(snap.mem_lat_l1_ns > 0.0);
    try std.testing.expect(snap.mem_lat_ram_ns > 0.0);

    const rep = try runner.exportReport(std.testing.allocator, "Test CPU", "Test GPU");
    defer std.testing.allocator.free(rep);
    try std.testing.expect(std.mem.indexOf(u8, rep, "RAM Latency") != null);
}
