# WinHardware Monitor v0.1.0（含 V2.2 特性）发布说明

## 1. 跨平台交付构建说明

本项目源码支持一键构建 **Windows 10/11 x64** 与 **Linux x86_64** 两个平台的安装包与便携包（构建产物默认生成在本地 `dist/` 与 `dist-linux/`，不纳入 Git 源码仓库，参见 [docs/BUILD.md](BUILD.md)）：

### Windows x64（`packaging/windows/build_release.ps1`）
- `WinHardwareMonitor-0.1.0-win64-setup.exe`：Inno Setup 6 用户级安装程序（默认无需管理员权限；提供**开机自动启动**与**可选 MPL-2.0 扩展辅助进程**勾选项；卸载时询问并默认保留用户配置与历史数据库）。
- `WinHardwareMonitor-0.1.0-win64-portable.zip`：绿色便携版（内置 `portable.flag`，配置、SQLite 历史库与日志全部保存在程序同级目录）。
- `winhardware-monitor.exe`：核心 GUI + CLI 主程序（Apache-2.0，Windows GUI 子系统无多余黑框，零内核驱动，默认零网络访问）。
- `WinHardwareMonitor.LhmHelper.exe`：可选、进程隔离的 LibreHardwareMonitor 只读辅助进程（MPL-2.0，同用户 Medium Integrity 本地命名管道）。
- `SHA256SUMS.txt`：全部产物的 SHA-256 校验清单。

### Linux x86_64（`packaging/linux/build_linux_packages.sh`）
- `winhardware-monitor-0.1.0-linux-x86_64.tar.gz`：免安装便携压缩包。
- `winhardware-monitor_0.1.0_amd64.deb`：Debian / Ubuntu / Mint 安装包。
- `winhardware-monitor-0.1.0-1.x86_64.rpm`：Fedora / RHEL / CentOS / Rocky / openSUSE 安装包。
- `SHA256SUMS.txt`：全部产物的 SHA-256 校验清单。

---

## 2. 核心功能摘要

- **真实跨平台硬件监控（绝不编造数据）**：
  - **Windows**：CPU 总体/每核实时负载与计算频率、物理内存与 SMBIOS 插槽明细、主板 SMBIOS、实时磁盘读写吞吐（MB/s & IOPS）与电池状态、NVMe SMART + 温度探头 `#1–#8`（普通用户直读）、ATA + 标准 T10 SAT SMART 与 `CHECK POWER MODE (0xE5)` 休眠保护（管理员）、GPU 温度/功耗/显存/频率/风扇（D3DKMT + 动态 `nvml.dll`）。
  - **Linux**：原生内核 `hwmon`（免驱动直读 CPU 封装与每核温度、主板温度、风扇与电压）、`/proc/stat` + `cpufreq`、`/proc/meminfo` + DMI、DRM GPU、以及 `NVME_IOCTL_ADMIN_CMD` / `SG_IO` 标准 T10 SAT SMART，支持无界面 `--cli` 终端体检。
- **21 条登记健康规则引擎**：严格执行规范 §2.5.5 全部 21 条编号规则与计数基线机制，绝不将 SMART 原始值折算为单一健康百分比，绝不将 RAID / 虚拟盘 / 无 SMART U 盘误报为“正常”。
- **中 / 英 / 日三语全栈一致**：支持 `简体中文 / English / 日本語` 实时无重启切换并持久化（含全部 11 页面、枚举标签、26 项 ATA SMART 属性名、21 条健康规则证据、全传感器统计表、托盘菜单、测试报告、诊断包与 CLI `--lang zh|en|ja`），自动通过 `merge_mode` 合并系统日文字体。
- **极低硬件占用设计**：无锁原子序号增量快照同步（内存拷贝降低 >100×）、静置自动降频至 **1 FPS**、最小化/托盘后进入 **0 FPS 零渲染休眠**、ImPlot 256 点视窗切片。
- **V2.2 系统友好型深度硬件测试与智能诊断套件**：
  - 默认低优先级「温和防卡顿模式」（预留 1 逻辑核、可用内存 35% 上限、磁盘剩余空间 `>= 2×文件+512MB` 护栏、实时高温自动熔断）；
  - 完整覆盖 **CPU 单核/多核与热降频分析**、**内存 L1/L2/L3/RAM 延迟 + 多核拷贝 + 4 轮位翻转校验**、**自定义目录无缓存磁盘 SEQ1M/RND4K + 完整性比对 + Min/Avg/P95/P99/Max 尾延迟**、**GPU OpenGL 3.3 离屏片段着色器烤机（3 档强度 + 实时预览 + 1% Low FPS）**、**整机安全联烤** 与 **一键全套体检**；
  - 内置实时性能/温度双轴曲线、三语智能诊断建议、测试前环境提醒及 SQLite `benchmark_history` 历史对比表。
- **本地历史、告警中心与可靠开机自启**：
  - SQLite 9 表 Schema、WAL 模式 60 秒批量刷盘、1m → 15m 分级降采样、损坏自动备份重建；
  - 30 秒防抖 / 5°C 回差 / 30 分钟抑制告警引擎联动托盘气泡通知；
  - Windows `HKCU\...\Run` + `StartupApproved\Run` 状态检测与自动恢复启用 + `--autostart` 延迟 2 秒静默托盘启动；Linux XDG `.desktop` 自启。

---

## 3. 安全、权限与实机边界声明

- **代码签名（Q7）**：源码仓库不包含商业代码签名证书；正式对外分发前请使用 `packaging/windows/sign.ps1` 注入有效证书签名并核查主流安全引擎误报。
- **扩展组件与驱动（Q8）**：主程序默认关闭扩展组件且绝不静默安装任何内核驱动；启用 `WinHardwareMonitor.LhmHelper.exe` 需用户手动点击 UAC 启动，如在开启内存完整性的 Windows 11 环境下读取 CPU/主板传感器请按官方文档自行安装 PawnIO 驱动。
- **实机验证边界**：完整实测数据与尚未实机验证清单详见 [docs/HARDWARE_SUPPORT.md](HARDWARE_SUPPORT.md)。
