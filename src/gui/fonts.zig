const std = @import("std");
const zgui = @import("zgui");

/// 中文字体加载器（规范 §7 / Q5）：
/// 优先按顺序加载 Windows 系统自带中文字体，依靠 ImGui 1.92 动态字形按需光栅化，
/// 不向 EXE 打包数十 MB 字体文件；全部不可用时回退 ImGui 内置默认字体。
pub const FontResult = struct {
    loaded_name: []const u8,
    base_size_px: f32,
};

const Candidate = struct {
    path: [:0]const u8,
    label: []const u8,
};

const CANDIDATES = [_]Candidate{
    .{ .path = "C:\\Windows\\Fonts\\msyh.ttc", .label = "Microsoft YaHei (msyh.ttc)" },
    .{ .path = "C:\\Windows\\Fonts\\simhei.ttf", .label = "SimHei (simhei.ttf)" },
    .{ .path = "C:\\Windows\\Fonts\\simsun.ttc", .label = "SimSun (simsun.ttc)" },
};

pub fn loadFonts(dpi_scale: f32) FontResult {
    // 禁止在工作目录生成杂乱的 imgui.ini
    zgui.io.setIniFilename(null);

    const scale = @max(dpi_scale, 1.0);
    const base_px: f32 = 16.0 * scale;

    for (CANDIDATES) |cand| {
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
