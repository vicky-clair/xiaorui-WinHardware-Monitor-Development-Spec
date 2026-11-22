# WinHardware Monitor

一款**轻量、可靠、零默认内核驱动、低资源占用**的 **Windows 10/11 x64 与 Linux x86_64 跨平台**硬件温度、SMART 磁盘健康与系统友好型硬件测试软件（支持**桌面 GUI** 与**无界面 CLI** 双形态，支持**简体中文 / English / 日本語**三语实时切换）。

- **核心技术栈**：Zig `0.15.2` + `zgui`（Dear ImGui 1.92 + ImPlot）+ `zglfw` + OpenGL 3.3 Core + SQLite 3.53.2 + 原生 Win32 / Linux `hwmon` & `sysfs` & `SG_IO` / `NVME_IOCTL`
- **设计红线**：**绝不编造硬件数据、绝不将不支持的硬件误报为“正常”、默认零网络访问、默认普通用户即可启动、被动监控期间绝不写入或唤醒休眠硬盘**
- **完整开发规范**：[WinHardware-Monitor-Development-Spec.md](WinHardware-Monitor-Development-Spec.md)
- **开源许可**：主程序采用 **Apache-2.0**（[LICENSE](LICENSE)）；Windows 可选 LibreHardwareMonitor 辅助进程以独立可执行文件隔离，遵循 **MPL-2.0**（[helpers/lhm_bridge/LICENSE-MPL-2.0.txt](helpers/lhm_bridge/LICENSE-MPL-2.0.txt)）

---

## 目录

1. [11 大核心功能模块](#11-大核心功能模块)
2. [Windows 快速上手与日常使用](#windows-快速上手与日常使用)
3. [V2.2 硬件测试与指标解读指南](#v22-硬件测试与指标解读指南)
4. [Linux 安装、无界面 CLI 与打包使用](#linux-安装无界面-cli-与打包使用)
5. [使用注意事项（必读）](#使用注意事项必读)
6. [从源码构建与一键打包](#从源码构建与一键打包)
7. [项目目录结构](#项目目录结构)
8. [常见问题（FAQ）](#常见问题faq)

---

## 11 大核心功能模块

| 页面 | 功能说明 |
| --- | --- |
| **硬件总览** | 内存环形仪表、CPU/内存/GPU 实时面积趋势图、权限与传感器采集状态速览、全部物理磁盘温度与健康状态汇总 |
| **处理器 CPU** | CPU 型号/核心/计算频率、**每核逻辑处理器实时负载条**、使用率曲线、CPU 封装温度/功耗仪表（Windows 通过可选 LHM 扩展，Linux 通过内核 `hwmon` 直读） |
| **显卡 GPU** | 厂商无关 D3DKMT + 运行时动态 `nvml.dll`（零 SDK 捆绑），展示核心温度、功耗、显存、占用率、核心/显存频率与风扇 RPM；Linux 原生读取 `/sys/class/drm` |
| **内存 RAM** | 物理内存占用环形图与趋势曲线、SMBIOS Type 17 内存插槽明细（插槽/容量/代际/生效频率/厂商/脱敏序列号） |
| **主板与传感器** | SMBIOS Type 2 / Linux DMI 主板信息、系统开机时长、实时磁盘总吞吐（MB/s & IOPS）、电池供电状态、扩展组件原始传感器明细表 |
| **磁盘健康** | 多磁盘列表 + 完整 SMART 详情（NVMe Log Page 02h + 温度探头 `#1–#8`、ATA/SATA SMART、标准只读 USB T10 SAT 透传）、**21 条登记健康规则与基线对比**、休眠机械盘 `0xE5` 防唤醒保护、可选 ATA SMART 短自检 |
| **全传感器表** | HWiNFO64 风格全量传感器统计表（当前 / 最小 / 平均 / 最大 / 采样数），支持一键清零统计与导出 **UTF-8 BOM CSV 报表** |
| **硬件测试** | **V2.2 系统友好型深度测试与诊断套件**：CPU 单核/多核与降频分析、内存 `L1/L2/L3/RAM` 延迟 + 多核拷贝 + 4 轮位翻转、自定义目录无缓存磁盘 SEQ1M/RND4K + 完整性校验 + P95/P99 尾延迟、GPU OpenGL 3.3 离屏着色器烤机、整机安全联烤、一键全套体检；内置实时双轴曲线、智能诊断建议与 SQLite 历史对比 |
| **历史趋势** | 本地 SQLite 9 表数据库（WAL 模式、60 秒批量写入、1m → 15m 分级降采样、损坏自动备份重建） |
| **告警中心** | 温度与磁盘健康告警（30 秒防抖、5°C 回差恢复、30 分钟抑制、NVMe WCTEMP/CCTEMP 优先），联动托盘气泡通知 |
| **系统设置** | **中 / 英 / 日三语实时切换**、**深色 / 浅色（黑白）双主题实时切换**（同步 Win10/11 原生标题栏）、托盘行为、**一键开机自启（含系统禁用态检测与修复）**、采集间隔、配置导出/导入、LHM 扩展启停与全序列号脱敏诊断包导出 |

---

## Windows 快速上手与日常使用

### 1. 安装模式 vs 便携模式

- **安装模式（推荐）**：运行 `WinHardwareMonitor-0.1.0-win64-setup.exe`，默认安装至 `%LOCALAPPDATA%\Programs\WinHardwareMonitor`（**无需管理员权限**），安装向导支持勾选：
  - 是否在登录 Windows 时静默自启至托盘；
  - 是否附带可选的 MPL-2.0 LHM 辅助进程（默认不勾选）。
  - 数据存放路径（卸载时弹窗询问，默认保留）：
    ```text
    %LOCALAPPDATA%\WinHardwareMonitor\
    ├── config\settings.toml    # 个人配置（语言、主题、阈值、间隔等）
    ├── data\monitor.db         # SQLite 历史曲线、SMART 快照与测试历史
    └── logs\                   # CSV 报表、硬件测试报告与脱敏诊断包
    ```
- **便携模式**：解压便携版 ZIP（或在 `winhardware-monitor.exe` 同级目录放置空文件 `portable.flag`），所有配置、数据库与日志将保存在程序同目录，不写入 `%LOCALAPPDATA%`。

### 2. 三语切换与双主题切换

- **左侧导航栏底部**提供一键快捷按钮：
  - 点击语言按钮可在 **简体中文 / English / 日本語** 之间实时无重启切换（所有页面、表头、状态徽章、SMART 属性名、健康规则、传感器统计表、托盘菜单与导出报告同步一致）；
  - 点击主题按钮可在 **深色 / 浅色** 双主题间切换，并自动同步 Windows 10/11 原生标题栏颜色。
- 在 **「系统设置」** 页也可直接单选语言、温度单位（`°C` / `°F`）与托盘行为，所有设置均自动持久化至 `settings.toml`。

### 3. 开机自动启动

- 在 **「系统设置」** 中勾选 **「开机自动启动」** 会**立即写入**当前用户注册表 `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`（无需管理员权限），并实时显示系统真实自启状态（`已启用` / `未启用` / `被系统任务管理器禁用`）。
- 若此前曾在 Windows 任务管理器的「启动应用」中手动禁用过，重新勾选会自动清除 `StartupApproved\Run` 的禁用标记。
- 开机自启时程序会携带 `--autostart` 参数，先等待 **2 秒** 让桌面和显卡驱动就绪，再静默驻留系统托盘（**0 FPS 零渲染占用**），不弹窗口打扰工作。

### 4. 普通用户与管理员权限说明

- **普通用户直接启动即可读取**：CPU 总体/每核负载与计算频率、内存与 SMBIOS 插槽、主板 SMBIOS、**NVMe SSD 完整 SMART 与温度**、**GPU 温度/功耗/显存/频率/风扇**、磁盘实时 I/O、电池状态以及全部 V2.2 硬件测试。
- **需要管理员权限的场景**：读取 **SATA 磁盘** 或 **支持标准 T10 SAT 的 USB 移动硬盘盒** 的 ATA SMART（Windows 要求读写句柄，普通用户会诚实提示 `权限不足 (err=5)`）。点击左侧栏底部 **「以管理员身份重启」** 即可通过 UAC 平滑切换。

### 5. 如何启用可选扩展组件（读取 Windows CPU 温度与主板风扇/电压）

Windows 原生用户态 API 不公开 CPU 封装温度、CPU 功耗与主板 Super I/O 芯片传感器；主程序坚持零内核驱动，若需要查看这些指标：
1. 确保 `WinHardwareMonitor.LhmHelper.exe` 位于主程序同目录（需本机安装 .NET 8/9/10 Desktop/Runtime）；
2. 在主程序 **「主板与传感器」** 或 **「系统设置」** 页面点击 **「启动 LHM 辅助进程 (需管理员)」**；
3. 该辅助进程为**无界面只读后台服务**，通过同用户本地命名管道 `\\.\pipe\WinHardwareMonitor_LhmBridge_v1` 向普通或管理员权限主程序提供数据，**零网络、不碰磁盘**；
4. 若在开启“内核隔离 / 内存完整性”的 Windows 11 上仍读取受限，请按 LibreHardwareMonitor 官方指引自行安装受信任的 [PawnIO](https://pawnio.eu) 驱动（本软件**绝不静默安装第三方驱动**）。

---

## V2.2 硬件测试与指标解读指南

进入 **「硬件测试」** 页面（或命令行使用 `--bench`），可按需运行 6 类硬件检测。所有测试默认开启 **「温和防卡顿模式」**，绝不抢占前台应用响应：

| 测试项目 | 测什么 & 怎么用 | 关键指标如何解读 |
| --- | --- | --- |
| **1. CPU 单核/多核与热降频** | 先跑 3 秒单核确定性算力，再跑多核压测并校验每步结果 | `1T / MT MOPS` 反映单核与多核算力；`扩展倍率` 越高多核效率越好；`降频衰减 %` > 10% 通常说明散热或功耗墙触发降频；`计算错误` 必须为 `0`（非 0 说明超频/欠压不稳定） |
| **2. 内存延迟 + 带宽 + 位翻转** | Sattolo 随机指针追踪测各级缓存延迟 + 多核拷贝 + 4 轮位翻转校验 | `L1 / L2 / L3 / RAM (ns)` 正常呈阶梯递增（如 `~2 / 5 / 25-70 / 80-150 ns`）；`4/4 轮位错误` 必须为 `0`（非 0 说明内存条/XMP 不稳定） |
| **3. 磁盘无缓存测速 + 完整性校验** | 可自选任意盘符/目录（如 `D:\Temp`），先检查剩余空间后创建受控临时文件并自动删除 | **必须勾选二次确认**；Windows 走 `NO_BUFFERING \| WRITE_THROUGH` 绕过内存缓存，测得真实物理盘速；`完整性错误` 非 0 警惕扩容盘或坏块；`RND4K P95/P99 (µs)` 反映日常系统流畅度与尾延迟 |
| **4. GPU 离屏着色器烤机** | OpenGL 3.3 离屏 FBO 实时片段着色器，支持轻量/均衡/高负载 3 档 | 查看实时预览画面、`Avg FPS / 1% Low FPS / 帧时间 (ms)`、温升 `+Δ°C` 与峰值功耗；测试结束自动销毁显存资源 |
| **5. 整机安全联烤** | 温和模式下同步联合加载 CPU + 内存 + GPU，检验整机散热与供电 | 观察实时双轴曲线（性能 + 温度）与智能诊断建议，触发高温阈值自动停机 |
| **6. 一键全套体检** | 依次串行完成 CPU → 内存 → GPU → 磁盘（若已确认）综合测试 | 结束后自动生成三语诊断建议、保存到本地 SQLite 历史对比表，并支持一键导出测试报告 |

---

## Linux 安装、无界面 CLI 与打包使用

Linux 端原生直读内核 `hwmon`（**免驱动读取 CPU 封装与每核温度、主板温度、风扇与电压**）、`/proc/stat` + `cpufreq`、`DRM` GPU 与 `NVME_IOCTL` / `SG_IO`（SATA / USB T10 SAT SMART）。

### 安装发行包
```bash
# Debian / Ubuntu / Linux Mint
sudo dpkg -i winhardware-monitor_0.1.0_amd64.deb

# Fedora / RHEL / CentOS / Rocky / openSUSE
sudo rpm -ivh winhardware-monitor-0.1.0-1.x86_64.rpm

# 或直接解压免安装便携包
tar -xzf winhardware-monitor-0.1.0-linux-x86_64.tar.gz
```

### 常用无界面 CLI 命令（Windows & Linux 通用）
```bash
# 1. 查看整机硬件与温度摘要（支持 --lang zh|en|ja）
winhardware-monitor --cli --lang zh

# 2. Linux 下提权查看 SATA / USB SAT / NVMe SMART 与 21 条健康规则
sudo winhardware-monitor --cli --lang zh

# 3. 单项或全套 V2.2 温和基准测试（自动预留核心、低优先级运行、临时文件自动删除）
winhardware-monitor --bench cpu --duration 10
winhardware-monitor --bench mem --mem-mb 128
winhardware-monitor --bench disk --disk-mb 64 --disk-dir /tmp
winhardware-monitor --bench all --duration 15 --mem-mb 128 --disk-mb 64 --cutoff-c 90

# 4. 如需满载跑分（关闭温和核预留），可显式附加 --no-gentle
winhardware-monitor --bench cpu --duration 15 --no-gentle
```

---

## 使用注意事项（必读）

1. **长期开启监控会伤硬盘吗？**
   **不会。** 被动监控期间只做极低频只读查询（SMART 默认每 60 秒一次、最低不得低于 30 秒），机械盘休眠前先发 `0xE5` 检查并默认跳过不唤醒，SQLite 历史每 60 秒批量落盘，不会产生额外磨损。
2. **为什么普通 U 盘、RAID 阵列或虚拟机磁盘显示“未知”？**
   绝大多数普通 U 盘固件不提供 SMART，RAID / Intel RST / Storage Spaces / 虚拟盘也会屏蔽底层物理盘健康信息。按开发红线，本软件**绝不伪造百分比，也绝不把无法读取的磁盘标成“正常”**。
3. **主动硬件测试的安全边界**：
   - **高温熔断**：所有压测均实时监测温度，达到熔断线（默认 `90°C`，可在 `70–100°C` 调节）立即中止。若 Windows 未启用 LHM 扩展导致暂无 CPU 温度读数，页面会在开测前明确提醒，请留意机箱散热。
   - **磁盘测速不伤裸盘**：仅写入受控临时文件 `winhw_monitor_bench_tmp.bin` 并在结束后立即删除，且启动前强制校验剩余空间 `>= 2×文件大小 + 512 MB`。SSD 请勿频繁反复跑超大文件测速以减少不必要的 TBW 消耗。
   - **笔记本供电提示**：电池供电模式下高负载测试会受系统降频策略限制，建议插电运行以获得准确性能基线。
4. **健康“正常”不等于免备份**：
   SMART 仅能预警可观测的退化指标，无法预测突发电路/主控故障，重要数据请始终保持异地备份。
5. **关闭窗口后为何还在托盘？**
   默认关闭按钮会最小化到系统托盘（进入 **0 FPS 零渲染** 后台守护），方便持续接收高温/磁盘告警；如需直接退出，可在「系统设置」修改关闭行为或右键托盘图标选择退出。

---

## 从源码构建与一键打包

### 环境要求
- **Zig 编译器**：**严格锁定 `0.15.2`**（不得擅自升级版本）
- **Windows 可选工具**：.NET 8.0+ SDK（仅构建 LHM 辅助进程）、Inno Setup 6（仅生成 `.exe` 安装包）
- **Linux 编译依赖**：`libx11-dev libxrandr-dev libxinerama-dev libxcursor-dev libxi-dev libgl-dev rpm`

### Windows 构建与测试命令
```powershell
# 运行全部自动化单元测试
zig build test

# Debug 构建 & ReleaseSafe 构建
zig build
zig build -Doptimize=ReleaseSafe

# 运行 11 页 × 3 语言 × 黑白双主题无人工冒烟测试
.\zig-out\bin\winhardware-monitor.exe --smoke-test

# 一键构建并打包 Windows 安装包 + 便携 ZIP + LHM Helper + SHA256SUMS.txt（输出至 dist/）
powershell -NoProfile -ExecutionPolicy Bypass -File packaging/windows/build_release.ps1
```

### Linux 一键构建与多格式打包命令
```bash
# 一键运行测试、构建并打包 .tar.gz / .deb / .rpm + SHA256SUMS.txt（输出至 dist-linux/）
ZIG_BIN=zig ./packaging/linux/build_linux_packages.sh
```

更多依赖锁定哈希、许可证清单与代码签名说明请查阅 [docs/BUILD.md](docs/BUILD.md)。

---

## 项目目录结构

```text
.
├── build.zig / build.zig.zon          # Zig 0.15.2 构建脚本与锁定依赖
├── config/default.toml                # 默认配置模板
├── data/drive_attributes.toml         # ATA SMART 属性参考表
├── helpers/lhm_bridge/                # 独立 MPL-2.0 LibreHardwareMonitor 辅助进程（C# .NET）
├── packaging/
│   ├── windows/                       # Inno Setup 6 脚本、代码签名与一键发布脚本
│   └── linux/                         # Linux .tar.gz / .deb / .rpm 一键打包脚本与桌面入口
├── docs/                              # 架构、构建、权限、硬件兼容性与发布说明
├── src/
│   ├── main.zig / cli.zig             # GUI 主入口与跨平台无界面 CLI 体检/测速入口
│   ├── root_tests.zig / verify_p0.zig # 全量单元测试入口与 P0 硬件权限自检工具
│   ├── app/state.zig                  # 全局应用状态与三态低占用渲染状态机
│   ├── core/                          # 核心领域层（三语 i18n/传感器模型/统计表/21 条规则/告警/V2.2 测试引擎/设备 ID）
│   ├── collectors/storage/            # 物理磁盘枚举、NVMe SMART、ATA & 标准 T10 SAT SMART
│   ├── providers/
│   │   ├── windows/                   # 手写 Win32 绑定/SMBIOS/PDH/D3DKMT+NVML
│   │   ├── linux/                     # 原生 hwmon/procfs/sysfs/DRM/NVME_IOCTL/SG_IO
│   │   └── libre_hardware_monitor/    # 可选 LHM 命名管道只读客户端与协议解析
│   ├── database/                      # SQLite 3.53.2 封装、9 表迁移、分级降采样与损坏自动恢复
│   ├── platform/                      # 单实例、托盘、隐藏消息窗口、开机自启、路径解析、显式 UAC 提权
│   ├── services/                      # 后台监控工作线程、TOML 配置服务、脱敏诊断导出
│   ├── gui/                           # 双主题、CJK 字体合并、Bento 卡片/仪表/ImPlot、GPU 离屏着色器与 11 页面视图
│   └── utils/toml.zig                 # 零依赖自研 TOML 解析与序列化器
└── WinHardware-Monitor-Development-Spec.md  # 项目完整开发规范
```

---

## 常见问题（FAQ）

- **Q：为什么 Windows 下 CPU 温度显示 `N/A（需要扩展组件）`？**
  A：Windows 原生用户态 API 不提供 CPU 温度，规范严禁拿不准确的 ACPI 热区温度冒充 CPU 温度。按上文启动可选的 `WinHardwareMonitor.LhmHelper.exe` 即可读取；Linux 端则原生直读内核 `hwmon` 无需任何扩展。
- **Q：为什么勾选了开机自启却在任务管理器里看到被禁用？**
  A：Windows 会在 `StartupApproved\Run` 中记忆用户历史禁用状态。本软件 V2.2 已支持自动检测并在「系统设置」页显示 `被系统禁用` 提示，重新勾选即可自动清除禁用标记并立即生效。
- **Q：运行硬件测试时电脑会卡死或影响我开着的办公软件吗？**
  A：默认开启「温和防卡顿模式」且所有测试线程运行在低优先级，自动留出核心与内存余量，浏览器、文档、聊天软件均可保持流畅。如需满载极限测分，再手动关闭温和模式即可。
- **Q：导出故障诊断报告会泄露我的硬盘或内存序列号吗？**
  A：不会。点击「系统设置」中的 **「导出脱敏诊断报告」** 时，所有磁盘与内存序列号均强制脱敏为仅保留后 4 位（如 `****77AE`），可放心分享排查问题。

---

## 相关文档

- [软件架构设计](docs/ARCHITECTURE.md)
- [构建与打包指南](docs/BUILD.md)
- [权限、安全边界与硬件保护说明](docs/PERMISSIONS.md)
- [硬件兼容性与实机验证矩阵](docs/HARDWARE_SUPPORT.md)
- [发布说明](docs/RELEASE_NOTES_v0.1.0.md)
- [更新日志](CHANGELOG.md)
