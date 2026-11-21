//! SQLite 3.53.2 轻量级 Zig 安全封装（通过 build.zig 静态编译 amalgamation C 源码）。
//! 开启线程安全（FULLMUTEX）、5 秒忙等待超时、WAL 日志模式与外键约束。
const std = @import("std");

pub const c = @cImport({
    @cInclude("sqlite3.h");
});

/// SQLite 操作错误集合
pub const Error = error{
    OpenFailed,
    ExecFailed,
    PrepareFailed,
    BindFailed,
    StepFailed,
};

/// 数据库连接句柄封装（调用方必须使用 `defer db.close()` 显式释放）
pub const Database = struct {
    handle: *c.sqlite3,

    /// 打开或创建数据库文件（支持 `:memory:` 内存库与 UTF-8 含中文路径）
    pub fn open(path_z: [:0]const u8) Error!Database {
        var db: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open_v2(
            path_z.ptr,
            &db,
            c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_FULLMUTEX,
            null,
        );
        if (rc != c.SQLITE_OK or db == null) {
            if (db) |d| _ = c.sqlite3_close(d);
            return error.OpenFailed;
        }
        var self = Database{ .handle = db.? };
        _ = c.sqlite3_busy_timeout(self.handle, 5000);
        // 启用 WAL 模式提升并发读写响应速度（对 :memory: 自动忽略）
        self.exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON;") catch {};
        return self;
    }

    /// 关闭数据库连接并释放底层资源
    pub fn close(self: *Database) void {
        _ = c.sqlite3_close(self.handle);
    }

    /// 执行单条或多条无返回结果的 SQL 语句
    pub fn exec(self: *Database, sql_z: [:0]const u8) Error!void {
        var errmsg: [*c]u8 = null;
        const rc = c.sqlite3_exec(self.handle, sql_z.ptr, null, null, &errmsg);
        if (errmsg != null) {
            c.sqlite3_free(errmsg);
        }
        if (rc != c.SQLITE_OK) return error.ExecFailed;
    }

    /// 预编译参数化 SQL 语句，防止注入并提升批量写入性能
    pub fn prepare(self: *Database, sql_z: [:0]const u8) Error!Statement {
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.handle, sql_z.ptr, -1, &stmt, null);
        if (rc != c.SQLITE_OK or stmt == null) return error.PrepareFailed;
        return .{ .stmt = stmt.? };
    }

    /// 返回当前静态链接的 SQLite 版本字符串
    pub fn version() [:0]const u8 {
        return std.mem.span(c.sqlite3_libversion());
    }
};

/// 预编译语句句柄封装（必须配对 `defer stmt.finalize()`）
pub const Statement = struct {
    stmt: *c.sqlite3_stmt,

    /// 销毁预编译语句释放资源
    pub fn finalize(self: *Statement) void {
        _ = c.sqlite3_finalize(self.stmt);
    }

    /// 绑定 64 位整数参数（1-based 索引）
    pub fn bindInt64(self: *Statement, index: c_int, val: i64) Error!void {
        if (c.sqlite3_bind_int64(self.stmt, index, val) != c.SQLITE_OK) return error.BindFailed;
    }

    /// 绑定双精度浮点参数（1-based 索引）
    pub fn bindDouble(self: *Statement, index: c_int, val: f64) Error!void {
        if (c.sqlite3_bind_double(self.stmt, index, val) != c.SQLITE_OK) return error.BindFailed;
    }

    /// 绑定 UTF-8 文本参数（SQLITE_TRANSIENT 确保 SQLite 内部拷贝一份副本）
    pub fn bindText(self: *Statement, index: c_int, text: []const u8) Error!void {
        const rc = c.sqlite3_bind_text(
            self.stmt,
            index,
            text.ptr,
            @intCast(text.len),
            c.SQLITE_TRANSIENT,
        );
        if (rc != c.SQLITE_OK) return error.BindFailed;
    }

    /// 单步推进执行：返回 true 表示有结果行，false 表示执行完成
    pub fn step(self: *Statement) Error!bool {
        const rc = c.sqlite3_step(self.stmt);
        if (rc == c.SQLITE_ROW) return true;
        if (rc == c.SQLITE_DONE) return false;
        return error.StepFailed;
    }

    /// 读取当前结果行指定列的 64 位整数值（0-based 列号）
    pub fn columnInt64(self: *Statement, col: c_int) i64 {
        return c.sqlite3_column_int64(self.stmt, col);
    }

    /// 读取当前结果行指定列的双精度浮点值
    pub fn columnDouble(self: *Statement, col: c_int) f64 {
        return c.sqlite3_column_double(self.stmt, col);
    }

    /// 读取当前结果行指定列的 UTF-8 文本切片（生命周期至下次 step/finalize）
    pub fn columnText(self: *Statement, col: c_int) []const u8 {
        const ptr = c.sqlite3_column_text(self.stmt, col);
        const len: usize = @intCast(c.sqlite3_column_bytes(self.stmt, col));
        if (ptr == null or len == 0) return "";
        return ptr[0..len];
    }
};

test "SQLite open, write, query, and 128-bit text storage" {
    var db = try Database.open(":memory:");
    defer db.close();

    try db.exec(
        \\CREATE TABLE telemetry_test (
        \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\  sensor_id TEXT NOT NULL,
        \\  val REAL NOT NULL,
        \\  big_counter TEXT NOT NULL
        \\);
    );

    {
        var ins = try db.prepare("INSERT INTO telemetry_test (sensor_id, val, big_counter) VALUES (?, ?, ?);");
        defer ins.finalize();
        try ins.bindText(1, "nvme0:temp");
        try ins.bindDouble(2, 38.5);
        try ins.bindText(3, "340282366920938463463374607431768211455"); // max u128
        _ = try ins.step();
    }

    {
        var sel = try db.prepare("SELECT sensor_id, val, big_counter FROM telemetry_test;");
        defer sel.finalize();
        try std.testing.expect(try sel.step());
        try std.testing.expectEqualStrings("nvme0:temp", sel.columnText(0));
        try std.testing.expectApproxEqAbs(@as(f64, 38.5), sel.columnDouble(1), 1e-9);
        try std.testing.expectEqualStrings("340282366920938463463374607431768211455", sel.columnText(2));
    }
}
