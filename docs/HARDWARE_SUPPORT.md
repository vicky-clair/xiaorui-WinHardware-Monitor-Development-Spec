# 硬件兼容性与实机验证说明（docs/HARDWARE_SUPPORT.md）

> 遵循开发规范与 `AGENTS.md`：所有未在真实硬件上验证的场景均明确标注“模拟/单元测试通过”或“尚未实机验证”，绝不虚构兼容结论。

## 1. 已在本机实测验证的硬件与功能

### A. Windows 11 x64 实机验证
测试环境：Windows 11 专业版 `10.0.26300` x64 / Intel Core i5-12490F / NVIDIA GeForce RTX 2060 / WD Blue SN570 1TB NVMe / HIKSEMI USB 3.0。

| 类别 | 设备 / 接口 | 普通用户 | 实测结论 |
| --- | --- | :---: | --- |
| CPU 总体与每核负载 | PDH + `NtQuerySystemInformation` | ✅ | 正常读取总体利用率、每核实时负载与计算频率（明确标注 `计算值`） |
| 内存与 SMBIOS | `GlobalMemoryStatusEx` + RSMB Type 17/2 | ✅ | 正常读取总容量/使用率、内存插槽频率与主板信息，序列号脱敏 |
| 实时磁盘 I/O 与供电 | PDH `PhysicalDisk(_Total)` + `GetSystemPowerStatus` | ✅ | 正常读取总读写 MB/s、IOPS；台式机诚实标注无内置电池 |
| NVMe SMART 与温度 | WD Blue SN570 1TB（`dwDesiredAccess=0`） | ✅ | 完整读取 Log Page 02h、Identify（WCTEMP=80°C / CCTEMP=85°C）与温度探头 |
| GPU 温度与功耗 | NVIDIA RTX 2060（D3DKMT + 动态 `nvml.dll`） | ✅ | 正常读取核心温度、功耗、显存、占用率、核心/显存频率与风扇 RPM |
| USB 移动存储 | HIKSEMI USB 3.0 | 受限 | 零权限可枚举型号/容量/稳定 ID；普通 U 盘固件无 SMART，诚实标注“未知” |
| LHM 扩展进程 IPC | `WinHardwareMonitor.LhmHelper.exe` 命名管道 | ✅ | 实测命名管道 `snapshot` / `shutdown` 联调与优雅退出通过 |
| 内存位翻转校验 | `BenchmarkRunner` 4 轮位模式校验 | ✅ | 单元测试与实机运行零位错误通过，测得真实读写 GB/s |

### B. Linux x86_64 实机验证（Debian 13 物理主机）
测试环境：Debian GNU/Linux 13 (`trixie`) / Linux `6.12.107-amd64` / Intel Celeron N5095A (4 核) / ATOPNUC AG55 / Intel UHD Graphics / `SCY SNM4T1G25600` 256GB SATA SSD (`/dev/sda`) / `Lenovo USB 3.0` (`HGST HTS721010A9E630` 1TB USB HDD, `/dev/sdb`)。

| 类别 | 设备 / 接口 | 权限要求 | 实测结论 |
| --- | --- | :---: | --- |
| CPU 总体/每核负载与实时频率 | `/proc/stat` + `cpufreq` | 普通用户 ✅ | 准确读取 4 核负载与实时动态频率（实测值） |
| CPU 封装与每核温度 | 内核 `hwmon` (`coretemp` / `acpitz`) | 普通用户 ✅ | 零驱动直接读取 `Package id 0`（64°C → 烤机 74°C）与 `Core 0–3` 实时温度 |
| 内存与主板 DMI | `/proc/meminfo` + `/sys/class/dmi/id` | 普通用户 ✅ | 准确读取 7725 MB 内存占用与 `ATOPNUC AG55` 主板型号 |
| GPU 枚举 | `/sys/class/drm/card0` (Intel `0x8086:0x4E55`) | 普通用户 ✅ | 正确识别 Intel UHD Graphics；内核未暴露温度时诚实标注 `不支持` |
| SATA SSD SMART | `/dev/sda` (`SG_IO` 标准 T10 SAT `0x85`) | `root` / `disk` 组 | 普通用户诚实报 `权限不足 (err=13)`；`sudo` 下完整读取 16 项 SMART（54°C、18150h、健康=正常） |
| USB 3.0 移动硬盘 SMART | `/dev/sdb` (`SG_IO` 标准 T10 SAT `0x85` + `0xE5` 防唤醒) | `root` / `disk` 组 | `sudo` 下完整读取 19 项 SMART（35°C、14117h、健康=正常），全程零私有命令 |
| 无界面 CLI 硬件测试套件 | `--bench all`（CPU 4 线程 + 128MB MemTest + 64MB 磁盘） | 普通用户 ✅ | CPU 100.37 MOPS（0 错、峰值 74°C 实时熔断监控）；内存 4/4 轮 0 位错（写 3.89 / 读 3.46 GB/s）；磁盘测试自动清理临时文件 |
| Linux 多格式打包 | `.tar.gz` / `.deb` / `.rpm` | 普通用户 ✅ | `dpkg-deb` 与 `rpmbuild` 全部编译校验通过并输出 `SHA256SUMS.txt` |

## 2. 尚未实机验证（仅模拟/单元测试通过，留待 P9 实机矩阵验证）

- Windows 10 22H2 实机验证
- AMD Ryzen CPU、AMD GPU（D3DKMT）与 Intel 独显/核显实机验证
- 笔记本真实电池放电与循环状态实机验证
- 管理员权限下原生 SATA HDD / SATA SSD 与支持标准 T10 SAT 的 USB 移动硬盘盒实盘 SMART 及与 `smartctl` 逐项比对
- ATA / SAT `CHECK POWER MODE (0xE5)` 对真实休眠机械硬盘的防唤醒实测
- Intel RST / VMD、硬件 RAID 与 Storage Spaces 实机验证（代码已按规范归类为“未知”并提示原因）
- 管理员权限下 `WinHardwareMonitor.LhmHelper.exe` 配合 PawnIO 驱动读取真实 CPU 封装温度与主板 Super I/O 传感器的跨机验证
- 24–72 小时连续稳定性与内存/句柄泄露监测
