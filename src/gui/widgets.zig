const std = @import("std");
const zgui = @import("zgui");
const theme = @import("theme.zig");
const state_mod = @import("../app/state.zig");
const sensor = @import("../core/sensor.zig");
const telemetry = @import("../core/telemetry.zig");
const i18n = @import("../core/i18n.zig");

/// 圆角 Bento 卡片容器（支持深色/浅色双主题；允许在内容超出时自动滚动，绝不静默裁切文字）
pub fn beginCard(
    id: [:0]const u8,
    title: [:0]const u8,
    subtitle: ?[:0]const u8,
    width: f32,
    height: f32,
    dpi_scale: f32,
    time_range: ?*state_mod.TimeRange,
) bool {
    const p = theme.active();
    zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = .{ 16.0 * dpi_scale, 13.0 * dpi_scale } });
    const open = zgui.beginChild(id, .{
        .w = width,
        .h = height,
        .child_flags = .{ .border = true, .always_use_window_padding = true },
    });
    zgui.popStyleVar(.{ .count = 1 });

    if (open) {
        const start_y = zgui.getCursorPosY();
        zgui.pushFont(null, 17.0 * dpi_scale);
        zgui.textColored(p.text_primary, "{s}", .{title});
        zgui.popFont();

        if (time_range) |tr| {
            const pill_w = 152.0 * dpi_scale;
            const avail_w = zgui.getContentRegionAvail()[0];
            if (avail_w > pill_w + 110.0 * dpi_scale) {
                zgui.sameLine(.{});
                zgui.setCursorPosX(zgui.getCursorPosX() + zgui.getContentRegionAvail()[0] - pill_w);
                zgui.setCursorPosY(start_y - 2.0 * dpi_scale);
                drawTimeRangePills(tr, dpi_scale);
            }
        }

        if (subtitle) |sub| {
            zgui.pushFont(null, 13.0 * dpi_scale);
            zgui.pushStyleColor4f(.{ .idx = .text, .c = p.text_muted });
            zgui.textWrapped("{s}", .{sub});
            zgui.popStyleColor(.{ .count = 1 });
            zgui.popFont();
        }
        zgui.dummy(.{ .w = 0, .h = 4.0 * dpi_scale });
    }
    return open;
}

pub fn endCard() void {
    zgui.endChild();
}

pub fn drawTimeRangePills(selected: *state_mod.TimeRange, dpi_scale: f32) void {
    const p = theme.active();
    const ranges = [_]state_mod.TimeRange{ .hour_1, .hour_24, .day_7, .day_30 };
    zgui.pushStyleVar2f(.{ .idx = .item_spacing, .v = .{ 3.0 * dpi_scale, 0 } });
    zgui.pushStyleVar2f(.{ .idx = .frame_padding, .v = .{ 7.0 * dpi_scale, 3.0 * dpi_scale } });
    zgui.pushFont(null, 12.0 * dpi_scale);

    for (ranges, 0..) |r, idx| {
        if (idx > 0) zgui.sameLine(.{});
        const is_sel = selected.* == r;
        zgui.pushStyleColor4f(.{ .idx = .button, .c = if (is_sel) p.accent_blue_soft else p.card_elevated });
        zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = if (is_sel) p.accent_blue_hover else p.btn_hover });
        zgui.pushStyleColor4f(.{ .idx = .text, .c = if (is_sel) p.accent_blue else p.text_muted });
        if (zgui.button(r.label(), .{})) {
            selected.* = r;
        }
        zgui.popStyleColor(.{ .count = 3 });
    }

    zgui.popFont();
    zgui.popStyleVar(.{ .count = 2 });
}

/// 彩色 + 中文文字状态胶囊（规范 §7：禁止只依赖颜色）
pub fn drawStatusPill(label: [:0]const u8, color: [4]f32, dpi_scale: f32) void {
    const dl = zgui.getWindowDrawList();
    const pos = zgui.getCursorScreenPos();
    const fs = 12.5 * dpi_scale;
    zgui.pushFont(null, fs);
    const text_sz = zgui.calcTextSize(label, .{});
    const pad_x = 9.0 * dpi_scale;
    const pad_y = 3.0 * dpi_scale;
    const dot_r = 3.5 * dpi_scale;
    const dot_gap = 6.0 * dpi_scale;
    const total_w = pad_x * 2.0 + dot_r * 2.0 + dot_gap + text_sz[0];
    const total_h = text_sz[1] + pad_y * 2.0;

    const bg_col = [4]f32{ color[0], color[1], color[2], 0.14 };
    const border_col = [4]f32{ color[0], color[1], color[2], 0.38 };
    dl.addRectFilled(.{
        .pmin = pos,
        .pmax = .{ pos[0] + total_w, pos[1] + total_h },
        .col = theme.colorU32(bg_col),
        .rounding = total_h * 0.5,
    });
    dl.addRect(.{
        .pmin = pos,
        .pmax = .{ pos[0] + total_w, pos[1] + total_h },
        .col = theme.colorU32(border_col),
        .rounding = total_h * 0.5,
        .thickness = 1.0,
    });
    dl.addCircleFilled(.{
        .p = .{ pos[0] + pad_x + dot_r, pos[1] + total_h * 0.5 },
        .r = dot_r,
        .col = theme.colorU32(color),
    });

    dl.addTextExtendedUnformatted(
        .{ pos[0] + pad_x + dot_r * 2.0 + dot_gap, pos[1] + pad_y },
        theme.colorU32(color),
        label,
        .{ .font = null, .font_size = fs },
    );
    zgui.popFont();
    zgui.dummy(.{ .w = total_w, .h = total_h });
}

/// Grafana 风格 240° 抗锯齿圆弧仪表
pub fn drawArcGauge(
    value_fraction: ?f32,
    value_text: [:0]const u8,
    caption: [:0]const u8,
    accent_color: [4]f32,
    height: f32,
    dpi_scale: f32,
) void {
    const p = theme.active();
    const dl = zgui.getWindowDrawList();
    const avail = zgui.getContentRegionAvail();
    const pos = zgui.getCursorScreenPos();
    const w = avail[0];
    const h = @max(130.0 * dpi_scale, height);
    const cx = pos[0] + w * 0.5;
    const cy = pos[1] + h * 0.52;
    const radius = @min(w * 0.34, h * 0.40);
    const thickness = @max(10.0 * dpi_scale, radius * 0.21);

    const pi: f32 = std.math.pi;
    const start_a: f32 = pi * 0.78;
    const end_a: f32 = pi * 2.22;
    const span: f32 = end_a - start_a;

    const outer_r = radius + thickness * 0.62;
    const seg1 = start_a + span * 0.65;
    const seg2 = start_a + span * 0.85;
    drawArcSegment(dl, .{ cx, cy }, outer_r, start_a, seg1, theme.colorU32(p.status_ok), 2.5 * dpi_scale);
    drawArcSegment(dl, .{ cx, cy }, outer_r, seg1, seg2, theme.colorU32(p.status_caution), 2.5 * dpi_scale);
    drawArcSegment(dl, .{ cx, cy }, outer_r, seg2, end_a, theme.colorU32(p.status_critical), 2.5 * dpi_scale);

    drawArcSegment(dl, .{ cx, cy }, radius, start_a, end_a, theme.colorU32(p.gauge_track), thickness);

    if (value_fraction) |frac| {
        const clamped = std.math.clamp(frac, 0.0, 1.0);
        if (clamped > 0.001) {
            drawArcSegment(dl, .{ cx, cy }, radius, start_a, start_a + span * clamped, theme.colorU32(accent_color), thickness);
        }
    }

    const big_fs = 26.0 * dpi_scale;
    zgui.pushFont(null, big_fs);
    const val_sz = zgui.calcTextSize(value_text, .{});
    const val_col = if (value_fraction != null) accent_color else p.text_muted;
    dl.addTextExtendedUnformatted(
        .{ cx - val_sz[0] * 0.5, cy - val_sz[1] * 0.52 },
        theme.colorU32(val_col),
        value_text,
        .{ .font = null, .font_size = big_fs },
    );
    zgui.popFont();

    const cap_fs = 12.5 * dpi_scale;
    zgui.pushFont(null, cap_fs);
    const cap_sz = zgui.calcTextSize(caption, .{});
    dl.addTextExtendedUnformatted(
        .{ cx - cap_sz[0] * 0.5, cy + radius * 0.56 },
        theme.colorU32(p.text_secondary),
        caption,
        .{ .font = null, .font_size = cap_fs },
    );
    zgui.popFont();

    zgui.dummy(.{ .w = w, .h = h });
}

/// Bento 风格 360° 环形仪表
pub fn drawDonutGauge(
    value_fraction: ?f32,
    center_big: [:0]const u8,
    center_sub: [:0]const u8,
    footer_line: [:0]const u8,
    accent_color: [4]f32,
    height: f32,
    dpi_scale: f32,
) void {
    const p = theme.active();
    const dl = zgui.getWindowDrawList();
    const avail = zgui.getContentRegionAvail();
    const pos = zgui.getCursorScreenPos();
    const w = avail[0];
    const h = @max(130.0 * dpi_scale, height);
    const cx = pos[0] + w * 0.5;
    const cy = pos[1] + h * 0.44;
    const radius = @min(w * 0.30, h * 0.33);
    const thickness = @max(9.0 * dpi_scale, radius * 0.19);
    const pi: f32 = std.math.pi;

    drawArcSegment(dl, .{ cx, cy }, radius, 0.0, pi * 2.0, theme.colorU32(p.gauge_track), thickness);

    if (value_fraction) |frac| {
        const clamped = std.math.clamp(frac, 0.0, 1.0);
        if (clamped > 0.001) {
            const a0 = -pi * 0.5;
            drawArcSegment(dl, .{ cx, cy }, radius, a0, a0 + pi * 2.0 * clamped, theme.colorU32(accent_color), thickness);
        }
    }

    const big_fs = 24.0 * dpi_scale;
    zgui.pushFont(null, big_fs);
    const big_sz = zgui.calcTextSize(center_big, .{});
    dl.addTextExtendedUnformatted(
        .{ cx - big_sz[0] * 0.5, cy - big_sz[1] * 0.72 },
        theme.colorU32(if (value_fraction != null) p.text_primary else p.text_muted),
        center_big,
        .{ .font = null, .font_size = big_fs },
    );
    zgui.popFont();

    const sub_fs = 12.5 * dpi_scale;
    zgui.pushFont(null, sub_fs);
    const sub_sz = zgui.calcTextSize(center_sub, .{});
    dl.addTextExtendedUnformatted(
        .{ cx - sub_sz[0] * 0.5, cy + 4.0 * dpi_scale },
        theme.colorU32(p.text_muted),
        center_sub,
        .{ .font = null, .font_size = sub_fs },
    );

    const ft_sz = zgui.calcTextSize(footer_line, .{});
    dl.addTextExtendedUnformatted(
        .{ cx - ft_sz[0] * 0.5, pos[1] + h - ft_sz[1] - 4.0 * dpi_scale },
        theme.colorU32(p.text_secondary),
        footer_line,
        .{ .font = null, .font_size = sub_fs },
    );
    zgui.popFont();

    zgui.dummy(.{ .w = w, .h = h });
}

fn drawArcSegment(dl: zgui.DrawList, center: [2]f32, radius: f32, a_min: f32, a_max: f32, col: u32, thickness: f32) void {
    dl.pathClear();
    dl.pathArcTo(.{
        .p = center,
        .r = radius,
        .amin = a_min,
        .amax = a_max,
        .num_segments = 48,
    });
    dl.pathStroke(.{ .col = col, .thickness = thickness });
}

/// 诚实空态 ImPlot 趋势图容器
pub fn drawEmptyTrendPlot(
    plot_id: [:0]const u8,
    y_label: [:0]const u8,
    y_min: f64,
    y_max: f64,
    empty_reason: [:0]const u8,
    height: f32,
    dpi_scale: f32,
) void {
    const p = theme.active();
    const h = @max(110.0 * dpi_scale, height);
    zgui.plot.pushStyleColor4f(.{ .idx = .frame_bg, .c = .{ 0, 0, 0, 0 } });
    zgui.plot.pushStyleColor4f(.{ .idx = .plot_bg, .c = p.canvas_bg });
    zgui.plot.pushStyleColor4f(.{ .idx = .plot_border, .c = p.divider });
    zgui.plot.pushStyleColor4f(.{ .idx = .inlay_text, .c = p.text_secondary });
    defer zgui.plot.popStyleColor(.{ .count = 4 });

    const dl = zgui.getWindowDrawList();
    const pos = zgui.getCursorScreenPos();
    const avail_w = zgui.getContentRegionAvail()[0];

    if (zgui.plot.beginPlot(plot_id, .{
        .w = -1.0,
        .h = h,
        .flags = .{ .no_title = true, .no_legend = true, .no_mouse_text = true, .no_inputs = true },
    })) {
        zgui.plot.setupAxis(.x1, .{ .flags = .{ .no_tick_labels = true } });
        zgui.plot.setupAxis(.y1, .{ .label = y_label });
        zgui.plot.setupAxisLimits(.x1, .{ .min = 0, .max = 60, .cond = .always });
        zgui.plot.setupAxisLimits(.y1, .{ .min = y_min, .max = y_max, .cond = .always });
        zgui.plot.endPlot();
    }

    const fs = 13.5 * dpi_scale;
    zgui.pushFont(null, fs);
    const sz = zgui.calcTextSize(empty_reason, .{});
    dl.addTextExtendedUnformatted(
        .{ pos[0] + (avail_w - sz[0]) * 0.5, pos[1] + (h - sz[1]) * 0.5 },
        theme.colorU32(p.text_muted),
        empty_reason,
        .{ .font = null, .font_size = fs },
    );
    zgui.popFont();
}

/// 实时 ImPlot 面积折线图（双主题自适应）
pub fn drawLiveAreaPlot(
    comptime cap: usize,
    plot_id: [:0]const u8,
    series_label: [:0]const u8,
    y_label: [:0]const u8,
    y_min: f64,
    y_max: f64,
    unit_suffix: [:0]const u8,
    line_color: [4]f32,
    rb: *const telemetry.RingBuffer(cap),
    empty_reason: [:0]const u8,
    height: f32,
    dpi_scale: f32,
) void {
    const p = theme.active();
    const plot_h = @max(100.0 * dpi_scale, height - 26.0 * dpi_scale);
    if (rb.len == 0) {
        drawEmptyTrendPlot(plot_id, y_label, y_min, y_max, empty_reason, plot_h, dpi_scale);
        return;
    }

    // 低占用优化：60 秒视窗仅需最新 256 个采样点（500ms 采样下亦涵盖 128 秒），减少 7 倍栈拷贝与 ImPlot 顶点提交
    const PLOT_WINDOW_CAP = @min(cap, 256);
    var xs: [PLOT_WINDOW_CAP]f64 = undefined;
    var ys: [PLOT_WINDOW_CAP]f64 = undefined;
    const n = rb.copyOrdered(&xs, &ys);
    const st = rb.stats();

    const x_end = xs[n - 1];
    const x_start = if (x_end > 60.0) x_end - 60.0 else 0.0;
    const x_max = @max(x_end, 60.0);

    zgui.plot.pushStyleColor4f(.{ .idx = .frame_bg, .c = .{ 0, 0, 0, 0 } });
    zgui.plot.pushStyleColor4f(.{ .idx = .plot_bg, .c = p.canvas_bg });
    zgui.plot.pushStyleColor4f(.{ .idx = .plot_border, .c = p.divider });
    zgui.plot.pushStyleColor4f(.{ .idx = .line, .c = line_color });
    zgui.plot.pushStyleColor4f(.{ .idx = .fill, .c = .{ line_color[0], line_color[1], line_color[2], 0.20 } });
    defer zgui.plot.popStyleColor(.{ .count = 5 });

    zgui.plot.pushStyleVar1f(.{ .idx = .line_weight, .v = 2.0 * dpi_scale });
    defer zgui.plot.popStyleVar(.{ .count = 1 });

    if (zgui.plot.beginPlot(plot_id, .{
        .w = -1.0,
        .h = plot_h,
        .flags = .{ .no_title = true, .no_legend = true, .no_mouse_text = true },
    })) {
        zgui.plot.setupAxis(.x1, .{ .flags = .{ .no_tick_labels = true } });
        zgui.plot.setupAxis(.y1, .{ .label = y_label });
        zgui.plot.setupAxisLimits(.x1, .{ .min = x_start, .max = x_max, .cond = .always });
        zgui.plot.setupAxisLimits(.y1, .{ .min = y_min, .max = y_max, .cond = .always });

        zgui.plot.plotShaded(series_label, f64, .{
            .xv = xs[0..n],
            .yv = ys[0..n],
            .yref = y_min,
        });
        zgui.plot.plotLine(series_label, f64, .{
            .xv = xs[0..n],
            .yv = ys[0..n],
        });
        zgui.plot.endPlot();
    }

    zgui.pushFont(null, 12.5 * dpi_scale);
    zgui.textColored(p.text_muted, "{s}: ", .{i18n.tr("当前", "Cur", "現在")});
    zgui.sameLine(.{ .spacing = 2.0 });
    zgui.textColored(line_color, "{d:.1}{s}", .{ st.current, unit_suffix });
    zgui.sameLine(.{ .spacing = 12.0 * dpi_scale });
    zgui.textColored(p.text_muted, "{s}: ", .{i18n.tr("平均", "Avg", "平均")});
    zgui.sameLine(.{ .spacing = 2.0 });
    zgui.textColored(p.text_secondary, "{d:.1}{s}", .{ st.avg, unit_suffix });
    zgui.sameLine(.{ .spacing = 12.0 * dpi_scale });
    zgui.textColored(p.text_muted, "{s}: ", .{i18n.tr("峰值", "Max", "最大")});
    zgui.sameLine(.{ .spacing = 2.0 });
    zgui.textColored(p.text_secondary, "{d:.1}{s}", .{ st.max, unit_suffix });
    zgui.sameLine(.{ .spacing = 12.0 * dpi_scale });
    zgui.textColored(p.text_muted, "{s}: {d}", .{ i18n.tr("样本", "Samples", "サンプル"), st.count });
    zgui.popFont();
}

/// 表格内传感器状态行（3 列清晰对齐，不裁切文字）
pub fn drawMetricTableRow(
    label: [:0]const u8,
    value_text: [:0]const u8,
    status: sensor.SensorStatus,
    reason_override: ?[:0]const u8,
    dpi_scale: f32,
) void {
    const p = theme.active();
    zgui.tableNextRow(.{});
    _ = zgui.tableNextColumn();
    zgui.textColored(p.text_secondary, "{s}", .{label});
    _ = zgui.tableNextColumn();
    zgui.textColored(if (status == .ok) p.text_primary else p.text_muted, "{s}", .{value_text});
    _ = zgui.tableNextColumn();
    const badge_text = reason_override orelse status.labelZh();
    drawStatusPill(badge_text, p.sensorStatusColor(status), dpi_scale);
}

/// 结构化键值信息小块（自动换行，保证 100% 完整展示不截断）
pub fn drawKeyValueLine(label: [:0]const u8, value: []const u8) void {
    const p = theme.active();
    zgui.textColored(p.text_muted, "{s}: ", .{label});
    zgui.sameLine(.{ .spacing = 2.0 });
    zgui.textWrapped("{s}", .{value});
}
