//! 跨平台中 / 英 / 日三语字体加载器（规范 §7 / Q5）。
//! - Windows：主字体优先加载微软雅黑（msyh.ttc → simhei.ttf → simsun.ttc），
//!   再通过 ImGui `merge_mode = true` 合并系统自带日文字体（YuGothM.ttc → meiryo.ttc → msgothic.ttc），
//!   确保简体中文、英文与日文假名/汉字同屏清晰无乱码，同时依托 ImGui 1.92 动态按需光栅化保持极低内存占用；
//! - Linux：优先加载 Noto Sans CJK（天然覆盖中日英）或文泉驿/DejaVu 回退。
const std = @import("std");
const builtin = @import("builtin");
const zgui = @import("zgui");

pub const FontResult = struct {
    loaded_name: []const u8,
    base_size_px: f32,
};

const Candidate = struct {
    path: [:0]const u8,
    label: []const u8,
};

const WIN_PRIMARY_CANDIDATES = [_]Candidate{
    .{ .path = "C:\\Windows\\Fonts\\msyh.ttc", .label = "Microsoft YaHei + Yu Gothic" },
    .{ .path = "C:\\Windows\\Fonts\\simhei.ttf", .label = "SimHei + Japanese Fallback" },
    .{ .path = "C:\\Windows\\Fonts\\simsun.ttc", .label = "SimSun + Japanese Fallback" },
};

const WIN_JP_MERGE_CANDIDATES = [_]Candidate{
    .{ .path = "C:\\Windows\\Fonts\\YuGothM.ttc", .label = "Yu Gothic Medium" },
    .{ .path = "C:\\Windows\\Fonts\\YuGothR.ttc", .label = "Yu Gothic Regular" },
    .{ .path = "C:\\Windows\\Fonts\\meiryo.ttc", .label = "Meiryo" },
    .{ .path = "C:\\Windows\\Fonts\\msgothic.ttc", .label = "MS Gothic" },
};

const LINUX_PRIMARY_CANDIDATES = [_]Candidate{
    .{ .path = "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc", .label = "Noto Sans CJK" },
    .{ .path = "/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc", .label = "Noto Sans CJK" },
    .{ .path = "/usr/share/fonts/truetype/wqy/wqy-microhei.ttc", .label = "WenQuanYi Micro Hei" },
    .{ .path = "/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc", .label = "WenQuanYi Zen Hei" },
    .{ .path = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", .label = "DejaVu Sans" },
};

const LINUX_JP_MERGE_CANDIDATES = [_]Candidate{
    .{ .path = "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc", .label = "Noto Sans CJK" },
    .{ .path = "/usr/share/fonts/truetype/fonts-japanese-gothic.ttf", .label = "Japanese Gothic" },
};

pub fn loadFonts(dpi_scale: f32) FontResult {
    // 禁止在工作目录生成杂乱的 imgui.ini
    zgui.io.setIniFilename(null);

    const scale = @max(dpi_scale, 1.0);
    const base_px: f32 = 16.0 * scale;
    const primaries = if (builtin.os.tag == .windows) &WIN_PRIMARY_CANDIDATES else &LINUX_PRIMARY_CANDIDATES;
    const jp_merges = if (builtin.os.tag == .windows) &WIN_JP_MERGE_CANDIDATES else &LINUX_JP_MERGE_CANDIDATES;

    for (primaries) |cand| {
        if (std.fs.accessAbsolute(cand.path, .{})) |_| {
            const font = zgui.io.addFontFromFile(cand.path, base_px);

            // 合并日文字体以完整覆盖平假名、片假名与日文汉字（按需光栅化，零预加载内存浪费）
            for (jp_merges) |jp| {
                if (std.mem.eql(u8, cand.path, jp.path)) break;
                if (std.fs.accessAbsolute(jp.path, .{})) |_| {
                    var cfg = zgui.FontConfig.init();
                    cfg.merge_mode = true;
                    _ = zgui.io.addFontFromFileWithConfig(jp.path, base_px, cfg, null);
                    break;
                } else |_| {}
            }

            zgui.io.setDefaultFont(font);
            return .{
                .loaded_name = cand.label,
                .base_size_px = base_px,
            };
        } else |_| {}
    }

    // 全部系统字体不可用时安全回退到 ImGui 默认字体
    const def = zgui.io.addFontDefault(null);
    zgui.io.setDefaultFont(def);
    return .{
        .loaded_name = "ImGui Default (fallback)",
        .base_size_px = 13.0 * scale,
    };
}
