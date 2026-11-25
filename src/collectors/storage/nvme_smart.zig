const std = @import("std");
const builtin = @import("builtin");
const win32 = @import("../../providers/windows/win32.zig");
const sensor = @import("../../core/sensor.zig");

/// NVMe SMART / Health Information (Log Page 02h) 与 Identify Controller (WCTEMP/CCTEMP) 采集与解析。
/// P0 已实测：在 Windows 11 普通用户权限下以 dwDesiredAccess = 0 打开句柄即可完整读取。
pub const NvmeSmartData = struct {
    status: sensor.SensorStatus = .unknown,
    error_code: ?u32 = null,
    collected_utc_ms: i64 = 0,

    // Raw 512-byte Log Page 02h for traceability (规范 §5.2)
    raw_log02: [512]u8 = std.mem.zeroes([512]u8),
    has_raw_log02: bool = false,

    // Parsed Log Page 02h fields (§2.5.2)
    critical_warning: u8 = 0,
    composite_temp_k: u16 = 0,
    composite_temp_c: ?i32 = null,
    available_spare: u8 = 0,
    available_spare_threshold: u8 = 0,
    percentage_used: u8 = 0,

    data_units_read: u128 = 0, // 1 unit = 1000 * 512 bytes
    data_units_written: u128 = 0,
    host_read_commands: u128 = 0,
    host_write_commands: u128 = 0,
    controller_busy_time_min: u128 = 0,
    power_cycles: u128 = 0,
    power_on_hours: u128 = 0,
    unsafe_shutdowns: u128 = 0,
    media_errors: u128 = 0,
    error_log_entries: u128 = 0,

    warning_temp_time_min: u32 = 0,
    critical_temp_time_min: u32 = 0,
    temp_sensors_c: [8]?i32 = .{ null, null, null, null, null, null, null, null },

    // From Identify Controller CNS 01h (0 = not reported)
    wctemp_c: ?i32 = null,
    cctemp_c: ?i32 = null,

    pub fn bytesReadTB(self: *const NvmeSmartData) f64 {
        return (@as(f64, @floatFromInt(self.data_units_read)) * 512_000.0) / 1_000_000_000_000.0;
    }

    pub fn bytesWrittenTB(self: *const NvmeSmartData) f64 {
        return (@as(f64, @floatFromInt(self.data_units_written)) * 512_000.0) / 1_000_000_000_000.0;
    }
};

/// 纯解析函数：将 512 字节 NVMe Log Page 02h 转为结构化数据（便于单元测试与样本对照）
pub fn parseLogPage02(raw: *const [512]u8) NvmeSmartData {
    var out = NvmeSmartData{
        .status = .ok,
        .collected_utc_ms = std.time.milliTimestamp(),
        .raw_log02 = raw.*,
        .has_raw_log02 = true,
    };

    const log: *const win32.NVME_HEALTH_INFO_LOG = @ptrCast(@alignCast(raw));
    out.critical_warning = log.CriticalWarning;
    out.composite_temp_k = log.compositeTempKelvin();
    if (out.composite_temp_k >= 200 and out.composite_temp_k <= 500) {
        out.composite_temp_c = @as(i32, out.composite_temp_k) - 273;
    }
    out.available_spare = log.AvailableSpare;
    out.available_spare_threshold = log.AvailableSpareThreshold;
    out.percentage_used = log.PercentageUsed;

    out.data_units_read = win32.NVME_HEALTH_INFO_LOG.readU128(log.DataUnitRead);
    out.data_units_written = win32.NVME_HEALTH_INFO_LOG.readU128(log.DataUnitWritten);
    out.host_read_commands = win32.NVME_HEALTH_INFO_LOG.readU128(log.HostReadCommands);
    out.host_write_commands = win32.NVME_HEALTH_INFO_LOG.readU128(log.HostWrittenCommands);
    out.controller_busy_time_min = win32.NVME_HEALTH_INFO_LOG.readU128(log.ControllerBusyTime);
    out.power_cycles = win32.NVME_HEALTH_INFO_LOG.readU128(log.PowerCycle);
    out.power_on_hours = win32.NVME_HEALTH_INFO_LOG.readU128(log.PowerOnHours);
    out.unsafe_shutdowns = win32.NVME_HEALTH_INFO_LOG.readU128(log.UnsafeShutdowns);
    out.media_errors = win32.NVME_HEALTH_INFO_LOG.readU128(log.MediaErrors);
    out.error_log_entries = win32.NVME_HEALTH_INFO_LOG.readU128(log.ErrorInfoLogEntryCount);

    out.warning_temp_time_min = log.WarningCompositeTemperatureTime;
    out.critical_temp_time_min = log.CriticalCompositeTemperatureTime;

    for (0..8) |i| {
        const k = log.TemperatureSensor[i];
        if (k >= 200 and k <= 500) {
            out.temp_sensors_c[i] = @as(i32, k) - 273;
        }
    }

    return out;
}

/// 读取指定物理磁盘的 NVMe SMART Log Page 02h 与 Identify Controller WCTEMP/CCTEMP
pub fn readNvmeSmart(drive_index: u32) NvmeSmartData {
    if (builtin.os.tag == .linux) {
        return @import("../../providers/linux/storage.zig").readLinuxNvmeSmart(drive_index);
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

    // 关键（P0 实测）：必须以 dwDesiredAccess = 0 打开，普通用户即可读取 NVMe ProtocolSpecificProperty
    const handle = win32.CreateFileW(
        @ptrCast(&path_w),
        0,
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

    // 1. Log Page 02h (512 bytes)
    const header_off = @offsetOf(win32.STORAGE_PROPERTY_QUERY, "AdditionalParameters");
    const total_size = header_off + @sizeOf(win32.STORAGE_PROTOCOL_SPECIFIC_DATA) + 512;
    var buf: [total_size]u8 align(8) = std.mem.zeroes([total_size]u8);

    const pq: *win32.STORAGE_PROPERTY_QUERY = @ptrCast(@alignCast(&buf));
    pq.PropertyId = win32.StorageDeviceProtocolSpecificProperty;
    pq.QueryType = win32.PropertyStandardQuery;

    const proto: *win32.STORAGE_PROTOCOL_SPECIFIC_DATA = @ptrCast(@alignCast(buf[header_off..].ptr));
    proto.ProtocolType = win32.ProtocolTypeNvme;
    proto.DataType = win32.NVMeDataTypeLogPage;
    proto.ProtocolDataRequestValue = win32.NVME_LOG_PAGE_HEALTH_INFO;
    proto.ProtocolDataRequestSubValue = 0;
    proto.ProtocolDataOffset = @sizeOf(win32.STORAGE_PROTOCOL_SPECIFIC_DATA);
    proto.ProtocolDataLength = 512;

    var ret: win32.DWORD = 0;
    if (win32.DeviceIoControl(handle, win32.IOCTL_STORAGE_QUERY_PROPERTY, &buf, total_size, &buf, total_size, &ret, null) == 0) {
        const err = win32.GetLastError();
        return .{
            .status = if (err == 5) .access_denied else if (err == 1 or err == 50) .unsupported else .transient_error,
            .error_code = err,
            .collected_utc_ms = std.time.milliTimestamp(),
        };
    }

    const out_desc: *const win32.STORAGE_PROTOCOL_DATA_DESCRIPTOR = @ptrCast(@alignCast(&buf));
    const data_start = @offsetOf(win32.STORAGE_PROTOCOL_DATA_DESCRIPTOR, "ProtocolSpecificData") + out_desc.ProtocolSpecificData.ProtocolDataOffset;
    if (data_start + 512 > buf.len) {
        return .{ .status = .transient_error, .collected_utc_ms = std.time.milliTimestamp() };
    }

    var aligned_log: [512]u8 align(8) = undefined;
    @memcpy(&aligned_log, buf[data_start .. data_start + 512]);
    var result = parseLogPage02(&aligned_log);

    // 2. Identify Controller (CNS 01h) 获取 WCTEMP / CCTEMP
    const id_total = header_off + @sizeOf(win32.STORAGE_PROTOCOL_SPECIFIC_DATA) + 4096;
    var id_buf: [id_total]u8 align(8) = std.mem.zeroes([id_total]u8);
    const id_pq: *win32.STORAGE_PROPERTY_QUERY = @ptrCast(@alignCast(&id_buf));
    id_pq.PropertyId = win32.StorageDeviceProtocolSpecificProperty;
    id_pq.QueryType = win32.PropertyStandardQuery;

    const id_proto: *win32.STORAGE_PROTOCOL_SPECIFIC_DATA = @ptrCast(@alignCast(id_buf[header_off..].ptr));
    id_proto.ProtocolType = win32.ProtocolTypeNvme;
    id_proto.DataType = win32.NVMeDataTypeIdentify;
    id_proto.ProtocolDataRequestValue = win32.NVME_IDENTIFY_CNS_CONTROLLER;
    id_proto.ProtocolDataOffset = @sizeOf(win32.STORAGE_PROTOCOL_SPECIFIC_DATA);
    id_proto.ProtocolDataLength = 4096;

    var id_ret: win32.DWORD = 0;
    if (win32.DeviceIoControl(handle, win32.IOCTL_STORAGE_QUERY_PROPERTY, &id_buf, id_total, &id_buf, id_total, &id_ret, null) != 0) {
        const id_out: *const win32.STORAGE_PROTOCOL_DATA_DESCRIPTOR = @ptrCast(@alignCast(&id_buf));
        const dstart = @offsetOf(win32.STORAGE_PROTOCOL_DATA_DESCRIPTOR, "ProtocolSpecificData") + id_out.ProtocolSpecificData.ProtocolDataOffset;
        if (dstart + @sizeOf(win32.NVME_IDENTIFY_CONTROLLER_HEAD) <= id_buf.len) {
            const id_head: *const win32.NVME_IDENTIFY_CONTROLLER_HEAD = @ptrCast(@alignCast(id_buf[dstart..].ptr));
            result.wctemp_c = id_head.wctempCelsius();
            result.cctemp_c = id_head.cctempCelsius();
        }
    }

    return result;
}

/// 通过 Windows StorageDeviceTemperatureProperty 读取存储温度描述符（备选温度源）
pub const StorageTempDescriptor = struct {
    available: bool = false,
    temp_c: ?i32 = null,
    warning_c: ?i32 = null,
    critical_c: ?i32 = null,
};

pub fn readStorageTemperature(drive_index: u32) StorageTempDescriptor {
    if (builtin.os.tag != .windows) return .{};
    var path_utf8: [64]u8 = undefined;
    const path_slice = std.fmt.bufPrint(&path_utf8, "\\\\.\\PhysicalDrive{d}", .{drive_index}) catch return .{};
    var path_w: [65]u16 = undefined;
    const wlen = std.unicode.utf8ToUtf16Le(&path_w, path_slice) catch return .{};
    path_w[wlen] = 0;

    const handle = win32.CreateFileW(@ptrCast(&path_w), 0, win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE, null, win32.OPEN_EXISTING, 0, null);
    if (handle == win32.INVALID_HANDLE_VALUE) return .{};
    defer _ = win32.CloseHandle(handle);

    var tq = win32.STORAGE_PROPERTY_QUERY{
        .PropertyId = win32.StorageDeviceTemperatureProperty,
        .QueryType = win32.PropertyStandardQuery,
    };
    var tbuf: [512]u8 align(8) = std.mem.zeroes([512]u8);
    var tret: win32.DWORD = 0;
    if (win32.DeviceIoControl(handle, win32.IOCTL_STORAGE_QUERY_PROPERTY, &tq, @sizeOf(win32.STORAGE_PROPERTY_QUERY), &tbuf, tbuf.len, &tret, null) == 0) {
        return .{};
    }

    const td: *const win32.STORAGE_TEMPERATURE_DATA_DESCRIPTOR = @ptrCast(@alignCast(&tbuf));
    if (td.InfoCount == 0) return .{};

    var res = StorageTempDescriptor{ .available = true };
    const t0 = td.TemperatureInfo[0].Temperature;
    if (t0 != win32.STORAGE_TEMPERATURE_VALUE_NOT_REPORTED) res.temp_c = t0;
    if (td.WarningTemperature != win32.STORAGE_TEMPERATURE_VALUE_NOT_REPORTED) res.warning_c = td.WarningTemperature;
    if (td.CriticalTemperature != win32.STORAGE_TEMPERATURE_VALUE_NOT_REPORTED) res.critical_c = td.CriticalTemperature;
    return res;
}

test "parseLogPage02 parses 512-byte NVMe SMART binary fixture accurately" {
    var raw: [512]u8 align(8) = std.mem.zeroes([512]u8);
    raw[0] = 0x05; // bit 0 (spare) + bit 2 (reliability)
    std.mem.writeInt(u16, raw[1..3], 315, .little); // 42°C
    raw[3] = 8; // Available Spare = 8%
    raw[4] = 10; // Threshold = 10%
    raw[5] = 85; // Percentage Used = 85%
    std.mem.writeInt(u128, raw[32..48], 2_000_000, .little); // 1.024 TB read
    std.mem.writeInt(u128, raw[48..64], 10_000_000, .little); // 5.12 TB written
    std.mem.writeInt(u128, raw[128..144], 1500, .little); // 1500 power-on hours
    std.mem.writeInt(u128, raw[160..176], 3, .little); // 3 media errors
    std.mem.writeInt(u16, raw[200..202], 320, .little); // Sensor 1 = 47°C

    const parsed = parseLogPage02(&raw);
    try std.testing.expectEqual(sensor.SensorStatus.ok, parsed.status);
    try std.testing.expectEqual(@as(u8, 0x05), parsed.critical_warning);
    try std.testing.expectEqual(@as(?i32, 42), parsed.composite_temp_c);
    try std.testing.expectEqual(@as(u8, 8), parsed.available_spare);
    try std.testing.expectEqual(@as(u8, 10), parsed.available_spare_threshold);
    try std.testing.expectEqual(@as(u8, 85), parsed.percentage_used);
    try std.testing.expectEqual(@as(u128, 1500), parsed.power_on_hours);
    try std.testing.expectEqual(@as(u128, 3), parsed.media_errors);
    try std.testing.expectEqual(@as(?i32, 47), parsed.temp_sensors_c[0]);
    try std.testing.expectApproxEqAbs(@as(f64, 5.12), parsed.bytesWrittenTB(), 1e-6);
}

test "NVME_IDENTIFY_CONTROLLER_HEAD parses WCTEMP and CCTEMP at comptime-verified offsets" {
    var raw: [270]u8 align(2) = std.mem.zeroes([270]u8);
    std.mem.writeInt(u16, raw[266..268], 353, .little); // 80°C
    std.mem.writeInt(u16, raw[268..270], 358, .little); // 85°C
    const head: *const win32.NVME_IDENTIFY_CONTROLLER_HEAD = @ptrCast(@alignCast(&raw));
    try std.testing.expectEqual(@as(?i32, 80), head.wctempCelsius());
    try std.testing.expectEqual(@as(?i32, 85), head.cctempCelsius());
}
