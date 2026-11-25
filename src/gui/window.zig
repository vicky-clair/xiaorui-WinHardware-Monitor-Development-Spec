const std = @import("std");
const builtin = @import("builtin");
const zglfw = @import("zglfw");
const zopengl = @import("zopengl");
const zgui = @import("zgui");
const win32 = @import("../providers/windows/win32.zig");
const state_mod = @import("../app/state.zig");
const AppState = state_mod.AppState;
const theme = @import("theme.zig");
const fonts = @import("fonts.zig");
const navigation = @import("navigation.zig");
const views = @import("views.zig");
const MessageWindow = @import("../platform/message_window.zig").MessageWindow;
const SingleInstance = @import("../platform/single_instance.zig").SingleInstance;
const elevation = @import("../platform/elevation.zig");
const autostart = @import("../platform/autostart.zig");
const AppPaths = @import("../platform/paths.zig").AppPaths;
const AppConfig = @import("../services/configuration.zig").AppConfig;
const monitoring = @import("../services/monitoring.zig");
const diagnostics = @import("../services/diagnostics.zig");
const benchmarks = @import("../core/benchmarks.zig");
const ata_smart = @import("../collectors/storage/ata_smart.zig");
const i18n = @import("../core/i18n.zig");
const gpu_shader = @import("gpu_shader.zig");
const repository = @import("../database/repository.zig");

pub const RunOptions = struct {
    smoke_test: bool = false,
    start_minimized: bool = false,
    single_instance: ?*SingleInstance = null,
};

var g_input_activity: std.atomic.Value(bool) = std.atomic.Value(bool).init(true);

fn onCursorPos(_: *zglfw.Window, _: f64, _: f64) callconv(.c) void {
    g_input_activity.store(true, .release);
}
fn onMouseButton(_: *zglfw.Window, _: zglfw.MouseButton, _: zglfw.Action, _: zglfw.Mods) callconv(.c) void {
    g_input_activity.store(true, .release);
}
fn onScroll(_: *zglfw.Window, _: f64, _: f64) callconv(.c) void {
    g_input_activity.store(true, .release);
}
fn onKey(_: *zglfw.Window, _: zglfw.Key, _: i32, _: zglfw.Action, _: zglfw.Mods) callconv(.c) void {
    g_input_activity.store(true, .release);
}
fn onFramebufferSize(_: *zglfw.Window, _: i32, _: i32) callconv(.c) void {
    g_input_activity.store(true, .release);
}
fn onWindowFocus(_: *zglfw.Window, focused: zglfw.Bool) callconv(.c) void {
    if (@intFromEnum(focused) != 0) g_input_activity.store(true, .release);
}
fn onWindowIconify(_: *zglfw.Window, iconified: zglfw.Bool) callconv(.c) void {
    if (@intFromEnum(iconified) == 0) g_input_activity.store(true, .release);
}

fn applyTitlebarTheme(native_hwnd: ?win32.HWND, mode: state_mod.ThemeMode) void {
    if (builtin.os.tag != .windows) return;
    if (native_hwnd) |hwnd| {
        const dark: win32.BOOL = if (mode == .dark) 1 else 0;
        _ = win32.DwmSetWindowAttribute(hwnd, win32.DWMWA_USE_IMMERSIVE_DARK_MODE, &dark, @sizeOf(win32.BOOL));
    }
}

pub fn runMainWindow(allocator: std.mem.Allocator, opts: RunOptions) !void {
    const co_hr: i32 = if (builtin.os.tag == .windows) win32.CoInitializeEx(null, win32.COINIT_APARTMENTTHREADED) else -1;
    defer if (builtin.os.tag == .windows and co_hr >= 0) win32.CoUninitialize();

    var paths = try AppPaths.resolve(allocator);
    defer paths.deinit();

    var config = if (opts.smoke_test)
        AppConfig{}
    else blk: {
        paths.ensureDirectories();
        const loaded = AppConfig.loadFileOrDefault(allocator, paths.settings_file);
        std.fs.accessAbsolute(paths.settings_file, .{}) catch {
            loaded.saveFile(allocator, paths.settings_file) catch {};
        };
        break :blk loaded;
    };

    // 关键修复：将 MonitoringService (~400 KB) 分配在堆上，避免挤占主线程与 OpenGL 驱动栈空间
    const db_path_opt: ?[]const u8 = if (opts.smoke_test) null else paths.db_file;
    const monitor = try allocator.create(monitoring.MonitoringService);
    defer allocator.destroy(monitor);
    monitor.* = monitoring.MonitoringService.init(allocator, db_path_opt, config.system_interval_ms, config.smart_interval_ms, config.allow_wake_standby_disk);
    monitor.cpu_caution_c = @floatFromInt(config.cpu_caution_c);
    monitor.cpu_warning_c = @floatFromInt(config.cpu_warning_c);
    monitor.gpu_caution_c = @floatFromInt(config.gpu_caution_c);
    monitor.gpu_warning_c = @floatFromInt(config.gpu_warning_c);
    monitor.setExtensionEnabled(config.enable_extension_helper);
    monitor.ssd_caution_c = config.ssd_caution_c;
    monitor.ssd_warning_c = config.ssd_warning_c;
    monitor.hdd_caution_c = config.hdd_caution_c;
    monitor.hdd_warning_c = config.hdd_warning_c;
    monitor.retain_1m_days = config.retain_1m_days;
    monitor.retain_15m_days = config.retain_15m_days;
    monitor.retain_smart_days = config.retain_smart_days;

    var msg_wnd = MessageWindow{};
    msg_wnd.init() catch {};
    defer msg_wnd.deinit();

    zglfw.init() catch |err| {
        if (builtin.os.tag != .windows) {
            std.debug.print(
                "[WinHardware Monitor] GLFW 图形界面初始化失败 ({s})。\n" ++
                    "若处于无桌面服务器/SSH 终端（无 DISPLAY），请使用无界面命令行模式：\n" ++
                    "  winhardware-monitor --cli\n" ++
                    "  winhardware-monitor --bench all\n" ++
                    "若处于桌面环境，请确认已安装 X11/XWayland 与 libGL（Mesa）驱动。\n",
                .{@errorName(err)},
            );
        }
        return err;
    };
    defer zglfw.terminate();

    // 关键修复（解决管理员启动白屏/白闪）：
    // 先创建隐藏窗口，完成 OpenGL 3.3、字体、主题与首帧完整 swapBuffers 后再显示窗口！
    zglfw.windowHint(.context_version_major, 3);
    zglfw.windowHint(.context_version_minor, 3);
    zglfw.windowHint(.opengl_profile, .opengl_core_profile);
    zglfw.windowHint(.visible, false);

    const window = zglfw.Window.create(1280, 780, "WinHardware Monitor", null, null) catch {
        if (builtin.os.tag == .windows) {
            const msg = std.unicode.utf8ToUtf16LeStringLiteral(
                "无法创建 OpenGL 3.3 Core 渲染上下文。\n请检查显卡驱动，或避免在不支持 OpenGL 3.3 的远程桌面/虚拟机环境中运行。",
            );
            const cap = std.unicode.utf8ToUtf16LeStringLiteral("WinHardware Monitor - 启动失败");
            _ = win32.MessageBoxW(null, msg, cap, 0x10);
        } else {
            std.debug.print(
                "[WinHardware Monitor] 无法创建 OpenGL 3.3 Core 窗口上下文。\n" ++
                    "若处于桌面环境，请确认 X11/XWayland（DISPLAY）与 libGL/Mesa 驱动正常；\n" ++
                    "若处于无桌面服务器/SSH 终端，请改用命令行模式：winhardware-monitor --cli 或 --bench all\n",
                .{},
            );
        }
        return error.OpenGLContextFailed;
    };
    defer window.destroy();

    window.setSizeLimits(920, 580, -1, -1);

    const native_hwnd: ?win32.HWND = if (builtin.os.tag == .windows) @ptrCast(zglfw.getWin32Window(window)) else null;
    applyTitlebarTheme(native_hwnd, config.theme_mode);

    _ = window.setCursorPosCallback(onCursorPos);
    _ = window.setMouseButtonCallback(onMouseButton);
    _ = window.setScrollCallback(onScroll);
    _ = window.setKeyCallback(onKey);
    _ = window.setFramebufferSizeCallback(onFramebufferSize);
    _ = zglfw.setWindowFocusCallback(window, onWindowFocus);
    _ = zglfw.setWindowIconifyCallback(window, onWindowIconify);

    zglfw.makeContextCurrent(window);
    zglfw.swapInterval(1);
    try zopengl.loadCoreProfile(zglfw.getProcAddress, 3, 3);
    const gl = zopengl.bindings;

    const scale_xy = window.getContentScale();
    const dpi_scale = @max(scale_xy[0], 1.0);

    zgui.init(allocator);
    defer zgui.deinit();
    zgui.plot.init();
    defer zgui.plot.deinit();

    const font_res = fonts.loadFonts(dpi_scale);
    theme.applyTheme(config.theme_mode, dpi_scale);

    zgui.backend.initWithGlSlVersion(window, "#version 330");
    defer zgui.backend.deinit();

    var state = AppState{
        .is_admin = win32.isElevated(),
        .tray_available = msg_wnd.tray.added,
        .dpi_scale = dpi_scale,
        .font_source = font_res.loaded_name,
        .last_input_ns = std.time.nanoTimestamp(),
        .is_portable = paths.is_portable,
        .config_path = paths.settings_file,
        .db_path = paths.db_file,
        .system_interval_ms = config.system_interval_ms,
        .smart_interval_ms = config.smart_interval_ms,
        .allow_wake_standby_disk = config.allow_wake_standby_disk,
        .desktop_notifications = config.desktop_notifications,
    };
    config.applyToState(&state);
    // 同步真实系统开机自启状态：若配置开启则确保注册表路径指向当前程序，若系统已开启则回显真实状态
    if (!opts.smoke_test) {
        if (state.start_with_windows) {
            _ = autostart.setAutoStart(true);
        } else if (autostart.isAutoStartEnabled()) {
            state.start_with_windows = true;
        }
    }
    var applied_theme = state.theme_mode;
    var applied_language = state.language;
    var synced_paused = state.monitoring_paused;
    var synced_interval_ms = state.system_interval_ms;
    var synced_smart_ms = state.smart_interval_ms;
    var synced_wake = state.allow_wake_standby_disk;
    var synced_ext = state.extension_enabled;
    var last_copied_seq: u64 = 0;
    var last_saved_bench_run_id: u64 = 0;
    var last_disk_space_check_ns: i128 = 0;

    // 初始化磁盘测速默认目标目录为 logs_dir（支持用户自由修改为任意盘符/目录）
    {
        const n = @min(state.bench_disk_dir.len - 1, paths.logs_dir.len);
        @memcpy(state.bench_disk_dir[0..n], paths.logs_dir[0..n]);
        state.bench_disk_dir[n] = 0;
    }

    var shader_stress = gpu_shader.GpuStressShader{};
    defer shader_stress.deinit();

    if (msg_wnd.tray.added) {
        msg_wnd.tray.updateTooltip(i18n.tr(
            "WinHardware Monitor - 硬件温度与磁盘健康监控",
            "WinHardware Monitor - Thermal & Disk Health",
            "WinHardware Monitor - ハードウェア温度・ディスク監視",
        ));
    }

    const ui_snapshot = try allocator.create(monitoring.SharedTelemetry);
    defer allocator.destroy(ui_snapshot);
    ui_snapshot.* = .{};

    const bench = try allocator.create(benchmarks.BenchmarkRunner);
    defer {
        bench.deinit();
        allocator.destroy(bench);
    }
    bench.* = benchmarks.BenchmarkRunner.init(allocator);

    // 启动后台硬件监控工作线程（在 OpenGL 就绪后启动，彻底避免启动竞态）
    try monitor.start();
    defer monitor.stop();

    var smoke_frames: usize = 0;
    if (opts.smoke_test) {
        var wait_iters: usize = 0;
        while (monitor.latestSeq() == 0 and wait_iters < 20) : (wait_iters += 1) {
            std.Thread.sleep(25 * std.time.ns_per_ms);
        }
    }

    var window_shown = false;

    while (!state.should_exit) {
        // 0. 实时同步黑白（深色/浅色）主题切换 + Win10/11 原生标题栏色调 + 中英日三语切换
        if (state.theme_mode != applied_theme) {
            applied_theme = state.theme_mode;
            theme.applyTheme(applied_theme, state.dpi_scale);
            applyTitlebarTheme(native_hwnd, applied_theme);
            g_input_activity.store(true, .release);
        }
        if (state.language != applied_language) {
            applied_language = state.language;
            i18n.setLanguage(applied_language);
            if (msg_wnd.tray.added) {
                msg_wnd.tray.updateTooltip(i18n.tr(
                    "WinHardware Monitor - 硬件温度与磁盘健康监控",
                    "WinHardware Monitor - Thermal & Disk Health",
                    "WinHardware Monitor - ハードウェア温度・ディスク監視",
                ));
            }
            g_input_activity.store(true, .release);
        }

        // 1. 低占用优化：仅在设置变更时同步至后台工作线程，消除每帧重复原子写
        if (state.monitoring_paused != synced_paused) {
            synced_paused = state.monitoring_paused;
            monitor.setPaused(synced_paused);
        }
        if (state.system_interval_ms != synced_interval_ms) {
            synced_interval_ms = state.system_interval_ms;
            monitor.setIntervalMs(synced_interval_ms);
        }
        if (state.smart_interval_ms != synced_smart_ms) {
            synced_smart_ms = state.smart_interval_ms;
            monitor.setSmartIntervalMs(synced_smart_ms);
        }
        if (state.allow_wake_standby_disk != synced_wake) {
            synced_wake = state.allow_wake_standby_disk;
            monitor.setAllowWakeStandby(synced_wake);
        }
        if (state.extension_enabled != synced_ext) {
            synced_ext = state.extension_enabled;
            monitor.setExtensionEnabled(synced_ext);
        }

        if (state.request_launch_lhm_helper) {
            state.request_launch_lhm_helper = false;
            state.extension_enabled = true;
            if (!opts.smoke_test) {
                switch (elevation.launchLhmHelperAsAdministrator(allocator, native_hwnd)) {
                    .launched => state.lhm_action_msg = i18n.tr("已触发启动扩展辅助进程（等待命名管道连接）", "Extension helper launched (waiting for Named Pipe)", "拡張ヘルパーを起動しました（パイプ接続待機中）"),
                    .not_found => state.lhm_action_msg = i18n.tr("未找到 WinHardwareMonitor.LhmHelper.exe（请确认已安装扩展组件）", "WinHardwareMonitor.LhmHelper.exe not found", "WinHardwareMonitor.LhmHelper.exe が見つかりません"),
                    .cancelled => state.lhm_action_msg = i18n.tr("已取消 UAC 提权启动扩展辅助进程", "UAC elevation cancelled for extension helper", "拡張ヘルパーの管理者昇格がキャンセルされました"),
                }
            }
        }
        if (state.request_stop_lhm_helper) {
            state.request_stop_lhm_helper = false;
            state.extension_enabled = false;
            if (!opts.smoke_test) {
                if (monitor.requestExtensionShutdown()) {
                    state.lhm_action_msg = i18n.tr("已通知扩展辅助进程安全退出", "Extension helper shutdown requested", "拡張ヘルパーの安全終了を要求しました");
                } else {
                    state.lhm_action_msg = i18n.tr("扩展组件已关闭（辅助进程未在运行）", "Extension disabled (helper not running)", "拡張機能オフ（ヘルパーは未稼働）");
                }
            }
        }

        if (state.request_reset_baseline_idx) |bidx| {
            state.request_reset_baseline_idx = null;
            monitor.resetBaselineForDisk(bidx);
        }
        if (state.request_ack_alerts) {
            state.request_ack_alerts = false;
            monitor.acknowledgeAllAlerts();
        }
        if (state.request_reset_sensor_stats) {
            state.request_reset_sensor_stats = false;
            monitor.resetSensorStats();
            state.sensors_csv_msg = i18n.tr("已清零全部传感器最小/平均/最大统计", "All sensor Min/Avg/Max stats reset", "全センサーの最小/平均/最大統計をリセットしました");
        }
        if (state.request_export_sensors_csv) {
            state.request_export_sensors_csv = false;
            if (!opts.smoke_test) {
                paths.ensureDirectories();
                if (ui_snapshot.sensor_stats.exportCsv(allocator)) |csv| {
                    defer allocator.free(csv);
                    const fname = std.fmt.allocPrint(allocator, "sensors_{d}.csv", .{std.time.timestamp()}) catch null;
                    if (fname) |fn_s| {
                        defer allocator.free(fn_s);
                        if (std.fs.path.join(allocator, &.{ paths.logs_dir, fn_s })) |full_p| {
                            defer allocator.free(full_p);
                            if (std.fs.createFileAbsolute(full_p, .{ .truncate = true })) |f| {
                                defer f.close();
                                f.writeAll(csv) catch {};
                                state.sensors_csv_msg = i18n.tr("传感器 CSV 报表已导出至 logs 目录", "Sensor CSV exported to logs/", "センサー CSV を logs/ に出力しました");
                            } else |_| {
                                state.sensors_csv_msg = i18n.tr("CSV 导出失败，请检查 logs 目录权限", "CSV export failed; check logs/ permissions", "CSV 出力失敗（logs/ の権限を確認）");
                            }
                        } else |_| {}
                    }
                } else |_| {}
            }
        }

        // V2.2: 主动硬件测试控制、空间检查与实时温度/功耗熔断保护
        {
            var live_max_t: ?f64 = null;
            var live_gpu_pwr: ?f64 = null;
            if (ui_snapshot.extension.connected) {
                if (ui_snapshot.extension.cpu_package_temp_c) |ct| live_max_t = ct;
            }
            if (ui_snapshot.has_gpu_sample and ui_snapshot.gpu.count > 0) {
                if (ui_snapshot.gpu.gpus[0].temp_c) |gt| {
                    if (live_max_t == null or gt > live_max_t.?) live_max_t = gt;
                }
                live_gpu_pwr = ui_snapshot.gpu.gpus[0].power_watts;
            }
            bench.updateLiveTelemetry(live_max_t, live_gpu_pwr);
        }
        // 仅在位于「硬件测试」页时每 2 秒刷新一次目标盘剩余空间（平时零 I/O）
        if (state.current_page == .stress_test) {
            const now_sp = std.time.nanoTimestamp();
            if (now_sp - last_disk_space_check_ns >= 2 * std.time.ns_per_s) {
                last_disk_space_check_ns = now_sp;
                const dir_slice = std.mem.sliceTo(&state.bench_disk_dir, 0);
                state.bench_disk_free_bytes = benchmarks.queryDirFreeBytes(if (dir_slice.len > 0) dir_slice else paths.logs_dir);
            }
        }
        if (state.request_stop_bench) {
            state.request_stop_bench = false;
            bench.requestStop();
            state.bench_msg = i18n.tr("已请求停止硬件测试", "Stop requested for active test", "テストの停止を要求しました");
        }
        if (state.request_start_cpu_bench) {
            state.request_start_cpu_bench = false;
            if (!opts.smoke_test) {
                const ok = bench.startCpuStress(.{
                    .cpu_threads = @intCast(@max(state.bench_cpu_threads, 1)),
                    .duration_s = @intCast(@max(state.bench_duration_s, 6)),
                    .thermal_cutoff_c = @floatFromInt(state.bench_thermal_cutoff_c),
                    .gentle_mode = state.bench_gentle_mode,
                });
                state.bench_msg = if (ok)
                    i18n.tr("CPU 单核/多核与降频测试已启动（低优先级防卡顿）", "CPU Single/Multi & throttle test started (low priority)", "CPU シングル/マルチ検証を開始（低優先度保護）")
                else
                    i18n.tr("已有测试正在运行", "Another test is already running", "他のテストが実行中です");
            }
        }
        if (state.request_start_mem_bench) {
            state.request_start_mem_bench = false;
            if (!opts.smoke_test) {
                const ok = bench.startMemoryVerify(.{
                    .cpu_threads = @intCast(@max(state.bench_cpu_threads, 1)),
                    .mem_size_mb = @intCast(@max(state.bench_mem_mb, 32)),
                    .thermal_cutoff_c = @floatFromInt(state.bench_thermal_cutoff_c),
                    .gentle_mode = state.bench_gentle_mode,
                }, ui_snapshot.system.mem_avail_bytes);
                state.bench_msg = if (ok)
                    i18n.tr("内存延迟、多核带宽与 4 轮位翻转校验已启动", "Memory latency, MT Copy & 4-pass verify started", "メモリ遅延・帯域・4パス検証を開始しました")
                else
                    i18n.tr("已有测试正在运行", "Another test is already running", "他のテストが実行中です");
            }
        }
        if (state.request_start_disk_bench) {
            state.request_start_disk_bench = false;
            if (!opts.smoke_test) {
                if (!state.bench_disk_confirmed) {
                    state.bench_msg = i18n.tr("请先勾选下方安全确认项后再执行磁盘写入基准测试", "Please check the safety confirmation before starting disk benchmark", "ディスクテスト開始前に下の安全確認にチェックを入れてください");
                } else {
                    paths.ensureDirectories();
                    const dir_slice = std.mem.sliceTo(&state.bench_disk_dir, 0);
                    const target_dir = if (dir_slice.len > 0) dir_slice else paths.logs_dir;
                    const ok = bench.startDiskBench(.{
                        .disk_file_mb = @intCast(@max(state.bench_disk_mb, 32)),
                        .thermal_cutoff_c = @floatFromInt(state.bench_thermal_cutoff_c),
                        .gentle_mode = state.bench_gentle_mode,
                    }, target_dir);
                    state.bench_msg = if (ok)
                        i18n.tr("无缓存磁盘读写与完整性校验已启动（结束后自动清理）", "Unbuffered disk R/W & integrity check started (auto-deleted)", "無キャッシュディスク計測・整合性検証を開始（終了後自動削除）")
                    else
                        i18n.tr("已有测试正在运行", "Another test is already running", "他のテストが実行中です");
                }
            }
        }
        if (state.request_start_gpu_bench) {
            state.request_start_gpu_bench = false;
            if (!opts.smoke_test) {
                const ok = bench.startGpuStress(.{
                    .duration_s = @intCast(@max(state.bench_duration_s, 10)),
                    .thermal_cutoff_c = @floatFromInt(state.bench_thermal_cutoff_c),
                    .gentle_mode = state.bench_gentle_mode,
                    .gpu_intensity = state.bench_gpu_intensity,
                });
                state.bench_msg = if (ok)
                    i18n.tr("GPU OpenGL 3.3 离屏着色器烤机已启动", "GPU OpenGL 3.3 shader stress started", "GPU OpenGL 3.3 シェーダー負荷テストを開始しました")
                else
                    i18n.tr("已有测试正在运行", "Another test is already running", "他のテストが実行中です");
            }
        }
        if (state.request_start_combined_bench) {
            state.request_start_combined_bench = false;
            if (!opts.smoke_test) {
                const ok = bench.startCombinedStress(.{
                    .cpu_threads = @intCast(@max(state.bench_cpu_threads, 1)),
                    .duration_s = @intCast(@max(state.bench_duration_s, 10)),
                    .thermal_cutoff_c = @floatFromInt(state.bench_thermal_cutoff_c),
                    .gentle_mode = true,
                    .gpu_intensity = @min(state.bench_gpu_intensity, 1), // 联烤自动限制着色器不超过均衡档防桌面卡顿
                });
                state.bench_msg = if (ok)
                    i18n.tr("整机安全联烤 (CPU+内存+GPU) 已启动（已自动预留系统核心）", "Combined Safe Stress started (OS headroom reserved)", "総合安全負荷テストを開始（OS 用コアを自動確保）")
                else
                    i18n.tr("已有测试正在运行", "Another test is already running", "他のテストが実行中です");
            }
        }
        if (state.request_start_full_suite) {
            state.request_start_full_suite = false;
            if (!opts.smoke_test) {
                paths.ensureDirectories();
                const dir_slice = std.mem.sliceTo(&state.bench_disk_dir, 0);
                const target_dir = if (dir_slice.len > 0) dir_slice else paths.logs_dir;
                const ok = bench.startFullSuite(.{
                    .cpu_threads = @intCast(@max(state.bench_cpu_threads, 1)),
                    .duration_s = @intCast(@max(state.bench_duration_s, 10)),
                    .thermal_cutoff_c = @floatFromInt(state.bench_thermal_cutoff_c),
                    .mem_size_mb = @intCast(@max(state.bench_mem_mb, 32)),
                    .disk_file_mb = @intCast(@max(state.bench_disk_mb, 32)),
                    .gentle_mode = state.bench_gentle_mode,
                    .gpu_intensity = state.bench_gpu_intensity,
                    .include_disk_in_suite = state.bench_disk_confirmed,
                }, ui_snapshot.system.mem_avail_bytes, target_dir, true);
                state.bench_msg = if (ok)
                    (if (state.bench_disk_confirmed)
                        i18n.tr("一键全套综合体检已启动（CPU → 内存 → 磁盘 → GPU）", "Full Diagnostic Suite started (CPU -> RAM -> Disk -> GPU)", "ワンクリック総合診断を開始（CPU → RAM → Disk → GPU）")
                    else
                        i18n.tr("一键全套体检已启动（未勾选磁盘确认，将执行 CPU → 内存 → GPU）", "Full Diagnostic started (CPU -> RAM -> GPU; disk skipped until confirmed)", "総合診断を開始（ディスク未確認のため CPU → RAM → GPU を実行）"))
                else
                    i18n.tr("已有测试正在运行", "Another test is already running", "他のテストが実行中です");
            }
        }
        if (state.request_export_bench_report) {
            state.request_export_bench_report = false;
            if (!opts.smoke_test) {
                paths.ensureDirectories();
                const gpu_n = if (ui_snapshot.gpu.count > 0) ui_snapshot.gpu.gpus[0].nameSlice() else "N/A";
                if (bench.exportReport(allocator, ui_snapshot.system.cpuNameSlice(), gpu_n)) |rep| {
                    defer allocator.free(rep);
                    const fname = std.fmt.allocPrint(allocator, "hwtest_report_{d}.txt", .{std.time.timestamp()}) catch null;
                    if (fname) |fn_s| {
                        defer allocator.free(fn_s);
                        if (std.fs.path.join(allocator, &.{ paths.logs_dir, fn_s })) |full_p| {
                            defer allocator.free(full_p);
                            if (std.fs.createFileAbsolute(full_p, .{ .truncate = true })) |f| {
                                defer f.close();
                                f.writeAll(rep) catch {};
                                state.bench_msg = i18n.tr("硬件测试报告已导出至 logs 目录", "Benchmark report exported to logs/", "テストレポートを logs/ に出力しました");
                            } else |_| {
                                state.bench_msg = i18n.tr("导出失败，请检查 logs 目录权限", "Export failed; check logs/ permissions", "出力失敗（logs/ の権限を確認）");
                            }
                        } else |_| {}
                    }
                } else |_| {}
            }
        }
        if (state.request_ata_short_selftest_idx) |sidx| {
            state.request_ata_short_selftest_idx = null;
            if (!opts.smoke_test and sidx < ui_snapshot.disk_count) {
                if (!state.bench_smart_confirmed) {
                    state.selftest_msg = i18n.tr("请先勾选 SMART 自检二次确认后再触发", "Please check SMART self-test confirmation first", "SMART セルフテストの確認チェックを入れてください");
                } else {
                    const drive_idx = ui_snapshot.disk_states[sidx].device.drive_index;
                    state.selftest_msg = switch (ata_smart.triggerAtaShortSelfTest(drive_idx)) {
                        .started => i18n.tr("已向磁盘下发 ATA SMART 短自检指令（后台执行约 2 分钟）", "ATA SMART short self-test started (~2 min in background)", "ATA SMART ショートセルフテストを開始しました（約2分）"),
                        .access_denied => i18n.tr("权限不足：请先以管理员身份重启后再下发 SMART 自检", "Access denied: restart as Administrator to run SMART self-test", "権限不足：管理者として再起動してから実行してください"),
                        .unsupported => i18n.tr("该磁盘或接口不支持标准 ATA SMART 短自检命令", "Drive/bus does not support standard ATA SMART short self-test", "このディスクは標準 ATA SMART セルフテスト非対応です"),
                        .failed => i18n.tr("下发 SMART 短自检失败", "Failed to issue SMART short self-test", "SMART ショートセルフテストの送信に失敗しました"),
                    };
                }
            }
        }
        if (state.request_export_diag) {
            state.request_export_diag = false;
            if (!opts.smoke_test) {
                paths.ensureDirectories();
                if (diagnostics.buildSanitizedDiagnosticsReport(allocator, ui_snapshot, state.is_admin, state.is_portable)) |rep| {
                    defer allocator.free(rep);
                    const fname = std.fmt.allocPrint(allocator, "diagnostics_{d}.txt", .{std.time.timestamp()}) catch null;
                    if (fname) |fn_s| {
                        defer allocator.free(fn_s);
                        if (std.fs.path.join(allocator, &.{ paths.logs_dir, fn_s })) |full_p| {
                            defer allocator.free(full_p);
                            if (std.fs.createFileAbsolute(full_p, .{ .truncate = true })) |f| {
                                defer f.close();
                                f.writeAll(rep) catch {};
                                state.diag_export_msg = i18n.tr("脱敏诊断报告已导出至 logs 目录", "Sanitized diagnostics exported to logs/", "匿名化診断レポートを logs/ に出力しました");
                            } else |_| {
                                state.diag_export_msg = i18n.tr("导出失败，请检查 logs 目录权限", "Export failed; check logs/ permissions", "出力失敗（logs/ の権限を確認）");
                            }
                        } else |_| {}
                    }
                } else |_| {
                    state.diag_export_msg = i18n.tr("生成诊断报告失败", "Failed to build diagnostics report", "診断レポートの生成に失敗しました");
                }
            }
        }

        if (state.desktop_notifications and !opts.smoke_test) {
            if (monitor.takePendingNotification()) |ev| {
                const title = if (ev.is_recovery)
                    i18n.tr("WinHardware Monitor — 告警恢复", "WinHardware Monitor — Alert Recovered", "WinHardware Monitor — アラート回復")
                else
                    i18n.tr("WinHardware Monitor — 硬件告警", "WinHardware Monitor — Hardware Alert", "WinHardware Monitor — ハードウェア警告");
                const flags: win32.DWORD = if (ev.is_recovery)
                    win32.NIIF_INFO
                else if (ev.level == .critical)
                    win32.NIIF_ERROR
                else
                    win32.NIIF_WARNING;
                msg_wnd.tray.showBalloon(title, ev.messageSlice(), flags);
            }
        }

        // 2. 处理配置保存 / 重置 / 导入导出与开机自启
        if (state.request_save_config) {
            state.request_save_config = false;
            config.syncFromState(&state);
            config.system_interval_ms = state.system_interval_ms;
            config.smart_interval_ms = state.smart_interval_ms;
            config.allow_wake_standby_disk = state.allow_wake_standby_disk;
            if (!opts.smoke_test) {
                const autostart_ok = autostart.setAutoStart(config.start_with_windows);
                paths.ensureDirectories();
                if (config.saveFile(allocator, paths.settings_file)) |_| {
                    if (!autostart_ok) {
                        state.config_save_msg = i18n.tr(
                            "配置已保存，但写入开机自启注册表失败（请检查安全软件拦截）",
                            "Config saved, but autostart registry write failed (check antivirus)",
                            "設定保存済・自動起動レジストリ書込失敗（セキュリティソフトを確認）",
                        );
                    } else if (config.start_with_windows) {
                        state.config_save_msg = i18n.tr(
                            "配置已保存（开机自启已写入系统注册表）",
                            "Configuration saved (Autostart registered)",
                            "設定を保存しました（自動起動を登録済）",
                        );
                    } else {
                        state.config_save_msg = i18n.tr("配置已保存", "Configuration saved", "設定を保存しました");
                    }
                } else |_| {
                    state.config_save_msg = i18n.tr("保存失败，请检查目录权限", "Save failed; check directory permissions", "保存失敗（フォルダ権限を確認）");
                }
            }
        }
        if (state.request_export_config) {
            state.request_export_config = false;
            config.syncFromState(&state);
            config.system_interval_ms = state.system_interval_ms;
            config.smart_interval_ms = state.smart_interval_ms;
            config.allow_wake_standby_disk = state.allow_wake_standby_disk;
            if (!opts.smoke_test) {
                paths.ensureDirectories();
                if (std.fs.path.join(allocator, &.{ paths.config_dir, "settings_backup.toml" })) |exp_path| {
                    defer allocator.free(exp_path);
                    if (config.saveFile(allocator, exp_path)) |_| {
                        state.config_save_msg = i18n.tr("已导出配置至 config/settings_backup.toml", "Exported to config/settings_backup.toml", "config/settings_backup.toml に出力しました");
                    } else |_| {
                        state.config_save_msg = i18n.tr("配置导出失败，请检查目录权限", "Config export failed; check permissions", "設定のエクスポートに失敗しました");
                    }
                } else |_| {}
            }
        }
        if (state.request_import_config) {
            state.request_import_config = false;
            if (!opts.smoke_test) {
                if (std.fs.path.join(allocator, &.{ paths.config_dir, "settings_backup.toml" })) |imp_path| {
                    defer allocator.free(imp_path);
                    if (std.fs.accessAbsolute(imp_path, .{})) |_| {
                        config = AppConfig.loadFileOrDefault(allocator, imp_path);
                        config.applyToState(&state);
                        state.system_interval_ms = config.system_interval_ms;
                        state.smart_interval_ms = config.smart_interval_ms;
                        state.allow_wake_standby_disk = config.allow_wake_standby_disk;
                        config.saveFile(allocator, paths.settings_file) catch {};
                        state.config_save_msg = i18n.tr("已从 config/settings_backup.toml 导入并生效", "Imported from config/settings_backup.toml", "config/settings_backup.toml を読み込みました");
                    } else |_| {
                        state.config_save_msg = i18n.tr("未找到 config/settings_backup.toml", "config/settings_backup.toml not found", "config/settings_backup.toml が見つかりません");
                    }
                } else |_| {}
            }
        }
        if (state.request_reset_config) {
            state.request_reset_config = false;
            config = AppConfig{};
            config.applyToState(&state);
            state.system_interval_ms = config.system_interval_ms;
            state.smart_interval_ms = config.smart_interval_ms;
            state.allow_wake_standby_disk = config.allow_wake_standby_disk;
            state.config_save_msg = i18n.tr("已恢复默认（点击保存后生效）", "Defaults restored (click Save to persist)", "初期値に戻しました（保存で確定）");
        }

        // 3. 泵送隐藏窗口的 Win32 消息
        msg_wnd.monitoring_paused = state.monitoring_paused;
        msg_wnd.pumpMessages();

        if (msg_wnd.events.restore_window) {
            msg_wnd.events.restore_window = false;
            state.in_tray = false;
            window.show();
            window.restore();
            window.focus();
            g_input_activity.store(true, .release);
        }
        if (msg_wnd.events.toggle_pause) {
            msg_wnd.events.toggle_pause = false;
            state.monitoring_paused = !state.monitoring_paused;
            g_input_activity.store(true, .release);
        }
        if (msg_wnd.events.request_exit) {
            msg_wnd.events.request_exit = false;
            state.should_exit = true;
            break;
        }
        if (msg_wnd.events.device_changed) {
            msg_wnd.events.device_changed = false;
            state.device_change_events = msg_wnd.events.device_change_count;
            monitor.triggerDiskRescan();
        }
        if (msg_wnd.events.power_resumed) {
            msg_wnd.events.power_resumed = false;
            state.power_resume_events = msg_wnd.events.power_resume_count;
            monitor.triggerDiskRescan();
        }

        // 4. 显式管理员重启请求（先释放单实例互斥体，再 UAC 启动新进程，避免竞态）
        if (state.request_relaunch_admin) {
            state.request_relaunch_admin = false;
            if (opts.single_instance) |si| si.release();
            if (elevation.relaunchAsAdministrator(native_hwnd)) {
                state.should_exit = true;
                break;
            } else {
                // 用户取消 UAC 时重新获取互斥体继续正常运行
                if (opts.single_instance) |si| _ = si.acquire();
            }
        }

        // 5. 关闭 / 最小化行为
        if (window.shouldClose()) {
            if (state.close_behavior == .minimize_to_tray and state.tray_available and !opts.smoke_test) {
                window.setShouldClose(false);
                window.hide();
                state.in_tray = true;
            } else {
                state.should_exit = true;
                break;
            }
        }

        const is_iconified = window.getAttribute(.iconified);
        if (is_iconified and state.minimize_behavior == .minimize_to_tray and state.tray_available and !state.in_tray) {
            window.hide();
            state.in_tray = true;
        }

        // 6. §6.1 渲染节能状态机（首帧展示前强制渲染；若外部 ShowWindow 唤醒托盘窗口则立即清除 in_tray）
        const now_ns = std.time.nanoTimestamp();
        const win_visible = window.getAttribute(.visible);
        if (state.in_tray and win_visible and !is_iconified) {
            state.in_tray = false;
            g_input_activity.store(true, .release);
        }
        const had_input = g_input_activity.swap(false, .acq_rel);
        const is_visible = opts.smoke_test or !window_shown or win_visible;
        const mode = state.updateRenderMode(now_ns, is_visible, is_iconified, had_input);

        if (opts.smoke_test or !window_shown) {
            zglfw.pollEvents();
        } else {
            switch (mode) {
                .active_60fps => zglfw.pollEvents(),
                .idle_low_fps => {
                    // 若后台刚发布了新硬件快照，立即刷新一帧，否则低功耗休眠等待输入或 1 秒周期
                    if (monitor.latestSeqAtomic() != last_copied_seq) {
                        zglfw.pollEvents();
                    } else {
                        zglfw.waitEventsTimeout(mode.waitTimeoutSeconds());
                    }
                },
                .paused_hidden => {
                    state.skipped_frames += 1;
                    zglfw.waitEventsTimeout(mode.waitTimeoutSeconds());
                    continue;
                },
            }
        }

        const fb = window.getFramebufferSize();
        if (fb[0] == 0 or fb[1] == 0) {
            if (!window_shown and !opts.smoke_test) {
                window.show();
                window.focus();
                window_shown = true;
            }
            state.skipped_frames += 1;
            continue;
        }

        // 7. 低占用绝对非阻塞快照同步：仅在 sample_seq 变化时拷贝一次（内存拷贝量降低 ~120 倍）
        if (monitor.tryCopySnapshotIfChanged(ui_snapshot, &last_copied_seq)) {
            state.active_alert_count = ui_snapshot.active_alert_count;
            if (ui_snapshot.has_system_sample and !state.bench_threads_initialized and ui_snapshot.system.logical_cores > 0) {
                // 默认预留 1 个逻辑核给操作系统与前台进程，确保测试期间绝不卡顿
                const safe_def: u32 = if (ui_snapshot.system.logical_cores > 1) ui_snapshot.system.logical_cores - 1 else 1;
                state.bench_cpu_threads = @intCast(safe_def);
                state.bench_threads_initialized = true;
            }
        }
        const bench_snap = bench.copySnapshot();
        if (bench_snap.outcome == .running) {
            g_input_activity.store(true, .release);
        } else if (!opts.smoke_test and bench_snap.run_id != 0 and bench_snap.run_id != last_saved_bench_run_id and bench_snap.outcome != .idle) {
            // 测试刚结束：自动异步归档至本地 SQLite 历史表，供优化前后成绩对比
            last_saved_bench_run_id = bench_snap.run_id;
            var p_buf: [96]u8 = undefined;
            var s_buf: [96]u8 = undefined;
            const hs = bench_snap.formatHistorySummary(&p_buf, &s_buf);
            var rec = repository.BenchmarkHistoryRecord{
                .timestamp_utc_ms = std.time.milliTimestamp(),
                .duration_s = bench_snap.elapsed_s,
                .error_count = bench_snap.error_count,
                .peak_temp_c = bench_snap.peak_temp_c,
            };
            const k_s = bench_snap.last_kind.code();
            @memcpy(rec.test_kind[0..k_s.len], k_s);
            rec.test_kind_len = k_s.len;
            const o_s = bench_snap.outcome.code();
            @memcpy(rec.outcome[0..o_s.len], o_s);
            rec.outcome_len = o_s.len;
            @memcpy(rec.primary_metric[0..hs.primary.len], hs.primary);
            rec.primary_metric_len = hs.primary.len;
            @memcpy(rec.secondary_metric[0..hs.secondary.len], hs.secondary);
            rec.secondary_metric_len = hs.secondary.len;
            monitor.recordBenchmarkHistory(rec);
        }

        // OpenGL 3.3 离屏着色器按需驱动（仅 GPU 烤机/联烤/体检第4步激活，结束立即释放显存零负担）
        if (bench_snap.gpu_shader_active and !opts.smoke_test) {
            if (shader_stress.ensureReady(bench_snap.gpu_intensity)) {
                shader_stress.renderFrame(bench_snap.elapsed_s);
                state.bench_gpu_tex_id = shader_stress.textureId();
            } else {
                state.bench_gpu_tex_id = 0;
            }
            _ = bench.tickGpuStressFrame();
        } else {
            if (shader_stress.ready) {
                shader_stress.deinit();
            }
            state.bench_gpu_tex_id = 0;
        }

        gl.viewport(0, 0, fb[0], fb[1]);
        const bg = theme.active().canvas_bg;
        gl.clearColor(bg[0], bg[1], bg[2], bg[3]);
        gl.clear(gl.COLOR_BUFFER_BIT);

        zgui.backend.newFrame(@intCast(fb[0]), @intCast(fb[1]));

        const fb_w: f32 = @floatFromInt(fb[0]);
        const fb_h: f32 = @floatFromInt(fb[1]);

        zgui.setNextWindowPos(.{ .x = 0, .y = 0, .cond = .always });
        zgui.setNextWindowSize(.{ .w = fb_w, .h = fb_h, .cond = .always });
        zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = .{ 0, 0 } });
        const root_open = zgui.begin("##WinHardwareMonitorRoot", .{
            .flags = .{
                .no_title_bar = true,
                .no_resize = true,
                .no_move = true,
                .no_collapse = true,
                .no_bring_to_front_on_focus = true,
                .no_scrollbar = true,
            },
        });
        zgui.popStyleVar(.{ .count = 1 });

        if (root_open) {
            navigation.renderSidebar(&state, fb_h);
            zgui.sameLine(.{ .spacing = 0.0 });

            zgui.pushStyleColor4f(.{ .idx = .child_bg, .c = theme.active().canvas_bg });
            zgui.pushStyleVar1f(.{ .idx = .child_rounding, .v = 0.0 });
            zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = .{ 18.0 * state.dpi_scale, 16.0 * state.dpi_scale } });
            if (zgui.beginChild("##main_content", .{
                .w = 0,
                .h = fb_h,
                .child_flags = .{ .always_use_window_padding = true },
            })) {
                views.renderCurrentPage(&state, ui_snapshot, &bench_snap);
            }
            zgui.endChild();
            zgui.popStyleVar(.{ .count = 2 });
            zgui.popStyleColor(.{ .count = 1 });
        }
        zgui.end();

        zgui.backend.draw();
        window.swapBuffers();

        // 首帧渲染完成后再显示窗口（若以 --autostart 开机自启且托盘可用，则静默驻留托盘不打扰开机）
        if (!window_shown and !opts.smoke_test) {
            window_shown = true;
            if (opts.start_minimized and state.tray_available) {
                window.hide();
                state.in_tray = true;
            } else {
                window.show();
                window.focus();
                g_input_activity.store(true, .release);
            }
        }

        state.rendered_frames += 1;
        if (opts.smoke_test) {
            smoke_frames += 1;
            const pages = std.meta.tags(state_mod.Page);
            if (smoke_frames < pages.len) {
                state.current_page = pages[smoke_frames];
                // 在冒烟测试中遍历深/浅双主题与中/英/日三语，验证全语种与全页面渲染零崩溃
                if (smoke_frames == pages.len / 3) {
                    state.language = .en_us;
                } else if (smoke_frames == (pages.len * 2) / 3) {
                    state.language = .ja_jp;
                    state.theme_mode = .light;
                }
            } else {
                break;
            }
        }
    }
}
