//! Linux 物理磁盘枚举与 SMART 采集模块（sysfs + NVME_IOCTL_ADMIN_CMD + 标准 T10 SAT SG_IO）。
//! 1. 通过 `/sys/block/{sd*,nvme*}` 零权限枚举全部物理磁盘型号、容量、接口、固件与跨重启稳定 ID；
//! 2. NVMe 走内核标准 `NVME_IOCTL_ADMIN_CMD` 读取 Log Page 02h 与 Identify Controller，复用 `nvme_smart.parseLogPage02`；
//! 3. SATA / USB SAT 走标准只读 `SG_IO` (`ATA PASS-THROUGH 16`, CDB `0x85`)，先查 `CHECK POWER MODE (0xE5)` 防唤醒，
//!    复用 `ata_smart.parseAtaSmartPages` 并接入全部 21 条健康判定规则。
const std = @import("std");
const linux = std.os.linux;
const win32 = @import("../windows/win32.zig");
const device_id = @import("../../core/device_id.zig");
const sensor = @import("../../core/sensor.zig");
const storage_enum = @import("../../collectors/storage/enumerate.zig");
const nvme_smart = @import("../../collectors/storage/nvme_smart.zig");
const ata_smart = @import("../../collectors/storage/ata_smart.zig");

/// 记录磁盘索引到 Linux 设备名（如 "sda"、"sdb"、"nvme0n1"）的线程安全映射缓存
var g_dev_names_mutex: std.Thread.Mutex = .{};
var g_dev_names: [storage_enum.MAX_DISKS][32]u8 = [_][32]u8{std.mem.zeroes([32]u8)} ** storage_enum.MAX_DISKS;
var g_dev_name_lens: [storage_enum.MAX_DISKS]usize = [_]usize{0} ** storage_enum.MAX_DISKS;

fn setDevName(idx: usize, name: []const u8) void {
    if (idx >= storage_enum.MAX_DISKS) return;
    g_dev_names_mutex.lock();
    defer g_dev_names_mutex.unlock();
    const n = @min(g_dev_names[idx].len, name.len);
    @memcpy(g_dev_names[idx][0..n], name[0..n]);
    g_dev_name_lens[idx] = n;
}

pub fn getDevName(idx: u32, out_buf: *[32]u8) ?[]const u8 {
    if (idx >= storage_enum.MAX_DISKS) return null;
    g_dev_names_mutex.lock();
    defer g_dev_names_mutex.unlock();
    const n = g_dev_name_lens[idx];
    if (n == 0) return null;
    @memcpy(out_buf[0..n], g_dev_names[idx][0..n]);
    return out_buf[0..n];
}

pub fn enumerateLinuxDisks() storage_enum.DiskInventory {
    var inv = storage_enum.DiskInventory{
        .enumerated_utc_ms = std.time.milliTimestamp(),
    };

    var dir = std.fs.openDirAbsolute("/sys/block", .{ .iterate = true }) catch return inv;
    defer dir.close();

    // 收集并按名称排序（保证 sda, sdb, nvme0n1 顺序稳定）
    var names: [storage_enum.MAX_DISKS][32]u8 = undefined;
    var name_lens: [storage_enum.MAX_DISKS]usize = undefined;
    var found: usize = 0;

    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (found >= storage_enum.MAX_DISKS) break;
        const nm = entry.name;
        const ok = std.mem.startsWith(u8, nm, "sd") or
            std.mem.startsWith(u8, nm, "nvme") or
            std.mem.startsWith(u8, nm, "vd");
        if (!ok) continue;
        const n = @min(32, nm.len);
        @memcpy(names[found][0..n], nm[0..n]);
        name_lens[found] = n;
        found += 1;
    }

    // 简单冒泡排序保持字典序稳定
    for (0..found) |i| {
        for (i + 1..found) |j| {
            if (std.mem.order(u8, names[j][0..name_lens[j]], names[i][0..name_lens[i]]) == .lt) {
                const tn = names[i];
                const tl = name_lens[i];
                names[i] = names[j];
                name_lens[i] = name_lens[j];
                names[j] = tn;
                name_lens[j] = tl;
            }
        }
    }

    for (0..found) |idx| {
        const dev_name = names[idx][0..name_lens[idx]];
        var base_buf: [96]u8 = undefined;
        const base = std.fmt.bufPrint(&base_buf, "/sys/block/{s}", .{dev_name}) catch continue;

        var dev = storage_enum.DiskDevice{
            .drive_index = @intCast(inv.count),
        };
        setDevName(inv.count, dev_name);

        var vbuf: [64]u8 = undefined;
        if (readSysTrim(base, "device/vendor", &vbuf)) |v| copyFixed(&dev.vendor, &dev.vendor_len, v);
        var mbuf: [128]u8 = undefined;
        if (readSysTrim(base, "device/model", &mbuf)) |m| copyFixed(&dev.model, &dev.model_len, m);
        var fbuf: [64]u8 = undefined;
        if (readSysTrim(base, "device/rev", &fbuf)) |r| {
            copyFixed(&dev.firmware, &dev.firmware_len, r);
        } else if (readSysTrim(base, "device/firmware_rev", &fbuf)) |r2| {
            copyFixed(&dev.firmware, &dev.firmware_len, r2);
        }
        var sbuf: [64]u8 = undefined;
        if (readSysTrim(base, "device/serial", &sbuf)) |sn| {
            copyFixed(&dev.serial_raw, &dev.serial_raw_len, sn);
            dev.serial_masked_len = device_id.maskSerial(sn, &dev.serial_masked);
        }

        // 容量（512 字节扇区数 × 512）
        var sz_buf: [64]u8 = undefined;
        if (readSysTrim(base, "size", &sz_buf)) |sz_s| {
            if (std.fmt.parseInt(u64, sz_s, 10)) |sectors| {
                if (sectors > 0) dev.capacity_bytes = sectors * 512;
            } else |_| {}
        }

        var rm_buf: [16]u8 = undefined;
        if (readSysTrim(base, "removable", &rm_buf)) |rm_s| {
            dev.removable = std.mem.eql(u8, rm_s, "1");
        }

        // 通过 sysfs 软链接路径精准识别总线类型（NVMe / USB / SATA / Virtual）
        var dev_link_path: [128]u8 = undefined;
        const dlp = std.fmt.bufPrint(&dev_link_path, "{s}/device", .{base}) catch "";
        var real_buf: [std.fs.max_path_bytes]u8 = undefined;
        const real_path = std.fs.realpath(dlp, &real_buf) catch "";

        if (std.mem.startsWith(u8, dev_name, "nvme")) {
            dev.bus_type = .nvme;
        } else if (std.mem.startsWith(u8, dev_name, "vd")) {
            dev.bus_type = .virtual;
        } else if (std.mem.indexOf(u8, real_path, "/usb") != null) {
            dev.bus_type = .usb;
        } else if (std.mem.indexOf(u8, real_path, "/ata") != null) {
            dev.bus_type = .sata;
        } else {
            dev.bus_type = .scsi;
        }

        var disp_buf: [160]u8 = undefined;
        const full_model = dev.modelDisplay(&disp_buf);
        dev.support = storage_enum.classifyBus(dev.bus_type, full_model);

        var dev_path_buf: [64]u8 = undefined;
        const dev_path = std.fmt.bufPrint(&dev_path_buf, "/dev/{s}", .{dev_name}) catch "/dev/unknown";
        dev.stable_id = device_id.computeDiskId(
            dev.bus_type.name(),
            full_model,
            dev.serial_raw[0..dev.serial_raw_len],
            "",
            dev_path,
        );

        inv.disks[inv.count] = dev;
        inv.count += 1;
    }

    return inv;
}

// ============================================================================
// Linux SG_IO (0x2285) 标准 T10 SAT ATA PASS-THROUGH (16) 读取 SATA/USB SMART
// ============================================================================
const SG_IO: u32 = 0x2285;
const SG_DXFER_NONE: c_int = -1;
const SG_DXFER_FROM_DEV: c_int = -3;

const SgIoHdr = extern struct {
    interface_id: c_int = 'S',
    dxfer_direction: c_int = 0,
    cmd_len: u8 = 0,
    mx_sb_len: u8 = 0,
    iovec_count: u16 = 0,
    dxfer_len: u32 = 0,
    dxferp: ?*anyopaque = null,
    cmdp: ?[*]u8 = null,
    sbp: ?[*]u8 = null,
    timeout: u32 = 5000,
    flags: u32 = 0,
    pack_id: c_int = 0,
    usr_ptr: ?*anyopaque = null,
    status: u8 = 0,
    masked_status: u8 = 0,
    msg_status: u8 = 0,
    sb_len_wr: u8 = 0,
    host_status: u16 = 0,
    driver_status: u16 = 0,
    resid: c_int = 0,
    duration: u32 = 0,
    info: u32 = 0,
};

fn openLinuxBlockFd(drive_index: u32) union(enum) { ok: std.posix.fd_t, access_denied, not_found, other: u32 } {
    var name_buf: [32]u8 = undefined;
    const nm = getDevName(drive_index, &name_buf) orelse return .not_found;
    var path_buf: [64]u8 = undefined;
    const p = std.fmt.bufPrintZ(&path_buf, "/dev/{s}", .{nm}) catch return .not_found;

    const rc = linux.open(p.ptr, .{ .ACCMODE = .RDONLY, .NONBLOCK = true }, 0);
    const err = linux.E.init(rc);
    if (err == .SUCCESS) return .{ .ok = @intCast(rc) };
    if (err == .ACCES or err == .PERM) return .access_denied;
    if (err == .NOENT) return .not_found;
    return .{ .other = @intFromEnum(err) };
}

fn checkLinuxSatPowerMode(fd: std.posix.fd_t) ata_smart.PowerMode {
    var cdb = ata_smart.buildSat16Cdb(0x06, 0x20, 0x00, 0x00, 0x00, 0x00, 0xE5);
    var sense: [64]u8 = std.mem.zeroes([64]u8);
    var hdr = SgIoHdr{
        .dxfer_direction = SG_DXFER_NONE,
        .cmd_len = 16,
        .mx_sb_len = sense.len,
        .cmdp = &cdb,
        .sbp = &sense,
        .timeout = 5000,
    };
    const rc = linux.ioctl(fd, SG_IO, @intFromPtr(&hdr));
    if (linux.E.init(rc) != .SUCCESS) return .unknown;
    if ((sense[0] == 0x72 or sense[0] == 0x73) and sense[7] >= 14 and sense[8] == 0x09) {
        return switch (sense[13]) {
            0x00, 0x40, 0x41 => .standby_or_sleep,
            0x80, 0xFF => .active_or_idle,
            else => .unknown,
        };
    }
    return .unknown;
}

fn readLinuxSatPage(fd: std.posix.fd_t, feature: u8, out_512: *[512]u8) u32 {
    var cdb = ata_smart.buildSat16Cdb(0x08, 0x0E, feature, 1, 0x4F, 0xC2, 0xB0);
    var sense: [64]u8 = std.mem.zeroes([64]u8);
    var hdr = SgIoHdr{
        .dxfer_direction = SG_DXFER_FROM_DEV,
        .cmd_len = 16,
        .mx_sb_len = sense.len,
        .dxfer_len = 512,
        .dxferp = out_512,
        .cmdp = &cdb,
        .sbp = &sense,
        .timeout = 5000,
    };
    const rc = linux.ioctl(fd, SG_IO, @intFromPtr(&hdr));
    const e = linux.E.init(rc);
    if (e != .SUCCESS) return @intFromEnum(e);
    if (hdr.host_status != 0 or (hdr.status != 0 and hdr.status != 2)) return 50;
    return 0;
}

pub fn readLinuxAtaSmart(drive_index: u32, allow_wake_standby: bool) ata_smart.AtaSmartData {
    const fd = switch (openLinuxBlockFd(drive_index)) {
        .ok => |f| f,
        .access_denied => return .{ .status = .access_denied, .error_code = 13, .collected_utc_ms = std.time.milliTimestamp() },
        .not_found => return .{ .status = .device_removed, .error_code = 2, .collected_utc_ms = std.time.milliTimestamp() },
        .other => |ec| return .{ .status = .transient_error, .error_code = ec, .collected_utc_ms = std.time.milliTimestamp() },
    };
    defer _ = linux.close(fd);

    if (!allow_wake_standby) {
        if (checkLinuxSatPowerMode(fd) == .standby_or_sleep) {
            return .{ .status = .device_standby, .collected_utc_ms = std.time.milliTimestamp() };
        }
    }

    var data_page: [512]u8 = std.mem.zeroes([512]u8);
    const err = readLinuxSatPage(fd, 0xD0, &data_page);
    if (err != 0) {
        return .{ .status = .unsupported, .error_code = err, .collected_utc_ms = std.time.milliTimestamp() };
    }

    var thr_page: [512]u8 = std.mem.zeroes([512]u8);
    const has_thr = (readLinuxSatPage(fd, 0xD1, &thr_page) == 0);
    const parsed = ata_smart.parseAtaSmartPages(&data_page, if (has_thr) &thr_page else null);
    if (parsed.attr_count == 0) {
        return .{ .status = .unsupported, .error_code = 50, .collected_utc_ms = std.time.milliTimestamp() };
    }
    return parsed;
}

// ============================================================================
// Linux NVME_IOCTL_ADMIN_CMD (0xC0484E41) 读取 NVMe Log Page 02h 与 Identify
// ============================================================================
const NVME_IOCTL_ADMIN_CMD: u32 = 0xC0484E41;

const NvmeAdminCmd = extern struct {
    opcode: u8 = 0,
    flags: u8 = 0,
    rsvd1: u16 = 0,
    nsid: u32 = 0,
    cdw2: u32 = 0,
    cdw3: u32 = 0,
    metadata: u64 = 0,
    addr: u64 = 0,
    metadata_len: u32 = 0,
    data_len: u32 = 0,
    cdw10: u32 = 0,
    cdw11: u32 = 0,
    cdw12: u32 = 0,
    cdw13: u32 = 0,
    cdw14: u32 = 0,
    cdw15: u32 = 0,
    timeout_ms: u32 = 5000,
    result: u32 = 0,
};

pub fn readLinuxNvmeSmart(drive_index: u32) nvme_smart.NvmeSmartData {
    const fd = switch (openLinuxBlockFd(drive_index)) {
        .ok => |f| f,
        .access_denied => return .{ .status = .access_denied, .error_code = 13, .collected_utc_ms = std.time.milliTimestamp() },
        .not_found => return .{ .status = .device_removed, .error_code = 2, .collected_utc_ms = std.time.milliTimestamp() },
        .other => |ec| return .{ .status = .transient_error, .error_code = ec, .collected_utc_ms = std.time.milliTimestamp() },
    };
    defer _ = linux.close(fd);

    var raw_log: [512]u8 align(8) = std.mem.zeroes([512]u8);
    // NVMe Admin Opcode 0x02 = Get Log Page; Log ID = 0x02 (SMART); NUMDL = (512/4 - 1) << 16 = 127 << 16
    var cmd = NvmeAdminCmd{
        .opcode = 0x02,
        .nsid = 0xFFFFFFFF,
        .addr = @intFromPtr(&raw_log),
        .data_len = 512,
        .cdw10 = 0x02 | (127 << 16),
    };
    const rc = linux.ioctl(fd, NVME_IOCTL_ADMIN_CMD, @intFromPtr(&cmd));
    const e = linux.E.init(rc);
    if (e != .SUCCESS) {
        return .{
            .status = if (e == .ACCES or e == .PERM) .access_denied else .unsupported,
            .error_code = @intFromEnum(e),
            .collected_utc_ms = std.time.milliTimestamp(),
        };
    }

    var res = nvme_smart.parseLogPage02(&raw_log);

    // Identify Controller (Opcode 0x06, CNS 0x01) 获取 WCTEMP / CCTEMP
    var id_buf: [4096]u8 align(8) = std.mem.zeroes([4096]u8);
    var id_cmd = NvmeAdminCmd{
        .opcode = 0x06,
        .nsid = 0,
        .addr = @intFromPtr(&id_buf),
        .data_len = 4096,
        .cdw10 = 0x01,
    };
    if (linux.E.init(linux.ioctl(fd, NVME_IOCTL_ADMIN_CMD, @intFromPtr(&id_cmd))) == .SUCCESS) {
        const id_head: *const win32.NVME_IDENTIFY_CONTROLLER_HEAD = @ptrCast(@alignCast(&id_buf));
        res.wctemp_c = id_head.wctempCelsius();
        res.cctemp_c = id_head.cctempCelsius();
    }

    return res;
}

fn readSysTrim(base: []const u8, rel: []const u8, buf: []u8) ?[]const u8 {
    var pbuf: [256]u8 = undefined;
    const p = std.fmt.bufPrint(&pbuf, "{s}/{s}", .{ base, rel }) catch return null;
    const f = std.fs.openFileAbsolute(p, .{}) catch return null;
    defer f.close();
    const n = f.readAll(buf) catch return null;
    const t = std.mem.trim(u8, buf[0..n], " \t\r\n\x00");
    return if (t.len > 0) t else null;
}

fn copyFixed(dest: []u8, out_len: *usize, src: []const u8) void {
    const n = @min(dest.len, src.len);
    @memcpy(dest[0..n], src[0..n]);
    out_len.* = n;
}
