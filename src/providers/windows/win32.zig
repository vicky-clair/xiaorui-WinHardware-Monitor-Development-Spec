const std = @import("std");
const builtin = @import("builtin");

/// 项目内手写 Win32 API 绑定（规范 §1.1 / Q1）。
/// 所有结构体布局均依据 Windows SDK 10.0.26100.0 头文件编写，并在文件底部使用 comptime 断言校验。
/// 非 Windows 平台下仅保留跨平台共用枚举/数据结构定义，Win32 API 符号不会被引用。

pub const HANDLE = if (builtin.os.tag == .windows) std.os.windows.HANDLE else *anyopaque;
pub const HWND = if (builtin.os.tag == .windows) std.os.windows.HWND else *opaque {};
pub const HINSTANCE = if (builtin.os.tag == .windows) std.os.windows.HINSTANCE else *opaque {};
pub const HMODULE = if (builtin.os.tag == .windows) std.os.windows.HMODULE else *opaque {};
pub const HICON = *opaque {};
pub const HCURSOR = *opaque {};
pub const HBRUSH = *opaque {};
pub const HMENU = *opaque {};
pub const ATOM = u16;
pub const BOOL = if (builtin.os.tag == .windows) std.os.windows.BOOL else i32;
pub const DWORD = u32;
pub const WORD = u16;
pub const BYTE = u8;
pub const LONG = i32;
pub const ULONG = u32;
pub const UINT = u32;
pub const SHORT = i16;
pub const USHORT = u16;
pub const NTSTATUS = i32;
pub const WPARAM = usize;
pub const LPARAM = isize;
pub const LRESULT = isize;
pub const LPCWSTR = [*:0]const u16;
pub const LPWSTR = [*:0]u16;
pub const LPCSTR = [*:0]const u8;
pub const LPVOID = ?*anyopaque;
pub const LPCVOID = ?*const anyopaque;

pub const INVALID_HANDLE_VALUE: HANDLE = if (builtin.os.tag == .windows) std.os.windows.INVALID_HANDLE_VALUE else @ptrFromInt(std.math.maxInt(usize));
pub const GENERIC_READ: DWORD = 0x80000000;
pub const GENERIC_WRITE: DWORD = 0x40000000;
pub const FILE_SHARE_READ: DWORD = 0x00000001;
pub const FILE_SHARE_WRITE: DWORD = 0x00000002;
pub const OPEN_EXISTING: DWORD = 3;

// Storage IOCTLs (winioctl.h / ntddscsi.h)
pub const IOCTL_STORAGE_QUERY_PROPERTY: DWORD = 0x002D1400;
pub const IOCTL_DISK_GET_LENGTH_INFO: DWORD = 0x0007405C;
pub const IOCTL_DISK_GET_DRIVE_GEOMETRY_EX: DWORD = 0x000700A0;
pub const IOCTL_ATA_PASS_THROUGH: DWORD = 0x0004D02C;
pub const IOCTL_SCSI_PASS_THROUGH: DWORD = 0x0004D004;
pub const IOCTL_SCSI_PASS_THROUGH_DIRECT: DWORD = 0x0004D014;
pub const SMART_RCV_DRIVE_DATA: DWORD = 0x0007C088;

pub const SCSI_IOCTL_DATA_OUT: BYTE = 0;
pub const SCSI_IOCTL_DATA_IN: BYTE = 1;
pub const SCSI_IOCTL_DATA_UNSPECIFIED: BYTE = 2;

/// SCSI_PASS_THROUGH_DIRECT (ntddscsi.h, x64 layout, 56 bytes)
pub const SCSI_PASS_THROUGH_DIRECT = extern struct {
    Length: WORD = @sizeOf(SCSI_PASS_THROUGH_DIRECT),
    ScsiStatus: BYTE = 0,
    PathId: BYTE = 0,
    TargetId: BYTE = 0,
    Lun: BYTE = 0,
    CdbLength: BYTE = 0,
    SenseInfoLength: BYTE = 0,
    DataIn: BYTE = 0,
    _pad0: [3]BYTE = .{ 0, 0, 0 },
    DataTransferLength: ULONG = 0,
    TimeOutValue: ULONG = 0,
    _pad1: DWORD = 0,
    DataBuffer: LPVOID = null,
    SenseInfoOffset: ULONG = 0,
    Cdb: [16]BYTE = std.mem.zeroes([16]BYTE),
};

/// SYSTEM_POWER_STATUS (winbase.h)
pub const SYSTEM_POWER_STATUS = extern struct {
    ACLineStatus: BYTE = 255, // 0=Offline, 1=Online, 255=Unknown
    BatteryFlag: BYTE = 255, // 128=No system battery, 255=Unknown
    BatteryLifePercent: BYTE = 255, // 0..100, 255=Unknown
    SystemStatusFlag: BYTE = 0,
    BatteryLifeTime: DWORD = 0xFFFFFFFF,
    BatteryFullLifeTime: DWORD = 0xFFFFFFFF,
};

/// SYSTEM_PROCESSOR_PERFORMANCE_INFORMATION (winternl.h, 48 bytes)
pub const SYSTEM_PROCESSOR_PERFORMANCE_INFORMATION = extern struct {
    IdleTime: i64 = 0,
    KernelTime: i64 = 0,
    UserTime: i64 = 0,
    DpcTime: i64 = 0,
    InterruptTime: i64 = 0,
    InterruptCount: ULONG = 0,
    _pad: ULONG = 0,
};
pub const SystemProcessorPerformanceInformation: ULONG = 8;

pub const GET_LENGTH_INFORMATION = extern struct {
    Length: i64 = 0,
};

pub const DISK_GEOMETRY = extern struct {
    Cylinders: i64 = 0,
    MediaType: DWORD = 0,
    TracksPerCylinder: DWORD = 0,
    SectorsPerTrack: DWORD = 0,
    BytesPerSector: DWORD = 0,
};

pub const DISK_GEOMETRY_EX = extern struct {
    Geometry: DISK_GEOMETRY = .{},
    DiskSize: i64 = 0,
    Data: [1]BYTE = .{0},
};

// STORAGE_PROPERTY_ID (winioctl.h)
pub const StorageDeviceProperty: DWORD = 0;
pub const StorageAdapterProperty: DWORD = 1;
pub const StorageAdapterProtocolSpecificProperty: DWORD = 49;
pub const StorageDeviceProtocolSpecificProperty: DWORD = 50;
pub const StorageAdapterTemperatureProperty: DWORD = 51;
pub const StorageDeviceTemperatureProperty: DWORD = 52;

// STORAGE_QUERY_TYPE
pub const PropertyStandardQuery: DWORD = 0;
pub const PropertyExistsQuery: DWORD = 1;

// STORAGE_PROTOCOL_TYPE
pub const ProtocolTypeUnknown: DWORD = 0;
pub const ProtocolTypeScsi: DWORD = 1;
pub const ProtocolTypeAta: DWORD = 2;
pub const ProtocolTypeNvme: DWORD = 3;

// STORAGE_PROTOCOL_NVME_DATA_TYPE
pub const NVMeDataTypeUnknown: DWORD = 0;
pub const NVMeDataTypeIdentify: DWORD = 1;
pub const NVMeDataTypeLogPage: DWORD = 2;
pub const NVMeDataTypeFeature: DWORD = 3;

// NVMe Log Page IDs & Identify CNS
pub const NVME_LOG_PAGE_ERROR_INFO: DWORD = 0x01;
pub const NVME_LOG_PAGE_HEALTH_INFO: DWORD = 0x02;
pub const NVME_IDENTIFY_CNS_CONTROLLER: DWORD = 0x01;

// STORAGE_BUS_TYPE
pub const STORAGE_BUS_TYPE = enum(u32) {
    unknown = 0,
    scsi = 1,
    atapi = 2,
    ata = 3,
    ieee1394 = 4,
    ssa = 5,
    fibre = 6,
    usb = 7,
    raid = 8,
    iscsi = 9,
    sas = 10,
    sata = 11,
    sd = 12,
    mmc = 13,
    virtual = 14,
    file_backed_virtual = 15,
    spaces = 16,
    nvme = 17,
    scm = 18,
    ufs = 19,
    _,

    pub fn name(self: STORAGE_BUS_TYPE) []const u8 {
        return switch (self) {
            .sata => "SATA",
            .ata => "ATA",
            .nvme => "NVMe",
            .usb => "USB",
            .scsi => "SCSI",
            .sas => "SAS",
            .raid => "RAID",
            .spaces => "StorageSpaces",
            .virtual, .file_backed_virtual => "Virtual",
            else => "Other",
        };
    }
};

pub const STORAGE_TEMPERATURE_VALUE_NOT_REPORTED: i16 = -32768; // 0x8000

pub const STORAGE_PROPERTY_QUERY = extern struct {
    PropertyId: DWORD,
    QueryType: DWORD,
    AdditionalParameters: [1]BYTE = .{0},
};

pub const STORAGE_DEVICE_DESCRIPTOR = extern struct {
    Version: DWORD,
    Size: DWORD,
    DeviceType: BYTE,
    DeviceTypeModifier: BYTE,
    RemovableMedia: BYTE,
    CommandQueueing: BYTE,
    VendorIdOffset: DWORD,
    ProductIdOffset: DWORD,
    ProductRevisionOffset: DWORD,
    SerialNumberOffset: DWORD,
    BusType: DWORD,
    RawPropertiesLength: DWORD,
    RawDeviceProperties: [1]BYTE,
};

pub const STORAGE_PROTOCOL_SPECIFIC_DATA = extern struct {
    ProtocolType: DWORD,
    DataType: DWORD,
    ProtocolDataRequestValue: DWORD,
    ProtocolDataRequestSubValue: DWORD,
    ProtocolDataOffset: DWORD,
    ProtocolDataLength: DWORD,
    FixedProtocolReturnData: DWORD,
    ProtocolDataRequestSubValue2: DWORD,
    ProtocolDataRequestSubValue3: DWORD,
    ProtocolDataRequestSubValue4: DWORD,
};

pub const STORAGE_PROTOCOL_DATA_DESCRIPTOR = extern struct {
    Version: DWORD,
    Size: DWORD,
    ProtocolSpecificData: STORAGE_PROTOCOL_SPECIFIC_DATA,
};

pub const STORAGE_TEMPERATURE_INFO = extern struct {
    Index: WORD,
    Temperature: SHORT,
    OverThreshold: SHORT,
    UnderThreshold: SHORT,
    OverThresholdChangable: BYTE,
    UnderThresholdChangable: BYTE,
    EventGenerated: BYTE,
    Reserved0: BYTE,
    Reserved1: DWORD,
};

pub const STORAGE_TEMPERATURE_DATA_DESCRIPTOR = extern struct {
    Version: DWORD,
    Size: DWORD,
    CriticalTemperature: SHORT,
    WarningTemperature: SHORT,
    InfoCount: WORD,
    Reserved0: [2]BYTE,
    Reserved1: [2]DWORD,
    TemperatureInfo: [1]STORAGE_TEMPERATURE_INFO,
};

/// NVMe Log Page 02h (SMART / Health Information), exact 512-byte layout (nvme.h)
pub const NVME_HEALTH_INFO_LOG = extern struct {
    CriticalWarning: u8,
    Temperature: [2]u8, // Composite Temperature in Kelvin (little-endian u16)
    AvailableSpare: u8,
    AvailableSpareThreshold: u8,
    PercentageUsed: u8,
    Reserved0: [26]u8,
    DataUnitRead: [16]u8,
    DataUnitWritten: [16]u8,
    HostReadCommands: [16]u8,
    HostWrittenCommands: [16]u8,
    ControllerBusyTime: [16]u8,
    PowerCycle: [16]u8,
    PowerOnHours: [16]u8,
    UnsafeShutdowns: [16]u8,
    MediaErrors: [16]u8,
    ErrorInfoLogEntryCount: [16]u8,
    WarningCompositeTemperatureTime: u32,
    CriticalCompositeTemperatureTime: u32,
    TemperatureSensor: [8]u16,
    Reserved1: [296]u8,

    pub fn compositeTempKelvin(self: *const NVME_HEALTH_INFO_LOG) u16 {
        return std.mem.readInt(u16, &self.Temperature, .little);
    }

    pub fn compositeTempCelsius(self: *const NVME_HEALTH_INFO_LOG) i32 {
        return @as(i32, self.compositeTempKelvin()) - 273;
    }

    pub fn readU128(bytes: [16]u8) u128 {
        return std.mem.readInt(u128, &bytes, .little);
    }
};

/// ATA_PASS_THROUGH_EX (ntddscsi.h, x64 layout)
pub const ATA_FLAGS_DRDY_REQUIRED: WORD = 1 << 0;
pub const ATA_FLAGS_DATA_IN: WORD = 1 << 1;
pub const ATA_FLAGS_DATA_OUT: WORD = 1 << 2;
pub const ATA_FLAGS_48BIT_COMMAND: WORD = 1 << 3;

pub const ATA_PASS_THROUGH_EX = extern struct {
    Length: WORD,
    AtaFlags: WORD,
    PathId: BYTE,
    TargetId: BYTE,
    Lun: BYTE,
    ReservedAsUchar: BYTE,
    DataTransferLength: ULONG,
    TimeOutValue: ULONG,
    ReservedAsUlong: ULONG,
    DataBufferOffset: usize,
    PreviousTaskFile: [8]BYTE,
    CurrentTaskFile: [8]BYTE,
};

// D3DKMT structs (d3dkmthk.h, Windows SDK 10.0.26100.0)
pub const LUID = extern struct {
    LowPart: DWORD,
    HighPart: LONG,
};

pub const D3DKMT_HANDLE = UINT;
pub const KMTQAITYPE_ADAPTERPERFDATA: UINT = 62;
pub const KMTQAITYPE_ADAPTERPERFDATACAPS: UINT = 63;

pub const D3DKMT_ADAPTERINFO = extern struct {
    hAdapter: D3DKMT_HANDLE,
    AdapterLuid: LUID,
    NumOfSources: ULONG,
    bPrecisePresentRegionsPreferred: BOOL,
};

pub const D3DKMT_ENUMADAPTERS2 = extern struct {
    NumAdapters: ULONG,
    pAdapters: ?[*]D3DKMT_ADAPTERINFO,
};

pub const D3DKMT_QUERYADAPTERINFO = extern struct {
    hAdapter: D3DKMT_HANDLE,
    Type: UINT,
    pPrivateDriverData: LPVOID,
    PrivateDriverDataSize: UINT,
};

pub const D3DKMT_ADAPTER_PERFDATA = extern struct {
    PhysicalAdapterIndex: u32,
    MemoryFrequency: u64 align(8),
    MaxMemoryFrequency: u64 align(8),
    MaxMemoryFrequencyOC: u64 align(8),
    MemoryBandwidth: u64 align(8),
    PCIEBandwidth: u64 align(8),
    FanRPM: ULONG,
    Power: ULONG, // tenths of a percentage
    Temperature: ULONG, // deci-Celsius (1 = 0.1°C)
    PowerStateOverride: u8,
};

pub const D3DKMT_ADAPTER_PERFDATACAPS = extern struct {
    PhysicalAdapterIndex: u32,
    MaxMemoryBandwidth: u64 align(8),
    MaxPCIEBandwidth: u64 align(8),
    MaxFanRPM: ULONG,
    TemperatureMax: ULONG,
    TemperatureWarning: ULONG,
};

pub const D3DKMT_CLOSEADAPTER = extern struct {
    hAdapter: D3DKMT_HANDLE,
};

// System Info structs
pub const MEMORYSTATUSEX = extern struct {
    dwLength: DWORD = @sizeOf(MEMORYSTATUSEX),
    dwMemoryLoad: DWORD = 0,
    ullTotalPhys: u64 = 0,
    ullAvailPhys: u64 = 0,
    ullTotalPageFile: u64 = 0,
    ullAvailPageFile: u64 = 0,
    ullTotalVirtual: u64 = 0,
    ullAvailVirtual: u64 = 0,
    ullAvailExtendedVirtual: u64 = 0,
};

pub const FILETIME = extern struct {
    dwLowDateTime: DWORD,
    dwHighDateTime: DWORD,

    pub fn toU64(self: FILETIME) u64 {
        return (@as(u64, self.dwHighDateTime) << 32) | @as(u64, self.dwLowDateTime);
    }
};

pub const SYSTEM_INFO = extern struct {
    wProcessorArchitecture: WORD = 0,
    wReserved: WORD = 0,
    dwPageSize: DWORD = 0,
    lpMinimumApplicationAddress: LPVOID = null,
    lpMaximumApplicationAddress: LPVOID = null,
    dwActiveProcessorMask: usize = 0,
    dwNumberOfProcessors: DWORD = 0,
    dwProcessorType: DWORD = 0,
    dwAllocationGranularity: DWORD = 0,
    wProcessorLevel: WORD = 0,
    wProcessorRevision: WORD = 0,
};

// Registry constants
pub const HKEY = *opaque {};
pub const HKEY_CURRENT_USER: HKEY = @ptrFromInt(0x80000001);
pub const HKEY_LOCAL_MACHINE: HKEY = @ptrFromInt(0x80000002);
pub const KEY_READ: DWORD = 0x20019;
pub const KEY_SET_VALUE: DWORD = 0x0002;
pub const KEY_WRITE: DWORD = 0x20006;
pub const REG_SZ: DWORD = 1;
pub const REG_DWORD: DWORD = 4;

// SMBIOS firmware table provider ('RSMB' little-endian = 0x52534D42)
pub const RSMB_SIGNATURE: DWORD = 0x52534D42;

// PDH (Performance Data Helper) types & constants
pub const PDH_HQUERY = ?*anyopaque;
pub const PDH_HCOUNTER = ?*anyopaque;
pub const PDH_STATUS = i32;
pub const PDH_FMT_DOUBLE: DWORD = 0x00000200;
pub const PDH_FMT_NOCAP100: DWORD = 0x00008000;

pub const PDH_FMT_COUNTERVALUE = extern struct {
    CStatus: DWORD = 0,
    _pad: DWORD = 0,
    doubleValue: f64 = 0.0,
};

// Token elevation check
pub const TOKEN_QUERY: DWORD = 0x0008;
pub const TokenElevation: DWORD = 20;
pub const TOKEN_ELEVATION = extern struct {
    TokenIsElevated: DWORD,
};

// Tray & Hidden Message Window structs
pub const HWND_MESSAGE: ?HWND = @ptrFromInt(@as(usize, @bitCast(@as(isize, -3))));
pub const WM_USER: UINT = 0x0400;
pub const WM_APP: UINT = 0x8000;
pub const WM_CLOSE: UINT = 0x0010;
pub const WM_DESTROY: UINT = 0x0002;
pub const WM_COMMAND: UINT = 0x0111;
pub const WM_DEVICECHANGE: UINT = 0x0219;
pub const WM_POWERBROADCAST: UINT = 0x0218;
pub const WM_LBUTTONUP: UINT = 0x0202;
pub const WM_LBUTTONDBLCLK: UINT = 0x0203;
pub const WM_RBUTTONUP: UINT = 0x0205;
pub const WM_CONTEXTMENU: UINT = 0x007B;

pub const PBT_APMSUSPEND: WPARAM = 0x0004;
pub const PBT_APMRESUMEAUTOMATIC: WPARAM = 0x0012;
pub const PBT_APMRESUMESUSPEND: WPARAM = 0x0007;
pub const PBT_POWERSETTINGCHANGE: WPARAM = 0x8013;

pub const ERROR_ALREADY_EXISTS: DWORD = 183;
pub const SW_HIDE: i32 = 0;
pub const SW_SHOWNORMAL: i32 = 1;
pub const SW_SHOW: i32 = 5;
pub const SW_RESTORE: i32 = 9;
pub const PM_REMOVE: UINT = 0x0001;

pub const MF_STRING: UINT = 0x00000000;
pub const MF_SEPARATOR: UINT = 0x00000800;
pub const MF_CHECKED: UINT = 0x00000008;
pub const TPM_RIGHTBUTTON: UINT = 0x0002;
pub const TPM_RETURNCMD: UINT = 0x0100;
pub const TPM_NONOTIFY: UINT = 0x0080;

pub const DWMWA_USE_IMMERSIVE_DARK_MODE: DWORD = 20;

pub const POINT = extern struct {
    x: LONG = 0,
    y: LONG = 0,
};

pub const MSG = extern struct {
    hwnd: ?HWND = null,
    message: UINT = 0,
    wParam: WPARAM = 0,
    lParam: LPARAM = 0,
    time: DWORD = 0,
    pt: POINT = .{},
};

pub const NIM_ADD: DWORD = 0x00000000;
pub const NIM_MODIFY: DWORD = 0x00000001;
pub const NIM_DELETE: DWORD = 0x00000002;
pub const NIF_MESSAGE: UINT = 0x00000001;
pub const NIF_ICON: UINT = 0x00000002;
pub const NIF_TIP: UINT = 0x00000004;
pub const NIF_INFO: UINT = 0x00000010;
pub const NIIF_INFO: DWORD = 0x00000001;
pub const NIIF_WARNING: DWORD = 0x00000002;
pub const NIIF_ERROR: DWORD = 0x00000003;
pub const IDI_APPLICATION: LPCWSTR = @ptrFromInt(32512);

pub const GUID = extern struct {
    Data1: u32 = 0,
    Data2: u16 = 0,
    Data3: u16 = 0,
    Data4: [8]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
};

pub const NOTIFYICONDATAW = extern struct {
    cbSize: DWORD = @sizeOf(NOTIFYICONDATAW),
    hWnd: ?HWND = null,
    uID: UINT = 0,
    uFlags: UINT = 0,
    uCallbackMessage: UINT = 0,
    hIcon: ?HICON = null,
    szTip: [128]u16 = std.mem.zeroes([128]u16),
    dwState: DWORD = 0,
    dwStateMask: DWORD = 0,
    szInfo: [256]u16 = std.mem.zeroes([256]u16),
    uTimeoutOrVersion: UINT = 0,
    szInfoTitle: [64]u16 = std.mem.zeroes([64]u16),
    dwInfoFlags: DWORD = 0,
    guidItem: GUID = .{},
    hBalloonIcon: ?HICON = null,
};

pub const WNDPROC = *const fn (HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT;

pub const WNDCLASSEXW = extern struct {
    cbSize: UINT = @sizeOf(WNDCLASSEXW),
    style: UINT = 0,
    lpfnWndProc: WNDPROC,
    cbClsExtra: i32 = 0,
    cbWndExtra: i32 = 0,
    hInstance: ?HINSTANCE = null,
    hIcon: ?HICON = null,
    hCursor: ?HCURSOR = null,
    hbrBackground: ?HBRUSH = null,
    lpszMenuName: ?LPCWSTR = null,
    lpszClassName: LPCWSTR,
    hIconSm: ?HICON = null,
};

// External Win32 functions
pub extern "kernel32" fn CreateFileW(
    lpFileName: LPCWSTR,
    dwDesiredAccess: DWORD,
    dwShareMode: DWORD,
    lpSecurityAttributes: LPVOID,
    dwCreationDisposition: DWORD,
    dwFlagsAndAttributes: DWORD,
    hTemplateFile: ?HANDLE,
) callconv(.winapi) HANDLE;

pub extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn ReadFile(
    hFile: HANDLE,
    lpBuffer: LPVOID,
    nNumberOfBytesToRead: DWORD,
    lpNumberOfBytesRead: ?*DWORD,
    lpOverlapped: LPVOID,
) callconv(.winapi) BOOL;
pub extern "kernel32" fn WriteFile(
    hFile: HANDLE,
    lpBuffer: LPCVOID,
    nNumberOfBytesToWrite: DWORD,
    lpNumberOfBytesWritten: ?*DWORD,
    lpOverlapped: LPVOID,
) callconv(.winapi) BOOL;
pub extern "kernel32" fn WaitNamedPipeW(
    lpNamedPipeName: LPCWSTR,
    nTimeOut: DWORD,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn DeviceIoControl(
    hDevice: HANDLE,
    dwIoControlCode: DWORD,
    lpInBuffer: LPCVOID,
    nInBufferSize: DWORD,
    lpOutBuffer: LPVOID,
    nOutBufferSize: DWORD,
    lpBytesReturned: ?*DWORD,
    lpOverlapped: LPVOID,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;
pub extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
pub extern "kernel32" fn GlobalMemoryStatusEx(lpBuffer: *MEMORYSTATUSEX) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetSystemTimes(
    lpIdleTime: ?*FILETIME,
    lpKernelTime: ?*FILETIME,
    lpUserTime: ?*FILETIME,
) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetCurrentProcess() callconv(.winapi) HANDLE;
pub extern "kernel32" fn GetModuleHandleW(lpModuleName: ?LPCWSTR) callconv(.winapi) ?HMODULE;
pub extern "kernel32" fn LoadLibraryW(lpLibFileName: LPCWSTR) callconv(.winapi) ?HMODULE;
pub extern "kernel32" fn FreeLibrary(hLibModule: HMODULE) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetProcAddress(hModule: HMODULE, lpProcName: LPCSTR) callconv(.winapi) ?*anyopaque;

pub extern "advapi32" fn OpenProcessToken(
    ProcessHandle: HANDLE,
    DesiredAccess: DWORD,
    TokenHandle: *HANDLE,
) callconv(.winapi) BOOL;

pub extern "advapi32" fn GetTokenInformation(
    TokenHandle: HANDLE,
    TokenInformationClass: DWORD,
    TokenInformation: LPVOID,
    TokenInformationLength: DWORD,
    ReturnLength: *DWORD,
) callconv(.winapi) BOOL;

pub extern "gdi32" fn D3DKMTEnumAdapters2(pData: *D3DKMT_ENUMADAPTERS2) callconv(.winapi) NTSTATUS;
pub extern "gdi32" fn D3DKMTQueryAdapterInfo(pData: *D3DKMT_QUERYADAPTERINFO) callconv(.winapi) NTSTATUS;
pub extern "gdi32" fn D3DKMTCloseAdapter(pData: *const D3DKMT_CLOSEADAPTER) callconv(.winapi) NTSTATUS;

pub extern "user32" fn RegisterClassExW(lpWndClass: *const WNDCLASSEXW) callconv(.winapi) ATOM;
pub extern "user32" fn UnregisterClassW(lpClassName: LPCWSTR, hInstance: ?HINSTANCE) callconv(.winapi) BOOL;
pub extern "user32" fn CreateWindowExW(
    dwExStyle: DWORD,
    lpClassName: LPCWSTR,
    lpWindowName: LPCWSTR,
    dwStyle: DWORD,
    X: i32,
    Y: i32,
    nWidth: i32,
    nHeight: i32,
    hWndParent: ?HWND,
    hMenu: ?HMENU,
    hInstance: ?HINSTANCE,
    lpParam: LPVOID,
) callconv(.winapi) ?HWND;
pub extern "user32" fn DestroyWindow(hWnd: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn DefWindowProcW(hWnd: HWND, Msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT;
pub extern "user32" fn LoadIconW(hInstance: ?HINSTANCE, lpIconName: LPCWSTR) callconv(.winapi) ?HICON;
pub extern "user32" fn MessageBoxW(hWnd: ?HWND, lpText: LPCWSTR, lpCaption: LPCWSTR, uType: UINT) callconv(.winapi) i32;
pub extern "user32" fn FindWindowW(lpClassName: ?LPCWSTR, lpWindowName: ?LPCWSTR) callconv(.winapi) ?HWND;
pub extern "user32" fn ShowWindow(hWnd: HWND, nCmdShow: i32) callconv(.winapi) BOOL;
pub extern "user32" fn SetForegroundWindow(hWnd: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn IsIconic(hWnd: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn RegisterWindowMessageW(lpString: LPCWSTR) callconv(.winapi) UINT;
pub extern "user32" fn PeekMessageW(lpMsg: *MSG, hWnd: ?HWND, wMsgFilterMin: UINT, wMsgFilterMax: UINT, wRemoveMsg: UINT) callconv(.winapi) BOOL;
pub extern "user32" fn TranslateMessage(lpMsg: *const MSG) callconv(.winapi) BOOL;
pub extern "user32" fn DispatchMessageW(lpMsg: *const MSG) callconv(.winapi) LRESULT;
pub extern "user32" fn PostMessageW(hWnd: ?HWND, Msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) BOOL;
pub extern "user32" fn CreatePopupMenu() callconv(.winapi) ?HMENU;
pub extern "user32" fn AppendMenuW(hMenu: HMENU, uFlags: UINT, uIDNewItem: usize, lpNewItem: ?LPCWSTR) callconv(.winapi) BOOL;
pub extern "user32" fn TrackPopupMenu(hMenu: HMENU, uFlags: UINT, x: i32, y: i32, nReserved: i32, hWnd: HWND, prcRect: ?*const anyopaque) callconv(.winapi) BOOL;
pub extern "user32" fn DestroyMenu(hMenu: HMENU) callconv(.winapi) BOOL;
pub extern "user32" fn GetCursorPos(lpPoint: *POINT) callconv(.winapi) BOOL;
pub extern "user32" fn SetWindowLongPtrW(hWnd: HWND, nIndex: i32, dwNewLong: isize) callconv(.winapi) isize;
pub extern "user32" fn GetWindowLongPtrW(hWnd: HWND, nIndex: i32) callconv(.winapi) isize;
pub const GWLP_USERDATA: i32 = -21;

pub extern "kernel32" fn CreateMutexW(lpMutexAttributes: LPVOID, bInitialOwner: BOOL, lpName: ?LPCWSTR) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn ReleaseMutex(hMutex: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetModuleFileNameW(hModule: ?HMODULE, lpFilename: LPWSTR, nSize: DWORD) callconv(.winapi) DWORD;
pub extern "kernel32" fn GetSystemInfo(lpSystemInfo: *SYSTEM_INFO) callconv(.winapi) void;
pub extern "kernel32" fn GetSystemPowerStatus(lpSystemPowerStatus: *SYSTEM_POWER_STATUS) callconv(.winapi) BOOL;
pub extern "ntdll" fn NtQuerySystemInformation(
    SystemInformationClass: ULONG,
    SystemInformation: LPVOID,
    SystemInformationLength: ULONG,
    ReturnLength: ?*ULONG,
) callconv(.winapi) NTSTATUS;
pub extern "kernel32" fn GetSystemFirmwareTable(
    FirmwareTableProviderSignature: DWORD,
    FirmwareTableID: DWORD,
    pFirmwareTableBuffer: LPVOID,
    BufferSize: DWORD,
) callconv(.winapi) UINT;
pub extern "kernel32" fn GetEnvironmentVariableW(
    lpName: LPCWSTR,
    lpBuffer: ?LPWSTR,
    nSize: DWORD,
) callconv(.winapi) DWORD;

pub extern "advapi32" fn RegOpenKeyExW(
    hKey: HKEY,
    lpSubKey: LPCWSTR,
    ulOptions: DWORD,
    samDesired: DWORD,
    phkResult: *HKEY,
) callconv(.winapi) LONG;
pub extern "advapi32" fn RegQueryValueExW(
    hKey: HKEY,
    lpValueName: ?LPCWSTR,
    lpReserved: ?*DWORD,
    lpType: ?*DWORD,
    lpData: ?[*]BYTE,
    lpcbData: ?*DWORD,
) callconv(.winapi) LONG;
pub extern "advapi32" fn RegCloseKey(hKey: HKEY) callconv(.winapi) LONG;
pub extern "advapi32" fn RegCreateKeyExW(
    hKey: HKEY,
    lpSubKey: LPCWSTR,
    Reserved: DWORD,
    lpClass: ?LPWSTR,
    dwOptions: DWORD,
    samDesired: DWORD,
    lpSecurityAttributes: LPVOID,
    phkResult: *HKEY,
    lpdwDisposition: ?*DWORD,
) callconv(.winapi) LONG;
pub extern "advapi32" fn RegSetValueExW(
    hKey: HKEY,
    lpValueName: ?LPCWSTR,
    Reserved: DWORD,
    dwType: DWORD,
    lpData: [*]const BYTE,
    cbData: DWORD,
) callconv(.winapi) LONG;
pub extern "advapi32" fn RegDeleteValueW(
    hKey: HKEY,
    lpValueName: ?LPCWSTR,
) callconv(.winapi) LONG;

pub extern "pdh" fn PdhOpenQueryW(szDataSource: ?LPCWSTR, dwUserData: usize, phQuery: *PDH_HQUERY) callconv(.winapi) PDH_STATUS;
pub extern "pdh" fn PdhAddEnglishCounterW(hQuery: PDH_HQUERY, szFullCounterPath: LPCWSTR, dwUserData: usize, phCounter: *PDH_HCOUNTER) callconv(.winapi) PDH_STATUS;
pub extern "pdh" fn PdhCollectQueryData(hQuery: PDH_HQUERY) callconv(.winapi) PDH_STATUS;
pub extern "pdh" fn PdhGetFormattedCounterValue(hCounter: PDH_HCOUNTER, dwFormat: DWORD, lpdwType: ?*DWORD, pValue: *PDH_FMT_COUNTERVALUE) callconv(.winapi) PDH_STATUS;
pub extern "pdh" fn PdhCloseQuery(hQuery: PDH_HQUERY) callconv(.winapi) PDH_STATUS;

pub extern "shell32" fn Shell_NotifyIconW(dwMessage: DWORD, lpData: *NOTIFYICONDATAW) callconv(.winapi) BOOL;
pub extern "shell32" fn ShellExecuteW(
    hwnd: ?HWND,
    lpOperation: ?LPCWSTR,
    lpFile: LPCWSTR,
    lpParameters: ?LPCWSTR,
    lpDirectory: ?LPCWSTR,
    nShowCmd: i32,
) callconv(.winapi) ?HINSTANCE;

pub extern "dwmapi" fn DwmSetWindowAttribute(
    hwnd: HWND,
    dwAttribute: DWORD,
    pvAttribute: *const anyopaque,
    cbAttribute: DWORD,
) callconv(.winapi) i32;

pub extern "ole32" fn CoInitializeEx(pvReserved: LPVOID, dwCoInit: DWORD) callconv(.winapi) i32;
pub extern "ole32" fn CoUninitialize() callconv(.winapi) void;
pub const COINIT_APARTMENTTHREADED: DWORD = 0x2;

/// 检测当前进程是否具有管理员 / root 权限
pub fn isElevated() bool {
    if (builtin.os.tag != .windows) {
        return std.os.linux.geteuid() == 0;
    }
    var token: HANDLE = undefined;
    if (OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token) == 0) return false;
    defer _ = CloseHandle(token);

    var elev: TOKEN_ELEVATION = .{ .TokenIsElevated = 0 };
    var ret_len: DWORD = 0;
    if (GetTokenInformation(token, TokenElevation, &elev, @sizeOf(TOKEN_ELEVATION), &ret_len) == 0) {
        return false;
    }
    return elev.TokenIsElevated != 0;
}

// ============================================================================
// Comptime struct layout assertions verified against Windows SDK 10.0.26100.0
// ============================================================================
comptime {
    std.debug.assert(@sizeOf(STORAGE_PROPERTY_QUERY) == 12);
    std.debug.assert(@offsetOf(STORAGE_PROPERTY_QUERY, "AdditionalParameters") == 8);

    std.debug.assert(@sizeOf(STORAGE_PROTOCOL_SPECIFIC_DATA) == 40);
    std.debug.assert(@offsetOf(STORAGE_PROTOCOL_SPECIFIC_DATA, "ProtocolDataOffset") == 16);
    std.debug.assert(@offsetOf(STORAGE_PROTOCOL_SPECIFIC_DATA, "ProtocolDataLength") == 20);

    std.debug.assert(@sizeOf(STORAGE_PROTOCOL_DATA_DESCRIPTOR) == 48);
    std.debug.assert(@offsetOf(STORAGE_PROTOCOL_DATA_DESCRIPTOR, "ProtocolSpecificData") == 8);

    std.debug.assert(@sizeOf(STORAGE_TEMPERATURE_INFO) == 16);
    std.debug.assert(@offsetOf(STORAGE_TEMPERATURE_INFO, "Temperature") == 2);
    std.debug.assert(@offsetOf(STORAGE_TEMPERATURE_INFO, "OverThreshold") == 4);

    std.debug.assert(@sizeOf(STORAGE_TEMPERATURE_DATA_DESCRIPTOR) == 40);
    std.debug.assert(@offsetOf(STORAGE_TEMPERATURE_DATA_DESCRIPTOR, "CriticalTemperature") == 8);
    std.debug.assert(@offsetOf(STORAGE_TEMPERATURE_DATA_DESCRIPTOR, "WarningTemperature") == 10);
    std.debug.assert(@offsetOf(STORAGE_TEMPERATURE_DATA_DESCRIPTOR, "InfoCount") == 12);
    std.debug.assert(@offsetOf(STORAGE_TEMPERATURE_DATA_DESCRIPTOR, "TemperatureInfo") == 24);

    std.debug.assert(@sizeOf(NVME_HEALTH_INFO_LOG) == 512);
    std.debug.assert(@offsetOf(NVME_HEALTH_INFO_LOG, "Temperature") == 1);
    std.debug.assert(@offsetOf(NVME_HEALTH_INFO_LOG, "AvailableSpare") == 3);
    std.debug.assert(@offsetOf(NVME_HEALTH_INFO_LOG, "PercentageUsed") == 5);
    std.debug.assert(@offsetOf(NVME_HEALTH_INFO_LOG, "DataUnitRead") == 32);
    std.debug.assert(@offsetOf(NVME_HEALTH_INFO_LOG, "MediaErrors") == 160);
    std.debug.assert(@offsetOf(NVME_HEALTH_INFO_LOG, "WarningCompositeTemperatureTime") == 192);
    std.debug.assert(@offsetOf(NVME_HEALTH_INFO_LOG, "TemperatureSensor") == 200);

    // x64 ATA_PASS_THROUGH_EX
    std.debug.assert(@sizeOf(ATA_PASS_THROUGH_EX) == 48);
    std.debug.assert(@offsetOf(ATA_PASS_THROUGH_EX, "DataBufferOffset") == 24);
    std.debug.assert(@offsetOf(ATA_PASS_THROUGH_EX, "PreviousTaskFile") == 32);
    std.debug.assert(@offsetOf(ATA_PASS_THROUGH_EX, "CurrentTaskFile") == 40);

    // D3DKMT x64
    std.debug.assert(@sizeOf(D3DKMT_ADAPTERINFO) == 20);
    std.debug.assert(@sizeOf(D3DKMT_ADAPTER_PERFDATA) == 64);
    std.debug.assert(@offsetOf(D3DKMT_ADAPTER_PERFDATA, "MemoryFrequency") == 8);
    std.debug.assert(@offsetOf(D3DKMT_ADAPTER_PERFDATA, "FanRPM") == 48);
    std.debug.assert(@offsetOf(D3DKMT_ADAPTER_PERFDATA, "Power") == 52);
    std.debug.assert(@offsetOf(D3DKMT_ADAPTER_PERFDATA, "Temperature") == 56);
    std.debug.assert(@sizeOf(D3DKMT_QUERYADAPTERINFO) == 24);
    std.debug.assert(@sizeOf(NOTIFYICONDATAW) == 976);
    std.debug.assert(@sizeOf(PDH_FMT_COUNTERVALUE) == 16);
    std.debug.assert(@sizeOf(SCSI_PASS_THROUGH_DIRECT) == 56);
    std.debug.assert(@offsetOf(SCSI_PASS_THROUGH_DIRECT, "DataBuffer") == 24);
    std.debug.assert(@offsetOf(SCSI_PASS_THROUGH_DIRECT, "Cdb") == 36);
    std.debug.assert(@sizeOf(SYSTEM_PROCESSOR_PERFORMANCE_INFORMATION) == 48);
    std.debug.assert(@offsetOf(PDH_FMT_COUNTERVALUE, "doubleValue") == 8);
}

test "Win32 comptime struct layouts and NVMe health parser helpers" {
    var log = std.mem.zeroes(NVME_HEALTH_INFO_LOG);
    // 310 K = 37 C
    std.mem.writeInt(u16, &log.Temperature, 310, .little);
    try std.testing.expectEqual(@as(i32, 37), log.compositeTempCelsius());

    std.mem.writeInt(u128, &log.DataUnitWritten, 123456789012345, .little);
    try std.testing.expectEqual(@as(u128, 123456789012345), NVME_HEALTH_INFO_LOG.readU128(log.DataUnitWritten));
}
