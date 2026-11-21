const std = @import("std");
const builtin = @import("builtin");
const win32 = @import("../../providers/windows/win32.zig");
const sensor = @import("../../core/sensor.zig");

/// ATA SMART 采集、解析与电源状态保护（规范 §2.5.1 / §2.5.3 / §2.5.4）。
/// 1. 读取 SMART 前必须先执行 CHECK POWER MODE (0xE5)，处于 Standby/Sleep 时默认跳过，绝不唤醒休眠硬盘。
/// 2. 严禁发送任何写入、自检、固件更新或 USB 桥接厂商私有命令（仅支持标准 IOCTL_ATA_PASS_THROUGH 与标准 T10 SAT）。
pub const MAX_ATA_ATTRS = 30;

pub const AtaAttribute = struct {
    id: u8 = 0,
    flags: u16 = 0,
    current: u8 = 0,
    worst: u8 = 0,
    threshold: u8 = 0,
    raw_bytes: [6]u8 = .{ 0, 0, 0, 0, 0, 0 },
    has_threshold: bool = false,

    /// Flags bit 0: 1 = Pre-fail, 0 = Old-age
    pub fn isPrefail(self: AtaAttribute) bool {
        return (self.flags & 0x0001) != 0;
    }

    pub fn rawU48(self: AtaAttribute) u64 {
        var v: u64 = 0;
        for (0..6) |i| {
            v |= @as(u64, self.raw_bytes[i]) << @intCast(i * 8);
        }
        return v;
    }

    pub fn rawLow16(self: AtaAttribute) u16 {
        return @as(u16, self.raw_bytes[0]) | (@as(u16, self.raw_bytes[1]) << 8);
    }

    pub fn knownNameZh(id: u8) []const u8 {
        return switch (id) {
            0x01 => "读取错误率",
            0x03 => "主轴起转时间",
            0x05 => "重映射扇区计数",
            0x07 => "寻道错误率",
            0x09 => "累计通电时间",
            0x0A => "起转重试计数",
            0x0C => "通电次数",
            0xAB => "编程失败计数",
            0xAC => "擦除失败计数",
            0xAD => "磨损均衡计数",
            0xB1 => "磨损差值",
            0xB4 => "未使用保留块计数",
            0xB8 => "端到端数据路径错误",
            0xBB => "报告不可校正错误",
            0xBC => "命令超时",
            0xBE => "气流温度",
            0xC1 => "磁头加载/卸载次数",
            0xC2 => "磁盘温度",
            0xC4 => "重映射事件计数",
            0xC5 => "当前待处理扇区",
            0xC6 => "离线不可校正扇区",
            0xC7 => "接口 CRC 传输错误",
            0xE7 => "SSD 剩余寿命",
            0xE9 => "介质磨损指标",
            0xF1 => "累计写入 LBA",
            0xF2 => "累计读取 LBA",
            else => "未知属性",
        };
    }
};

pub const AtaSmartData = struct {
    status: sensor.SensorStatus = .unknown,
    error_code: ?u32 = null,
    collected_utc_ms: i64 = 0,

    // SMART RETURN STATUS (0xDA): true 表示硬盘自身报告阈值超限
    smart_status_failed: bool = false,
    smart_status_checked: bool = false,

    // 原始 512B 数据页保留以供追溯
    raw_data_page: [512]u8 = std.mem.zeroes([512]u8),
    has_raw_data: bool = false,

    attrs: [MAX_ATA_ATTRS]AtaAttribute = [_]AtaAttribute{.{}} ** MAX_ATA_ATTRS,
    attr_count: usize = 0,

    pub fn findAttr(self: *const AtaSmartData, id: u8) ?AtaAttribute {
        for (self.attrs[0..self.attr_count]) |a| {
            if (a.id == id) return a;
        }
        return null;
    }

    pub fn temperatureCelsius(self: *const AtaSmartData) ?i32 {
        if (self.findAttr(0xC2)) |a| {
            const c: i32 = @as(i8, @bitCast(a.raw_bytes[0]));
            if (c >= -20 and c <= 120) return c;
        }
        if (self.findAttr(0xBE)) |a| {
            const c: i32 = @as(i8, @bitCast(a.raw_bytes[0]));
            if (c >= -20 and c <= 120) return c;
        }
        return null;
    }

    pub fn powerOnHours(self: *const AtaSmartData) ?u64 {
        if (self.findAttr(0x09)) |a| {
            // 仅取低 32 位避免部分厂商高 16 位夹带分钟/毫秒造成误解
            return std.mem.readInt(u32, a.raw_bytes[0..4], .little);
        }
        return null;
    }
};

/// 纯解析函数：解析 512 字节 ATA SMART READ DATA 页与可选 512 字节 THRESHOLDS 页
pub fn parseAtaSmartPages(data_page: *const [512]u8, threshold_page: ?*const [512]u8) AtaSmartData {
    var out = AtaSmartData{
        .status = .ok,
        .collected_utc_ms = std.time.milliTimestamp(),
        .raw_data_page = data_page.*,
        .has_raw_data = true,
    };

    var thr_map: [256]u8 = std.mem.zeroes([256]u8);
    var thr_present: [256]bool = [_]bool{false} ** 256;
    if (threshold_page) |tp| {
        for (0..30) |i| {
            const off = 2 + i * 12;
            const id = tp[off];
            if (id != 0) {
                thr_map[id] = tp[off + 1];
                thr_present[id] = true;
            }
        }
    }

    // 30 个属性条目从偏移 2 开始，每条 12 字节
    for (0..30) |i| {
        const off = 2 + i * 12;
        const id = data_page[off];
        if (id == 0) continue;

        var attr = AtaAttribute{
            .id = id,
            .flags = std.mem.readInt(u16, data_page[off + 1 ..][0..2], .little),
            .current = data_page[off + 3],
            .worst = data_page[off + 4],
            .threshold = if (thr_present[id]) thr_map[id] else 0,
            .has_threshold = thr_present[id],
        };
        @memcpy(&attr.raw_bytes, data_page[off + 5 .. off + 11]);

        if (out.attr_count < MAX_ATA_ATTRS) {
            out.attrs[out.attr_count] = attr;
            out.attr_count += 1;
        }
    }

    return out;
}

pub const PowerMode = enum {
    active_or_idle,
    standby_or_sleep,
    unknown,
};

/// 规范 §2.5.4：发送 ATA CHECK POWER MODE (0xE5)，避免唤醒休眠磁盘
pub fn checkAtaPowerMode(handle: win32.HANDLE) PowerMode {
    var ata = std.mem.zeroes(win32.ATA_PASS_THROUGH_EX);
    ata.Length = @sizeOf(win32.ATA_PASS_THROUGH_EX);
    ata.AtaFlags = win32.ATA_FLAGS_DRDY_REQUIRED;
    ata.TimeOutValue = 5;
    ata.CurrentTaskFile[6] = 0xE5; // CHECK POWER MODE

    var ret: win32.DWORD = 0;
    if (win32.DeviceIoControl(
        handle,
        win32.IOCTL_ATA_PASS_THROUGH,
        &ata,
        @sizeOf(win32.ATA_PASS_THROUGH_EX),
        &ata,
        @sizeOf(win32.ATA_PASS_THROUGH_EX),
        &ret,
        null,
    ) == 0) {
        return .unknown;
    }

    const sector_count = ata.CurrentTaskFile[1];
    return switch (sector_count) {
        0x00, 0x40, 0x41 => .standby_or_sleep,
        0x80, 0xFF => .active_or_idle,
        else => .unknown,
    };
}

/// 读取 SATA/ATA 或 USB SAT 磁盘 SMART 数据（含电源保护、权限区分与标准 T10 SAT 透传）
/// 严禁发送任何 USB 桥接芯片厂商私有命令（仅支持标准 IOCTL_ATA_PASS_THROUGH 与标准 T10 SAT 0x85）。
pub fn readAtaSmart(drive_index: u32, allow_wake_standby: bool) AtaSmartData {
    return readAtaSmartWithMode(drive_index, allow_wake_standby, false);
}

pub fn readAtaSmartWithMode(drive_index: u32, allow_wake_standby: bool, prefer_sat: bool) AtaSmartData {
    if (builtin.os.tag == .linux) {
        return @import("../../providers/linux/storage.zig").readLinuxAtaSmart(drive_index, allow_wake_standby);
    }
    var path_utf8: [64]u8 = undefined;
    const path_slice = std.fmt.bufPrint(&path_utf8, "\\\\.\\PhysicalDrive{d}", .{drive_index}) catch {
        return .{ .status = .transient_error };
    };
    var path_w: [65]u16 = undefined;
    const wlen = std.unicode.utf8ToUtf16Le(&path_w, path_slice) catch {
        return .{ .status = .transient_error };
    };
    path_w[wlen] = 0;

    // ATA/SAT pass-through 需要读写句柄（普通用户报 ERROR_ACCESS_DENIED = 5）
    const handle = win32.CreateFileW(
        @ptrCast(&path_w),
        win32.GENERIC_READ | win32.GENERIC_WRITE,
        win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE,
        null,
        win32.OPEN_EXISTING,
        0,
        null,
    );
    if (handle == win32.INVALID_HANDLE_VALUE) {
        const err = win32.GetLastError();
        return .{
            .status = if (err == 5) .access_denied else if (err == 2) .device_removed else .transient_error,
            .error_code = err,
            .collected_utc_ms = std.time.milliTimestamp(),
        };
    }
    defer _ = win32.CloseHandle(handle);

    if (prefer_sat) {
        const sat_res = readSmartViaSat(handle, allow_wake_standby);
        if (sat_res.status == .ok or sat_res.status == .device_standby) return sat_res;
        // 若 SAT 失败再尝试标准 ATA（部分 eSATA/桥接驱动直接支持）
        const ata_res = readSmartViaAta(handle, allow_wake_standby);
        if (ata_res.status == .ok or ata_res.status == .device_standby) return ata_res;
        return sat_res;
    } else {
        const ata_res = readSmartViaAta(handle, allow_wake_standby);
        if (ata_res.status == .ok or ata_res.status == .device_standby) return ata_res;
        // SATA 走 StorPort / SCSI miniport 时尝试标准 T10 SAT 回退
        const sat_res = readSmartViaSat(handle, allow_wake_standby);
        if (sat_res.status == .ok or sat_res.status == .device_standby) return sat_res;
        return ata_res;
    }
}

fn readSmartViaAta(handle: win32.HANDLE, allow_wake_standby: bool) AtaSmartData {
    // 1. 磁盘电源状态保护（默认不唤醒休眠磁盘）
    if (!allow_wake_standby) {
        if (checkAtaPowerMode(handle) == .standby_or_sleep) {
            return .{
                .status = .device_standby,
                .collected_utc_ms = std.time.milliTimestamp(),
            };
        }
    }

    // 2. SMART READ DATA (0xB0 / Feature 0xD0)
    var data_page: [512]u8 = undefined;
    const read_err = ataSmartReadPage(handle, 0xD0, &data_page);
    if (read_err != 0) {
        return .{
            .status = if (read_err == 1 or read_err == 50) .unsupported else .transient_error,
            .error_code = read_err,
            .collected_utc_ms = std.time.milliTimestamp(),
        };
    }

    // 3. SMART READ THRESHOLDS (0xB0 / Feature 0xD1)
    var thr_page: [512]u8 = undefined;
    const has_thr = (ataSmartReadPage(handle, 0xD1, &thr_page) == 0);

    var result = parseAtaSmartPages(&data_page, if (has_thr) &thr_page else null);

    // 4. SMART RETURN STATUS (0xB0 / Feature 0xDA)
    var st = std.mem.zeroes(win32.ATA_PASS_THROUGH_EX);
    st.Length = @sizeOf(win32.ATA_PASS_THROUGH_EX);
    st.AtaFlags = win32.ATA_FLAGS_DRDY_REQUIRED;
    st.TimeOutValue = 5;
    st.CurrentTaskFile[0] = 0xDA; // Feature: SMART RETURN STATUS
    st.CurrentTaskFile[3] = 0x4F; // LBA Mid
    st.CurrentTaskFile[4] = 0xC2; // LBA High
    st.CurrentTaskFile[6] = 0xB0; // Command: SMART
    var ret: win32.DWORD = 0;
    if (win32.DeviceIoControl(handle, win32.IOCTL_ATA_PASS_THROUGH, &st, @sizeOf(win32.ATA_PASS_THROUGH_EX), &st, @sizeOf(win32.ATA_PASS_THROUGH_EX), &ret, null) != 0) {
        result.smart_status_checked = true;
        result.smart_status_failed = (st.CurrentTaskFile[3] == 0xF4 and st.CurrentTaskFile[4] == 0x2C);
    }

    return result;
}

/// 构造标准 T10 SAT ATA PASS-THROUGH (16) CDB (Opcode 0x85)
pub fn buildSat16Cdb(protocol_field: u8, flags: u8, feature: u8, sector_count: u8, lba_mid: u8, lba_high: u8, command: u8) [16]u8 {
    return .{
        0x85, // ATA PASS-THROUGH (16)
        protocol_field, // (protocol << 1)
        flags, // T_DIR / BYTE_BLOCK / T_LENGTH / CK_COND
        0x00,
        feature,
        0x00,
        sector_count,
        0x00,
        0x00, // LBA Low
        0x00,
        lba_mid,
        0x00,
        lba_high,
        0x00, // Device
        command,
        0x00, // Control
    };
}

const SatRequestBuf = extern struct {
    sptd: win32.SCSI_PASS_THROUGH_DIRECT = .{},
    _align_pad: [8]u8 = std.mem.zeroes([8]u8),
    sense: [64]u8 = std.mem.zeroes([64]u8),
};

/// 标准 T10 SAT CHECK POWER MODE (0xE5)，避免唤醒休眠 USB/SATA 移动硬盘
fn checkSatPowerMode(handle: win32.HANDLE) PowerMode {
    var req = SatRequestBuf{};
    req.sptd.Length = @sizeOf(win32.SCSI_PASS_THROUGH_DIRECT);
    req.sptd.CdbLength = 16;
    req.sptd.SenseInfoLength = @sizeOf(@TypeOf(req.sense));
    req.sptd.DataIn = win32.SCSI_IOCTL_DATA_UNSPECIFIED;
    req.sptd.DataTransferLength = 0;
    req.sptd.TimeOutValue = 5;
    req.sptd.DataBuffer = null;
    req.sptd.SenseInfoOffset = @offsetOf(SatRequestBuf, "sense");
    // Protocol = 3 (Non-data -> 3<<1 = 0x06), CK_COND = 0x20
    req.sptd.Cdb = buildSat16Cdb(0x06, 0x20, 0x00, 0x00, 0x00, 0x00, 0xE5);

    var ret: win32.DWORD = 0;
    if (win32.DeviceIoControl(handle, win32.IOCTL_SCSI_PASS_THROUGH_DIRECT, &req, @sizeOf(SatRequestBuf), &req, @sizeOf(SatRequestBuf), &ret, null) == 0) {
        return .unknown;
    }

    // 解析 ATA Status Return Descriptor (Descriptor format sense: code 0x72/0x73, descriptor type 0x09)
    if (req.sense[0] == 0x72 or req.sense[0] == 0x73) {
        if (req.sense[7] >= 14 and req.sense[8] == 0x09) {
            const sector_count = req.sense[13];
            return switch (sector_count) {
                0x00, 0x40, 0x41 => .standby_or_sleep,
                0x80, 0xFF => .active_or_idle,
                else => .unknown,
            };
        }
    }
    return .unknown;
}

fn satSmartReadPage(handle: win32.HANDLE, feature: u8, out_512: *[512]u8) win32.DWORD {
    var req = SatRequestBuf{};
    req.sptd.Length = @sizeOf(win32.SCSI_PASS_THROUGH_DIRECT);
    req.sptd.CdbLength = 16;
    req.sptd.SenseInfoLength = @sizeOf(@TypeOf(req.sense));
    req.sptd.DataIn = win32.SCSI_IOCTL_DATA_IN;
    req.sptd.DataTransferLength = 512;
    req.sptd.TimeOutValue = 5;
    req.sptd.DataBuffer = out_512;
    req.sptd.SenseInfoOffset = @offsetOf(SatRequestBuf, "sense");
    // Protocol = 4 (PIO Data-In -> 4<<1 = 0x08), Flags = T_DIR(1<<3) | BYTE_BLOCK(1<<2) | T_LENGTH=2 (sector count) = 0x0E
    req.sptd.Cdb = buildSat16Cdb(0x08, 0x0E, feature, 1, 0x4F, 0xC2, 0xB0);

    var ret: win32.DWORD = 0;
    if (win32.DeviceIoControl(handle, win32.IOCTL_SCSI_PASS_THROUGH_DIRECT, &req, @sizeOf(SatRequestBuf), &req, @sizeOf(SatRequestBuf), &ret, null) == 0) {
        return win32.GetLastError();
    }
    if (req.sptd.ScsiStatus != 0 and req.sptd.ScsiStatus != 2) {
        return 50; // ERROR_NOT_SUPPORTED
    }
    return 0;
}

fn readSmartViaSat(handle: win32.HANDLE, allow_wake_standby: bool) AtaSmartData {
    if (!allow_wake_standby) {
        if (checkSatPowerMode(handle) == .standby_or_sleep) {
            return .{
                .status = .device_standby,
                .collected_utc_ms = std.time.milliTimestamp(),
            };
        }
    }

    var data_page: [512]u8 = std.mem.zeroes([512]u8);
    const read_err = satSmartReadPage(handle, 0xD0, &data_page);
    if (read_err != 0) {
        return .{
            .status = if (read_err == 1 or read_err == 50) .unsupported else .transient_error,
            .error_code = read_err,
            .collected_utc_ms = std.time.milliTimestamp(),
        };
    }

    // 校验返回页至少包含 1 个有效 SMART 属性，避免 USB 桥接返回全零假页
    var thr_page: [512]u8 = std.mem.zeroes([512]u8);
    const has_thr = (satSmartReadPage(handle, 0xD1, &thr_page) == 0);
    const parsed = parseAtaSmartPages(&data_page, if (has_thr) &thr_page else null);
    if (parsed.attr_count == 0) {
        return .{
            .status = .unsupported,
            .error_code = 50,
            .collected_utc_ms = std.time.milliTimestamp(),
        };
    }
    return parsed;
}

fn ataSmartReadPage(handle: win32.HANDLE, feature: u8, out_512: *[512]u8) win32.DWORD {
    const buf_size = @sizeOf(win32.ATA_PASS_THROUGH_EX) + 512;
    var buf: [buf_size]u8 align(8) = std.mem.zeroes([buf_size]u8);
    const ata: *win32.ATA_PASS_THROUGH_EX = @ptrCast(@alignCast(&buf));
    ata.Length = @sizeOf(win32.ATA_PASS_THROUGH_EX);
    ata.AtaFlags = win32.ATA_FLAGS_DRDY_REQUIRED | win32.ATA_FLAGS_DATA_IN;
    ata.DataTransferLength = 512;
    ata.TimeOutValue = 5;
    ata.DataBufferOffset = @sizeOf(win32.ATA_PASS_THROUGH_EX);
    ata.CurrentTaskFile[0] = feature;
    ata.CurrentTaskFile[1] = 1; // Sector count
    ata.CurrentTaskFile[3] = 0x4F; // SMART signature low
    ata.CurrentTaskFile[4] = 0xC2; // SMART signature high
    ata.CurrentTaskFile[6] = 0xB0; // ATA SMART command

    var ret: win32.DWORD = 0;
    if (win32.DeviceIoControl(handle, win32.IOCTL_ATA_PASS_THROUGH, &buf, buf_size, &buf, buf_size, &ret, null) == 0) {
        return win32.GetLastError();
    }
    @memcpy(out_512, buf[@sizeOf(win32.ATA_PASS_THROUGH_EX)..][0..512]);
    return 0;
}

/// V2.0 可选主动 SMART 短自检（ATA SMART EXECUTE OFF-LINE IMMEDIATE, Feature 0xD4, LBA Low 0x01）。
/// 严格遵守 AGENTS.md V2.0 安全边界：仅在用户于界面明确点击二次确认后调用，绝不自动执行！
pub fn triggerAtaShortSelfTest(drive_index: u32) enum { started, access_denied, unsupported, failed } {
    if (builtin.os.tag != .windows) return .unsupported;
    var path_utf8: [64]u8 = undefined;
    const path_slice = std.fmt.bufPrint(&path_utf8, "\\\\.\\PhysicalDrive{d}", .{drive_index}) catch return .failed;
    var path_w: [65]u16 = undefined;
    const wlen = std.unicode.utf8ToUtf16Le(&path_w, path_slice) catch return .failed;
    path_w[wlen] = 0;

    const handle = win32.CreateFileW(
        @ptrCast(&path_w),
        win32.GENERIC_READ | win32.GENERIC_WRITE,
        win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE,
        null,
        win32.OPEN_EXISTING,
        0,
        null,
    );
    if (handle == win32.INVALID_HANDLE_VALUE) {
        return if (win32.GetLastError() == 5) .access_denied else .failed;
    }
    defer _ = win32.CloseHandle(handle);

    var ata = std.mem.zeroes(win32.ATA_PASS_THROUGH_EX);
    ata.Length = @sizeOf(win32.ATA_PASS_THROUGH_EX);
    ata.AtaFlags = win32.ATA_FLAGS_DRDY_REQUIRED;
    ata.TimeOutValue = 5;
    ata.CurrentTaskFile[0] = 0xD4; // Feature: EXECUTE OFF-LINE IMMEDIATE
    ata.CurrentTaskFile[2] = 0x01; // LBA Low: Short Self-test routine (captive=off)
    ata.CurrentTaskFile[3] = 0x4F;
    ata.CurrentTaskFile[4] = 0xC2;
    ata.CurrentTaskFile[6] = 0xB0;

    var ret: win32.DWORD = 0;
    if (win32.DeviceIoControl(handle, win32.IOCTL_ATA_PASS_THROUGH, &ata, @sizeOf(win32.ATA_PASS_THROUGH_EX), &ata, @sizeOf(win32.ATA_PASS_THROUGH_EX), &ret, null) == 0) {
        const err = win32.GetLastError();
        return if (err == 1 or err == 50) .unsupported else .failed;
    }
    return .started;
}

test "parseAtaSmartPages extracts Prefail/Old-age flags, Current/Worst/Threshold, and 48-bit raw values" {
    var data: [512]u8 = std.mem.zeroes([512]u8);
    var thrs: [512]u8 = std.mem.zeroes([512]u8);

    // Slot 0: ID 0x05 (Reallocated Sectors), Prefail (flag=0x0033), Current=98, Worst=98, Raw=4
    data[2] = 0x05;
    std.mem.writeInt(u16, data[3..5], 0x0033, .little);
    data[5] = 98;
    data[6] = 98;
    data[7] = 4;
    thrs[2] = 0x05;
    thrs[3] = 36;

    // Slot 1: ID 0xC2 (Temperature), Old-age (flag=0x0022), Current=66, Worst=52, Raw=34°C
    data[14] = 0xC2;
    std.mem.writeInt(u16, data[15..17], 0x0022, .little);
    data[17] = 66;
    data[18] = 52;
    data[19] = 34;

    // Slot 2: ID 0x09 (Power-On Hours), Raw = 12345 hours
    data[26] = 0x09;
    std.mem.writeInt(u16, data[27..29], 0x0032, .little);
    data[29] = 90;
    data[30] = 90;
    std.mem.writeInt(u32, data[31..35], 12345, .little);

    const parsed = parseAtaSmartPages(&data, &thrs);
    try std.testing.expectEqual(@as(usize, 3), parsed.attr_count);

    const a05 = parsed.findAttr(0x05).?;
    try std.testing.expect(a05.isPrefail());
    try std.testing.expectEqual(@as(u8, 98), a05.current);
    try std.testing.expectEqual(@as(u8, 36), a05.threshold);
    try std.testing.expectEqual(@as(u64, 4), a05.rawU48());

    const ac2 = parsed.findAttr(0xC2).?;
    try std.testing.expect(!ac2.isPrefail());
    try std.testing.expectEqual(@as(?i32, 34), parsed.temperatureCelsius());
    try std.testing.expectEqual(@as(?u64, 12345), parsed.powerOnHours());

    // T10 SAT ATA PASS-THROUGH (16) CDB layout check
    const cdb = buildSat16Cdb(0x08, 0x0E, 0xD0, 1, 0x4F, 0xC2, 0xB0);
    try std.testing.expectEqual(@as(u8, 0x85), cdb[0]);
    try std.testing.expectEqual(@as(u8, 0xD0), cdb[4]);
    try std.testing.expectEqual(@as(u8, 0x4F), cdb[10]);
    try std.testing.expectEqual(@as(u8, 0xC2), cdb[12]);
    try std.testing.expectEqual(@as(u8, 0xB0), cdb[14]);
}
