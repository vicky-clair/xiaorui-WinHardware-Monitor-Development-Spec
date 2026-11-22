const std = @import("std");
const builtin = @import("builtin");
const win32 = @import("win32.zig");

/// 用户态 SMBIOS (RSMB) 解析器（规范 §2.4 / §3.3）：
/// 读取主板厂商/型号/版本（Type 2）、处理器基础频率（Type 4）、物理内存插槽明细（Type 17）。
/// 严格执行边界与长度校验（规范 §9 第 13 条）。
pub const MAX_DIMMS = 16;

pub const DimmInfo = struct {
    slot: [48]u8 = std.mem.zeroes([48]u8),
    slot_len: usize = 0,
    manufacturer: [48]u8 = std.mem.zeroes([48]u8),
    manufacturer_len: usize = 0,
    part_number: [48]u8 = std.mem.zeroes([48]u8),
    part_number_len: usize = 0,
    serial_masked: [24]u8 = std.mem.zeroes([24]u8),
    serial_masked_len: usize = 0,
    size_mb: u64 = 0,
    speed_mhz: u32 = 0,
    configured_speed_mhz: u32 = 0,
    memory_type: u8 = 0,

    pub fn slotSlice(self: *const DimmInfo) []const u8 {
        return self.slot[0..self.slot_len];
    }
    pub fn manufacturerSlice(self: *const DimmInfo) []const u8 {
        return self.manufacturer[0..self.manufacturer_len];
    }
    pub fn partNumberSlice(self: *const DimmInfo) []const u8 {
        return self.part_number[0..self.part_number_len];
    }
    pub fn serialMaskedSlice(self: *const DimmInfo) []const u8 {
        return self.serial_masked[0..self.serial_masked_len];
    }

    /// 将 SMBIOS Type 17 内存类型字节映射为常见标准代际名称
    pub fn memoryTypeName(self: *const DimmInfo) []const u8 {
        return switch (self.memory_type) {
            0x18 => "DDR3",
            0x1A => "DDR4",
            0x1E => "LPDDR4",
            0x22 => "DDR5",
            0x23 => "LPDDR5",
            else => "RAM",
        };
    }

    /// 优先返回当前 BIOS 配置生效频率，未提供时回退到标称最大频率
    pub fn effectiveSpeedMhz(self: *const DimmInfo) u32 {
        return if (self.configured_speed_mhz > 0) self.configured_speed_mhz else self.speed_mhz;
    }
};

/// 完整 SMBIOS 解析结果（主板信息、CPU 标称频率及全部已插槽 DIMM 明细）
pub const SmbiosData = struct {
    available: bool = false,
    major_version: u8 = 0,
    minor_version: u8 = 0,

    board_manufacturer: [64]u8 = std.mem.zeroes([64]u8),
    board_manufacturer_len: usize = 0,
    board_product: [64]u8 = std.mem.zeroes([64]u8),
    board_product_len: usize = 0,
    board_version: [48]u8 = std.mem.zeroes([48]u8),
    board_version_len: usize = 0,

    cpu_max_speed_mhz: u32 = 0,
    cpu_current_speed_mhz: u32 = 0,

    dimms: [MAX_DIMMS]DimmInfo = [_]DimmInfo{.{}} ** MAX_DIMMS,
    dimm_count: usize = 0,

    pub fn boardManufacturer(self: *const SmbiosData) []const u8 {
        return self.board_manufacturer[0..self.board_manufacturer_len];
    }
    pub fn boardProduct(self: *const SmbiosData) []const u8 {
        return self.board_product[0..self.board_product_len];
    }
    pub fn boardVersion(self: *const SmbiosData) []const u8 {
        return self.board_version[0..self.board_version_len];
    }

    pub fn primaryMemorySpeedMhz(self: *const SmbiosData) ?u32 {
        var best: u32 = 0;
        for (self.dimms[0..self.dimm_count]) |d| {
            if (d.size_mb == 0) continue;
            const spd = d.effectiveSpeedMhz();
            if (spd > best) best = spd;
        }
        return if (best > 0) best else null;
    }
};

pub fn queryLocal(allocator: std.mem.Allocator) SmbiosData {
    if (builtin.os.tag != .windows) return .{};
    const needed = win32.GetSystemFirmwareTable(win32.RSMB_SIGNATURE, 0, null, 0);
    if (needed < 8 or needed > 4 * 1024 * 1024) return .{};

    const buf = allocator.alloc(u8, needed) catch return .{};
    defer allocator.free(buf);

    const written = win32.GetSystemFirmwareTable(win32.RSMB_SIGNATURE, 0, buf.ptr, needed);
    if (written < 8 or written > needed) return .{};

    return parseRawRsmb(buf[0..written]);
}

/// 解析 Windows RawSMBIOSData 结构（前 8 字节头 + SMBIOS 表流）
pub fn parseRawRsmb(raw: []const u8) SmbiosData {
    var out = SmbiosData{};
    if (raw.len < 8) return out;

    out.major_version = raw[1];
    out.minor_version = raw[2];
    const table_len = std.mem.readInt(u32, raw[4..8], .little);
    if (8 + @as(usize, table_len) > raw.len) return out;

    const table = raw[8 .. 8 + table_len];
    out.available = true;

    var pos: usize = 0;
    while (pos + 4 <= table.len) {
        const stype = table[pos];
        const slen: usize = table[pos + 1];
        if (slen < 4 or pos + slen > table.len) break;

        const formatted = table[pos .. pos + slen];
        const strings_start = pos + slen;

        // 查找字符串段结束符（双 NUL）
        var p = strings_start;
        if (p + 1 < table.len and table[p] == 0 and table[p + 1] == 0) {
            p += 2;
        } else {
            while (p + 1 < table.len) : (p += 1) {
                if (table[p] == 0 and table[p + 1] == 0) {
                    p += 2;
                    break;
                }
            } else {
                p = table.len;
            }
        }
        const strings_block = table[strings_start..p];

        switch (stype) {
            2 => {
                // Baseboard Information
                if (slen >= 7) {
                    copyTrimmed(&out.board_manufacturer, &out.board_manufacturer_len, getString(strings_block, formatted[4]));
                    copyTrimmed(&out.board_product, &out.board_product_len, getString(strings_block, formatted[5]));
                    copyTrimmed(&out.board_version, &out.board_version_len, getString(strings_block, formatted[6]));
                }
            },
            4 => {
                // Processor Information
                if (slen >= 24) {
                    const max_spd = std.mem.readInt(u16, formatted[20..22], .little);
                    const cur_spd = std.mem.readInt(u16, formatted[22..24], .little);
                    if (max_spd > out.cpu_max_speed_mhz) out.cpu_max_speed_mhz = max_spd;
                    if (cur_spd > out.cpu_current_speed_mhz) out.cpu_current_speed_mhz = cur_spd;
                }
            },
            17 => {
                // Memory Device
                if (slen >= 21 and out.dimm_count < MAX_DIMMS) {
                    var dimm = DimmInfo{};
                    const raw_size = std.mem.readInt(u16, formatted[12..14], .little);
                    if (raw_size == 0 or raw_size == 0xFFFF) {
                        dimm.size_mb = 0;
                    } else if (raw_size == 0x7FFF and slen >= 32) {
                        dimm.size_mb = std.mem.readInt(u32, formatted[28..32], .little) & 0x7FFFFFFF;
                    } else if ((raw_size & 0x8000) != 0) {
                        dimm.size_mb = @as(u64, raw_size & 0x7FFF) / 1024;
                    } else {
                        dimm.size_mb = raw_size;
                    }

                    copyTrimmed(&dimm.slot, &dimm.slot_len, getString(strings_block, formatted[16]));
                    dimm.memory_type = formatted[18];

                    if (slen >= 23) {
                        dimm.speed_mhz = std.mem.readInt(u16, formatted[21..23], .little);
                    }
                    if (slen >= 28) {
                        copyTrimmed(&dimm.manufacturer, &dimm.manufacturer_len, getString(strings_block, formatted[23]));
                        maskSerialInto(&dimm.serial_masked, &dimm.serial_masked_len, getString(strings_block, formatted[24]));
                        copyTrimmed(&dimm.part_number, &dimm.part_number_len, getString(strings_block, formatted[26]));
                    }
                    if (slen >= 34) {
                        dimm.configured_speed_mhz = std.mem.readInt(u16, formatted[32..34], .little);
                    }
                    // SMBIOS 3.3+ Extended Speed for >= 65535 MT/s
                    if (slen >= 92) {
                        if (dimm.speed_mhz == 0xFFFF) {
                            dimm.speed_mhz = std.mem.readInt(u32, formatted[84..88], .little);
                        }
                        if (dimm.configured_speed_mhz == 0xFFFF) {
                            dimm.configured_speed_mhz = std.mem.readInt(u32, formatted[88..92], .little);
                        }
                    }

                    if (dimm.size_mb > 0) {
                        out.dimms[out.dimm_count] = dimm;
                        out.dimm_count += 1;
                    }
                }
            },
            127 => break, // End-of-table
            else => {},
        }

        pos = p;
    }

    return out;
}

fn getString(strings_block: []const u8, index_1based: u8) []const u8 {
    if (index_1based == 0) return "";
    var cur: u8 = 1;
    var start: usize = 0;
    while (start < strings_block.len) {
        const end = std.mem.indexOfScalarPos(u8, strings_block, start, 0) orelse strings_block.len;
        if (cur == index_1based) return strings_block[start..end];
        if (end + 1 >= strings_block.len or strings_block[end + 1] == 0) break;
        start = end + 1;
        cur += 1;
    }
    return "";
}

fn copyTrimmed(dest: []u8, out_len: *usize, src: []const u8) void {
    const trimmed = std.mem.trim(u8, src, " \t\r\n\x00");
    const n = @min(dest.len, trimmed.len);
    @memcpy(dest[0..n], trimmed[0..n]);
    out_len.* = n;
}

fn maskSerialInto(dest: []u8, out_len: *usize, raw_sn: []const u8) void {
    const trimmed = std.mem.trim(u8, raw_sn, " \t\r\n\x00");
    if (trimmed.len == 0) {
        copyTrimmed(dest, out_len, "N/A");
        return;
    }
    if (trimmed.len <= 4) {
        copyTrimmed(dest, out_len, "****");
        return;
    }
    const res = std.fmt.bufPrint(dest, "****{s}", .{trimmed[trimmed.len - 4 ..]}) catch "****";
    out_len.* = res.len;
}

test "SMBIOS parser extracts Type 2 baseboard and Type 17 DIMM cleanly" {
    var raw: [256]u8 = std.mem.zeroes([256]u8);
    // RawSMBIOSData header: major=3, minor=3
    raw[1] = 3;
    raw[2] = 3;

    var p: usize = 8;
    // Type 2 (Baseboard): len=8
    raw[p] = 2;
    raw[p + 1] = 8;
    raw[p + 4] = 1; // Manufacturer string #1
    raw[p + 5] = 2; // Product string #2
    raw[p + 6] = 3; // Version string #3
    p += 8;
    const s_board = "ASUSTeK\x00PRIME B660M-A\x00Rev 1.xx\x00\x00";
    @memcpy(raw[p .. p + s_board.len], s_board);
    p += s_board.len;

    // Type 17 (Memory Device): len=34, 16384 MB DDR4 @ 3200 MHz
    raw[p] = 17;
    raw[p + 1] = 34;
    std.mem.writeInt(u16, raw[p + 12 ..][0..2], 16384, .little);
    raw[p + 16] = 1; // slot
    raw[p + 18] = 0x1A; // DDR4
    std.mem.writeInt(u16, raw[p + 21 ..][0..2], 3200, .little);
    raw[p + 23] = 2; // mfg
    raw[p + 24] = 3; // sn
    raw[p + 26] = 4; // part
    std.mem.writeInt(u16, raw[p + 32 ..][0..2], 3200, .little);
    p += 34;
    const s_dimm = "DIMM_A2\x00Kingston\x00AB12CD34\x00KF432C16BB/16\x00\x00";
    @memcpy(raw[p .. p + s_dimm.len], s_dimm);
    p += s_dimm.len;

    // Type 127 End-of-table
    raw[p] = 127;
    raw[p + 1] = 4;
    p += 6;

    std.mem.writeInt(u32, raw[4..8], @intCast(p - 8), .little);

    const parsed = parseRawRsmb(raw[0..p]);
    try std.testing.expect(parsed.available);
    try std.testing.expectEqualStrings("ASUSTeK", parsed.boardManufacturer());
    try std.testing.expectEqualStrings("PRIME B660M-A", parsed.boardProduct());
    try std.testing.expectEqual(@as(usize, 1), parsed.dimm_count);
    try std.testing.expectEqual(@as(u64, 16384), parsed.dimms[0].size_mb);
    try std.testing.expectEqual(@as(u32, 3200), parsed.dimms[0].effectiveSpeedMhz());
    try std.testing.expectEqualStrings("DIMM_A2", parsed.dimms[0].slotSlice());
    try std.testing.expectEqualStrings("****CD34", parsed.dimms[0].serialMaskedSlice());
    try std.testing.expectEqual(@as(?u32, 3200), parsed.primaryMemorySpeedMhz());
}
