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

pub const RunOptions = struct {
    smoke_test: bool = false,
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

    try zglfw.init();
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
    var applied_theme = state.theme_mode;

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
        // 0. 实时同步黑白（深色/浅色）主题切换 + Win10/11 原生标题栏色调
        if (state.theme_mode != applied_theme) {
            applied_theme = state.theme_mode;
            theme.applyTheme(applied_theme, state.dpi_scale);
            applyTitlebarTheme(native_hwnd, applied_theme);
            g_input_activity.store(true, .release);
        }

        // 1. 同步暂停/采样间隔/电源保护/扩展组件开关给后台工作线程
        monitor.setPaused(state.monitoring_paused);
        monitor.setIntervalMs(state.system_interval_ms);
        monitor.setSmartIntervalMs(state.smart_interval_ms);
        monitor.setAllowWakeStandby(state.allow_wake_standby_disk);
        monitor.setExtensionEnabled(state.extension_enabled);

        if (state.request_launch_lhm_helper) {
            state.request_launch_lhm_helper = false;
            state.extension_enabled = true;
            if (!opts.smoke_test) {
                switch (elevation.launchLhmHelperAsAdministrator(allocator, native_hwnd)) {
                    .launched => state.lhm_action_msg = "已触发启动扩展辅助进程（等待命名管道连接）",
                    .not_found => state.lhm_action_msg = "未找到 WinHardwareMonitor.LhmHelper.exe（请确认已安装扩展组件）",
                    .cancelled => state.lhm_action_msg = "已取消 UAC 提权启动扩展辅助进程",
                }
            }
        }
        if (state.request_stop_lhm_helper) {
            state.request_stop_lhm_helper = false;
            state.extension_enabled = false;
            if (!opts.smoke_test) {
                if (monitor.requestExtensionShutdown()) {
                    state.lhm_action_msg = "已通知扩展辅助进程安全退出";
                } else {
                    state.lhm_action_msg = "扩展组件已关闭（辅助进程未在运行）";
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
            state.sensors_csv_msg = "已清零全部传感器最小/平均/最大统计";
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
                                state.sensors_csv_msg = "传感器 CSV 报表已导出至 logs 目录";
                            } else |_| {
                                state.sensors_csv_msg = "CSV 导出失败，请检查 logs 目录权限";
                            }
                        } else |_| {}
                    }
                } else |_| {}
            }
        }

        // V2: 主动硬件测试控制与实时高温熔断保护
        {
            var live_max_t: ?f64 = null;
            if (ui_snapshot.extension.connected) {
                if (ui_snapshot.extension.cpu_package_temp_c) |ct| live_max_t = ct;
            }
            if (ui_snapshot.has_gpu_sample and ui_snapshot.gpu.count > 0) {
                if (ui_snapshot.gpu.gpus[0].temp_c) |gt| {
                    if (live_max_t == null or gt > live_max_t.?) live_max_t = gt;
                }
            }
            bench.updateLiveTemperature(live_max_t);
        }
        if (state.request_stop_bench) {
            state.request_stop_bench = false;
            bench.requestStop();
            state.bench_msg = "已请求停止硬件测试";
        }
        if (state.request_start_cpu_bench) {
            state.request_start_cpu_bench = false;
            if (!opts.smoke_test) {
                const ok = bench.startCpuStress(.{
                    .cpu_threads = @intCast(@max(state.bench_cpu_threads, 1)),
                    .duration_s = @intCast(@max(state.bench_duration_s, 5)),
                    .thermal_cutoff_c = @floatFromInt(state.bench_thermal_cutoff_c),
                });
                state.bench_msg = if (ok) "CPU 稳定性与算力校验已启动" else "已有测试正在运行";
            }
        }
        if (state.request_start_mem_bench) {
            state.request_start_mem_bench = false;
            if (!opts.smoke_test) {
                const ok = bench.startMemoryVerify(.{
                    .mem_size_mb = @intCast(@max(state.bench_mem_mb, 32)),
                    .thermal_cutoff_c = @floatFromInt(state.bench_thermal_cutoff_c),
                }, ui_snapshot.system.mem_avail_bytes);
                state.bench_msg = if (ok) "4 轮内存位翻转与带宽校验已启动" else "已有测试正在运行";
            }
        }
        if (state.request_start_disk_bench) {
            state.request_start_disk_bench = false;
            if (!opts.smoke_test) {
                if (!state.bench_disk_confirmed) {
                    state.bench_msg = "请先勾选下方安全确认项后再执行磁盘写入基准测试";
                } else {
                    paths.ensureDirectories();
                    const ok = bench.startDiskBench(.{
                        .disk_file_mb = @intCast(@max(state.bench_disk_mb, 32)),
                        .thermal_cutoff_c = @floatFromInt(state.bench_thermal_cutoff_c),
                    }, paths.logs_dir);
                    state.bench_msg = if (ok) "文件级磁盘基准测试已启动（结束后自动删除临时文件）" else "已有测试正在运行";
                }
            }
        }
        if (state.request_start_gpu_bench) {
            state.request_start_gpu_bench = false;
            if (!opts.smoke_test) {
                const ok = bench.startGpuStress(.{
                    .duration_s = @intCast(@max(state.bench_duration_s, 10)),
                    .thermal_cutoff_c = @floatFromInt(state.bench_thermal_cutoff_c),
                });
                state.bench_msg = if (ok) "GPU OpenGL 稳定性烤机已启动" else "已有测试正在运行";
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
                                state.bench_msg = "硬件测试报告已导出至 logs 目录";
                            } else |_| {
                                state.bench_msg = "导出失败，请检查 logs 目录权限";
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
                    state.selftest_msg = "请先勾选 SMART 自检二次确认后再触发";
                } else {
                    const drive_idx = ui_snapshot.disk_states[sidx].device.drive_index;
                    state.selftest_msg = switch (ata_smart.triggerAtaShortSelfTest(drive_idx)) {
                        .started => "已向磁盘下发 ATA SMART 短自检指令（后台执行约 2 分钟）",
                        .access_denied => "权限不足：请先以管理员身份重启后再下发 SMART 自检",
                        .unsupported => "该磁盘或接口不支持标准 ATA SMART 短自检命令",
                        .failed => "下发 SMART 短自检失败",
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
                                state.diag_export_msg = "脱敏诊断报告已导出至 logs 目录";
                            } else |_| {
                                state.diag_export_msg = "导出失败，请检查 logs 目录权限";
                            }
                        } else |_| {}
                    }
                } else |_| {
                    state.diag_export_msg = "生成诊断报告失败";
                }
            }
        }

        if (state.desktop_notifications and !opts.smoke_test) {
            if (monitor.takePendingNotification()) |ev| {
                const title = if (ev.is_recovery) "WinHardware Monitor — 告警恢复" else "WinHardware Monitor — 硬件告警";
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
                _ = autostart.setAutoStart(config.start_with_windows);
                paths.ensureDirectories();
                if (config.saveFile(allocator, paths.settings_file)) |_| {
                    state.config_save_msg = "配置已保存";
                } else |_| {
                    state.config_save_msg = "保存失败，请检查目录权限";
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
                        state.config_save_msg = "已导出配置至 config/settings_backup.toml";
                    } else |_| {
                        state.config_save_msg = "配置导出失败，请检查目录权限";
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
                        state.config_save_msg = "已从 config/settings_backup.toml 导入并生效";
                    } else |_| {
                        state.config_save_msg = "未找到 config/settings_backup.toml";
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
            state.config_save_msg = "已恢复默认（点击保存后生效）";
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
                .idle_low_fps => zglfw.waitEventsTimeout(mode.waitTimeoutSeconds()),
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

        // 7. 绝对非阻塞拷贝后台快照（即使后台正在读磁盘或写 SQLite，UI 也绝不卡死白屏）
        if (monitor.tryCopySnapshot(ui_snapshot)) {
            state.active_alert_count = ui_snapshot.active_alert_count;
            if (ui_snapshot.has_system_sample and state.bench_cpu_threads == 4 and ui_snapshot.system.logical_cores > 0) {
                state.bench_cpu_threads = @intCast(ui_snapshot.system.logical_cores);
            }
        }
        const bench_snap = bench.copySnapshot();
        if (bench_snap.outcome == .running) {
            g_input_activity.store(true, .release);
        }
        _ = bench.tickGpuStressFrame();

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

        // 首帧渲染完成后再显示窗口，彻底杜绝管理员或普通用户启动时的白屏/白闪
        if (!window_shown and !opts.smoke_test) {
            window.show();
            window.focus();
            window_shown = true;
            g_input_activity.store(true, .release);
        }

        state.rendered_frames += 1;
        if (opts.smoke_test) {
            smoke_frames += 1;
            const pages = std.meta.tags(state_mod.Page);
            if (smoke_frames < pages.len) {
                state.current_page = pages[smoke_frames];
                // 同时在冒烟测试中切换浅色主题验证两套主题渲染无崩溃
                if (smoke_frames == pages.len / 2) {
                    state.theme_mode = .light;
                }
            } else {
                break;
            }
        }
    }
}
