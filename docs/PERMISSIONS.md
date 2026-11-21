# 权限与驱动安全说明（docs/PERMISSIONS.md）

## 1. 核心安全原则

1. **主程序零内核驱动**：`winhardware-monitor.exe` 不包含、不释放、不安装任何 `.sys` 驱动，也不携带任何已知存在提权漏洞的旧驱动（严禁 WinRing0）。
2. **普通用户优先启动**：默认标准用户即可直接运行，严禁静默 UAC 提权；仅当用户主动点击“以管理员身份重启”或“启动 LHM 辅助进程”时触发 UAC。
3. **默认零网络访问**：主程序与可选 LHM 辅助进程均不建立任何对外网络连接，不上传任何硬件序列号、SMART 或诊断信息。
4. **隐私脱敏**：界面显示、日志输出与诊断报告导出均默认对磁盘/内存序列号脱敏（仅保留后 4 位）。

---

## 2. 普通用户 vs 管理员权限能力矩阵

| 能力项 | 普通用户 | 管理员 | 说明 |
| --- | :---: | :---: | --- |
| CPU 总体/每核使用率与计算频率 | ✅ | ✅ | PDH + `NtQuerySystemInformation` |
| 物理内存、SMBIOS 内存条与主板型号 | ✅ | ✅ | `GlobalMemoryStatusEx` + `GetSystemFirmwareTable` |
| 实时磁盘读写吞吐 / IOPS 与电池状态 | ✅ | ✅ | PDH `PhysicalDisk` + `GetSystemPowerStatus` |
| GPU 温度 / 功耗 / 显存 / 频率 / 风扇 | ✅ | ✅ | D3DKMT + 运行时动态 `nvml.dll` |
| NVMe SSD 完整 SMART 与温度 | ✅ | ✅ | Windows 11 实测 `dwDesiredAccess = 0` 直读 |
| 物理磁盘枚举、容量与稳定设备 ID | ✅ | ✅ | 零权限句柄枚举，自动识别 RAID / 虚拟盘为“未知” |
| SATA / USB T10 SAT 磁盘 SMART | ❌ (`err=5`) | ✅ | Windows 要求 `GENERIC_READ \| GENERIC_WRITE` 句柄 |
| 可选 ATA SMART 短自检 | ❌ | ✅ | 仅管理员 + 用户二次确认触发 |
| CPU 封装温度/功耗 & 主板风扇/电压 | 需扩展组件 | 需扩展组件 | 通过独立隔离的 MPL-2.0 LHM 辅助进程提供 |

---

## 3. 可选 LHM 辅助进程安全边界

- **进程隔离**：独立 EXE（`WinHardwareMonitor.LhmHelper.exe`），崩溃或未启动完全不影响主程序正常运行。
- **同用户跨权限管道**：管道使用 `PipeSecurity` 绑定当前用户 SID、显式拒绝 `NetworkSid`，并设置 `Medium Integrity` 标签（`S:(ML;;NW;;;ME)`），因此**普通用户主程序也可安全连接管理员权限辅助进程**，同时隔离其他用户与低权限沙盒。
- **只读与禁用磁盘**：辅助进程仅启用 CPU/主板/控制器/内存只读查询，**明确关闭 Storage/GPU/Network 模块**，绝不干扰主程序的休眠硬盘保护。
- **第三方驱动（PawnIO）**：本软件绝不静默安装驱动；如在 Windows 11 内存完整性环境下读取 CPU/主板芯片受限，请按 LibreHardwareMonitor 官方文档自行安装受信任的 PawnIO 驱动。

---

## 4. V2.0 主动硬件测试安全约束

- **被动监控期间零干扰**：默认监控期间绝不执行任何写入、压测、自检、固件更新或 USB 桥接厂商私有命令。
- **主动测试三重防护**：
  1. **二次确认**：磁盘文件级测速与 ATA SMART 短自检必须由用户手动勾选二次确认后方可触发；
  2. **绝不写裸盘**：磁盘测速仅在 `logs` 目录创建受控临时文件（`winhw_monitor_bench_tmp.bin`），无论完成或中途取消均通过 `defer` 强制删除；
  3. **实时高温自动熔断**：测试期间持续监测 CPU/GPU 实时最高温度，达到熔断阈值（默认 `90°C`）立即停止全部测试线程。
