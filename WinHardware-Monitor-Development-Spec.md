# Windows 硬件监控软件开发规范

| 项目 | 内容 |
| --- | --- |
| 项目代号 | WinHardware Monitor（暂定） |
| 技术规范版本 | V1.1 |
| 文档日期 | 2026-11-21 |
| 目标平台 | Windows 10 / Windows 11 x64 |

## 修订记录

| 版本 | 日期 | 说明 |
| --- | --- | --- |
| V1.0 | 2026-11-20 | 初版 |
| V1.1 | 2026-11-21 | 新增权限与驱动策略、权限能力矩阵；修正传感器状态枚举；新增稳定设备 ID、大整数与时间戳规则；新增健康判定规则表与基线机制；补充 SMART 读取细节、磁盘电源状态保护、兼容范围；新增后台运行与系统集成；新增数据降采样与存储位置；补充渲染节能、告警防抖、代码签名、Zig 生态风险、测试对照标准；调整开发阶段与 MVP 范围；统一为 GFM 表格格式；新增术语表与待决事项 |

## 1. 项目定位

开发一款 Windows 桌面硬件监控软件，重点关注两大领域：

1. **硬件温度监控**：CPU、GPU、主板、内存、硬盘等设备的温度及相关运行参数。
2. **磁盘健康监控**：HDD、SATA SSD、NVMe SSD 的 SMART 数据、健康状态、寿命损耗和异常指标。

目标是做成可以长期运行、低资源占用、数据可靠、界面直观的独立桌面应用。

### 1.1 基本技术决策

| 项目 | 确定方案 |
| --- | --- |
| 编程语言 | Zig（锁定具体版本，见 1.3） |
| GUI | zgui + Dear ImGui |
| 图表 | ImPlot（zgui 扩展） |
| 窗口与渲染 | GLFW + OpenGL 3.3 Core |
| 操作系统 | Windows 10 / Windows 11 x64 |
| 硬件接口 | Windows Win32 API（用户态） |
| Win32 绑定 | 在 P0 中二选一：zigwin32 或项目内手写 `extern` 声明，确定后不得混用 |
| 磁盘协议 | ATA SMART / NVMe SMART / SAT（USB 桥接，仅标准命令） |
| 数据存储 | SQLite（通过 build.zig 编译 amalgamation 源码） |
| 配置文件 | TOML（Zig 标准库无 TOML 解析器，P0 中选定第三方库或自行实现最小子集） |
| 日志 | 基于 `std.log` 封装的结构化日志，JSON Lines 格式 |
| 构建系统 | Zig Build System |
| 持续集成 | GitHub Actions（windows runner），执行构建与自动化测试 |
| 发布形态 | 便携版 ZIP + 安装程序，打包工具在 P8 前确定 |

选择 zgui 的原因是：硬件监控软件需要大量实时数据展示、动态图表、设备列表、传感器状态和告警信息。Dear ImGui 的即时模式 GUI 适合这类工具，不需要 Electron、浏览器内核或完整的 Web 运行环境。

### 1.2 权限与驱动策略

Windows 上不存在能在所有平台统一读取 CPU 温度的公开用户态接口。CPU 核心温度、CPU 功耗（RAPL）、真实频率（APERF/MPERF）、主板 Super I/O 传感器、DIMM 温度（SMBus）通常都需要内核驱动访问 MSR 或 IO 端口。本项目采用以下策略：

1. **主程序本体不包含、不安装任何内核驱动。**
2. **主程序可以在普通用户权限下启动**，并按下方能力矩阵自动降级，对不可用的数据明确显示原因（如"需要管理员权限""需要启用扩展传感器组件"）。
3. **管理员模式**：用户可在界面中选择"以管理员身份重新启动"，以获得 ATA SMART 等需要管理员权限的数据。程序不得静默提权。
4. **扩展传感器组件**（LibreHardwareMonitor 辅助进程）为**默认关闭的可选组件**。用户启用前必须看到明确说明：该组件需要管理员权限，并会加载第三方内核驱动（当前 LibreHardwareMonitor 使用 PawnIO；旧版使用的 WinRing0 已被 Windows Defender 标记为存在漏洞的驱动，禁止使用依赖 WinRing0 的版本）。
5. 未启用扩展组件时，磁盘监控、系统信息、GPU 基础信息等原生功能必须完整可用。

#### 1.2.1 权限能力矩阵

| 能力 | 普通用户 | 管理员 | 需扩展组件（驱动） | 说明 |
| --- | --- | --- | --- | --- |
| CPU 使用率、内存使用 | ✅ | ✅ | — | PDH / GetSystemTimes / GlobalMemoryStatusEx |
| CPU 频率（计算值） | ✅ | ✅ | — | PDH `% Processor Performance` × 基础频率，标为"计算值" |
| CPU 真实频率、温度、功耗 | ❌ | ❌ | ✅ | 需要 MSR 访问 |
| 内存频率、型号 | ✅ | ✅ | — | SMBIOS（GetSystemFirmwareTable） |
| DIMM 温度 | ❌ | ❌ | ✅ | 需要 SMBus 访问 |
| 主板传感器、风扇、电压 | ❌ | ❌ | ✅ | 需要 Super I/O 访问 |
| GPU 使用率、显存 | ✅ | ✅ | — | PDH GPU Engine / DXGI |
| GPU 温度 | ✅（Win11 实测） | ✅ | 可选 | `D3DKMTQueryAdapterInfo(KMTQAITYPE_ADAPTERPERFDATA)` 与动态加载 `nvml.dll` 在 Win11 26300 + RTX 2060 普通用户权限下均实测可读（Win10 待补测） |
| 磁盘枚举、型号、容量 | ✅ | ✅ | — | IOCTL_STORAGE_QUERY_PROPERTY（零访问权限句柄 `dwDesiredAccess=0`） |
| 磁盘温度（存储温度描述符） | ✅（NVMe，取决于设备与驱动） | ✅ | — | Win11 实测：WD Blue SN570 NVMe 以 `access=0` 可读温度及 Warn/Crit 阈值；USB 桥接盘可能不支持（返回 err=1117） |
| NVMe SMART | ✅（需 `access=0` 打开） | ✅ | — | Win11 实测：以 `dwDesiredAccess=0` 打开句柄可读 Log Page 02h 与 Identify Controller（WCTEMP/CCTEMP）；以 `GENERIC_READ` 打开会报 `ERROR_ACCESS_DENIED=5`（Win10 待补测） |
| ATA SMART | ❌（实测 err=5） | ✅ | — | 需要 `GENERIC_READ \| GENERIC_WRITE` 句柄，普通用户报 `ERROR_ACCESS_DENIED` |

以上结果已于 P0 阶段在 Windows 11 专业版（10.0.26300，Intel i5-12490F，RTX 2060，WD Blue SN570 NVMe，HIKSEMI USB 3.0）普通用户权限下实测回填；Windows 10 22H2 及管理员权限下的 ATA SMART/smartctl 对照将于后续实机矩阵测试中补齐。

### 1.3 版本约束

1. Zig、zgui、Dear ImGui、ImPlot、GLFW、SQLite、TOML 库等依赖必须锁定具体版本或提交哈希，记录在 `build.zig.zon` 和 `docs/BUILD.md` 中。
2. Zig 尚未发布 1.0，各版本之间存在破坏性变更，zgui 也绑定特定 Zig 版本。**必须锁定一个具体 Zig 版本**（如 `0.x.y`），不得使用"最新 nightly"。
3. 升级 Zig 或核心依赖的流程：单独分支 → 说明原因与兼容性影响 → 全量构建与测试通过 → 更新文档 → 合并。不得与功能开发混在同一次提交中。
4. 不得默认最新版本一定兼容，也不得在未验证前宣称构建成功。

## 2. 软件功能规划

### 2.1 硬件总览

首页显示：

- CPU 名称、占用率、频率、温度、功耗。
- GPU 名称、占用率、温度、显存、功耗。
- 内存使用量、使用率、频率及可获取的温度。
- 主板温度及传感器信息。
- 所有物理磁盘的温度和健康状态。
- 系统运行时间。
- 当前告警数量。
- 当前运行权限（普通用户 / 管理员）和扩展组件状态。

要求：

- 自动识别硬件。
- 设备数量不固定。
- 支持多个 CPU/GPU/磁盘设备。
- 无法读取的参数显示为 `N/A`，并可查看原因（不支持、权限不足、需要扩展组件、读取失败等）。
- 不允许用估算值冒充真实传感器数据。
- 每项数据必须标明来源、单位和采集时间。

### 2.2 CPU 监控

| 指标 | 说明 | 数据来源 |
| --- | --- | --- |
| CPU Package | CPU 封装温度 | 扩展组件 |
| CPU Core | 各核心温度 | 扩展组件 |
| CPU Average | 核心平均温度（计算值） | 由核心温度计算 |
| CPU Usage | 总使用率与各逻辑核心使用率 | PDH / NtQuerySystemInformation |
| CPU Clock | CPU 频率 | 普通模式为计算值；扩展组件提供实际值 |
| CPU Power | CPU 功耗 | 扩展组件 |
| CPU Fan | CPU 风扇转速（支持时） | 扩展组件 |

兼容方向：

- Intel Core 系列。
- AMD Ryzen 系列。
- 多核心、多线程处理器、混合架构（P 核 / E 核）。

说明：

1. Windows 11 任务管理器使用 `% Processor Utility` 计数器，与传统 `% Processor Time` 算法存在差异。程序需在数据来源中注明所用计数器。
2. **禁止**将 WMI `MSAcpi_ThermalZoneTemperature` 标注为 CPU 温度。该值是 ACPI 热区温度，多数平台上不代表 CPU 核心温度。如需展示，只能以"ACPI 热区"原始名称展示。
3. CPU 温度通过 LibreHardwareMonitor 兼容适配器获取。LibreHardwareMonitor 是 .NET 项目（MPL-2.0 许可），Zig 不能直接导入，采用独立辅助进程 + 本机 IPC 方式，详见 3.4。

### 2.3 GPU 监控

自动识别：NVIDIA GPU、AMD GPU、Intel GPU。

| 指标 | 说明 |
| --- | --- |
| GPU Temperature | GPU 温度 |
| GPU Hotspot | GPU 热点温度 |
| Memory Temperature | 显存温度 |
| GPU Usage | GPU 使用率 |
| Memory Usage | 显存占用 |
| Core Clock | 核心频率 |
| Memory Clock | 显存频率 |
| GPU Power | GPU 功耗 |
| Fan Speed | 风扇转速 |

采集路线（按优先级）：

1. **厂商无关路线（MVP）**：
   - GPU 使用率：PDH `GPU Engine` 计数器。
   - 显存：DXGI `IDXGIAdapter3::QueryVideoMemoryInfo`。
   - GPU 温度：评估 `D3DKMTQueryAdapterInfo` + `KMTQAITYPE_ADAPTERPERFDATA`（任务管理器 GPU 温度来源，需 WDDM 2.4 及以上，需实测）。
2. **厂商 SDK 路线（后续扩展）**：
   - NVIDIA：优先 NVML（随驱动提供 `nvml.dll`，运行时动态加载，不随软件分发），NVAPI 作为补充。
   - AMD：ADLX。
   - Intel：IGCL（Intel Graphics Control Library）或 Level Zero Sysman。

要求：

- 自动识别 GPU 型号，支持多 GPU。
- 仅展示硬件和驱动实际支持的指标，不支持的传感器不产生虚假数据。
- 不同厂商接口必须隔离在独立 Provider 中。
- 每个接口的许可、分发条件、驱动要求和实际可用指标必须在实现前核实。
- **混合显卡笔记本**：轮询独立显卡可能将其从低功耗状态唤醒并增加耗电。独显处于休眠状态时默认不主动唤醒，提供设置项控制。

### 2.4 内存与主板

内存：

- 总容量、已使用容量、可用容量、使用率（用户态）。
- 内存频率、型号、插槽信息（SMBIOS，用户态）。
- DIMM 温度（需扩展组件，硬件支持时）。

主板（需扩展组件）：

- 主板型号（SMBIOS，用户态可得）。
- 主板温度传感器、芯片组温度、VRM 温度。
- 风扇转速。
- 电压信息（支持时）。

注意：主板传感器名称可能由厂商定义，必须保留原始传感器名称，不要将未知传感器强行归类。

### 2.5 磁盘健康监控

这是本项目最重要的模块之一。

支持设备：

- SATA HDD。
- SATA SSD。
- NVMe SSD。
- 多磁盘设备。
- USB 外接磁盘（仅支持标准 SAT 透传，取决于桥接芯片、固件和驱动支持情况）。

明确的兼容边界（以下情况必须显示"未知"并说明原因，不得报错崩溃或显示为健康）：

- Intel RST / VMD 模式下的 NVMe（标准 IOCTL 通常无法访问）。
- 硬件 RAID 阵列、存储空间（Storage Spaces）虚拟磁盘。
- 虚拟机虚拟磁盘。
- 需要桥接芯片厂商私有命令才能读取 SMART 的 USB 设备（V1 **禁止**发送厂商私有命令）。

磁盘基本信息：

| 参数 | 内容 |
| --- | --- |
| Model | 硬盘型号 |
| Serial Number | 序列号（默认脱敏展示） |
| Firmware | 固件版本 |
| Interface | SATA / NVMe / USB |
| Capacity | 磁盘容量 |
| Power On Hours | 累计通电时间 |
| Power Cycle Count | 通电次数 |
| Temperature | 磁盘温度 |
| Health | 健康状态及触发规则 |

#### 2.5.1 SATA SMART 属性

通用属性：

| ID（十六进制） | ID（十进制） | 属性 | 监控目的 |
| --- | --- | --- | --- |
| 01 | 1 | Read Error Rate | 读取错误（编码因厂商而异） |
| 03 | 3 | Spin-Up Time | 起转时间（HDD） |
| 05 | 5 | Reallocated Sectors Count | 重映射扇区 |
| 07 | 7 | Seek Error Rate | 寻道错误（编码因厂商而异） |
| 09 | 9 | Power-On Hours | 通电时间 |
| 0A | 10 | Spin Retry Count | 起转重试 |
| 0C | 12 | Power Cycle Count | 通电次数 |
| B8 | 184 | End-to-End Error | 数据路径错误 |
| BB | 187 | Reported Uncorrectable Errors | 不可校正错误 |
| BC | 188 | Command Timeout | 命令超时 |
| BE | 190 | Airflow Temperature | 气流温度 |
| C1 | 193 | Load Cycle Count | 磁头加载/卸载次数 |
| C2 | 194 | Temperature | 温度（Raw 低字节通常为当前温度） |
| C4 | 196 | Reallocation Event Count | 重映射事件 |
| C5 | 197 | Current Pending Sector | 待处理扇区 |
| C6 | 198 | Offline Uncorrectable | 离线不可校正扇区 |
| C7 | 199 | UDMA CRC Error Count | 接口传输错误 |

SATA SSD 常见属性（含义因厂商而异，必须通过厂商属性数据库解释）：

| ID（十六进制） | ID（十进制） | 常见含义 |
| --- | --- | --- |
| AB | 171 | Program Fail Count |
| AC | 172 | Erase Fail Count |
| AD | 173 | Wear Leveling Count |
| B1 | 177 | Wear Range Delta / Wear Leveling Count |
| B4 | 180 | Unused Reserved Block Count |
| E7 | 231 | SSD Life Left |
| E9 | 233 | Media Wearout Indicator |
| F1 | 241 | Total LBAs Written |
| F2 | 242 | Total LBAs Read |

每个属性必须读取并保存：ID、Flags（含 Prefail/Old-age 标志）、Normalized（当前值）、Worst（最差值）、Threshold（阈值）、Raw（6 字节原始值）。

读取命令：

- SMART READ DATA（属性值）。
- SMART READ THRESHOLDS（阈值）。
- SMART RETURN STATUS（磁盘自身报告的整体通过/失败状态）。
- IDENTIFY DEVICE（型号、序列号、固件、是否支持 SMART）。

规则：

1. 以上属性按设备实际提供情况显示，不要求所有磁盘都具有全部属性。
2. 厂商对部分 SMART 原始值的编码可能不同，必须保留原始数据，不能把所有设备的 Raw Value 解释成统一含义。
3. 厂商属性数据库以项目自有格式维护（`data/drive_attributes.toml` 或同类文件）。**smartmontools 的 `drivedb.h` 为 GPL 许可，在项目许可证确定前不得直接内嵌或翻译其内容**。
4. 无法识别的属性显示为 "Unknown Attribute (ID)"，保留原始值。

#### 2.5.2 NVMe SMART 属性

SMART / Health Information 日志页（Log Page 02h）：

| 指标 | 说明 |
| --- | --- |
| Critical Warning | 严重健康警告（位域，逐位解释） |
| Composite Temperature | 综合温度（Kelvin，显示时转换） |
| Available Spare | 可用备用空间百分比 |
| Available Spare Threshold | 备用空间阈值 |
| Percentage Used | 预计寿命使用百分比（可超过 100，最大 255） |
| Data Units Read | 累计读取量（128 位，1 单位 = 1000 × 512 字节） |
| Data Units Written | 累计写入量（128 位，同上） |
| Host Read Commands | 主机读取命令（128 位） |
| Host Write Commands | 主机写入命令（128 位） |
| Controller Busy Time | 控制器忙碌时间（分钟，128 位） |
| Power Cycles | 通电次数（128 位） |
| Power On Hours | 通电时间（128 位） |
| Unsafe Shutdowns | 非正常关机次数（128 位） |
| Media and Data Integrity Errors | 媒体及数据完整性错误（128 位） |
| Error Information Log Entries | 错误日志条目（128 位） |
| Warning Composite Temperature Time | 处于警告温度的累计时间（分钟） |
| Critical Composite Temperature Time | 处于临界温度的累计时间（分钟） |
| Temperature Sensor 1–8 | 附加温度传感器（设备提供时） |

Identify Controller（CNS 01h）需读取：型号、序列号、固件版本、**WCTEMP（警告温度阈值）**、**CCTEMP（临界温度阈值）**。两个阈值单位为 Kelvin，为 0 表示设备未报告。

可选读取：Error Information Log（Log Page 01h），用于在详情页展示最近错误。

NVMe 数据优先评估 Windows 的 `IOCTL_STORAGE_QUERY_PROPERTY` + `StorageDeviceProtocolSpecificProperty` + `STORAGE_PROTOCOL_SPECIFIC_DATA`。实现时必须根据 Windows SDK 头文件和目标系统版本核对结构布局、查询参数及缓冲区长度，并在 Zig 中用 `comptime` 断言校验 `@sizeOf` 和 `@offsetOf`。

#### 2.5.3 SATA 读取方式

- 首选 `IOCTL_ATA_PASS_THROUGH`，备选 `SMART_RCV_DRIVE_DATA`。
- USB 设备使用 `IOCTL_SCSI_PASS_THROUGH` 封装标准 SAT（ATA PASS-THROUGH 12/16）命令。
- 以上方式通常需要以读写权限打开 `\\.\PhysicalDriveN`，即需要管理员权限。普通用户权限下必须显示"需要管理员权限"，不得显示为"不支持"。
- 必须处理控制器、驱动和 USB 桥接设备造成的访问差异，对每种失败记录具体的 Win32 错误码。

#### 2.5.4 磁盘电源状态保护

定时读取 SMART 会阻止 HDD 进入待机，或将其从待机中唤醒，增加磨损和功耗。

1. 读取 ATA SMART 前，必须先发送 `CHECK POWER MODE` 命令。磁盘处于 Standby/Sleep 时，**默认跳过本次读取**，沿用上次数据并标记为"休眠中（数据为 hh:mm 采集）"。
2. 设置项"允许唤醒休眠磁盘"，默认关闭。
3. 电池供电时，磁盘 SMART 采集周期自动延长（默认 ×5），可在设置中关闭此行为。
4. NVMe 采集需评估对 APST 低功耗状态的影响，在 P4 中实测并记录。

#### 2.5.5 健康状态判定

不能仅根据一个 SMART 属性判定磁盘是否健康。健康状态分为五级：

| 级别 | 含义 |
| --- | --- |
| 正常 | 没有已知严重异常 |
| 注意 | 存在值得观察的指标 |
| 警告 | 出现需要尽快备份和检查的异常 |
| 严重 | 出现关键健康警告或明显恶化 |
| 未知 | 数据无法获取或不足以判断 |

磁盘的整体健康级别 = 所有触发规则中的最高级别。没有任何可用数据时为"未知"。

默认规则表（规则 ID 必须在代码、告警和测试中一致使用；阈值可在设置中调整）：

| 规则 ID | 适用 | 条件 | 级别 |
| --- | --- | --- | --- |
| NVME-CW-SPARE | NVMe | Critical Warning bit 0（备用空间低于阈值） | 严重 |
| NVME-CW-TEMP | NVMe | Critical Warning bit 1（温度超限） | 警告 |
| NVME-CW-RELIABILITY | NVMe | Critical Warning bit 2（可靠性下降） | 严重 |
| NVME-CW-READONLY | NVMe | Critical Warning bit 3（介质只读） | 严重 |
| NVME-CW-BACKUP | NVMe | Critical Warning bit 4（易失性备份设备失效） | 警告 |
| NVME-SPARE | NVMe | Available Spare < Available Spare Threshold | 严重 |
| NVME-MEDIA | NVMe | Media and Data Integrity Errors > 0 | 注意 |
| NVME-MEDIA-INC | NVMe | Media and Data Integrity Errors 相对基线增加 | 警告 |
| NVME-USED-1 | NVMe | Percentage Used ≥ 80（可配置） | 注意 |
| NVME-USED-2 | NVMe | Percentage Used ≥ 100（可配置） | 警告 |
| ATA-STATUS | ATA | SMART RETURN STATUS 报告阈值超限 | 严重 |
| ATA-PREFAIL | ATA | 任一 Prefail 属性 Normalized ≤ Threshold（Threshold ≠ 0） | 严重 |
| ATA-OLDAGE | ATA | 任一 Old-age 属性 Normalized ≤ Threshold（Threshold ≠ 0） | 注意 |
| ATA-05 | ATA | 05 Raw > 0 | 注意 |
| ATA-05-INC | ATA | 05 Raw 相对基线增加 | 警告 |
| ATA-C5 | ATA | C5 Raw > 0 | 警告 |
| ATA-C6 | ATA | C6 Raw > 0 | 警告 |
| ATA-C6-INC | ATA | C6 Raw 相对基线增加 | 严重 |
| ATA-BB | ATA | BB Raw 相对基线增加 | 注意 |
| ATA-C7-INC | ATA | C7 Raw 相对基线增加（提示检查线缆和接口，不判定为盘片损坏） | 注意 |
| SSD-LIFE | SATA SSD | 厂商数据库标记的寿命属性低于 10%（可配置） | 警告 |

基线机制：

1. 首次识别到某块磁盘（按稳定设备 ID）时，记录各计数型属性的当前值作为基线，并记录基线时间。
2. "相对基线增加"指当前值 > 基线值。确认告警后，用户可选择"以当前值为新基线"，原基线保留在历史中。
3. 计数型属性值减小（如固件重置）时记录事件，不触发健康级别下降，并在详情页提示。

特别注意：

1. SMART 正常不代表硬盘不会突然损坏，界面需提示。
2. 不同品牌、型号的原始 SMART 数值可能采用不同编码。
3. NVMe Percentage Used 是寿命消耗估计，不是精确剩余寿命。
4. C7 接口错误不应直接判定为盘片损坏。
5. 不允许将所有 SMART 指标简单相加生成所谓的健康百分比。
6. 健康判定必须给出触发的规则 ID、条件和证据数值，不能只显示颜色。

### 2.6 后台运行与系统集成

软件定位为长期运行，必须提供：

| 功能 | 要求 |
| --- | --- |
| 系统托盘 | 使用 Win32 `Shell_NotifyIcon` 实现（GLFW 不支持托盘）。托盘图标显示整体状态，菜单提供"打开主窗口""暂停采集""退出" |
| 关闭按钮行为 | 设置项：最小化到托盘（默认）/ 退出程序 |
| 最小化行为 | 设置项：最小化到任务栏（默认）/ 最小化到托盘 |
| 开机自启 | 默认关闭。普通权限使用 `HKCU\...\Run`；需要管理员权限时使用计划任务（"最高权限运行"），由用户在设置中明确启用 |
| 单实例 | 通过命名互斥体保证单实例。再次启动时激活已运行实例的主窗口后退出 |
| 桌面通知 | V1 保底使用托盘气泡通知（`NIF_INFO`）；Windows Toast 通知（需要 AppUserModelID 和开始菜单快捷方式）作为增强功能，后续实现 |
| 系统事件 | 创建隐藏消息窗口，处理 `WM_DEVICECHANGE`（或 `CM_Register_Notification`）和 `WM_POWERBROADCAST`，支持 Modern Standby (S0ix) 恢复 |

## 3. 硬件数据采集架构

采用模块化采集架构，不允许将所有硬件读取代码直接写进 GUI。

```text
                GUI 展示层
         zgui / Dear ImGui / ImPlot
                       |
             统一数据模型与业务层
       设备管理 / 数据标准化 / 健康判定 / 告警
                       |
          +------------+------------+------------+
          |            |            |            |
       系统采集      磁盘采集      GPU 采集    扩展传感器
       CPU/RAM       ATA/NVMe      D3DKMT/SDK   LHM 辅助进程
          |            |            |            |
          +------------+------------+------------+
                       |
                 Windows API 层
       Win32 / PDH / Storage IOCTL / DXGI / 本机 IPC
```

### 3.1 采集接口设计

每个硬件采集模块必须遵守统一接口约定：

- 初始化。
- 设备枚举。
- 数据读取（带超时）。
- 能力检测。
- 错误报告。
- 资源释放。

每个传感器数据至少包含：

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| sensor_id | 字符串 | 稳定传感器标识（见 3.2） |
| device_id | 字符串 | 所属设备的稳定标识 |
| name | 字符串 | 传感器名称（保留原始名称） |
| value | 数值，可空 | 当前值；status 不是 `ok` 时为空 |
| unit | 枚举/字符串 | 单位（°C、%、MHz、W、RPM、V、bytes 等） |
| timestamp | 时间戳 | 采集时间（UTC，毫秒） |
| source | 字符串 | 数据来源（如 `pdh:% Processor Utility`、`nvme:log02`、`lhm`） |
| status | 枚举 | 见下表 |
| accuracy | 枚举 | `measured`（传感器实测）、`derived`（由实测值计算）、`estimated`（估算）、`unknown` |
| error_code | 整数，可空 | 失败时的 Win32 / NTSTATUS / 内部错误码 |

status 枚举：

| 值 | 含义 |
| --- | --- |
| `ok` | 读取成功，value 有效（包括有效的 0） |
| `unsupported` | 设备或驱动不支持该指标 |
| `access_denied` | 权限不足 |
| `requires_extension` | 需要启用扩展传感器组件 |
| `transient_error` | 暂时读取失败，会重试 |
| `timeout` | 读取超时 |
| `device_standby` | 设备休眠中，本次未读取（沿用上次值时需标注时间） |
| `device_removed` | 设备已移除 |
| `stale` | 数据超过 3 个采集周期未更新 |
| `unknown` | 无法确定 |

禁止使用零值表示读取失败。`estimated` 类数据在界面上必须带明显标识，且不得参与健康判定。

### 3.2 稳定设备 ID 与数据规则

`PhysicalDriveN`、适配器序号等编号在重启或插拔后可能变化，不得作为设备 ID。

| 设备类型 | 稳定 ID 生成方式 |
| --- | --- |
| 磁盘 | SHA-256（接口类型 + 型号 + 序列号 + WWN/EUI-64 若有），取前 16 个十六进制字符 |
| GPU | PCI VEN/DEV/SUBSYS/REV + PCI 总线位置 |
| CPU | CPUID 厂商 + 品牌字符串 + 插槽序号 |
| 内存条 | SMBIOS 插槽定位符 + 序列号 |
| 传感器 | device_id + 来源 + 原始传感器名称/索引 |

序列号缺失或明显无效（全 0、全空格）时，回退到设备实例路径，并标记"ID 可能不稳定"。

数据规则：

1. **大整数**：NVMe 计数器为 128 位，ATA Raw 为 48 位。内存中使用 `u128`/`u64`。SQLite INTEGER 最大为有符号 64 位，超出范围的值以十进制 TEXT 存储，字段命名注明。
2. **时间**：持久化统一使用 UTC 毫秒时间戳；显示时转换为本地时间。采集间隔与超时计算使用单调时钟，不受用户修改系统时间影响。
3. **单位**：内部统一使用基础单位（°C、字节、Hz、W），显示时格式化。温度显示单位可在设置中切换 °C/°F。

### 3.3 Windows API 采集

优先采用 Windows 官方公开接口：

| 采集目标 | 技术 |
| --- | --- |
| CPU 使用率 | PDH（`% Processor Utility` / `% Processor Time`）、GetSystemTimes |
| CPU 频率（计算值） | PDH `% Processor Performance` + CallNtPowerInformation |
| 内存使用 | GlobalMemoryStatusEx |
| 内存/主板型号 | GetSystemFirmwareTable（SMBIOS） |
| 磁盘设备枚举 | SetupDi / CfgMgr32 + Storage API |
| 磁盘基本信息 | IOCTL_STORAGE_QUERY_PROPERTY（StorageDeviceProperty） |
| NVMe SMART | IOCTL_STORAGE_QUERY_PROPERTY + STORAGE_PROTOCOL_SPECIFIC_DATA |
| 磁盘温度 | STORAGE_TEMPERATURE_DATA_DESCRIPTOR（设备和驱动支持时） |
| SATA SMART | IOCTL_ATA_PASS_THROUGH / SMART_RCV_DRIVE_DATA |
| USB 磁盘 SMART | IOCTL_SCSI_PASS_THROUGH（标准 SAT） |
| GPU 使用率 | PDH `GPU Engine` |
| GPU 显存 | DXGI |
| GPU 温度 | D3DKMTQueryAdapterInfo（待验证）/ 厂商 SDK |
| 系统运行时间 | GetTickCount64 |
| 设备插拔 | WM_DEVICECHANGE / CM_Register_Notification |
| 电源事件 | WM_POWERBROADCAST / RegisterPowerSettingNotification |

`DeviceIoControl` 是磁盘信息读取的重要底层接口。程序需要正确处理设备句柄、输入输出缓冲区长度、返回状态和错误码。对可能长时间阻塞的 IOCTL，使用重叠 I/O 或独立线程配合超时与 `CancelIoEx`。

### 3.4 传感器提供程序

Provider 接口：

```text
SensorProvider
├── initialize()
├── enumerateDevices()
├── readSensors(timeout)
├── getCapabilities()
├── getLastError()
└── shutdown()
```

第一阶段：

- Windows 系统信息 Provider。
- 磁盘 ATA SMART Provider。
- 磁盘 NVMe SMART Provider。
- GPU 通用 Provider（PDH / DXGI / D3DKMT）。
- LibreHardwareMonitor 兼容 Provider（扩展组件）。

后续扩展：

- NVIDIA NVML Provider。
- AMD ADLX Provider。
- Intel IGCL / Level Zero Provider。
- 主板厂商传感器 Provider。

#### 3.4.1 LibreHardwareMonitor 辅助进程

| 项目 | 要求 |
| --- | --- |
| 定位 | 默认关闭的可选组件，主程序不得依赖它才能启动 |
| 运行时 | .NET 自包含（self-contained）发布，不要求用户安装 .NET；体积单独统计并在下载页说明 |
| 权限 | 以管理员权限运行，通过 UAC 提示由用户确认启动；需要开机自动运行时使用计划任务 |
| IPC | 命名管道，协议带版本号，消息格式为长度前缀 + JSON（或同等结构化格式） |
| IPC 安全 | 管道 ACL 仅允许当前登录用户 SID；连接后校验对端进程路径与签名；单条消息限制大小（如 1 MB）；辅助进程只提供只读查询 |
| 生命周期 | 主程序退出时通知辅助进程退出；辅助进程检测到主程序消失后自动退出 |
| 故障 | 辅助进程崩溃或无响应时，相关传感器状态变为 `transient_error`，主程序按退避策略重连，不影响其他功能 |
| 许可 | LibreHardwareMonitor 为 MPL-2.0，PawnIO 驱动许可需在集成前核实，并列入依赖许可证清单 |

## 4. 软件架构与目录结构

采用单机桌面应用架构，不引入不必要的服务器、Docker 或网络依赖。

建议目录：

```text
winhardware-monitor/
│
├── build.zig
├── build.zig.zon
├── README.md
├── LICENSE
├── CHANGELOG.md
├── AGENTS.md
│
├── config/
│   └── default.toml
│
├── data/
│   └── drive_attributes.toml        # 厂商 SMART 属性数据库
│
├── assets/
│   ├── fonts/
│   ├── icons/
│   └── images/
│
├── src/
│   ├── main.zig
│   ├── app/
│   │   ├── app.zig
│   │   ├── state.zig
│   │   └── lifecycle.zig
│   ├── gui/
│   │   ├── window.zig
│   │   ├── theme.zig
│   │   ├── fonts.zig
│   │   ├── navigation.zig
│   │   ├── dashboard.zig
│   │   ├── cpu_view.zig
│   │   ├── gpu_view.zig
│   │   ├── memory_view.zig
│   │   ├── motherboard_view.zig
│   │   ├── disk_view.zig
│   │   ├── history_view.zig
│   │   ├── alert_view.zig
│   │   └── settings_view.zig
│   ├── core/
│   │   ├── device.zig
│   │   ├── device_id.zig
│   │   ├── sensor.zig
│   │   ├── telemetry.zig
│   │   ├── health.zig
│   │   ├── health_rules.zig
│   │   ├── alert.zig
│   │   └── error.zig
│   ├── collectors/
│   │   ├── collector.zig
│   │   ├── cpu.zig
│   │   ├── memory.zig
│   │   ├── gpu.zig
│   │   ├── motherboard.zig
│   │   └── storage/
│   │       ├── enumerate.zig
│   │       ├── ata_smart.zig
│   │       ├── nvme_smart.zig
│   │       ├── sat.zig
│   │       ├── power_state.zig
│   │       ├── temperature.zig
│   │       └── parser.zig
│   ├── providers/
│   │   ├── provider.zig
│   │   ├── windows/
│   │   │   ├── win32.zig
│   │   │   ├── pdh.zig
│   │   │   ├── smbios.zig
│   │   │   ├── storage_ioctl.zig
│   │   │   ├── d3dkmt.zig
│   │   │   └── system_info.zig
│   │   ├── nvidia/
│   │   ├── amd/
│   │   ├── intel/
│   │   └── libre_hardware_monitor/
│   │       ├── client.zig
│   │       └── protocol.zig
│   ├── platform/
│   │   ├── tray.zig
│   │   ├── notification.zig
│   │   ├── single_instance.zig
│   │   ├── autostart.zig
│   │   ├── elevation.zig
│   │   ├── message_window.zig       # 设备插拔与电源事件
│   │   └── paths.zig                # 配置/数据/日志路径
│   ├── database/
│   │   ├── database.zig
│   │   ├── schema.zig
│   │   ├── migration.zig
│   │   ├── downsample.zig
│   │   └── repository.zig
│   ├── services/
│   │   ├── monitoring.zig
│   │   ├── scheduler.zig
│   │   ├── configuration.zig
│   │   └── diagnostics.zig          # 诊断包导出
│   └── utils/
│       ├── time.zig
│       ├── format.zig
│       ├── bigint.zig
│       └── logging.zig
│
├── helper/
│   └── lhm-bridge/                  # .NET 辅助进程（可选组件）
│
├── tests/
│   ├── unit/
│   ├── integration/
│   ├── storage/
│   └── fixtures/
│       ├── ata/                     # ATA SMART 二进制样本 + smartctl 对照输出
│       └── nvme/                    # NVMe 日志页二进制样本 + 对照输出
│
├── docs/
│   ├── ARCHITECTURE.md
│   ├── HARDWARE_SUPPORT.md
│   ├── STORAGE_SMART.md
│   ├── HEALTH_RULES.md
│   ├── WINDOWS_API.md
│   ├── PERMISSIONS.md
│   └── BUILD.md
│
└── packaging/
    └── windows/
```

目录允许在实施过程中合理调整，但必须保持 GUI、业务逻辑、数据采集和系统接口相互独立。只有在确有必要时才新增模块，避免空目录和过度设计。

## 5. 数据存储设计

### 5.1 文件位置

| 内容 | 安装版路径 | 便携版路径 |
| --- | --- | --- |
| 配置 | `%LOCALAPPDATA%\WinHardwareMonitor\config\settings.toml` | `<exe 目录>\config\` |
| 数据库 | `%LOCALAPPDATA%\WinHardwareMonitor\data\monitor.db` | `<exe 目录>\data\` |
| 日志 | `%LOCALAPPDATA%\WinHardwareMonitor\logs\` | `<exe 目录>\logs\` |

- exe 同目录存在 `portable.flag` 文件时进入便携模式。
- 所有路径操作必须支持中文和含空格路径（使用宽字符 API）。
- 卸载时询问用户是否删除配置、数据库和日志，默认保留。

### 5.2 数据表

| 表名 | 用途 |
| --- | --- |
| devices | 硬件设备信息（稳定 ID、首次/最近发现时间） |
| sensors | 传感器信息 |
| telemetry_raw | 短期原始数据（可选，默认不持久化） |
| telemetry_1m | 1 分钟聚合数据（min/avg/max/样本数） |
| telemetry_15m | 15 分钟聚合数据 |
| disk_smart | 磁盘 SMART 快照（原始二进制 + 解析结果） |
| disk_baseline | 计数型属性基线 |
| alerts | 告警记录（规则 ID、证据、触发/恢复/确认时间） |
| schema_version | 数据库版本 |

用户配置以 TOML 文件为准，不在数据库中重复存储。

### 5.3 持久化与降采样

| 数据类型 | 采集周期 | 内存保留 | 持久化方式 | 历史保存 |
| --- | --- | --- | --- | --- |
| CPU/GPU 温度与使用率 | 2 秒 | 最近 1 小时原始数据 | 1 分钟聚合 | 1 分钟聚合 7 天，15 分钟聚合 30 天 |
| 内存状态 | 2 秒 | 最近 1 小时 | 1 分钟聚合 | 同上 |
| 磁盘温度 | 10 秒 | 最近 1 小时 | 1 分钟聚合 | 同上 |
| SMART 健康信息 | 60 秒 | 最新快照 | 值变化时写入快照，且至少每 6 小时写一次 | 90 天（含告警关联快照永久保留） |
| 磁盘基本信息 | 启动及设备变化时 | 当前值 | 变化时写入 | 长期 |

容量估算（100 个传感器）：1 分钟聚合约 14.4 万行/天，7 天约 100 万行；15 分钟聚合 30 天约 29 万行。数据库目标体积小于 200 MB。

要求：

1. 实时数据保存在内存固定容量环形缓冲区。
2. 数据库采用事务批量写入（默认每 60 秒一次）。
3. 过期数据清理与降采样在后台定时执行，不阻塞 UI。
4. 数据库升级必须提供迁移机制，迁移前自动备份数据库文件。
5. 数据库损坏时：重命名损坏文件、新建数据库、在界面提示，GUI 必须能正常启动。
6. 数据库写入不得阻塞 UI 线程。
7. SMART 原始数据和解析结果应能关联追溯。
8. 采集周期均可在设置中调整，SMART 读取最短间隔不低于 30 秒。

## 6. 线程与性能设计

采用采集线程和 UI 主线程分离的设计。

```text
                Main Thread
          GUI / Rendering / 消息窗口
                    |
             Shared Data Snapshot
          （双缓冲或互斥保护的快照）
                    |
        +-----------+-----------+-----------+
        |           |           |           |
     System/GPU   Storage     Extension   Database
     Worker       Worker      IPC Worker   Worker
        |           |           |           |
     PDH/DXGI     SMART       LHM 辅助进程  Persistence
```

约束：

- GUI 主线程不得执行阻塞式硬件查询。
- 每个采集任务必须有超时或可控退出机制，单块磁盘读取超时（默认 5 秒）后标记 `timeout` 并继续处理其他设备。
- 数据跨线程传递必须保证线程安全。
- 不能因为某块硬盘读取失败导致整个采集线程永久阻塞。
- UI 更新频率与硬件采集频率分离。
- 图表历史数据使用固定容量环形缓冲区。
- 数据库写入采用批处理。
- 应用关闭时必须正确停止所有工作线程，最长等待 3 秒。
- 设备插拔和休眠唤醒后必须能恢复设备枚举与采集。

### 6.1 渲染节能策略

| 场景 | 行为 |
| --- | --- |
| 窗口前台且有用户输入 | 最高 60 FPS |
| 窗口可见但无输入 | 使用 `glfwWaitEventsTimeout`，仅在新数据到达或动画需要时重绘（约 1–2 FPS） |
| 窗口最小化或在托盘中 | 完全停止渲染，仅保留采集与告警 |
| 系统锁屏或显示器关闭 | 停止渲染 |

### 6.2 性能目标

| 项目 | 目标 | 测量条件 |
| --- | --- | --- |
| 后台空闲 CPU 占用 | 低于 1% | 窗口在托盘中，默认采集周期 |
| 前台静止 CPU 占用 | 低于 3% | 窗口可见，无用户操作 |
| 内存占用 | 低于 150 MB | 不含扩展组件辅助进程 |
| GUI 交互帧率 | 30–60 FPS | 有用户操作时 |
| 常规温度刷新 | 2 秒 | — |
| 磁盘 SMART 刷新 | 60 秒 | — |
| 程序启动 | 3 秒内显示主窗口 | 磁盘枚举可在显示后异步完成 |

以上是工程目标，不是未经测试的性能承诺。应在明确的测试机器、设备数量和运行场景下测量，并写入测试报告。

## 7. GUI 页面规划

建议使用深色主题，整体参考专业硬件诊断工具，但不要照搬其他软件的界面。

| 页面 | 功能 |
| --- | --- |
| 总览 | 全部硬件状态、权限状态、告警数量 |
| CPU | CPU 参数、温度、历史曲线 |
| GPU | GPU 参数、温度、显存 |
| 内存 | 内存使用率、频率、温度 |
| 主板 | 主板及传感器（未启用扩展组件时显示启用说明） |
| 磁盘 | 所有硬盘健康状态 |
| 磁盘详情 | SMART 属性、寿命、温度、触发规则 |
| 历史记录 | 温度及健康趋势 |
| 告警中心 | 温度过高、磁盘异常、告警历史 |
| 设置 | 刷新周期、告警、数据保留、托盘、自启、扩展组件、导入导出 |

磁盘详情页面必须提供：

- 硬盘型号、容量、接口、固件。
- 当前温度及温度阈值来源（设备报告 / 用户设置）。
- 健康状态及触发的规则 ID、证据数值。
- SMART 属性表格：ID、名称、类型（Prefail/Old-age）、当前值、最差值、阈值、原始值（十六进制及解析值）。
- 属性解释（来自厂商属性数据库，未知属性明确标注）。
- 基线信息及"重设基线"操作。
- 历史异常记录。
- 数据采集时间和是否为休眠期间沿用的旧数据。

GUI 交互要求：

- 界面语言：V1 为简体中文，文本集中管理，便于后续增加英文。
- 中文字体：优先运行时加载系统字体（如 `C:\Windows\Fonts\msyh.ttc`），只加载所需字形范围；系统字体不可用时回退到内置的精简字体。
- 支持 DPI 缩放和多显示器不同 DPI。
- 长设备名称不得破坏布局。
- 多磁盘、多 GPU 时列表可滚动。
- 无数据、加载中、读取失败、权限不足、需要扩展组件、设备休眠、不支持必须有不同状态显示。
- 图表支持时间范围切换（1 小时 / 24 小时 / 7 天 / 30 天）。
- 关键数值同时提供文字，不只依赖颜色。
- 关闭窗口、最小化和退出行为符合 2.6 中的设置项。
- 启动时检测 OpenGL 3.3 是否可用（远程桌面、部分虚拟机、老旧核显可能不支持），不可用时用 Win32 消息框给出明确提示，不得静默崩溃。

## 8. 告警系统

### 8.1 温度告警

阈值优先级：用户设置 > 设备报告的阈值 > 默认初始值。

| 设备 | 设备报告阈值来源 | 默认注意 | 默认警告 |
| --- | --- | --- | --- |
| CPU | TjMax（扩展组件提供时，注意 = TjMax − 15°C，警告 = TjMax − 5°C） | 80°C | 90°C |
| GPU | 厂商 SDK 提供的降频温度（如有） | 80°C | 90°C |
| NVMe SSD | Identify Controller 的 WCTEMP / CCTEMP | 60°C | 70°C |
| SATA SSD | — | 60°C | 70°C |
| HDD | — | 50°C | 55°C |

默认值仅为可配置的初始提醒值，不能作为所有硬件的统一安全标准。

### 8.2 磁盘告警

磁盘告警由 2.5.5 健康规则表驱动。健康级别升高到"注意"及以上时产生告警，告警记录中必须包含规则 ID 和证据数值。

### 8.3 告警行为要求

- 支持阈值配置。
- **持续时间**：温度连续超过阈值达到设定时长（默认 30 秒）才触发，避免瞬时尖峰误报。
- **回差**：温度降到阈值以下指定值（默认 5°C）才视为恢复，避免在阈值附近反复触发。
- 支持重复告警抑制（同一规则、同一设备默认 30 分钟内不重复通知）。
- 支持恢复通知（可关闭）。
- 支持告警确认。
- 支持告警历史。
- 支持桌面通知（见 2.6）。
- 告警不能只依赖颜色，还必须提供文字说明。
- 对计数型 SMART 属性重点检测增量，而不是只看某个固定绝对值。
- 告警规则必须能解释触发原因。

## 9. 安全、权限与隐私

第一版主程序不安装内核驱动，权限策略见 1.2。

必须遵守：

1. 不主动修改硬件设置。
2. 不执行磁盘写入测试。
3. 不发送 NVMe 固件更新命令或任何会修改设备状态的命令。
4. 不执行 SMART 自检，除非未来明确加入独立功能并获得用户确认。
5. 不向 USB 桥接芯片发送厂商私有命令。
6. 默认不需要管理员权限即可启动，不静默提权。
7. 遇到权限不足时明确说明缺少什么权限，以及如何获得。
8. 不自动安装第三方驱动；扩展组件必须由用户明确启用。
9. **网络策略：V1 默认零网络访问。** 不上传设备序列号、SMART 数据或其他用户信息。如未来加入更新检查，必须默认关闭并由用户启用，且只发送版本号。
10. 本机 IPC 必须验证连接来源，限制消息大小（见 3.4.1）。
11. 外部辅助进程不可用时，核心监控功能仍可运行。
12. 所有设备句柄、内存、线程和数据库连接必须有明确的生命周期管理。
13. 对来自设备和驱动的数据进行长度、范围和结构校验。
14. **序列号隐私**：界面默认脱敏（只显示后 4 位）；日志中一律脱敏；数据库中存储完整序列号用于设备识别，但导出诊断包时必须脱敏。

## 10. 测试要求

必须建立自动化测试体系，并接入 CI。

| 测试类别 | 验证内容 |
| --- | --- |
| 单元测试 | 数据转换、SMART 解析、健康规则、大整数、设备 ID 生成 |
| 接口测试 | Win32 API 返回值及错误处理（通过可替换的接口层注入错误） |
| 设备测试 | 不同硬盘和 GPU 的识别 |
| 稳定性测试 | 连续运行 24–72 小时，监测内存与句柄数无持续增长 |
| 性能测试 | CPU、内存、采集开销，按 6.2 的测量条件 |
| 异常测试 | 硬盘断开、权限不足、驱动不支持、扩展组件崩溃 |
| 数据库测试 | 迁移、损坏、恢复、降采样 |
| GUI 测试 | 页面切换、图表、告警 |

### 10.1 SMART 解析对照标准

- 必须准备 ATA 和 NVMe SMART 二进制测试数据样本，不能只依靠实际硬盘进行测试。
- 每个样本必须附带 **smartctl（smartmontools）在同一块盘上的输出**作为对照（只用作测试对照，不复制其代码或数据库）。
- P4 验收要求：解析结果与对照输出的 ID、当前值、最差值、阈值、原始值逐项一致。

### 10.2 测试覆盖要求

- 不同字节序和字段长度。
- 缺失属性、未知属性和异常原始值。
- 128 位计数器边界值。
- 设备重复枚举。
- 睡眠、唤醒和热插拔。
- 磁盘休眠状态下不唤醒磁盘。
- 采集超时和取消。
- 数据库升级中断。
- 中文路径、用户名和安装目录。
- 普通用户与管理员两种权限下的行为。
- Windows 10/11 目标版本差异。
- 无 OpenGL 3.3 环境下的启动提示。

### 10.3 最小实机测试矩阵

| 类别 | 最低要求 |
| --- | --- |
| 平台 | Intel 平台 1 台、AMD 平台 1 台 |
| 系统 | Windows 10 22H2、Windows 11 最新正式版 |
| 磁盘 | SATA HDD、SATA SSD、NVMe SSD、USB 硬盘盒各至少 1 个 |
| GPU | 至少覆盖两家厂商；至少 1 台混合显卡笔记本 |
| 特殊场景 | 1 台开启 Intel RST/VMD 的设备（验证"未知"处理） |

GUI 自动化测试如采用 Dear ImGui Test Engine，必须先确认其许可证条款（与 Dear ImGui 本体许可不同）。

## 11. 开发阶段与交付标准

采用分阶段开发，不允许 AI 编程代理一次性生成整个项目后宣称完成。

| 阶段 | 开发内容 | 验收标准 |
| --- | --- | --- |
| P0 | 技术验证（见 16.1）、锁定依赖、项目骨架、CI | 16.1 全部检查项有结论；Windows x64 Debug/Release 编译通过；CI 运行；1.2.1 矩阵"待验证"项已回填 |
| P1 | GUI 基础框架、单实例、托盘、渲染节能 | 窗口、导航、主题、中文字体、DPI 正常；最小化后停止渲染 |
| P2 | Windows 系统信息、配置文件 | CPU、内存、SMBIOS 数据正常；配置读写与默认值正常 |
| P3 | 磁盘设备枚举、稳定设备 ID、插拔事件 | SATA/NVMe/USB 设备识别；重启后设备 ID 不变；热插拔恢复 |
| P4 | SMART 数据、电源状态保护、健康规则 | 对照 smartctl 逐项一致；休眠磁盘不被唤醒；规则表全部有单元测试 |
| P5 | 温度采集（磁盘、GPU 通用路线、扩展组件） | 各温度来源正确标注；扩展组件关闭时其他功能正常 |
| P6 | 历史数据库、降采样 | 数据保存、查询、清理、迁移、损坏恢复 |
| P7 | 告警中心、通知 | 阈值、持续时间、回差、抑制、通知、历史 |
| P8 | 设置完善、导入导出、诊断包、打包与签名 | 安装、卸载、升级、便携模式；代码签名 |
| P9 | 稳定性验证 | 按 10.3 矩阵完成长时间运行与实机测试 |

每个阶段必须提交：

- 完整源代码。
- 编译结果。
- 自动化测试结果。
- 已知问题。
- 下一阶段开发说明。

未完成验收的功能不能标记为已完成。没有在真实硬件上验证的功能必须标记为"模拟测试通过"或"尚未实机验证"。

## 12. 第一版 MVP 范围

第一版不追求所有硬件、所有传感器全部支持。

必须优先完成：

- Windows 10/11 x64。
- 深色 GUI、中文界面、托盘运行。
- 普通用户权限启动，按权限能力矩阵降级并提示原因。
- "以管理员身份重新启动"功能。
- CPU 使用率、计算频率和基本参数。
- 内存使用率和频率。
- GPU 型号、使用率、显存（厂商无关路线）；GPU 温度在技术验证可行时纳入。
- SATA HDD/SSD 识别、NVMe SSD 识别。
- SATA SMART 数据（管理员模式）、NVMe SMART 数据。
- 磁盘温度。
- 磁盘健康规则与告警。
- 历史记录（含降采样）。
- 设置页面。
- 便携版 EXE 发布。

可选（扩展组件，用户手动启用）：

- CPU 温度、功耗、真实频率。
- 主板传感器、风扇转速。

暂缓：

- 风扇控制。
- 电压调整。
- 超频。
- 磁盘压力测试。
- SMART 自检。
- 内核驱动开发。
- Windows Toast 通知（V1 使用托盘气泡通知）。
- 厂商 GPU SDK Provider。
- 云端同步。
- 远程监控。
- 自动更新。

## 13. 最终交付要求

最终软件应当具备：

1. 独立运行的 Windows EXE（便携版）及安装程序。
2. 完整硬件信息展示。
3. 多硬盘健康监控。
4. ATA/NVMe SMART 解析。
5. 温度历史曲线。
6. 告警和通知。
7. 本地数据库。
8. 配置导入导出。
9. 日志及故障诊断（含脱敏诊断包导出）。
10. 安装和卸载能力。

发布时必须提供：

- x64 Release 构建。
- 软件版本号（语义化版本）。
- **代码签名**（主程序、安装程序、辅助进程）。
- 主流杀毒软件误报检测结果。
- 依赖及许可证清单。
- 安装说明。
- 硬件兼容性说明与权限能力说明。
- 测试报告。
- SHA-256 文件校验值。

项目自身许可证必须在 P0 结束前确定。许可证选择会影响能否使用 GPL 类资源，以及与 MPL-2.0 组件的分发方式。

## 14. 给 AI 编程代理的强制开发规则

项目根目录必须创建 `AGENTS.md`，约束 Codex、Claude Code 等代理：

- 不得擅自更换 Zig、zgui、ImPlot 等技术栈，不得擅自升级 Zig 版本。
- 不得用模拟数据冒充真实硬件数据。
- 不得将暂不支持的硬件标记为正常。
- 不得将 SMART 原始值直接解释成统一健康百分比。
- 不得新增未在健康规则表中登记的健康判定逻辑。
- 不得跳过错误处理和资源释放。
- 不得把硬件采集、GUI、数据库耦合在一起。
- 不得一次性生成整个项目而不进行分阶段编译。
- 不得向磁盘发送任何写入、自检、固件或厂商私有命令。
- 不得引入网络访问代码。
- 不得复制 GPL 许可的代码或数据（如 smartmontools `drivedb.h`），除非项目许可证允许。
- 每个模块必须有对应测试。
- 每次修改必须验证 Windows x64 Release 构建。
- 第三方依赖必须锁定版本并记录许可证。
- 所有未实现功能必须明确标注，不允许虚构完成状态。
- 修改依赖前必须说明原因、兼容性影响和验证方式。
- 不得在没有实机或可靠设备数据验证的情况下声称硬件兼容。
- 所有破坏性操作必须经过用户明确确认。

### 14.1 每阶段完成报告模板

```text
阶段：
本阶段目标：

已完成：
- 

新增文件：
- 

修改文件：
- 

构建结果：
- Debug：
- Release：

测试结果：
- 自动化测试：
- 实机测试（设备型号 / 系统版本 / 权限）：

未完成事项：
- 

已知问题：
- 

下一阶段建议：
- 
```

## 15. 关键技术参考

开发代理必须优先参考官方文档和项目仓库：

1. [zgui 官方仓库](https://github.com/zig-gamedev/zgui)：GUI 绑定、构建方式和 ImPlot。
2. [Dear ImGui](https://github.com/ocornut/imgui)：即时模式图形界面。
3. [Microsoft NVMe 开发文档](https://learn.microsoft.com/en-us/windows/win32/fileio/working-with-nvme-devices)：NVMe SMART 和温度读取。
4. [IOCTL_STORAGE_QUERY_PROPERTY](https://learn.microsoft.com/en-us/windows/win32/api/winioctl/ni-winioctl-ioctl_storage_query_property)：Windows 存储设备查询接口。
5. [IOCTL_ATA_PASS_THROUGH](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/ntddscsi/ni-ntddscsi-ioctl_ata_pass_through)：ATA 命令透传。
6. [NVM Express 规范](https://nvmexpress.org/specifications/)：SMART/Health 日志页与 Identify 数据结构。
7. [T10 SAT 规范](https://www.t10.org/)：SCSI/ATA Translation（USB 桥接）。
8. [Performance Counters (PDH)](https://learn.microsoft.com/en-us/windows/win32/perfctrs/performance-counters-portal)：CPU/GPU 使用率。
9. [LibreHardwareMonitor](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor)：传感器兼容方案（扩展组件）。
10. [PawnIO](https://pawnio.eu/)：LibreHardwareMonitor 当前使用的驱动方案，需核实许可与分发条件。
11. [NVIDIA NVML](https://developer.nvidia.com/management-library-nvml)：NVIDIA GPU 监控接口。
12. [NVIDIA NVAPI](https://github.com/nvapi/nvapi)：NVIDIA 硬件接口。
13. [AMD ADLX](https://github.com/GPUOpen-LibrariesAndSDKs/ADLX)：AMD GPU 接口。
14. [Intel IGCL](https://github.com/intel/drivers.gpu.control-library)：Intel GPU 控制库。
15. [SQLite](https://www.sqlite.org/)：本地数据库。
16. [smartmontools](https://www.smartmontools.org/)：仅作为测试对照工具。

具体 API、SDK、依赖版本、许可和分发条件必须在开发时重新核实，以官方资料为准。

## 16. 项目实施建议

### 16.1 先进行技术验证（P0）

正式开发前，先建立一个最小技术验证项目，确认：

- 锁定的 Zig 版本与 zgui、Dear ImGui、ImPlot、GLFW、OpenGL 构建链兼容。
- Win32 绑定方案（zigwin32 或手写）可行，关键结构体布局通过 `comptime` 校验。
- TOML 解析方案可用。
- SQLite 可通过 build.zig 编译并读写。
- 中文字体加载正常（系统字体 + 回退字体）。
- Windows DPI 缩放正常。
- 实时曲线可以稳定刷新，静止时 CPU 占用符合 6.2。
- 托盘图标与隐藏消息窗口可与 GLFW 共存。
- 能枚举本机 SATA 和 NVMe 磁盘。
- 普通用户权限下：NVMe SMART、存储温度描述符、D3DKMT GPU 温度是否可读，结果回填 1.2.1。
- 管理员权限下：能读取至少一组真实 NVMe SMART 和 ATA SMART 数据，并与 smartctl 对照一致。
- ATA `CHECK POWER MODE` 可用，读取不会唤醒休眠磁盘。

技术验证不通过时，应先解决依赖或接口问题，不得直接进入大规模功能开发。

### 16.2 开发优先级

**第一优先级：磁盘健康监控。**

不仅显示绿色健康状态，还要展示 SMART 原始属性、标准化值、变化趋势、触发规则和异常记录，尤其关注 05、C5、C6、C7 等关键属性。

**第二优先级：温度采集兼容性。**

Windows 不同厂商的传感器接口存在差异。采用 Provider 架构，未来增加新的 CPU、GPU 和主板支持时，不需要重写整个软件。

**第三优先级：稳定性与低权限运行。**

第一版主程序不开发、不安装内核驱动，先使用 Windows 用户态 API 和厂商提供的接口；需要驱动的能力通过用户手动启用的扩展组件提供。这样能够降低系统兼容性、安全性和安装维护方面的风险。

---

## 17. 最终技术路线摘要

| 项目 | 方案 |
| --- | --- |
| 核心语言 | Zig（锁定版本） |
| GUI | zgui + Dear ImGui |
| 图表 | ImPlot |
| 窗口与渲染 | GLFW + OpenGL 3.3 Core，按需渲染 |
| 硬件接口 | Win32 API（用户态） |
| 磁盘协议 | ATA SMART / NVMe SMART / SAT |
| GPU 适配 | 厂商无关路线（PDH/DXGI/D3DKMT）+ 后续 NVIDIA / AMD / Intel Provider |
| 传感器兼容 | 可选 LibreHardwareMonitor 辅助进程（默认关闭） |
| 权限 | 普通用户启动，按能力矩阵降级，可选管理员模式 |
| 数据存储 | SQLite + 分级降采样 |
| 配置 | TOML |
| 网络 | 默认零网络访问 |
| 目标平台 | Windows 10 / 11 x64 |
| 部署 | 便携版 + 安装程序，代码签名 |

**项目目标：** 构建一款轻量、可靠、可扩展的 Windows 硬件温度与磁盘健康监控软件。以真实硬件数据为依据，以模块化采集和可验证的健康判定为核心，逐步完善多厂商硬件兼容性。

## 18. 术语表

| 术语 | 说明 |
| --- | --- |
| SMART | 硬盘自我监测、分析与报告技术 |
| Normalized / 当前值 | 厂商归一化后的属性值，通常越大越好 |
| Worst / 最差值 | 历史上出现过的最差归一化值 |
| Threshold / 阈值 | 归一化值低于或等于该值时视为失败 |
| Raw / 原始值 | 6 字节原始数据，编码因厂商而异 |
| Prefail | 预示即将失效的属性类型 |
| Old-age | 反映正常老化的属性类型 |
| SAT | SCSI/ATA Translation，USB 桥接透传 ATA 命令的标准方式 |
| WCTEMP / CCTEMP | NVMe 设备报告的警告 / 临界温度阈值 |
| APST | NVMe 自主电源状态转换 |
| Provider | 传感器数据提供程序，隔离不同数据来源 |
| 扩展组件 | 基于 LibreHardwareMonitor 的可选辅助进程，需管理员权限和驱动 |
| 基线 | 首次识别磁盘时记录的计数型属性值，用于判断增量 |

## 19. 待决事项

| 编号 | 事项 | 决定时机 | 状态 / 结论 |
| --- | --- | --- | --- |
| Q1 | Win32 绑定方案：zigwin32 或手写 | P0 | **已决定**：手写 `extern` 声明（`src/providers/windows/win32.zig`），全部关键结构体通过 `comptime` 校验 |
| Q2 | TOML 解析库选型 | P0 | **已决定**：项目自研零依赖 TOML 最小子集解析与序列化器（`src/utils/toml.zig`） |
| Q3 | 项目许可证 | P0 结束前 | **已决定**：主程序采用 **Apache-2.0**；可选的 LibreHardwareMonitor 辅助进程以独立进程隔离并遵循 **MPL-2.0** |
| Q4 | 普通用户权限下 NVMe SMART / 磁盘温度 / GPU 温度的实际可用性 | P0 实测 | **已实测（Win11）**：NVMe SMART（`access=0`）、NVMe 温度描述符（`access=0`）、D3DKMT & NVML GPU 温度均可用；已回填 §1.2.1（Win10 22H2 待补测） |
| Q5 | 内置回退中文字体的选择与体积 | P1 | **已决定（P1）**：优先加载 Windows 10/11 系统自带中文字体链（`msyh.ttc → simhei.ttf → simsun.ttc`），依托 ImGui 1.92 动态字形按需光栅化；全部不可用时回退 ImGui 默认字体并日志告警，避免增大单文件 EXE 体积 |
| Q6 | 安装包打包工具 | P8 前 | **已决定（P8）**：采用 **Inno Setup 6 (`iscc.exe`)** 构建用户级安装程序（`packaging/windows/installer.iss`，卸载时询问并默认保留用户数据），并同步产出内置 `portable.flag` 的便携版 ZIP |
| Q7 | 代码签名证书来源 | P8 前 | **已决定（P8）**：接入 Windows SDK `signtool.exe`（`packaging/windows/sign.ps1`，SHA-256 + RFC 3161 时间戳），正式发布支持注入商业 EV/OV PFX 或 Azure Trusted Signing / SignPath.io 证书；本地无商业证书时不伪造签名，明确标注未签名并提供 SHA-256 校验清单 |
| Q8 | PawnIO 驱动的许可与分发方式 | 启用扩展组件开发前 | **已决定（P8）**：采用独立隔离的 `WinHardwareMonitor.LhmHelper.exe`（`helpers/lhm_bridge/`，`LibreHardwareMonitorLib 0.9.4`，**MPL-2.0** 许可，只读且同用户命名管道通信）；安装包默认不勾选、**绝不自动静默安装第三方驱动**，文档明确指引需用户手动以管理员启动并按 LHM 官方说明自行安装 PawnIO 驱动 |
