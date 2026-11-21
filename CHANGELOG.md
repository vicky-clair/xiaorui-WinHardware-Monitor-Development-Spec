# Changelog

## [Unreleased]

### V2.1 - 中/英/日三语全栈国际化、数据准确性加固与低硬件占用优化
- **中 / 英 / 日三语全栈一致显示（`src/core/i18n.zig`）**：
  - 支持 `zh-CN`（简体中文）、`en-US`（English）、`ja-JP`（日本語）实时无重启切换与 `settings.toml` 持久化，支持左侧栏一键切换、设置页单选及 CLI `--lang zh|en|ja`；
  - 覆盖全部 11 个页面、状态枚举（`SensorStatus` / `HealthLevel` / `DiskSupport` / `TestKind` / `TestOutcome`）、26 项 ATA SMART 属性名、21 条磁盘健康规则证据、告警与托盘右键菜单/气泡通知、全传感器统计表（内部采用稳定键，切换语言零重复行）、测试报告与脱敏诊断报告；
  - 字体引擎（`src/gui/fonts.zig`）采用 `merge_mode` 自动合并系统日文字体（Windows `YuGothM/meiryo/msgothic`，Linux `NotoSansCJK`），确保中文、英文与日文假名/汉字清晰无方框。
- **硬件数据准确性加固**：
  - Windows 磁盘基准测试新增 `FILE_FLAG_NO_BUFFERING | FILE_FLAG_WRITE_THROUGH` + 4096 字节页对齐缓冲直通路径（绕过 Windows 系统内存页缓存，测得真实物理 SSD/HDD 的 SEQ1M 与 RND4K 吞吐及延迟），与 Linux 端 `posix_fadvise(POSIX_FADV_DONTNEED)` 保持跨平台一致精度；
  - ATA SMART 温度解析增加零字节过滤，防止不支持温度属性却返回 0 的硬盘误报 `0°C`。
- **低硬件资源占用优化**：
  - `MonitoringService` 引入无锁原子发布序号 `latest_seq_atomic` 与 `tryCopySnapshotIfChanged`，仅在后台产生新样本时加锁拷贝快照，消除 GUI 60 FPS 期间 ~280 KB/帧的冗余内存拷贝与锁竞争（内存拷贝量降低 >100×）；
  - 静置渲染周期优化至 1 FPS（有新样本或输入即时唤醒），取消主循环每帧重复原子同步；
  - `drawLiveAreaPlot` 仅提取最近 60 秒视窗所需的最多 256 个点，降低 7× 栈拷贝与 ImPlot 顶点提交开销。

### V2.0 (Linux x86_64) - 跨平台原生采集、无界面 CLI 测试与 `.tar.gz`/`.deb`/`.rpm` 多格式打包
- **新增 Linux 原生硬件采集层（`src/providers/linux/`）**：
  - `hwmon.zig`：直读内核 `/sys/class/hwmon`（CPU 封装/每核温度、主板温度、风扇、功耗、电压），零驱动即开即用；
  - `system_info.zig`：采集 `/proc/stat`（总体与每核负载）、`cpufreq` 实时频率、`/proc/meminfo`、`/proc/diskstats`（读写 MB/s & IOPS）、`/sys/class/dmi/id` 主板信息与电池状态；
  - `gpu_provider.zig`：基于 `/sys/class/drm/card*` 识别 AMD/Intel/NVIDIA GPU 及其 `hwmon` 指标；
  - `storage.zig`：基于 `/sys/block` 枚举磁盘与稳定 ID，通过 `NVME_IOCTL_ADMIN_CMD` 与标准 `SG_IO` T10 SAT (`0x85` + `0xE5` 防唤醒) 复用现有 SMART 解析器与全部 21 条健康规则。
- **新增无界面 CLI 硬件检测与烤机模式（`src/cli.zig`）**：支持 `--cli` / `--info` 与 `--bench <cpu|mem|disk|all>`（实时高温熔断 + Linux `posix_fadvise(POSIX_FADV_DONTNEED)` 驱逐页缓存测真实磁盘读速）。
- **新增 Linux 多格式打包脚本与 CI（`packaging/linux/`）**：支持一键产出 `.tar.gz` 便携包、`.deb`（Debian/Ubuntu）与 `.rpm`（Fedora/RHEL/CentOS/Rocky/openSUSE）及 `SHA256SUMS.txt`，并在 Debian 13 物理主机完成全套编译、打包、SATA/USB 实盘 SMART 读取与烤机实测。

### V2.0 (Windows) - LHM Bug 修复、深度监控增强与主动硬件测试套件
- **修复 `WinHardwareMonitor.LhmHelper.exe` 两个核心 Bug**：
  - 将本地命名管道 ACL 细化为“仅当前用户 SID + 显式拒绝网络 + Medium Integrity 完整性标签（`S:(ML;;NW;;;ME)`）”，解决普通权限主程序无法直连管理员权限辅助进程的跨完整性级别访问被拒问题；
  - 直接双击 `WinHardwareMonitor.LhmHelper.exe` 时在独立线程弹出友好说明窗口，主程序通过 `--from-host` 启动时保持无弹窗静默运行；实测通过实时命名管道 `snapshot` / `shutdown` 联调与优雅退出。
- **对标 HWiNFO64 / CrystalDiskInfo 的只读深度监控增强**：
  - 新增 `src/core/sensor_stats.zig` 与「全传感器表」页面：全量追踪所有活跃传感器的**当前 / 最小 / 平均 / 最大 / 采样数**，支持一键清零与 UTF-8 BOM CSV 报表导出；
  - 处理器页面新增 **每核逻辑处理器实时负载条**（`NtQuerySystemInformation`）；主板/系统卡片新增 **电池/供电状态** 与 **磁盘实时读写吞吐 (MB/s & IOPS)**；
  - `src/collectors/storage/ata_smart.zig` 新增 **标准只读 T10 SAT 透传**（`IOCTL_SCSI_PASS_THROUGH_DIRECT` + CDB `0x85`，含 `CHECK POWER MODE 0xE5` 防唤醒，严禁厂商私有命令）；NVMe 详情表展示全部温度传感器 `#1–#8`。
- **对标 OCCT / MemTest / CrystalDiskMark 的主动硬件测试套件（`src/core/benchmarks.zig` + 「硬件测试」页面）**：
  - **CPU 稳定性与算力校验**：多线程整数+浮点确定性核校验（检出计算错误计数 + MOPS 算力）；
  - **内存 4 轮位翻转与带宽校验**：棋盘格 / 走 1 / 地址异或 / PRNG 写读回校（防 OOM 上限保护 + GB/s 读写带宽）；
  - **磁盘文件级 SEQ1M / RND4K 基准测试**：需二次确认勾选，仅在 `logs` 目录创建受控临时文件并于结束后自动删除（绝不写裸盘）；
  - **GPU OpenGL 3.3 渲染烤机** + **可选 ATA SMART 短自检**（二次确认）+ **全测试内置实时高温自动熔断保护** + 一键导出测试报告。

### P8 - 可选 LHM 扩展辅助进程、设置完善、Q6/Q7/Q8 收尾与发布打包
- **构建独立隔离的 MPL-2.0 LibreHardwareMonitor 辅助进程**（`helpers/lhm_bridge/`）：
  - 锁定 `LibreHardwareMonitorLib 0.9.4`（MPL-2.0），发布单文件 WinExe（`WinHardwareMonitor.LhmHelper.exe`，无控制台黑框、零网络、严格只读、仅采集 CPU/主板/控制器/内存，不碰磁盘与 GPU）
  - 通过同用户本地命名管道 `\\.\pipe\WinHardwareMonitor_LhmBridge_v1`（`PipeOptions.CurrentUserOnly`）提供 v1 协议快照与优雅退出指令
  - 完成 Zig 侧完整命名管道客户端（`src/providers/libre_hardware_monitor/client.zig`），接入总览、CPU 温度仪表与告警、主板原始传感器明细表及设置页显式 UAC 启动/停止入口
- **设置与用户体验完善**：
  - 新增当前用户开机自启（`src/platform/autostart.zig`，写入 `HKCU\...\Run`）、配置备份导出/导入（`config/settings_backup.toml`）
  - 精简全局顶栏（将系统开机时长移入主板与系统信息卡片），优化可移动 USB 磁盘 SMART 提示文案
- **Q6 / Q7 / Q8 定型与 P8 打包发布**：
  - 完成 Inno Setup 6 安装脚本（`packaging/windows/installer.iss`，支持用户级默认安装、可选 LHM 扩展组件默认不勾选、卸载询问保留数据）
  - 完成代码签名流水线（`packaging/windows/sign.ps1`，对接 Windows SDK `signtool.exe`）与一键构建打包脚本（`packaging/windows/build_release.ps1`），产出便携版 ZIP、安装程序 EXE、发布说明与 `dist/SHA256SUMS.txt`

### UX 修复与稳定性增强（管理员白屏、无控制台窗口、黑白双主题、防裁切自适应布局）
- **移除多余控制台黑框**：在 `build.zig` 中将 `winhardware-monitor` 切换为 Windows GUI 子系统（`exe.subsystem = .Windows`），启动不再弹出附带终端窗口
- **修复管理员启动与托盘唤醒白屏**：
  - 将 `MonitoringService` 与 `next_states` 移至堆分配避免大对象挤占栈空间，并在 OpenGL / 字体就绪后再启动后台采集线程
  - 窗口改为隐藏创建（`.visible = false`），待首帧完整渲染并 `swapBuffers()` 后再显示，且 UI 改用非阻塞 `tryCopySnapshot`
  - 修复托盘隐藏后经由 `SingleInstance`（含右键“以管理员身份运行”）唤醒窗口时 `in_tray` 未复位导致停留在 `.paused_hidden` 永不重绘的白屏问题；补齐焦点与取消最小化回调
  - 显式“以管理员身份重启”改为先释放单实例互斥体再提权并传入 `--wait-mutex` 平滑交接
- **新增深色 / 浅色（黑白）双主题实时切换**：支持左侧栏一键切换与系统设置页切换，自动同步 Windows 10/11 原生标题栏深浅色并持久化到 `settings.toml`
- **修复文字裁切与底部大片空白**：移除卡片 `.no_scrollbar` 裁切、改用三列表格与自动换行键值行，并按 `getContentRegionAvail` 动态撑满页面底部区域

### P6 & P7 - 本地历史数据库、降采样、告警中心与脱敏诊断导出
- 新增 `src/database/repository.zig`：实现 SQLite 8 表 Schema 与版本迁移、60 秒批量事务写入、1m → 15m 分级降采样与过期清理（永久保留告警关联 SMART）、以及数据库损坏自动备份重建恢复
- 新增 `src/core/alert.zig`：实现 30 秒持续时间防抖、5°C 回差恢复、30 分钟重复抑制、NVMe WCTEMP/CCTEMP 设备阈值优先与磁盘健康规则联动告警，打通托盘气泡通知
- 新增 `src/services/diagnostics.zig`：实现全序列号脱敏的诊断报告导出
- 历史趋势页、告警中心页与设置页完整接入实时数据与交互

### P5 - 温度采集（磁盘、GPU 通用路线与扩展组件 IPC）
- 新增 `src/providers/windows/gpu_provider.zig`：支持 D3DKMT 通用 GPU 温度/风扇/频率与运行时动态 `nvml.dll`（温度/功耗/占用/显存/频率/风扇），普通用户权限可用且零编译期厂商 SDK 依赖
- 新增 `src/providers/libre_hardware_monitor/{protocol,client}.zig`：定义带版本号 `v1` 与 1 MB 上限的只读命名管道 IPC 协议，默认关闭且辅助进程不可用时优雅降级
- 总览页与 GPU 页面接入真实 GPU 温度圆弧仪表、实时温度曲线与实时功耗/显存/频率/风扇展示

### P4 - SMART 数据解析、磁盘电源状态保护与 21 条健康规则引擎
- 新增 `src/collectors/storage/nvme_smart.zig`：完整解析 NVMe Log Page 02h（含全部 128 位计数器、原始 512B 追溯页）与 Identify Controller WCTEMP/CCTEMP，支持普通用户 `access=0` 实机读取
- 新增 `src/collectors/storage/ata_smart.zig`：实现 ATA `CHECK POWER MODE (0xE5)` 休眠保护（默认不唤醒休眠硬盘）、SMART READ DATA / THRESHOLDS / RETURN STATUS 解析与 48 位 Raw 值保留
- 新增 `src/core/health_rules.zig`：严格按规范 §2.5.5 实现全部 21 条编号健康判定规则与计数基线机制，21 条规则均具备独立单元测试
- 磁盘页面升级为“多磁盘列表 + 完整磁盘详情面板”，支持健康规则证据展示与“重设基线”操作

### P3 - 磁盘设备枚举、稳定设备 ID 与热插拔联动
- 新增 `src/core/device_id.zig`：基于 SHA-256（接口+型号+序列号+WWN）生成跨重启稳定 16 位设备 ID，无效序列号自动回退并标示不稳定
- 新增 `src/collectors/storage/enumerate.zig`：普通用户零权限句柄枚举全部物理磁盘、精确容量、接口分类与去重，明确区分 RAID / Storage Spaces / 虚拟机磁盘
- 打通 `WM_DEVICECHANGE` 与 `WM_POWERBROADCAST` 到后台监控线程的异步重扫触发（`triggerDiskRescan`）
- 磁盘页面与总览页接入实时多磁盘列表展示

### P2 - Windows 系统信息采集与配置管理
- 新增 `AppPaths`（安装版 `%LOCALAPPDATA%` 与便携版 `portable.flag` 自动识别，全宽字符支持中文与空格路径）
- 新增 `AppConfig`（基于 TOML 的配置加载、校验、安全回退与持久化保存，SMART 间隔强制 ≥30 秒）
- 新增 `SMBIOS` 解析器（读取主板厂商/型号/版本与物理内存插槽容量、类型、频率与脱敏序列号）
- 新增 `PDH` + `GetSystemTimes` + `GlobalMemoryStatusEx` + `GetTickCount64` 真实系统采集 Provider（CPU 计算频率明确标注 `计算值`）
- 新增固定容量环形缓冲区 `RingBuffer(1800)` 与独立后台监控工作线程 `MonitoringService`（与 GUI 主线程解耦）
- 将真实 CPU/内存/SMBIOS/运行时间数据与实时 ImPlot 面积折线图接入总览、CPU、内存、主板与设置页面

### P1 - GUI 基础框架、单实例、托盘与渲染节能
- 确定主程序采用 Apache-2.0 许可证（新增 `LICENSE`），可选 LibreHardwareMonitor 辅助进程以独立进程隔离并遵循 MPL-2.0
- 参照 `界面示例.jpg` 与 `界面示例2.jpg` 实现深色 Bento + Grafana 风格主题、圆角卡片、240° 抗锯齿圆弧仪表、360° 环形仪表与 ImPlot 趋势图容器
- 实现左侧导航栏与全部 9 个功能页面骨架（所有未接入采集器的硬件指标严格显示 `N/A` 与真实原因）
- 实现 Windows 10/11 原生深色标题栏、系统字体链式回退（`msyh.ttc → simhei.ttf → simsun.ttc`）与 DPI 缩放
- 实现单实例命名互斥体、隐藏顶层消息窗口（托盘交互 / `TaskbarCreated` / `WM_DEVICECHANGE` / `WM_POWERBROADCAST`）、显式管理员重启与 §6.1 三态渲染节能策略

### P0 - 技术验证与项目骨架
- 初始化 Zig 0.15.2 项目骨架、锁定依赖（zgui / zglfw / zopengl / SQLite 3.53.2）
- 建立 `AGENTS.md` 开发规则与 GitHub Actions Windows CI
- 实现手写 Win32 API 绑定与 `comptime` 结构体布局校验
- 实现自研零依赖 TOML 解析与序列化器
- 完成 Windows 11 x64 实机 P0 技术验证并回填规范 §1.2.1 权限能力矩阵
