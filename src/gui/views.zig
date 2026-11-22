const std = @import("std");
const builtin = @import("builtin");
const zgui = @import("zgui");
const state_mod = @import("../app/state.zig");
const AppState = state_mod.AppState;
const theme = @import("theme.zig");
const widgets = @import("widgets.zig");
const monitoring = @import("../services/monitoring.zig");
const SharedTelemetry = monitoring.SharedTelemetry;
const benchmarks = @import("../core/benchmarks.zig");
const BenchmarkSnapshot = benchmarks.BenchmarkSnapshot;
const i18n = @import("../core/i18n.zig");
const autostart = @import("../platform/autostart.zig");

/// 规范 §7 + V2.0 全页面三语视图（简体中文 / English / 日本語）：
/// - 全部卡片依据窗口剩余高度动态延展，消除底部大面积空白；
/// - 全部长文本采用结构化分行与 textWrapped 自动换行，并允许卡片内滚动，确保文字 100% 完整可见；
/// - 全面适配深色 / 浅色（黑白）双主题与中英日实时无缝切换。
pub fn renderCurrentPage(state: *AppState, tel: *const SharedTelemetry, bench: *const BenchmarkSnapshot) void {
    const s = state.dpi_scale;

    renderTopHeader(state, tel);
    zgui.dummy(.{ .w = 0, .h = 10.0 * s });

    switch (state.current_page) {
        .dashboard => renderDashboard(state, tel),
        .cpu => renderCpuView(state, tel),
        .gpu => renderGpuView(state, tel),
        .memory => renderMemoryView(state, tel),
        .motherboard => renderMotherboardView(state, tel),
        .disks => renderDisksView(state, tel),
        .sensors => renderSensorsView(state, tel),
        .stress_test => renderStressTestView(state, tel, bench),
        .history => renderHistoryView(state, tel),
        .alerts => renderAlertsView(state, tel),
        .settings => renderSettingsView(state, tel),
    }
}

fn formatUptime(secs: u64, buf: *[64]u8) [:0]const u8 {
    const days = secs / 86400;
    const hours = (secs % 86400) / 3600;
    const mins = (secs % 3600) / 60;
    if (days > 0) {
        return std.fmt.bufPrintZ(buf, "{d}{s} {d}{s} {d}{s}", .{
            days,
            i18n.trSlice("天", "d", "日"),
            hours,
            i18n.trSlice("小时", "h", "時間"),
            mins,
            i18n.trSlice("分", "m", "分"),
        }) catch "N/A";
    }
    return std.fmt.bufPrintZ(buf, "{d}{s} {d}{s}", .{
        hours,
        i18n.trSlice("小时", "h", "時間"),
        mins,
        i18n.trSlice("分", "m", "分"),
    }) catch "N/A";
}

fn renderTopHeader(state: *AppState, _: *const SharedTelemetry) void {
    const s = state.dpi_scale;
    const p = theme.active();
    zgui.pushFont(null, 22.0 * s);
    zgui.textColored(p.text_primary, "{s}", .{state.current_page.labelZh()});
    zgui.popFont();

    zgui.sameLine(.{});
    const right_w = 270.0 * s;
    const avail_w = zgui.getContentRegionAvail()[0];
    if (avail_w > right_w) {
        zgui.setCursorPosX(zgui.getCursorPosX() + avail_w - right_w);
    }

    var alert_buf: [64]u8 = undefined;
    const alert_txt = std.fmt.bufPrintZ(&alert_buf, "{s}: {d}", .{
        i18n.tr("当前告警", "Alerts", "アラート"),
        state.active_alert_count,
    }) catch "Alerts: 0";
    widgets.drawStatusPill(
        alert_txt,
        if (state.active_alert_count == 0) p.status_ok else p.status_critical,
        s,
    );
    zgui.sameLine(.{});
    widgets.drawStatusPill(
        if (state.monitoring_paused)
            i18n.tr("采集已暂停", "Paused", "一時停止中")
        else
            i18n.tr("实时采集中", "Live Monitoring", "リアルタイム監視"),
        if (state.monitoring_paused) p.status_caution else p.accent_blue,
        s,
    );
}

fn renderDashboard(state: *AppState, tel: *const SharedTelemetry) void {
    const s = state.dpi_scale;
    const p = theme.active();
    const avail = zgui.getContentRegionAvail();
    const avail_w = avail[0];
    const avail_h = avail[1];
    const gap = 12.0 * s;

    const col3_w = @max(220.0 * s, (avail_w - gap * 2.0) / 3.0);
    const row1_h = @max(248.0 * s, (avail_h - gap) * 0.44);
    const row2_h = @max(310.0 * s, avail_h - row1_h - gap);

    // Card 1: 内存占用环形仪表
    if (widgets.beginCard(
        "##dash_mem_donut",
        i18n.tr("物理内存占用", "Physical Memory", "物理メモリ使用率"),
        i18n.tr("系统内存实时采样", "Live OS memory telemetry", "OS メモリリアルタイム計測"),
        col3_w,
        row1_h,
        s,
        null,
    )) {
        const inner_h = @max(150.0 * s, zgui.getContentRegionAvail()[1] - 4.0 * s);
        if (tel.has_system_sample and tel.system.mem_load_pct != null) {
            const pct = tel.system.mem_load_pct.?;
            const used_gb = @as(f64, @floatFromInt(tel.system.mem_used_bytes)) / (1024.0 * 1024.0 * 1024.0);
            const total_gb = @as(f64, @floatFromInt(tel.system.mem_total_bytes)) / (1024.0 * 1024.0 * 1024.0);
            var big_buf: [32]u8 = undefined;
            var foot_buf: [80]u8 = undefined;
            const big_txt = std.fmt.bufPrintZ(&big_buf, "{d:.1}%", .{pct}) catch "N/A";
            const foot_txt = if (tel.system.smbios_info.primaryMemorySpeedMhz()) |spd|
                std.fmt.bufPrintZ(&foot_buf, "{d:.1} / {d:.1} GB  •  {d} MHz", .{ used_gb, total_gb, spd }) catch ""
            else
                std.fmt.bufPrintZ(&foot_buf, "{d:.1} / {d:.1} GB", .{ used_gb, total_gb }) catch "";

            const col = if (pct >= 90.0) p.status_critical else if (pct >= 80.0) p.status_caution else p.status_ok;
            widgets.drawDonutGauge(@floatCast(pct / 100.0), big_txt, i18n.tr("已使用", "Used", "使用中"), foot_txt, col, inner_h, s);
        } else {
            widgets.drawDonutGauge(
                null,
                i18n.tr("采集中", "Loading", "計測中"),
                i18n.tr("初始化", "Init", "初期化"),
                i18n.tr("正在等待首个系统快照", "Waiting for first snapshot", "初回スナップショット待機中"),
                p.accent_blue,
                inner_h,
                s,
            );
        }
    }
    widgets.endCard();

    zgui.sameLine(.{ .spacing = gap });

    // Card 2: 内存实时面积趋势图
    if (widgets.beginCard(
        "##dash_mem_card",
        i18n.tr("内存使用趋势", "Memory Usage Trend", "メモリ使用率推移"),
        i18n.tr("内存环形缓冲区（最近 60 秒窗口）", "Ring buffer (last 60s window)", "リングバッファ（直近60秒）"),
        col3_w,
        row1_h,
        s,
        &state.time_range,
    )) {
        const inner_h = @max(150.0 * s, zgui.getContentRegionAvail()[1] - 4.0 * s);
        widgets.drawLiveAreaPlot(
            monitoring.HISTORY_CAPACITY,
            "##dash_mem_plot",
            "RAM%",
            "%",
            0,
            100,
            "%",
            p.accent_blue,
            &tel.mem_usage_history,
            i18n.tr("等待首个内存采集样本...", "Waiting for memory sample...", "メモリ計測待機中..."),
            inner_h,
            s,
        );
    }
    widgets.endCard();

    zgui.sameLine(.{ .spacing = gap });

    // Card 3: CPU 实时使用率圆弧仪表
    if (widgets.beginCard(
        "##dash_cpu_gauge",
        i18n.tr("CPU 实时占用", "CPU Load", "CPU 使用率"),
        i18n.tr("PDH / 系统内核时间实时采样", "PDH / OS kernel counters", "PDH / カーネルカウンタ計測"),
        col3_w,
        row1_h,
        s,
        null,
    )) {
        const inner_h = @max(150.0 * s, zgui.getContentRegionAvail()[1] - 4.0 * s);
        if (tel.has_system_sample and tel.system.cpu_usage_pct != null) {
            const pct = tel.system.cpu_usage_pct.?;
            var val_buf: [32]u8 = undefined;
            var cap_buf: [96]u8 = undefined;
            const val_txt = std.fmt.bufPrintZ(&val_buf, "{d:.1}%", .{pct}) catch "N/A";
            const cap_txt = if (tel.system.cpu_clock_mhz) |mhz|
                std.fmt.bufPrintZ(&cap_buf, "{d} {s}  •  {d:.2} GHz", .{
                    tel.system.logical_cores,
                    i18n.trSlice("线程", "Threads", "スレッド"),
                    mhz / 1000.0,
                }) catch ""
            else
                std.fmt.bufPrintZ(&cap_buf, "{d} {s}", .{
                    tel.system.logical_cores,
                    i18n.trSlice("逻辑处理器", "Logical CPUs", "論理プロセッサ"),
                }) catch "";
            const col = if (pct >= 90.0) p.status_critical else if (pct >= 75.0) p.status_caution else p.status_ok;
            widgets.drawArcGauge(@floatCast(pct / 100.0), val_txt, cap_txt, col, inner_h, s);
        } else {
            widgets.drawArcGauge(null, "N/A", i18n.tr("正在采集首个 CPU 样本...", "Waiting for CPU sample...", "CPU 計測待機中..."), p.accent_blue, inner_h, s);
        }
    }
    widgets.endCard();

    zgui.dummy(.{ .w = 0, .h = gap });

    // Row 2: 宽曲线 + 传感器状态表
    const wide_w = @max(320.0 * s, (avail_w - gap) * 0.56);
    const side_w = @max(300.0 * s, avail_w - wide_w - gap);

    if (widgets.beginCard(
        "##dash_cpu_trend",
        i18n.tr("CPU 使用率实时趋势", "CPU Usage History", "CPU 使用率推移"),
        i18n.tr("数据源：PDH % Processor Utility（回退 GetSystemTimes）", "Source: PDH % Processor Utility (fallback GetSystemTimes)", "取得元：PDH / OS システム時間"),
        wide_w,
        row2_h,
        s,
        &state.time_range,
    )) {
        const inner_h = @max(170.0 * s, zgui.getContentRegionAvail()[1] - 4.0 * s);
        widgets.drawLiveAreaPlot(
            monitoring.HISTORY_CAPACITY,
            "##dash_cpu_plot",
            "CPU%",
            "%",
            0,
            100,
            "%",
            p.accent_cyan,
            &tel.cpu_usage_history,
            i18n.tr("等待首个 CPU 采集样本...", "Waiting for CPU sample...", "CPU 計測待機中..."),
            inner_h,
            s,
        );
    }
    widgets.endCard();

    zgui.sameLine(.{ .spacing = gap });

    if (widgets.beginCard(
        "##dash_status_card",
        i18n.tr("传感器采集状态", "Sensor Acquisition Status", "センサー取得ステータス"),
        i18n.tr("按规范 §1.2.1 权限能力矩阵实时报告", "Live capability matrix (§1.2.1)", "権限マトリクス準拠のリアルタイム状態"),
        side_w,
        row2_h,
        s,
        null,
    )) {
        if (zgui.beginTable("##dash_sensor_tbl", .{
            .column = 3,
            .flags = .{ .borders = .{ .inner_h = true }, .sizing = .stretch_prop },
        })) {
            zgui.tableSetupColumn(i18n.tr("传感器项目", "Sensor", "センサー項目"), .{ .init_width_or_height = 1.4 });
            zgui.tableSetupColumn(i18n.tr("当前读数", "Value", "現在値"), .{ .init_width_or_height = 0.85 });
            zgui.tableSetupColumn(i18n.tr("状态 / 来源", "Status / Source", "状態 / 取得元"), .{ .init_width_or_height = 1.15 });
            zgui.tableHeadersRow();

            var cpu_val_buf: [32]u8 = undefined;
            const cpu_val = if (tel.has_system_sample and tel.system.cpu_usage_pct != null)
                std.fmt.bufPrintZ(&cpu_val_buf, "{d:.1}%", .{tel.system.cpu_usage_pct.?}) catch "N/A"
            else
                "N/A";
            widgets.drawMetricTableRow(
                i18n.tr("CPU 使用率", "CPU Usage", "CPU 使用率"),
                cpu_val,
                if (tel.has_system_sample) tel.system.cpu_usage_status else .unknown,
                if (tel.has_system_sample and tel.system.cpu_usage_status == .ok)
                    i18n.tr("实测值", "Measured", "実測値")
                else
                    i18n.tr("采集中", "Sampling", "計測中"),
                s,
            );

            var clk_val_buf: [32]u8 = undefined;
            const clk_val = if (tel.has_system_sample and tel.system.cpu_clock_mhz != null)
                std.fmt.bufPrintZ(&clk_val_buf, "{d:.2} GHz", .{tel.system.cpu_clock_mhz.? / 1000.0}) catch "N/A"
            else
                "N/A";
            widgets.drawMetricTableRow(
                i18n.tr("CPU 频率", "CPU Clock", "CPU クロック"),
                clk_val,
                if (tel.has_system_sample) tel.system.cpu_clock_status else .unknown,
                if (tel.has_system_sample and tel.system.cpu_clock_status == .ok)
                    i18n.tr("计算值", "Computed", "算出値")
                else
                    i18n.tr("采集中", "Sampling", "計測中"),
                s,
            );

            if (tel.extension.connected and tel.extension.cpu_package_temp_c != null) {
                var ct_buf: [32]u8 = undefined;
                const ct_txt = std.fmt.bufPrintZ(&ct_buf, "{d:.1}{s}", .{
                    state.temp_unit.convert(tel.extension.cpu_package_temp_c.?),
                    state.temp_unit.symbol(),
                }) catch "N/A";
                widgets.drawMetricTableRow(i18n.tr("CPU 封装温度", "CPU Package Temp", "CPU パッケージ温度"), ct_txt, .ok, i18n.tr("扩展组件 (LHM)", "Extension (LHM)", "拡張機能 (LHM)"), s);
            } else {
                widgets.drawMetricTableRow(
                    i18n.tr("CPU 封装温度", "CPU Package Temp", "CPU パッケージ温度"),
                    "N/A",
                    if (state.extension_enabled) .transient_error else .requires_extension,
                    if (state.extension_enabled) i18n.tr("等待辅助进程", "Waiting Helper", "ヘルパー待機中") else i18n.tr("需要扩展组件", "Extension Req.", "拡張機能が必要"),
                    s,
                );
            }

            if (tel.has_gpu_sample and tel.gpu.count > 0 and tel.gpu.gpus[0].temp_c != null) {
                const g0 = &tel.gpu.gpus[0];
                var gt_buf: [32]u8 = undefined;
                const gt_txt = std.fmt.bufPrintZ(&gt_buf, "{d:.1}{s}", .{ state.temp_unit.convert(g0.temp_c.?), state.temp_unit.symbol() }) catch "N/A";
                widgets.drawMetricTableRow(i18n.tr("GPU 温度", "GPU Temp", "GPU 温度"), gt_txt, g0.temp_status, g0.temp_source, s);
            } else {
                widgets.drawMetricTableRow(i18n.tr("GPU 温度", "GPU Temp", "GPU 温度"), "N/A", .unsupported, i18n.tr("无传感器", "No Sensor", "センサーなし"), s);
            }

            if (tel.has_disk_inventory and tel.disk_count > 0) {
                const d0 = &tel.disk_states[0];
                var dt_buf: [32]u8 = undefined;
                const dt_txt = if (d0.effectiveTempC()) |tc|
                    std.fmt.bufPrintZ(&dt_buf, "{d:.0}{s}", .{ state.temp_unit.convert(@floatFromInt(tc)), state.temp_unit.symbol() }) catch "N/A"
                else
                    "N/A";
                widgets.drawMetricTableRow(i18n.tr("主磁盘温度 / 健康", "Disk 0 Temp / Health", "ディスク0 温度/健康"), dt_txt, d0.effectiveTempStatus(), d0.assessment.overall.labelZh(), s);
            } else {
                widgets.drawMetricTableRow(i18n.tr("物理磁盘 SMART", "Physical Disk SMART", "物理ディスク SMART"), "N/A", .unknown, i18n.tr("枚举中", "Scanning", "スキャン中"), s);
            }

            widgets.drawMetricTableRow(
                "ATA SMART (SATA)",
                "N/A",
                if (state.is_admin) .unknown else .access_denied,
                if (state.is_admin) i18n.tr("按盘检测", "Per-Disk", "ドライブ別検出") else i18n.tr("需要管理员", "Admin Req.", "管理者権限が必要"),
                s,
            );
            if (tel.extension.connected and tel.extension.sensor_count > 0) {
                var ext_cnt_buf: [48]u8 = undefined;
                const ext_cnt_txt = std.fmt.bufPrintZ(&ext_cnt_buf, "{d} {s}", .{
                    tel.extension.sensor_count,
                    i18n.trSlice("项在线", "online", "件稼働"),
                }) catch "Online";
                widgets.drawMetricTableRow(i18n.tr("主板 / Super I/O", "Board / Super I/O", "マザーボード / I/O"), ext_cnt_txt, .ok, i18n.tr("扩展组件 (LHM)", "Extension (LHM)", "拡張機能 (LHM)"), s);
            } else {
                widgets.drawMetricTableRow(
                    i18n.tr("主板 / Super I/O", "Board / Super I/O", "マザーボード / I/O"),
                    "N/A",
                    if (state.extension_enabled) .transient_error else .requires_extension,
                    if (state.extension_enabled) i18n.tr("辅助进程未连", "Helper Offline", "ヘルパー未接続") else i18n.tr("需要扩展组件", "Extension Req.", "拡張機能が必要"),
                    s,
                );
            }

            zgui.endTable();
        }
    }
    widgets.endCard();
}

fn renderCpuView(state: *AppState, tel: *const SharedTelemetry) void {
    const s = state.dpi_scale;
    const p = theme.active();
    const avail = zgui.getContentRegionAvail();
    const gap = 12.0 * s;

    const top_h = 205.0 * s;
    const bot_h = @max(260.0 * s, avail[1] - top_h - gap);

    if (widgets.beginCard(
        "##cpu_meta",
        i18n.tr("处理器规格与每核实时负载", "Processor Specs & Per-Core Load", "プロセッサ仕様・コア別負荷"),
        i18n.tr("数据来源：系统信息 / PDH / 每核内核性能计数器", "Source: OS Info / PDH / Per-Core Kernel Counters", "取得元：OS 情報 / PDH / コア別カーネルカウンタ"),
        -1.0,
        top_h,
        s,
        null,
    )) {
        if (tel.has_system_sample) {
            zgui.pushFont(null, 18.0 * s);
            zgui.textColored(p.text_primary, "{s}", .{tel.system.cpuNameSlice()});
            zgui.popFont();
            zgui.dummy(.{ .w = 0, .h = 4.0 * s });

            var line1: [220]u8 = undefined;
            const s1 = std.fmt.bufPrint(&line1, "{d} {s}   •   {s} {d} MHz   •   {s}: {s} ({s})", .{
                tel.system.logical_cores,
                i18n.trSlice("线程", "Threads", "スレッド"),
                i18n.trSlice("基础频率", "Base Clock", "ベースクロック"),
                tel.system.base_clock_mhz,
                i18n.trSlice("来源", "Source", "取得元"),
                tel.system.cpu_clock_source,
                tel.system.cpu_clock_accuracy.labelZh(),
            }) catch "";
            widgets.drawKeyValueLine(i18n.tr("核心与频率", "Cores & Clock", "コア・クロック"), s1);

            if (tel.system.per_core_count > 0) {
                zgui.dummy(.{ .w = 0, .h = 4.0 * s });
                const cols: usize = @min(tel.system.per_core_count, 6);
                if (zgui.beginTable("##cpu_per_core_tbl", .{
                    .column = @intCast(cols),
                    .flags = .{ .sizing = .stretch_same },
                })) {
                    for (0..tel.system.per_core_count) |ci| {
                        if (ci % cols == 0) zgui.tableNextRow(.{});
                        _ = zgui.tableNextColumn();
                        const pct = tel.system.per_core_usage[ci];
                        var ov_buf: [32]u8 = undefined;
                        const ov = std.fmt.bufPrintZ(&ov_buf, "C{d}: {d:.0}%", .{ ci, pct }) catch "C?";
                        const bar_col = if (pct >= 90.0) p.status_critical else if (pct >= 70.0) p.status_caution else p.accent_blue;
                        zgui.pushStyleColor4f(.{ .idx = .plot_histogram, .c = bar_col });
                        zgui.progressBar(.{ .fraction = pct / 100.0, .w = -1.0, .h = 18.0 * s, .overlay = ov });
                        zgui.popStyleColor(.{ .count = 1 });
                    }
                    zgui.endTable();
                }
            }
        } else {
            zgui.textColored(p.text_muted, "{s}", .{i18n.tr("正在采集处理器信息...", "Sampling CPU info...", "CPU 情報を取得中...")});
        }
    }
    widgets.endCard();

    zgui.dummy(.{ .w = 0, .h = gap });

    const left_w = (avail[0] - gap) * 0.66;
    const right_w = avail[0] - left_w - gap;

    if (widgets.beginCard(
        "##cpu_usage_card",
        i18n.tr("CPU 使用率实时曲线", "CPU Utilization History", "CPU 使用率リアルタイム推移"),
        i18n.tr("禁止将 ACPI 热区温度冒充 CPU 温度", "ACPI thermal zones are never misrepresented as CPU temp", "ACPI サーマルゾーンを CPU 温度として誤表示しません"),
        left_w,
        bot_h,
        s,
        &state.time_range,
    )) {
        const inner_h = @max(170.0 * s, zgui.getContentRegionAvail()[1] - 4.0 * s);
        widgets.drawLiveAreaPlot(
            monitoring.HISTORY_CAPACITY,
            "##cpu_plot",
            "CPU%",
            "%",
            0,
            100,
            "%",
            p.accent_blue,
            &tel.cpu_usage_history,
            i18n.tr("等待 CPU 实时采样...", "Waiting for CPU sample...", "CPU サンプル待機中..."),
            inner_h,
            s,
        );
    }
    widgets.endCard();

    zgui.sameLine(.{ .spacing = gap });

    if (widgets.beginCard(
        "##cpu_temp_gauge",
        i18n.tr("CPU 封装温度", "CPU Package Temp", "CPU パッケージ温度"),
        i18n.tr("需启用可选 LibreHardwareMonitor 扩展组件", "Requires optional LibreHardwareMonitor extension", "任意拡張 LibreHardwareMonitor ヘルパーが必要"),
        right_w,
        bot_h,
        s,
        null,
    )) {
        const inner_h = @max(170.0 * s, zgui.getContentRegionAvail()[1] - 34.0 * s);
        if (tel.extension.connected and tel.extension.cpu_package_temp_c != null) {
            const tc = tel.extension.cpu_package_temp_c.?;
            var vt_buf: [32]u8 = undefined;
            const vt = std.fmt.bufPrintZ(&vt_buf, "{d:.1}{s}", .{ state.temp_unit.convert(tc), state.temp_unit.symbol() }) catch "N/A";
            var cap_buf: [64]u8 = undefined;
            const cap = if (tel.extension.cpu_package_power_w) |pw|
                std.fmt.bufPrintZ(&cap_buf, "LHM • {s} {d:.1} W", .{ i18n.trSlice("功耗", "Power", "電力"), pw }) catch "LHM"
            else
                i18n.tr("扩展组件 (LHM 实测)", "Extension (LHM Live)", "拡張機能 (LHM 実測)");
            const col = if (tc >= 90.0) p.status_critical else if (tc >= 80.0) p.status_caution else p.status_ok;
            widgets.drawArcGauge(@floatCast(std.math.clamp(tc / 100.0, 0.0, 1.0)), vt, cap, col, inner_h, s);
        } else {
            const cap: [:0]const u8 = if (state.extension_enabled)
                (if (tel.extension.connected)
                    i18n.tr("已连接但需管理员/驱动读取温度", "Connected; admin/driver required", "接続済（管理者権限/ドライバが必要）")
                else
                    i18n.tr("辅助进程未运行", "Helper not running", "ヘルパー未稼働"))
            else
                i18n.tr("需要扩展组件（默认关闭）", "Extension required (off by default)", "拡張機能が必要（初期オフ）");
            widgets.drawArcGauge(null, "N/A", cap, p.status_caution, inner_h, s);
            if (!tel.extension.connected) {
                if (zgui.button(i18n.tr("启动扩展组件 (需管理员)", "Launch Extension (Admin)", "拡張ヘルパー起動 (管理者)"), .{ .w = -1.0, .h = 28.0 * s })) {
                    state.request_launch_lhm_helper = true;
                }
            }
        }
    }
    widgets.endCard();
}

fn renderGpuView(state: *AppState, tel: *const SharedTelemetry) void {
    const s = state.dpi_scale;
    const p = theme.active();
    const avail = zgui.getContentRegionAvail();
    const gap = 12.0 * s;

    const top_h = 172.0 * s;
    const bot_h = @max(280.0 * s, avail[1] - top_h - gap);

    if (widgets.beginCard(
        "##gpu_meta",
        i18n.tr("图形处理器规格与实时参数", "GPU Specs & Live Telemetry", "GPU 仕様・リアルタイム計測"),
        i18n.tr("数据源：动态 NVML / 通用 D3DKMT（普通用户权限可用）", "Source: Dynamic NVML / D3DKMT (standard user supported)", "取得元：動的 NVML / 汎用 D3DKMT（標準権限対応）"),
        -1.0,
        top_h,
        s,
        null,
    )) {
        if (tel.has_gpu_sample and tel.gpu.count > 0) {
            const g0 = &tel.gpu.gpus[0];
            zgui.pushFont(null, 18.0 * s);
            zgui.textColored(p.text_primary, "{s}", .{g0.nameSlice()});
            zgui.popFont();
            zgui.dummy(.{ .w = 0, .h = 6.0 * s });

            var row1: [220]u8 = undefined;
            var pwr_buf: [24]u8 = undefined;
            const pwr_txt = if (g0.power_watts) |w| std.fmt.bufPrint(&pwr_buf, "{d:.1} W", .{w}) catch "N/A" else "N/A";
            var vram_buf: [40]u8 = undefined;
            const vram_txt = if (g0.mem_used_bytes != null and g0.mem_total_bytes != null)
                std.fmt.bufPrint(&vram_buf, "{d:.1} / {d:.1} GB", .{
                    @as(f64, @floatFromInt(g0.mem_used_bytes.?)) / (1024.0 * 1024.0 * 1024.0),
                    @as(f64, @floatFromInt(g0.mem_total_bytes.?)) / (1024.0 * 1024.0 * 1024.0),
                }) catch "N/A"
            else
                "N/A";
            var util_buf: [16]u8 = undefined;
            const util_txt = if (g0.usage_pct) |u| std.fmt.bufPrint(&util_buf, "{d:.0}%", .{u}) catch "N/A" else "N/A";
            const r1 = std.fmt.bufPrint(&row1, "{s} {s}   •   VRAM {s}   •   {s} {s}", .{
                i18n.trSlice("功耗", "Power", "電力"),
                pwr_txt,
                vram_txt,
                i18n.trSlice("占用率", "Load", "使用率"),
                util_txt,
            }) catch "";
            widgets.drawKeyValueLine(i18n.tr("功耗与显存", "Power & VRAM", "電力・VRAM"), r1);

            var row2: [220]u8 = undefined;
            var clk_buf: [64]u8 = undefined;
            const clk_txt = if (g0.core_clock_mhz) |c|
                std.fmt.bufPrint(&clk_buf, "{s} {d} MHz / VRAM {d} MHz", .{ i18n.trSlice("核心", "Core", "コア"), c, g0.mem_clock_mhz orelse 0 }) catch "N/A"
            else if (g0.mem_clock_mhz) |m|
                std.fmt.bufPrint(&clk_buf, "VRAM {d} MHz", .{m}) catch "N/A"
            else
                "N/A";
            var fan_buf: [24]u8 = undefined;
            const fan_txt = if (g0.fan_rpm) |rpm|
                std.fmt.bufPrint(&fan_buf, "{d} RPM", .{rpm}) catch "N/A"
            else if (g0.fan_pct) |fp|
                std.fmt.bufPrint(&fan_buf, "{d}%", .{fp}) catch "N/A"
            else
                "N/A";
            const r2 = std.fmt.bufPrint(&row2, "{s}   •   {s} {s}   •   {s}: {s}   •   GPUs: {d}", .{
                clk_txt,
                i18n.trSlice("风扇", "Fan", "ファン"),
                fan_txt,
                i18n.trSlice("温度来源", "Temp Source", "温度取得元"),
                g0.temp_source,
                tel.gpu.count,
            }) catch "";
            widgets.drawKeyValueLine(i18n.tr("频率与散热", "Clocks & Cooling", "クロック・冷却"), r2);
        } else {
            zgui.textColored(p.text_muted, "{s}", .{i18n.tr("正在采集 GPU 信息...", "Sampling GPU info...", "GPU 情報を取得中...")});
        }
    }
    widgets.endCard();

    zgui.dummy(.{ .w = 0, .h = gap });

    const left_w = (avail[0] - gap) * 0.66;
    const right_w = avail[0] - left_w - gap;

    if (widgets.beginCard(
        "##gpu_trend_card",
        i18n.tr("GPU 温度实时曲线", "GPU Temperature History", "GPU 温度推移"),
        i18n.tr("实时面积趋势 + 当前 / 平均 / 峰值 统计", "Live area trend + Cur / Avg / Max stats", "リアルタイム推移＋現在/平均/最大統計"),
        left_w,
        bot_h,
        s,
        &state.time_range,
    )) {
        const inner_h = @max(170.0 * s, zgui.getContentRegionAvail()[1] - 4.0 * s);
        widgets.drawLiveAreaPlot(
            monitoring.HISTORY_CAPACITY,
            "##gpu_plot",
            "GPU °C",
            "°C",
            20,
            100,
            "°C",
            p.status_ok,
            &tel.gpu_temp_history,
            i18n.tr("等待 GPU 温度样本...", "Waiting for GPU temp sample...", "GPU 温度サンプル待機中..."),
            inner_h,
            s,
        );
    }
    widgets.endCard();

    zgui.sameLine(.{ .spacing = gap });

    if (widgets.beginCard(
        "##gpu_gauge_card",
        i18n.tr("GPU 核心温度", "GPU Core Temperature", "GPU コア温度"),
        i18n.tr("多 GPU 独立 Provider 隔离", "Isolated per-GPU telemetry provider", "マルチ GPU 独立プロバイダ分離"),
        right_w,
        bot_h,
        s,
        null,
    )) {
        const inner_h = @max(170.0 * s, zgui.getContentRegionAvail()[1] - 4.0 * s);
        if (tel.has_gpu_sample and tel.gpu.count > 0 and tel.gpu.gpus[0].temp_c != null) {
            const tc = tel.gpu.gpus[0].temp_c.?;
            const disp_t = state.temp_unit.convert(tc);
            var vt_buf: [32]u8 = undefined;
            const vt = std.fmt.bufPrintZ(&vt_buf, "{d:.1}{s}", .{ disp_t, state.temp_unit.symbol() }) catch "N/A";
            const col = if (tc >= 90.0) p.status_critical else if (tc >= 80.0) p.status_caution else p.status_ok;
            widgets.drawArcGauge(@floatCast(std.math.clamp(tc / 100.0, 0.0, 1.0)), vt, tel.gpu.gpus[0].temp_source, col, inner_h, s);
        } else {
            widgets.drawArcGauge(null, "N/A", i18n.tr("无可用 GPU 温度传感器", "No GPU temperature sensor", "GPU 温度センサーなし"), p.status_unknown, inner_h, s);
        }
    }
    widgets.endCard();
}

fn renderMemoryView(state: *AppState, tel: *const SharedTelemetry) void {
    const s = state.dpi_scale;
    const p = theme.active();
    const avail = zgui.getContentRegionAvail();
    const gap = 12.0 * s;

    const top_h = @max(250.0 * s, (avail[1] - gap) * 0.46);
    const bot_h = @max(220.0 * s, avail[1] - top_h - gap);
    const left_w = @max(240.0 * s, (avail[0] - gap) * 0.34);
    const right_w = avail[0] - left_w - gap;

    if (widgets.beginCard(
        "##mem_donut_card",
        i18n.tr("物理内存使用率", "Physical Memory Load", "物理メモリ使用率"),
        i18n.tr("系统内存实时数据", "Live physical memory usage", "リアルタイム物理メモリ計測"),
        left_w,
        top_h,
        s,
        null,
    )) {
        const inner_h = @max(150.0 * s, zgui.getContentRegionAvail()[1] - 4.0 * s);
        if (tel.has_system_sample and tel.system.mem_load_pct != null) {
            const pct = tel.system.mem_load_pct.?;
            const used_gb = @as(f64, @floatFromInt(tel.system.mem_used_bytes)) / (1024.0 * 1024.0 * 1024.0);
            const avail_gb = @as(f64, @floatFromInt(tel.system.mem_avail_bytes)) / (1024.0 * 1024.0 * 1024.0);
            const total_gb = @as(f64, @floatFromInt(tel.system.mem_total_bytes)) / (1024.0 * 1024.0 * 1024.0);
            var big_buf: [32]u8 = undefined;
            var foot_buf: [96]u8 = undefined;
            const big_txt = std.fmt.bufPrintZ(&big_buf, "{d:.1}%", .{pct}) catch "N/A";
            const foot_txt = std.fmt.bufPrintZ(&foot_buf, "{s} {d:.1} GB  •  {s} {d:.1} / {d:.1} GB", .{
                i18n.trSlice("已用", "Used", "使用"),
                used_gb,
                i18n.trSlice("可用", "Free", "空き"),
                avail_gb,
                total_gb,
            }) catch "";
            widgets.drawDonutGauge(@floatCast(pct / 100.0), big_txt, i18n.tr("已使用", "Used", "使用中"), foot_txt, p.accent_blue, inner_h, s);
        } else {
            widgets.drawDonutGauge(null, "N/A", i18n.tr("采集中", "Sampling", "計測中"), i18n.tr("正在读取系统内存", "Reading OS memory", "メモリ情報取得中"), p.accent_blue, inner_h, s);
        }
    }
    widgets.endCard();

    zgui.sameLine(.{ .spacing = gap });

    if (widgets.beginCard(
        "##mem_trend_card",
        i18n.tr("内存使用历史趋势", "Memory Usage History", "メモリ使用率履歴"),
        i18n.tr("实时环形缓冲区（每 2 秒采样）", "Live ring buffer (2s polling)", "リングバッファ（2秒間隔）"),
        right_w,
        top_h,
        s,
        &state.time_range,
    )) {
        const inner_h = @max(150.0 * s, zgui.getContentRegionAvail()[1] - 4.0 * s);
        widgets.drawLiveAreaPlot(
            monitoring.HISTORY_CAPACITY,
            "##mem_plot",
            "RAM%",
            "%",
            0,
            100,
            "%",
            p.accent_blue,
            &tel.mem_usage_history,
            i18n.tr("等待首个内存采集样本...", "Waiting for memory sample...", "メモリ計測待機中..."),
            inner_h,
            s,
        );
    }
    widgets.endCard();

    zgui.dummy(.{ .w = 0, .h = gap });

    if (widgets.beginCard(
        "##mem_dimm_table",
        i18n.tr("SMBIOS 物理内存插槽明细", "SMBIOS Physical Memory DIMMs", "SMBIOS 物理メモリスロット詳細"),
        i18n.tr("数据来源：SMBIOS Type 17 • 序列号默认脱敏", "Source: SMBIOS Type 17 • Serials masked by default", "取得元：SMBIOS Type 17 • シリアル番号マスク済"),
        -1.0,
        bot_h,
        s,
        null,
    )) {
        if (tel.has_system_sample and tel.system.smbios_info.dimm_count > 0) {
            if (zgui.beginTable("##dimms", .{
                .column = 7,
                .flags = .{ .borders = .{ .inner_h = true }, .row_bg = true, .sizing = .stretch_prop, .scroll_y = true },
            })) {
                zgui.tableSetupColumn(i18n.tr("插槽", "Slot", "スロット"), .{});
                zgui.tableSetupColumn(i18n.tr("类型", "Type", "種類"), .{});
                zgui.tableSetupColumn(i18n.tr("容量", "Capacity", "容量"), .{});
                zgui.tableSetupColumn(i18n.tr("运行频率", "Speed", "動作速度"), .{});
                zgui.tableSetupColumn(i18n.tr("厂商", "Vendor", "メーカー"), .{});
                zgui.tableSetupColumn(i18n.tr("型号", "Part Number", "型番"), .{});
                zgui.tableSetupColumn(i18n.tr("序列号 (脱敏)", "Serial (Masked)", "シリアル (マスク)"), .{});
                zgui.tableHeadersRow();

                for (tel.system.smbios_info.dimms[0..tel.system.smbios_info.dimm_count]) |d| {
                    zgui.tableNextRow(.{});
                    _ = zgui.tableNextColumn();
                    zgui.text("{s}", .{if (d.slot_len > 0) d.slotSlice() else "N/A"});
                    _ = zgui.tableNextColumn();
                    zgui.text("{s}", .{d.memoryTypeName()});
                    _ = zgui.tableNextColumn();
                    zgui.text("{d:.1} GB", .{@as(f64, @floatFromInt(d.size_mb)) / 1024.0});
                    _ = zgui.tableNextColumn();
                    const spd = d.effectiveSpeedMhz();
                    if (spd > 0) zgui.text("{d} MHz", .{spd}) else zgui.textColored(p.text_muted, "N/A", .{});
                    _ = zgui.tableNextColumn();
                    zgui.text("{s}", .{if (d.manufacturer_len > 0) d.manufacturerSlice() else i18n.trSlice("未知", "Unknown", "不明")});
                    _ = zgui.tableNextColumn();
                    zgui.text("{s}", .{if (d.part_number_len > 0) d.partNumberSlice() else "N/A"});
                    _ = zgui.tableNextColumn();
                    zgui.textColored(p.text_secondary, "{s}", .{d.serialMaskedSlice()});
                }
                zgui.endTable();
            }
        } else {
            zgui.textColored(p.text_muted, "{s}", .{i18n.tr(
                "当前 SMBIOS 表未返回有效内存条记录（常见于部分虚拟机或受限固件）。",
                "No valid DIMM entries returned by SMBIOS (common on VMs or restricted firmware).",
                "SMBIOS テーブルに有効なメモリ情報がありません（仮想環境等で一般的）。",
            )});
        }
    }
    widgets.endCard();
}

fn renderMotherboardView(state: *AppState, tel: *const SharedTelemetry) void {
    const s = state.dpi_scale;
    const p = theme.active();
    const avail_h = zgui.getContentRegionAvail()[1];
    const gap = 12.0 * s;
    const top_h = 212.0 * s;
    const bot_h = @max(220.0 * s, avail_h - top_h - gap);

    if (widgets.beginCard(
        "##mb_smbios_card",
        i18n.tr("主板与系统基本信息", "Motherboard & System Info", "マザーボード・システム基本情報"),
        i18n.tr("数据来源：SMBIOS Type 2 与系统正常运行时间（用户态）", "Source: SMBIOS Type 2 & OS Uptime (user mode)", "取得元：SMBIOS Type 2・システム稼働時間"),
        -1.0,
        top_h,
        s,
        null,
    )) {
        if (tel.has_system_sample and tel.system.smbios_info.available) {
            const sb = &tel.system.smbios_info;
            widgets.drawKeyValueLine(i18n.tr("主板厂商", "Manufacturer", "メーカー"), if (sb.board_manufacturer_len > 0) sb.boardManufacturer() else "N/A");
            widgets.drawKeyValueLine(i18n.tr("主板型号", "Model", "製品名"), if (sb.board_product_len > 0) sb.boardProduct() else "N/A");
            var vb: [128]u8 = undefined;
            var up_buf: [64]u8 = undefined;
            const up_txt = formatUptime(tel.system.uptime_seconds, &up_buf);
            const vs = std.fmt.bufPrint(&vb, "{s}   •   SMBIOS {d}.{d}   •   {s} {s}", .{
                if (sb.board_version_len > 0) sb.boardVersion() else "N/A",
                sb.major_version,
                sb.minor_version,
                i18n.trSlice("系统已开机", "Uptime", "稼働時間"),
                up_txt,
            }) catch "N/A";
            widgets.drawKeyValueLine(i18n.tr("版本与开机时长", "Version & Uptime", "バージョン・稼働時間"), vs);

            var io_buf: [160]u8 = undefined;
            const io_str = std.fmt.bufPrint(&io_buf, "{s} {d:.1} MB/s  •  {s} {d:.1} MB/s  •  {d:.0} IOPS", .{
                i18n.trSlice("磁盘读", "Read", "読込"),
                tel.system.disk_read_mbs orelse 0.0,
                i18n.trSlice("写", "Write", "書込"),
                tel.system.disk_write_mbs orelse 0.0,
                tel.system.disk_iops orelse 0.0,
            }) catch "N/A";
            widgets.drawKeyValueLine(i18n.tr("存储实时吞吐", "Live Storage I/O", "ストレージ I/O"), io_str);

            var bat_buf: [128]u8 = undefined;
            const bat_str = if (tel.system.battery.has_battery)
                std.fmt.bufPrint(&bat_buf, "{s}  •  {s} {d}%", .{
                    if (tel.system.battery.ac_online)
                        i18n.trSlice("交流供电/充电", "AC Power / Charging", "AC電源 / 充電中")
                    else
                        i18n.trSlice("电池放电", "On Battery", "バッテリー駆動"),
                    i18n.trSlice("电量", "Charge", "残量"),
                    tel.system.battery.charge_pct orelse 0,
                }) catch "Battery"
            else
                i18n.trSlice("台式机 / 无内置电池（交流供电）", "Desktop / No Battery (AC Power)", "デスクトップ / バッテリーなし（AC電源）");
            widgets.drawKeyValueLine(i18n.tr("电源与电池", "Power & Battery", "電源・バッテリー"), bat_str);
        } else {
            zgui.textColored(p.text_muted, "{s}", .{i18n.tr("正在读取 SMBIOS 主板信息...", "Reading SMBIOS board info...", "SMBIOS マザーボード情報取得中...")});
        }
    }
    widgets.endCard();

    zgui.dummy(.{ .w = 0, .h = gap });

    if (widgets.beginCard(
        "##mb_info_card",
        i18n.tr("主板 Super I/O 与扩展传感器", "Motherboard Super I/O & Extension Sensors", "マザーボード Super I/O・拡張センサー"),
        i18n.tr("保留厂商原始传感器名称，不强行归类（通过独立 MPL-2.0 辅助进程提供）", "Preserves raw hardware sensor names (isolated MPL-2.0 helper)", "メーカー固有のセンサー名をそのまま表示（独立 MPL-2.0 ヘルパー）"),
        -1.0,
        bot_h,
        s,
        null,
    )) {
        if (tel.extension.connected) {
            widgets.drawStatusPill(
                if (tel.extension.helper_is_admin)
                    i18n.tr("扩展组件已连接（管理员权限）", "Extension Connected (Admin)", "拡張機能接続済（管理者権限）")
                else
                    i18n.tr("扩展组件已连接（普通权限，部分传感器受限）", "Extension Connected (Limited Privilege)", "拡張機能接続済（標準権限・一部制限）"),
                if (tel.extension.helper_is_admin) p.status_ok else p.status_caution,
                s,
            );
            zgui.sameLine(.{});
            if (zgui.button(i18n.tr("停止辅助进程", "Stop Helper", "ヘルパー停止"), .{})) {
                state.request_stop_lhm_helper = true;
            }
            zgui.dummy(.{ .w = 0, .h = 6.0 * s });

            if (tel.extension.sensor_count == 0) {
                zgui.textWrapped("{s}", .{i18n.tr(
                    "扩展辅助进程已连接，但当前未读到可用传感器。请确认以管理员身份启动辅助进程，并在 Windows 11 内存完整性环境下按文档安装受信任的 PawnIO 驱动。",
                    "Helper connected, but no sensors were reported. Ensure the helper runs as Administrator (and PawnIO is installed if Win11 Core Isolation is active).",
                    "ヘルパーは接続されていますがセンサーが取得できません。管理者権限での起動や Win11 コア分離環境での PawnIO 設定を確認してください。",
                )});
            } else if (zgui.beginTable("##lhm_sensors_tbl", .{
                .column = 4,
                .flags = .{ .borders = .{ .inner_h = true }, .row_bg = true, .sizing = .stretch_prop, .scroll_y = true },
            })) {
                zgui.tableSetupColumn(i18n.tr("硬件设备", "Hardware", "ハードウェア"), .{ .init_width_or_height = 1.4 });
                zgui.tableSetupColumn(i18n.tr("原始传感器名", "Raw Sensor Name", "センサー名"), .{ .init_width_or_height = 1.4 });
                zgui.tableSetupColumn(i18n.tr("类型", "Type", "種別"), .{ .init_width_or_height = 0.8 });
                zgui.tableSetupColumn(i18n.tr("实时数值", "Value", "現在値"), .{ .init_width_or_height = 0.8 });
                zgui.tableHeadersRow();

                for (tel.extension.sensors[0..tel.extension.sensor_count]) |item| {
                    zgui.tableNextRow(.{});
                    _ = zgui.tableNextColumn();
                    zgui.text("{s}", .{item.hardwareSlice()});
                    _ = zgui.tableNextColumn();
                    zgui.text("{s}", .{item.nameSlice()});
                    _ = zgui.tableNextColumn();
                    zgui.textColored(p.text_muted, "{s}", .{item.sensorTypeSlice()});
                    _ = zgui.tableNextColumn();
                    zgui.textColored(p.accent_cyan, "{d:.1} {s}", .{ item.value, item.unitSlice() });
                }
                zgui.endTable();
            }
        } else {
            widgets.drawStatusPill(
                if (state.extension_enabled)
                    i18n.tr("等待扩展辅助进程连接", "Waiting for Helper Connection", "拡張ヘルパー接続待機中")
                else
                    i18n.tr("扩展组件未启用（默认关闭）", "Extension Disabled (Default)", "拡張機能オフ（初期設定）"),
                p.status_caution,
                s,
            );
            zgui.sameLine(.{});
            if (zgui.button(i18n.tr("启动扩展辅助进程 (需管理员)", "Launch Helper (Admin)", "拡張ヘルパー起動 (管理者)"), .{})) {
                state.request_launch_lhm_helper = true;
            }
            if (state.lhm_action_msg.len > 0) {
                zgui.dummy(.{ .w = 0, .h = 4.0 * s });
                zgui.textColored(p.accent_blue, "{s}", .{state.lhm_action_msg});
            }
            zgui.dummy(.{ .w = 0, .h = 10.0 * s });
            zgui.textWrapped("{s}", .{i18n.tr(
                "CPU 封装温度/功耗、主板芯片组温度、VRM 温度、机箱风扇转速与电压需要内核级硬件访问。按照规范 §1.2，主程序本体（Apache-2.0）坚持零内核驱动。",
                "CPU package temp/power, motherboard VRM, case fans, and voltages require kernel-level access. Per spec §1.2, the core app (Apache-2.0) ships zero kernel drivers.",
                "CPU パッケージ温度/電力・VRM・ファン・電圧の取得にはカーネルアクセスが必要です。本体（Apache-2.0）はカーネルドライバ非搭載です。",
            )});
            zgui.dummy(.{ .w = 0, .h = 4.0 * s });
            zgui.pushStyleColor4f(.{ .idx = .text, .c = p.text_secondary });
            zgui.textWrapped("{s}", .{i18n.tr(
                "点击上方按钮将显式按需启动独立隔离的 WinHardwareMonitor.LhmHelper.exe（MPL-2.0，仅只读、零网络、同用户命名管道通信）；不自动静默安装第三方驱动。",
                "Clicking above launches the isolated WinHardwareMonitor.LhmHelper.exe on demand (MPL-2.0, read-only, zero network, same-user Named Pipe).",
                "上のボタンで独立分離された WinHardwareMonitor.LhmHelper.exe（MPL-2.0・読取専用・通信ゼロ）をオンデマンド起動します。",
            )});
            zgui.popStyleColor(.{ .count = 1 });
        }
    }
    widgets.endCard();
}

fn renderDisksView(state: *AppState, tel: *const SharedTelemetry) void {
    const s = state.dpi_scale;
    const p = theme.active();
    const avail_h = zgui.getContentRegionAvail()[1];
    const gap = 12.0 * s;

    const top_h = @min(220.0 * s, @max(175.0 * s, avail_h * 0.32));
    const bot_h = @max(300.0 * s, avail_h - top_h - gap);

    if (widgets.beginCard(
        "##disks_card",
        i18n.tr("物理磁盘列表与健康状态", "Physical Disks & Health Status", "物理ディスク一覧・健康状態"),
        i18n.tr("点击任意磁盘查看下方完整 SMART 详情 • 休眠磁盘默认不唤醒", "Click any drive for full SMART details • Sleeping drives are never woken by default", "ディスク選択で詳細 SMART 表示 • スリープ中ドライブは自動保護"),
        -1.0,
        top_h,
        s,
        null,
    )) {
        if (!tel.has_disk_inventory) {
            widgets.drawStatusPill(i18n.tr("正在枚举物理磁盘与 SMART...", "Enumerating physical disks & SMART...", "物理ディスク・SMART をスキャン中..."), p.accent_blue, s);
        } else if (tel.disk_count == 0) {
            widgets.drawStatusPill(i18n.tr("未发现物理磁盘", "No physical disks found", "物理ディスクが見つかりません"), p.status_unknown, s);
        } else {
            if (state.selected_disk_idx >= tel.disk_count) state.selected_disk_idx = 0;

            if (zgui.beginTable("##disks_table", .{
                .column = 8,
                .flags = .{ .borders = .{ .inner_h = true }, .row_bg = true, .sizing = .stretch_prop, .scroll_y = true },
            })) {
                zgui.tableSetupColumn(i18n.tr("设备", "Drive", "デバイス"), .{});
                zgui.tableSetupColumn(i18n.tr("型号", "Model", "モデル"), .{ .init_width_or_height = 1.8 });
                zgui.tableSetupColumn(i18n.tr("接口", "Bus", "接続"), .{});
                zgui.tableSetupColumn(i18n.tr("容量", "Capacity", "容量"), .{});
                zgui.tableSetupColumn(i18n.tr("温度", "Temp", "温度"), .{});
                zgui.tableSetupColumn(i18n.tr("健康状态", "Health", "健康状態"), .{});
                zgui.tableSetupColumn(i18n.tr("通电时间", "Power-On", "使用時間"), .{});
                zgui.tableSetupColumn(i18n.tr("操作", "Action", "操作"), .{});
                zgui.tableHeadersRow();

                for (tel.disk_states[0..tel.disk_count], 0..) |ds, idx| {
                    const d = &ds.device;
                    var model_buf: [160]u8 = undefined;
                    const model_str = d.modelDisplay(&model_buf);
                    zgui.tableNextRow(.{});

                    _ = zgui.tableNextColumn();
                    zgui.text("Disk {d}", .{d.drive_index});

                    _ = zgui.tableNextColumn();
                    zgui.text("{s}", .{model_str});

                    _ = zgui.tableNextColumn();
                    zgui.text("{s}", .{d.bus_type.name()});

                    _ = zgui.tableNextColumn();
                    if (d.capacity_bytes) |cap| {
                        const gb = @as(f64, @floatFromInt(cap)) / 1_000_000_000.0;
                        if (gb >= 1000.0) zgui.text("{d:.2} TB", .{gb / 1000.0}) else zgui.text("{d:.0} GB", .{gb});
                    } else {
                        zgui.textColored(p.text_muted, "N/A", .{});
                    }

                    _ = zgui.tableNextColumn();
                    if (ds.effectiveTempC()) |tc| {
                        const disp_t = state.temp_unit.convert(@floatFromInt(tc));
                        const tcol = if (tc >= 70) p.status_warning else if (tc >= 60) p.status_caution else p.status_ok;
                        zgui.textColored(tcol, "{d:.0}{s}", .{ disp_t, state.temp_unit.symbol() });
                    } else {
                        zgui.textColored(p.text_muted, "N/A", .{});
                    }

                    _ = zgui.tableNextColumn();
                    widgets.drawStatusPill(ds.assessment.overall.labelZh(), p.healthColor(ds.assessment.overall), s);

                    _ = zgui.tableNextColumn();
                    if (ds.effectivePowerOnHours()) |poh| {
                        zgui.text("{d} h", .{poh});
                    } else {
                        zgui.textColored(p.text_muted, "N/A", .{});
                    }

                    _ = zgui.tableNextColumn();
                    var btn_buf: [48]u8 = undefined;
                    const btn_lbl = std.fmt.bufPrintZ(&btn_buf, "{s}##sel_disk_{d}", .{
                        if (state.selected_disk_idx == idx)
                            i18n.trSlice("查看中", "Selected", "選択中")
                        else
                            i18n.trSlice("详情", "Details", "詳細"),
                        idx,
                    }) catch "Details";
                    if (zgui.button(btn_lbl, .{})) {
                        state.selected_disk_idx = idx;
                    }
                }
                zgui.endTable();
            }
        }
    }
    widgets.endCard();

    if (!tel.has_disk_inventory or tel.disk_count == 0) return;

    zgui.dummy(.{ .w = 0, .h = gap });

    const ds = &tel.disk_states[state.selected_disk_idx];
    const d = &ds.device;
    var model_buf: [160]u8 = undefined;
    const model_str = d.modelDisplay(&model_buf);
    var title_buf: [200]u8 = undefined;
    const detail_title = std.fmt.bufPrintZ(&title_buf, "{s}: Disk {d} — {s}", .{
        i18n.trSlice("磁盘详情", "Disk Details", "ディスク詳細"),
        d.drive_index,
        model_str,
    }) catch "Disk Details";

    if (widgets.beginCard(
        "##disk_detail_card",
        detail_title,
        i18n.tr("SMART 正常不代表硬盘不会突然损坏，请定期做好重要数据备份", "Normal SMART does not guarantee immunity from sudden failure; back up regularly", "SMART 正常でも突然故障する可能性があります。定期的なバックアップを推奨します"),
        -1.0,
        bot_h,
        s,
        null,
    )) {
        var meta1: [256]u8 = undefined;
        const m1 = std.fmt.bufPrint(&meta1, "{s}: {s}   •   FW: {s}   •   SN: {s}   •   ID: {s}{s}   •   {s}", .{
            i18n.trSlice("接口", "Bus", "接続"),
            d.bus_type.name(),
            d.firmwareSlice(),
            d.serialMaskedSlice(),
            d.stable_id.slice(),
            if (d.stable_id.is_stable) "" else i18n.trSlice(" (不稳定)", " (unstable)", " (不安定)"),
            d.support.labelZh(),
        }) catch "";
        zgui.pushStyleColor4f(.{ .idx = .text, .c = p.text_secondary });
        zgui.textWrapped("{s}", .{m1});
        zgui.popStyleColor(.{ .count = 1 });

        zgui.dummy(.{ .w = 0, .h = 6.0 * s });
        widgets.drawStatusPill(ds.assessment.overall.labelZh(), p.healthColor(ds.assessment.overall), s);
        zgui.sameLine(.{});
        if (ds.nvme.wctemp_c) |wc| {
            zgui.textColored(p.text_secondary, "{s}: {d}°C / {d}°C", .{
                i18n.tr("设备温度阈值 (警/危)", "Device Temp Limits (Warn/Crit)", "デバイス温度閾値 (警告/危険)"),
                wc,
                ds.nvme.cctemp_c orelse 0,
            });
            zgui.sameLine(.{ .spacing = 16.0 * s });
        }
        if (ds.baseline.initialized) {
            if (zgui.button(i18n.tr("以当前值重设基线", "Reset Baseline", "基準値リセット"), .{})) {
                state.request_reset_baseline_idx = state.selected_disk_idx;
            }
        }
        if (ds.ata.status == .ok) {
            zgui.sameLine(.{ .spacing = 12.0 * s });
            _ = zgui.checkbox(i18n.tr("确认下发自检", "Confirm Self-Test", "セルフテスト確認"), .{ .v = &state.bench_smart_confirmed });
            zgui.sameLine(.{ .spacing = 6.0 * s });
            if (zgui.button(i18n.tr("执行 SMART 短自检 (~2分)", "Run SMART Short Self-Test (~2m)", "SMART ショートテスト (~2分)"), .{})) {
                state.request_ata_short_selftest_idx = state.selected_disk_idx;
            }
        }
        if (state.selftest_msg.len > 0) {
            zgui.textColored(p.accent_blue, "{s}", .{state.selftest_msg});
        }

        if (ds.assessment.hit_count > 0) {
            zgui.dummy(.{ .w = 0, .h = 4.0 * s });
            for (ds.assessment.slice()) |hit| {
                zgui.pushStyleColor4f(.{ .idx = .text, .c = p.healthColor(hit.level) });
                zgui.textWrapped("[{s}] {s}", .{ hit.rule_id, hit.evidenceSlice() });
                zgui.popStyleColor(.{ .count = 1 });
            }
        } else if (ds.assessment.overall == .normal) {
            zgui.textColored(p.status_ok, "{s}", .{i18n.tr(
                "全部已检测健康规则均正常（无 Critical Warning / 介质错误 / 扇区重映射异常）。",
                "All evaluated §2.5.5 health rules are normal (no Critical Warning, media errors, or sector reallocation issues).",
                "すべての健康判定ルールは正常です（致命的警告・メディアエラー・代替セクタ異常なし）。",
            )});
        }

        zgui.dummy(.{ .w = 0, .h = 6.0 * s });
        zgui.separator();
        zgui.dummy(.{ .w = 0, .h = 6.0 * s });

        if (ds.nvme.status == .ok) {
            renderNvmeSmartTable(&ds.nvme, state.temp_unit);
        } else if (ds.ata.status == .ok) {
            renderAtaSmartTable(&ds.ata);
        } else {
            const st = if (d.support == .nvme_native) ds.nvme.status else ds.ata.status;
            const err = if (d.support == .nvme_native) ds.nvme.error_code else ds.ata.error_code;
            widgets.drawStatusPill(st.labelZh(), p.sensorStatusColor(st), s);
            zgui.dummy(.{ .w = 0, .h = 6.0 * s });
            if (d.support.isUnsupported()) {
                zgui.textWrapped("{s}: {s}", .{
                    i18n.tr("该设备不支持标准直读 SMART，健康状态标注为“未知”", "Direct SMART read unsupported; health is marked Unknown", "標準 SMART 直読非対応のため健康状態は「不明」と表示します"),
                    d.support.labelZh(),
                });
            } else if (d.removable and d.bus_type == .usb) {
                zgui.textWrapped("{s} ({s}, err={d})", .{
                    i18n.tr(
                        "可移动 USB 存储通常不提供 SMART 统计；规范严禁编造健康度或发送桥接厂商私有命令",
                        "Removable USB flash drives usually lack SMART; vendor-proprietary bridge commands are strictly forbidden",
                        "リムーバブル USB メモリは通常 SMART 非対応です（独自コマンド送信は禁止）",
                    ),
                    st.labelZh(),
                    err orelse 0,
                });
            } else if (st == .access_denied) {
                zgui.textWrapped("{s} (err={d})", .{
                    i18n.tr(
                        "读取 ATA/SAT SMART 需要管理员权限，请点击左侧“以管理员身份重启”后再查看",
                        "Reading ATA/SAT SMART requires Administrator privileges; click 'Restart as Admin' on the left",
                        "ATA/SAT SMART の読取には管理者権限が必要です。左側の「管理者として再起動」を押してください",
                    ),
                    err orelse 5,
                });
            } else if (st == .device_standby) {
                zgui.textWrapped("{s}", .{i18n.tr(
                    "该磁盘当前处于休眠/待机状态，已按规范 §2.5.4 跳过 SMART 读取以避免唤醒增加磨损。",
                    "Drive is currently in standby/sleep; SMART polling skipped per §2.5.4 to avoid waking it.",
                    "このディスクはスリープ/待機状態のため、摩耗防止のため SMART 取得をスキップしました。",
                )});
            } else {
                zgui.textWrapped("{s} ({s}, err={d})", .{
                    i18n.tr(
                        "当前无法读取该磁盘的 SMART 属性（受接口或桥接固件限制，严禁发送厂商私有命令）",
                        "Unable to read SMART from this drive (bus/bridge firmware limit; no proprietary commands sent)",
                        "このディスクの SMART を取得できません（インターフェースまたはブリッジ制限）",
                    ),
                    st.labelZh(),
                    err orelse 0,
                });
            }
        }
    }
    widgets.endCard();
}

fn renderNvmeSmartTable(nv: *const @import("../collectors/storage/nvme_smart.zig").NvmeSmartData, unit: state_mod.TemperatureUnit) void {
    if (zgui.beginTable("##nvme_smart_tbl", .{
        .column = 3,
        .flags = .{ .borders = .{ .inner_h = true }, .row_bg = true, .sizing = .stretch_prop, .scroll_y = true },
    })) {
        zgui.tableSetupColumn(i18n.tr("NVMe SMART 指标", "NVMe SMART Metric", "NVMe SMART 指標"), .{ .init_width_or_height = 1.1 });
        zgui.tableSetupColumn(i18n.tr("当前值", "Value", "現在値"), .{ .init_width_or_height = 0.9 });
        zgui.tableSetupColumn(i18n.tr("说明", "Description", "説明"), .{ .init_width_or_height = 1.6 });
        zgui.tableHeadersRow();

        nvmeRow(
            "Critical Warning",
            "0x{X:0>2}",
            .{nv.critical_warning},
            if (nv.critical_warning == 0)
                i18n.tr("无严重硬件健康警告", "No critical hardware warnings", "致命的な警告なし")
            else
                i18n.tr("存在严重警告位，请查看上方规则证据", "Critical warning bits set — check rule hits above", "警告ビットあり（上のルール結果を確認）"),
        );
        if (nv.composite_temp_c) |tc| {
            nvmeRow("Composite Temperature", "{d:.0}{s} ({d} K)", .{ unit.convert(@floatFromInt(tc)), unit.symbol(), nv.composite_temp_k }, i18n.tr("综合温度", "Composite temperature", "総合温度"));
        }
        nvmeRow("Available Spare / Threshold", "{d}% / {d}%", .{ nv.available_spare, nv.available_spare_threshold }, i18n.tr("可用备用块比例及设备阈值", "Available spare & threshold", "予備領域と閾値"));
        nvmeRow("Percentage Used", "{d}%", .{nv.percentage_used}, i18n.tr("厂商寿命消耗估计（非精确剩余寿命，可超 100%）", "Vendor endurance estimate (may exceed 100%)", "メーカー推定寿命消費率（100%超過可）"));
        nvmeRow(i18n.tr("累计读取量 (Data Units Read)", "Data Units Read", "総読込量 (Data Units Read)"), "{d:.2} TB ({d})", .{ nv.bytesReadTB(), nv.data_units_read }, i18n.tr("128 位计数，1 unit = 512,000 字节", "128-bit counter (1 unit = 512,000 bytes)", "128ビットカウンタ（1 unit = 512,000 B）"));
        nvmeRow(i18n.tr("累计写入量 (Data Units Written)", "Data Units Written", "総書込量 (Data Units Written)"), "{d:.2} TB ({d})", .{ nv.bytesWrittenTB(), nv.data_units_written }, i18n.tr("128 位计数，1 unit = 512,000 字节", "128-bit counter (1 unit = 512,000 bytes)", "128ビットカウンタ（1 unit = 512,000 B）"));
        nvmeRow(i18n.tr("累计通电时间 (Power On Hours)", "Power On Hours", "使用時間 (Power On Hours)"), "{d} h", .{nv.power_on_hours}, i18n.tr("控制器累计通电运行时间", "Cumulative powered-on hours", "累計通電時間"));
        nvmeRow(i18n.tr("通电次数 (Power Cycles)", "Power Cycles", "電源投入回数 (Power Cycles)"), "{d}", .{nv.power_cycles}, i18n.tr("累计通电循环次数", "Total power cycles", "累計電源サイクル数"));
        nvmeRow(i18n.tr("非正常关机 (Unsafe Shutdowns)", "Unsafe Shutdowns", "異常終了回数 (Unsafe Shutdowns)"), "{d}", .{nv.unsafe_shutdowns}, i18n.tr("未收到正常关机通知的断电次数", "Power losses without clean shutdown", "正常シャットダウンなしの電源断回数"));
        nvmeRow(i18n.tr("介质及数据完整性错误", "Media & Data Integrity Errors", "メディア・データ整合性エラー"), "{d}", .{nv.media_errors}, i18n.tr("不可恢复 ECC/CRC 完整性错误计数", "Unrecovered ECC/CRC errors", "回復不能 ECC/CRC エラー数"));
        nvmeRow(i18n.tr("错误日志条目", "Error Log Entries", "エラーログ件数"), "{d}", .{nv.error_log_entries}, i18n.tr("历史错误日志总条数", "Total error information log entries", "累計エラーログ件数"));
        nvmeRow(i18n.tr("高温累计时间 (Warn / Crit)", "Thermal Time (Warn / Crit)", "高温累計時間 (警告 / 危険)"), "{d}m / {d}m", .{ nv.warning_temp_time_min, nv.critical_temp_time_min }, i18n.tr("超过警告/临界温度的累计时间", "Minutes above warning / critical temp", "警告・危険温度超過の累計時間"));
        for (nv.temp_sensors_c, 0..) |ts_opt, ti| {
            if (ts_opt) |ts| {
                var lbl_b: [48]u8 = undefined;
                const lbl = std.fmt.bufPrintZ(&lbl_b, "{s} #{d}", .{ i18n.trSlice("温度传感器", "Temp Sensor", "温度センサー"), ti + 1 }) catch "Sensor";
                nvmeRow(lbl, "{d:.0}{s}", .{ unit.convert(@floatFromInt(ts)), unit.symbol() }, i18n.tr("NVMe 控制器附加温度探头", "Auxiliary NVMe thermal sensor", "NVMe コントローラ補助温度センサー"));
            }
        }

        zgui.endTable();
    }
}

fn nvmeRow(name: [:0]const u8, comptime fmt: []const u8, args: anytype, desc: [:0]const u8) void {
    const p = theme.active();
    zgui.tableNextRow(.{});
    _ = zgui.tableNextColumn();
    zgui.text("{s}", .{name});
    _ = zgui.tableNextColumn();
    zgui.text(fmt, args);
    _ = zgui.tableNextColumn();
    zgui.textColored(p.text_muted, "{s}", .{desc});
}

fn renderAtaSmartTable(ad: *const @import("../collectors/storage/ata_smart.zig").AtaSmartData) void {
    const p = theme.active();
    const AtaAttr = @import("../collectors/storage/ata_smart.zig").AtaAttribute;
    if (zgui.beginTable("##ata_smart_tbl", .{
        .column = 7,
        .flags = .{ .borders = .{ .inner_h = true }, .row_bg = true, .sizing = .stretch_prop, .scroll_y = true },
    })) {
        zgui.tableSetupColumn("ID", .{});
        zgui.tableSetupColumn(i18n.tr("属性名称", "Attribute Name", "属性名"), .{ .init_width_or_height = 1.4 });
        zgui.tableSetupColumn(i18n.tr("类型", "Type", "種別"), .{});
        zgui.tableSetupColumn(i18n.tr("当前值", "Current", "現在値"), .{});
        zgui.tableSetupColumn(i18n.tr("最差值", "Worst", "最悪値"), .{});
        zgui.tableSetupColumn(i18n.tr("阈值", "Threshold", "閾値"), .{});
        zgui.tableSetupColumn(i18n.tr("原始值 (Hex / Dec)", "Raw (Hex / Dec)", "生の値 (Hex / Dec)"), .{ .init_width_or_height = 1.4 });
        zgui.tableHeadersRow();

        for (ad.attrs[0..ad.attr_count]) |a| {
            zgui.tableNextRow(.{});
            _ = zgui.tableNextColumn();
            zgui.text("0x{X:0>2} ({d})", .{ a.id, a.id });
            _ = zgui.tableNextColumn();
            zgui.text("{s}", .{AtaAttr.knownNameZh(a.id)});
            _ = zgui.tableNextColumn();
            zgui.textColored(if (a.isPrefail()) p.status_caution else p.text_muted, "{s}", .{if (a.isPrefail()) "Pre-fail" else "Old-age"});
            _ = zgui.tableNextColumn();
            zgui.text("{d}", .{a.current});
            _ = zgui.tableNextColumn();
            zgui.text("{d}", .{a.worst});
            _ = zgui.tableNextColumn();
            if (a.has_threshold) zgui.text("{d}", .{a.threshold}) else zgui.textColored(p.text_muted, "N/A", .{});
            _ = zgui.tableNextColumn();
            zgui.text("0x{X:0>12} ({d})", .{ a.rawU48(), a.rawU48() });
        }
        zgui.endTable();
    }
}

fn renderSensorsView(state: *AppState, tel: *const SharedTelemetry) void {
    const s = state.dpi_scale;
    const p = theme.active();
    const avail_h = zgui.getContentRegionAvail()[1];

    if (widgets.beginCard(
        "##all_sensors_card",
        i18n.tr("全传感器实时统计表（HWiNFO 风格）", "All Sensors Live Table (HWiNFO Style)", "全センサー統計表（HWiNFO 形式）"),
        i18n.tr("自动累计所有活跃传感器的当前 / 最小 / 平均 / 最大值，支持一键清零与 CSV 导出", "Tracks Current / Min / Avg / Max for all active sensors with 1-click reset & CSV export", "全アクティブセンサーの現在/最小/平均/最大を自動集計（リセット・CSV出力対応）"),
        -1.0,
        @max(360.0 * s, avail_h),
        s,
        null,
    )) {
        if (zgui.button(i18n.tr("清零最小 / 平均 / 最大统计", "Reset Min / Avg / Max", "最小/平均/最大をリセット"), .{ .w = 210.0 * s, .h = 28.0 * s })) {
            state.request_reset_sensor_stats = true;
        }
        zgui.sameLine(.{});
        if (zgui.button(i18n.tr("导出 CSV 报表至 logs", "Export CSV to logs/", "CSV レポートを logs/ に出力"), .{ .w = 195.0 * s, .h = 28.0 * s })) {
            state.request_export_sensors_csv = true;
        }
        if (state.sensors_csv_msg.len > 0) {
            zgui.sameLine(.{ .spacing = 12.0 * s });
            zgui.textColored(p.status_ok, "{s}", .{state.sensors_csv_msg});
        }
        zgui.dummy(.{ .w = 0, .h = 8.0 * s });

        const rows = tel.sensor_stats.slice();
        if (rows.len == 0) {
            zgui.textColored(p.text_muted, "{s}", .{i18n.tr("正在等待首个传感器采样周期...", "Waiting for first sensor polling cycle...", "初回センサー取得サイクル待機中...")});
        } else if (zgui.beginTable("##sensors_stats_tbl", .{
            .column = 7,
            .flags = .{ .borders = .{ .inner_h = true }, .row_bg = true, .sizing = .stretch_prop, .scroll_y = true },
        })) {
            zgui.tableSetupColumn(i18n.tr("分类", "Category", "カテゴリ"), .{ .init_width_or_height = 0.8 });
            zgui.tableSetupColumn(i18n.tr("传感器名称", "Sensor Name", "センサー名"), .{ .init_width_or_height = 1.6 });
            zgui.tableSetupColumn(i18n.tr("当前值", "Current", "現在値"), .{ .init_width_or_height = 0.8 });
            zgui.tableSetupColumn(i18n.tr("最小值", "Min", "最小値"), .{ .init_width_or_height = 0.8 });
            zgui.tableSetupColumn(i18n.tr("平均值", "Avg", "平均値"), .{ .init_width_or_height = 0.8 });
            zgui.tableSetupColumn(i18n.tr("最大值", "Max", "最大値"), .{ .init_width_or_height = 0.8 });
            zgui.tableSetupColumn(i18n.tr("采样数", "Samples", "サンプル"), .{ .init_width_or_height = 0.6 });
            zgui.tableHeadersRow();

            var name_buf: [96]u8 = undefined;
            for (rows) |*e| {
                const is_c = std.mem.eql(u8, e.unitSlice(), "C");
                const disp_unit = if (is_c) state.temp_unit.symbol() else e.unitSlice();
                const cur_v = if (is_c) state.temp_unit.convert(e.current) else e.current;
                const min_v = if (is_c) state.temp_unit.convert(e.min_val) else e.min_val;
                const avg_v = if (is_c) state.temp_unit.convert(e.avg()) else e.avg();
                const max_v = if (is_c) state.temp_unit.convert(e.max_val) else e.max_val;

                zgui.tableNextRow(.{});
                _ = zgui.tableNextColumn();
                zgui.textColored(p.text_muted, "{s}", .{e.localizedCategory()});
                _ = zgui.tableNextColumn();
                zgui.text("{s}", .{e.localizedName(&name_buf)});
                _ = zgui.tableNextColumn();
                zgui.textColored(p.accent_cyan, "{d:.1} {s}", .{ cur_v, disp_unit });
                _ = zgui.tableNextColumn();
                zgui.text("{d:.1} {s}", .{ min_v, disp_unit });
                _ = zgui.tableNextColumn();
                zgui.text("{d:.1} {s}", .{ avg_v, disp_unit });
                _ = zgui.tableNextColumn();
                zgui.textColored(p.status_caution, "{d:.1} {s}", .{ max_v, disp_unit });
                _ = zgui.tableNextColumn();
                zgui.textColored(p.text_muted, "{d}", .{e.count});
            }
            zgui.endTable();
        }
    }
    widgets.endCard();
}

fn setFixedDir(dest: *[260]u8, src: []const u8) void {
    const n = @min(dest.len - 1, src.len);
    @memcpy(dest[0..n], src[0..n]);
    dest[n] = 0;
}

fn renderStressTestView(state: *AppState, tel: *const SharedTelemetry, bench: *const BenchmarkSnapshot) void {
    const s = state.dpi_scale;
    const p = theme.active();
    const avail = zgui.getContentRegionAvail();
    const gap = 12.0 * s;
    const left_w = @max(360.0 * s, (avail[0] - gap) * 0.46);
    const right_w = avail[0] - left_w - gap;
    const full_h = @max(480.0 * s, avail[1]);

    if (widgets.beginCard(
        "##bench_ctrl_card",
        i18n.tr("硬件稳定性与基准测试控制台 (V2.2)", "Hardware Stress & Benchmark Console (V2.2)", "ハードウェア安定性・ベンチマーク (V2.2)"),
        i18n.tr("默认低优先级温和防卡顿模式 + 实时高温熔断；磁盘测速仅用受控临时文件并自动删除", "Low-priority Gentle Mode + live thermal cutoff; disk test uses auto-deleted temp file", "低優先度システム保護＋高温自動停止・ディスク計測は一時ファイル自動削除"),
        left_w,
        full_h,
        s,
        null,
    )) {
        // 1. 测试前环境智能提醒（电池供电 / 缺少 CPU 温度传感器 / 防卡顿保护）
        widgets.drawStatusPill(
            if (state.bench_gentle_mode)
                i18n.tr("防卡顿保护已开启（低优先级 + 保留系统核）", "Gentle Mode ON (Low-Priority + OS Headroom)", "システム保護オン（低優先度・OSコア確保）")
            else
                i18n.tr("全速压测模式（系统响应可能变慢）", "Full Speed Mode (UI may feel heavy)", "全速モード（応答が重くなる場合あり）"),
            if (state.bench_gentle_mode) p.status_ok else p.status_caution,
            s,
        );

        if (tel.has_system_sample and tel.system.battery.has_battery and !tel.system.battery.ac_online) {
            zgui.dummy(.{ .w = 0, .h = 3.0 * s });
            zgui.pushStyleColor4f(.{ .idx = .text, .c = p.status_caution });
            zgui.textWrapped("! {s}", .{i18n.tr(
                "检测到当前处于电池供电：CPU/GPU 性能可能受省电策略限制，建议插电后测试。",
                "Running on battery power: CPU/GPU clocks may be throttled; plug in AC for accurate scores.",
                "バッテリー駆動中です：省電力制限によりスコアが低下する可能性があります。AC 接続を推奨します。",
            )});
            zgui.popStyleColor(.{ .count = 1 });
        }

        if (builtin.os.tag == .windows and !(tel.extension.connected and tel.extension.cpu_package_temp_c != null)) {
            zgui.dummy(.{ .w = 0, .h = 3.0 * s });
            zgui.pushStyleColor4f(.{ .idx = .text, .c = p.status_caution });
            zgui.textWrapped("! {s}", .{i18n.tr(
                "提示：CPU 温度当前为 N/A，高温熔断仅能依赖 GPU 温度；建议先在「系统设置」启动 LHM 辅助进程。",
                "Note: CPU temp is N/A; thermal cutoff uses GPU temp only. Launch LHM helper in Settings for CPU temp guard.",
                "注意：CPU 温度が N/A のため高温保護は GPU 温度のみ参照します。設定から LHM ヘルパー起動を推奨します。",
            )});
            zgui.popStyleColor(.{ .count = 1 });
        }

        zgui.dummy(.{ .w = 0, .h = 6.0 * s });
        _ = zgui.checkbox(i18n.tr(
            "温和防卡顿模式（推荐：低优先级调度，不影响日常软件和系统流畅度）",
            "Gentle System-Safe Mode (Recommended: low priority, keeps OS responsive)",
            "システム保護モード（推奨：低優先度実行で普段の作業を妨げない）",
        ), .{ .v = &state.bench_gentle_mode });

        const max_threads: i32 = @intCast(@max(tel.system.logical_cores, 1));
        _ = zgui.sliderInt(i18n.tr("CPU 测试线程数", "CPU Threads", "CPU スレッド数"), .{ .v = &state.bench_cpu_threads, .min = 1, .max = max_threads });
        _ = zgui.sliderInt(i18n.tr("烤机持续时长 (秒)", "Duration (sec)", "実行時間 (秒)"), .{ .v = &state.bench_duration_s, .min = 10, .max = 300 });
        _ = zgui.sliderInt(i18n.tr("高温自动熔断阈值 (°C)", "Thermal Cutoff (°C)", "高温自動停止閾値 (°C)"), .{ .v = &state.bench_thermal_cutoff_c, .min = 70, .max = 100 });
        _ = zgui.sliderInt(i18n.tr("内存校验容量 (MB)", "Memory Size (MB)", "メモリ検証容量 (MB)"), .{ .v = &state.bench_mem_mb, .min = 64, .max = 1024 });
        _ = zgui.sliderInt(i18n.tr("磁盘临时文件大小 (MB)", "Disk Temp File (MB)", "ディスク一時ファイル (MB)"), .{ .v = &state.bench_disk_mb, .min = 64, .max = 1024 });

        // GPU 着色器强度选择（默认均衡，绝不触发 TDR 或桌面卡死）
        zgui.textColored(p.text_secondary, "{s}:", .{i18n.tr("GPU 着色器负载档位", "GPU Shader Load", "GPU シェーダー負荷")});
        zgui.sameLine(.{});
        if (zgui.radioButton(i18n.tr("温和", "Gentle", "軽負荷"), .{ .active = state.bench_gpu_intensity == 0 })) state.bench_gpu_intensity = 0;
        zgui.sameLine(.{});
        if (zgui.radioButton(i18n.tr("均衡 (推荐)", "Balanced", "標準 (推奨)"), .{ .active = state.bench_gpu_intensity == 1 })) state.bench_gpu_intensity = 1;
        zgui.sameLine(.{});
        if (zgui.radioButton(i18n.tr("高负载", "Heavy", "高負荷"), .{ .active = state.bench_gpu_intensity == 2 })) state.bench_gpu_intensity = 2;

        // 自定义磁盘测速目标目录 + 快捷盘符按钮 + 剩余空间/TBW 透明提示
        zgui.dummy(.{ .w = 0, .h = 4.0 * s });
        zgui.textColored(p.text_secondary, "{s}:", .{i18n.tr("磁盘测试目标目录", "Disk Target Directory", "ディスク計測先フォルダ")});
        const dir_buf_z: [:0]u8 = state.bench_disk_dir[0 .. state.bench_disk_dir.len - 1 :0];
        _ = zgui.inputText("##bench_disk_dir", .{ .buf = dir_buf_z });

        if (builtin.os.tag == .windows) {
            if (zgui.button("C:\\", .{})) setFixedDir(&state.bench_disk_dir, "C:\\Users\\Public");
            zgui.sameLine(.{});
            if (zgui.button("D:\\", .{})) setFixedDir(&state.bench_disk_dir, "D:\\");
            zgui.sameLine(.{});
            if (zgui.button("E:\\", .{})) setFixedDir(&state.bench_disk_dir, "E:\\");
            zgui.sameLine(.{});
            if (zgui.button("F:\\", .{})) setFixedDir(&state.bench_disk_dir, "F:\\");
        } else {
            if (zgui.button("/tmp", .{})) setFixedDir(&state.bench_disk_dir, "/tmp");
            zgui.sameLine(.{});
            if (zgui.button("/var/tmp", .{})) setFixedDir(&state.bench_disk_dir, "/var/tmp");
        }

        const est_tbw: f64 = (@as(f64, @floatFromInt(state.bench_disk_mb)) + 2.0) / (1024.0 * 1024.0);
        if (state.bench_disk_free_bytes) |fb| {
            const free_gb = @as(f64, @floatFromInt(fb)) / (1024.0 * 1024.0 * 1024.0);
            const needed_b: u64 = @as(u64, @intCast(@max(state.bench_disk_mb, 32))) * 2 * 1024 * 1024 + 512 * 1024 * 1024;
            zgui.textColored(if (fb >= needed_b) p.text_muted else p.status_critical, "{s}: {d:.1} GB  •  {s} {d} MB (~{d:.5} TBW)", .{
                i18n.tr("目标盘可用空间", "Free Space", "空き容量"),
                free_gb,
                i18n.tr("预计写入", "Est. Write", "予想書込"),
                state.bench_disk_mb,
                est_tbw,
            });
        } else {
            zgui.textColored(p.text_muted, "{s} {d} MB (~{d:.5} TBW)", .{
                i18n.tr("预计写入量", "Est. Write", "予想書込量"),
                state.bench_disk_mb,
                est_tbw,
            });
        }

        zgui.dummy(.{ .w = 0, .h = 4.0 * s });
        _ = zgui.checkbox(i18n.tr(
            "二次确认：允许在目标目录创建受控临时文件测速（结束后自动删除）",
            "Confirm: allow creating a temp file in target directory (auto-deleted)",
            "二次確認：指定フォルダに一時ファイルを作成して計測（終了後自動削除）",
        ), .{ .v = &state.bench_disk_confirmed });

        zgui.dummy(.{ .w = 0, .h = 6.0 * s });
        const running = (bench.outcome == .running);

        zgui.beginDisabled(.{ .disabled = running });
        zgui.pushStyleColor4f(.{ .idx = .button, .c = p.accent_blue_soft });
        zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = p.accent_blue_hover });
        zgui.pushStyleColor4f(.{ .idx = .text, .c = p.accent_blue });
        if (zgui.button(i18n.tr("1. CPU 单核/多核与散热降频测试", "1. CPU Single/Multi & Throttle Test", "1. CPU シングル/マルチ・サーマル検証"), .{ .w = -1.0, .h = 29.0 * s })) {
            state.request_start_cpu_bench = true;
        }
        if (zgui.button(i18n.tr("2. 内存延迟 (L1-RAM) + 多核拷贝 + 位翻转校验", "2. RAM Latency (L1-RAM) + Copy + Bit-Flip", "2. メモリ遅延 + コピー帯域 + 4パス検証"), .{ .w = -1.0, .h = 29.0 * s })) {
            state.request_start_mem_bench = true;
        }
        if (zgui.button(i18n.tr("3. 磁盘无缓存 SEQ1M/4K 读写 + 完整性校验", "3. Disk Unbuffered SEQ1M/4K R/W + Integrity", "3. ディスク無キャッシュ計測 + 整合性検証"), .{ .w = -1.0, .h = 29.0 * s })) {
            state.request_start_disk_bench = true;
        }
        if (zgui.button(i18n.tr("4. GPU OpenGL 3.3 离屏着色器烤机", "4. GPU OpenGL 3.3 Offscreen Shader Stress", "4. GPU OpenGL 3.3 シェーダー負荷テスト"), .{ .w = -1.0, .h = 29.0 * s })) {
            state.request_start_gpu_bench = true;
        }
        if (zgui.button(i18n.tr("5. 整机安全联烤 (CPU + 内存 + GPU)", "5. Combined Safe Stress (CPU + RAM + GPU)", "5. 総合安全負荷テスト (CPU + RAM + GPU)"), .{ .w = -1.0, .h = 29.0 * s })) {
            state.request_start_combined_bench = true;
        }
        zgui.popStyleColor(.{ .count = 3 });

        zgui.pushStyleColor4f(.{ .idx = .button, .c = .{ p.status_ok[0], p.status_ok[1], p.status_ok[2], 0.18 } });
        zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = .{ p.status_ok[0], p.status_ok[1], p.status_ok[2], 0.30 } });
        zgui.pushStyleColor4f(.{ .idx = .text, .c = p.status_ok });
        if (zgui.button(i18n.tr("6. 一键全套硬件综合体检（自动生成报告）", "6. 1-Click Full Hardware Diagnostic Suite", "6. ワンクリック総合ハードウェア診断"), .{ .w = -1.0, .h = 31.0 * s })) {
            state.request_start_full_suite = true;
        }
        zgui.popStyleColor(.{ .count = 3 });
        zgui.endDisabled();

        zgui.dummy(.{ .w = 0, .h = 6.0 * s });
        zgui.pushStyleColor4f(.{ .idx = .button, .c = .{ p.status_critical[0], p.status_critical[1], p.status_critical[2], 0.22 } });
        zgui.pushStyleColor4f(.{ .idx = .text, .c = p.status_critical });
        if (zgui.button(i18n.tr("立即停止测试", "Stop Test", "今すぐ停止"), .{ .w = 155.0 * s, .h = 28.0 * s })) {
            state.request_stop_bench = true;
        }
        zgui.popStyleColor(.{ .count = 2 });
        zgui.sameLine(.{});
        if (zgui.button(i18n.tr("导出综合测试报告", "Export Report", "レポート出力"), .{ .w = 165.0 * s, .h = 28.0 * s })) {
            state.request_export_bench_report = true;
        }

        if (state.bench_msg.len > 0) {
            zgui.dummy(.{ .w = 0, .h = 4.0 * s });
            zgui.textWrapped("{s}", .{state.bench_msg});
        }
    }
    widgets.endCard();

    zgui.sameLine(.{ .spacing = gap });

    if (widgets.beginCard(
        "##bench_result_card",
        i18n.tr("实时曲线、实测指标、诊断结论与历史对比", "Live Telemetry, Metrics, Diagnostics & History", "リアルタイム推移・実測値・診断結果・履歴比較"),
        i18n.tr("自动归档每次测试成绩至本地 SQLite，方便清灰/调 XMP/换盘前后对比", "Results auto-saved to local SQLite for before/after tuning comparison", "結果をローカル SQLite に自動保存（清掃・XMP・換装前後の比較に対応）"),
        right_w,
        full_h,
        s,
        null,
    )) {
        const badge_col = switch (bench.outcome) {
            .passed => p.status_ok,
            .running => p.accent_blue,
            .failed_errors, .stopped_by_thermal, .failed_io => p.status_critical,
            .stopped_by_user, .idle => p.status_unknown,
        };
        widgets.drawStatusPill(bench.outcome.labelZh(), badge_col, s);
        zgui.sameLine(.{ .spacing = 10.0 * s });
        zgui.textColored(p.text_secondary, "{s}: {s}", .{ i18n.tr("项目", "Test", "項目"), bench.last_kind.labelZh() });

        zgui.dummy(.{ .w = 0, .h = 6.0 * s });
        var prog_buf: [32]u8 = undefined;
        const prog_txt = std.fmt.bufPrintZ(&prog_buf, "{d:.0}% ({d:.1}s)", .{ bench.progress_pct, bench.elapsed_s }) catch "";
        zgui.progressBar(.{ .fraction = bench.progress_pct / 100.0, .w = -1.0, .h = 20.0 * s, .overlay = prog_txt });

        zgui.dummy(.{ .w = 0, .h = 6.0 * s });
        var err_buf: [96]u8 = undefined;
        const err_str = std.fmt.bufPrint(&err_buf, "{d} ({s})", .{
            bench.error_count,
            i18n.trSlice("0 = 计算/内存/磁盘校验正常", "0 = compute/RAM/disk OK", "0 = 演算/メモリ/ディスク正常"),
        }) catch "0";
        widgets.drawKeyValueLine(i18n.tr("错误计数", "Errors", "エラー数"), err_str);

        var peak_buf: [128]u8 = undefined;
        const peak_str = if (bench.peak_temp_c) |pt| blk: {
            const dt = if (bench.start_temp_c) |st_t| @max(0.0, pt - st_t) else 0.0;
            if (bench.peak_gpu_power_w) |pw| {
                break :blk std.fmt.bufPrint(&peak_buf, "{d:.1}{s} (+{d:.1}°)  •  GPU {d:.1} W  •  {s} {d:.0}{s}", .{
                    state.temp_unit.convert(pt),
                    state.temp_unit.symbol(),
                    dt,
                    pw,
                    i18n.trSlice("熔断", "Cutoff", "保護"),
                    state.temp_unit.convert(bench.thermal_cutoff_c),
                    state.temp_unit.symbol(),
                }) catch "N/A";
            }
            break :blk std.fmt.bufPrint(&peak_buf, "{d:.1}{s} (+{d:.1}°)  •  {s} {d:.0}{s}", .{
                state.temp_unit.convert(pt),
                state.temp_unit.symbol(),
                dt,
                i18n.trSlice("熔断", "Cutoff", "保護"),
                state.temp_unit.convert(bench.thermal_cutoff_c),
                state.temp_unit.symbol(),
            }) catch "N/A";
        } else i18n.trSlice("N/A（建议启用 LHM 扩展或参考 GPU 温度）", "N/A (enable LHM extension or check GPU temp)", "N/A（LHM 拡張有効化または GPU 温度を参照）");
        widgets.drawKeyValueLine(i18n.tr("峰值温度与温升", "Peak Temp & Delta", "最高温度・昇温幅"), peak_str);

        // 智能三语诊断结论与排障建议框
        zgui.dummy(.{ .w = 0, .h = 4.0 * s });
        const advice_col = switch (bench.outcome) {
            .failed_errors, .stopped_by_thermal, .failed_io => p.status_critical,
            .passed => if (bench.cpu_throttle_drop_pct >= 15.0 or bench.disk_rnd4k_p99_lat_us > 15000.0) p.status_caution else p.status_ok,
            else => p.accent_blue,
        };
        zgui.pushStyleColor4f(.{ .idx = .text, .c = advice_col });
        zgui.textWrapped("{s}: {s}", .{
            i18n.tr("智能诊断", "Diagnosis", "診断アドバイス"),
            bench.diagnosticAdvice(),
        });
        zgui.popStyleColor(.{ .count = 1 });

        // 实时 GPU OpenGL 3.3 FBO 着色器预览画面
        if (bench.gpu_shader_active and state.bench_gpu_tex_id != 0) {
            zgui.dummy(.{ .w = 0, .h = 6.0 * s });
            const cw = @min(zgui.getContentRegionAvail()[0], 420.0 * s);
            const ch = cw * 9.0 / 16.0;
            const tex_ref = zgui.TextureRef{
                .tex_data = null,
                .tex_id = @enumFromInt(@as(u64, state.bench_gpu_tex_id)),
            };
            zgui.image(tex_ref, .{ .w = cw, .h = ch, .uv0 = .{ 0, 1 }, .uv1 = .{ 1, 0 } });
        }

        // 测试过程实时曲线（性能 + 温度双线 ImPlot）
        if (bench.trace_len >= 2) {
            zgui.dummy(.{ .w = 0, .h = 6.0 * s });
            zgui.plot.pushStyleColor4f(.{ .idx = .frame_bg, .c = .{ 0, 0, 0, 0 } });
            zgui.plot.pushStyleColor4f(.{ .idx = .plot_bg, .c = p.canvas_bg });
            zgui.plot.pushStyleColor4f(.{ .idx = .plot_border, .c = p.divider });
            defer zgui.plot.popStyleColor(.{ .count = 3 });
            if (zgui.plot.beginPlot("##bench_live_trace", .{
                .w = -1.0,
                .h = 135.0 * s,
                .flags = .{ .no_title = true, .no_mouse_text = true },
            })) {
                zgui.plot.setupAxis(.x1, .{ .label = "s" });
                zgui.plot.setupAxis(.y1, .{ .flags = .{ .auto_fit = true } });
                zgui.plot.setupAxis(.y2, .{ .label = "°C", .flags = .{ .opposite = true, .auto_fit = true } });
                zgui.plot.setAxis(.y1);
                zgui.plot.pushStyleColor4f(.{ .idx = .line, .c = p.accent_blue });
                zgui.plot.plotLine("Perf", f64, .{
                    .xv = bench.trace_times[0..bench.trace_len],
                    .yv = bench.trace_perf[0..bench.trace_len],
                });
                zgui.plot.popStyleColor(.{ .count = 1 });
                if (bench.peak_temp_c != null) {
                    zgui.plot.setAxis(.y2);
                    zgui.plot.pushStyleColor4f(.{ .idx = .line, .c = p.status_warning });
                    zgui.plot.plotLine("Temp °C", f64, .{
                        .xv = bench.trace_times[0..bench.trace_len],
                        .yv = bench.trace_temp[0..bench.trace_len],
                    });
                    zgui.plot.popStyleColor(.{ .count = 1 });
                }
                zgui.plot.endPlot();
            }
        }

        zgui.dummy(.{ .w = 0, .h = 6.0 * s });
        zgui.separator();
        zgui.dummy(.{ .w = 0, .h = 6.0 * s });

        // 完整分项实测明细
        if (bench.has_cpu_result) {
            var b1: [160]u8 = undefined;
            const s1 = std.fmt.bufPrint(&b1, "{s} {d:.2}  •  {s}({d}T) {d:.2} MOPS  •  {s} {d:.2}x  •  {s} {d:.1}%", .{
                i18n.trSlice("单核", "1T", "1T"),
                bench.cpu_single_mops,
                i18n.trSlice("多核", "MT", "MT"),
                bench.cpu_threads,
                bench.cpu_score_mops,
                i18n.trSlice("扩展", "Scale", "倍率"),
                bench.cpu_scaling_ratio,
                i18n.trSlice("后段衰减", "Drop", "低下"),
                bench.cpu_throttle_drop_pct,
            }) catch "";
            widgets.drawKeyValueLine(i18n.tr("CPU 实测成绩", "CPU Score", "CPU 実測"), s1);
        }
        if (bench.has_mem_result) {
            var b1: [160]u8 = undefined;
            const s1 = std.fmt.bufPrint(&b1, "{d} MB ({d}/4)  •  W {d:.2}  •  R {d:.2}  •  MT-Copy {d:.2} GB/s", .{
                bench.mem_tested_mb, bench.mem_passes_done, bench.mem_write_gbs, bench.mem_read_gbs, bench.mem_copy_gbs,
            }) catch "";
            widgets.drawKeyValueLine(i18n.tr("内存带宽", "RAM Bandwidth", "メモリ帯域"), s1);
            var b2: [160]u8 = undefined;
            const s2 = std.fmt.bufPrint(&b2, "L1 {d:.2} ns  •  L2 {d:.2} ns  •  L3 {d:.2} ns  •  RAM {d:.2} ns", .{
                bench.mem_lat_l1_ns, bench.mem_lat_l2_ns, bench.mem_lat_l3_ns, bench.mem_lat_ram_ns,
            }) catch "";
            widgets.drawKeyValueLine(i18n.tr("缓存与内存延迟", "Cache & RAM Latency", "キャッシュ/メモリ遅延"), s2);
        }
        if (bench.has_disk_result) {
            var b1: [160]u8 = undefined;
            const s1 = std.fmt.bufPrint(&b1, "SEQ1M W {d:.1} / R {d:.1} MB/s  •  {s}: {s}", .{
                bench.disk_seq_write_mbs,
                bench.disk_seq_read_mbs,
                i18n.trSlice("完整性", "Integrity", "整合性"),
                if (!bench.disk_integrity_checked)
                    "..."
                else if (bench.disk_integrity_errors == 0)
                    i18n.trSlice("100% 一致", "100% OK", "100% 一致")
                else
                    i18n.trSlice("异常不匹配!", "MISMATCH!", "不一致検出!"),
            }) catch "";
            widgets.drawKeyValueLine(i18n.tr("磁盘顺序与校验", "Disk SEQ & Verify", "シーケンシャル・検証"), s1);

            var b2: [180]u8 = undefined;
            const s2 = std.fmt.bufPrint(&b2, "R {d:.1} MB/s ({d:.0} IOPS)  •  W {d:.1} MB/s ({d:.0} IOPS)", .{
                bench.disk_rnd4k_read_mbs, bench.disk_rnd4k_read_iops, bench.disk_rnd4k_write_mbs, bench.disk_rnd4k_write_iops,
            }) catch "";
            widgets.drawKeyValueLine(i18n.tr("4K 随机读写", "4K Random R/W", "4K ランダム R/W"), s2);

            var b3: [180]u8 = undefined;
            const s3 = std.fmt.bufPrint(&b3, "Read Min/Avg/P95/P99/Max: {d:.0}/{d:.0}/{d:.0}/{d:.0}/{d:.0} us  •  Write P99: {d:.0} us", .{
                bench.disk_rnd4k_min_lat_us,
                bench.disk_rnd4k_avg_lat_us,
                bench.disk_rnd4k_p95_lat_us,
                bench.disk_rnd4k_p99_lat_us,
                bench.disk_rnd4k_max_lat_us,
                bench.disk_rnd4k_write_p99_us,
            }) catch "";
            widgets.drawKeyValueLine(i18n.tr("4K 分位数延迟", "4K Tail Latency", "4K 遅延分布"), s3);
        }
        if (bench.has_gpu_result) {
            var b1: [160]u8 = undefined;
            const s1 = std.fmt.bufPrint(&b1, "Avg {d:.1} FPS  •  1% Low {d:.1} FPS  •  FT {d:.2} ms (Max {d:.2} ms)  •  {d} frames", .{
                bench.gpu_avg_fps, bench.gpu_low1_fps, bench.gpu_avg_frametime_ms, bench.gpu_max_frametime_ms, bench.gpu_frames,
            }) catch "";
            widgets.drawKeyValueLine(i18n.tr("GPU 着色器成绩", "GPU Shader Result", "GPU シェーダー結果"), s1);
        }
        if (!bench.has_cpu_result and !bench.has_mem_result and !bench.has_disk_result and !bench.has_gpu_result) {
            zgui.textColored(p.text_muted, "{s}", .{i18n.tr(
                "请在左侧选择任意测试项或点击「6. 一键全套硬件综合体检」开始验证。",
                "Select any test on the left or click '6. 1-Click Full Diagnostic Suite' to begin.",
                "左側からテスト項目を選ぶか「6. ワンクリック総合診断」を押してください。",
            )});
        }

        if (bench.summary_len > 0) {
            zgui.dummy(.{ .w = 0, .h = 4.0 * s });
            widgets.drawKeyValueLine(i18n.tr("运行状态", "Status", "実行状態"), bench.summarySlice());
        }

        // 本地 SQLite 历史测试成绩对比表
        if (tel.bench_history_count > 0) {
            zgui.dummy(.{ .w = 0, .h = 8.0 * s });
            zgui.separator();
            zgui.dummy(.{ .w = 0, .h = 4.0 * s });
            zgui.textColored(p.text_secondary, "{s} ({d})", .{
                i18n.tr("历史测试记录对比（本地 SQLite）", "Recent Benchmark History (SQLite)", "過去のテスト履歴比較 (SQLite)"),
                tel.bench_history_count,
            });
            if (zgui.beginTable("##bench_hist_tbl", .{
                .column = 5,
                .flags = .{ .borders = .{ .inner_h = true }, .row_bg = true, .sizing = .stretch_prop, .scroll_y = true },
                .outer_size = .{ 0.0, 130.0 * s },
            })) {
                zgui.tableSetupColumn(i18n.tr("测试项", "Test", "項目"), .{ .init_width_or_height = 0.85 });
                zgui.tableSetupColumn(i18n.tr("结果", "Result", "結果"), .{ .init_width_or_height = 0.65 });
                zgui.tableSetupColumn(i18n.tr("主成绩", "Primary", "主スコア"), .{ .init_width_or_height = 1.6 });
                zgui.tableSetupColumn(i18n.tr("细项", "Details", "詳細"), .{ .init_width_or_height = 1.3 });
                zgui.tableSetupColumn(i18n.tr("峰值温度", "Peak", "最高温度"), .{ .init_width_or_height = 0.6 });
                zgui.tableHeadersRow();

                for (tel.bench_history[0..tel.bench_history_count]) |*hr| {
                    zgui.tableNextRow(.{});
                    _ = zgui.tableNextColumn();
                    zgui.text("{s}", .{hr.testKindSlice()});
                    _ = zgui.tableNextColumn();
                    const ok = std.mem.eql(u8, hr.outcomeSlice(), "passed");
                    zgui.textColored(if (ok) p.status_ok else p.status_caution, "{s}", .{hr.outcomeSlice()});
                    _ = zgui.tableNextColumn();
                    zgui.text("{s}", .{hr.primarySlice()});
                    _ = zgui.tableNextColumn();
                    zgui.textColored(p.text_muted, "{s}", .{hr.secondarySlice()});
                    _ = zgui.tableNextColumn();
                    if (hr.peak_temp_c) |pt| {
                        zgui.text("{d:.0}{s}", .{ state.temp_unit.convert(pt), state.temp_unit.symbol() });
                    } else {
                        zgui.textColored(p.text_muted, "N/A", .{});
                    }
                }
                zgui.endTable();
            }
        }
    }
    widgets.endCard();
}

fn renderHistoryView(state: *AppState, tel: *const SharedTelemetry) void {
    const s = state.dpi_scale;
    const p = theme.active();
    const avail = zgui.getContentRegionAvail();
    const gap = 12.0 * s;
    const top_h = 132.0 * s;
    const bot_h = @max(260.0 * s, avail[1] - top_h - gap);
    const half_w = @max(280.0 * s, (avail[0] - gap) * 0.5);

    if (widgets.beginCard(
        "##hist_db_status",
        i18n.tr("本地历史数据库与分级降采样状态", "Local History DB & Downsampling", "ローカル履歴 DB・ダウンサンプリング"),
        i18n.tr("SQLite WAL 模式 • 1 分钟聚合保留 7 天 • 15 分钟聚合保留 30 天 • 告警 SMART 永久保留", "SQLite WAL • 1m avg 7d • 15m avg 30d • Alert SMART retained permanently", "SQLite WAL • 1分集計7日 • 15分集計30日 • 警告SMART永久保存"),
        -1.0,
        top_h,
        s,
        null,
    )) {
        widgets.drawStatusPill(
            if (tel.db_active)
                i18n.tr("SQLite 持久化运行中", "SQLite Persistence Active", "SQLite 永続化稼働中")
            else
                i18n.tr("内存模式（smoke-test）", "In-Memory Mode", "メモリモード"),
            if (tel.db_active) p.status_ok else p.accent_cyan,
            s,
        );
        zgui.sameLine(.{});
        zgui.textColored(p.text_secondary, "{s}: {d}", .{ i18n.tr("已完成批量写入次数", "Batch Flushes", "バッチ書込回数"), tel.db_flush_count });
        widgets.drawKeyValueLine(i18n.tr("数据库路径", "Database Path", "DB パス"), state.db_path);
        if (tel.db_recovered) {
            zgui.textColored(p.status_caution, "{s}", .{i18n.tr(
                "提示：检测到旧数据库文件损坏，已自动备份并重建新库，GUI 正常运行。",
                "Notice: Corrupted database was backed up and rebuilt automatically.",
                "通知：破損した旧 DB を自動バックアップして再構築しました。",
            )});
        }
    }
    widgets.endCard();

    zgui.dummy(.{ .w = 0, .h = gap });

    if (widgets.beginCard(
        "##hist_gpu_temp",
        i18n.tr("GPU 温度历史趋势", "GPU Temp History", "GPU 温度履歴"),
        i18n.tr("实时环形缓冲区 + 每分钟自动落盘聚合", "Live ring buffer + 1-min SQLite flush", "リングバッファ＋1分間隔 DB 保存"),
        half_w,
        bot_h,
        s,
        &state.time_range,
    )) {
        const inner_h = @max(170.0 * s, zgui.getContentRegionAvail()[1] - 4.0 * s);
        widgets.drawLiveAreaPlot(monitoring.HISTORY_CAPACITY, "##hist_gpu_plot", "GPU °C", "°C", 20, 100, "°C", p.status_ok, &tel.gpu_temp_history, i18n.tr("等待 GPU 温度数据...", "Waiting for GPU temp...", "GPU 温度待機中..."), inner_h, s);
    }
    widgets.endCard();

    zgui.sameLine(.{ .spacing = gap });

    if (widgets.beginCard(
        "##hist_disk_temp",
        i18n.tr("主磁盘温度历史趋势", "Disk 0 Temp History", "ディスク0 温度履歴"),
        i18n.tr("无唤醒存储温度描述符 / NVMe 综合温度", "Zero-wake storage temp / NVMe composite", "非ウェイク温度取得 / NVMe 総合温度"),
        half_w,
        bot_h,
        s,
        &state.time_range,
    )) {
        const inner_h = @max(170.0 * s, zgui.getContentRegionAvail()[1] - 4.0 * s);
        widgets.drawLiveAreaPlot(monitoring.HISTORY_CAPACITY, "##hist_disk_plot", "Disk °C", "°C", 20, 90, "°C", p.accent_purple, &tel.disk0_temp_history, i18n.tr("等待磁盘温度数据...", "Waiting for disk temp...", "ディスク温度待機中..."), inner_h, s);
    }
    widgets.endCard();
}

fn renderAlertsView(state: *AppState, tel: *const SharedTelemetry) void {
    const s = state.dpi_scale;
    const p = theme.active();
    const avail_h = @max(320.0 * s, zgui.getContentRegionAvail()[1]);

    if (widgets.beginCard(
        "##alerts_card",
        i18n.tr("告警中心与规则溯源", "Alert Center & Rule Traceability", "アラートセンター・ルール根拠"),
        i18n.tr("持续时间防抖 30s • 温度回差恢复 5°C • 同规则 30 分钟抑制 • 磁盘规则严格对应 §2.5.5", "30s debounce • 5°C hysteresis • 30m suppression • Disk rules strictly follow §2.5.5", "30秒デバウンス・5°Cヒステリシス・30分抑制・§2.5.5 ルール準拠"),
        -1.0,
        avail_h,
        s,
        null,
    )) {
        widgets.drawStatusPill(
            if (tel.active_alert_count == 0)
                i18n.tr("当前无活动告警", "No Active Alerts", "アクティブなアラートなし")
            else
                i18n.tr("存在活动告警，请及时检查", "Active Alerts — Attention Required", "アクティブなアラートがあります"),
            if (tel.active_alert_count == 0) p.status_ok else p.status_critical,
            s,
        );
        if (tel.alert_history_count > 0) {
            zgui.sameLine(.{ .spacing = 16.0 * s });
            if (zgui.button(i18n.tr("全部标记已确认", "Acknowledge All", "すべて確認済にする"), .{})) {
                state.request_ack_alerts = true;
            }
        }
        zgui.dummy(.{ .w = 0, .h = 10.0 * s });

        if (tel.alert_history_count == 0) {
            zgui.textColored(p.text_secondary, "{s}", .{i18n.tr(
                "暂无历史告警记录。所有温度与 SMART 健康指标均在安全范围内。",
                "No alert history. All temperatures and SMART health metrics are within safe ranges.",
                "アラート履歴はありません。すべての温度および SMART 指標は安全範囲内です。",
            )});
        } else {
            if (zgui.beginTable("##alerts_table", .{
                .column = 5,
                .flags = .{ .borders = .{ .inner_h = true }, .row_bg = true, .sizing = .stretch_prop, .scroll_y = true },
            })) {
                zgui.tableSetupColumn(i18n.tr("级别", "Level", "レベル"), .{});
                zgui.tableSetupColumn(i18n.tr("规则 ID", "Rule ID", "ルール ID"), .{});
                zgui.tableSetupColumn(i18n.tr("设备 ID", "Device ID", "デバイス ID"), .{});
                zgui.tableSetupColumn(i18n.tr("触发原因与证据", "Reason & Evidence", "原因・根拠"), .{ .init_width_or_height = 2.0 });
                zgui.tableSetupColumn(i18n.tr("状态", "State", "状態"), .{});
                zgui.tableHeadersRow();

                for (tel.alert_history[0..tel.alert_history_count]) |ev| {
                    zgui.tableNextRow(.{});
                    _ = zgui.tableNextColumn();
                    widgets.drawStatusPill(
                        if (ev.is_recovery) i18n.tr("已恢复", "Recovered", "回復済") else ev.level.labelZh(),
                        if (ev.is_recovery) p.status_ok else p.healthColor(ev.level),
                        s,
                    );
                    _ = zgui.tableNextColumn();
                    zgui.text("{s}", .{ev.ruleIdSlice()});
                    _ = zgui.tableNextColumn();
                    zgui.textColored(p.accent_cyan, "{s}", .{ev.deviceIdSlice()});
                    _ = zgui.tableNextColumn();
                    zgui.textWrapped("{s}", .{ev.messageSlice()});
                    _ = zgui.tableNextColumn();
                    zgui.textColored(p.text_muted, "{s}", .{if (ev.acknowledged) i18n.tr("已确认", "Acked", "確認済") else i18n.tr("未确认", "Unread", "未確認")});
                }
                zgui.endTable();
            }
        }
    }
    widgets.endCard();
}

fn renderSettingsView(state: *AppState, tel: *const SharedTelemetry) void {
    const s = state.dpi_scale;
    const p = theme.active();
    const avail = zgui.getContentRegionAvail();
    const gap = 12.0 * s;
    const col_w = @max(300.0 * s, (avail[0] - gap) * 0.5);
    const full_h = @max(460.0 * s, avail[1]);

    if (widgets.beginCard(
        "##settings_behavior",
        i18n.tr("语言、外观、窗口与采集设置", "Language, Theme, Window & Polling", "言語・外観・ウィンドウ・監視設定"),
        i18n.tr("修改后点击“保存配置”持久化至 settings.toml", "Click Save to persist changes to settings.toml", "変更後に「設定を保存」を押すと settings.toml に保存されます"),
        col_w,
        full_h,
        s,
        null,
    )) {
        zgui.textColored(p.text_secondary, "{s}", .{i18n.tr("界面显示语言（实时生效）：", "Display Language (Instant):", "表示言語（即時反映）：")});
        if (zgui.radioButton("简体中文", .{ .active = state.language == .zh_cn })) {
            state.language = .zh_cn;
            i18n.setLanguage(.zh_cn);
        }
        zgui.sameLine(.{});
        if (zgui.radioButton("English", .{ .active = state.language == .en_us })) {
            state.language = .en_us;
            i18n.setLanguage(.en_us);
        }
        zgui.sameLine(.{});
        if (zgui.radioButton("日本語", .{ .active = state.language == .ja_jp })) {
            state.language = .ja_jp;
            i18n.setLanguage(.ja_jp);
        }

        zgui.dummy(.{ .w = 0, .h = 6.0 * s });
        zgui.textColored(p.text_secondary, "{s}", .{i18n.tr("界面颜色主题（实时生效）：", "Color Theme (Instant):", "カラーテーマ（即時反映）：")});
        if (zgui.radioButton(i18n.tr("深色主题 (黑)", "Dark Theme", "ダークテーマ"), .{ .active = state.theme_mode == .dark })) {
            state.theme_mode = .dark;
        }
        zgui.sameLine(.{});
        if (zgui.radioButton(i18n.tr("浅色主题 (白)", "Light Theme", "ライトテーマ"), .{ .active = state.theme_mode == .light })) {
            state.theme_mode = .light;
        }

        zgui.dummy(.{ .w = 0, .h = 6.0 * s });
        zgui.textColored(p.text_secondary, "{s}", .{i18n.tr("关闭窗口按钮行为：", "Close Button Behavior:", "閉じるボタンの動作：")});
        if (zgui.radioButton(i18n.tr("最小化到系统托盘（默认）", "Minimize to Tray (Default)", "トレイに最小化（初期値）"), .{ .active = state.close_behavior == .minimize_to_tray })) {
            state.close_behavior = .minimize_to_tray;
        }
        if (zgui.radioButton(i18n.tr("直接退出程序", "Exit Application", "アプリを終了"), .{ .active = state.close_behavior == .exit_app })) {
            state.close_behavior = .exit_app;
        }

        zgui.dummy(.{ .w = 0, .h = 6.0 * s });
        zgui.textColored(p.text_secondary, "{s}", .{i18n.tr("最小化按钮行为：", "Minimize Button Behavior:", "最小化ボタンの動作：")});
        if (zgui.radioButton(i18n.tr("最小化到任务栏（默认）", "Minimize to Taskbar (Default)", "タスクバーに最小化（初期値）"), .{ .active = state.minimize_behavior == .minimize_to_taskbar })) {
            state.minimize_behavior = .minimize_to_taskbar;
        }
        if (zgui.radioButton(i18n.tr("最小化到系统托盘##min_tray", "Minimize to Tray##min_tray", "トレイに最小化##min_tray"), .{ .active = state.minimize_behavior == .minimize_to_tray })) {
            state.minimize_behavior = .minimize_to_tray;
        }

        zgui.dummy(.{ .w = 0, .h = 6.0 * s });
        zgui.textColored(p.text_secondary, "{s}", .{i18n.tr("温度显示单位：", "Temperature Unit:", "温度の単位：")});
        if (zgui.radioButton(i18n.tr("摄氏度 (°C)", "Celsius (°C)", "摂氏 (°C)"), .{ .active = state.temp_unit == .celsius })) {
            state.temp_unit = .celsius;
        }
        zgui.sameLine(.{});
        if (zgui.radioButton(i18n.tr("华氏度 (°F)", "Fahrenheit (°F)", "華氏 (°F)"), .{ .active = state.temp_unit == .fahrenheit })) {
            state.temp_unit = .fahrenheit;
        }

        zgui.dummy(.{ .w = 0, .h = 6.0 * s });
        var sys_ms: i32 = @intCast(state.system_interval_ms);
        if (zgui.sliderInt(i18n.tr("系统采集间隔 (ms)", "System Polling (ms)", "システム監視間隔 (ms)"), .{ .v = &sys_ms, .min = 500, .max = 10000 })) {
            state.system_interval_ms = @intCast(sys_ms);
        }
        var smart_s: i32 = @intCast(state.smart_interval_ms / 1000);
        if (zgui.sliderInt(i18n.tr("SMART 采集间隔 (秒，≥30)", "SMART Interval (sec, >=30)", "SMART 取得間隔 (秒, >=30)"), .{ .v = &smart_s, .min = 30, .max = 600 })) {
            state.smart_interval_ms = @intCast(smart_s * 1000);
        }

        zgui.dummy(.{ .w = 0, .h = 6.0 * s });
        if (zgui.checkbox(i18n.tr("开机自动启动（勾选即立即生效，静默托盘启动）", "Start with Windows (Instant, starts in tray)", "Windows 起動時に自動開始（即時反映・トレイ常駐）"), .{ .v = &state.start_with_windows })) {
            state.request_save_config = true;
        }
        const auto_st = autostart.queryAutoStartStatus();
        zgui.sameLine(.{ .spacing = 8.0 * s });
        widgets.drawStatusPill(
            switch (auto_st) {
                .enabled => i18n.tr("系统自启已生效", "Active in OS", "登録済"),
                .disabled => i18n.tr("未注册", "Off", "未登録"),
                .blocked_by_os => i18n.tr("被任务管理器禁用", "Disabled in TaskMgr", "タスクマネージャ無効"),
            },
            switch (auto_st) {
                .enabled => p.status_ok,
                .disabled => p.status_unknown,
                .blocked_by_os => p.status_caution,
            },
            s,
        );
        _ = zgui.checkbox(i18n.tr("暂停后台采集", "Pause Background Monitoring", "バックグラウンド監視を一時停止"), .{ .v = &state.monitoring_paused });
        _ = zgui.checkbox(i18n.tr("允许唤醒休眠中的机械硬盘（默认关闭）", "Allow Waking Standby HDDs (Default Off)", "スリープ中の HDD 起動を許可（初期オフ）"), .{ .v = &state.allow_wake_standby_disk });
        _ = zgui.checkbox(i18n.tr("启用可选 LHM 扩展组件通信（默认关闭）", "Enable Optional LHM Extension (Default Off)", "任意 LHM 拡張通信を有効化（初期オフ）"), .{ .v = &state.extension_enabled });

        zgui.dummy(.{ .w = 0, .h = 8.0 * s });
        zgui.pushStyleColor4f(.{ .idx = .button, .c = p.accent_blue_soft });
        zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = p.accent_blue_hover });
        zgui.pushStyleColor4f(.{ .idx = .text, .c = p.accent_blue });
        if (zgui.button(i18n.tr("保存配置", "Save", "設定を保存"), .{ .w = 96.0 * s, .h = 30.0 * s })) {
            state.request_save_config = true;
        }
        zgui.popStyleColor(.{ .count = 3 });
        zgui.sameLine(.{});
        if (zgui.button(i18n.tr("恢复默认", "Defaults", "初期値"), .{ .w = 92.0 * s, .h = 30.0 * s })) {
            state.request_reset_config = true;
        }
        zgui.sameLine(.{});
        if (zgui.button(i18n.tr("导出配置", "Export", "出力"), .{ .w = 92.0 * s, .h = 30.0 * s })) {
            state.request_export_config = true;
        }
        zgui.sameLine(.{});
        if (zgui.button(i18n.tr("导入配置", "Import", "読込"), .{ .w = 92.0 * s, .h = 30.0 * s })) {
            state.request_import_config = true;
        }
        if (state.config_save_msg.len > 0) {
            zgui.dummy(.{ .w = 0, .h = 4.0 * s });
            zgui.textColored(p.status_ok, "{s}", .{state.config_save_msg});
        }
    }
    widgets.endCard();

    zgui.sameLine(.{ .spacing = gap });

    if (widgets.beginCard(
        "##settings_diag",
        i18n.tr("运行时、扩展组件与诊断", "Runtime, Extension & Diagnostics", "ランタイム・拡張機能・診断"),
        i18n.tr("全部为当前进程实时检测值", "Live process runtime diagnostics", "現在のプロセスのリアルタイム情報"),
        col_w,
        full_h,
        s,
        null,
    )) {
        widgets.drawKeyValueLine(
            i18n.tr("运行权限", "Privilege", "実行権限"),
            if (state.is_admin)
                i18n.trSlice("管理员 (Administrator)", "Administrator", "管理者 (Administrator)")
            else
                i18n.trSlice("普通用户 (Standard User)", "Standard User", "標準ユーザー"),
        );
        widgets.drawKeyValueLine(i18n.tr("当前语言", "Language", "表示言語"), state.language.nativeName());
        widgets.drawKeyValueLine(i18n.tr("当前主题", "Theme", "テーマ"), state.theme_mode.labelZh());
        widgets.drawKeyValueLine(
            i18n.tr("部署模式", "Deployment", "配置モード"),
            if (state.is_portable)
                i18n.trSlice("便携模式 (portable.flag)", "Portable (portable.flag)", "ポータブル (portable.flag)")
            else
                i18n.trSlice("安装模式 (%LOCALAPPDATA%)", "Installed (%LOCALAPPDATA%)", "インストール (%LOCALAPPDATA%)"),
        );
        widgets.drawKeyValueLine(i18n.tr("配置文件", "Config File", "設定ファイル"), if (state.config_path.len > 0) state.config_path else "N/A");
        widgets.drawKeyValueLine(i18n.tr("数据库路径", "DB Path", "DB パス"), if (state.db_path.len > 0) state.db_path else "N/A");
        widgets.drawKeyValueLine(
            i18n.tr("系统托盘", "System Tray", "システムトレイ"),
            if (state.tray_available)
                i18n.trSlice("已挂载", "Active", "有効")
            else
                i18n.trSlice("未挂载（自动降级）", "Unavailable (auto-fallback)", "未検出（自動フォールバック）"),
        );
        widgets.drawKeyValueLine(i18n.tr("当前字体", "Font", "フォント"), state.font_source);

        var lhm_buf: [96]u8 = undefined;
        const lhm_txt = if (tel.extension.connected)
            std.fmt.bufPrint(&lhm_buf, "{s} ({d} sensors, {s})", .{
                i18n.trSlice("已连接", "Connected", "接続済"),
                tel.extension.sensor_count,
                if (tel.extension.helper_is_admin) "Admin" else "User",
            }) catch "Connected"
        else if (state.extension_enabled)
            i18n.trSlice("已开启但未连接（请点击下方启动辅助进程）", "Enabled but disconnected (launch helper below)", "有効・未接続（下からヘルパーを起動）")
        else
            i18n.trSlice("已关闭（默认零驱动模式）", "Disabled (default zero-driver mode)", "オフ（初期ゼロドライバ構成）");
        widgets.drawKeyValueLine(i18n.tr("扩展辅助进程", "Extension Helper", "拡張ヘルパー"), lhm_txt);

        var dpi_buf: [64]u8 = undefined;
        const dpi_txt = std.fmt.bufPrint(&dpi_buf, "{d:.2}x  •  {s}", .{ state.dpi_scale, state.render_mode.labelZh() }) catch "";
        widgets.drawKeyValueLine(i18n.tr("DPI 与渲染", "DPI & Render", "DPI・描画"), dpi_txt);

        var frm_buf: [128]u8 = undefined;
        const frm_txt = std.fmt.bufPrint(&frm_buf, "{s} {d}  •  {s} {d}  •  PnP {d}  •  Resume {d}", .{
            i18n.trSlice("已渲染", "Rendered", "描画済"),
            state.rendered_frames,
            i18n.trSlice("节能跳过", "Skipped", "省電力スキップ"),
            state.skipped_frames,
            state.device_change_events,
            state.power_resume_events,
        }) catch "";
        widgets.drawKeyValueLine(i18n.tr("运行统计", "Runtime Stats", "稼働統計"), frm_txt);
        widgets.drawKeyValueLine(i18n.tr("开源许可", "License", "ライセンス"), "Core: Apache-2.0  •  Optional Helper: MPL-2.0");

        zgui.dummy(.{ .w = 0, .h = 10.0 * s });
        if (zgui.button(i18n.tr("启动 LHM 辅助进程 (需管理员)", "Launch LHM Helper (Admin)", "LHM ヘルパー起動 (管理者)"), .{ .w = 215.0 * s, .h = 30.0 * s })) {
            state.request_launch_lhm_helper = true;
        }
        zgui.sameLine(.{});
        if (zgui.button(i18n.tr("停止辅助进程", "Stop Helper", "ヘルパー停止"), .{ .w = 115.0 * s, .h = 30.0 * s })) {
            state.request_stop_lhm_helper = true;
        }
        if (state.lhm_action_msg.len > 0) {
            zgui.dummy(.{ .w = 0, .h = 4.0 * s });
            zgui.textColored(p.accent_blue, "{s}", .{state.lhm_action_msg});
        }

        zgui.dummy(.{ .w = 0, .h = 10.0 * s });
        if (zgui.button(i18n.tr("导出脱敏诊断报告", "Export Diagnostics", "診断レポート出力"), .{ .w = 165.0 * s, .h = 30.0 * s })) {
            state.request_export_diag = true;
        }
        zgui.sameLine(.{});
        if (zgui.button(i18n.tr("安全退出程序", "Exit Safely", "安全に終了"), .{ .w = 135.0 * s, .h = 30.0 * s })) {
            state.should_exit = true;
        }
        if (state.diag_export_msg.len > 0) {
            zgui.dummy(.{ .w = 0, .h = 4.0 * s });
            zgui.textColored(p.status_ok, "{s}", .{state.diag_export_msg});
        }
    }
    widgets.endCard();
}
