//! Linux 原生 `hwmon` 传感器采集模块（`/sys/class/hwmon/hwmon*`，即 `lm-sensors` 同源内核接口）。
//! 普通用户零驱动即可读取 CPU 封装/核心温度、主板温度、风扇转速、电压与功耗，
//! 并直接复用 `ExtensionSnapshot` 数据结构，无缝联动 GUI 仪表、全传感器表与烤机高温熔断保护。
const std = @import("std");
const sensor = @import("../../core/sensor.zig");
const lhm_client = @import("../libre_hardware_monitor/client.zig");

/// 扫描 Linux `/sys/class/hwmon` 收集全部可用真实传感器（绝不伪造数据）
pub fn collectHwmonSnapshot() lhm_client.ExtensionSnapshot {
    var snap = lhm_client.ExtensionSnapshot{
        .status = .ok,
        .connected = true,
        .helper_is_admin = (std.os.linux.geteuid() == 0),
    };

    var dir = std.fs.openDirAbsolute("/sys/class/hwmon", .{ .iterate = true }) catch {
        snap.status = .unsupported;
        snap.connected = false;
        return snap;
    };
    defer dir.close();

    var fallback_cpu_temp: ?f64 = null;
    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind != .directory and entry.kind != .sym_link) continue;
        if (!std.mem.startsWith(u8, entry.name, "hwmon")) continue;

        var base_buf: [128]u8 = undefined;
        const base_path = std.fmt.bufPrint(&base_buf, "/sys/class/hwmon/{s}", .{entry.name}) catch continue;

        var name_buf: [64]u8 = undefined;
        const chip_name = readTrimmedFile(base_path, "name", &name_buf) orelse entry.name;
        const is_cpu_chip = std.mem.eql(u8, chip_name, "coretemp") or
            std.mem.eql(u8, chip_name, "k10temp") or
            std.mem.eql(u8, chip_name, "zenpower") or
            std.mem.eql(u8, chip_name, "cpu_thermal");

        // 1. 温度探头 temp1_input .. temp16_input（单位：毫摄氏度 m°C）
        for (1..17) |idx| {
            var in_name: [32]u8 = undefined;
            const in_f = std.fmt.bufPrint(&in_name, "temp{d}_input", .{idx}) catch continue;
            var val_buf: [64]u8 = undefined;
            const val_s = readTrimmedFile(base_path, in_f, &val_buf) orelse continue;
            const milli_c = std.fmt.parseInt(i64, val_s, 10) catch continue;
            const temp_c: f64 = @as(f64, @floatFromInt(milli_c)) / 1000.0;
            if (temp_c < -40.0 or temp_c > 150.0) continue;

            var lbl_file: [32]u8 = undefined;
            const lf = std.fmt.bufPrint(&lbl_file, "temp{d}_label", .{idx}) catch "";
            var lbl_buf: [64]u8 = undefined;
            var fallback_lbl: [32]u8 = undefined;
            const label = readTrimmedFile(base_path, lf, &lbl_buf) orelse
                (std.fmt.bufPrint(&fallback_lbl, "{s} temp{d}", .{ chip_name, idx }) catch "temp");

            appendSensor(&snap, chip_name, label, "Temperature", temp_c, "C");

            if (is_cpu_chip) {
                if (containsIgnoreCase(label, "Package") or
                    containsIgnoreCase(label, "Tctl") or
                    containsIgnoreCase(label, "Tdie"))
                {
                    if (snap.cpu_package_temp_c == null) snap.cpu_package_temp_c = temp_c;
                } else if (fallback_cpu_temp == null) {
                    fallback_cpu_temp = temp_c;
                }
            }
        }

        // 2. 风扇转速 fan1_input .. fan8_input（单位：RPM）
        for (1..9) |idx| {
            var in_name: [32]u8 = undefined;
            const in_f = std.fmt.bufPrint(&in_name, "fan{d}_input", .{idx}) catch continue;
            var val_buf: [64]u8 = undefined;
            const val_s = readTrimmedFile(base_path, in_f, &val_buf) orelse continue;
            const rpm = std.fmt.parseFloat(f64, val_s) catch continue;
            if (rpm < 0.0 or rpm > 30000.0) continue;

            var lbl_file: [32]u8 = undefined;
            const lf = std.fmt.bufPrint(&lbl_file, "fan{d}_label", .{idx}) catch "";
            var lbl_buf: [64]u8 = undefined;
            var fb: [32]u8 = undefined;
            const label = readTrimmedFile(base_path, lf, &lbl_buf) orelse
                (std.fmt.bufPrint(&fb, "Fan #{d}", .{idx}) catch "Fan");
            appendSensor(&snap, chip_name, label, "Fan", rpm, "RPM");
        }

        // 3. 功耗 power1_average / power1_input（单位：微瓦 uW -> W）
        for (1..5) |idx| {
            var in_name: [32]u8 = undefined;
            const avg_f = std.fmt.bufPrint(&in_name, "power{d}_average", .{idx}) catch continue;
            var val_buf: [64]u8 = undefined;
            var val_s = readTrimmedFile(base_path, avg_f, &val_buf);
            if (val_s == null) {
                const inp_f = std.fmt.bufPrint(&in_name, "power{d}_input", .{idx}) catch continue;
                val_s = readTrimmedFile(base_path, inp_f, &val_buf);
            }
            if (val_s) |vs| {
                const uw = std.fmt.parseInt(i64, vs, 10) catch continue;
                const watts = @as(f64, @floatFromInt(uw)) / 1_000_000.0;
                if (watts < 0.0 or watts > 2000.0) continue;
                var fb: [32]u8 = undefined;
                const label = std.fmt.bufPrint(&fb, "{s} Power #{d}", .{ chip_name, idx }) catch "Power";
                appendSensor(&snap, chip_name, label, "Power", watts, "W");
                if (is_cpu_chip and snap.cpu_package_power_w == null) {
                    snap.cpu_package_power_w = watts;
                }
            }
        }

        // 4. 电压 in0_input .. in8_input（单位：毫伏 mV -> V）
        for (0..9) |idx| {
            var in_name: [32]u8 = undefined;
            const in_f = std.fmt.bufPrint(&in_name, "in{d}_input", .{idx}) catch continue;
            var val_buf: [64]u8 = undefined;
            const val_s = readTrimmedFile(base_path, in_f, &val_buf) orelse continue;
            const mv = std.fmt.parseInt(i64, val_s, 10) catch continue;
            const volts = @as(f64, @floatFromInt(mv)) / 1000.0;
            if (volts < 0.0 or volts > 30.0) continue;
            var lbl_file: [32]u8 = undefined;
            const lf = std.fmt.bufPrint(&lbl_file, "in{d}_label", .{idx}) catch "";
            var lbl_buf: [64]u8 = undefined;
            var fb: [32]u8 = undefined;
            const label = readTrimmedFile(base_path, lf, &lbl_buf) orelse
                (std.fmt.bufPrint(&fb, "Voltage in{d}", .{idx}) catch "Voltage");
            appendSensor(&snap, chip_name, label, "Voltage", volts, "V");
        }
    }

    if (snap.cpu_package_temp_c == null) {
        snap.cpu_package_temp_c = fallback_cpu_temp;
    }
    if (snap.sensor_count == 0) {
        snap.status = .unsupported;
    }
    return snap;
}

fn appendSensor(
    snap: *lhm_client.ExtensionSnapshot,
    hw: []const u8,
    name: []const u8,
    stype: []const u8,
    value: f64,
    unit: []const u8,
) void {
    if (snap.sensor_count >= lhm_client.MAX_EXT_SENSORS) return;
    var e = lhm_client.ExtSensorEntry{ .value = value };
    copyFixed(&e.hardware, &e.hardware_len, hw);
    copyFixed(&e.name, &e.name_len, name);
    copyFixed(&e.sensor_type, &e.sensor_type_len, stype);
    copyFixed(&e.unit, &e.unit_len, unit);
    snap.sensors[snap.sensor_count] = e;
    snap.sensor_count += 1;
}

fn readTrimmedFile(dir_path: []const u8, file_name: []const u8, out_buf: []u8) ?[]const u8 {
    if (file_name.len == 0) return null;
    var full_buf: [256]u8 = undefined;
    const full = std.fmt.bufPrint(&full_buf, "{s}/{s}", .{ dir_path, file_name }) catch return null;
    const f = std.fs.openFileAbsolute(full, .{}) catch return null;
    defer f.close();
    const n = f.readAll(out_buf) catch return null;
    const trimmed = std.mem.trim(u8, out_buf[0..n], " \t\r\n\x00");
    return if (trimmed.len > 0) trimmed else null;
}

fn copyFixed(dest: []u8, out_len: *usize, src: []const u8) void {
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
