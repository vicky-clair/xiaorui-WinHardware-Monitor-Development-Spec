# WinHardware Monitor v0.1.0 发布说明

## 1. 交付产物（通过 `packaging/windows/build_release.ps1` 构建）

- `WinHardwareMonitor-0.1.0-win64-setup.exe`：Inno Setup 6 用户级安装程序（默认无需管理员权限；可选勾选 MPL-2.0 扩展辅助进程；卸载时询问并默认保留用户配置与历史数据库）。
- `WinHardwareMonitor-0.1.0-win64-portable.zip`：绿色便携版（内置 `portable.flag`，配置、SQLite 数据库与日志保存在程序同目录）。
- `winhardware-monitor.exe`：核心 GUI 主程序（Apache-2.0，Windows GUI 子系统无多余黑框，零内核驱动，默认零网络访问）。
- `WinHardwareMonitor.LhmHelper.exe`：可选、进程隔离的 LibreHardwareMonitor 只读辅助进程（MPL-2.0，支持同用户跨完整性级别本地命名管道通信，双击提示后台运行状态）。
- `SHA256SUMS.txt`：全部发布产物的 SHA-256 校验清单。

## 2. 功能摘要

- **真实硬件监控（绝不编造数据）**：CPU 总体/每核实时负载与计算频率、物理内存与 SMBIOS 插槽明细、主板 SMBIOS、磁盘实时吞吐（MB/s & IOPS）与电池状态、NVMe SMART + 温度探头 `#1–#8`（普通用户直读）、ATA + 标准 T10 SAT SMART 与 `CHECK POWER MODE (0xE5)` 休眠保护（管理员）、GPU 温度/功耗/显存/频率/风扇（D3DKMT + 动态 NVML）。
- **21 条登记健康规则引擎**：严格执行规范 §2.5.5 全部 21 条编号规则与计数基线机制，不将 SMART 原始值折算为单一健康百分比。
- **全传感器表与 CSV 导出**：HWiNFO64 风格当前/最小/平均/最大统计，支持一键清零与 UTF-8 BOM CSV 导出。
- **V2.0 主动硬件测试套件**：CPU 多线程确定性算力校验、内存 4 轮位翻转校验、磁盘文件级 SEQ1M/RND4K 基准（需二次确认且绝不写裸盘）、GPU OpenGL 3.3 渲染烤机、可选 ATA SMART 短自检，内置实时高温自动熔断与测试报告导出。
- **本地历史与告警中心**：SQLite 8 表 Schema、60 秒批量写入、1m → 15m 分级降采样、损坏自动备份重建；30 秒防抖、5°C 回差、30 分钟抑制与托盘气泡通知。
- **现代桌面体验**：深色/浅色（黑白）双主题实时切换并同步 Win10/11 原生标题栏、托盘驻留与 0 FPS 最小化节能、开机自启、配置导入导出与全序列号脱敏诊断包导出。

## 3. 安全、权限与实机边界声明

- **代码签名（Q7）**：源码仓库不包含商业代码签名证书；正式对外分发前请使用 `packaging/windows/sign.ps1` 注入有效证书签名并上传主流安全引擎核查误报。
- **扩展组件与驱动（Q8）**：主程序默认关闭扩展组件且不自动安装任何内核驱动；启用 `WinHardwareMonitor.LhmHelper.exe` 需用户手动点击 UAC 启动，如在 Windows 11 内存完整性环境下读取 CPU/主板传感器请自行按官方文档安装 PawnIO 驱动。
- **实机验证范围**：详见 `docs/HARDWARE_SUPPORT.md`。
