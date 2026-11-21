const std = @import("std");
const builtin = @import("builtin");
const win32 = @import("../../providers/windows/win32.zig");
const device_id = @import("../../core/device_id.zig");
const sensor = @import("../../core/sensor.zig");

/// 规范 §2.5 物理磁盘枚举模块。
/// 使用零访问权限句柄（dwDesiredAccess = 0）在普通用户权限下完成物理磁盘枚举、接口识别、容量查询与稳定 ID 生成，
/// 并明确标注 RAID / Storage Spaces / 虚拟机 / RST-VMD 等受限场景，绝不误报“正常”。
pub const MAX_DISKS = 32;

pub const DiskSupport = enum(u8) {
    nvme_native,
    sata_ata,
    usb_sat,
    unsupported_raid,
    unsupported_spaces,
    unsupported_virtual,
    unknown_bus,

    pub fn labelZh(self: DiskSupport) [:0]const u8 {
        return switch (self) {
            .nvme_native => "NVMe 原生接口",
            .sata_ata => "SATA/ATA（需管理员）",
            .usb_sat => "USB SAT 透传（需管理员）",
            .unsupported_raid => "RAID 阵列（不支持直读）",
            .unsupported_spaces => "存储空间虚拟盘（不支持）",
            .unsupported_virtual => "虚拟机磁盘（不支持）",
            .unknown_bus => "未知总线类型",
        };
    }

    pub fn isUnsupported(self: DiskSupport) bool {
        return switch (self) {
            .unsupported_raid, .unsupported_spaces, .unsupported_virtual, .unknown_bus => true,
            else => false,
        };
    }
};

pub const DiskDevice = struct {
    drive_index: u32 = 0,
    stable_id: device_id.StableId = .{},
    bus_type: win32.STORAGE_BUS_TYPE = .unknown,
    support: DiskSupport = .unknown_bus,

    vendor: [48]u8 = std.mem.zeroes([48]u8),
    vendor_len: usize = 0,
    model: [96]u8 = std.mem.zeroes([96]u8),
    model_len: usize = 0,
    firmware: [32]u8 = std.mem.zeroes([32]u8),
    firmware_len: usize = 0,
    serial_raw: [64]u8 = std.mem.zeroes([64]u8),
    serial_raw_len: usize = 0,
    serial_masked: [24]u8 = std.mem.zeroes([24]u8),
    serial_masked_len: usize = 0,

    capacity_bytes: ?u64 = null,
    removable: bool = false,

    // 预留给 P4/P5 填充的健康与温度状态（P3 诚实保持未知/N/A）
    health: sensor.HealthLevel = .unknown,
    temperature_c: ?i32 = null,
    temp_status: sensor.SensorStatus = .unknown,

    pub fn modelDisplay(self: *const DiskDevice, buf: []u8) []const u8 {
        const v = self.vendor[0..self.vendor_len];
        const m = self.model[0..self.model_len];
        if (v.len > 0 and m.len > 0) {
            // 若 model 已以 vendor 开头则不重复拼接
            if (std.mem.startsWith(u8, m, v)) {
                return m;
            }
            return std.fmt.bufPrint(buf, "{s} {s}", .{ v, m }) catch m;
        }
        if (m.len > 0) return m;
        if (v.len > 0) return v;
        return "未知磁盘";
    }

    pub fn firmwareSlice(self: *const DiskDevice) []const u8 {
        return if (self.firmware_len > 0) self.firmware[0..self.firmware_len] else "N/A";
    }

    pub fn serialMaskedSlice(self: *const DiskDevice) []const u8 {
        return if (self.serial_masked_len > 0) self.serial_masked[0..self.serial_masked_len] else "N/A";
    }
};

pub const DiskInventory = struct {
    disks: [MAX_DISKS]DiskDevice = [_]DiskDevice{.{}} ** MAX_DISKS,
    count: usize = 0,
    enumerated_utc_ms: i64 = 0,

    pub fn slice(self: *const DiskInventory) []const DiskDevice {
        return self.disks[0..self.count];
    }

    pub fn containsStableId(self: *const DiskInventory, id: device_id.StableId) bool {
        for (self.disks[0..self.count]) |d| {
            if (d.stable_id.eql(id)) return true;
        }
        return false;
    }
};

pub fn classifyBus(bus: win32.STORAGE_BUS_TYPE, model: []const u8) DiskSupport {
    // 检测虚拟机磁盘与 Intel RST/VMD 特征
    if (containsIgnoreCase(model, "VMware") or
        containsIgnoreCase(model, "VBOX") or
        containsIgnoreCase(model, "Virtual Disk") or
        containsIgnoreCase(model, "QEMU"))
    {
        return .unsupported_virtual;
    }
    if (containsIgnoreCase(model, "Intel Optane") or containsIgnoreCase(model, "RST")) {
        return .unsupported_raid;
    }

    return switch (bus) {
        .nvme => .nvme_native,
        .sata, .ata => .sata_ata,
        .usb => .usb_sat,
        .raid => .unsupported_raid,
        .spaces => .unsupported_spaces,
        .virtual, .file_backed_virtual => .unsupported_virtual,
        else => .unknown_bus,
    };
}

pub fn enumeratePhysicalDisks() DiskInventory {
    if (builtin.os.tag == .linux) {
        return @import("../../providers/linux/storage.zig").enumerateLinuxDisks();
    }
    var inv = DiskInventory{
        .enumerated_utc_ms = std.time.milliTimestamp(),
    };

    for (0..MAX_DISKS) |drive_idx| {
        if (inv.count >= MAX_DISKS) break;

        var path_utf8: [64]u8 = undefined;
        const path_slice = std.fmt.bufPrint(&path_utf8, "\\\\.\\PhysicalDrive{d}", .{drive_idx}) catch continue;
        var path_w: [65]u16 = undefined;
        const wlen = std.unicode.utf8ToUtf16Le(&path_w, path_slice) catch continue;
        path_w[wlen] = 0;

        // 零访问权限打开句柄（普通用户即可执行 IOCTL_STORAGE_QUERY_PROPERTY）
        const handle = win32.CreateFileW(
            @ptrCast(&path_w),
            0,
            win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE,
            null,
            win32.OPEN_EXISTING,
            0,
            null,
        );
        if (handle == win32.INVALID_HANDLE_VALUE) continue;
        defer _ = win32.CloseHandle(handle);

        var dev = DiskDevice{
            .drive_index = @intCast(drive_idx),
        };

        // 1. StorageDeviceProperty
        var query = win32.STORAGE_PROPERTY_QUERY{
            .PropertyId = win32.StorageDeviceProperty,
            .QueryType = win32.PropertyStandardQuery,
        };
        var desc_buf: [1024]u8 align(8) = std.mem.zeroes([1024]u8);
        var bytes_ret: win32.DWORD = 0;

        if (win32.DeviceIoControl(
            handle,
            win32.IOCTL_STORAGE_QUERY_PROPERTY,
            &query,
            @sizeOf(win32.STORAGE_PROPERTY_QUERY),
            &desc_buf,
            desc_buf.len,
            &bytes_ret,
            null,
        ) != 0 and bytes_ret >= @sizeOf(win32.STORAGE_DEVICE_DESCRIPTOR)) {
            const desc: *const win32.STORAGE_DEVICE_DESCRIPTOR = @ptrCast(@alignCast(&desc_buf));
            dev.bus_type = @enumFromInt(desc.BusType);
            dev.removable = desc.RemovableMedia != 0;

            copyStr(&dev.vendor, &dev.vendor_len, readCString(&desc_buf, desc.VendorIdOffset));
            copyStr(&dev.model, &dev.model_len, readCString(&desc_buf, desc.ProductIdOffset));
            copyStr(&dev.firmware, &dev.firmware_len, readCString(&desc_buf, desc.ProductRevisionOffset));
            copyStr(&dev.serial_raw, &dev.serial_raw_len, readCString(&desc_buf, desc.SerialNumberOffset));
            dev.serial_masked_len = device_id.maskSerial(dev.serial_raw[0..dev.serial_raw_len], &dev.serial_masked);

            var disp_buf: [160]u8 = undefined;
            const full_model = dev.modelDisplay(&disp_buf);
            dev.support = classifyBus(dev.bus_type, full_model);
            dev.stable_id = device_id.computeDiskId(
                dev.bus_type.name(),
                full_model,
                dev.serial_raw[0..dev.serial_raw_len],
                "",
                path_slice,
            );
        } else {
            dev.stable_id = device_id.computeDiskId("Other", "", "", "", path_slice);
        }

        // 2. 精确磁盘容量（优先 DISK_GEOMETRY_EX，备选 GET_LENGTH_INFO）
        var geom = win32.DISK_GEOMETRY_EX{};
        var geom_ret: win32.DWORD = 0;
        if (win32.DeviceIoControl(
            handle,
            win32.IOCTL_DISK_GET_DRIVE_GEOMETRY_EX,
            null,
            0,
            &geom,
            @sizeOf(win32.DISK_GEOMETRY_EX),
            &geom_ret,
            null,
        ) != 0 and geom.DiskSize > 0) {
            dev.capacity_bytes = @intCast(geom.DiskSize);
        } else {
            var len_info = win32.GET_LENGTH_INFORMATION{};
            var len_ret: win32.DWORD = 0;
            if (win32.DeviceIoControl(
                handle,
                win32.IOCTL_DISK_GET_LENGTH_INFO,
                null,
                0,
                &len_info,
                @sizeOf(win32.GET_LENGTH_INFORMATION),
                &len_ret,
                null,
            ) != 0 and len_info.Length > 0) {
                dev.capacity_bytes = @intCast(len_info.Length);
            }
        }

        // 规范 §10.2：按稳定设备 ID 去重，防止设备重复枚举
        if (dev.stable_id.is_stable and inv.containsStableId(dev.stable_id)) {
            continue;
        }

        inv.disks[inv.count] = dev;
        inv.count += 1;
    }

    return inv;
}

fn readCString(buf: []const u8, offset: u32) []const u8 {
    if (offset == 0 or offset >= buf.len) return "";
    const slice = buf[offset..];
    const nul = std.mem.indexOfScalar(u8, slice, 0) orelse slice.len;
    return std.mem.trim(u8, slice[0..nul], " \t\r\n");
}

fn copyStr(dest: []u8, out_len: *usize, src: []const u8) void {
    const n = @min(dest.len, src.len);
    @memcpy(dest[0..n], src[0..n]);
    out_len.* = n;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

test "classifyBus identifies unsupported virtual/RAID/Spaces disks accurately" {
    try std.testing.expectEqual(DiskSupport.nvme_native, classifyBus(.nvme, "WD Blue SN570 1TB SSD"));
    try std.testing.expectEqual(DiskSupport.usb_sat, classifyBus(.usb, "HIKSEMI USB 3.0"));
    try std.testing.expectEqual(DiskSupport.unsupported_raid, classifyBus(.raid, "PERC H730"));
    try std.testing.expectEqual(DiskSupport.unsupported_spaces, classifyBus(.spaces, "Microsoft Storage Space"));
    try std.testing.expectEqual(DiskSupport.unsupported_virtual, classifyBus(.scsi, "VMware Virtual disk"));
}

test "enumeratePhysicalDisks finds real local disks under standard user privilege" {
    const inv = enumeratePhysicalDisks();
    try std.testing.expect(inv.count >= 1);
    const d0 = inv.disks[0];
    try std.testing.expect(d0.model_len > 0);
    try std.testing.expectEqual(@as(usize, 16), d0.stable_id.slice().len);
    // Repeated enumeration yields identical stable ID
    const inv2 = enumeratePhysicalDisks();
    try std.testing.expectEqual(inv.count, inv2.count);
    try std.testing.expect(inv.disks[0].stable_id.eql(inv2.disks[0].stable_id));
}
