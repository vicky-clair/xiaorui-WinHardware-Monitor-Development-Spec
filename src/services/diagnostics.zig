const std = @import("std");
const monitoring = @import("monitoring.zig");

/// 规范 §9 第 14 条 / §13：脱敏诊断报告导出（所有序列号均脱敏，绝不导出完整序列号）。
pub fn buildSanitizedDiagnosticsReport(
    allocator: std.mem.Allocator,
    tel: *const monitoring.SharedTelemetry,
    is_admin: bool,
    is_portable: bool,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const w = out.writer(allocator);

    try w.print("# WinHardware Monitor 脱敏诊断报告\n", .{});
    try w.print("生成时间 (UTC ms): {d}\n", .{std.time.milliTimestamp()});
    try w.print("运行权限: {s}\n", .{if (is_admin) "Administrator" else "Standard User"});
    try w.print("部署模式: {s}\n\n", .{if (is_portable) "Portable" else "Installed"});

    try w.print("## 系统与 CPU / 内存\n", .{});
    if (tel.has_system_sample) {
        try w.print("CPU: {s} ({d} 逻辑核心, 基础频率 {d} MHz)\n", .{
            tel.system.cpuNameSlice(),
            tel.system.logical_cores,
            tel.system.base_clock_mhz,
        });
        try w.print("运行时间: {d} 秒\n", .{tel.system.uptime_seconds});
        try w.print("内存: {d} / {d} MB\n", .{
            tel.system.mem_used_bytes / (1024 * 1024),
            tel.system.mem_total_bytes / (1024 * 1024),
        });
        if (tel.system.smbios_info.available) {
            try w.print("主板: {s} {s} ({s})\n", .{
                tel.system.smbios_info.boardManufacturer(),
                tel.system.smbios_info.boardProduct(),
                tel.system.smbios_info.boardVersion(),
            });
            for (tel.system.smbios_info.dimms[0..tel.system.smbios_info.dimm_count]) |d| {
                try w.print("  DIMM [{s}]: {s} {d}MB @{d}MHz SN={s}\n", .{
                    d.slotSlice(),
                    d.memoryTypeName(),
                    d.size_mb,
                    d.effectiveSpeedMhz(),
                    d.serialMaskedSlice(),
                });
            }
        }
    }

    try w.print("\n## GPU\n", .{});
    for (tel.gpu.slice(), 0..) |g, i| {
        try w.print("GPU #{d}: {s} | Temp={?d:.1}C ({s}) | Power={?d:.1}W | Fan={?d}RPM\n", .{
            i,
            g.nameSlice(),
            g.temp_c,
            g.temp_source,
            g.power_watts,
            g.fan_rpm,
        });
    }

    try w.print("\n## 物理磁盘与健康规则（序列号已脱敏）\n", .{});
    for (tel.disk_states[0..tel.disk_count]) |ds| {
        var mb: [160]u8 = undefined;
        const model = ds.device.modelDisplay(&mb);
        try w.print("Disk {d}: {s} | Bus={s} | SN={s} | StableID={s} | Health={s} | Temp={?d}C\n", .{
            ds.device.drive_index,
            model,
            ds.device.bus_type.name(),
            ds.device.serialMaskedSlice(),
            ds.device.stable_id.slice(),
            ds.assessment.overall.labelZh(),
            ds.effectiveTempC(),
        });
        for (ds.assessment.slice()) |h| {
            try w.print("  - [{s}] {s}\n", .{ h.rule_id, h.evidenceSlice() });
        }
    }

    return out.toOwnedSlice(allocator);
}

test "buildSanitizedDiagnosticsReport masks raw serial numbers" {
    var tel = monitoring.SharedTelemetry{};
    tel.disk_count = 1;
    const raw_sn = "SECRET12349988";
    @memcpy(tel.disk_states[0].device.serial_raw[0..raw_sn.len], raw_sn);
    tel.disk_states[0].device.serial_raw_len = raw_sn.len;
    const masked = "****9988";
    @memcpy(tel.disk_states[0].device.serial_masked[0..masked.len], masked);
    tel.disk_states[0].device.serial_masked_len = masked.len;

    const report = try buildSanitizedDiagnosticsReport(std.testing.allocator, &tel, false, true);
    defer std.testing.allocator.free(report);

    try std.testing.expect(std.mem.indexOf(u8, report, "****9988") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "SECRET12349988") == null);
}
