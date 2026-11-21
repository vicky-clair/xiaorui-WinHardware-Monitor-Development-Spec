# WinHardware Monitor

一款**轻量、可靠、零默认内核驱动、低资源占用**的 **Windows 10/11 x64 与 Linux x86_64 跨平台**硬件温度、磁盘健康与硬件稳定性测试软件（支持**桌面 GUI** 与**无界面 CLI** 双形态）。

- **核心技术栈**：Zig `0.15.2` + `zgui`（Dear ImGui + ImPlot）+ `zglfw` + OpenGL 3.3 Core + SQLite 3.53.2 + 原生 Win32 / Linux `hwmon` & `sysfs` & `SG_IO` / `NVME_IOCTL`
- **设计原则**：**绝不编造硬件数据、绝不将不支持的硬件误报为“正常”、默认零网络访问、默认普通用户即可启动**
- **详细开发规范**：[WinHardware-Monitor-Development-Spec.md](WinHardware-Monitor-Development-Spec.md)
- **开源许可**：主程序采用 **Apache-2.0**（[LICENSE](LICENSE)）；Windows 可选 LibreHardwareMonitor 辅助进程以独立可执行文件隔离，遵循 **MPL-2.0**（[helpers/lhm_bridge/LICENSE-MPL-2.0.txt](helpers/lhm_bridge/LICENSE-MPL-2.0.txt)）

---

## 核心功能（11 大模块）

| 页面 | 功能说明 |
| --- | --- |
| **硬件总览** | 内存环形仪表、内存/CPU/GPU 实时面积趋势图、权限与传感器采集状态一览、多磁盘温度与健康速览 |
| **处理器 CPU** | CPU 型号/核心/计算频率、**每核逻辑处理器实时负载条**、使用率曲线、CPU 封装温度/功耗仪表（扩展组件） |
| **显卡 GPU** | 厂商无关 D3DKMT + 运行时动态 NVML（零 SDK 捆绑），展示 GPU 核心温度、功耗、显存、占用率、核心/显存频率与风扇转速 |
| **内存 RAM** | 物理内存占用环形图与趋势曲线、SMBIOS Type 17 内存插槽明细（容量/类型/频率/厂商/脱敏序列号） |
| **主板与传感器** | SMBIOS Type 2 主板信息、系统开机时长、实时磁盘读写吞吐（MB/s & IOPS）、电池供电状态、扩展组件原始传感器明细表 |
| **磁盘健康** | 多磁盘列表 + 完整 SMART 详情（NVMe Log Page 02h + 温度探头 #1–#8、ATA/SATA SMART、标准只读 USB T10 SAT 透传）、**21 条编号健康规则与基线对比**、休眠硬盘防唤醒保护、可选 ATA SMART 短自检 |
| **全传感器表** | HWiNFO64 风格全量传感器统计表（当前 / 最小 / 平均 / 最大 / 采样数），支持一键清零统计与导出 **UTF-8 BOM CSV 报表** |
| **硬件测试** | **V2.0 主动测试套件**：CPU 多线程确定性算力校验、内存 4 轮位翻转校验（MemTest 类）、磁盘 SEQ1M/RND4K 文件级测速、GPU OpenGL 3.3 渲染烤机，全项内置**实时高温自动熔断**与测试报告导出 |
| **历史趋势** | 本地 SQLite 历史数据库（WAL 模式、60 秒批量写入、1m → 15m 分级降采样、损坏自动备份重建） |
| **告警中心** | 温度与磁盘健康告警（30 秒持续防抖、5°C 回差恢复、30 分钟抑制、NVMe WCTEMP/CCTEMP 优先），联动托盘气泡通知 |
| **系统设置** | **深色 / 浅色（黑白）双主题实时切换**（同步 Win10/11 原生标题栏）、关闭/最小化托盘行为、开机自启、采集间隔、配置导出/导入、LHM 扩展启停与全序列号脱敏诊断包导出 |

---

## 快速上手（用户使用指南）

### 1. 部署方式（安装版 vs 便携版）

- **安装模式（默认）**：运行构建生成的 `WinHardwareMonitor-0.1.0-win64-setup.exe`，默认安装至 `%LOCALAPPDATA%\Programs\WinHardwareMonitor`（**无需管理员权限**）。配置文件、SQLite 历史库与日志存放于：
  ```text
  %LOCALAPPDATA%\WinHardwareMonitor\
  ├── config\settings.toml    # 用户配置
  ├── data\monitor.db         # SQLite 历史与 SMART 数据库
  └── logs\                   # CSV 报表、测试报告与脱敏诊断包
  ```
  卸载时会弹窗询问是否删除本地数据，**默认保留**。
- **便携模式**：在 `winhardware-monitor.exe` 同级目录放置空文件 `portable.flag`（或直接解压便携版 ZIP），所有配置、数据库与日志将自动保存在程序所在目录，不写入 `%LOCALAPPDATA%`。

### 2. 普通用户与管理员权限说明

- **默认普通用户启动即可获得**：CPU 使用率/每核负载/计算频率、内存与 SMBIOS 插槽、主板 SMBIOS、**NVMe SSD 温度与完整 SMART**、**GPU 温度/功耗/显存/频率/风扇**、磁盘 I/O 与电池状态。
- **需要管理员权限的功能**：
  - 读取 **SATA / USB SAT 外接硬盘盒** 的 ATA SMART（Windows 强制要求读写设备句柄，普通用户会诚实提示 `权限不足 (err=5)`）；
  - 点击左侧栏底部的 **「以管理员身份重启」** 按钮即可通过 UAC 平滑切换至管理员模式。

### 3. 如何启用可选扩展组件（读取 CPU 温度与主板风扇/电压）

Windows 原生用户态接口不开放 CPU 封装温度、CPU 功耗及主板 Super I/O 传感器。主程序坚持零内核驱动，若需要这些指标：
1. 确保 `WinHardwareMonitor.LhmHelper.exe` 位于主程序同级目录（安装时选“完整安装”或勾选可选扩展组件；需本机安装 .NET 8/9/10 Desktop/Runtime）；
2. 打开主程序 `winhardware-monitor.exe`，进入 **「主板与传感器」** 或 **「系统设置」** 页面，点击 **「启动 LHM 辅助进程 (需管理员)」**；
3. 该辅助进程为**无界面后台服务**（若直接双击它会弹出说明提示框并驻留后台），通过同用户本地命名管道 `\\.\pipe\WinHardwareMonitor_LhmBridge_v1`（Medium Integrity 安全标签）向普通权限或管理员权限主程序提供**严格只读**数据，**零网络访问、不触碰磁盘**。
4. **驱动说明**：在开启“内核隔离 / 内存完整性”的 Windows 11 系统上，LibreHardwareMonitor 读取 CPU/主板芯片需要受信任的签名驱动，请按其官方文档自行安装 [PawnIO](https://pawnio.eu) 驱动（本软件**绝不静默自动安装任何第三方驱动**）。

---

## 使用注意事项（必读）

1. **为什么普通 U 盘看不到磁盘健康度？**
   绝大多数普通 U 盘主控固件本身不提供 SMART 健康协议，程序会诚实标注为 **“未知”**，严禁编造健康百分比。对于支持标准 **T10 SAT** 协议的 USB 移动硬盘盒，请在管理员模式下查看；本软件严禁发送 USB 桥接芯片厂商私有命令。
2. **关于主动硬件测试的安全边界（V2.0）**：
   - **高温自动熔断**：所有烤机项目（CPU / GPU / 内存 / 磁盘）均实时联动监控温度，一旦达到设定阈值（默认 `90°C`，可在 `70–100°C` 间调整）将立即中止全部测试线程。
   - **磁盘测速安全**：仅在勾选**二次确认**后于 `logs` 目录创建受控临时文件执行 SEQ1M / RND4K 测试，测试完成或中止后自动删除，**绝不直接写入裸物理磁盘扇区**。
   - **SMART 短自检**：仅在磁盘详情页手动勾选二次确认后下发，默认被动监控期间绝不向硬盘发送写入或自检命令。
3. **关于健康判定与备份**：
   SMART 状态显示“正常”并不代表硬盘不会突发物理故障，请始终对重要数据保持异地备份。
4. **托盘与节能**：
   默认点击窗口右上角 `×` 会最小化到系统托盘（可在「系统设置」改为直接退出）。窗口最小化或隐藏到托盘后渲染线程自动进入 **0 FPS 零渲染节能模式**，右键托盘图标可打开窗口、暂停采集或安全退出。

---

## 从源码构建与打包

### 环境要求

- **操作系统**：Windows 10 (22H2+) / Windows 11 x64
- **Zig 编译器**：**严格锁定 `0.15.2`**（不得擅自升级版本）
- **可选（仅构建 LHM 辅助进程）**：.NET 8.0+ SDK
- **可选（仅编译安装程序）**：Inno Setup 6（`iscc.exe`）
- **可选（仅正式签名发布）**：Windows SDK `signtool.exe` 与商业代码签名证书

### 常用命令

```powershell
# 1. 运行全部自动化单元测试
zig build test

# 2. Debug 构建（输出至 zig-out\bin\winhardware-monitor.exe）
zig build

# 3. ReleaseSafe 发布构建（推荐）
zig build -Doptimize=ReleaseSafe

# 4. 运行 11 页 + 黑白双主题无人工冒烟测试
.\zig-out\bin\winhardware-monitor.exe --smoke-test

# 5. 运行 P0 硬件接口与权限自检工具
zig build verify-p0

# 6. 单独发布可选 MPL-2.0 LHM 辅助进程
dotnet publish helpers/lhm_bridge/WinHardwareMonitor.LhmHelper.csproj -c Release -r win-x64 -o zig-out/bin

# 7. Windows 一键构建并打包（ReleaseSafe + LHM Helper + 便携版 ZIP + Inno Setup 安装包 + SHA256SUMS.txt）
powershell -NoProfile -ExecutionPolicy Bypass -File packaging/windows/build_release.ps1
```

### Linux 构建、打包（`.tar.gz` / `.deb` / `.rpm`）与无界面 CLI 测试

Linux 端原生支持内核 `hwmon`（CPU 封装与核心温度、风扇、电压，无需任何第三方驱动）、`DRM/sysfs` GPU、`NVME_IOCTL_ADMIN_CMD` 与 `SG_IO`（SATA / USB T10 SAT SMART）：

```bash
# 1. 安装编译依赖（Debian/Ubuntu 示例；打包 .rpm 需安装 rpm）
sudo apt-get install -y libx11-dev libxrandr-dev libxinerama-dev libxcursor-dev libxi-dev libgl-dev rpm

# 2. 一键运行测试、构建并打包 .tar.gz（便携版）、.deb 与 .rpm（输出至 dist-linux/）
ZIG_BIN=zig ./packaging/linux/build_linux_packages.sh

# 3. 安装 .deb 或 .rpm
sudo dpkg -i dist-linux/winhardware-monitor_0.1.0_amd64.deb
# 或 Fedora / RHEL / CentOS / Rocky / openSUSE：
sudo rpm -ivh dist-linux/winhardware-monitor-0.1.0-1.x86_64.rpm

# 4. 无界面 CLI 硬件监测与准确基准测试（适用于 Linux 服务器 / SSH 终端）
winhardware-monitor --cli                                          # 普通用户查看 CPU/温度/内存/GPU/磁盘
sudo winhardware-monitor --cli                                     # 提权读取 SATA / USB SAT / NVMe SMART 与 21 条健康规则
winhardware-monitor --bench all --duration 15 --mem-mb 256 --disk-mb 128 --cutoff-c 90
```

更多构建、依赖许可证与代码签名细节请查阅 [docs/BUILD.md](docs/BUILD.md)。

---

## 项目目录结构

```text
.
├── build.zig / build.zig.zon          # Zig 0.15.2 构建脚本与锁定依赖
├── config/default.toml                # 默认配置模板
├── data/drive_attributes.toml         # ATA SMART 属性参考表
├── helpers/lhm_bridge/                # 独立 MPL-2.0 LibreHardwareMonitor 辅助进程（C# .NET）
├── packaging/windows/                 # Inno Setup 6 脚本、代码签名与一键发布脚本
├── docs/                              # 架构、构建、权限、硬件兼容性与发布说明
├── src/
│   ├── main.zig / root_tests.zig      # 主程序入口与全量单元测试入口
│   ├── app/state.zig                  # 全局应用状态与三态渲染节能状态机
│   ├── core/                          # 跨平台核心层（传感器模型/统计表/21条健康规则/告警/硬件测试引擎/设备ID）
│   ├── collectors/storage/            # 物理磁盘枚举、NVMe SMART、ATA & 标准 T10 SAT SMART
│   ├── providers/                     # Win32 绑定/SMBIOS/PDH/D3DKMT+NVML/LHM 命名管道客户端
│   ├── database/                      # SQLite 3.53.2 封装、8 表迁移、分级降采样与损坏自动恢复
│   ├── platform/                      # 单实例、托盘、隐藏消息窗口、开机自启、路径解析、显式 UAC 提权
│   ├── services/                      # 后台监控工作线程、TOML 配置服务、脱敏诊断导出
│   ├── gui/                           # 深/浅双主题、字体回退、Bento 卡片/圆弧仪表/ImPlot 控件与 11 页面视图
│   └── utils/toml.zig                 # 零依赖自研 TOML 解析与序列化器
└── WinHardware-Monitor-Development-Spec.md  # 项目完整开发规范
```

---

## 常见问题（FAQ）

- **Q：双击后为什么窗口关闭了程序还在后台？**
  A：默认关闭行为是“最小化到系统托盘”以便持续后台监控温度和磁盘告警。可在「系统设置」中切换为“直接退出程序”，或右键托盘图标退出。
- **Q：为什么 CPU 温度显示 `N/A（需要扩展组件）`？**
  A：Windows 原生 API 不提供 CPU 温度，规范严禁拿不准确的 ACPI 热区温度冒充 CPU 温度。按上文启动可选的 `WinHardwareMonitor.LhmHelper.exe` 即可读取。
- **Q：如何导出故障排查信息发给开发者，会泄露我的硬盘序列号吗？**
  A：在「系统设置」点击 **「导出脱敏诊断报告」**，所有硬盘与内存序列号均自动脱敏（仅保留后 4 位），可放心分享。

---

## 相关文档

- [架构设计说明](docs/ARCHITECTURE.md)
- [构建与打包指南](docs/BUILD.md)
- [权限与驱动安全说明](docs/PERMISSIONS.md)
- [硬件兼容性与实机验证矩阵](docs/HARDWARE_SUPPORT.md)
- [v0.1.0 发布说明](docs/RELEASE_NOTES_v0.1.0.md)
- [更新日志](CHANGELOG.md)
