const std = @import("std");
const zgui = @import("zgui");
const state_mod = @import("../app/state.zig");
const AppState = state_mod.AppState;
const Page = state_mod.Page;
const theme = @import("theme.zig");
const widgets = @import("widgets.zig");

/// 左侧导航栏（支持深色/浅色一键切换、底部状态自适应不裁切）
pub fn renderSidebar(state: *AppState, height: f32) void {
    const s = state.dpi_scale;
    const p = theme.active();
    const sidebar_w = 220.0 * s;

    zgui.pushStyleColor4f(.{ .idx = .child_bg, .c = p.sidebar_bg });
    zgui.pushStyleColor4f(.{ .idx = .border, .c = p.divider });
    zgui.pushStyleVar1f(.{ .idx = .child_rounding, .v = 0.0 });
    zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = .{ 12.0 * s, 14.0 * s } });
    defer {
        zgui.popStyleVar(.{ .count = 2 });
        zgui.popStyleColor(.{ .count = 2 });
    }

    if (zgui.beginChild("##sidebar", .{
        .w = sidebar_w,
        .h = height,
        .child_flags = .{ .border = true, .always_use_window_padding = true },
    })) {
        zgui.pushFont(null, 17.5 * s);
        zgui.textColored(p.text_primary, "WinHardware", .{});
        zgui.popFont();
        zgui.pushFont(null, 12.0 * s);
        zgui.textColored(p.text_muted, "硬件温度与磁盘健康监控", .{});
        zgui.popFont();

        zgui.dummy(.{ .w = 0, .h = 8.0 * s });
        zgui.separator();
        zgui.dummy(.{ .w = 0, .h = 6.0 * s });

        const pages = [_]Page{
            .dashboard,
            .cpu,
            .gpu,
            .memory,
            .motherboard,
            .disks,
            .sensors,
            .stress_test,
            .history,
            .alerts,
            .settings,
        };

        for (pages) |page| {
            if (page == .sensors or page == .history) {
                zgui.dummy(.{ .w = 0, .h = 3.0 * s });
                zgui.separator();
                zgui.dummy(.{ .w = 0, .h = 3.0 * s });
            }
            renderNavItem(state, page);
        }

        // 底部状态区（根据剩余空间弹性贴底，空间不足时自然跟排可滚动，绝不裁切）
        const bottom_h = (if (state.is_admin) @as(f32, 162.0) else @as(f32, 198.0)) * s;
        const avail_y = zgui.getContentRegionAvail()[1];
        if (avail_y > bottom_h + 8.0 * s) {
            zgui.dummy(.{ .w = 0, .h = avail_y - bottom_h });
        } else {
            zgui.dummy(.{ .w = 0, .h = 10.0 * s });
        }

        zgui.separator();
        zgui.dummy(.{ .w = 0, .h = 8.0 * s });

        // 一键切换深色 / 浅色（黑白）主题并立即持久化
        const toggle_lbl: [:0]const u8 = if (state.theme_mode == .dark) "切换浅色主题 (白)" else "切换深色主题 (黑)";
        if (zgui.button(toggle_lbl, .{ .w = -1.0, .h = 28.0 * s })) {
            state.theme_mode = if (state.theme_mode == .dark) .light else .dark;
            state.request_save_config = true;
        }

        zgui.dummy(.{ .w = 0, .h = 6.0 * s });
        widgets.drawStatusPill(
            if (state.is_admin) "管理员模式" else "普通用户模式",
            if (state.is_admin) p.status_ok else p.status_caution,
            s,
        );

        zgui.dummy(.{ .w = 0, .h = 4.0 * s });
        zgui.pushFont(null, 12.0 * s);
        zgui.textWrapped("渲染: {s}", .{state.render_mode.labelZh()});
        zgui.textColored(p.text_muted, "采集: {s} | 扩展: {s}", .{
            if (state.monitoring_paused) "暂停" else "运行",
            if (state.extension_enabled) "开" else "关",
        });
        zgui.popFont();

        if (!state.is_admin) {
            zgui.dummy(.{ .w = 0, .h = 6.0 * s });
            zgui.pushStyleColor4f(.{ .idx = .button, .c = p.accent_blue_soft });
            zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = p.accent_blue_hover });
            zgui.pushStyleColor4f(.{ .idx = .text, .c = p.accent_blue });
            if (zgui.button("以管理员身份重启", .{ .w = -1.0, .h = 30.0 * s })) {
                state.request_relaunch_admin = true;
            }
            zgui.popStyleColor(.{ .count = 3 });
        }
    }
    zgui.endChild();
}

fn renderNavItem(state: *AppState, page: Page) void {
    const s = state.dpi_scale;
    const p = theme.active();
    const is_active = state.current_page == page;
    const dl = zgui.getWindowDrawList();
    const pos = zgui.getCursorScreenPos();
    const btn_h = 33.0 * s;

    zgui.pushStyleColor4f(.{ .idx = .button, .c = if (is_active) p.accent_blue_soft else .{ 0, 0, 0, 0 } });
    zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = if (is_active) p.accent_blue_hover else p.card_elevated });
    zgui.pushStyleColor4f(.{ .idx = .button_active, .c = p.accent_blue_hover });
    zgui.pushStyleColor4f(.{ .idx = .text, .c = if (is_active) p.accent_blue else p.text_secondary });
    zgui.pushStyleVar2f(.{ .idx = .button_text_align, .v = .{ 0.08, 0.5 } });

    var label_buf: [64]u8 = undefined;
    const btn_label = if (page == .alerts and state.active_alert_count > 0)
        std.fmt.bufPrintZ(&label_buf, "[{s}]  {s} ({d})", .{ page.badge(), page.labelZh(), state.active_alert_count }) catch page.labelZh()
    else
        std.fmt.bufPrintZ(&label_buf, "[{s}]  {s}", .{ page.badge(), page.labelZh() }) catch page.labelZh();

    if (zgui.button(btn_label, .{ .w = -1.0, .h = btn_h })) {
        state.current_page = page;
    }

    zgui.popStyleVar(.{ .count = 1 });
    zgui.popStyleColor(.{ .count = 4 });

    if (is_active) {
        dl.addRectFilled(.{
            .pmin = .{ pos[0], pos[1] + 5.0 * s },
            .pmax = .{ pos[0] + 3.5 * s, pos[1] + btn_h - 5.0 * s },
            .col = theme.colorU32(p.accent_blue),
            .rounding = 2.0 * s,
        });
    }
}
