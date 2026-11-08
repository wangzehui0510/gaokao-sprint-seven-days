using System;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

// 短命 Win32 桥接进程：只操作同时匹配 HWND 与进程 ID 的真实窗口。
internal static class DesktopWindowBridge
{
    private const int SwHide = 0;
    private const int SwRestore = 9;
    // 限定原生消息响应的等待时间；超时明确失败，不冒充已完成隐藏或恢复。
    private const int VerificationTimeoutMilliseconds = 3000;

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool IsWindow(IntPtr window);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool IsWindowVisible(IntPtr window);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool IsIconic(IntPtr window);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ShowWindowAsync(IntPtr window, int command);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetForegroundWindow(IntPtr window);

    [DllImport("kernel32.dll")]
    private static extern IntPtr GetStdHandle(int standardHandle);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool WriteFile(IntPtr file, byte[] buffer, uint count, out uint written, IntPtr overlapped);

    // 查询和错误快照共用一套字段；verified 为真才代表窗口归属已验证。
    private sealed class WindowState
    {
        internal string Command = "";
        internal long Handle;
        internal uint ExpectedProcessId;
        internal uint ProcessId;
        internal bool Verified;
        internal bool Visible;
        internal bool Minimized;
    }

    // 唯一命令入口先验证窗口归属，再执行并核验真实状态，最后输出结构化结果。
    [STAThread]
    private static int Main(string[] arguments)
    {
        WindowState state = new WindowState();
        try
        {
            if (arguments.Length != 3)
                return Report(state, false, "参数应为 <hide|restore|query> <HWND十进制> <预期进程ID>。", 2);
            state.Command = arguments[0];
            if (state.Command != "hide" && state.Command != "restore" && state.Command != "query")
                return Report(state, false, "不支持的窗口命令。", 2);
            if (!long.TryParse(arguments[1], NumberStyles.None, CultureInfo.InvariantCulture, out state.Handle) || state.Handle <= 0)
                return Report(state, false, "HWND 必须是有效的正十进制整数。", 2);
            if (!uint.TryParse(arguments[2], NumberStyles.None, CultureInfo.InvariantCulture, out state.ExpectedProcessId) || state.ExpectedProcessId == 0)
                return Report(state, false, "预期进程 ID 必须是有效的正整数。", 2);
            if (IntPtr.Size == 4 && state.Handle > int.MaxValue)
                return Report(state, false, "当前辅助进程无法表示该窗口句柄。", 2);

            IntPtr window = new IntPtr(state.Handle);
            string validationError = CaptureWindow(window, state);
            if (validationError != null)
                return Report(state, false, validationError, 3);
            if (state.Command == "query")
                return Report(state, true, "", 0);

            // 使用异步消息，避免辅助程序与正在等待它的 Godot UI 线程互相阻塞。
            if (!ShowWindowAsync(window, state.Command == "hide" ? SwHide : SwRestore))
                return Report(state, false, "ShowWindowAsync 提交失败，Win32错误码 " + Marshal.GetLastWin32Error().ToString(CultureInfo.InvariantCulture) + "。", 4);

            DateTime deadline = DateTime.UtcNow.AddMilliseconds(VerificationTimeoutMilliseconds);
            while (true)
            {
                validationError = CaptureWindow(window, state);
                if (validationError != null)
                    return Report(state, false, validationError, 3);
                bool reachedTarget = state.Command == "hide" ? !state.Visible : state.Visible && !state.Minimized;
                if (reachedTarget)
                {
                    // Windows 可限制抢占前台；可见且已解除最小化才是恢复成功的判据。
                    if (state.Command == "restore")
                        SetForegroundWindow(window);
                    return Report(state, true, "", 0);
                }
                if (DateTime.UtcNow >= deadline)
                    return Report(state, false, "窗口未在限定时间内达到请求的真实可见状态。", 5);
                Thread.Sleep(10);
            }
        }
        catch (Exception error)
        {
            return Report(state, false, error.GetType().Name + ": " + error.Message, 6);
        }
    }

    // 每次读取状态前重验窗口存在性与进程归属，拒绝操作回收或其他进程的句柄。
    private static string CaptureWindow(IntPtr window, WindowState state)
    {
        state.Verified = false;
        state.ProcessId = 0;
        if (!IsWindow(window))
            return "目标 HWND 已不存在。";
        if (GetWindowThreadProcessId(window, out state.ProcessId) == 0 || state.ProcessId == 0)
            return "无法读取目标窗口的进程归属。";
        if (state.ProcessId != state.ExpectedProcessId)
            return "目标 HWND 不属于指定的游戏进程。";
        state.Visible = IsWindowVisible(window);
        state.Minimized = IsIconic(window);
        state.Verified = true;
        return null;
    }

    // WinExe 不创建控制台；Godot 重定向标准输出后仍可读取这一行 UTF-8 JSON。
    private static int Report(WindowState state, bool ok, string message, int exitCode)
    {
        string json = "{\"ok\":" + BooleanText(ok)
            + ",\"command\":\"" + EscapeJson(state.Command) + "\""
            + ",\"hwnd\":\"" + state.Handle.ToString(CultureInfo.InvariantCulture) + "\""
            + ",\"pid\":" + state.ProcessId.ToString(CultureInfo.InvariantCulture)
            + ",\"verified\":" + BooleanText(state.Verified)
            + ",\"visible\":" + BooleanText(state.Visible)
            + ",\"minimized\":" + BooleanText(state.Minimized)
            + ",\"message\":\"" + EscapeJson(message) + "\"}\n";
        // GUI 子系统没有控制台；只写父进程提供的管道，直接双击时也不能弹出异常窗口。
        IntPtr standardOutput = GetStdHandle(-11);
        if (standardOutput != IntPtr.Zero && standardOutput != new IntPtr(-1))
        {
            byte[] bytes = new UTF8Encoding(false).GetBytes(json);
            uint written;
            WriteFile(standardOutput, bytes, (uint)bytes.Length, out written, IntPtr.Zero);
        }
        return exitCode;
    }

    private static string BooleanText(bool value)
    {
        return value ? "true" : "false";
    }

    // 错误消息也必须保持可解析 JSON，不让异常文本破坏调用协议。
    private static string EscapeJson(string value)
    {
        StringBuilder result = new StringBuilder();
        foreach (char character in value)
        {
            if (character == '\\' || character == '"')
                result.Append('\\').Append(character);
            // 管道只传 ASCII，中文由 JSON Unicode 转义保留，避开宿主进程代码页差异。
            else if (character < 0x20 || character > 0x7e)
                result.Append("\\u").Append(((int)character).ToString("x4", CultureInfo.InvariantCulture));
            else
                result.Append(character);
        }
        return result.ToString();
    }
}
