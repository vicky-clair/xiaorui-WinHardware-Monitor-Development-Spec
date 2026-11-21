const zgui = @import("zgui");
const sensor = @import("../core/sensor.zig");
const ThemeMode = @import("../app/state.zig").ThemeMode;

/// 深色 / 浅色（黑白）双主题色彩系统（深色参照 界面示例.jpg / 界面示例2.jpg，浅色对应高对比明亮 Bento 风格）
pub const ThemeColors = struct {
    canvas_bg: [4]f32,
    sidebar_bg: [4]f32,
    card_bg: [4]f32,
    card_elevated: [4]f32,
    card_border: [4]f32,
    divider: [4]f32,

    text_primary: [4]f32,
    text_secondary: [4]f32,
    text_muted: [4]f32,

    accent_blue: [4]f32,
    accent_blue_soft: [4]f32,
    accent_blue_hover: [4]f32,
    accent_cyan: [4]f32,
    accent_purple: [4]f32,

    status_ok: [4]f32,
    status_caution: [4]f32,
    status_warning: [4]f32,
    status_critical: [4]f32,
    status_unknown: [4]f32,

    gauge_track: [4]f32,
    btn_hover: [4]f32,
    btn_active: [4]f32,
    row_alt: [4]f32,

    pub fn healthColor(self: ThemeColors, level: sensor.HealthLevel) [4]f32 {
        return switch (level) {
            .normal => self.status_ok,
            .caution => self.status_caution,
            .warning => self.status_warning,
            .critical => self.status_critical,
            .unknown => self.status_unknown,
        };
    }

    pub fn sensorStatusColor(self: ThemeColors, st: sensor.SensorStatus) [4]f32 {
        return switch (st) {
            .ok => self.status_ok,
            .access_denied, .requires_extension => self.status_caution,
            .transient_error, .timeout, .device_removed => self.status_critical,
            .device_standby, .stale => self.accent_cyan,
            .unsupported, .unknown => self.status_unknown,
        };
    }
};

pub const DARK_COLORS = ThemeColors{
    .canvas_bg = hex(0x0A0C10, 1.0),
    .sidebar_bg = hex(0x0E1117, 1.0),
    .card_bg = hex(0x13161E, 1.0),
    .card_elevated = hex(0x1A1F2B, 1.0),
    .card_border = hex(0x232836, 1.0),
    .divider = hex(0x1E2330, 1.0),

    .text_primary = hex(0xF1F5F9, 1.0),
    .text_secondary = hex(0x94A3B8, 1.0),
    .text_muted = hex(0x64748B, 1.0),

    .accent_blue = hex(0x3B82F6, 1.0),
    .accent_blue_soft = hex(0x3B82F6, 0.18),
    .accent_blue_hover = hex(0x3B82F6, 0.30),
    .accent_cyan = hex(0x06B6D4, 1.0),
    .accent_purple = hex(0xA855F7, 1.0),

    .status_ok = hex(0x34D399, 1.0),
    .status_caution = hex(0xF59E0B, 1.0),
    .status_warning = hex(0xF97316, 1.0),
    .status_critical = hex(0xEF4444, 1.0),
    .status_unknown = hex(0x64748B, 1.0),

    .gauge_track = hex(0x232836, 1.0),
    .btn_hover = hex(0x252C3D, 1.0),
    .btn_active = hex(0x2E3850, 1.0),
    .row_alt = hex(0xFFFFFF, 0.025),
};

pub const LIGHT_COLORS = ThemeColors{
    .canvas_bg = hex(0xF2F5F9, 1.0),
    .sidebar_bg = hex(0xFFFFFF, 1.0),
    .card_bg = hex(0xFFFFFF, 1.0),
    .card_elevated = hex(0xEDF1F7, 1.0),
    .card_border = hex(0xD8E0EC, 1.0),
    .divider = hex(0xE2E8F0, 1.0),

    .text_primary = hex(0x0F172A, 1.0),
    .text_secondary = hex(0x334155, 1.0),
    .text_muted = hex(0x64748B, 1.0),

    .accent_blue = hex(0x2563EB, 1.0),
    .accent_blue_soft = hex(0x2563EB, 0.12),
    .accent_blue_hover = hex(0x2563EB, 0.22),
    .accent_cyan = hex(0x0891B2, 1.0),
    .accent_purple = hex(0x7C3AED, 1.0),

    .status_ok = hex(0x059669, 1.0),
    .status_caution = hex(0xD97706, 1.0),
    .status_warning = hex(0xEA580C, 1.0),
    .status_critical = hex(0xDC2626, 1.0),
    .status_unknown = hex(0x64748B, 1.0),

    .gauge_track = hex(0xE2E8F0, 1.0),
    .btn_hover = hex(0xDFE6F0, 1.0),
    .btn_active = hex(0xCBD5E1, 1.0),
    .row_alt = hex(0x0F172A, 0.03),
};

var current_colors: ThemeColors = DARK_COLORS;
var style_scaled_once: bool = false;

pub fn active() *const ThemeColors {
    return &current_colors;
}

pub fn hex(comptime rgb: u24, alpha: f32) [4]f32 {
    const r: f32 = @as(f32, @floatFromInt((rgb >> 16) & 0xFF)) / 255.0;
    const g: f32 = @as(f32, @floatFromInt((rgb >> 8) & 0xFF)) / 255.0;
    const b: f32 = @as(f32, @floatFromInt(rgb & 0xFF)) / 255.0;
    return .{ r, g, b, alpha };
}

pub fn colorU32(c: [4]f32) u32 {
    return zgui.colorConvertFloat4ToU32(c);
}

pub fn applyTheme(mode: ThemeMode, dpi_scale: f32) void {
    current_colors = switch (mode) {
        .dark => DARK_COLORS,
        .light => LIGHT_COLORS,
    };
    const p = &current_colors;

    const style = zgui.getStyle();
    if (mode == .dark) {
        style.setColorsDark();
    } else {
        style.setColorsLight();
    }

    if (!style_scaled_once) {
        style.window_padding = .{ 16.0, 14.0 };
        style.window_rounding = 0.0;
        style.window_border_size = 0.0;
        style.child_rounding = 10.0;
        style.child_border_size = 1.0;
        style.frame_padding = .{ 10.0, 6.0 };
        style.frame_rounding = 6.0;
        style.frame_border_size = 0.0;
        style.popup_rounding = 8.0;
        style.popup_border_size = 1.0;
        style.scrollbar_size = 10.0;
        style.scrollbar_rounding = 6.0;
        style.grab_rounding = 6.0;
        style.tab_rounding = 6.0;
        style.item_spacing = .{ 10.0, 8.0 };
        style.cell_padding = .{ 10.0, 6.0 };
        style.anti_aliased_lines = true;
        style.anti_aliased_fill = true;

        if (dpi_scale > 1.01) {
            style.scaleAllSizes(dpi_scale);
        }
        style_scaled_once = true;
    }

    style.setColor(.window_bg, p.canvas_bg);
    style.setColor(.child_bg, p.card_bg);
    style.setColor(.popup_bg, p.card_elevated);
    style.setColor(.border, p.card_border);
    style.setColor(.border_shadow, .{ 0, 0, 0, 0 });
    style.setColor(.text, p.text_primary);
    style.setColor(.text_disabled, p.text_muted);

    style.setColor(.frame_bg, p.card_elevated);
    style.setColor(.frame_bg_hovered, p.btn_hover);
    style.setColor(.frame_bg_active, p.btn_active);

    style.setColor(.button, p.card_elevated);
    style.setColor(.button_hovered, p.btn_hover);
    style.setColor(.button_active, p.btn_active);

    style.setColor(.header, p.accent_blue_soft);
    style.setColor(.header_hovered, p.accent_blue_hover);
    style.setColor(.header_active, p.accent_blue_hover);

    style.setColor(.check_mark, p.accent_blue);
    style.setColor(.slider_grab, p.accent_blue);
    style.setColor(.slider_grab_active, p.accent_blue);

    style.setColor(.separator, p.divider);
    style.setColor(.scrollbar_bg, p.canvas_bg);
    style.setColor(.scrollbar_grab, p.card_border);
    style.setColor(.scrollbar_grab_hovered, p.text_muted);
    style.setColor(.scrollbar_grab_active, p.accent_blue);

    style.setColor(.table_header_bg, p.card_elevated);
    style.setColor(.table_border_strong, p.card_border);
    style.setColor(.table_border_light, p.divider);
    style.setColor(.table_row_bg, .{ 0, 0, 0, 0 });
    style.setColor(.table_row_bg_alt, p.row_alt);
}
