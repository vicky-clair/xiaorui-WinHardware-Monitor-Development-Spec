// WinHardware Monitor — 可选独立隔离的 LibreHardwareMonitor 硬件传感器辅助进程
// 许可证：Mozilla Public License 2.0 (MPL-2.0)，与主程序 Apache-2.0 严格进程隔离
// 安全边界：严格只读、零网络访问、禁用磁盘/GPU采集、仅限本机同用户命名管道 IPC (v1)

using System.Buffers.Binary;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using LibreHardwareMonitor.Hardware;

namespace WinHardwareMonitor.LhmHelper;

/// 单条硬件传感器快照项（保留原始硬件名与传感器名，不强行归类）
internal sealed record HelperSensorItem(
    [property: JsonPropertyName("hardware")] string Hardware,
    [property: JsonPropertyName("name")] string Name,
    [property: JsonPropertyName("sensor_type")] string SensorType,
    [property: JsonPropertyName("value")] double Value,
    [property: JsonPropertyName("unit")] string Unit
);

/// 命名管道 v1 协议快照响应体
internal sealed record HelperSnapshotResponse(
    [property: JsonPropertyName("version")] uint Version,
    [property: JsonPropertyName("is_admin")] bool IsAdmin,
    [property: JsonPropertyName("sensors")] List<HelperSensorItem> Sensors
);

/// 递归刷新硬件节点与子硬件节点的只读访问器
internal sealed class UpdateVisitor : IVisitor
{
    public void VisitComputer(IComputer computer) => computer.Traverse(this);

    public void VisitHardware(IHardware hardware)
    {
        try
        {
            hardware.Update();
            foreach (var sub in hardware.SubHardware)
            {
                sub.Accept(this);
            }
        }
        catch
        {
            // 忽略单个传感器节点采集异常，确保其余硬件数据不受影响
        }
    }

    public void VisitSensor(ISensor sensor) { }
    public void VisitParameter(IParameter parameter) { }
}

internal static class Program
{
    private const string PipeName = "WinHardwareMonitor_LhmBridge_v1";
    private const string MutexName = "Local\\WinHardwareMonitor_LhmHelper_v1";
    private const uint ProtocolVersion = 1;
    private const int MaxRequestBytes = 64 * 1024;
    private const int MaxResponseBytes = 1024 * 1024; // 1 MB hard cap (Spec §9 #10)
    private const int MaxSensors = 64;

    private static readonly JsonSerializerOptions JsonOpts = new()
    {
        WriteIndented = false,
    };

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int MessageBoxW(IntPtr hWnd, string lpText, string lpCaption, uint uType);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool ConvertStringSecurityDescriptorToSecurityDescriptorW(
        string stringSecurityDescriptor,
        uint stringSDRevision,
        out IntPtr securityDescriptor,
        out uint securityDescriptorSize);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool GetSecurityDescriptorSacl(
        IntPtr pSecurityDescriptor,
        out bool lpbSaclPresent,
        out IntPtr pSacl,
        out bool lpbSaclDefaulted);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern uint SetSecurityInfo(
        SafeHandle handle,
        int objectType,
        uint securityInfo,
        IntPtr psidOwner,
        IntPtr psidGroup,
        IntPtr pDacl,
        IntPtr pSacl);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr LocalFree(IntPtr hMem);

    private const int SE_KERNEL_OBJECT = 6;
    private const uint LABEL_SECURITY_INFORMATION = 0x00000010;
    private const uint SDDL_REVISION_1 = 1;

    [STAThread]
    private static int Main(string[] args)
    {
        bool selfTest = args.Any(a => string.Equals(a, "--self-test", StringComparison.OrdinalIgnoreCase));
        bool fromHost = args.Any(a => string.Equals(a, "--from-host", StringComparison.OrdinalIgnoreCase));
        bool isAdmin = IsCurrentProcessElevated();

        if (selfTest)
        {
            using var probe = CreateReadOnlyComputer();
            var snap = CollectSnapshot(probe, isAdmin);
            string json = JsonSerializer.Serialize(snap, JsonOpts);
            Console.WriteLine(json);
            return 0;
        }

        using var mutex = new Mutex(true, MutexName, out bool createdNew);
        if (!createdNew)
        {
            if (!fromHost)
            {
                MessageBoxW(
                    IntPtr.Zero,
                    "WinHardwareMonitor.LhmHelper 已在后台运行中。\n\n本程序为无界面后台传感器辅助进程，请直接打开主程序 winhardware-monitor.exe 查看 CPU 与主板传感器数据。",
                    "WinHardware Monitor 扩展辅助进程",
                    0x00000040);
            }
            return 0;
        }

        using var computer = CreateReadOnlyComputer();
        var cts = new CancellationTokenSource();
        AppDomain.CurrentDomain.ProcessExit += (_, _) => cts.Cancel();

        // 若用户直接双击运行（非主程序通过 --from-host 启动），在独立线程弹出友好说明，不阻塞命名管道监听
        if (!fromHost)
        {
            string roleHint = isAdmin
                ? "当前权限：管理员（可完整读取 CPU 温度与主板传感器）。"
                : "当前权限：普通用户（部分 CPU/主板传感器可能需要以管理员身份启动或在主程序内点击“启动 LHM 辅助进程”）。";
            var uiNoticeThread = new Thread(() =>
            {
                MessageBoxW(
                    IntPtr.Zero,
                    "WinHardwareMonitor.LhmHelper 是 WinHardware Monitor 的后台传感器辅助进程（无独立主界面），现已在后台就绪。\n\n" +
                    roleHint + "\n\n请打开主程序 winhardware-monitor.exe，在「系统设置」或「主板与传感器」页面启用扩展组件即可查看数据。",
                    "WinHardware Monitor 扩展辅助进程（已在后台运行）",
                    0x00000040);
            })
            {
                IsBackground = true,
            };
            uiNoticeThread.Start();
        }

        try
        {
            while (!cts.IsCancellationRequested)
            {
                using var server = CreateSameUserMediumIntegrityPipe();
                server.WaitForConnection();

                bool shouldExit = HandleClientSession(server, computer, isAdmin);
                if (shouldExit)
                {
                    break;
                }
            }
        }
        catch (OperationCanceledException)
        {
            // Clean shutdown
        }
        catch
        {
            // Do not crash with unhandled dialog
        }

        return 0;
    }

    /// <summary>
    /// 创建仅允许当前登录用户（SID）连接、且允许同用户的普通权限（Medium Integrity）主程序
    /// 连接管理员权限（High Integrity）辅助进程的本地命名管道（规范 §9 第 10 条）。
    /// 拒绝网络访问、其他用户与低完整性沙盒进程。
    /// </summary>
    private static NamedPipeServerStream CreateSameUserMediumIntegrityPipe()
    {
        var pipeSec = new PipeSecurity();
        var currentUserSid = WindowsIdentity.GetCurrent().User;
        if (currentUserSid != null)
        {
            pipeSec.AddAccessRule(new PipeAccessRule(
                currentUserSid,
                PipeAccessRights.ReadWrite | PipeAccessRights.CreateNewInstance,
                AccessControlType.Allow));
        }

        // Deny network access explicitly
        pipeSec.AddAccessRule(new PipeAccessRule(
            new SecurityIdentifier(WellKnownSidType.NetworkSid, null),
            PipeAccessRights.FullControl,
            AccessControlType.Deny));

        var server = NamedPipeServerStreamAcl.Create(
            PipeName,
            PipeDirection.InOut,
            1,
            PipeTransmissionMode.Byte,
            PipeOptions.None,
            65536,
            65536,
            pipeSec);

        // 将管道完整性标签设为 Medium（S:(ML;;NW;;;ME)），避免普通用户主程序连接管理员辅助进程时报 ERROR_ACCESS_DENIED
        ApplyMediumIntegrityLabel(server.SafePipeHandle);
        return server;
    }

    private static void ApplyMediumIntegrityLabel(SafeHandle handle)
    {
        IntPtr sd = IntPtr.Zero;
        try
        {
            if (ConvertStringSecurityDescriptorToSecurityDescriptorW("S:(ML;;NW;;;ME)", SDDL_REVISION_1, out sd, out _))
            {
                if (GetSecurityDescriptorSacl(sd, out bool saclPresent, out IntPtr pSacl, out _) && saclPresent)
                {
                    _ = SetSecurityInfo(handle, SE_KERNEL_OBJECT, LABEL_SECURITY_INFORMATION, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, pSacl);
                }
            }
        }
        catch
        {
            // Best-effort; falls back cleanly to default ACL
        }
        finally
        {
            if (sd != IntPtr.Zero)
            {
                LocalFree(sd);
            }
        }
    }

    private static DisposableComputer CreateReadOnlyComputer()
    {
        // Strictly read-only, zero network, never touch disks/GPUs handled natively by main app
        var c = new Computer
        {
            IsCpuEnabled = true,
            IsMotherboardEnabled = true,
            IsControllerEnabled = true,
            IsMemoryEnabled = true,
            IsGpuEnabled = false,
            IsStorageEnabled = false,
            IsNetworkEnabled = false,
            IsBatteryEnabled = false,
            IsPsuEnabled = false,
        };
        try
        {
            c.Open();
        }
        catch
        {
            // Safe degradation when driver or admin privilege is unavailable
        }
        return new DisposableComputer(c);
    }

    private static bool HandleClientSession(NamedPipeServerStream stream, DisposableComputer dc, bool isAdmin)
    {
        try
        {
            var reqBytes = ReadFrame(stream, MaxRequestBytes);
            if (reqBytes == null || reqBytes.Length == 0)
            {
                return false;
            }

            string op = "snapshot";
            try
            {
                using var doc = JsonDocument.Parse(reqBytes);
                if (doc.RootElement.TryGetProperty("op", out var opProp) && opProp.ValueKind == JsonValueKind.String)
                {
                    op = opProp.GetString() ?? "snapshot";
                }
            }
            catch
            {
                return false;
            }

            if (string.Equals(op, "shutdown", StringComparison.OrdinalIgnoreCase))
            {
                byte[] ack = Encoding.UTF8.GetBytes("{\"version\":1,\"status\":\"bye\"}");
                WriteFrame(stream, ack);
                return true;
            }

            var snapshot = CollectSnapshot(dc, isAdmin);
            byte[] payload = JsonSerializer.SerializeToUtf8Bytes(snapshot, JsonOpts);
            if (payload.Length <= MaxResponseBytes)
            {
                WriteFrame(stream, payload);
            }
        }
        catch
        {
            // Client disconnected or malformed frame; loop cleanly for next connection
        }
        return false;
    }

    private static HelperSnapshotResponse CollectSnapshot(DisposableComputer dc, bool isAdmin)
    {
        var sensors = new List<HelperSensorItem>(MaxSensors);
        try
        {
            dc.Computer.Accept(new UpdateVisitor());
            foreach (var hw in dc.Computer.Hardware)
            {
                AppendHardwareSensors(hw, sensors);
                foreach (var sub in hw.SubHardware)
                {
                    AppendHardwareSensors(sub, sensors);
                }
            }
        }
        catch
        {
            // Return whatever valid sensors were collected
        }

        return new HelperSnapshotResponse(ProtocolVersion, isAdmin, sensors);
    }

    private static void AppendHardwareSensors(IHardware hw, List<HelperSensorItem> output)
    {
        foreach (var s in hw.Sensors)
        {
            if (output.Count >= MaxSensors) return;
            if (!s.Value.HasValue) continue;
            double v = s.Value.Value;
            if (double.IsNaN(v) || double.IsInfinity(v)) continue;

            string? unit = s.SensorType switch
            {
                SensorType.Temperature => "C",
                SensorType.Power => "W",
                SensorType.Fan => "RPM",
                SensorType.Voltage => "V",
                SensorType.Clock => "MHz",
                _ => null,
            };
            if (unit == null) continue;

            // Preserve original hardware and sensor names per Spec §3.4 / §7
            output.Add(new HelperSensorItem(
                Truncate(hw.Name ?? "Unknown", 60),
                Truncate(s.Name ?? "Sensor", 60),
                s.SensorType.ToString(),
                Math.Round(v, 2),
                unit));
        }
    }

    private static string Truncate(string s, int maxLen) =>
        s.Length <= maxLen ? s : s[..maxLen];

    private static byte[]? ReadFrame(Stream stream, int maxLen)
    {
        byte[] hdr = new byte[4];
        if (!ReadExact(stream, hdr)) return null;
        uint len = BinaryPrimitives.ReadUInt32LittleEndian(hdr);
        if (len == 0 || len > maxLen) return null;

        byte[] buf = new byte[len];
        if (!ReadExact(stream, buf)) return null;
        return buf;
    }

    private static bool ReadExact(Stream stream, byte[] buffer)
    {
        int off = 0;
        while (off < buffer.Length)
        {
            int n = stream.Read(buffer, off, buffer.Length - off);
            if (n <= 0) return false;
            off += n;
        }
        return true;
    }

    private static void WriteFrame(Stream stream, byte[] payload)
    {
        byte[] hdr = new byte[4];
        BinaryPrimitives.WriteUInt32LittleEndian(hdr, (uint)payload.Length);
        stream.Write(hdr, 0, 4);
        stream.Write(payload, 0, payload.Length);
        stream.Flush();
    }

    private static bool IsCurrentProcessElevated()
    {
        try
        {
            using var id = WindowsIdentity.GetCurrent();
            var principal = new WindowsPrincipal(id);
            return principal.IsInRole(WindowsBuiltInRole.Administrator);
        }
        catch
        {
            return false;
        }
    }

    private sealed class DisposableComputer(Computer computer) : IDisposable
    {
        public Computer Computer { get; } = computer;
        public void Dispose()
        {
            try { Computer.Close(); } catch { }
        }
    }
}
