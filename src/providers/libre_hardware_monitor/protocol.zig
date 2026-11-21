const std = @import("std");

/// LibreHardwareMonitor 辅助进程本机 IPC 协议定义（规范 §3.4.1 / §9 第 10 条）。
/// - 独立进程隔离（MPL-2.0 边界）
/// - 仅允许只读查询
/// - 帧格式：4 字节小端长度前缀 + UTF-8 JSON 负载
/// - 严格限制单条消息最大 1 MB，防止异常或恶意对端造成内存耗尽
pub const PROTOCOL_VERSION: u32 = 1;
pub const MAX_MESSAGE_BYTES: u32 = 1024 * 1024; // 1 MB 上限
pub const PIPE_NAME_UTF8: []const u8 = "\\\\.\\pipe\\WinHardwareMonitor_LhmBridge_v1";

pub const FrameError = error{
    MessageTooLarge,
    EmptyMessage,
    TruncatedFrame,
    OutOfMemory,
};

/// 编码长度前缀帧（[4B LE len][payload]）
pub fn encodeFrame(allocator: std.mem.Allocator, payload: []const u8) FrameError![]u8 {
    if (payload.len == 0) return error.EmptyMessage;
    if (payload.len > MAX_MESSAGE_BYTES) return error.MessageTooLarge;

    const frame = try allocator.alloc(u8, 4 + payload.len);
    std.mem.writeInt(u32, frame[0..4], @intCast(payload.len), .little);
    @memcpy(frame[4..], payload);
    return frame;
}

/// 校验并解码长度前缀帧，返回负载切片视图
pub fn decodeFrame(frame: []const u8) FrameError![]const u8 {
    if (frame.len < 4) return error.TruncatedFrame;
    const len = std.mem.readInt(u32, frame[0..4], .little);
    if (len == 0) return error.EmptyMessage;
    if (len > MAX_MESSAGE_BYTES) return error.MessageTooLarge;
    if (frame.len < 4 + len) return error.TruncatedFrame;
    return frame[4 .. 4 + len];
}

/// 只读传感器快照响应解析（供可选辅助进程返回 CPU 温度/功耗/主板传感器）
pub const HelperSensorItem = struct {
    hardware: []const u8,
    name: []const u8,
    sensor_type: []const u8,
    value: f64,
    unit: []const u8,
};

pub const HelperSnapshotResponse = struct {
    version: u32 = 0,
    is_admin: bool = false,
    sensors: []const HelperSensorItem = &.{},
};

pub fn parseSnapshotJson(allocator: std.mem.Allocator, json_bytes: []const u8) !std.json.Parsed(HelperSnapshotResponse) {
    return std.json.parseFromSlice(HelperSnapshotResponse, allocator, json_bytes, .{
        .ignore_unknown_fields = true,
    });
}

test "IPC frame codec enforces 1 MB limit and round-trips JSON snapshot" {
    const sample =
        \\{"version":1,"sensors":[{"hardware":"Intel Core i5-12490F","name":"CPU Package","sensor_type":"Temperature","value":48.5,"unit":"C"}]}
    ;
    const frame = try encodeFrame(std.testing.allocator, sample);
    defer std.testing.allocator.free(frame);

    const decoded = try decodeFrame(frame);
    try std.testing.expectEqualStrings(sample, decoded);

    var parsed = try parseSnapshotJson(std.testing.allocator, decoded);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u32, 1), parsed.value.version);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.sensors.len);
    try std.testing.expectApproxEqAbs(@as(f64, 48.5), parsed.value.sensors[0].value, 1e-6);

    // 超过 1 MB 的伪造长度头必须拒绝（规范 §9 第 10 条）
    var bad_hdr = [_]u8{ 0, 0, 0, 0, '{', '}' };
    std.mem.writeInt(u32, bad_hdr[0..4], MAX_MESSAGE_BYTES + 1, .little);
    try std.testing.expectError(error.MessageTooLarge, decodeFrame(&bad_hdr));
}
