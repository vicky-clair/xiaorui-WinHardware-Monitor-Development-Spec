# WinHardwareMonitor.LhmHelper（可选扩展辅助进程）

本目录包含 WinHardware Monitor 的**可选、独立进程隔离**硬件传感器扩展组件，基于开源 [LibreHardwareMonitorLib](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor)（MPL-2.0 许可）。

## 安全与边界声明（严格遵守规范 §1.2 / §3.4 / §9）

1. **默认关闭、零强依赖**：主程序 `winhardware-monitor.exe`（Apache-2.0）在未启动或未安装本扩展进程时所有核心功能照常运行。
2. **严格只读 & 零网络访问**：仅启用 CPU、主板、风扇控制器与内存传感器只读查询；禁用磁盘（避免干扰主程序休眠保护）、禁用 GPU（由主程序原生 D3DKMT/NVML 读取）、禁用网络模块。
3. **本机同用户 IPC 隔离**：通过 Windows 命名管道 `\\.\pipe\WinHardwareMonitor_LhmBridge_v1`（`PipeOptions.CurrentUserOnly`）提供 4 字节长度前缀 + UTF-8 JSON 只读快照，单帧上限 1 MB。
4. **驱动与权限说明（Q8）**：
   - 本扩展组件**不会静默自动安装第三方内核驱动**。
   - 读取 CPU 封装温度、CPU 功耗及主板 Super I/O 传感器（风扇/电压/芯片组温度）需要以**管理员身份**运行本辅助进程；若系统环境要求签名内核驱动（如 Windows 11 开启内核隔离/内存完整性），请按 LibreHardwareMonitor 官方文档自行安装受信任的 **PawnIO** 驱动（`https://pawnio.eu`）。

## 构建命令

```powershell
dotnet publish helpers/lhm_bridge/WinHardwareMonitor.LhmHelper.csproj -c Release -r win-x64 -o zig-out/bin
```
