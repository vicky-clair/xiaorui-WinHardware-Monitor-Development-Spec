const std = @import("std");
const zglfw = @import("zglfw");
const zopengl = @import("zopengl");
const zgui = @import("zgui");
const win32 = @import("providers/windows/win32.zig");
const toml = @import("utils/toml.zig");
const sqlite = @import("database/sqlite.zig");

const log = std.log.scoped(.verify_p0);

fn maskSerial(serial: []const u8, buf: *[64]u8) []const u8 {
    const trimmed = std.mem.trim(u8, serial, " \t\r\n\x00");
    if (trimmed.len == 0) return "N/A";
    if (trimmed.len <= 4) return "****";
    const last4 = trimmed[trimmed.len - 4 ..];
    return std.fmt.bufPrint(buf, "****{s}", .{last4}) catch "****";
}

fn readCStringAt(buf: []const u8, offset: u32) []const u8 {
    if (offset == 0 or offset >= buf.len) return "";
    const slice = buf[offset..];
    const nul = std.mem.indexOfScalar(u8, slice, 0) orelse slice.len;
    return std.mem.trim(u8, slice[0..nul], " \t\r\n");
}

fn verifyStorage() void {
    std.debug.print("\n=== [4] 磁盘枚举、NVMe SMART、存储温度描述符、ATA 检测 ===\n", .{});
    var found: usize = 0;

    for (0..16) |drive_idx| {
        var path_utf8: [64]u8 = undefined;
        const path_slice = std.fmt.bufPrint(&path_utf8, "\\\\.\\PhysicalDrive{d}", .{drive_idx}) catch continue;
        var path_w: [65]u16 = undefined;
        const wlen = std.unicode.utf8ToUtf16Le(&path_w, path_slice) catch continue;
        path_w[wlen] = 0;

        // First open with 0 access (standard user allowed for STORAGE_QUERY_PROPERTY!)
        const h_zero = win32.CreateFileW(
            @ptrCast(&path_w),
            0,
            win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE,
            null,
            win32.OPEN_EXISTING,
            0,
            null,
        );
        if (h_zero == win32.INVALID_HANDLE_VALUE) {
            const err = win32.GetLastError();
            if (err != 2) { // ERROR_FILE_NOT_FOUND
                std.debug.print("  PhysicalDrive{d}: CreateFile(0) failed, err={d}\n", .{ drive_idx, err });
            }
            continue;
        }
        defer _ = win32.CloseHandle(h_zero);
        found += 1;

        // 4.1 Device descriptor
        var query = win32.STORAGE_PROPERTY_QUERY{
            .PropertyId = win32.StorageDeviceProperty,
            .QueryType = win32.PropertyStandardQuery,
        };
        var desc_buf: [1024]u8 align(8) = std.mem.zeroes([1024]u8);
        var bytes_ret: win32.DWORD = 0;
        var bus_type: win32.STORAGE_BUS_TYPE = .unknown;

        if (win32.DeviceIoControl(
            h_zero,
            win32.IOCTL_STORAGE_QUERY_PROPERTY,
            &query,
            @sizeOf(win32.STORAGE_PROPERTY_QUERY),
            &desc_buf,
            desc_buf.len,
            &bytes_ret,
            null,
        ) != 0) {
            const desc: *const win32.STORAGE_DEVICE_DESCRIPTOR = @ptrCast(@alignCast(&desc_buf));
            bus_type = @enumFromInt(desc.BusType);
            const vendor = readCStringAt(&desc_buf, desc.VendorIdOffset);
            const product = readCStringAt(&desc_buf, desc.ProductIdOffset);
            const rev = readCStringAt(&desc_buf, desc.ProductRevisionOffset);
            const serial = readCStringAt(&desc_buf, desc.SerialNumberOffset);
            var masked_buf: [64]u8 = undefined;
            std.debug.print("  PhysicalDrive{d}: Bus={s} ({d}), Vendor=\"{s}\", Model=\"{s}\", FW=\"{s}\", SN={s}\n", .{
                drive_idx,
                bus_type.name(),
                desc.BusType,
                vendor,
                product,
                rev,
                maskSerial(serial, &masked_buf),
            });
        } else {
            std.debug.print("  PhysicalDrive{d}: StorageDeviceProperty failed, err={d}\n", .{ drive_idx, win32.GetLastError() });
        }

        // 4.2 Storage Temperature Descriptor (zero access handle)
        {
            var tq = win32.STORAGE_PROPERTY_QUERY{
                .PropertyId = win32.StorageDeviceTemperatureProperty,
                .QueryType = win32.PropertyStandardQuery,
            };
            var tbuf: [512]u8 align(8) = std.mem.zeroes([512]u8);
            var tret: win32.DWORD = 0;
            if (win32.DeviceIoControl(
                h_zero,
                win32.IOCTL_STORAGE_QUERY_PROPERTY,
                &tq,
                @sizeOf(win32.STORAGE_PROPERTY_QUERY),
                &tbuf,
                tbuf.len,
                &tret,
                null,
            ) != 0) {
                const td: *const win32.STORAGE_TEMPERATURE_DATA_DESCRIPTOR = @ptrCast(@alignCast(&tbuf));
                const info0 = td.TemperatureInfo[0];
                std.debug.print("    [StorageDeviceTemperatureProperty (access=0)] OK! InfoCount={d}, Temp={d}°C, Warn={d}°C, Crit={d}°C\n", .{
                    td.InfoCount,
                    info0.Temperature,
                    td.WarningTemperature,
                    td.CriticalTemperature,
                });
            } else {
                std.debug.print("    [StorageDeviceTemperatureProperty (access=0)] FAILED, err={d}\n", .{win32.GetLastError()});
            }
        }

        // 4.3 NVMe SMART Log Page 02h & Identify Controller (try with access=0 first, then GENERIC_READ)
        if (bus_type == .nvme) {
            testNvmeQuery(h_zero, "access=0");

            const h_rd = win32.CreateFileW(
                @ptrCast(&path_w),
                win32.GENERIC_READ,
                win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE,
                null,
                win32.OPEN_EXISTING,
                0,
                null,
            );
            if (h_rd != win32.INVALID_HANDLE_VALUE) {
                defer _ = win32.CloseHandle(h_rd);
                testNvmeQuery(h_rd, "GENERIC_READ");
            } else {
                std.debug.print("    [NVMe Open(GENERIC_READ)] FAILED, err={d}\n", .{win32.GetLastError()});
            }
        } else {
            // 4.4 ATA CHECK POWER MODE probe (requires GENERIC_READ | GENERIC_WRITE)
            const h_rw = win32.CreateFileW(
                @ptrCast(&path_w),
                win32.GENERIC_READ | win32.GENERIC_WRITE,
                win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE,
                null,
                win32.OPEN_EXISTING,
                0,
                null,
            );
            if (h_rw == win32.INVALID_HANDLE_VALUE) {
                std.debug.print("    [ATA/SAT Open(R|W)] FAILED, err={d} (5=ERROR_ACCESS_DENIED，普通用户符合预期)\n", .{win32.GetLastError()});
            } else {
                defer _ = win32.CloseHandle(h_rw);
                var ata = std.mem.zeroes(win32.ATA_PASS_THROUGH_EX);
                ata.Length = @sizeOf(win32.ATA_PASS_THROUGH_EX);
                ata.AtaFlags = win32.ATA_FLAGS_DRDY_REQUIRED;
                ata.TimeOutValue = 5;
                ata.CurrentTaskFile[6] = 0xE5; // ATA CHECK POWER MODE
                var ret_ata: win32.DWORD = 0;
                if (win32.DeviceIoControl(
                    h_rw,
                    win32.IOCTL_ATA_PASS_THROUGH,
                    &ata,
                    @sizeOf(win32.ATA_PASS_THROUGH_EX),
                    &ata,
                    @sizeOf(win32.ATA_PASS_THROUGH_EX),
                    &ret_ata,
                    null,
                ) != 0) {
                    std.debug.print("    [ATA CHECK POWER MODE] OK! SectorCount=0x{X:0>2} (0xFF=Active/Idle, 0x00=Standby)\n", .{ata.CurrentTaskFile[1]});
                } else {
                    std.debug.print("    [ATA CHECK POWER MODE] FAILED, err={d} (USB 设备通常需通过 SAT SCSI 透传)\n", .{win32.GetLastError()});
                }
            }
        }
    }

    if (found == 0) {
        std.debug.print("  未发现物理磁盘\n", .{});
    }
}

fn testNvmeQuery(handle: win32.HANDLE, tag: []const u8) void {
    // Buffer layout: [PropertyId(4), QueryType(4)] + STORAGE_PROTOCOL_SPECIFIC_DATA(40) + 512 bytes log
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
    if (win32.DeviceIoControl(
        handle,
        win32.IOCTL_STORAGE_QUERY_PROPERTY,
        &buf,
        total_size,
        &buf,
        total_size,
        &ret,
        null,
    ) != 0) {
        const out_desc: *const win32.STORAGE_PROTOCOL_DATA_DESCRIPTOR = @ptrCast(@alignCast(&buf));
        const data_start = @offsetOf(win32.STORAGE_PROTOCOL_DATA_DESCRIPTOR, "ProtocolSpecificData") + out_desc.ProtocolSpecificData.ProtocolDataOffset;
        if (data_start + @sizeOf(win32.NVME_HEALTH_INFO_LOG) <= buf.len) {
            const health: *const win32.NVME_HEALTH_INFO_LOG = @ptrCast(@alignCast(buf[data_start..].ptr));
            std.debug.print(
                "    [NVMe SMART ({s})] OK! Temp={d}°C ({d}K), Spare={d}% (Thr={d}%), Used={d}%, CW=0x{X:0>2}, POH={d}h, PowerCycles={d}, MediaErr={d}, WrittenUnits={d}\n",
                .{
                    tag,
                    health.compositeTempCelsius(),
                    health.compositeTempKelvin(),
                    health.AvailableSpare,
                    health.AvailableSpareThreshold,
                    health.PercentageUsed,
                    health.CriticalWarning,
                    win32.NVME_HEALTH_INFO_LOG.readU128(health.PowerOnHours),
                    win32.NVME_HEALTH_INFO_LOG.readU128(health.PowerCycle),
                    win32.NVME_HEALTH_INFO_LOG.readU128(health.MediaErrors),
                    win32.NVME_HEALTH_INFO_LOG.readU128(health.DataUnitWritten),
                },
            );
        }
    } else {
        std.debug.print("    [NVMe SMART ({s})] FAILED, err={d}\n", .{ tag, win32.GetLastError() });
    }

    // Also test NVMe Identify Controller (WCTEMP / CCTEMP)
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
        const out_desc: *const win32.STORAGE_PROTOCOL_DATA_DESCRIPTOR = @ptrCast(@alignCast(&id_buf));
        const dstart = @offsetOf(win32.STORAGE_PROTOCOL_DATA_DESCRIPTOR, "ProtocolSpecificData") + out_desc.ProtocolSpecificData.ProtocolDataOffset;
        if (dstart + 270 <= id_buf.len) {
            const wctemp = std.mem.readInt(u16, id_buf[dstart + 266 ..][0..2], .little);
            const cctemp = std.mem.readInt(u16, id_buf[dstart + 268 ..][0..2], .little);
            std.debug.print("    [NVMe Identify ({s})] OK! WCTEMP={d}K ({d}°C), CCTEMP={d}K ({d}°C)\n", .{
                tag,
                wctemp,
                if (wctemp > 273) @as(i32, wctemp) - 273 else 0,
                cctemp,
                if (cctemp > 273) @as(i32, cctemp) - 273 else 0,
            });
        }
    } else {
        std.debug.print("    [NVMe Identify ({s})] FAILED, err={d}\n", .{ tag, win32.GetLastError() });
    }
}

fn verifyGpuD3dkmtAndNvml() void {
    std.debug.print("\n=== [5] GPU 温度检测（D3DKMT + NVML 动态加载） ===\n", .{});

    // 5.1 D3DKMTEnumAdapters2
    var enum_req = win32.D3DKMT_ENUMADAPTERS2{
        .NumAdapters = 0,
        .pAdapters = null,
    };
    const st1 = win32.D3DKMTEnumAdapters2(&enum_req);
    if (st1 != 0) {
        std.debug.print("  [D3DKMT] EnumAdapters2(count) failed, NTSTATUS=0x{X:0>8}\n", .{@as(u32, @bitCast(st1))});
    } else {
        std.debug.print("  [D3DKMT] 枚举到 {d} 个图形适配器\n", .{enum_req.NumAdapters});
        var adapters: [16]win32.D3DKMT_ADAPTERINFO = undefined;
        const cap: u32 = @min(enum_req.NumAdapters, 16);
        enum_req.NumAdapters = cap;
        enum_req.pAdapters = &adapters;
        const st2 = win32.D3DKMTEnumAdapters2(&enum_req);
        if (st2 == 0) {
            std.debug.print("  [D3DKMT] 实际返回 {d} 个活动适配器\n", .{enum_req.NumAdapters});
            for (adapters[0..enum_req.NumAdapters], 0..) |ad, idx| {
                defer {
                    const close_arg = win32.D3DKMT_CLOSEADAPTER{ .hAdapter = ad.hAdapter };
                    _ = win32.D3DKMTCloseAdapter(&close_arg);
                }
                var perf = std.mem.zeroes(win32.D3DKMT_ADAPTER_PERFDATA);
                var q = win32.D3DKMT_QUERYADAPTERINFO{
                    .hAdapter = ad.hAdapter,
                    .Type = win32.KMTQAITYPE_ADAPTERPERFDATA,
                    .pPrivateDriverData = &perf,
                    .PrivateDriverDataSize = @sizeOf(win32.D3DKMT_ADAPTER_PERFDATA),
                };
                const qst = win32.D3DKMTQueryAdapterInfo(&q);
                if (qst == 0) {
                    const temp_c = @as(f64, @floatFromInt(perf.Temperature)) / 10.0;
                    std.debug.print("    Adapter #{d} (LUID 0x{X}): Temp={d:.1}°C, Fan={d} RPM, MemFreq={d} MHz, PowerRaw={d}\n", .{
                        idx,
                        ad.AdapterLuid.LowPart,
                        temp_c,
                        perf.FanRPM,
                        perf.MemoryFrequency / 1_000_000,
                        perf.Power,
                    });
                } else {
                    std.debug.print("    Adapter #{d} (LUID 0x{X}): KMTQAITYPE_ADAPTERPERFDATA failed, NTSTATUS=0x{X:0>8} (软渲染器/基础驱动可能不支持)\n", .{
                        idx,
                        ad.AdapterLuid.LowPart,
                        @as(u32, @bitCast(qst)),
                    });
                }
            }
        }
    }

    // 5.2 Dynamic NVML probe (zero compile-time SDK dependency)
    const nvml_dll_w = std.unicode.utf8ToUtf16LeStringLiteral("nvml.dll");
    const hmod = win32.LoadLibraryW(nvml_dll_w);
    if (hmod == null) {
        std.debug.print("  [NVML] 未检测到 nvml.dll（非 NVIDIA 驱动或未安装）\n", .{});
        return;
    }
    defer _ = win32.FreeLibrary(hmod.?);

    const NvmlInitFn = *const fn () callconv(.c) c_int;
    const NvmlShutdownFn = *const fn () callconv(.c) c_int;
    const NvmlCountFn = *const fn (*c_uint) callconv(.c) c_int;
    const NvmlHandleByIdxFn = *const fn (c_uint, *?*anyopaque) callconv(.c) c_int;
    const NvmlNameFn = *const fn (?*anyopaque, [*]u8, c_uint) callconv(.c) c_int;
    const NvmlTempFn = *const fn (?*anyopaque, c_uint, *c_uint) callconv(.c) c_int;
    const NvmlPowerFn = *const fn (?*anyopaque, *c_uint) callconv(.c) c_int;

    const init_fn: NvmlInitFn = @ptrCast(@alignCast(win32.GetProcAddress(hmod.?, "nvmlInit_v2") orelse return));
    const shutdown_fn: NvmlShutdownFn = @ptrCast(@alignCast(win32.GetProcAddress(hmod.?, "nvmlShutdown") orelse return));
    const count_fn: NvmlCountFn = @ptrCast(@alignCast(win32.GetProcAddress(hmod.?, "nvmlDeviceGetCount_v2") orelse return));
    const by_idx_fn: NvmlHandleByIdxFn = @ptrCast(@alignCast(win32.GetProcAddress(hmod.?, "nvmlDeviceGetHandleByIndex_v2") orelse return));
    const name_fn: NvmlNameFn = @ptrCast(@alignCast(win32.GetProcAddress(hmod.?, "nvmlDeviceGetName") orelse return));
    const temp_fn: NvmlTempFn = @ptrCast(@alignCast(win32.GetProcAddress(hmod.?, "nvmlDeviceGetTemperature") orelse return));
    const power_fn: ?NvmlPowerFn = if (win32.GetProcAddress(hmod.?, "nvmlDeviceGetPowerUsage")) |p| @ptrCast(@alignCast(p)) else null;

    if (init_fn() != 0) {
        std.debug.print("  [NVML] nvmlInit_v2 失败\n", .{});
        return;
    }
    defer _ = shutdown_fn();

    var dev_count: c_uint = 0;
    if (count_fn(&dev_count) == 0) {
        std.debug.print("  [NVML] 检测到 {d} 块 NVIDIA GPU\n", .{dev_count});
        for (0..dev_count) |i| {
            var dev: ?*anyopaque = null;
            if (by_idx_fn(@intCast(i), &dev) == 0) {
                var name_buf: [96]u8 = std.mem.zeroes([96]u8);
                _ = name_fn(dev, &name_buf, name_buf.len);
                const name_str = std.mem.sliceTo(&name_buf, 0);
                var temp: c_uint = 0;
                const trc = temp_fn(dev, 0, &temp);
                var power_mw: c_uint = 0;
                const prc: c_int = if (power_fn) |pf| pf(dev, &power_mw) else -1;
                std.debug.print("    NVML GPU #{d}: {s}, Temp={d}°C (rc={d}), Power={d:.1}W (rc={d})\n", .{
                    i,
                    name_str,
                    temp,
                    trc,
                    @as(f64, @floatFromInt(power_mw)) / 1000.0,
                    prc,
                });
            }
        }
    }
}

fn hiddenWndProc(hwnd: win32.HWND, msg: win32.UINT, wp: win32.WPARAM, lp: win32.LPARAM) callconv(.winapi) win32.LRESULT {
    return win32.DefWindowProcW(hwnd, msg, wp, lp);
}

fn verifyGuiAndTray(allocator: std.mem.Allocator) !void {
    std.debug.print("\n=== [6] GUI + ImPlot + 中文字体 + DPI + 托盘/消息窗口共存验证 ===\n", .{});

    // Hidden message window + tray icon test
    const class_name = std.unicode.utf8ToUtf16LeStringLiteral("WinHwMonP0VerifyMsgWnd");
    const hinst: ?win32.HINSTANCE = @ptrCast(win32.GetModuleHandleW(null));
    var wc = win32.WNDCLASSEXW{
        .lpfnWndProc = hiddenWndProc,
        .hInstance = hinst,
        .lpszClassName = class_name,
    };
    const atom = win32.RegisterClassExW(&wc);
    defer if (atom != 0) {
        _ = win32.UnregisterClassW(class_name, hinst);
    };
    const co_hr = win32.CoInitializeEx(null, win32.COINIT_APARTMENTTHREADED);
    defer if (co_hr >= 0) win32.CoUninitialize();

    const tray_wnd_class = std.unicode.utf8ToUtf16LeStringLiteral("Shell_TrayWnd");
    const shell_tray = win32.FindWindowW(tray_wnd_class, null);

    // Hidden top-level window (required for WM_DEVICECHANGE, WM_POWERBROADCAST, and Shell_NotifyIconW)
    const msg_hwnd = win32.CreateWindowExW(
        0,
        class_name,
        class_name,
        0,
        0,
        0,
        0,
        0,
        null,
        null,
        hinst,
        null,
    );
    if (msg_hwnd) |hwnd| {
        defer _ = win32.DestroyWindow(hwnd);
        if (shell_tray == null) {
            std.debug.print("  [Win32 隐藏顶层窗口] 创建成功 (hwnd={*})；当前会话未检测到 Shell_TrayWnd，跳过实时托盘添加测试（NOTIFYICONDATAW 976B 布局已通过编译期校验）\n", .{hwnd});
        } else {
            const hicon = win32.LoadIconW(null, win32.IDI_APPLICATION);
            var nid = win32.NOTIFYICONDATAW{
                .hWnd = hwnd,
                .uID = 1,
                .uFlags = win32.NIF_ICON | win32.NIF_TIP | win32.NIF_MESSAGE,
                .uCallbackMessage = win32.WM_APP + 1,
                .hIcon = hicon,
            };
            const tip = "WinHardware Monitor P0 验证";
            const tlen = std.unicode.utf8ToUtf16Le(&nid.szTip, tip) catch 0;
            nid.szTip[@min(tlen, nid.szTip.len - 1)] = 0;

            const tray_ok = win32.Shell_NotifyIconW(win32.NIM_ADD, &nid) != 0;
            const tray_err = if (!tray_ok) win32.GetLastError() else 0;
            if (tray_ok) {
                _ = win32.Shell_NotifyIconW(win32.NIM_DELETE, &nid);
            }
            std.debug.print("  [Win32 隐藏顶层窗口 + 托盘图标] 创建/添加/移除: {s} (cbSize={d}, err=0x{X})\n", .{
                if (tray_ok) "OK" else "FAILED",
                nid.cbSize,
                tray_err,
            });
        }
    } else {
        std.debug.print("  [Win32 隐藏顶层窗口] 创建失败, err={d}\n", .{win32.GetLastError()});
    }

    // GLFW + OpenGL 3.3 Core + zgui + ImPlot + Chinese font
    try zglfw.init();
    defer zglfw.terminate();

    zglfw.windowHint(.context_version_major, 3);
    zglfw.windowHint(.context_version_minor, 3);
    zglfw.windowHint(.opengl_profile, .opengl_core_profile);
    zglfw.windowHint(.visible, false); // keep smoke test non-intrusive

    const window = try zglfw.Window.create(800, 500, "WinHardware Monitor P0 Verify", null, null);
    defer window.destroy();

    zglfw.makeContextCurrent(window);
    try zopengl.loadCoreProfile(zglfw.getProcAddress, 3, 3);
    const gl = zopengl.bindings;

    const scale = window.getContentScale();
    std.debug.print("  [GLFW + OpenGL 3.3 Core] 上下文创建成功, DPI scale=({d:.2}, {d:.2})\n", .{ scale[0], scale[1] });

    zgui.init(allocator);
    defer zgui.deinit();
    zgui.plot.init();
    defer zgui.plot.deinit();

    // Load Chinese system font (msyh.ttc)
    const font_path = "C:\\Windows\\Fonts\\msyh.ttc";
    const font_exists = blk: {
        std.fs.accessAbsolute(font_path, .{}) catch break :blk false;
        break :blk true;
    };
    if (font_exists) {
        const font_size = 16.0 * @max(scale[0], 1.0);
        const font = zgui.io.addFontFromFile(font_path, font_size);
        zgui.io.setDefaultFont(font);
        std.debug.print("  [中文字体] 已加载 {s} (size={d:.1}px)\n", .{ font_path, font_size });
    } else {
        std.debug.print("  [中文字体] 未找到 {s}，使用默认字体\n", .{font_path});
    }

    zgui.backend.initWithGlSlVersion(window, "#version 330");
    defer zgui.backend.deinit();

    // Render 5 frames with an ImPlot curve to verify complete rendering pipeline
    const xs = [_]f64{ 0, 1, 2, 3, 4 };
    const ys = [_]f64{ 35.0, 36.5, 37.2, 36.8, 37.0 };

    for (0..5) |_| {
        zglfw.pollEvents();
        const fb = window.getFramebufferSize();
        gl.viewport(0, 0, fb[0], fb[1]);
        gl.clearColor(0.05, 0.06, 0.08, 1.0);
        gl.clear(gl.COLOR_BUFFER_BIT);

        zgui.backend.newFrame(@intCast(fb[0]), @intCast(fb[1]));
        if (zgui.begin("P0 Verify", .{})) {
            zgui.text("中文渲染与 ImPlot 验证", .{});
            if (zgui.plot.beginPlot("温度曲线", .{})) {
                zgui.plot.plotLine("NVMe °C", f64, .{ .xv = &xs, .yv = &ys });
                zgui.plot.endPlot();
            }
        }
        zgui.end();
        zgui.backend.draw();
        window.swapBuffers();
    }
    std.debug.print("  [zgui + ImPlot] 5 帧完整渲染验证通过\n", .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("============================================================\n", .{});
    std.debug.print("  WinHardware Monitor — P0 技术验证工具 (Zig 0.15.2)\n", .{});
    std.debug.print("============================================================\n", .{});
    std.debug.print("运行权限: {s}\n", .{if (win32.isElevated()) "管理员 (Administrator)" else "普通用户 (Standard User)"});
    std.debug.print("系统运行时间: {d} 秒\n", .{win32.GetTickCount64() / 1000});

    var mem = win32.MEMORYSTATUSEX{};
    if (win32.GlobalMemoryStatusEx(&mem) != 0) {
        std.debug.print("内存状态: 使用率 {d}%, 总计 {d} MB, 可用 {d} MB\n", .{
            mem.dwMemoryLoad,
            mem.ullTotalPhys / (1024 * 1024),
            mem.ullAvailPhys / (1024 * 1024),
        });
    }

    // [1] Comptime layout check already verified at compile time
    std.debug.print("\n=== [1] Win32 结构体 comptime 布局校验 ===\n", .{});
    std.debug.print("  全部结构体 (@sizeOf/@offsetOf) 编译期校验通过\n", .{});

    // [2] SQLite verification
    std.debug.print("\n=== [2] SQLite 编译与读写验证 ===\n", .{});
    {
        var db = try sqlite.Database.open(":memory:");
        defer db.close();
        try db.exec("CREATE TABLE p0_check (k TEXT, v INT); INSERT INTO p0_check VALUES ('ok', 42);");
        var stmt = try db.prepare("SELECT k, v FROM p0_check;");
        defer stmt.finalize();
        if (try stmt.step()) {
            std.debug.print("  SQLite {s} 读写通过: ({s}, {d})\n", .{
                sqlite.Database.version(),
                stmt.columnText(0),
                stmt.columnInt64(1),
            });
        }
    }

    // [3] TOML verification on real config/default.toml & data/drive_attributes.toml
    std.debug.print("\n=== [3] TOML 解析器验证 ===\n", .{});
    {
        const cfg_bytes = try std.fs.cwd().readFileAlloc(allocator, "config/default.toml", 1024 * 1024);
        defer allocator.free(cfg_bytes);
        var cfg = try toml.Document.parse(allocator, cfg_bytes);
        defer cfg.deinit();
        std.debug.print("  config/default.toml 解析通过: lang={s}, smart_interval={d}ms, cpu_warn={d}°C\n", .{
            cfg.getString("general", "language") orelse "?",
            cfg.getInt("polling", "smart_interval_ms") orelse -1,
            cfg.getInt("alerts.thresholds", "cpu_warning_c") orelse -1,
        });

        const db_bytes = try std.fs.cwd().readFileAlloc(allocator, "data/drive_attributes.toml", 1024 * 1024);
        defer allocator.free(db_bytes);
        var attr_doc = try toml.Document.parse(allocator, db_bytes);
        defer attr_doc.deinit();
        std.debug.print("  data/drive_attributes.toml 解析通过: attr_05={s}\n", .{
            attr_doc.getString("attr_05", "name_zh") orelse "?",
        });
    }

    // [4] Storage enumeration, NVMe SMART, Temperature Descriptor, ATA
    verifyStorage();

    // [5] GPU D3DKMT + NVML
    verifyGpuD3dkmtAndNvml();

    // [6] GUI + ImPlot + Chinese font + DPI + Tray coexistence
    try verifyGuiAndTray(allocator);

    std.debug.print("\n============================================================\n", .{});
    std.debug.print("  P0 技术验证完成！\n", .{});
    std.debug.print("============================================================\n", .{});
    _ = log;
}
