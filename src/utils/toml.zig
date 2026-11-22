const std = @import("std");

/// 项目自研零依赖 TOML 最小子集解析与序列化器（规范 §1.1 / Q2）。
/// 支持：[section]、[section.sub]、string / int / float / bool、# 注释、UTF-8 与往返序列化。
pub const Value = union(enum) {
    string: []const u8,
    int: i64,
    float: f64,
    boolean: bool,
};

pub const Entry = struct {
    section: []const u8,
    key: []const u8,
    value: Value,
};

pub const ParseError = error{
    InvalidSyntax,
    UnterminatedString,
    InvalidEscape,
    InvalidValue,
    OutOfMemory,
};

pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    entries: std.ArrayList(Entry),

    pub fn init(backing: std.mem.Allocator) Document {
        return .{
            .arena = std.heap.ArenaAllocator.init(backing),
            .entries = .empty,
        };
    }

    pub fn deinit(self: *Document) void {
        self.entries.deinit(self.arena.allocator());
        self.arena.deinit();
    }

    /// 解析 UTF-8 TOML 文本为只读键值文档，内部使用 ArenaAllocator 统一托管字符串生命周期
    pub fn parse(backing: std.mem.Allocator, input: []const u8) ParseError!Document {
        var doc = Document.init(backing);
        errdefer doc.deinit();
        const alloc = doc.arena.allocator();

        var current_section: []const u8 = "";
        var line_iter = std.mem.splitScalar(u8, input, '\n');

        while (line_iter.next()) |raw_line| {
            const line_no_cr = std.mem.trimRight(u8, raw_line, "\r");
            const trimmed = std.mem.trim(u8, line_no_cr, " \t");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            // 节头解析：[section] 或 [section.sub]
            if (trimmed[0] == '[') {
                const close_idx = std.mem.indexOfScalar(u8, trimmed, ']') orelse return error.InvalidSyntax;
                const sec_raw = std.mem.trim(u8, trimmed[1..close_idx], " \t");
                if (sec_raw.len == 0) return error.InvalidSyntax;
                const trailing = std.mem.trim(u8, trimmed[close_idx + 1 ..], " \t");
                if (trailing.len > 0 and trailing[0] != '#') return error.InvalidSyntax;
                current_section = try alloc.dupe(u8, sec_raw);
                continue;
            }

            // 键值对解析：Key = Value
            const eq_idx = std.mem.indexOfScalar(u8, trimmed, '=') orelse return error.InvalidSyntax;
            const key_raw = std.mem.trim(u8, trimmed[0..eq_idx], " \t");
            if (key_raw.len == 0) return error.InvalidSyntax;
            const val_raw_full = std.mem.trim(u8, trimmed[eq_idx + 1 ..], " \t");
            if (val_raw_full.len == 0) return error.InvalidValue;

            const value = try parseValue(alloc, val_raw_full);
            try doc.entries.append(alloc, .{
                .section = current_section,
                .key = try alloc.dupe(u8, key_raw),
                .value = value,
            });
        }

        return doc;
    }

    pub fn get(self: *const Document, section: []const u8, key: []const u8) ?Value {
        for (self.entries.items) |e| {
            if (std.mem.eql(u8, e.section, section) and std.mem.eql(u8, e.key, key)) {
                return e.value;
            }
        }
        return null;
    }

    pub fn getString(self: *const Document, section: []const u8, key: []const u8) ?[]const u8 {
        const v = self.get(section, key) orelse return null;
        return switch (v) {
            .string => |s| s,
            else => null,
        };
    }

    pub fn getInt(self: *const Document, section: []const u8, key: []const u8) ?i64 {
        const v = self.get(section, key) orelse return null;
        return switch (v) {
            .int => |i| i,
            else => null,
        };
    }

    pub fn getBool(self: *const Document, section: []const u8, key: []const u8) ?bool {
        const v = self.get(section, key) orelse return null;
        return switch (v) {
            .boolean => |b| b,
            else => null,
        };
    }

    pub fn getFloat(self: *const Document, section: []const u8, key: []const u8) ?f64 {
        const v = self.get(section, key) orelse return null;
        return switch (v) {
            .float => |f| f,
            .int => |i| @floatFromInt(i),
            else => null,
        };
    }

    pub fn put(self: *Document, section: []const u8, key: []const u8, value: Value) !void {
        const alloc = self.arena.allocator();
        const stored_val: Value = switch (value) {
            .string => |s| .{ .string = try alloc.dupe(u8, s) },
            else => value,
        };
        for (self.entries.items) |*e| {
            if (std.mem.eql(u8, e.section, section) and std.mem.eql(u8, e.key, key)) {
                e.value = stored_val;
                return;
            }
        }
        try self.entries.append(alloc, .{
            .section = try alloc.dupe(u8, section),
            .key = try alloc.dupe(u8, key),
            .value = stored_val,
        });
    }

    /// 序列化为标准 TOML 文本，调用方负责释放返回切片
    pub fn serialize(self: *const Document, allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        const w = out.writer(allocator);

        var last_section: ?[]const u8 = null;
        for (self.entries.items) |e| {
            if (last_section == null or !std.mem.eql(u8, last_section.?, e.section)) {
                if (last_section != null) try w.writeByte('\n');
                if (e.section.len > 0) {
                    try w.print("[{s}]\n", .{e.section});
                }
                last_section = e.section;
            }
            try w.print("{s} = ", .{e.key});
            switch (e.value) {
                .string => |s| {
                    try w.writeByte('"');
                    for (s) |ch| {
                        switch (ch) {
                            '"' => try w.writeAll("\\\""),
                            '\\' => try w.writeAll("\\\\"),
                            '\n' => try w.writeAll("\\n"),
                            '\r' => try w.writeAll("\\r"),
                            '\t' => try w.writeAll("\\t"),
                            else => try w.writeByte(ch),
                        }
                    }
                    try w.writeAll("\"\n");
                },
                .int => |i| try w.print("{d}\n", .{i}),
                .float => |f| try w.print("{d}\n", .{f}),
                .boolean => |b| try w.print("{s}\n", .{if (b) "true" else "false"}),
            }
        }
        return out.toOwnedSlice(allocator);
    }
};

fn parseValue(alloc: std.mem.Allocator, raw: []const u8) ParseError!Value {
    if (raw[0] == '"') {
        var buf: std.ArrayList(u8) = .empty;
        var i: usize = 1;
        while (i < raw.len) : (i += 1) {
            const c = raw[i];
            if (c == '"') {
                const rest = std.mem.trim(u8, raw[i + 1 ..], " \t");
                if (rest.len > 0 and rest[0] != '#') return error.InvalidSyntax;
                return .{ .string = try buf.toOwnedSlice(alloc) };
            }
            if (c == '\\') {
                i += 1;
                if (i >= raw.len) return error.UnterminatedString;
                const esc = raw[i];
                const mapped: u8 = switch (esc) {
                    '"' => '"',
                    '\\' => '\\',
                    'n' => '\n',
                    'r' => '\r',
                    't' => '\t',
                    else => return error.InvalidEscape,
                };
                try buf.append(alloc, mapped);
            } else {
                try buf.append(alloc, c);
            }
        }
        return error.UnterminatedString;
    }

    // Strip inline comment for non-string values
    const val_str = blk: {
        if (std.mem.indexOfScalar(u8, raw, '#')) |hash_idx| {
            break :blk std.mem.trim(u8, raw[0..hash_idx], " \t");
        }
        break :blk raw;
    };

    if (std.mem.eql(u8, val_str, "true")) return .{ .boolean = true };
    if (std.mem.eql(u8, val_str, "false")) return .{ .boolean = false };

    if (std.mem.indexOfScalar(u8, val_str, '.') != null) {
        const f = std.fmt.parseFloat(f64, val_str) catch return error.InvalidValue;
        return .{ .float = f };
    }

    const i = std.fmt.parseInt(i64, val_str, 10) catch return error.InvalidValue;
    return .{ .int = i };
}

test "TOML parse and serialize round-trip" {
    const sample =
        \\# Comment line
        \\[general]
        \\language = "zh-CN" # inline comment
        \\start_with_windows = false
        \\
        \\[alerts.thresholds]
        \\cpu_caution_c = 80
        \\ratio = 1.5
        \\escaped = "C:\\Program Files\\Monitor"
    ;

    var doc = try Document.parse(std.testing.allocator, sample);
    defer doc.deinit();

    try std.testing.expectEqualStrings("zh-CN", doc.getString("general", "language").?);
    try std.testing.expectEqual(false, doc.getBool("general", "start_with_windows").?);
    try std.testing.expectEqual(@as(i64, 80), doc.getInt("alerts.thresholds", "cpu_caution_c").?);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), doc.getFloat("alerts.thresholds", "ratio").?, 1e-9);
    try std.testing.expectEqualStrings("C:\\Program Files\\Monitor", doc.getString("alerts.thresholds", "escaped").?);

    try doc.put("general", "language", .{ .string = "en-US" });
    const serialized = try doc.serialize(std.testing.allocator);
    defer std.testing.allocator.free(serialized);

    var doc2 = try Document.parse(std.testing.allocator, serialized);
    defer doc2.deinit();
    try std.testing.expectEqualStrings("en-US", doc2.getString("general", "language").?);
    try std.testing.expectEqualStrings("C:\\Program Files\\Monitor", doc2.getString("alerts.thresholds", "escaped").?);
}
