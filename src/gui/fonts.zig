const std = @import("std");
const builtin = @import("builtin");
const zgui = @import("zgui");

/// 跨平台中文字体加载器（规范 §7 / Q5）：
/// Windows 优先加载 msyh.ttc → simhei.ttf → simsun.ttc；
/// Linux 优先加载 Noto Sans CJK → WenQuanYi Micro Hei → DejaVu Sans；
/// 全部不可用时回退 ImGui 默认内置字体。
pub const FontResult = struct {
    loaded_name: []const u8,
    base_size_px: f32,
};

const Candidate = struct {
    path: [:0]const u8,
    label: []const u8,
};

const WIN_CANDIDATES = [_]Candidate{
    .{ .path = "C:\\Windows\\Fonts\\msyh.ttc", .label = "Microsoft YaHei (msyh.ttc)" },
    .{ .path = "C:\\Windows\\Fonts\\simhei.ttf", .label = "SimHei (simhei.ttf)" },
    .{ .path = "C:\\Windows\\Fonts\\simsun.ttc", .label = "SimSun (simsun.ttc)" },
};

const LINUX_CANDIDATES = [_]Candidate{
    .{ .path = "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc", .label = "Noto Sans CJK" },
    .{ .path = "/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc", .label = "Noto Sans CJK" },
    .{ .path = "/usr/share/fonts/truetype/wqy/wqy-microhei.ttc", .label = "WenQuanYi Micro Hei" },
    .{ .path = "/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc", .label = "WenQuanYi Zen Hei" },
    .{ .path = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", .label = "DejaVu Sans" },
};

pub fn loadFonts(dpi_scale: f32) FontResult {
    // 禁止在工作目录生成杂乱的 imgui.ini
    zgui.io.setIniFilename(null);

    const scale = @max(dpi_scale, 1.0);
    const base_px: f32 = 16.0 * scale;
    const candidates = if (builtin.os.tag == .windows) &WIN_CANDIDATES else &LINUX_CANDIDATES;

    for (candidates) |cand| {
        if (std.fs.accessAbsolute(cand.path, .{})) |_| {
            const font = zgui.io.addFontFromFile(cand.path, base_px);
            zgui.io.setDefaultFont(font);
            return .{
                .loaded_name = cand.label,
                .base_size_px = base_px,
            };
        } else |_| {}
    }

    // Fallback to built-in default font
    const def = zgui.io.addFontDefault(null);
    zgui.io.setDefaultFont(def);
    return .{
        .loaded_name = "ImGui Default (fallback)",
        .base_size_px = 13.0 * scale,
    };
}
