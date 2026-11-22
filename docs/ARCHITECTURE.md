# 软件架构设计（docs/ARCHITECTURE.md）

## 1. 分层解耦与跨平台架构

项目严格执行四层隔离架构（遵循 `AGENTS.md` 红线 #10：GUI 主线程严禁执行阻塞式硬件查询或数据库写入），并在同一套核心领域模型之上支持 **Windows 10/11 x64（桌面 GUI + CLI）** 与 **Linux x86_64（桌面 GUI + 无界面 CLI）**：

```text
┌───────────────────────────────────────────────────────────────────────────┐
│  1. 展示与交互层 (src/gui/ + src/cli.zig)                                  │
│  window.zig / navigation.zig / views.zig / widgets.zig / theme.zig        │
│  fonts.zig / gpu_shader.zig / cli.zig                                     │
│  - 仅通过无锁原子序号 + tryCopySnapshotIfChanged() 增量消费后台快照         │
│  - 简体中文 / English / 日本語 三语全栈一致 + CJK 字体 merge_mode 合并      │
│  - 深色 / 浅色双主题实时切换，同步 Win10/11 原生标题栏（DWM）               │
│  - 三态低占用渲染（活跃 60 FPS / 静止 1 FPS / 托盘最小化 0 FPS）            │
│  - gpu_shader.zig：OpenGL 3.3 FBO 离屏片段着色器 GPU 烤机（懒创建/即释放）  │
│  - cli.zig：无界面服务器/SSH 终端体检、基准测试与三语报告输出               │
└──────────────────────────────────▲────────────────────────────────────────┘
                                   │ 无锁序号检测 + 增量只读快照 (SharedTelemetry / BenchmarkSnapshot)
┌──────────────────────────────────┴────────────────────────────────────────┐
│  2. 核心领域与业务服务层 (src/core/, src/services/, src/app/)               │
│  - i18n.zig          : 线程安全全局三语路由（zh-CN / en-US / ja-JP）        │
│  - sensor.zig        : 10 种传感器状态枚举 + 4 种准确度分类                 │
│  - sensor_stats.zig  : HWiNFO 风格稳定键统计表（当前/最小/平均/最大/CSV）   │
│  - device_id.zig     : SHA-256 跨重启稳定设备 ID 与序列号后 4 位脱敏        │
│  - health_rules.zig  : 规范 §2.5.5 全部 21 条编号健康规则与计数基线         │
│  - alert.zig         : 30s 防抖 / 5°C 回差 / 30m 抑制告警引擎               │
│  - benchmarks.zig    : V2.2 系统友好型测试引擎（低优先级/温和护栏/熔断）    │
│  - monitoring.zig    : 独立后台工作线程，统一调度采集、入库、告警与历史保存 │
│  - configuration.zig : TOML 配置解析、范围钳位、三语与主题持久化            │
│  - diagnostics.zig   : 全序列号脱敏三语诊断报告生成                         │
└──────────────────────────────────▲────────────────────────────────────────┘
                                   │
┌──────────────────────────────────┴────────────────────────────────────────┐
│  3. 硬件采集与提供程序层 (src/collectors/, src/providers/)                  │
│  [Windows x64]                                                            │
│  - windows/win32.zig       : 手写 Win32 绑定 + comptime 布局校验           │
│  - windows/system_info.zig : CPU 总体与每核负载、内存、电池、SMBIOS         │
│  - windows/pdh.zig         : PDH CPU 性能与物理磁盘实时吞吐/IOPS            │
│  - windows/gpu_provider.zig: 厂商无关 D3DKMT + 动态 nvml.dll                │
│  - storage/enumerate.zig   : 零权限物理盘枚举与 RAID/虚拟盘识别             │
│  - storage/nvme_smart.zig  : NVMe Log Page 02h + Identify WCTEMP/CCTEMP    │
│  - storage/ata_smart.zig   : ATA + 标准 T10 SAT + 0xE5 休眠防唤醒保护       │
│  - libre_hardware_monitor/ : 可选 MPL-2.0 命名管道只读 IPC 客户端           │
│  [Linux x86_64]                                                           │
│  - linux/hwmon.zig         : 内核 /sys/class/hwmon（CPU 温/功耗/风扇/电压） │
│  - linux/system_info.zig   : /proc/stat、cpufreq、meminfo、diskstats、DMI  │
│  - linux/gpu_provider.zig  : /sys/class/drm/card* + 下属 hwmon             │
│  - linux/storage.zig       : /sys/block + NVME_IOCTL + SG_IO T10 SAT       │
└──────────────────────────────────▲────────────────────────────────────────┘
                                   │
┌──────────────────────────────────┴────────────────────────────────────────┐
│  4. 平台与持久化层 (src/platform/, src/database/)                           │
│  - single_instance.zig : Windows 命名互斥体单实例与唤醒已有窗口             │
│  - message_window.zig  : 托盘交互 / TaskbarCreated / 热插拔 / 电源恢复      │
│  - autostart.zig       : Windows HKCU\Run + StartupApproved / Linux XDG    │
│  - elevation.zig       : 显式 UAC 管理员重启与 LHM 辅助进程按需拉起         │
│  - paths.zig           : 安装模式 (%LOCALAPPDATA% / XDG) 与便携模式切换     │
│  - database/repository.zig : SQLite 9 表 Schema（含 benchmark_history）     │
└───────────────────────────────────────────────────────────────────────────┘
```

## 2. 低硬件占用与数据流优化

为确保长时间常驻监控不拖慢前台游戏、影音或办公软件，程序实现了四级降耗机制：

1. **无锁序号增量快照同步**：`MonitoringService` 在后台线程更新快照后递增原子序号 `latest_seq_atomic`；GUI 线程每帧先读一次原子序号，仅在序号变化时加锁调用 `tryCopySnapshotIfChanged()` 拷贝约 280 KB 结构体，消除 60 FPS 期间 >100× 的冗余内存拷贝与锁竞争。
2. **三态自适应渲染帧率**：
   - 有鼠标/键盘操作或 GPU 烤机进行中：**60 FPS** 流畅响应；
   - 前台无交互静置：**1 FPS** 极低刷新率（收到后台新样本或用户交互时即时唤醒）；
   - 最小化到系统托盘（或 `--autostart` 静默自启）：**0 FPS** 零渲染休眠（主线程暂停 OpenGL 绘制，仅响应 Win32 托盘消息）。
3. **图表窗口切片**：`drawLiveAreaPlot` 仅提取最近 60 秒视窗所需的最多 256 个采样点提交给 ImPlot，降低 7× 栈拷贝与 GPU 顶点提交。
4. **磁盘零干扰被动监测**：默认采集周期（系统/GPU 2 秒、磁盘温度 10 秒、SMART ≥ 60 秒且强制下限 30 秒），电池供电下自动拉长 SMART 间隔；对机械盘先发 `CHECK POWER MODE (0xE5)`，处于休眠态时默认跳过，绝不频繁唤醒磁头。

## 3. 进程隔离与双许可证边界

- **主程序（`winhardware-monitor.exe` / `winhardware-monitor`）**：`Apache-2.0`，Windows 下使用 GUI 子系统（无控制台黑框），纯用户态原生 API，零内核驱动、默认零网络访问。
- **可选 Windows 辅助进程（`helpers/lhm_bridge/WinHardwareMonitor.LhmHelper.exe`）**：`MPL-2.0`，独立单文件进程运行，通过本机命名管道 `\\.\pipe\WinHardwareMonitor_LhmBridge_v1` 通信。
  - **帧协议（v1）**：`[4 字节小端长度][UTF-8 JSON]`，单帧硬上限 `1 MB`；
  - **安全边界**：`PipeSecurity` 仅允许当前登录用户 SID 访问、显式拒绝 `NetworkSid`，并附加 `Medium Integrity` 标签（`S:(ML;;NW;;;ME)`），让普通权限主程序也能安全读取管理员权限辅助进程的只读传感器数据；
  - **模块约束**：仅启用 CPU/主板/控制器/内存只读查询，显式禁用 Storage/GPU/Network，绝不干扰磁盘休眠。

## 4. V2.2 硬件测试引擎与数据库 Schema

- **系统友好型防卡顿调度（`src/core/benchmarks.zig`）**：
  - 后台测试线程自动降级为低优先级（Windows `THREAD_PRIORITY_BELOW_NORMAL` / Linux `nice +10`）；
  - 默认开启「温和防卡顿模式」（`gentle_mode = true`）：自动保留 1 个逻辑核心给 OS 与前台任务、内存测试上限限制为当前可用物理内存的 35%、磁盘测试前强制检测目标目录剩余空间 `>= 2 × 文件大小 + 512 MB`；
  - 所有测试全程受实时高温熔断器保护（默认 `90°C`，可调 `70–100°C`）。
- **GPU OpenGL 3.3 离屏着色器（`src/gui/gpu_shader.zig`）**：
  - 仅在用户点击启动 GPU/联烤/体检时才懒创建离屏 FBO 与片段着色器，测试结束或取消后立即销毁并释放显存；支持轻量/均衡/高负载 3 档安全强度，并将离屏纹理直接实时预览到 ImGui 卡片中。
- **SQLite 9 表持久化（`src/database/repository.zig`）**：
  - 在原有 8 张表（`schema_meta`、`devices`、`sensor_samples_1m`、`sensor_samples_15m`、`smart_snapshots`、`smart_baselines`、`alert_events`、`app_events`）基础上，新增第 9 张表 `benchmark_history`，记录每次硬件测试的成绩、峰值温度、错误数与结论，供历史对比查看；
  - 全部写入均在后台线程通过 WAL 模式批量提交（默认 60 秒刷盘），数据库损坏时自动备份 `.corrupt` 并安全重建。

## 5. 国际化、字体与开机自启设计

- **三语全栈一致（`src/core/i18n.zig`）**：`Language` 枚举支持 `zh-CN` / `en-US` / `ja-JP`，所有页面文案、枚举标签、26 项 ATA SMART 属性名、21 条健康规则证据、全传感器统计表、托盘菜单与 CLI 输出均统一走 `i18n`；统计表内部以语言无关的稳定 `key` 索引，运行中切换语言不会产生重复行。
- **CJK 动态字形合并（`src/gui/fonts.zig`）**：优先加载系统中文主字体（Windows `msyh.ttc` / Linux `NotoSansCJK`），再通过 Dear ImGui `merge_mode` 自动合并系统日文字体（`YuGothM.ttc` / `meiryo.ttc` / `msgothic.ttc`），无需向安装包打包数十 MB 字体文件即可清晰显示中、英、日三语文字。
- **可靠开机自启（`src/platform/autostart.zig`）**：
  - Windows 写入 `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` 并附加 `--autostart` 参数，同时检测并复位 `Explorer\StartupApproved\Run` 中可能残留的“已禁用”标记；
  - 带 `--autostart` 启动时延迟 2 秒等待桌面与 OpenGL 驱动就绪，随后静默驻留托盘（0 FPS 零占用）；Linux 端自动生成 `~/.config/autostart/winhardware-monitor.desktop`。
