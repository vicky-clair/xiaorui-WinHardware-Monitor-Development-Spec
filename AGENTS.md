# AGENTS.md — WinHardware Monitor 开发强制规则

本文件面向所有 AI 编程代理（Codex、Claude Code、Antigravity 等）及协作者。所有开发必须严格遵守 [WinHardware-Monitor-Development-Spec.md](WinHardware-Monitor-Development-Spec.md)（当前版本 V1.1）。

## 1. 技术栈锁定（禁止擅自变更）

- **编程语言**：Zig `0.15.2`（锁定，不得擅自升级 Zig 版本）
- **GUI**：`zgui` + Dear ImGui + ImPlot（`glfw_opengl3` 后端）
- **窗口与渲染**：`zglfw` + OpenGL 3.3 Core（`zopengl`）
- **数据库**：SQLite（amalgamation C 源码经 `build.zig` 编译）
- **配置**：TOML（项目内自研最小子集解析与序列化器 `src/utils/toml.zig`）
- **Win32 绑定**：项目内手写 `extern` 声明（`src/providers/windows/win32.zig`），关键结构体必须包含 `comptime` `@sizeOf`/`@offsetOf` 校验
- **目标平台**：Windows 10 / Windows 11 x64

## 2. 红线规则（绝对禁止）

1. **不得用模拟数据冒充真实硬件数据。** 无法读取的传感器必须显示 `N/A` 并标明真实状态与原因。
2. **不得将暂不支持的硬件标记为"正常"。** 如 Intel RST/VMD、RAID、Storage Spaces、虚拟机磁盘等必须显示"未知"并说明原因。
3. **不得将 SMART 原始值直接解释成统一健康百分比。**
4. **不得新增未在规范 §2.5.5 健康规则表中登记的健康判定逻辑。**
5. **不得将 WMI `MSAcpi_ThermalZoneTemperature` 标注为 CPU 温度。**
6. **默认被动监控期间不得向磁盘发送写入、压测、自检、固件更新或 USB 桥接芯片厂商私有命令。** V2.0 经用户明确授权新增的「主动硬件测试与烤机」功能（CPU/内存/GPU 烤机、文件级磁盘读写测速、可选 SMART 自检）必须满足：
   - 仅在用户主动点击并**二次确认**后触发；
   - 磁盘测速**严禁直接写入裸物理磁盘扇区**，仅可在用户选定目录创建受控临时文件并于结束后自动删除；
   - 主动压测必须内置**实时高温自动熔断保护**（超温立即停机），且仍绝对禁止固件更新与 USB 桥接芯片厂商私有命令。
7. **不得引入网络访问代码（V1 默认零网络访问）。**
8. **不得复制 GPL 许可的代码或数据**（例如 smartmontools 的 `drivedb.h`），除非项目许可证明确允许。
9. **不得跳过错误处理和资源释放**（句柄、内存、线程、数据库连接必须有明确生命周期管理）。
10. **不得把硬件采集、GUI、数据库耦合在一起。** GUI 主线程不得执行阻塞式硬件查询。
11. **不得一次性生成整个项目而不进行分阶段编译与验收。**
12. **所有破坏性操作必须经过用户明确确认，不得破坏用户本地文件与数据。**

## 3. 构建、测试与依赖规则

- 每次修改必须验证 `zig build`（Debug）、`zig build -Doptimize=ReleaseSafe`（Release）以及 `zig build test` 在 Windows x64 上通过。
- 第三方依赖必须在 `build.zig.zon` 中锁定具体提交哈希或版本，并在 `docs/BUILD.md` 记录许可证。
- 修改依赖前必须说明原因、兼容性影响和验证方式。
- 未在真实硬件上验证的功能必须标注"模拟测试通过"或"尚未实机验证"，不得虚构兼容结论。
- 每个阶段结束必须按规范 §14.1 模板提交阶段完成报告。
