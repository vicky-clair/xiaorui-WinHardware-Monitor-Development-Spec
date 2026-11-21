const std = @import("std");

/// 规范 §7 + V2.0 全部导航页面
pub const Page = enum(u8) {
    dashboard,
    cpu,
    gpu,
    memory,
    motherboard,
    disks,
    sensors,
    stress_test,
    history,
    alerts,
    settings,

    pub fn labelZh(self: Page) [:0]const u8 {
        return switch (self) {
            .dashboard => "硬件总览",
            .cpu => "处理器 CPU",
            .gpu => "显卡 GPU",
            .memory => "内存 RAM",
            .motherboard => "主板与传感器",
            .disks => "磁盘健康",
            .sensors => "全传感器表",
            .stress_test => "硬件测试",
            .history => "历史趋势",
            .alerts => "告警中心",
            .settings => "系统设置",
        };
    }

    pub fn badge(self: Page) [:0]const u8 {
        return switch (self) {
            .dashboard => "OV",
            .cpu => "CP",
            .gpu => "GP",
            .memory => "MM",
            .motherboard => "MB",
            .disks => "DK",
            .sensors => "SN",
            .stress_test => "BT",
            .history => "HS",
            .alerts => "AL",
            .settings => "ST",
        };
    }
};

/// 参照界面示例2.jpg 右上角分段切换
pub const TimeRange = enum(u8) {
    hour_1,
    hour_24,
    day_7,
    day_30,

    pub fn label(self: TimeRange) [:0]const u8 {
        return switch (self) {
            .hour_1 => "1h",
            .hour_24 => "24h",
            .day_7 => "7d",
            .day_30 => "30d",
        };
    }
};

pub const CloseBehavior = enum(u8) {
    minimize_to_tray,
    exit_app,

    pub fn labelZh(self: CloseBehavior) [:0]const u8 {
        return switch (self) {
            .minimize_to_tray => "最小化到系统托盘",
            .exit_app => "直接退出程序",
        };
    }
};

pub const MinimizeBehavior = enum(u8) {
    minimize_to_taskbar,
    minimize_to_tray,

    pub fn labelZh(self: MinimizeBehavior) [:0]const u8 {
        return switch (self) {
            .minimize_to_taskbar => "最小化到任务栏",
            .minimize_to_tray => "最小化到系统托盘",
        };
    }
};

pub const ThemeMode = enum(u8) {
    dark,
    light,

    pub fn labelZh(self: ThemeMode) [:0]const u8 {
        return switch (self) {
            .dark => "深色主题",
            .light => "浅色主题",
        };
    }
};

pub const TemperatureUnit = enum(u8) {
    celsius,
    fahrenheit,

    pub fn symbol(self: TemperatureUnit) [:0]const u8 {
        return switch (self) {
            .celsius => "°C",
            .fahrenheit => "°F",
        };
    }

    pub fn convert(self: TemperatureUnit, celsius: f64) f64 {
        return switch (self) {
            .celsius => celsius,
            .fahrenheit => celsius * 9.0 / 5.0 + 32.0,
        };
    }
};

/// 规范 §6.1 渲染节能状态机
pub const RenderMode = enum(u8) {
    active_60fps, // 窗口前台且有用户输入
    idle_low_fps, // 窗口可见但无输入（约 1–2 FPS）
    paused_hidden, // 窗口最小化或托盘隐藏（完全停止渲染）

    pub fn labelZh(self: RenderMode) [:0]const u8 {
        return switch (self) {
            .active_60fps => "活跃交互 (最高 60 FPS)",
            .idle_low_fps => "静止节能 (按需 2 FPS)",
            .paused_hidden => "后台休眠 (0 FPS 零渲染)",
        };
    }

    pub fn waitTimeoutSeconds(self: RenderMode) f64 {
        return switch (self) {
            .active_60fps => 0.0, // 由 swapInterval(1) 控制垂直同步
            .idle_low_fps => 0.5, // 2 FPS 按需重绘
            .paused_hidden => 0.25, // 不渲染，仅低频检查 Win32 托盘消息
        };
    }
};

pub const AppState = struct {
    current_page: Page = .dashboard,
    time_range: TimeRange = .hour_1,

    // 权限与运行状态
    is_admin: bool = false,
    extension_enabled: bool = false,
    monitoring_paused: bool = false,
    tray_available: bool = false,

    // 窗口与节能设置（规范 §2.6 / §6.1）
    theme_mode: ThemeMode = .dark,
    close_behavior: CloseBehavior = .minimize_to_tray,
    minimize_behavior: MinimizeBehavior = .minimize_to_taskbar,
    temp_unit: TemperatureUnit = .celsius,
    start_with_windows: bool = false,
    system_interval_ms: u32 = 2000,
    smart_interval_ms: u32 = 60000,
    allow_wake_standby_disk: bool = false,
    selected_disk_idx: usize = 0,
    request_reset_baseline_idx: ?usize = null,
    in_tray: bool = false,
    should_exit: bool = false,
    request_relaunch_admin: bool = false,
    request_launch_lhm_helper: bool = false,
    request_stop_lhm_helper: bool = false,
    request_save_config: bool = false,
    request_reset_config: bool = false,
    request_export_config: bool = false,
    request_import_config: bool = false,
    request_ack_alerts: bool = false,
    request_export_diag: bool = false,

    // V2: 全传感器统计与主动硬件测试控制
    request_reset_sensor_stats: bool = false,
    request_export_sensors_csv: bool = false,
    sensors_csv_msg: [:0]const u8 = "",

    bench_cpu_threads: i32 = 4,
    bench_duration_s: i32 = 30,
    bench_thermal_cutoff_c: i32 = 90,
    bench_mem_mb: i32 = 256,
    bench_disk_mb: i32 = 256,
    bench_disk_confirmed: bool = false,
    bench_smart_confirmed: bool = false,
    request_start_cpu_bench: bool = false,
    request_start_mem_bench: bool = false,
    request_start_disk_bench: bool = false,
    request_start_gpu_bench: bool = false,
    request_stop_bench: bool = false,
    request_export_bench_report: bool = false,
    request_ata_short_selftest_idx: ?usize = null,
    bench_msg: [:0]const u8 = "",
    selftest_msg: [:0]const u8 = "",

    // 路径与配置状态（P2/P6/P8）
    is_portable: bool = false,
    config_path: []const u8 = "",
    db_path: []const u8 = "",
    config_save_msg: [:0]const u8 = "",
    diag_export_msg: [:0]const u8 = "",
    lhm_action_msg: [:0]const u8 = "",
    desktop_notifications: bool = true,

    // 渲染节能状态
    render_mode: RenderMode = .active_60fps,
    last_input_ns: i128 = 0,
    dpi_scale: f32 = 1.0,
    rendered_frames: u64 = 0,
    skipped_frames: u64 = 0,
    font_source: []const u8 = "default",

    // 系统事件计数（热插拔 / 电源恢复）
    device_change_events: u64 = 0,
    power_resume_events: u64 = 0,

    // 告警状态（P7 接入真实引擎，P1 诚实显示 0）
    active_alert_count: u32 = 0,

    pub const IDLE_THRESHOLD_NS: i128 = 2 * std.time.ns_per_s;

    pub fn updateRenderMode(self: *AppState, now_ns: i128, is_visible: bool, is_iconified: bool, had_user_input: bool) RenderMode {
        if (!is_visible or is_iconified or self.in_tray) {
            self.render_mode = .paused_hidden;
            return self.render_mode;
        }
        if (had_user_input) {
            self.last_input_ns = now_ns;
            self.render_mode = .active_60fps;
            return self.render_mode;
        }
        if (now_ns - self.last_input_ns <= IDLE_THRESHOLD_NS) {
            self.render_mode = .active_60fps;
        } else {
            self.render_mode = .idle_low_fps;
        }
        return self.render_mode;
    }
};

test "RenderMode transitions obey §6.1 power saving policy" {
    var st = AppState{};
    const t0: i128 = 10 * std.time.ns_per_s;

    // Input keeps active 60 FPS
    try std.testing.expectEqual(RenderMode.active_60fps, st.updateRenderMode(t0, true, false, true));
    // Within 2s stays active
    try std.testing.expectEqual(RenderMode.active_60fps, st.updateRenderMode(t0 + 1 * std.time.ns_per_s, true, false, false));
    // After 2s without input drops to idle low FPS
    try std.testing.expectEqual(RenderMode.idle_low_fps, st.updateRenderMode(t0 + 3 * std.time.ns_per_s, true, false, false));
    // Minimized or in tray stops rendering completely
    try std.testing.expectEqual(RenderMode.paused_hidden, st.updateRenderMode(t0 + 4 * std.time.ns_per_s, true, true, false));
    st.in_tray = true;
    try std.testing.expectEqual(RenderMode.paused_hidden, st.updateRenderMode(t0 + 4 * std.time.ns_per_s, false, false, true));
}

test "TemperatureUnit converts Celsius to Fahrenheit" {
    try std.testing.expectApproxEqAbs(@as(f64, 40.0), TemperatureUnit.celsius.convert(40.0), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 104.0), TemperatureUnit.fahrenheit.convert(40.0), 1e-9);
}
