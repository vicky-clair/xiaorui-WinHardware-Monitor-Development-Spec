# 软件架构设计（docs/ARCHITECTURE.md）

## 1. 分层解耦架构

项目严格执行四层隔离架构（遵循 `AGENTS.md` 红线 #10：GUI 主线程严禁执行阻塞式硬件查询或数据库写入）：

```text
┌────────────────────────────────────────────────────────────────────┐
│  1. GUI 展示层 (src/gui/)                                           │
│  window.zig / navigation.zig / views.zig / widgets.zig / theme.zig │
│  - 仅通过非阻塞 tryCopySnapshot() 消费后台快照，绝不阻塞渲染帧       │
│  - 支持深色/浅色双主题与 Win10/11 原生标题栏联动                     │
│  - 三态渲染节能（活跃 60 FPS / 静止 2 FPS / 托盘最小化 0 FPS）       │
└───────────────────────────────▲────────────────────────────────────┘
                                │ 线程安全只读快照 (SharedTelemetry / BenchmarkSnapshot)
┌───────────────────────────────┴────────────────────────────────────┐
│  2. 核心领域与业务服务层 (src/core/, src/services/, src/app/)        │
│  - sensor.zig        : 10 种状态枚举 + 4 种准确度分类               │
│  - sensor_stats.zig  : HWiNFO 风格全传感器 Min/Avg/Max 与 CSV 导出  │
│  - device_id.zig     : SHA-256 跨重启稳定设备 ID 与序列号脱敏       │
│  - health_rules.zig  : 规范 §2.5.5 全部 21 条健康判定规则与基线     │
│  - alert.zig         : 30s 防抖 / 5°C 回差 / 30m 抑制告警引擎       │
│  - benchmarks.zig    : V2.0 硬件测试引擎（CPU/内存/磁盘/GPU+熔断）   │
│  - monitoring.zig    : 独立后台工作线程，统一调度采集、入库与告警    │
│  - configuration.zig : TOML 配置校验、安全钳位与导入导出            │
│  - diagnostics.zig   : 全序列号脱敏诊断报告生成                     │
└───────────────────────────────▲────────────────────────────────────┘
                                │
┌───────────────────────────────┴────────────────────────────────────┐
│  3. 硬件采集与提供程序层 (src/collectors/, src/providers/)           │
│  - windows/win32.zig       : 手写 Win32 绑定 + comptime 布局校验    │
│  - windows/system_info.zig : CPU 总体与每核负载、内存、电池、SMBIOS │
│  - windows/pdh.zig         : PDH CPU 性能与物理磁盘读写/IOPS        │
│  - windows/gpu_provider.zig: 厂商无关 D3DKMT + 动态 nvml.dll        │
│  - storage/enumerate.zig   : 零权限物理盘枚举与 RAID/虚拟盘识别     │
│  - storage/nvme_smart.zig  : NVMe Log Page 02h + Identify WCTEMP    │
│  - storage/ata_smart.zig   : ATA + 标准 T10 SAT + 休眠防唤醒保护    │
│  - libre_hardware_monitor/ : 可选 MPL-2.0 命名管道只读 IPC 客户端   │
└───────────────────────────────▲────────────────────────────────────┘
                                │
┌───────────────────────────────┴────────────────────────────────────┐
│  4. 平台与持久化层 (src/platform/, src/database/)                    │
│  - single_instance.zig : 命名互斥体单实例与激活已有窗口             │
│  - message_window.zig  : 托盘交互 / TaskbarCreated / 热插拔 / 电源  │
│  - autostart.zig       : HKCU\...\Run 当前用户开机自启              │
│  - elevation.zig       : 显式 UAC 管理员重启与 LHM 辅助进程启动     │
│  - paths.zig           : 安装模式 (%LOCALAPPDATA%) 与便携模式切换   │
│  - database/repository.zig : SQLite 8 表 Schema、WAL、降采样、恢复  │
└────────────────────────────────────────────────────────────────────┘
```

## 2. 进程隔离与双许可证边界

- **主程序 (`winhardware-monitor.exe`)**：Apache-2.0，Windows GUI 子系统（无控制台黑框），纯用户态 Win32 API，零内核驱动。
- **可选辅助进程 (`helpers/lhm_bridge/WinHardwareMonitor.LhmHelper.exe`)**：MPL-2.0，独立进程运行，通过本机命名管道 `\\.\pipe\WinHardwareMonitor_LhmBridge_v1` 交互。
  - **帧协议（v1）**：`[4 字节小端长度][UTF-8 JSON]`，单帧硬上限 `1 MB`；
  - **权限边界**：`PipeSecurity` 仅允许当前登录用户 SID 访问、显式拒绝 `NetworkSid`，并设置 `Medium Integrity` 标签（`S:(ML;;NW;;;ME)`），允许普通权限主程序安全连接管理员权限辅助进程。

## 3. 界面视觉与布局设计

- **双主题配色**：内置深色（Bento + Grafana 暗黑面板）与高对比浅色两套主题，实时同步 Windows 10/11 原生标题栏（`DwmSetWindowAttribute`）。
- **自适应防裁切布局**：全部 11 个页面的卡片依据 `getContentRegionAvail()` 动态占满窗口剩余空间，避免底部大片留白；长文本统一使用自动换行与可滚动表格，绝不静默截断文字。
- **中文字体策略**：按 `msyh.ttc → simhei.ttf → simsun.ttc` 顺序加载系统字体，依托 Dear ImGui 1.92 动态字形按需光栅化，无需向 EXE 打包数十 MB 字体文件。
