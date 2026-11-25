# 构建与打包指南（docs/BUILD.md）

## 1. 环境要求

### Windows x64 构建环境
- **操作系统**：Windows 10 (22H2+) / Windows 11 x64
- **Zig 编译器**：**严格锁定版本 `0.15.2`**（严禁擅自升级 Zig 版本）
- **Windows SDK**：手写 Win32 声明对照 Windows SDK `10.0.26100.0` 头文件编写，并在 `src/providers/windows/win32.zig` 中通过 `comptime` 校验全部关键结构体大小与字段偏移
- **可选（构建 LHM 辅助进程）**：.NET 8.0+ SDK
- **可选（编译 Windows 安装包）**：Inno Setup 6（`iscc.exe`）
- **可选（正式发布代码签名）**：Windows SDK `signtool.exe` 与有效 EV/OV 代码签名证书

### Linux x86_64 构建环境
- **操作系统**：任意主流 x86_64 发行版（已在 Debian 13 `trixie` / Linux `6.12` 实机验证）
- **Zig 编译器**：**锁定版本 `0.15.2`**
- **系统开发库（编译 GUI + OpenGL 依赖）**：
  - Debian / Ubuntu：
    ```bash
    sudo apt-get install -y libx11-dev libxrandr-dev libxinerama-dev libxcursor-dev libxi-dev libgl-dev rpm
    ```
  - Fedora / RHEL / Rocky / AlmaLinux：
    ```bash
    sudo dnf install -y libX11-devel libXrandr-devel libXinerama-devel libXcursor-devel libXi-devel mesa-libGL-devel rpm-build
    ```
- **跨平台行尾规范**：根目录 `.gitattributes` 已锁定 `*.sh`、`*.spec`、`*.desktop` 为 `LF`，防止在 Windows 上克隆后同步到 Linux 执行脚本时出现 `\r` 报错。

---

## 2. 锁定依赖与许可证清单

- **主程序许可证**：`Apache-2.0`（见根目录 [LICENSE](../LICENSE)）
- **可选 Windows 扩展组件许可证**：独立进程隔离在 `helpers/lhm_bridge/`，遵循 `MPL-2.0`

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
- `src/core/i18n.zig`：零依赖中/英/日三语国际化路由

---

## 3. 日常开发、测试与 CLI 调试命令

### Windows PowerShell
```powershell
# 1. 运行全部自动化单元测试（含健康规则、TOML、SQLite、V2.2 测试引擎与 Win32 开机自启校验）
zig build test

# 2. Debug 构建（输出至 zig-out\bin\winhardware-monitor.exe）
zig build

# 3. ReleaseSafe 通用发布构建（强制 -Dcpu=baseline 兼容所有 64 位 Win10/Win11 处理器，避免旧 CPU 非法指令闪退）
zig build -Doptimize=ReleaseSafe -Dcpu=baseline

# 4. 运行 11 页面 × 3 语言 × 黑白双主题无人工冒烟测试
.\zig-out\bin\winhardware-monitor.exe --smoke-test

# 5. 运行 P0 硬件接口与权限验证工具
zig build verify-p0

# 6. 直接从命令行运行 V2.2 无界面体检或单项基准测试
.\zig-out\bin\winhardware-monitor.exe --cli --lang zh
.\zig-out\bin\winhardware-monitor.exe --bench cpu --duration 10
.\zig-out\bin\winhardware-monitor.exe --bench mem --mem-mb 128
.\zig-out\bin\winhardware-monitor.exe --bench disk --disk-mb 64 --disk-dir D:\Temp
.\zig-out\bin\winhardware-monitor.exe --bench all --duration 15 --mem-mb 128 --disk-mb 64 --cutoff-c 90
```

### Linux Bash
```bash
# 运行全部单元测试与 ReleaseSafe 通用发布构建（锁定 GLIBC 2.17 + x86-64 baseline）
zig build test
zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-gnu.2.17 -Dcpu=baseline

# 无界面 CLI 硬件信息采集与 V2.2 基准测试（支持 --lang zh|en|ja）
./zig-out/bin/winhardware-monitor --cli --lang zh
sudo ./zig-out/bin/winhardware-monitor --cli --lang en
./zig-out/bin/winhardware-monitor --bench all --duration 10 --mem-mb 128 --disk-mb 64 --cutoff-c 90
```

---

## 4. 一键打包发布

### A. Windows 打包（便携版 ZIP + Inno Setup 安装包）
```powershell
# 单独构建可选 MPL-2.0 LibreHardwareMonitor 辅助进程（基于 Win10/11 原生内置 .NET Framework 4.8，无需用户安装 .NET 8）
dotnet build helpers/lhm_bridge/WinHardwareMonitor.LhmHelper.csproj -c Release -o zig-out/bin

# 一键执行：单元测试 + Debug/ReleaseSafe (-Dcpu=baseline) 构建 + LHM 构建 + 便携版 ZIP + Inno Setup 安装包 + SHA256SUMS.txt
powershell -NoProfile -ExecutionPolicy Bypass -File packaging/windows/build_release.ps1
```
默认输出至 `dist/`（已加入 `.gitignore`，不提交至 Git 仓库）：
- `dist/WinHardwareMonitor-0.1.0-win64-setup.exe`（Inno Setup 6 安装程序，支持可选开机自启与可选 LHM 辅助进程）
- `dist/WinHardwareMonitor-0.1.0-win64-portable.zip`（含 `portable.flag` 的绿色便携版）
- `dist/SHA256SUMS.txt`（全部产物的 SHA-256 校验值）

### B. Linux 多格式打包（`.tar.gz` / `.deb` / `.rpm`）
```bash
# 一键执行：单元测试 + ReleaseSafe 构建 + 产出 .tar.gz / .deb / .rpm + SHA256SUMS.txt
ZIG_BIN=zig ./packaging/linux/build_linux_packages.sh
```
默认输出至 `dist-linux/`（已加入 `.gitignore`，不提交至 Git 仓库）：
- `dist-linux/winhardware-monitor-0.1.0-linux-x86_64.tar.gz`（免安装便携压缩包）
- `dist-linux/winhardware-monitor_0.1.0_amd64.deb`（Debian / Ubuntu / Mint 安装包）
- `dist-linux/winhardware-monitor-0.1.0-1.x86_64.rpm`（Fedora / RHEL / CentOS / Rocky / openSUSE 安装包）
- `dist-linux/SHA256SUMS.txt`

---

## 5. 正式发布代码签名（Q7）

本地开发默认不伪造签名。正式对外发布前，配置商业代码签名证书环境变量后运行一键打包脚本即可自动调用 Windows SDK `signtool.exe` 完成 SHA-256 + RFC 3161 时间戳签名与校验：

```powershell
$env:WHM_SIGN_PFX = "C:\path\to\your-cert.pfx"
$env:WHM_SIGN_PFX_PASSWORD = "your-password"
# 或使用证书存储区指纹：$env:WHM_SIGN_THUMBPRINT = "..."
powershell -NoProfile -ExecutionPolicy Bypass -File packaging/windows/build_release.ps1
```

---

## 6. 升级依赖流程

遵循开发规范 §1.3：
1. 单独拉取分支，不与功能代码混在同一次提交。
2. 说明升级原因、兼容性影响与测试验证计划。
3. 验证 Windows x64（及 Linux x86_64）Debug、ReleaseSafe 构建及全部自动化测试通过。
4. 同步更新本文件与 `build.zig.zon` 后再合并。
