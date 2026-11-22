# 权限、安全边界与硬件保护说明（docs/PERMISSIONS.md）

## 1. 核心安全原则

1. **主程序零内核驱动**：`winhardware-monitor.exe` / `winhardware-monitor` 不包含、不释放、不安装任何 `.sys` 或内核模块，也绝不携带 WinRing0 等存在已知提权漏洞的旧驱动。
2. **普通用户优先启动**：默认标准用户即可直接运行，严禁静默 UAC 提权；仅当用户主动点击「以管理员身份重启」或「启动 LHM 辅助进程」时才会触发系统 UAC 授权提示。
3. **默认零网络访问**：主程序与可选 LHM 辅助进程均不包含任何联网代码，不建立对外网络连接，不上传硬件序列号、SMART 或诊断信息。
4. **隐私脱敏**：界面显示、日志输出与诊断报告导出均默认对磁盘/内存序列号脱敏（仅保留后 4 位，如 `****77AE`）。

---

## 2. 普通用户 vs 管理员 / Root 权限能力矩阵

### Windows 10/11 x64
| 能力项 | 普通用户 | 管理员 | 说明 |
| --- | :---: | :---: | --- |
| CPU 总体/每核使用率与计算频率 | ✅ | ✅ | PDH + `NtQuerySystemInformation` |
| 物理内存、SMBIOS 内存条与主板型号 | ✅ | ✅ | `GlobalMemoryStatusEx` + `GetSystemFirmwareTable` |
| 实时磁盘读写吞吐 / IOPS 与电池状态 | ✅ | ✅ | PDH `PhysicalDisk` + `GetSystemPowerStatus` |
| GPU 温度 / 功耗 / 显存 / 频率 / 风扇 | ✅ | ✅ | D3DKMT + 运行时动态加载 `nvml.dll` |
| NVMe SSD 完整 SMART 与温度探头 | ✅ | ✅ | Windows 11 实测 `dwDesiredAccess = 0` 直读 |
| 物理磁盘枚举、容量与稳定设备 ID | ✅ | ✅ | 零权限句柄枚举，自动识别 RAID / 虚拟盘为“未知” |
| SATA / USB T10 SAT 磁盘 SMART | ❌ (`err=5`) | ✅ | Windows 要求 `GENERIC_READ \| GENERIC_WRITE` 句柄 |
| 可选 ATA SMART 短自检 | ❌ | ✅ | 仅管理员 + 用户二次确认勾选后触发 |
| CPU 封装温度/功耗 & 主板风扇/电压 | 需扩展组件 | 需扩展组件 | 通过独立隔离的 MPL-2.0 LHM 辅助进程提供 |
| V2.2 硬件测试（CPU/内存/磁盘/GPU/联烤） | ✅ | ✅ | 仅在用户主动点击后执行；磁盘测试需二次确认 |

### Linux x86_64
| 能力项 | 普通用户 | `root` / `disk` 组 | 说明 |
| --- | :---: | :---: | --- |
| CPU 负载/每核频率、**CPU 封装与核心温度** | ✅ | ✅ | 原生 `/proc/stat` + `cpufreq` + `/sys/class/hwmon`，无需任何第三方驱动 |
| 内存、主板 DMI、磁盘 I/O、电池、DRM GPU | ✅ | ✅ | `/proc/meminfo`、`/sys/class/dmi/id`、`/sys/class/drm` |
| SATA / USB T10 SAT / NVMe SMART | ❌ (`err=13`) | ✅ | `SG_IO` / `NVME_IOCTL_ADMIN_CMD` 需要访问 `/dev/sd*` 或 `/dev/nvme*` 的权限 |
| V2.2 无界面 CLI 基准测试（CPU/内存/磁盘） | ✅ | ✅ | 温和模式默认低优先级，磁盘测试仅写受控临时文件并自动清理 |

---

## 3. 长期后台监控为什么不会损伤硬盘？

1. **只读采样，绝不写入扇区**：默认被动监控期间仅发送标准只读查询命令（NVMe Log Page 02h / ATA READ DATA），绝不向磁盘写入测试数据、绝不触发自检、绝不发送固件更新或 USB 桥接芯片厂商私有命令。
2. **极低轮询频率与节电退让**：SMART 完整轮询默认间隔 `60 秒`（系统强制保护下限为 `30 秒`，防止误配高频查询），电池供电模式下自动拉长倍率。
3. **休眠机械盘防唤醒保护**：读取 ATA / USB SAT 磁盘 SMART 前先执行标准 `CHECK POWER MODE (0xE5)` 检查电源状态；若机械硬盘正处于待机/休眠态，默认直接跳过本次查询，避免反复唤醒磁头启停。
4. **本地历史库写入极轻**：SQLite 采用 WAL 模式并默认每 `60 秒` 批量落盘一次，配合自动降采样（1m → 15m），全天总写入量仅在数 MB 级，对现代 SSD 寿命影响可忽略不计。

---

## 4. 可选 Windows LHM 辅助进程安全边界

- **进程隔离**：独立 EXE（`WinHardwareMonitor.LhmHelper.exe`，MPL-2.0），崩溃或未启动完全不影响主程序正常运行。
- **同用户跨权限安全管道**：管道使用 `PipeSecurity` 绑定当前用户 SID、显式拒绝 `NetworkSid`，并附加 `Medium Integrity` 标签（`S:(ML;;NW;;;ME)`），因此**普通用户主程序也可安全连接管理员权限辅助进程**，同时隔离其他登录用户与低权限沙盒。
- **严格只读与禁用磁盘**：辅助进程仅启用 CPU/主板/控制器/内存只读查询，**明确关闭 Storage/GPU/Network 模块**，绝不干扰主程序的休眠硬盘保护。
- **第三方驱动声明（PawnIO）**：本软件绝不静默安装任何驱动；若在开启“内存完整性”的 Windows 11 环境下读取 CPU/主板芯片受限，请按 LibreHardwareMonitor 官方文档自行安装受信任的 PawnIO 驱动。

---

## 5. V2.2 主动硬件测试防卡顿与安全护栏

1. **低优先级 + 温和防卡顿模式（默认开启）**：
   - 所有测试工作线程自动降为低优先级（Windows `THREAD_PRIORITY_BELOW_NORMAL` / Linux `nice +10`）；
   - CPU 测试默认预留 1 个逻辑核心给操作系统和前台应用（浏览器、会议、影音、杀毒等不卡顿）；
   - 内存测试自动钳位在当前可用物理内存的 **35%** 以内，严防触发系统页面交换（Swap/OOM）；
   - GPU OpenGL 3.3 离屏着色器按需懒创建、测试结束即销毁释放显存，默认「均衡」档位避免桌面掉帧或触发显卡 TDR 重置。
2. **磁盘测试三重保护**：
   - **必须二次确认**：GUI 端勾选确认框后才允许启动；
   - **绝不写裸物理磁盘**：仅在指定目录（默认程序 `logs` 目录，或用户自选目录）创建受控临时文件 `winhw_monitor_bench_tmp.bin`，无论正常完成、用户取消还是高温熔断，均通过 `defer` 强制删除；
   - **剩余空间护栏**：启动前通过 `GetDiskFreeSpaceExW` / `statvfs` 校验可用空间必须 `>= 2 × 测试文件大小 + 512 MB`，空间不足直接拒绝执行并明确提示。
3. **实时高温自动熔断**：
   - 测试全程联动读取 CPU 与 GPU 实时最高温度，一旦触及设定熔断阈值（默认 `90°C`，允许在 `70–100°C` 调节），立即中止全部压测线程并在报告与历史中明确标明熔断原因。

---

## 6. 开机自启权限说明

- **Windows**：采用当前用户级注册表项 `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`（**无需管理员权限**），写入带 `--autostart` 参数的完整路径，并自动检测/清除 `Explorer\StartupApproved\Run` 中的任务管理器禁用标记；开机登录后自动等待 2 秒待桌面与显卡驱动就绪再静默驻留托盘（0 FPS 零占用）。
- **Linux**：写入标准 XDG 当前用户自启项 `~/.config/autostart/winhardware-monitor.desktop`（同样无需 `root` 权限）。
