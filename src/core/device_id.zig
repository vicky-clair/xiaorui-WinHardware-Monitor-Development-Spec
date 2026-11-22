const std = @import("std");

/// 规范 §3.2 跨重启稳定设备 ID 生成器。
/// 禁止使用易变的 PhysicalDriveN 序号作为设备标识；
/// 磁盘 ID = SHA-256(接口 + 型号 + 序列号 + WWN) 前 16 位十六进制字符。
pub const StableId = struct {
    text: [16]u8 = [_]u8{'0'} ** 16,
    is_stable: bool = true,

    pub fn slice(self: *const StableId) []const u8 {
        return &self.text;
    }

    pub fn eql(self: StableId, other: StableId) bool {
        return std.mem.eql(u8, &self.text, &other.text);
    }
};

/// 校验硬件序列号是否有效（过滤空串、过短串以及全 0 / 全 F / 全占位符的无效厂商固件值）
pub fn isSerialValid(raw_serial: []const u8) bool {
    const trimmed = std.mem.trim(u8, raw_serial, " \t\r\n\x00");
    if (trimmed.len < 4) return false;
    var all_zero = true;
    var all_f = true;
    var all_underscore = true;
    for (trimmed) |c| {
        if (c != '0' and c != ' ') all_zero = false;
        if (c != 'F' and c != 'f' and c != ' ') all_f = false;
        if (c != '_' and c != '-' and c != ' ') all_underscore = false;
    }
    if (all_zero or all_f or all_underscore) return false;
    return true;
}

/// 根据磁盘接口类型、型号、序列号及 WWN/EUI 生成跨重启不变的 16 位十六进制稳定设备 ID；
/// 若序列号与 WWN 均缺失，则回退到设备路径并显式标记 `is_stable = false`。
pub fn computeDiskId(
    interface_name: []const u8,
    model: []const u8,
    serial: []const u8,
    wwn_or_eui: []const u8,
    fallback_path: []const u8,
) StableId {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    const serial_ok = isSerialValid(serial);
    const wwn_ok = std.mem.trim(u8, wwn_or_eui, " \t\r\n\x00").len >= 4;
    const stable = serial_ok or wwn_ok;

    hasher.update("disk|");
    hasher.update(std.mem.trim(u8, interface_name, " \t\r\n\x00"));
    hasher.update("|");
    hasher.update(std.mem.trim(u8, model, " \t\r\n\x00"));
    hasher.update("|");
    if (stable) {
        if (serial_ok) hasher.update(std.mem.trim(u8, serial, " \t\r\n\x00"));
        hasher.update("|");
        if (wwn_ok) hasher.update(std.mem.trim(u8, wwn_or_eui, " \t\r\n\x00"));
    } else {
        // 回退路径，标记不稳定（规范 §3.2）
        hasher.update("fallback:");
        hasher.update(fallback_path);
    }

    var digest: [32]u8 = undefined;
    hasher.final(&digest);

    var out = StableId{ .is_stable = stable };
    const hex_chars = "0123456789abcdef";
    for (0..8) |i| {
        out.text[i * 2] = hex_chars[digest[i] >> 4];
        out.text[i * 2 + 1] = hex_chars[digest[i] & 0x0F];
    }
    return out;
}

/// 规范 §9 第 14 条：界面与日志默认脱敏序列号（仅保留后 4 位）
pub fn maskSerial(raw_serial: []const u8, out_buf: []u8) usize {
    const trimmed = std.mem.trim(u8, raw_serial, " \t\r\n\x00");
    if (trimmed.len == 0) {
        const na = "N/A";
        const n = @min(na.len, out_buf.len);
        @memcpy(out_buf[0..n], na[0..n]);
        return n;
    }
    if (trimmed.len <= 4) {
        const stars = "****";
        const n = @min(stars.len, out_buf.len);
        @memcpy(out_buf[0..n], stars[0..n]);
        return n;
    }
    const last4 = trimmed[trimmed.len - 4 ..];
    const res = std.fmt.bufPrint(out_buf, "****{s}", .{last4}) catch return 0;
    return res.len;
}

test "computeDiskId stays identical across PhysicalDrive renumbering" {
    const id_boot1 = computeDiskId("NVMe", "WD Blue SN570 1TB SSD", "2234AB8077AE", "", "\\\\.\\PhysicalDrive0");
    const id_boot2 = computeDiskId("NVMe", "WD Blue SN570 1TB SSD", "2234AB8077AE", "", "\\\\.\\PhysicalDrive3");
    try std.testing.expect(id_boot1.is_stable);
    try std.testing.expect(id_boot1.eql(id_boot2));

    const id_other = computeDiskId("NVMe", "WD Blue SN570 1TB SSD", "9999ZZ112233", "", "\\\\.\\PhysicalDrive0");
    try std.testing.expect(!id_boot1.eql(id_other));
}

test "computeDiskId marks fallback as unstable when serial is invalid" {
    const id_zero = computeDiskId("USB", "Generic Disk", "000000000000", "", "\\\\.\\PhysicalDrive2");
    try std.testing.expect(!id_zero.is_stable);
    try std.testing.expectEqual(@as(usize, 16), id_zero.slice().len);
}

test "maskSerial masks all but last 4 chars" {
    var buf: [32]u8 = undefined;
    const n = maskSerial("2234AB8077AE", &buf);
    try std.testing.expectEqualStrings("****77AE", buf[0..n]);
}
