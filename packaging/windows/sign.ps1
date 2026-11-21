<#
.SYNOPSIS
    WinHardware Monitor 代码签名脚本（规范 §13 / Q7）。
.DESCRIPTION
    自动查找 Windows SDK signtool.exe，对主程序、可选 LHM 辅助进程和安装程序执行 Authenticode SHA-256 + RFC 3161 时间戳签名。
    支持商业 PFX 证书、证书存储区 SHA-1 指纹，或明确跳过（无证书时不伪造签名）。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string[]]$Files,

    [string]$CertPath = $env:WHM_SIGN_PFX,
    [string]$CertPassword = $env:WHM_SIGN_PFX_PASSWORD,
    [string]$CertThumbprint = $env:WHM_SIGN_THUMBPRINT,
    [string]$TimestampUrl = "http://timestamp.digicert.com"
)

$ErrorActionPreference = "Stop"

function Find-SignTool {
    $cmd = Get-Command signtool.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $kit = Get-ChildItem "C:\Program Files (x86)\Windows Kits\10\bin\*\x64\signtool.exe" -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending | Select-Object -First 1
    if ($kit) { return $kit.FullName }
    return $null
}

$signTool = Find-SignTool
if (-not $signTool) {
    Write-Warning "[SIGN] 未找到 signtool.exe，已跳过代码签名（发布前请在装有 Windows SDK 的环境中执行签名）。"
    exit 0
}

if (-not $CertPath -and -not $CertThumbprint) {
    Write-Warning "[SIGN] 未提供商业代码签名证书（WHM_SIGN_PFX / WHM_SIGN_THUMBPRINT），已保持未签名状态（严禁伪造签名结论）。"
    exit 0
}

foreach ($f in $Files) {
    if (-not (Test-Path $f)) {
        Write-Warning "[SIGN] 跳过不存在的文件: $f"
        continue
    }
    $argsList = @("sign", "/fd", "SHA256", "/tr", $TimestampUrl, "/td", "SHA256")
    if ($CertPath) {
        $argsList += @("/f", $CertPath)
        if ($CertPassword) { $argsList += @("/p", $CertPassword) }
    } else {
        $argsList += @("/sha1", $CertThumbprint)
    }
    $argsList += $f

    Write-Host "[SIGN] Signing $f ..."
    & $signTool @argsList
    if ($LASTEXITCODE -ne 0) {
        throw "signtool failed for $f (exit $LASTEXITCODE)"
    }
    & $signTool verify /pa /v $f
    if ($LASTEXITCODE -ne 0) {
        throw "signtool verify failed for $f (exit $LASTEXITCODE)"
    }
}

Write-Host "[SIGN] 全部目标已完成 Authenticode SHA-256 签名与校验。"
