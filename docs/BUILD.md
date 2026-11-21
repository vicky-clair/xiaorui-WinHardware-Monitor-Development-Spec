# 构建与打包指南（docs/BUILD.md）

## 1. 环境要求

- **操作系统**：Windows 10 (22H2+) / Windows 11 x64
- **Zig 编译器**：**锁定版本 `0.15.2`**（严禁擅自升级 Zig 版本）
- **Windows SDK**：手写 Win32 声明对照 Windows SDK `10.0.26100.0` 头文件编写，并在 `src/providers/windows/win32.zig` 中通过 `comptime` 校验全部关键结构体大小与字段偏移
- **可选（构建 LHM 辅助进程）**：.NET 8.0+ SDK
- **可选（编译 Windows 安装包）**：Inno Setup 6（`iscc.exe`）
- **可选（正式发布代码签名）**：Windows SDK `signtool.exe` 与有效 EV/OV 代码签名证书

## 2. 锁定依赖与许可证清单

- **主程序许可证**：`Apache-2.0`（见根目录 [LICENSE](../LICENSE)）
- **可选扩展组件许可证**：独立进程隔离在 `helpers/lhm_bridge/`，遵循 `MPL-2.0`

| 依赖 | 锁定版本 / 提交哈希 | 用途 | 许可证 |
| --- | --- | --- | --- |
| `zgui` | `f3ac2a45304eec6c291b74bee0b0a2bca80d06c5` | Dear ImGui 1.92 + ImPlot Zig 绑定与源码 | MIT |
| `zglfw` | `0dd29d8073487c9fe1e45e6b729b3aac271d5a71` | GLFW 3.4 Zig 绑定与源码 | MIT / zlib |
| `zopengl` | `db9d615c742086b39954eef064f957e92dafc7e2` | OpenGL 3.3 Core 函数加载器 | MIT |
| `sqlite3` | `3.53.2` (`sqlite-amalgamation-3530200.zip`) | 本地历史数据库（C amalgamation 静态编译） | Public Domain |
| `LibreHardwareMonitorLib` | `0.9.4`（仅限独立 `helpers/lhm_bridge/`） | 可选独立进程 CPU/主板只读传感器采集 | MPL-2.0 |

项目自研零依赖模块：
- `src/utils/toml.zig`：TOML 最小子集解析与序列化器（规范 Q2）
- `src/providers/windows/win32.zig`：手写 Win32 API 绑定与 `comptime` 结构体校验（规范 Q1）

## 3. 日常开发与测试命令

```powershell
# 运行全部自动化单元测试
zig build test

# Debug 构建（Windows x64，输出 zig-out\bin\winhardware-monitor.exe）
zig build

# ReleaseSafe 发布构建（推荐）
zig build -Doptimize=ReleaseSafe

# 运行 P0 硬件接口与权限验证工具
zig build verify-p0

# 运行 11 页 + 黑白双主题无人工冒烟测试
.\zig-out\bin\winhardware-monitor.exe --smoke-test
```

## 4. 构建可选 LHM 辅助进程与一键打包发布

```powershell
# 单独发布可选 MPL-2.0 LibreHardwareMonitor 辅助进程（单文件 WinExe）
dotnet publish helpers/lhm_bridge/WinHardwareMonitor.LhmHelper.csproj -c Release -r win-x64 -o zig-out/bin

# 一键执行：单元测试 + Debug/ReleaseSafe 构建 + LHM 发布 + 便携版 ZIP + Inno Setup 安装包 + SHA256SUMS.txt
powershell -NoProfile -ExecutionPolicy Bypass -File packaging/windows/build_release.ps1
```

打包输出统一生成在 `dist/` 目录（已加入 `.gitignore`，不提交至 Git 仓库）：
- `dist/WinHardwareMonitor-0.1.0-win64-setup.exe`（Inno Setup 6 安装程序）
- `dist/WinHardwareMonitor-0.1.0-win64-portable.zip`（含 `portable.flag` 的绿色便携版）
- `dist/SHA256SUMS.txt`（全部产物的 SHA-256 校验值）

## 5. 正式发布代码签名（Q7）

本地开发默认不伪造签名。正式对外发布前，配置商业代码签名证书环境变量后运行一键打包脚本即可自动调用 Windows SDK `signtool.exe` 完成 SHA-256 + RFC 3161 时间戳签名与校验：

```powershell
$env:WHM_SIGN_PFX = "C:\path\to\your-cert.pfx"
$env:WHM_SIGN_PFX_PASSWORD = "your-password"
# 或使用证书存储区指纹：$env:WHM_SIGN_THUMBPRINT = "..."
powershell -NoProfile -ExecutionPolicy Bypass -File packaging/windows/build_release.ps1
```

## 6. 升级依赖流程

遵循开发规范 §1.3：
1. 单独拉取分支，不与功能代码混在同一次提交。
2. 说明升级原因、兼容性影响与测试验证计划。
3. 验证 Windows x64 Debug、ReleaseSafe 构建及全部自动化测试通过。
4. 同步更新本文件与 `build.zig.zon` 后再合并。
