// WinHardware Monitor — 可选独立隔离的 LibreHardwareMonitor 硬件传感器辅助进程
// 许可证：Mozilla Public License 2.0 (MPL-2.0)，与主程序 Apache-2.0 严格进程隔离
// 目标运行时：Windows 内置 .NET Framework 4.8（Win10/Win11 开箱即用，无需额外安装 .NET 8）
// 安全边界：严格只读、零网络访问、禁用磁盘/GPU采集、仅限本机同用户命名管道 IPC (v1)、低优先级调度

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Threading;
using LibreHardwareMonitor.Hardware;

namespace WinHardwareMonitor.LhmHelper
{
    /// <summary>单条硬件传感器快照项（保留原始硬件名与传感器名，不强行归类）</summary>
    internal sealed class HelperSensorItem
    {
        public string Hardware { get; }
        public string Name { get; }
        public string SensorType { get; }
        public double Value { get; }
        public string Unit { get; }

        public HelperSensorItem(string hardware, string name, string sensorType, double value, string unit)
        {
            Hardware = hardware;
            Name = name;
            SensorType = sensorType;
            Value = value;
            Unit = unit;
        }
    }

    /// <summary>递归刷新硬件节点与子硬件节点的只读访问器</summary>
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
            // 降低后台辅助进程优先级，绝不抢占系统前台应用与游戏 CPU 时间片
            try { Process.GetCurrentProcess().PriorityClass = ProcessPriorityClass.BelowNormal; } catch { }

            bool selfTest = HasArg(args, "--self-test");
            bool fromHost = HasArg(args, "--from-host");
            bool isAdmin = IsCurrentProcessElevated();

            if (selfTest)
            {
                using (var probe = CreateReadOnlyComputer())
                {
                    var sensors = CollectSensors(probe);
                    Console.WriteLine(SerializeSnapshotJson(isAdmin, sensors));
                }
                return 0;
            }

            bool createdNew;
            using (var mutex = new Mutex(true, MutexName, out createdNew))
            {
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

                using (var computer = CreateReadOnlyComputer())
                using (var cts = new CancellationTokenSource())
                {
                    AppDomain.CurrentDomain.ProcessExit += (_, __) =>
                    {
                        try { cts.Cancel(); } catch { }
                    };

                    // 若用户直接双击运行（非主程序通过 --from-host 启动），在独立线程弹出友好说明，不阻塞命名管道监听
                    if (!fromHost)
                    {
                        string roleHint = isAdmin
                            ? "当前权限：管理员（可完整读取 CPU 温度与主板传感器）。"
                            : "当前权限：普通用户（部分 CPU/主板传感器可能需要以管理员身份启动或在主程序内点击“启动扩展辅助进程”）。";
                        var uiNoticeThread = new Thread(() =>
                        {
                            MessageBoxW(
                                IntPtr.Zero,
                                "WinHardwareMonitor.LhmHelper 是 WinHardware Monitor 的后台传感器辅助进程（无独立主界面），现已在后台就绪。\n\n" +
                                roleHint + "\n\n请打开主程序 winhardware-monitor.exe，在「系统设置」或「主板与传感器」页面启用扩展组件即可查看数据。",
                                "WinHardware Monitor 扩展辅助进程（已在后台运行）",
                                0x00000040);
                        });
                        uiNoticeThread.IsBackground = true;
                        uiNoticeThread.Start();
                    }

                    try
                    {
                        while (!cts.IsCancellationRequested)
                        {
                            using (var server = CreateSameUserMediumIntegrityPipe())
                            {
                                server.WaitForConnection();
                                bool shouldExit = HandleClientSession(server, computer, isAdmin);
                                if (shouldExit)
                                {
                                    break;
                                }
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
                }
            }

            return 0;
        }

        private static bool HasArg(string[] args, string flag)
        {
            if (args == null) return false;
            foreach (var a in args)
            {
                if (string.Equals(a, flag, StringComparison.OrdinalIgnoreCase)) return true;
            }
            return false;
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

            // 显式拒绝网络访问
            pipeSec.AddAccessRule(new PipeAccessRule(
                new SecurityIdentifier(WellKnownSidType.NetworkSid, null),
                PipeAccessRights.FullControl,
                AccessControlType.Deny));

            var server = new NamedPipeServerStream(
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
                uint sdSize;
                if (ConvertStringSecurityDescriptorToSecurityDescriptorW("S:(ML;;NW;;;ME)", SDDL_REVISION_1, out sd, out sdSize))
                {
                    bool saclPresent;
                    IntPtr pSacl;
                    bool saclDefaulted;
                    if (GetSecurityDescriptorSacl(sd, out saclPresent, out pSacl, out saclDefaulted) && saclPresent)
                    {
                        SetSecurityInfo(handle, SE_KERNEL_OBJECT, LABEL_SECURITY_INFORMATION, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, pSacl);
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
            // 严格只读、零网络、禁用存储与显卡（由主程序原生只读接口采集，绝不干扰休眠磁盘）
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
                // 驱动或权限受限时安全降级
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

                string reqText = Encoding.UTF8.GetString(reqBytes);
                if (reqText.IndexOf("\"shutdown\"", StringComparison.OrdinalIgnoreCase) >= 0)
                {
                    byte[] ack = Encoding.UTF8.GetBytes("{\"version\":1,\"status\":\"bye\"}");
                    WriteFrame(stream, ack);
                    return true;
                }

                var sensors = CollectSensors(dc);
                byte[] payload = Encoding.UTF8.GetBytes(SerializeSnapshotJson(isAdmin, sensors));
                if (payload.Length <= MaxResponseBytes)
                {
                    WriteFrame(stream, payload);
                }
            }
            catch
            {
                // 客户端断开或帧异常时静默恢复下一次监听
            }
            return false;
        }

        private static List<HelperSensorItem> CollectSensors(DisposableComputer dc)
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
                // 保留已成功采集的有效传感器
            }
            return sensors;
        }

        private static void AppendHardwareSensors(IHardware hw, List<HelperSensorItem> output)
        {
            foreach (var s in hw.Sensors)
            {
                if (output.Count >= MaxSensors) return;
                if (!s.Value.HasValue) continue;
                double v = s.Value.Value;
                if (double.IsNaN(v) || double.IsInfinity(v)) continue;

                string unit;
                switch (s.SensorType)
                {
                    case SensorType.Temperature: unit = "C"; break;
                    case SensorType.Power: unit = "W"; break;
                    case SensorType.Fan: unit = "RPM"; break;
                    case SensorType.Voltage: unit = "V"; break;
                    case SensorType.Clock: unit = "MHz"; break;
                    default: continue;
                }

                // 保留原始硬件名与传感器名（规范 §3.4 / §7）
                output.Add(new HelperSensorItem(
                    Truncate(hw.Name ?? "Unknown", 60),
                    Truncate(s.Name ?? "Sensor", 60),
                    s.SensorType.ToString(),
                    Math.Round(v, 2),
                    unit));
            }
        }

        /// <summary>零外部依赖紧凑 UTF-8 JSON 序列化（兼容 .NET Framework 4.8，零包体积膨胀）</summary>
        private static string SerializeSnapshotJson(bool isAdmin, List<HelperSensorItem> sensors)
        {
            var sb = new StringBuilder(256 + sensors.Count * 96);
            sb.Append("{\"version\":");
            sb.Append(ProtocolVersion);
            sb.Append(",\"is_admin\":");
            sb.Append(isAdmin ? "true" : "false");
            sb.Append(",\"sensors\":[");
            for (int i = 0; i < sensors.Count; i++)
            {
                if (i > 0) sb.Append(',');
                var item = sensors[i];
                sb.Append("{\"hardware\":");
                AppendJsonString(sb, item.Hardware);
                sb.Append(",\"name\":");
                AppendJsonString(sb, item.Name);
                sb.Append(",\"sensor_type\":");
                AppendJsonString(sb, item.SensorType);
                sb.Append(",\"value\":");
                sb.Append(item.Value.ToString("0.##", CultureInfo.InvariantCulture));
                sb.Append(",\"unit\":");
                AppendJsonString(sb, item.Unit);
                sb.Append('}');
            }
            sb.Append("]}");
            return sb.ToString();
        }

        private static void AppendJsonString(StringBuilder sb, string s)
        {
            sb.Append('"');
            if (!string.IsNullOrEmpty(s))
            {
                for (int i = 0; i < s.Length; i++)
                {
                    char c = s[i];
                    switch (c)
                    {
                        case '"': sb.Append("\\\""); break;
                        case '\\': sb.Append("\\\\"); break;
                        case '\b': sb.Append("\\b"); break;
                        case '\f': sb.Append("\\f"); break;
                        case '\n': sb.Append("\\n"); break;
                        case '\r': sb.Append("\\r"); break;
                        case '\t': sb.Append("\\t"); break;
                        default:
                            if (c < 0x20)
                            {
                                sb.Append("\\u");
                                sb.Append(((int)c).ToString("x4", CultureInfo.InvariantCulture));
                            }
                            else
                            {
                                sb.Append(c);
                            }
                            break;
                    }
                }
            }
            sb.Append('"');
        }

        private static string Truncate(string s, int maxLen)
        {
            return s.Length <= maxLen ? s : s.Substring(0, maxLen);
        }

        private static byte[] ReadFrame(Stream stream, int maxLen)
        {
            byte[] hdr = new byte[4];
            if (!ReadExact(stream, hdr)) return null;
            uint len = (uint)hdr[0] | ((uint)hdr[1] << 8) | ((uint)hdr[2] << 16) | ((uint)hdr[3] << 24);
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
            uint len = (uint)payload.Length;
            byte[] hdr = new byte[4];
            hdr[0] = (byte)(len & 0xFF);
            hdr[1] = (byte)((len >> 8) & 0xFF);
            hdr[2] = (byte)((len >> 16) & 0xFF);
            hdr[3] = (byte)((len >> 24) & 0xFF);
            stream.Write(hdr, 0, 4);
            stream.Write(payload, 0, payload.Length);
            stream.Flush();
        }

        private static bool IsCurrentProcessElevated()
        {
            try
            {
                using (var id = WindowsIdentity.GetCurrent())
                {
                    var principal = new WindowsPrincipal(id);
                    return principal.IsInRole(WindowsBuiltInRole.Administrator);
                }
            }
            catch
            {
                return false;
            }
        }

        private sealed class DisposableComputer : IDisposable
        {
            public Computer Computer { get; }
            public DisposableComputer(Computer computer) { Computer = computer; }
            public void Dispose()
            {
                try { Computer.Close(); } catch { }
            }
        }
    }
}
