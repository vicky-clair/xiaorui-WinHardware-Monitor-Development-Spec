<#
.SYNOPSIS
    WinHardware Monitor P8 一键发布构建、打包与 SHA-256 生成脚本。
.DESCRIPTION
    1. 运行全部 Zig 单元测试与 ReleaseSafe Windows x64 编译；
    2. 发布独立的 MPL-2.0 LibreHardwareMonitor 辅助进程（WinHardwareMonitor.LhmHelper.exe）；
    3. 如配置了代码签名证书，则对主程序与辅助进程执行 Authenticode 签名；
    4. 打包便携版 ZIP（内置 portable.flag）与 Inno Setup 6 安装程序 EXE；
    5. 生成 dist/SHA256SUMS.txt 校验清单。
#>
[CmdletBinding()]
param(
    [string]$Version = "0.1.0",
    [string]$ZigExe = "C:\Users\xasr2\.version-fox\cache\zig\current\zig.exe",
    [switch]$SkipTests
)

$ErrorActionPreference = "Stop"
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
Set-Location $RepoRoot

if (-not (Test-Path $ZigExe)) {
    $zigCmd = Get-Command zig -ErrorAction SilentlyContinue
    if ($zigCmd) { $ZigExe = $zigCmd.Source } else { throw "未找到 Zig 0.15.2，请通过 -ZigExe 指定路径。" }
}

$distDir = Join-Path $RepoRoot "dist"
$stagePrefix = Join-Path $distDir "stage"
$stageBin = Join-Path $stagePrefix "bin"
New-Item -ItemType Directory -Force -Path $stageBin | Out-Null

Write-Host "=== [1/6] Zig 单元测试、Debug 校验与 ReleaseSafe x64 构建 ==="
if (-not $SkipTests) {
    & $ZigExe build test
    if ($LASTEXITCODE -ne 0) { throw "zig build test 失败" }
}
& $ZigExe build --prefix (Join-Path $distDir "stage-debug")
if ($LASTEXITCODE -ne 0) { throw "zig build (Debug) 失败" }
& $ZigExe build -Doptimize=ReleaseSafe --prefix $stagePrefix
if ($LASTEXITCODE -ne 0) { throw "zig build -Doptimize=ReleaseSafe 失败" }

Write-Host "=== [2/6] 发布可选 MPL-2.0 LibreHardwareMonitor 辅助进程 ==="
dotnet publish "helpers\lhm_bridge\WinHardwareMonitor.LhmHelper.csproj" -c Release -r win-x64 -o $stageBin
if ($LASTEXITCODE -ne 0) { throw "dotnet publish LhmHelper 失败" }

$mainExe = Join-Path $stageBin "winhardware-monitor.exe"
$helperExe = Join-Path $stageBin "WinHardwareMonitor.LhmHelper.exe"

# 若 zig-out\bin\winhardware-monitor.exe 未被占用，则顺带同步更新过去
try {
    New-Item -ItemType Directory -Force -Path (Join-Path $RepoRoot "zig-out\bin") | Out-Null
    Copy-Item $mainExe (Join-Path $RepoRoot "zig-out\bin\winhardware-monitor.exe") -Force -ErrorAction Stop
    Copy-Item $helperExe (Join-Path $RepoRoot "zig-out\bin\WinHardwareMonitor.LhmHelper.exe") -Force -ErrorAction Stop
} catch {
    Write-Warning "zig-out\bin 下的旧 EXE 正在运行占用，已保留运行中实例；最新产物位于 dist\stage\bin 与 dist\ 发布包。"
}

Write-Host "=== [3/6] 代码签名（若已配置证书） ==="
& (Join-Path $PSScriptRoot "sign.ps1") -Files @($mainExe, $helperExe)

Write-Host "=== [4/6] 组装便携版目录与 ZIP ==="
$portableStage = Join-Path $distDir "WinHardwareMonitor-$Version-win64-portable"
$portableZip = Join-Path $distDir "WinHardwareMonitor-$Version-win64-portable.zip"
New-Item -ItemType Directory -Force -Path $distDir | Out-Null
if (Test-Path $portableStage) { Remove-Item -Recurse -Force $portableStage }
if (Test-Path $portableZip) { Remove-Item -Force $portableZip }

New-Item -ItemType Directory -Force -Path `
    $portableStage, `
    (Join-Path $portableStage "config"), `
    (Join-Path $portableStage "data"), `
    (Join-Path $portableStage "docs"), `
    (Join-Path $portableStage "helpers\lhm_bridge") | Out-Null

Copy-Item $mainExe $portableStage
Copy-Item $helperExe $portableStage
Set-Content -Path (Join-Path $portableStage "portable.flag") -Value "# Presence of this file enables portable mode (config/data/logs stored beside EXE)." -Encoding UTF8
Copy-Item "config\default.toml" (Join-Path $portableStage "config\")
Copy-Item "data\drive_attributes.toml" (Join-Path $portableStage "data\")
Copy-Item "LICENSE", "README.md", "CHANGELOG.md" $portableStage
Copy-Item "docs\*.md" (Join-Path $portableStage "docs\")
Copy-Item "helpers\lhm_bridge\LICENSE-MPL-2.0.txt", "helpers\lhm_bridge\README.md" (Join-Path $portableStage "helpers\lhm_bridge\")

Compress-Archive -Path (Join-Path $portableStage "*") -DestinationPath $portableZip -CompressionLevel Optimal

Write-Host "=== [5/6] 编译 Inno Setup 6 安装程序 ==="
$iscc = Get-Command iscc.exe -ErrorAction SilentlyContinue
if (-not $iscc) {
    $isccItem = Get-Item "C:\Program Files (x86)\Inno Setup 6\ISCC.exe","C:\Program Files\Inno Setup 6\ISCC.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($isccItem) { $isccPath = $isccItem.FullName } else { $isccPath = $null }
} else {
    $isccPath = $iscc.Source
}

$setupExe = Join-Path $distDir "WinHardwareMonitor-$Version-win64-setup.exe"
if ($isccPath) {
    & $isccPath "/DBinDir=$stageBin" (Join-Path $PSScriptRoot "installer.iss")
    if ($LASTEXITCODE -ne 0) { throw "ISCC 编译安装程序失败" }
    & (Join-Path $PSScriptRoot "sign.ps1") -Files @($setupExe)
} else {
    Write-Warning "未找到 ISCC.exe（Inno Setup 6），跳过安装程序编译。"
}

Write-Host "=== [6/6] 生成 SHA-256 校验清单 ==="
$artifacts = @($mainExe, $helperExe, $portableZip)
if (Test-Path $setupExe) { $artifacts += $setupExe }

$lines = foreach ($item in $artifacts) {
    $h = Get-FileHash -Path $item -Algorithm SHA256
    "$($h.Hash.ToLowerInvariant())  $(Split-Path -Leaf $item)"
}
$shaFile = Join-Path $distDir "SHA256SUMS.txt"
Set-Content -Path $shaFile -Value $lines -Encoding ASCII

Write-Host "`n=== 发布产物汇总 ($distDir) ==="
Get-Content $shaFile
