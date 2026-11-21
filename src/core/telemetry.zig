const std = @import("std");

/// 固定容量内存环形缓冲区（规范 §5.3 / §6）：
/// 用于图表实时历史数据（默认 1800 点 = 2 秒采样保留 1 小时），零动态分配、O(1) 写入。
pub fn RingBuffer(comptime capacity: usize) type {
    return struct {
        const Self = @This();

        pub const Stats = struct {
            count: usize = 0,
            current: f64 = 0.0,
            min: f64 = 0.0,
            max: f64 = 0.0,
            avg: f64 = 0.0,
        };

        xs: [capacity]f64 = [_]f64{0.0} ** capacity,
        ys: [capacity]f64 = [_]f64{0.0} ** capacity,
        head: usize = 0,
        len: usize = 0,

        pub fn push(self: *Self, x: f64, y: f64) void {
            self.xs[self.head] = x;
            self.ys[self.head] = y;
            self.head = (self.head + 1) % capacity;
            if (self.len < capacity) {
                self.len += 1;
            }
        }

        pub fn clear(self: *Self) void {
            self.head = 0;
            self.len = 0;
        }

        /// 按时间升序拷贝出连续数组，直接供给 ImPlot 绘制
        pub fn copyOrdered(self: *const Self, out_x: []f64, out_y: []f64) usize {
            const n = @min(self.len, @min(out_x.len, out_y.len));
            if (n == 0) return 0;
            // 取最新的 n 个点
            const oldest = (self.head + capacity - self.len) % capacity;
            const start = (oldest + (self.len - n)) % capacity;
            for (0..n) |i| {
                const idx = (start + i) % capacity;
                out_x[i] = self.xs[idx];
                out_y[i] = self.ys[idx];
            }
            return n;
        }

        pub fn stats(self: *const Self) Stats {
            if (self.len == 0) return .{};
            const oldest = (self.head + capacity - self.len) % capacity;
            var min_v: f64 = std.math.inf(f64);
            var max_v: f64 = -std.math.inf(f64);
            var sum: f64 = 0.0;
            var last: f64 = 0.0;
            for (0..self.len) |i| {
                const v = self.ys[(oldest + i) % capacity];
                if (v < min_v) min_v = v;
                if (v > max_v) max_v = v;
                sum += v;
                last = v;
            }
            return .{
                .count = self.len,
                .current = last,
                .min = min_v,
                .max = max_v,
                .avg = sum / @as(f64, @floatFromInt(self.len)),
            };
        }
    };
}

test "RingBuffer wrap-around, ordering, and min/avg/max statistics" {
    var rb = RingBuffer(4){};
    rb.push(1.0, 10.0);
    rb.push(2.0, 20.0);
    rb.push(3.0, 30.0);
    rb.push(4.0, 40.0);
    rb.push(5.0, 50.0); // overwrites (1.0, 10.0)

    try std.testing.expectEqual(@as(usize, 4), rb.len);
    var ox: [4]f64 = undefined;
    var oy: [4]f64 = undefined;
    const n = rb.copyOrdered(&ox, &oy);
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqual(@as(f64, 2.0), ox[0]);
    try std.testing.expectEqual(@as(f64, 5.0), ox[3]);
    try std.testing.expectEqual(@as(f64, 20.0), oy[0]);
    try std.testing.expectEqual(@as(f64, 50.0), oy[3]);

    const s = rb.stats();
    try std.testing.expectEqual(@as(usize, 4), s.count);
    try std.testing.expectApproxEqAbs(@as(f64, 50.0), s.current, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 20.0), s.min, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 50.0), s.max, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 35.0), s.avg, 1e-9);
}
