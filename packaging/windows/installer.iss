; WinHardware Monitor — Inno Setup 6 安装程序脚本（P8 / Q6 已定型）
; 特点：
; 1. 默认用户级安装（无需管理员权限，PrivilegesRequired=lowest）；
; 2. 可选 MPL-2.0 LibreHardwareMonitor 辅助进程作为独立组件默认不勾选（严格遵守规范 §1.2 / §9 #8，绝不自动安装第三方驱动）；
; 3. 卸载时明确询问并默认保留 %LOCALAPPDATA%\WinHardwareMonitor 下的配置、历史数据库与日志（规范 §5.1）。

[Setup]
AppId={{8D62A1B4-4F1E-4A98-9D37-4B8F7E31A5C2}
AppName=WinHardware Monitor
AppVersion=0.1.0
AppVerName=WinHardware Monitor 0.1.0
AppPublisher=WinHardware Monitor Contributors
DefaultDirName={localappdata}\Programs\WinHardwareMonitor
DefaultGroupName=WinHardware Monitor
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\..\dist
OutputBaseFilename=WinHardwareMonitor-0.1.0-win64-setup
Compression=lzma2/ultra64
SolidCompression=yes
LicenseFile=..\..\LICENSE
WizardStyle=modern
DisableProgramGroupPage=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Types]
Name: "standard"; Description: "标准安装（仅核心监控，零内核驱动，推荐）"
Name: "full"; Description: "完整安装（含可选 MPL-2.0 硬件扩展辅助进程）"
Name: "custom"; Description: "自定义安装"; Flags: iscustom

[Components]
Name: "core"; Description: "核心监控程序（Apache-2.0，零内核驱动）"; Types: standard full custom; Flags: fixed
Name: "lhm_helper"; Description: "可选扩展组件：LibreHardwareMonitor 辅助进程（MPL-2.0，独立进程，用于 CPU/主板温度，需用户手动启动）"; Types: full

#ifndef BinDir
  #define BinDir "..\..\zig-out\bin"
#endif

[Files]
Source: "{#BinDir}\winhardware-monitor.exe"; DestDir: "{app}"; Components: core; Flags: ignoreversion
Source: "..\..\config\default.toml"; DestDir: "{app}\config"; Components: core; Flags: ignoreversion
Source: "..\..\data\drive_attributes.toml"; DestDir: "{app}\data"; Components: core; Flags: ignoreversion
Source: "..\..\LICENSE"; DestDir: "{app}"; Components: core; Flags: ignoreversion
Source: "..\..\README.md"; DestDir: "{app}"; Components: core; Flags: ignoreversion
Source: "..\..\CHANGELOG.md"; DestDir: "{app}"; Components: core; Flags: ignoreversion
Source: "..\..\docs\BUILD.md"; DestDir: "{app}\docs"; Components: core; Flags: ignoreversion
Source: "..\..\docs\ARCHITECTURE.md"; DestDir: "{app}\docs"; Components: core; Flags: ignoreversion
Source: "..\..\docs\PERMISSIONS.md"; DestDir: "{app}\docs"; Components: core; Flags: ignoreversion
Source: "..\..\docs\HARDWARE_SUPPORT.md"; DestDir: "{app}\docs"; Components: core; Flags: ignoreversion
Source: "..\..\docs\RELEASE_NOTES_v0.1.0.md"; DestDir: "{app}\docs"; Components: core; Flags: ignoreversion

; 可选 MPL-2.0 独立辅助进程（默认不勾选，与 Apache-2.0 主程序严格进程隔离）
Source: "{#BinDir}\WinHardwareMonitor.LhmHelper.exe"; DestDir: "{app}"; Components: lhm_helper; Flags: ignoreversion
Source: "..\..\helpers\lhm_bridge\LICENSE-MPL-2.0.txt"; DestDir: "{app}\helpers\lhm_bridge"; Components: lhm_helper; Flags: ignoreversion
Source: "..\..\helpers\lhm_bridge\README.md"; DestDir: "{app}\helpers\lhm_bridge"; Components: lhm_helper; Flags: ignoreversion

[Icons]
Name: "{group}\WinHardware Monitor"; Filename: "{app}\winhardware-monitor.exe"
Name: "{autodesktop}\WinHardware Monitor"; Filename: "{app}\winhardware-monitor.exe"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "附加任务:"; Flags: unchecked

[Run]
Filename: "{app}\winhardware-monitor.exe"; Description: "启动 WinHardware Monitor"; Flags: nowait postinstall skipifsilent

[Code]
// 规范 §5.1：卸载时明确询问是否删除本地配置/数据库/日志，默认保留
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  DataDir: String;
begin
  if CurUninstallStep = usPostUninstall then
  begin
    DataDir := ExpandConstant('{localappdata}\WinHardwareMonitor');
    if DirExists(DataDir) then
    begin
      if MsgBox('是否同时删除本地配置文件、历史数据库和日志？' + #13#10 + DataDir + #13#10 + '（点击“否”保留数据，便于后续重装或升级）', mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES then
      begin
        DelTree(DataDir, True, True, True);
      end;
    end;
  end;
end;
