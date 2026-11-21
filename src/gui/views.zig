const std = @import("std");
const zgui = @import("zgui");
const state_mod = @import("../app/state.zig");
const AppState = state_mod.AppState;
const theme = @import("theme.zig");
const widgets = @import("widgets.zig");
const monitoring = @import("../services/monitoring.zig");
const SharedTelemetry = monitoring.SharedTelemetry;
const benchmarks = @import("../core/benchmarks.zig");
const BenchmarkSnapshot = benchmarks.BenchmarkSnapshot;

/// 规范 §7 + V2.0 全页面视图：
/// - 全部卡片依据窗口剩余高度动态延展，消除底部大面积空白；
/// - 全部长文本采用结构化分行与 textWrapped 自动换行，并允许卡片内滚动，确保文字 100% 完整可见；
/// - 全面适配深色 / 浅色（黑白）双主题。
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
        return std.fmt.bufPrintZ(buf, "{d}天 {d}小时 {d}分", .{ days, hours, mins }) catch "N/A";
    }
    return std.fmt.bufPrintZ(buf, "{d}小时 {d}分", .{ hours, mins }) catch "N/A";
}

fn renderTopHeader(state: *AppState, _: *const SharedTelemetry) void {
    const s = state.dpi_scale;
    const p = theme.active();
    zgui.pushFont(null, 22.0 * s);
    zgui.textColored(p.text_primary, "{s}", .{state.current_page.labelZh()});
    zgui.popFont();

    zgui.sameLine(.{});
    const right_w = 240.0 * s;
    const avail_w = zgui.getContentRegionAvail()[0];
    if (avail_w > right_w) {
        zgui.setCursorPosX(zgui.getCursorPosX() + avail_w - right_w);
    }

    var alert_buf: [48]u8 = undefined;
    const alert_txt = std.fmt.bufPrintZ(&alert_buf, "当前告警: {d}", .{state.active_alert_count}) catch "当前告警: 0";
    widgets.drawStatusPill(
        alert_txt,
        if (state.active_alert_count == 0) p.status_ok else p.status_critical,
        s,
    );
    zgui.sameLine(.{});
    widgets.drawStatusPill(
        if (state.monitoring_paused) "采集已暂停" else "实时采集中",
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

    // 动态占满整个可视高度：上排 44%，下排占满剩余全部高度（彻底消除底部大片留白与文字截断）
    const col3_w = @max(220.0 * s, (avail_w - gap * 2.0) / 3.0);
    const row1_h = @max(248.0 * s, (avail_h - gap) * 0.44);
    const row2_h = @max(310.0 * s, avail_h - row1_h - gap);

    // Card 1: 内存占用环形仪表
    if (widgets.beginCard("##dash_mem_donut", "物理内存占用", "GlobalMemoryStatusEx 实时采样", col3_w, row1_h, s, null)) {
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
                std.fmt.bufPrintZ(&foot_buf, "已用 {d:.1} GB / 总计 {d:.1} GB", .{ used_gb, total_gb }) catch "";

            const col = if (pct >= 90.0) p.status_critical else if (pct >= 80.0) p.status_caution else p.status_ok;
            widgets.drawDonutGauge(@floatCast(pct / 100.0), big_txt, "已使用", foot_txt, col, inner_h, s);
        } else {
            widgets.drawDonutGauge(null, "采集中", "初始化", "正在等待首个系统快照", p.accent_blue, inner_h, s);
        }
    }
    widgets.endCard();

    zgui.sameLine(.{ .spacing = gap });

    // Card 2: 内存实时面积趋势图
    if (widgets.beginCard("##dash_mem_card", "内存使用趋势", "内存环形缓冲区（最近 60 秒窗口）", col3_w, row1_h, s, &state.time_range)) {
        const inner_h = @max(150.0 * s, zgui.getContentRegionAvail()[1] - 4.0 * s);
        widgets.drawLiveAreaPlot(
            monitoring.HISTORY_CAPACITY,
            "##dash_mem_plot",
            "内存%",
            "%",
            0,
            100,
            "%",
            p.accent_blue,
            &tel.mem_usage_history,
            "等待首个内存采集样本...",
            inner_h,
            s,
        );
    }
    widgets.endCard();

    zgui.sameLine(.{ .spacing = gap });

    // Card 3: CPU 实时使用率圆弧仪表
    if (widgets.beginCard("##dash_cpu_gauge", "CPU 实时占用", "PDH / GetSystemTimes 实时采样", col3_w, row1_h, s, null)) {
        const inner_h = @max(150.0 * s, zgui.getContentRegionAvail()[1] - 4.0 * s);
        if (tel.has_system_sample and tel.system.cpu_usage_pct != null) {
            const pct = tel.system.cpu_usage_pct.?;
            var val_buf: [32]u8 = undefined;
            var cap_buf: [96]u8 = undefined;
            const val_txt = std.fmt.bufPrintZ(&val_buf, "{d:.1}%", .{pct}) catch "N/A";
            const cap_txt = if (tel.system.cpu_clock_mhz) |mhz|
                std.fmt.bufPrintZ(&cap_buf, "{d} 线程  •  {d:.2} GHz (计算值)", .{ tel.system.logical_cores, mhz / 1000.0 }) catch ""
            else
                std.fmt.bufPrintZ(&cap_buf, "{d} 逻辑处理器", .{tel.system.logical_cores}) catch "";
            const col = if (pct >= 90.0) p.status_critical else if (pct >= 75.0) p.status_caution else p.status_ok;
            widgets.drawArcGauge(@floatCast(pct / 100.0), val_txt, cap_txt, col, inner_h, s);
        } else {
            widgets.drawArcGauge(null, "N/A", "正在采集首个 CPU 样本...", p.accent_blue, inner_h, s);
        }
    }
    widgets.endCard();

    zgui.dummy(.{ .w = 0, .h = gap });

    // Row 2: 宽曲线 + 传感器状态表（自适应占满窗口剩余全部高度）
    const wide_w = @max(320.0 * s, (avail_w - gap) * 0.56);
    const side_w = @max(300.0 * s, avail_w - wide_w - gap);

    if (widgets.beginCard("##dash_cpu_trend", "CPU 使用率实时趋势", "数据源：PDH % Processor Utility（回退 GetSystemTimes）", wide_w, row2_h, s, &state.time_range)) {
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
            "等待首个 CPU 采集样本...",
            inner_h,
            s,
        );
    }
    widgets.endCard();

    zgui.sameLine(.{ .spacing = gap });

    if (widgets.beginCard("##dash_status_card", "传感器采集状态", "按规范 §1.2.1 权限能力矩阵实时报告", side_w, row2_h, s, null)) {
        if (zgui.beginTable("##dash_sensor_tbl", .{
            .column = 3,
            .flags = .{ .borders = .{ .inner_h = true }, .sizing = .stretch_prop },
        })) {
            zgui.tableSetupColumn("传感器项目", .{ .init_width_or_height = 1.4 });
            zgui.tableSetupColumn("当前读数", .{ .init_width_or_height = 0.85 });
            zgui.tableSetupColumn("状态 / 来源", .{ .init_width_or_height = 1.15 });
            zgui.tableHeadersRow();

            var cpu_val_buf: [32]u8 = undefined;
            const cpu_val = if (tel.has_system_sample and tel.system.cpu_usage_pct != null)
                std.fmt.bufPrintZ(&cpu_val_buf, "{d:.1}%", .{tel.system.cpu_usage_pct.?}) catch "N/A"
            else
                "N/A";
            widgets.drawMetricTableRow("CPU 使用率", cpu_val, if (tel.has_system_sample) tel.system.cpu_usage_status else .unknown, if (tel.has_system_sample and tel.system.cpu_usage_status == .ok) "实测值" else "采集中", s);

            var clk_val_buf: [32]u8 = undefined;
            const clk_val = if (tel.has_system_sample and tel.system.cpu_clock_mhz != null)
                std.fmt.bufPrintZ(&clk_val_buf, "{d:.2} GHz", .{tel.system.cpu_clock_mhz.? / 1000.0}) catch "N/A"
            else
                "N/A";
            widgets.drawMetricTableRow("CPU 频率", clk_val, if (tel.has_system_sample) tel.system.cpu_clock_status else .unknown, if (tel.has_system_sample and tel.system.cpu_clock_status == .ok) "计算值" else "采集中", s);

            if (tel.extension.connected and tel.extension.cpu_package_temp_c != null) {
                var ct_buf: [32]u8 = undefined;
                const ct_txt = std.fmt.bufPrintZ(&ct_buf, "{d:.1}{s}", .{
                    state.temp_unit.convert(tel.extension.cpu_package_temp_c.?),
                    state.temp_unit.symbol(),
                }) catch "N/A";
                widgets.drawMetricTableRow("CPU 封装温度", ct_txt, .ok, "扩展组件 (LHM)", s);
            } else {
                widgets.drawMetricTableRow(
                    "CPU 封装温度",
                    "N/A",
                    if (state.extension_enabled) .transient_error else .requires_extension,
                    if (state.extension_enabled) "等待辅助进程" else "需要扩展组件",
                    s,
                );
            }

            if (tel.has_gpu_sample and tel.gpu.count > 0 and tel.gpu.gpus[0].temp_c != null) {
                const g0 = &tel.gpu.gpus[0];
                var gt_buf: [32]u8 = undefined;
                const gt_txt = std.fmt.bufPrintZ(&gt_buf, "{d:.1}{s}", .{ state.temp_unit.convert(g0.temp_c.?), state.temp_unit.symbol() }) catch "N/A";
                widgets.drawMetricTableRow("GPU 温度", gt_txt, g0.temp_status, g0.temp_source, s);
            } else {
                widgets.drawMetricTableRow("GPU 温度", "N/A", .unsupported, "无传感器", s);
            }

            if (tel.has_disk_inventory and tel.disk_count > 0) {
                const d0 = &tel.disk_states[0];
                var dt_buf: [32]u8 = undefined;
                const dt_txt = if (d0.effectiveTempC()) |tc|
                    std.fmt.bufPrintZ(&dt_buf, "{d:.0}{s}", .{ state.temp_unit.convert(@floatFromInt(tc)), state.temp_unit.symbol() }) catch "N/A"
                else
                    "N/A";
                widgets.drawMetricTableRow("主磁盘温度 / 健康", dt_txt, d0.effectiveTempStatus(), d0.assessment.overall.labelZh(), s);
            } else {
                widgets.drawMetricTableRow("物理磁盘 SMART", "N/A", .unknown, "枚举中", s);
            }

            widgets.drawMetricTableRow(
                "ATA SMART (SATA)",
                "N/A",
                if (state.is_admin) .unknown else .access_denied,
                if (state.is_admin) "按盘检测" else "需要管理员",
                s,
            );
            if (tel.extension.connected and tel.extension.sensor_count > 0) {
                var ext_cnt_buf: [32]u8 = undefined;
                const ext_cnt_txt = std.fmt.bufPrintZ(&ext_cnt_buf, "{d} 项在线", .{tel.extension.sensor_count}) catch "在线";
                widgets.drawMetricTableRow("主板 / Super I/O", ext_cnt_txt, .ok, "扩展组件 (LHM)", s);
            } else {
                widgets.drawMetricTableRow(
                    "主板 / Super I/O",
                    "N/A",
                    if (state.extension_enabled) .transient_error else .requires_extension,
                    if (state.extension_enabled) "辅助进程未连" else "需要扩展组件",
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

    if (widgets.beginCard("##cpu_meta", "处理器规格与每核实时负载", "数据来源：Windows 注册表 / GetSystemInfo / PDH / NtQuerySystemInformation", -1.0, top_h, s, null)) {
        if (tel.has_system_sample) {
            zgui.pushFont(null, 18.0 * s);
            zgui.textColored(p.text_primary, "{s}", .{tel.system.cpuNameSlice()});
            zgui.popFont();
            zgui.dummy(.{ .w = 0, .h = 4.0 * s });

            var line1: [200]u8 = undefined;
            const s1 = std.fmt.bufPrint(&line1, "{d} 线程   •   基础频率 {d} MHz   •   来源：{s} ({s})", .{
                tel.system.logical_cores,
                tel.system.base_clock_mhz,
                tel.system.cpu_clock_source,
                tel.system.cpu_clock_accuracy.labelZh(),
            }) catch "";
            widgets.drawKeyValueLine("核心与频率", s1);

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
            zgui.textColored(p.text_muted, "正在采集处理器信息...", .{});
        }
    }
    widgets.endCard();

    zgui.dummy(.{ .w = 0, .h = gap });

    const left_w = (avail[0] - gap) * 0.66;
    const right_w = avail[0] - left_w - gap;

    if (widgets.beginCard("##cpu_usage_card", "CPU 使用率实时曲线", "禁止将 ACPI 热区温度冒充 CPU 温度", left_w, bot_h, s, &state.time_range)) {
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
            "等待 CPU 实时采样...",
            inner_h,
            s,
        );
    }
    widgets.endCard();

    zgui.sameLine(.{ .spacing = gap });

    if (widgets.beginCard("##cpu_temp_gauge", "CPU 封装温度", "需启用可选 LibreHardwareMonitor 扩展组件", right_w, bot_h, s, null)) {
        const inner_h = @max(170.0 * s, zgui.getContentRegionAvail()[1] - 34.0 * s);
        if (tel.extension.connected and tel.extension.cpu_package_temp_c != null) {
            const tc = tel.extension.cpu_package_temp_c.?;
            var vt_buf: [32]u8 = undefined;
            const vt = std.fmt.bufPrintZ(&vt_buf, "{d:.1}{s}", .{ state.temp_unit.convert(tc), state.temp_unit.symbol() }) catch "N/A";
            var cap_buf: [64]u8 = undefined;
            const cap = if (tel.extension.cpu_package_power_w) |pw|
                std.fmt.bufPrintZ(&cap_buf, "LHM 扩展 • 封装功耗 {d:.1} W", .{pw}) catch "LHM 扩展组件"
            else
                "扩展组件 (LHM 实测)";
            const col = if (tc >= 90.0) p.status_critical else if (tc >= 80.0) p.status_caution else p.status_ok;
            widgets.drawArcGauge(@floatCast(std.math.clamp(tc / 100.0, 0.0, 1.0)), vt, cap, col, inner_h, s);
        } else {
            const cap: [:0]const u8 = if (state.extension_enabled)
                (if (tel.extension.connected) "已连接但需管理员/驱动读取温度" else "辅助进程未运行")
            else
                "需要扩展组件（默认关闭）";
            widgets.drawArcGauge(null, "N/A", cap, p.status_caution, inner_h, s);
            if (!tel.extension.connected) {
                if (zgui.button("启动扩展组件 (需管理员)", .{ .w = -1.0, .h = 28.0 * s })) {
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

    if (widgets.beginCard("##gpu_meta", "图形处理器规格与实时参数", "数据源：动态 NVML / 通用 D3DKMT（普通用户权限可用）", -1.0, top_h, s, null)) {
        if (tel.has_gpu_sample and tel.gpu.count > 0) {
            const g0 = &tel.gpu.gpus[0];
            zgui.pushFont(null, 18.0 * s);
            zgui.textColored(p.text_primary, "{s}", .{g0.nameSlice()});
            zgui.popFont();
            zgui.dummy(.{ .w = 0, .h = 6.0 * s });

            var row1: [200]u8 = undefined;
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
            const r1 = std.fmt.bufPrint(&row1, "功耗 {s}   •   显存 {s}   •   占用率 {s}", .{ pwr_txt, vram_txt, util_txt }) catch "";
            widgets.drawKeyValueLine("功耗与显存", r1);

            var row2: [200]u8 = undefined;
            var clk_buf: [48]u8 = undefined;
            const clk_txt = if (g0.core_clock_mhz) |c|
                std.fmt.bufPrint(&clk_buf, "核心 {d} MHz / 显存 {d} MHz", .{ c, g0.mem_clock_mhz orelse 0 }) catch "N/A"
            else if (g0.mem_clock_mhz) |m|
                std.fmt.bufPrint(&clk_buf, "显存 {d} MHz", .{m}) catch "N/A"
            else
                "N/A";
            var fan_buf: [24]u8 = undefined;
            const fan_txt = if (g0.fan_rpm) |rpm|
                std.fmt.bufPrint(&fan_buf, "{d} RPM", .{rpm}) catch "N/A"
            else if (g0.fan_pct) |fp|
                std.fmt.bufPrint(&fan_buf, "{d}%", .{fp}) catch "N/A"
            else
                "N/A";
            const r2 = std.fmt.bufPrint(&row2, "{s}   •   风扇 {s}   •   温度来源 {s}   •   显卡总数 {d}", .{ clk_txt, fan_txt, g0.temp_source, tel.gpu.count }) catch "";
            widgets.drawKeyValueLine("频率与散热", r2);
        } else {
            zgui.textColored(p.text_muted, "正在采集 GPU 信息...", .{});
        }
    }
    widgets.endCard();

    zgui.dummy(.{ .w = 0, .h = gap });

    const left_w = (avail[0] - gap) * 0.66;
    const right_w = avail[0] - left_w - gap;

    if (widgets.beginCard("##gpu_trend_card", "GPU 温度实时曲线", "实时面积趋势 + 当前 / 平均 / 峰值 统计", left_w, bot_h, s, &state.time_range)) {
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
            "等待 GPU 温度样本...",
            inner_h,
            s,
        );
    }
    widgets.endCard();

    zgui.sameLine(.{ .spacing = gap });

    if (widgets.beginCard("##gpu_gauge_card", "GPU 核心温度", "多 GPU 独立 Provider 隔离", right_w, bot_h, s, null)) {
        const inner_h = @max(170.0 * s, zgui.getContentRegionAvail()[1] - 4.0 * s);
        if (tel.has_gpu_sample and tel.gpu.count > 0 and tel.gpu.gpus[0].temp_c != null) {
            const tc = tel.gpu.gpus[0].temp_c.?;
            const disp_t = state.temp_unit.convert(tc);
            var vt_buf: [32]u8 = undefined;
            const vt = std.fmt.bufPrintZ(&vt_buf, "{d:.1}{s}", .{ disp_t, state.temp_unit.symbol() }) catch "N/A";
            const col = if (tc >= 90.0) p.status_critical else if (tc >= 80.0) p.status_caution else p.status_ok;
            widgets.drawArcGauge(@floatCast(std.math.clamp(tc / 100.0, 0.0, 1.0)), vt, tel.gpu.gpus[0].temp_source, col, inner_h, s);
        } else {
            widgets.drawArcGauge(null, "N/A", "无可用 GPU 温度传感器", p.status_unknown, inner_h, s);
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

    if (widgets.beginCard("##mem_donut_card", "物理内存使用率", "GlobalMemoryStatusEx 实时数据", left_w, top_h, s, null)) {
        const inner_h = @max(150.0 * s, zgui.getContentRegionAvail()[1] - 4.0 * s);
        if (tel.has_system_sample and tel.system.mem_load_pct != null) {
            const pct = tel.system.mem_load_pct.?;
            const used_gb = @as(f64, @floatFromInt(tel.system.mem_used_bytes)) / (1024.0 * 1024.0 * 1024.0);
            const avail_gb = @as(f64, @floatFromInt(tel.system.mem_avail_bytes)) / (1024.0 * 1024.0 * 1024.0);
            const total_gb = @as(f64, @floatFromInt(tel.system.mem_total_bytes)) / (1024.0 * 1024.0 * 1024.0);
            var big_buf: [32]u8 = undefined;
            var foot_buf: [80]u8 = undefined;
            const big_txt = std.fmt.bufPrintZ(&big_buf, "{d:.1}%", .{pct}) catch "N/A";
            const foot_txt = std.fmt.bufPrintZ(&foot_buf, "已用 {d:.1} GB  •  可用 {d:.1} / {d:.1} GB", .{ used_gb, avail_gb, total_gb }) catch "";
            widgets.drawDonutGauge(@floatCast(pct / 100.0), big_txt, "已使用", foot_txt, p.accent_blue, inner_h, s);
        } else {
            widgets.drawDonutGauge(null, "N/A", "采集中", "正在读取系统内存", p.accent_blue, inner_h, s);
        }
    }
    widgets.endCard();

    zgui.sameLine(.{ .spacing = gap });

    if (widgets.beginCard("##mem_trend_card", "内存使用历史趋势", "实时环形缓冲区（每 2 秒采样）", right_w, top_h, s, &state.time_range)) {
        const inner_h = @max(150.0 * s, zgui.getContentRegionAvail()[1] - 4.0 * s);
        widgets.drawLiveAreaPlot(
            monitoring.HISTORY_CAPACITY,
            "##mem_plot",
            "内存%",
            "%",
            0,
            100,
            "%",
            p.accent_blue,
            &tel.mem_usage_history,
            "等待首个内存采集样本...",
            inner_h,
            s,
        );
    }
    widgets.endCard();

    zgui.dummy(.{ .w = 0, .h = gap });

    if (widgets.beginCard("##mem_dimm_table", "SMBIOS 物理内存插槽明细", "数据来源：GetSystemFirmwareTable (RSMB Type 17) • 序列号默认脱敏", -1.0, bot_h, s, null)) {
        if (tel.has_system_sample and tel.system.smbios_info.dimm_count > 0) {
            if (zgui.beginTable("##dimms", .{
                .column = 7,
                .flags = .{ .borders = .{ .inner_h = true }, .row_bg = true, .sizing = .stretch_prop, .scroll_y = true },
            })) {
                zgui.tableSetupColumn("插槽", .{});
                zgui.tableSetupColumn("类型", .{});
                zgui.tableSetupColumn("容量", .{});
                zgui.tableSetupColumn("运行频率", .{});
                zgui.tableSetupColumn("厂商", .{});
                zgui.tableSetupColumn("型号", .{});
                zgui.tableSetupColumn("序列号 (脱敏)", .{});
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
                    zgui.text("{s}", .{if (d.manufacturer_len > 0) d.manufacturerSlice() else "未知"});
                    _ = zgui.tableNextColumn();
                    zgui.text("{s}", .{if (d.part_number_len > 0) d.partNumberSlice() else "N/A"});
                    _ = zgui.tableNextColumn();
                    zgui.textColored(p.text_secondary, "{s}", .{d.serialMaskedSlice()});
                }
                zgui.endTable();
            }
        } else {
            zgui.textColored(p.text_muted, "当前 SMBIOS 表未返回有效内存条记录（常见于部分虚拟机或受限固件）。", .{});
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

    if (widgets.beginCard("##mb_smbios_card", "主板与系统基本信息", "数据来源：SMBIOS Type 2 与 GetTickCount64（用户态）", -1.0, top_h, s, null)) {
        if (tel.has_system_sample and tel.system.smbios_info.available) {
            const sb = &tel.system.smbios_info;
            widgets.drawKeyValueLine("主板厂商", if (sb.board_manufacturer_len > 0) sb.boardManufacturer() else "N/A");
            widgets.drawKeyValueLine("主板型号", if (sb.board_product_len > 0) sb.boardProduct() else "N/A");
            var vb: [96]u8 = undefined;
            var up_buf: [64]u8 = undefined;
            const up_txt = formatUptime(tel.system.uptime_seconds, &up_buf);
            const vs = std.fmt.bufPrint(&vb, "{s}   •   SMBIOS {d}.{d}   •   系统已开机 {s}", .{
                if (sb.board_version_len > 0) sb.boardVersion() else "N/A",
                sb.major_version,
                sb.minor_version,
                up_txt,
            }) catch "N/A";
            widgets.drawKeyValueLine("版本与开机时长", vs);

            var io_buf: [160]u8 = undefined;
            const io_str = std.fmt.bufPrint(&io_buf, "磁盘读 {d:.1} MB/s  •  写 {d:.1} MB/s  •  {d:.0} IOPS", .{
                tel.system.disk_read_mbs orelse 0.0,
                tel.system.disk_write_mbs orelse 0.0,
                tel.system.disk_iops orelse 0.0,
            }) catch "N/A";
            widgets.drawKeyValueLine("存储实时吞吐", io_str);

            var bat_buf: [96]u8 = undefined;
            const bat_str = if (tel.system.battery.has_battery)
                std.fmt.bufPrint(&bat_buf, "{s}  •  电量 {d}%", .{
                    if (tel.system.battery.ac_online) "交流供电/充电" else "电池放电",
                    tel.system.battery.charge_pct orelse 0,
                }) catch "电池在线"
            else
                "台式机 / 无内置电池（交流供电）";
            widgets.drawKeyValueLine("电源与电池", bat_str);
        } else {
            zgui.textColored(p.text_muted, "正在读取 SMBIOS 主板信息...", .{});
        }
    }
    widgets.endCard();

    zgui.dummy(.{ .w = 0, .h = gap });

    if (widgets.beginCard("##mb_info_card", "主板 Super I/O 与扩展传感器", "保留厂商原始传感器名称，不强行归类（通过独立 MPL-2.0 辅助进程提供）", -1.0, bot_h, s, null)) {
        if (tel.extension.connected) {
            widgets.drawStatusPill(
                if (tel.extension.helper_is_admin) "扩展组件已连接（管理员权限）" else "扩展组件已连接（普通权限，部分传感器受限）",
                if (tel.extension.helper_is_admin) p.status_ok else p.status_caution,
                s,
            );
            zgui.sameLine(.{});
            if (zgui.button("停止辅助进程", .{})) {
                state.request_stop_lhm_helper = true;
            }
            zgui.dummy(.{ .w = 0, .h = 6.0 * s });

            if (tel.extension.sensor_count == 0) {
                zgui.textWrapped("扩展辅助进程已连接，但当前未读到可用传感器。请确认以管理员身份启动辅助进程，并在 Windows 11 内存完整性环境下按文档安装受信任的 PawnIO 驱动。", .{});
            } else if (zgui.beginTable("##lhm_sensors_tbl", .{
                .column = 4,
                .flags = .{ .borders = .{ .inner_h = true }, .row_bg = true, .sizing = .stretch_prop, .scroll_y = true },
            })) {
                zgui.tableSetupColumn("硬件设备", .{ .init_width_or_height = 1.4 });
                zgui.tableSetupColumn("原始传感器名", .{ .init_width_or_height = 1.4 });
                zgui.tableSetupColumn("类型", .{ .init_width_or_height = 0.8 });
                zgui.tableSetupColumn("实时数值", .{ .init_width_or_height = 0.8 });
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
                if (state.extension_enabled) "等待扩展辅助进程连接" else "扩展组件未启用（默认关闭）",
                p.status_caution,
                s,
            );
            zgui.sameLine(.{});
            if (zgui.button("启动扩展辅助进程 (需管理员)", .{})) {
                state.request_launch_lhm_helper = true;
            }
            if (state.lhm_action_msg.len > 0) {
                zgui.dummy(.{ .w = 0, .h = 4.0 * s });
                zgui.textColored(p.accent_blue, "{s}", .{state.lhm_action_msg});
            }
            zgui.dummy(.{ .w = 0, .h = 10.0 * s });
            zgui.textWrapped("CPU 封装温度/功耗、主板芯片组温度、VRM 温度、机箱风扇转速与电压需要内核级硬件访问。按照规范 §1.2，主程序本体（Apache-2.0）坚持零内核驱动。", .{});
            zgui.dummy(.{ .w = 0, .h = 4.0 * s });
            zgui.pushStyleColor4f(.{ .idx = .text, .c = p.text_secondary });
            zgui.textWrapped("点击上方按钮将显式按需启动独立隔离的 WinHardwareMonitor.LhmHelper.exe（MPL-2.0，仅只读、零网络、同用户命名管道通信）；不自动静默安装第三方驱动。", .{});
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

    if (widgets.beginCard("##disks_card", "物理磁盘列表与健康状态", "点击任意磁盘查看下方完整 SMART 详情 • 休眠磁盘默认不唤醒", -1.0, top_h, s, null)) {
        if (!tel.has_disk_inventory) {
            widgets.drawStatusPill("正在枚举物理磁盘与 SMART...", p.accent_blue, s);
        } else if (tel.disk_count == 0) {
            widgets.drawStatusPill("未发现物理磁盘", p.status_unknown, s);
        } else {
            if (state.selected_disk_idx >= tel.disk_count) state.selected_disk_idx = 0;

            if (zgui.beginTable("##disks_table", .{
                .column = 8,
                .flags = .{ .borders = .{ .inner_h = true }, .row_bg = true, .sizing = .stretch_prop, .scroll_y = true },
            })) {
                zgui.tableSetupColumn("设备", .{});
                zgui.tableSetupColumn("型号", .{ .init_width_or_height = 1.8 });
                zgui.tableSetupColumn("接口", .{});
                zgui.tableSetupColumn("容量", .{});
                zgui.tableSetupColumn("温度", .{});
                zgui.tableSetupColumn("健康状态", .{});
                zgui.tableSetupColumn("通电时间", .{});
                zgui.tableSetupColumn("操作", .{});
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
                    var btn_buf: [32]u8 = undefined;
                    const btn_lbl = std.fmt.bufPrintZ(&btn_buf, "{s}##sel_disk_{d}", .{
                        if (state.selected_disk_idx == idx) "查看中" else "详情",
                        idx,
                    }) catch "详情";
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
    const detail_title = std.fmt.bufPrintZ(&title_buf, "磁盘详情：Disk {d} — {s}", .{ d.drive_index, model_str }) catch "磁盘详情";

    if (widgets.beginCard("##disk_detail_card", detail_title, "SMART 正常不代表硬盘不会突然损坏，请定期做好重要数据备份", -1.0, bot_h, s, null)) {
        var meta1: [240]u8 = undefined;
        const m1 = std.fmt.bufPrint(&meta1, "接口 {s}   •   固件 {s}   •   序列号 {s}   •   稳定 ID {s}{s}   •   {s}", .{
            d.bus_type.name(),
            d.firmwareSlice(),
            d.serialMaskedSlice(),
            d.stable_id.slice(),
            if (d.stable_id.is_stable) "" else " (不稳定)",
            d.support.labelZh(),
        }) catch "";
        zgui.pushStyleColor4f(.{ .idx = .text, .c = p.text_secondary });
        zgui.textWrapped("{s}", .{m1});
        zgui.popStyleColor(.{ .count = 1 });

        zgui.dummy(.{ .w = 0, .h = 6.0 * s });
        widgets.drawStatusPill(ds.assessment.overall.labelZh(), p.healthColor(ds.assessment.overall), s);
        zgui.sameLine(.{});
        if (ds.nvme.wctemp_c) |wc| {
            zgui.textColored(p.text_secondary, "设备温度阈值：警告 {d}°C / 临界 {d}°C", .{ wc, ds.nvme.cctemp_c orelse 0 });
            zgui.sameLine(.{ .spacing = 16.0 * s });
        }
        if (ds.baseline.initialized) {
            if (zgui.button("以当前值重设基线", .{})) {
                state.request_reset_baseline_idx = state.selected_disk_idx;
            }
        }
        if (ds.ata.status == .ok) {
            zgui.sameLine(.{ .spacing = 12.0 * s });
            _ = zgui.checkbox("确认下发自检", .{ .v = &state.bench_smart_confirmed });
            zgui.sameLine(.{ .spacing = 6.0 * s });
            if (zgui.button("执行 SMART 短自检 (~2分)", .{})) {
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
            zgui.textColored(p.status_ok, "全部已检测健康规则均正常（无 Critical Warning / 介质错误 / 扇区重映射异常）。", .{});
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
                zgui.textWrapped("该设备属于“{s}”，Windows 标准存储接口无法直读底层 SMART，因此健康状态标注为“未知”。", .{d.support.labelZh()});
            } else if (d.removable and d.bus_type == .usb) {
                zgui.textWrapped("该设备为可移动 USB 存储（普通 U 盘主控固件通常不提供 SMART 健康统计，状态码={s} / 错误码={d}）；规范严禁编造健康度或发送 USB 桥接厂商私有命令。", .{ st.labelZh(), err orelse 0 });
            } else if (st == .access_denied) {
                zgui.textWrapped("读取该磁盘的 ATA/SAT SMART 需要以读写权限打开物理设备句柄（Win32 错误码 {d} = ERROR_ACCESS_DENIED）。请点击左侧“以管理员身份重启”后再查看。", .{err orelse 5});
            } else if (st == .device_standby) {
                zgui.textWrapped("该磁盘当前处于休眠/待机状态，已按规范 §2.5.4 跳过 SMART 读取以避免唤醒增加磨损。", .{});
            } else {
                zgui.textWrapped("当前无法读取该磁盘的 SMART 属性（状态：{s}，错误码：{d}）。USB 外接盒受桥接芯片固件限制，V1 严禁发送厂商私有命令。", .{ st.labelZh(), err orelse 0 });
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
        zgui.tableSetupColumn("NVMe SMART 指标", .{ .init_width_or_height = 1.1 });
        zgui.tableSetupColumn("当前值", .{ .init_width_or_height = 0.9 });
        zgui.tableSetupColumn("说明", .{ .init_width_or_height = 1.6 });
        zgui.tableHeadersRow();

        nvmeRow("Critical Warning", "0x{X:0>2}", .{nv.critical_warning}, if (nv.critical_warning == 0) "无严重硬件健康警告" else "存在严重警告位，请查看上方规则证据");
        if (nv.composite_temp_c) |tc| {
            nvmeRow("Composite Temperature", "{d:.0}{s} ({d} K)", .{ unit.convert(@floatFromInt(tc)), unit.symbol(), nv.composite_temp_k }, "综合温度");
        }
        nvmeRow("Available Spare / Threshold", "{d}% / {d}%", .{ nv.available_spare, nv.available_spare_threshold }, "可用备用块比例及设备阈值");
        nvmeRow("Percentage Used", "{d}%", .{nv.percentage_used}, "厂商寿命消耗估计（非精确剩余寿命，可超 100%）");
        nvmeRow("累计读取量 (Data Units Read)", "{d:.2} TB ({d} units)", .{ nv.bytesReadTB(), nv.data_units_read }, "128 位计数，1 unit = 512,000 字节");
        nvmeRow("累计写入量 (Data Units Written)", "{d:.2} TB ({d} units)", .{ nv.bytesWrittenTB(), nv.data_units_written }, "128 位计数，1 unit = 512,000 字节");
        nvmeRow("累计通电时间 (Power On Hours)", "{d} 小时", .{nv.power_on_hours}, "控制器累计通电运行时间");
        nvmeRow("通电次数 (Power Cycles)", "{d} 次", .{nv.power_cycles}, "累计通电循环次数");
        nvmeRow("非正常关机 (Unsafe Shutdowns)", "{d} 次", .{nv.unsafe_shutdowns}, "未收到正常关机通知的断电次数");
        nvmeRow("介质及数据完整性错误", "{d}", .{nv.media_errors}, "不可恢复 ECC/CRC 完整性错误计数");
        nvmeRow("错误日志条目 (Error Log Entries)", "{d}", .{nv.error_log_entries}, "历史错误日志总条数");
        nvmeRow("高温累计时间 (Warn / Crit)", "{d} 分 / {d} 分", .{ nv.warning_temp_time_min, nv.critical_temp_time_min }, "超过警告/临界温度的累计时间");
        for (nv.temp_sensors_c, 0..) |ts_opt, ti| {
            if (ts_opt) |ts| {
                var lbl_b: [32]u8 = undefined;
                const lbl = std.fmt.bufPrintZ(&lbl_b, "温度传感器 #{d}", .{ti + 1}) catch "温度传感器";
                nvmeRow(lbl, "{d:.0}{s}", .{ unit.convert(@floatFromInt(ts)), unit.symbol() }, "NVMe 控制器附加温度探头");
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
        zgui.tableSetupColumn("属性名称", .{ .init_width_or_height = 1.4 });
        zgui.tableSetupColumn("类型", .{});
        zgui.tableSetupColumn("当前值", .{});
        zgui.tableSetupColumn("最差值", .{});
        zgui.tableSetupColumn("阈值", .{});
        zgui.tableSetupColumn("原始值 (Hex / Dec)", .{ .init_width_or_height = 1.4 });
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

    if (widgets.beginCard("##all_sensors_card", "全传感器实时统计表（HWiNFO 风格）", "自动累计所有活跃传感器的当前 / 最小 / 平均 / 最大值，支持一键清零与 CSV 导出", -1.0, @max(360.0 * s, avail_h), s, null)) {
        if (zgui.button("清零最小 / 平均 / 最大统计", .{ .w = 210.0 * s, .h = 28.0 * s })) {
            state.request_reset_sensor_stats = true;
        }
        zgui.sameLine(.{});
        if (zgui.button("导出 CSV 报表至 logs", .{ .w = 180.0 * s, .h = 28.0 * s })) {
            state.request_export_sensors_csv = true;
        }
        if (state.sensors_csv_msg.len > 0) {
            zgui.sameLine(.{ .spacing = 12.0 * s });
            zgui.textColored(p.status_ok, "{s}", .{state.sensors_csv_msg});
        }
        zgui.dummy(.{ .w = 0, .h = 8.0 * s });

        const rows = tel.sensor_stats.slice();
        if (rows.len == 0) {
            zgui.textColored(p.text_muted, "正在等待首个传感器采样周期...", .{});
        } else if (zgui.beginTable("##sensors_stats_tbl", .{
            .column = 7,
            .flags = .{ .borders = .{ .inner_h = true }, .row_bg = true, .sizing = .stretch_prop, .scroll_y = true },
        })) {
            zgui.tableSetupColumn("分类", .{ .init_width_or_height = 0.8 });
            zgui.tableSetupColumn("传感器名称", .{ .init_width_or_height = 1.6 });
            zgui.tableSetupColumn("当前值", .{ .init_width_or_height = 0.8 });
            zgui.tableSetupColumn("最小值", .{ .init_width_or_height = 0.8 });
            zgui.tableSetupColumn("平均值", .{ .init_width_or_height = 0.8 });
            zgui.tableSetupColumn("最大值", .{ .init_width_or_height = 0.8 });
            zgui.tableSetupColumn("采样数", .{ .init_width_or_height = 0.6 });
            zgui.tableHeadersRow();

            for (rows) |*e| {
                const is_c = std.mem.eql(u8, e.unitSlice(), "C");
                const disp_unit = if (is_c) state.temp_unit.symbol() else e.unitSlice();
                const cur_v = if (is_c) state.temp_unit.convert(e.current) else e.current;
                const min_v = if (is_c) state.temp_unit.convert(e.min_val) else e.min_val;
                const avg_v = if (is_c) state.temp_unit.convert(e.avg()) else e.avg();
                const max_v = if (is_c) state.temp_unit.convert(e.max_val) else e.max_val;

                zgui.tableNextRow(.{});
                _ = zgui.tableNextColumn();
                zgui.textColored(p.text_muted, "{s}", .{e.categorySlice()});
                _ = zgui.tableNextColumn();
                zgui.text("{s}", .{e.nameSlice()});
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

fn renderStressTestView(state: *AppState, tel: *const SharedTelemetry, bench: *const BenchmarkSnapshot) void {
    const s = state.dpi_scale;
    const p = theme.active();
    const avail = zgui.getContentRegionAvail();
    const gap = 12.0 * s;
    const left_w = @max(340.0 * s, (avail[0] - gap) * 0.48);
    const right_w = avail[0] - left_w - gap;
    const full_h = @max(460.0 * s, avail[1]);

    if (widgets.beginCard("##bench_ctrl_card", "硬件稳定性与基准测试控制台 (V2.0)", "所有主动负载均内置高温自动熔断保护；磁盘测速仅写受控临时文件，绝不写裸盘", left_w, full_h, s, null)) {
        const max_threads: i32 = @intCast(@max(tel.system.logical_cores, 1));
        _ = zgui.sliderInt("CPU 测试线程数", .{ .v = &state.bench_cpu_threads, .min = 1, .max = max_threads });
        _ = zgui.sliderInt("烤机持续时长 (秒)", .{ .v = &state.bench_duration_s, .min = 10, .max = 300 });
        _ = zgui.sliderInt("高温自动熔断阈值 (°C)", .{ .v = &state.bench_thermal_cutoff_c, .min = 70, .max = 100 });
        _ = zgui.sliderInt("内存校验容量 (MB)", .{ .v = &state.bench_mem_mb, .min = 64, .max = 1024 });
        _ = zgui.sliderInt("磁盘临时文件大小 (MB)", .{ .v = &state.bench_disk_mb, .min = 64, .max = 1024 });

        zgui.dummy(.{ .w = 0, .h = 6.0 * s });
        _ = zgui.checkbox("二次确认：允许在 logs 目录创建临时文件进行磁盘测速（结束后自动删除）", .{ .v = &state.bench_disk_confirmed });

        zgui.dummy(.{ .w = 0, .h = 8.0 * s });
        const running = (bench.outcome == .running);

        zgui.beginDisabled(.{ .disabled = running });
        zgui.pushStyleColor4f(.{ .idx = .button, .c = p.accent_blue_soft });
        zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = p.accent_blue_hover });
        zgui.pushStyleColor4f(.{ .idx = .text, .c = p.accent_blue });
        if (zgui.button("1. 启动 CPU 算力与稳定性校验", .{ .w = -1.0, .h = 32.0 * s })) {
            state.request_start_cpu_bench = true;
        }
        if (zgui.button("2. 启动 4 轮内存位翻转与带宽校验 (MemTest)", .{ .w = -1.0, .h = 32.0 * s })) {
            state.request_start_mem_bench = true;
        }
        if (zgui.button("3. 启动磁盘 SEQ1M / RND4K 文件级测速", .{ .w = -1.0, .h = 32.0 * s })) {
            state.request_start_disk_bench = true;
        }
        if (zgui.button("4. 启动 GPU OpenGL 3.3 渲染烤机", .{ .w = -1.0, .h = 32.0 * s })) {
            state.request_start_gpu_bench = true;
        }
        zgui.popStyleColor(.{ .count = 3 });
        zgui.endDisabled();

        zgui.dummy(.{ .w = 0, .h = 8.0 * s });
        zgui.pushStyleColor4f(.{ .idx = .button, .c = .{ p.status_critical[0], p.status_critical[1], p.status_critical[2], 0.22 } });
        zgui.pushStyleColor4f(.{ .idx = .text, .c = p.status_critical });
        if (zgui.button("立即停止当前测试", .{ .w = 160.0 * s, .h = 30.0 * s })) {
            state.request_stop_bench = true;
        }
        zgui.popStyleColor(.{ .count = 2 });
        zgui.sameLine(.{});
        if (zgui.button("导出硬件测试报告", .{ .w = 160.0 * s, .h = 30.0 * s })) {
            state.request_export_bench_report = true;
        }

        if (state.bench_msg.len > 0) {
            zgui.dummy(.{ .w = 0, .h = 6.0 * s });
            zgui.textWrapped("{s}", .{state.bench_msg});
        }
    }
    widgets.endCard();

    zgui.sameLine(.{ .spacing = gap });

    if (widgets.beginCard("##bench_result_card", "实时执行进度与实测结果", "联动监控实时温度与计算校验错误数", right_w, full_h, s, null)) {
        const badge_col = switch (bench.outcome) {
            .passed => p.status_ok,
            .running => p.accent_blue,
            .failed_errors, .stopped_by_thermal, .failed_io => p.status_critical,
            .stopped_by_user, .idle => p.status_unknown,
        };
        widgets.drawStatusPill(bench.outcome.labelZh(), badge_col, s);
        zgui.sameLine(.{ .spacing = 10.0 * s });
        zgui.textColored(p.text_secondary, "项目：{s}", .{bench.last_kind.labelZh()});

        zgui.dummy(.{ .w = 0, .h = 8.0 * s });
        var prog_buf: [32]u8 = undefined;
        const prog_txt = std.fmt.bufPrintZ(&prog_buf, "{d:.0}% ({d:.1}s)", .{ bench.progress_pct, bench.elapsed_s }) catch "";
        zgui.progressBar(.{ .fraction = bench.progress_pct / 100.0, .w = -1.0, .h = 22.0 * s, .overlay = prog_txt });

        zgui.dummy(.{ .w = 0, .h = 8.0 * s });
        var err_buf: [64]u8 = undefined;
        const err_str = std.fmt.bufPrint(&err_buf, "{d} 个（0 = 硬件计算/位校验正常）", .{bench.error_count}) catch "0";
        widgets.drawKeyValueLine("硬件错误计数", err_str);

        var peak_buf: [80]u8 = undefined;
        const peak_str = if (bench.peak_temp_c) |pt|
            std.fmt.bufPrint(&peak_buf, "{d:.1}{s}  •  熔断上限 {d:.0}{s}", .{
                state.temp_unit.convert(pt),
                state.temp_unit.symbol(),
                state.temp_unit.convert(bench.thermal_cutoff_c),
                state.temp_unit.symbol(),
            }) catch "N/A"
        else
            "N/A（建议启用 LHM 扩展或参考 GPU 温度）";
        widgets.drawKeyValueLine("期间峰值温度", peak_str);

        zgui.dummy(.{ .w = 0, .h = 6.0 * s });
        zgui.separator();
        zgui.dummy(.{ .w = 0, .h = 6.0 * s });

        switch (bench.last_kind) {
            .cpu_stress => {
                var b1: [96]u8 = undefined;
                const s1 = std.fmt.bufPrint(&b1, "{d} 线程  •  综合算力 {d:.2} MOPS (百万次确定性混合运算/秒)", .{ bench.cpu_threads, bench.cpu_score_mops }) catch "";
                widgets.drawKeyValueLine("CPU 实测成绩", s1);
            },
            .memory_verify => {
                var b1: [128]u8 = undefined;
                const s1 = std.fmt.bufPrint(&b1, "容量 {d} MB  •  完成 {d}/4 轮  •  写入 {d:.2} GB/s  •  回读校验 {d:.2} GB/s", .{
                    bench.mem_tested_mb, bench.mem_passes_done, bench.mem_write_gbs, bench.mem_read_gbs,
                }) catch "";
                widgets.drawKeyValueLine("内存实测成绩", s1);
            },
            .disk_bench => {
                var b1: [128]u8 = undefined;
                const s1 = std.fmt.bufPrint(&b1, "SEQ1M 写入 {d:.1} MB/s  •  SEQ1M 读取 {d:.1} MB/s", .{ bench.disk_seq_write_mbs, bench.disk_seq_read_mbs }) catch "";
                widgets.drawKeyValueLine("顺序吞吐", s1);
                var b2: [128]u8 = undefined;
                const s2 = std.fmt.bufPrint(&b2, "RND4K 读取 {d:.1} MB/s  •  {d:.0} IOPS  •  平均延迟 {d:.1} us", .{
                    bench.disk_rnd4k_read_mbs, bench.disk_rnd4k_read_iops, bench.disk_rnd4k_avg_lat_us,
                }) catch "";
                widgets.drawKeyValueLine("4K 随机读", s2);
            },
            .gpu_stress => {
                var b1: [96]u8 = undefined;
                const s1 = std.fmt.bufPrint(&b1, "累计帧数 {d}  •  平均帧率 {d:.1} FPS", .{ bench.gpu_frames, bench.gpu_avg_fps }) catch "";
                widgets.drawKeyValueLine("GPU 渲染统计", s1);
            },
            .none => {
                zgui.textColored(p.text_muted, "请在左侧选择测试项开始准确的硬件稳定性与性能验证。", .{});
            },
        }

        if (bench.summary_len > 0) {
            zgui.dummy(.{ .w = 0, .h = 6.0 * s });
            widgets.drawKeyValueLine("运行说明", bench.summarySlice());
        }

        // GPU 烤机活跃时绘制高密度动态几何渲染压力预览区
        if (bench.active_kind == .gpu_stress and bench.outcome == .running) {
            zgui.dummy(.{ .w = 0, .h = 10.0 * s });
            const dl = zgui.getWindowDrawList();
            const pos = zgui.getCursorScreenPos();
            const cw = zgui.getContentRegionAvail()[0];
            const ch = @max(140.0 * s, zgui.getContentRegionAvail()[1] - 8.0 * s);
            dl.addRectFilled(.{ .pmin = pos, .pmax = .{ pos[0] + cw, pos[1] + ch }, .col = theme.colorU32(p.canvas_bg), .rounding = 8.0 });
            const cx = pos[0] + cw * 0.5;
            const cy = pos[1] + ch * 0.5;
            const max_r = @min(cw, ch) * 0.44;
            const phase: f32 = @floatCast(@mod(bench.elapsed_s * 2.4, std.math.pi * 2.0));
            // 180 层抗锯齿同心旋转多边形几何光栅负载
            var k: usize = 0;
            while (k < 180) : (k += 1) {
                const fk: f32 = @floatFromInt(k);
                const r = max_r * (0.15 + 0.85 * (fk / 180.0));
                const a0 = phase + fk * 0.17;
                const x1 = cx + @cos(a0) * r;
                const y1 = cy + @sin(a0) * r;
                const x2 = cx + @cos(a0 + 2.094) * r;
                const y2 = cy + @sin(a0 + 2.094) * r;
                const x3 = cx + @cos(a0 + 4.188) * r;
                const y3 = cy + @sin(a0 + 4.188) * r;
                const col = [4]f32{
                    0.2 + 0.7 * (@sin(fk * 0.05 + phase) * 0.5 + 0.5),
                    0.5 + 0.4 * (@cos(fk * 0.04 + phase) * 0.5 + 0.5),
                    0.95,
                    0.35,
                };
                dl.addTriangle(.{ .p1 = .{ x1, y1 }, .p2 = .{ x2, y2 }, .p3 = .{ x3, y3 }, .col = theme.colorU32(col), .thickness = 1.5 });
            }
            zgui.dummy(.{ .w = cw, .h = ch });
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

    if (widgets.beginCard("##hist_db_status", "本地历史数据库与分级降采样状态", "SQLite WAL 模式 • 1 分钟聚合保留 7 天 • 15 分钟聚合保留 30 天 • 告警 SMART 永久保留", -1.0, top_h, s, null)) {
        widgets.drawStatusPill(
            if (tel.db_active) "SQLite 持久化运行中" else "内存模式（smoke-test）",
            if (tel.db_active) p.status_ok else p.accent_cyan,
            s,
        );
        zgui.sameLine(.{});
        zgui.textColored(p.text_secondary, "已完成批量事务写入：{d} 次", .{tel.db_flush_count});
        widgets.drawKeyValueLine("数据库路径", state.db_path);
        if (tel.db_recovered) {
            zgui.textColored(p.status_caution, "提示：检测到旧数据库文件损坏，已自动备份并重建新库，GUI 正常运行。", .{});
        }
    }
    widgets.endCard();

    zgui.dummy(.{ .w = 0, .h = gap });

    if (widgets.beginCard("##hist_gpu_temp", "GPU 温度历史趋势", "实时环形缓冲区 + 每分钟自动落盘聚合", half_w, bot_h, s, &state.time_range)) {
        const inner_h = @max(170.0 * s, zgui.getContentRegionAvail()[1] - 4.0 * s);
        widgets.drawLiveAreaPlot(monitoring.HISTORY_CAPACITY, "##hist_gpu_plot", "GPU °C", "°C", 20, 100, "°C", p.status_ok, &tel.gpu_temp_history, "等待 GPU 温度数据...", inner_h, s);
    }
    widgets.endCard();

    zgui.sameLine(.{ .spacing = gap });

    if (widgets.beginCard("##hist_disk_temp", "主磁盘温度历史趋势", "无唤醒存储温度描述符 / NVMe 综合温度", half_w, bot_h, s, &state.time_range)) {
        const inner_h = @max(170.0 * s, zgui.getContentRegionAvail()[1] - 4.0 * s);
        widgets.drawLiveAreaPlot(monitoring.HISTORY_CAPACITY, "##hist_disk_plot", "Disk °C", "°C", 20, 90, "°C", p.accent_purple, &tel.disk0_temp_history, "等待磁盘温度数据...", inner_h, s);
    }
    widgets.endCard();
}

fn renderAlertsView(state: *AppState, tel: *const SharedTelemetry) void {
    const s = state.dpi_scale;
    const p = theme.active();
    const avail_h = @max(320.0 * s, zgui.getContentRegionAvail()[1]);

    if (widgets.beginCard("##alerts_card", "告警中心与规则溯源", "持续时间防抖 30s • 温度回差恢复 5°C • 同规则 30 分钟抑制 • 磁盘规则严格对应 §2.5.5", -1.0, avail_h, s, null)) {
        widgets.drawStatusPill(
            if (tel.active_alert_count == 0) "当前无活动告警" else "存在活动告警，请及时检查",
            if (tel.active_alert_count == 0) p.status_ok else p.status_critical,
            s,
        );
        if (tel.alert_history_count > 0) {
            zgui.sameLine(.{ .spacing = 16.0 * s });
            if (zgui.button("全部标记已确认", .{})) {
                state.request_ack_alerts = true;
            }
        }
        zgui.dummy(.{ .w = 0, .h = 10.0 * s });

        if (tel.alert_history_count == 0) {
            zgui.textColored(p.text_secondary, "暂无历史告警记录。所有温度与 SMART 健康指标均在安全范围内。", .{});
        } else {
            if (zgui.beginTable("##alerts_table", .{
                .column = 5,
                .flags = .{ .borders = .{ .inner_h = true }, .row_bg = true, .sizing = .stretch_prop, .scroll_y = true },
            })) {
                zgui.tableSetupColumn("级别", .{});
                zgui.tableSetupColumn("规则 ID", .{});
                zgui.tableSetupColumn("设备 ID", .{});
                zgui.tableSetupColumn("触发原因与证据", .{ .init_width_or_height = 2.0 });
                zgui.tableSetupColumn("状态", .{});
                zgui.tableHeadersRow();

                for (tel.alert_history[0..tel.alert_history_count]) |ev| {
                    zgui.tableNextRow(.{});
                    _ = zgui.tableNextColumn();
                    widgets.drawStatusPill(
                        if (ev.is_recovery) "已恢复" else ev.level.labelZh(),
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
                    zgui.textColored(p.text_muted, "{s}", .{if (ev.acknowledged) "已确认" else "未确认"});
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

    if (widgets.beginCard("##settings_behavior", "外观、窗口、扩展与采集设置", "修改后点击“保存配置”持久化至 settings.toml", col_w, full_h, s, null)) {
        zgui.textColored(p.text_secondary, "界面颜色主题（实时生效）：", .{});
        if (zgui.radioButton("深色主题 (黑)", .{ .active = state.theme_mode == .dark })) {
            state.theme_mode = .dark;
        }
        zgui.sameLine(.{});
        if (zgui.radioButton("浅色主题 (白)", .{ .active = state.theme_mode == .light })) {
            state.theme_mode = .light;
        }

        zgui.dummy(.{ .w = 0, .h = 6.0 * s });
        zgui.textColored(p.text_secondary, "关闭窗口按钮行为：", .{});
        if (zgui.radioButton("最小化到系统托盘（默认）", .{ .active = state.close_behavior == .minimize_to_tray })) {
            state.close_behavior = .minimize_to_tray;
        }
        if (zgui.radioButton("直接退出程序", .{ .active = state.close_behavior == .exit_app })) {
            state.close_behavior = .exit_app;
        }

        zgui.dummy(.{ .w = 0, .h = 6.0 * s });
        zgui.textColored(p.text_secondary, "最小化按钮行为：", .{});
        if (zgui.radioButton("最小化到任务栏（默认）", .{ .active = state.minimize_behavior == .minimize_to_taskbar })) {
            state.minimize_behavior = .minimize_to_taskbar;
        }
        if (zgui.radioButton("最小化到系统托盘", .{ .active = state.minimize_behavior == .minimize_to_tray })) {
            state.minimize_behavior = .minimize_to_tray;
        }

        zgui.dummy(.{ .w = 0, .h = 6.0 * s });
        zgui.textColored(p.text_secondary, "温度显示单位：", .{});
        if (zgui.radioButton("摄氏度 (°C)", .{ .active = state.temp_unit == .celsius })) {
            state.temp_unit = .celsius;
        }
        zgui.sameLine(.{});
        if (zgui.radioButton("华氏度 (°F)", .{ .active = state.temp_unit == .fahrenheit })) {
            state.temp_unit = .fahrenheit;
        }

        zgui.dummy(.{ .w = 0, .h = 6.0 * s });
        var sys_ms: i32 = @intCast(state.system_interval_ms);
        if (zgui.sliderInt("系统采集间隔 (ms)", .{ .v = &sys_ms, .min = 500, .max = 10000 })) {
            state.system_interval_ms = @intCast(sys_ms);
        }
        var smart_s: i32 = @intCast(state.smart_interval_ms / 1000);
        if (zgui.sliderInt("SMART 采集间隔 (秒，≥30)", .{ .v = &smart_s, .min = 30, .max = 600 })) {
            state.smart_interval_ms = @intCast(smart_s * 1000);
        }

        zgui.dummy(.{ .w = 0, .h = 6.0 * s });
        _ = zgui.checkbox("开机自动启动（当前用户 HKCU\\Run）", .{ .v = &state.start_with_windows });
        _ = zgui.checkbox("暂停后台采集", .{ .v = &state.monitoring_paused });
        _ = zgui.checkbox("允许唤醒休眠中的机械硬盘（默认关闭）", .{ .v = &state.allow_wake_standby_disk });
        _ = zgui.checkbox("启用可选 LHM 扩展组件通信（默认关闭）", .{ .v = &state.extension_enabled });

        zgui.dummy(.{ .w = 0, .h = 8.0 * s });
        zgui.pushStyleColor4f(.{ .idx = .button, .c = p.accent_blue_soft });
        zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = p.accent_blue_hover });
        zgui.pushStyleColor4f(.{ .idx = .text, .c = p.accent_blue });
        if (zgui.button("保存配置", .{ .w = 100.0 * s, .h = 30.0 * s })) {
            state.request_save_config = true;
        }
        zgui.popStyleColor(.{ .count = 3 });
        zgui.sameLine(.{});
        if (zgui.button("恢复默认", .{ .w = 96.0 * s, .h = 30.0 * s })) {
            state.request_reset_config = true;
        }
        zgui.sameLine(.{});
        if (zgui.button("导出配置", .{ .w = 96.0 * s, .h = 30.0 * s })) {
            state.request_export_config = true;
        }
        zgui.sameLine(.{});
        if (zgui.button("导入配置", .{ .w = 96.0 * s, .h = 30.0 * s })) {
            state.request_import_config = true;
        }
        if (state.config_save_msg.len > 0) {
            zgui.dummy(.{ .w = 0, .h = 4.0 * s });
            zgui.textColored(p.status_ok, "{s}", .{state.config_save_msg});
        }
    }
    widgets.endCard();

    zgui.sameLine(.{ .spacing = gap });

    if (widgets.beginCard("##settings_diag", "运行时、扩展组件与诊断", "全部为当前进程实时检测值", col_w, full_h, s, null)) {
        widgets.drawKeyValueLine("运行权限", if (state.is_admin) "管理员 (Administrator)" else "普通用户 (Standard User)");
        widgets.drawKeyValueLine("当前主题", state.theme_mode.labelZh());
        widgets.drawKeyValueLine("部署模式", if (state.is_portable) "便携模式 (portable.flag)" else "安装模式 (%LOCALAPPDATA%)");
        widgets.drawKeyValueLine("配置文件", if (state.config_path.len > 0) state.config_path else "N/A");
        widgets.drawKeyValueLine("数据库路径", if (state.db_path.len > 0) state.db_path else "N/A");
        widgets.drawKeyValueLine("系统托盘", if (state.tray_available) "已挂载" else "当前会话未挂载 Shell_TrayWnd（自动降级）");
        widgets.drawKeyValueLine("当前字体", state.font_source);

        var lhm_buf: [96]u8 = undefined;
        const lhm_txt = if (tel.extension.connected)
            std.fmt.bufPrint(&lhm_buf, "已连接（{d} 个传感器，{s}）", .{
                tel.extension.sensor_count,
                if (tel.extension.helper_is_admin) "管理员" else "普通权限",
            }) catch "已连接"
        else if (state.extension_enabled)
            "已开启但未连接（请点击下方启动辅助进程）"
        else
            "已关闭（默认零驱动模式）";
        widgets.drawKeyValueLine("扩展辅助进程", lhm_txt);

        var dpi_buf: [64]u8 = undefined;
        const dpi_txt = std.fmt.bufPrint(&dpi_buf, "{d:.2}x  •  {s}", .{ state.dpi_scale, state.render_mode.labelZh() }) catch "";
        widgets.drawKeyValueLine("DPI 与渲染", dpi_txt);

        var frm_buf: [96]u8 = undefined;
        const frm_txt = std.fmt.bufPrint(&frm_buf, "已渲染 {d} 帧  •  节能跳过 {d} 帧  •  热插拔 {d}  •  电源恢复 {d}", .{
            state.rendered_frames,
            state.skipped_frames,
            state.device_change_events,
            state.power_resume_events,
        }) catch "";
        widgets.drawKeyValueLine("运行统计", frm_txt);
        widgets.drawKeyValueLine("开源许可", "主程序 Apache-2.0  •  可选扩展组件边界 MPL-2.0");

        zgui.dummy(.{ .w = 0, .h = 10.0 * s });
        if (zgui.button("启动 LHM 辅助进程 (需管理员)", .{ .w = 210.0 * s, .h = 30.0 * s })) {
            state.request_launch_lhm_helper = true;
        }
        zgui.sameLine(.{});
        if (zgui.button("停止辅助进程", .{ .w = 110.0 * s, .h = 30.0 * s })) {
            state.request_stop_lhm_helper = true;
        }
        if (state.lhm_action_msg.len > 0) {
            zgui.dummy(.{ .w = 0, .h = 4.0 * s });
            zgui.textColored(p.accent_blue, "{s}", .{state.lhm_action_msg});
        }

        zgui.dummy(.{ .w = 0, .h = 10.0 * s });
        if (zgui.button("导出脱敏诊断报告", .{ .w = 165.0 * s, .h = 30.0 * s })) {
            state.request_export_diag = true;
        }
        zgui.sameLine(.{});
        if (zgui.button("安全退出程序", .{ .w = 135.0 * s, .h = 30.0 * s })) {
            state.should_exit = true;
        }
        if (state.diag_export_msg.len > 0) {
            zgui.dummy(.{ .w = 0, .h = 4.0 * s });
            zgui.textColored(p.status_ok, "{s}", .{state.diag_export_msg});
        }
    }
    widgets.endCard();
}
