const std = @import("std");
const builtin = @import("builtin");
const win32 = @import("../windows/win32.zig");
const sensor = @import("../../core/sensor.zig");
const protocol = @import("protocol.zig");

/// 可选 LibreHardwareMonitor 辅助进程 IPC 客户端（规范 §1.2 / §3.4.1 / §9 第 10 条）。
/// - 默认关闭；主程序启动不依赖该进程；
/// - 严格执行 1 MB 帧上限校验；不可用时安全返回 .requires_extension / .transient_error，绝不阻塞 UI。
pub const MAX_EXT_SENSORS = 64;

pub const ExtSensorEntry = struct {
    hardware: [64]u8 = std.mem.zeroes([64]u8),
    hardware_len: usize = 0,
    name: [64]u8 = std.mem.zeroes([64]u8),
    name_len: usize = 0,
    sensor_type: [24]u8 = std.mem.zeroes([24]u8),
    sensor_type_len: usize = 0,
    unit: [12]u8 = std.mem.zeroes([12]u8),
    unit_len: usize = 0,
    value: f64 = 0.0,

    pub fn hardwareSlice(self: *const ExtSensorEntry) []const u8 {
        return self.hardware[0..self.hardware_len];
    }
    pub fn nameSlice(self: *const ExtSensorEntry) []const u8 {
        return self.name[0..self.name_len];
    }
    pub fn sensorTypeSlice(self: *const ExtSensorEntry) []const u8 {
        return self.sensor_type[0..self.sensor_type_len];
    }
    pub fn unitSlice(self: *const ExtSensorEntry) []const u8 {
        return self.unit[0..self.unit_len];
    }
};

pub const ExtensionSnapshot = struct {
    status: sensor.SensorStatus = .requires_extension,
    connected: bool = false,
    helper_is_admin: bool = false,
    cpu_package_temp_c: ?f64 = null,
    cpu_package_power_w: ?f64 = null,
    sensors: [MAX_EXT_SENSORS]ExtSensorEntry = [_]ExtSensorEntry{.{}} ** MAX_EXT_SENSORS,
    sensor_count: usize = 0,
};

pub const LhmClient = struct {
    allocator: std.mem.Allocator,
    enabled: bool = false,

    pub fn poll(self: *const LhmClient) ExtensionSnapshot {
        if (builtin.os.tag == .linux) {
            // Linux 原生内核 hwmon 无需第三方驱动或辅助进程，普通用户即可直接提供 CPU 与主板传感器
            return @import("../linux/hwmon.zig").collectHwmonSnapshot();
        }
        if (!self.enabled) {
            return .{ .status = .requires_extension, .connected = false };
        }

        const resp_bytes = self.sendPipeRequest("{\"version\":1,\"op\":\"snapshot\"}") orelse {
            return .{ .status = .transient_error, .connected = false };
        };
        defer self.allocator.free(resp_bytes);

        return parseResponseToSnapshot(self.allocator, resp_bytes);
    }

    /// 请求独立辅助进程优雅退出
    pub fn requestShutdown(self: *const LhmClient) bool {
        if (builtin.os.tag != .windows) return false;
        const resp = self.sendPipeRequest("{\"version\":1,\"op\":\"shutdown\"}") orelse return false;
        self.allocator.free(resp);
        return true;
    }

    fn sendPipeRequest(self: *const LhmClient, req_json: []const u8) ?[]u8 {
        var pipe_w: [128]u16 = undefined;
        const wlen = std.unicode.utf8ToUtf16Le(&pipe_w, protocol.PIPE_NAME_UTF8) catch return null;
        pipe_w[wlen] = 0;

        // 最多等待 120ms，辅助进程未启动时立即返回 null，不拖慢采集线程
        _ = win32.WaitNamedPipeW(@ptrCast(&pipe_w), 120);

        const handle = win32.CreateFileW(
            @ptrCast(&pipe_w),
            win32.GENERIC_READ | win32.GENERIC_WRITE,
            0,
            null,
            win32.OPEN_EXISTING,
            0,
            null,
        );
        if (handle == win32.INVALID_HANDLE_VALUE) {
            return null;
        }
        defer _ = win32.CloseHandle(handle);

        const frame = protocol.encodeFrame(self.allocator, req_json) catch return null;
        defer self.allocator.free(frame);

        if (!writeExact(handle, frame)) return null;

        var hdr: [4]u8 = undefined;
        if (!readExact(handle, &hdr)) return null;
        const payload_len = std.mem.readInt(u32, &hdr, .little);
        if (payload_len == 0 or payload_len > protocol.MAX_MESSAGE_BYTES) return null;

        const payload = self.allocator.alloc(u8, payload_len) catch return null;
        errdefer self.allocator.free(payload);
        if (!readExact(handle, payload)) {
            self.allocator.free(payload);
            return null;
        }
        return payload;
    }
};

pub fn parseResponseToSnapshot(allocator: std.mem.Allocator, json_bytes: []const u8) ExtensionSnapshot {
    var parsed = protocol.parseSnapshotJson(allocator, json_bytes) catch {
        return .{ .status = .transient_error, .connected = false };
    };
    defer parsed.deinit();

    if (parsed.value.version != protocol.PROTOCOL_VERSION) {
        return .{ .status = .transient_error, .connected = false };
    }

    var snap = ExtensionSnapshot{
        .status = .ok,
        .connected = true,
        .helper_is_admin = parsed.value.is_admin,
    };

    var fallback_cpu_temp: ?f64 = null;

    for (parsed.value.sensors) |item| {
        if (snap.sensor_count < MAX_EXT_SENSORS) {
            var e = ExtSensorEntry{ .value = item.value };
            copyFixed(&e.hardware, &e.hardware_len, item.hardware);
            copyFixed(&e.name, &e.name_len, item.name);
            copyFixed(&e.sensor_type, &e.sensor_type_len, item.sensor_type);
            copyFixed(&e.unit, &e.unit_len, item.unit);
            snap.sensors[snap.sensor_count] = e;
            snap.sensor_count += 1;
        }

        if (std.ascii.eqlIgnoreCase(item.sensor_type, "Temperature")) {
            if (containsIgnoreCase(item.name, "CPU Package") or
                containsIgnoreCase(item.name, "Tctl/Tdie") or
                containsIgnoreCase(item.name, "Core (Tctl/Tdie)") or
                containsIgnoreCase(item.name, "Core Max"))
            {
                if (snap.cpu_package_temp_c == null) {
                    snap.cpu_package_temp_c = item.value;
                }
            } else if (containsIgnoreCase(item.name, "Core Average") or containsIgnoreCase(item.name, "CPU Core")) {
                if (fallback_cpu_temp == null) fallback_cpu_temp = item.value;
            }
        } else if (std.ascii.eqlIgnoreCase(item.sensor_type, "Power")) {
            if (containsIgnoreCase(item.name, "CPU Package") or containsIgnoreCase(item.name, "Package")) {
                if (snap.cpu_package_power_w == null) {
                    snap.cpu_package_power_w = item.value;
                }
            }
        }
    }

    if (snap.cpu_package_temp_c == null) {
        snap.cpu_package_temp_c = fallback_cpu_temp;
    }

    return snap;
}

fn readExact(handle: win32.HANDLE, buf: []u8) bool {
    var off: usize = 0;
    while (off < buf.len) {
        var got: win32.DWORD = 0;
        const ok = win32.ReadFile(handle, buf[off..].ptr, @intCast(buf.len - off), &got, null);
        if (ok == 0 or got == 0) return false;
        off += got;
    }
    return true;
}

fn writeExact(handle: win32.HANDLE, buf: []const u8) bool {
    var off: usize = 0;
    while (off < buf.len) {
        var sent: win32.DWORD = 0;
        const ok = win32.WriteFile(handle, buf[off..].ptr, @intCast(buf.len - off), &sent, null);
        if (ok == 0 or sent == 0) return false;
        off += sent;
    }
    return true;
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

test "LhmClient safely degrades when disabled or helper absent, and parses snapshot JSON" {
    var client = LhmClient{ .allocator = std.testing.allocator, .enabled = false };
    const s1 = client.poll();
    if (builtin.os.tag == .windows) {
        try std.testing.expectEqual(sensor.SensorStatus.requires_extension, s1.status);
        try std.testing.expect(!s1.connected);
    } else {
        // Linux 原生 hwmon 直接采集，无需外部辅助进程
        try std.testing.expect(s1.status == .ok or s1.status == .unsupported);
    }

    const sample_json =
        \\{"version":1,"is_admin":true,"sensors":[
        \\{"hardware":"Intel Core i5-12490F","name":"CPU Package","sensor_type":"Temperature","value":51.5,"unit":"C"},
        \\{"hardware":"Intel Core i5-12490F","name":"CPU Package","sensor_type":"Power","value":28.4,"unit":"W"},
        \\{"hardware":"Nuvoton NCT6798D","name":"Fan #1","sensor_type":"Fan","value":1120,"unit":"RPM"}
        \\]}
    ;
    const parsed = parseResponseToSnapshot(std.testing.allocator, sample_json);
    try std.testing.expect(parsed.connected);
    try std.testing.expect(parsed.helper_is_admin);
    try std.testing.expectEqual(@as(usize, 3), parsed.sensor_count);
    try std.testing.expectApproxEqAbs(@as(f64, 51.5), parsed.cpu_package_temp_c.?, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 28.4), parsed.cpu_package_power_w.?, 1e-6);
}
