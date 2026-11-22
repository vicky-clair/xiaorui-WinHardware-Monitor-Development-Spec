# 硬件兼容性与实机验证说明（docs/HARDWARE_SUPPORT.md）

> 遵循开发规范与 `AGENTS.md`：所有未在真实硬件上验证的场景均明确标注“模拟/单元测试通过”或“尚未实机验证”，绝不虚构兼容结论。

## 1. 已在真实硬件上实测验证的环境与功能

### A. Windows 11 x64 实机验证
测试环境：Windows 11 专业版 `10.0.26300` x64 / Intel Core i5-12490F (6C/12T) / NVIDIA GeForce RTX 2060 / WD Blue SN570 1TB NVMe / HIKSEMI USB 3.0。

| 类别 | 设备 / 接口 | 权限要求 | 实测结论 |
| --- | --- | :---: | --- |
| CPU 总体与每核负载 | PDH + `NtQuerySystemInformation` | 普通用户 ✅ | 正常读取总体利用率、12 逻辑核实时负载与计算频率（明确标注 `计算值`） |
| 内存与 SMBIOS | `GlobalMemoryStatusEx` + RSMB Type 17/2 | 普通用户 ✅ | 正常读取总容量/使用率、内存插槽频率与主板信息，序列号自动脱敏 |
| 实时磁盘 I/O 与供电 | PDH `PhysicalDisk(_Total)` + `GetSystemPowerStatus` | 普通用户 ✅ | 正常读取总读写 MB/s、IOPS；台式机诚实标注无内置电池 |
| NVMe SMART 与温度 | WD Blue SN570 1TB（`dwDesiredAccess=0`） | 普通用户 ✅ | 完整读取 Log Page 02h、Identify（WCTEMP=80°C / CCTEMP=85°C）与全部温度探头 |
| GPU 温度与功耗 | NVIDIA RTX 2060（D3DKMT + 动态 `nvml.dll`） | 普通用户 ✅ | 正常读取核心温度、功耗、显存、占用率、核心/显存频率与风扇 RPM |
| USB 移动存储 | HIKSEMI USB 3.0 普通 U 盘 | 普通用户（受限） | 零权限可枚举型号/容量/稳定 ID；普通 U 盘固件无 SMART，诚实标注“未知” |
| LHM 扩展进程 IPC | `WinHardwareMonitor.LhmHelper.exe` 命名管道 | UAC 启动辅助进程 | 实测普通权限主程序直连管理员权限辅助进程（Medium Integrity ACL），`snapshot` / `shutdown` 联调通过 |
| V2.2 CPU 基准与降频分析 | 温和模式 `11T`（预留 1 核） | 普通用户 ✅ | 单核 `246.27 MOPS` / 多核 `1946.44 MOPS`（扩展 `7.90×`），热降频 `8.4%`，`0` 计算错误 |
| V2.2 内存延迟 + 带宽 + 位翻转 | `64 MB` 4 轮校验 + 指针追踪 | 普通用户 ✅ | 4/4 轮 `0` 位错；写 `7.53` / 读 `7.69` / 多核拷贝 `10.57 GB/s`；延迟 `L1=1.75ns / L2=5.32ns / L3=71.09ns / RAM=123.14ns` |
| V2.2 磁盘无缓存直通测试 | WD Blue SN570（`64 MB` `NO_BUFFERING \| WRITE_THROUGH`） | 普通用户 ✅ | SEQ1M 写 `1470.9` / 读 `1966.6 MB/s`（完整性校验 `0` 错）；RND4K 读 `34.0 MB/s` (`8709 IOPS`, P95/P99 `181/288 µs`)、写 `91.5 MB/s` (`23434 IOPS`, P99 `120 µs`)；临时文件自动删除 |
| 开机自启与三语冒烟 | `HKCU\...\Run` + `StartupApproved\Run` + `--smoke-test` | 普通用户 ✅ | 实测注册表读写/状态恢复/删除闭环通过；11 页面 × 中英日 3 语言 × 黑白双主题无报错通过 |

---

### B. Linux x86_64 实机验证（Debian 13 物理主机）
测试环境：Debian GNU/Linux 13 (`trixie`) / Linux `6.12.107-amd64` / Intel Celeron N5095A (4 核) / ATOPNUC AG55 / Intel UHD Graphics / `SCY SNM4T1G25600` 256GB SATA SSD (`/dev/sda`) / `Lenovo USB 3.0` (`HGST HTS721010A9E630` 1TB USB HDD, `/dev/sdb`)。

| 类别 | 设备 / 接口 | 权限要求 | 实测结论 |
| --- | --- | :---: | --- |
| CPU 总体/每核负载与实时频率 | `/proc/stat` + `cpufreq` | 普通用户 ✅ | 准确读取 4 核负载与实时动态频率（实测值） |
| CPU 封装与每核温度 | 内核 `hwmon` (`coretemp` / `acpitz`) | 普通用户 ✅ | 零驱动直接读取 `Package id 0` 与 `Core 0–3` 实时温度 |
| 内存与主板 DMI | `/proc/meminfo` + `/sys/class/dmi/id` | 普通用户 ✅ | 准确读取物理内存占用与 `ATOPNUC AG55` 主板型号 |
| GPU 枚举 | `/sys/class/drm/card0` (`0x8086:0x4E55`) | 普通用户 ✅ | 正确识别 Intel UHD Graphics；内核未暴露温度时诚实标注 `不支持` |
| SATA SSD SMART | `/dev/sda` (`SG_IO` 标准 T10 SAT `0x85`) | `root` / `disk` 组 | 普通用户诚实报 `权限不足 (err=13)`；`sudo` 下完整读取 16 项 SMART（`54°C`、`18155h`、健康=正常） |
| USB 3.0 移动硬盘 SMART | `/dev/sdb` (`SG_IO` 标准 T10 SAT `0x85` + `0xE5` 防唤醒) | `root` / `disk` 组 | `sudo` 下完整读取 19 项 SMART（`35°C`、`14124h`、健康=正常），全程零厂商私有命令 |
| V2.2 CLI 全套硬件测试 | `--bench all`（温和 `3T` + `64MB` 内存 + `64MB` 磁盘） | 普通用户 ✅ | CPU 1T `26.72` / MT `77.71 MOPS` (`2.91×`, 降频 `0.2%`, 峰值 `64.0°C`, `0` 错)；内存 4/4 轮 `0` 错（W `3.81` / R `3.50` / MT-Copy `7.90 GB/s`, `L1=1.88 / L2=12.98 / L3=25.64 / RAM=146.42 ns`）；磁盘 SEQ1M W `294.8` / R `507.3 MB/s` (`0` 错), RND4K R `40.3 MB/s` (`10315 IOPS`, P99 `139 µs`), W `205.0 MB/s` (`52484 IOPS`) |
| Linux 多格式打包 | `.tar.gz` / `.deb` / `.rpm` | 普通用户 ✅ | `dpkg-deb` 与 `rpmbuild` 全部编译校验通过并输出 `SHA256SUMS.txt` |

---

## 2. 尚未实机验证（仅模拟/单元测试通过）

以下场景已在架构和单元测试中按规范实现，但尚未在对应真实物理机上完成交叉验证：

- **Windows 10 22H2** 实机验证
- **Linux 桌面图形界面（X11 / Wayland + OpenGL 3.3 实时窗口与 GPU 着色器烤机）**：目前 Linux 端仅在无界面 SSH 物理主机实测了 CLI 采集、CLI V2.2 全套测试及 `.tar.gz`/`.deb`/`.rpm` 打包，图形会话尚未实机验证
- **AMD Ryzen CPU、AMD Radeon GPU（D3DKMT / `amdgpu`）与 Intel 独显**实机验证
- **笔记本真实电池放电、充电功率与循环状态**实机验证
- **Windows 管理员权限下原生 SATA HDD / SATA SSD 与支持标准 T10 SAT 的 USB 硬盘盒**与 `smartctl` 逐项比对（Linux 物理机已完成 SATA + USB SAT 实盘验证）
- **ATA / SAT `CHECK POWER MODE (0xE5)`** 对处于深度休眠（Standby）机械硬盘的防唤醒实测
- **Intel RST / VMD、硬件 RAID 与 Storage Spaces** 实机验证（代码已按规范识别并归类为“未知”并说明原因）
- **Windows 管理员权限下 `WinHardwareMonitor.LhmHelper.exe` 配合 PawnIO 驱动**读取真实 CPU 封装温度与主板 Super I/O 传感器的跨机验证
- **24–72 小时连续稳定性**与长期内存/句柄曲线验证
