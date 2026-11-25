//! 全项目自动化单元测试统一入口（由 `zig build test` 执行）。
//! 涵盖核心数据模型、21 条磁盘健康规则、告警防抖回差、硬件压测引擎、TOML 解析、
//! SQLite 降采样与损坏恢复、Win32/NVMe/ATA/SAT 采集解析、LHM IPC 协议与脱敏诊断报告。
const std = @import("std");

test {
    // 核心层（跨平台纯逻辑）
    _ = @import("core/i18n.zig");
    _ = @import("core/sensor.zig");
    _ = @import("core/sensor_stats.zig");
    _ = @import("core/benchmarks.zig");
    _ = @import("core/telemetry.zig");
    _ = @import("core/device_id.zig");
    _ = @import("core/health_rules.zig");
    _ = @import("core/alert.zig");

    // 工具与本地数据库层
    _ = @import("utils/toml.zig");
    _ = @import("database/sqlite.zig");
    _ = @import("database/repository.zig");

    // Windows 硬件采集与可选扩展 IPC 层
    _ = @import("providers/windows/win32.zig");
    _ = @import("providers/windows/smbios.zig");
    _ = @import("providers/windows/system_info.zig");
    _ = @import("providers/windows/gpu_provider.zig");
    _ = @import("providers/libre_hardware_monitor/protocol.zig");
    _ = @import("providers/libre_hardware_monitor/client.zig");

    // 存储枚举与 SMART 采集解析层
    _ = @import("collectors/storage/enumerate.zig");
    _ = @import("collectors/storage/nvme_smart.zig");
    _ = @import("collectors/storage/ata_smart.zig");

    // 平台封装、配置服务、CLI 与状态机
    _ = @import("cli.zig");
    _ = @import("platform/single_instance.zig");
    _ = @import("platform/tray.zig");
    _ = @import("platform/autostart.zig");
    _ = @import("platform/paths.zig");
    _ = @import("services/configuration.zig");
    _ = @import("services/diagnostics.zig");
    _ = @import("app/state.zig");
}
