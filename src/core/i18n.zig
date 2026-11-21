//! 中 / 英 / 日 三语国际化模块（简体中文 `zh-CN`、English `en-US`、日本語 `ja-JP`）。
//! 设计目标：
//! - 零运行时堆分配、原子读 O(1) 开销，对 CPU/内存占用几乎为零；
//! - 支持在主界面实时无缝切换语言，所有页面、表格、仪表、托盘菜单与导出报告同步一致；
//! - 语言代码持久化到 `settings.toml` 的 `[general] language` 字段。
const std = @import("std");

pub const Language = enum(u8) {
    zh_cn = 0,
    en_us = 1,
    ja_jp = 2,

    /// 对应配置文件与标准 BCP-47 语言代码
    pub fn code(self: Language) []const u8 {
        return switch (self) {
            .zh_cn => "zh-CN",
            .en_us => "en-US",
            .ja_jp => "ja-JP",
        };
    }

    /// 解析配置文件中的语言代码（容错大小写与短前缀，默认简体中文）
    pub fn fromCode(raw: []const u8) Language {
        if (raw.len >= 2) {
            if (std.ascii.eqlIgnoreCase(raw[0..2], "en")) return .en_us;
            if (std.ascii.eqlIgnoreCase(raw[0..2], "ja")) return .ja_jp;
            if (std.ascii.eqlIgnoreCase(raw[0..2], "zh")) return .zh_cn;
        }
        return .zh_cn;
    }

    /// 语言自身名称（用于下拉/单选与快捷切换按钮，不随当前语言改变以便误切时找回）
    pub fn nativeName(self: Language) [:0]const u8 {
        return switch (self) {
            .zh_cn => "简体中文",
            .en_us => "English",
            .ja_jp => "日本語",
        };
    }

    /// 快捷循环切换顺序：中文 → English → 日本語 → 中文
    pub fn next(self: Language) Language {
        return switch (self) {
            .zh_cn => .en_us,
            .en_us => .ja_jp,
            .ja_jp => .zh_cn,
        };
    }
};

var g_active_lang: std.atomic.Value(u8) = std.atomic.Value(u8).init(@intFromEnum(Language.zh_cn));

/// 获取当前全局生效语言（线程安全、无锁读取）
pub inline fn current() Language {
    return @enumFromInt(g_active_lang.load(.acquire));
}

/// 切换当前全局生效语言（实时生效于 GUI 线程、后台采集与托盘菜单）
pub fn setLanguage(lang: Language) void {
    g_active_lang.store(@intFromEnum(lang), .release);
}

/// 返回以 NUL 结尾的当前语言本地化字符串（适用于 zgui 控件与标签）
pub inline fn tr(zh: [:0]const u8, en: [:0]const u8, ja: [:0]const u8) [:0]const u8 {
    return switch (current()) {
        .zh_cn => zh,
        .en_us => en,
        .ja_jp => ja,
    };
}

/// 返回普通切片形式的当前语言本地化字符串
pub inline fn trSlice(zh: []const u8, en: []const u8, ja: []const u8) []const u8 {
    return switch (current()) {
        .zh_cn => zh,
        .en_us => en,
        .ja_jp => ja,
    };
}

test "i18n switches cleanly across zh-CN, en-US, and ja-JP" {
    const prev = current();
    defer setLanguage(prev);

    try std.testing.expectEqual(Language.zh_cn, Language.fromCode("zh-CN"));
    try std.testing.expectEqual(Language.en_us, Language.fromCode("en-US"));
    try std.testing.expectEqual(Language.ja_jp, Language.fromCode("ja-JP"));
    try std.testing.expectEqual(Language.zh_cn, Language.fromCode("unknown"));

    setLanguage(.zh_cn);
    try std.testing.expectEqualStrings("正常", tr("正常", "Normal", "正常"));
    setLanguage(.en_us);
    try std.testing.expectEqualStrings("Normal", tr("正常", "Normal", "正常"));
    setLanguage(.ja_jp);
    try std.testing.expectEqualStrings("温度", tr("温度", "Temperature", "温度"));

    try std.testing.expectEqual(Language.en_us, Language.zh_cn.next());
    try std.testing.expectEqual(Language.ja_jp, Language.en_us.next());
    try std.testing.expectEqual(Language.zh_cn, Language.ja_jp.next());
}
