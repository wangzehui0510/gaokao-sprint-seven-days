# Windows 窗口辅助程序

Godot 主窗口不能使用 `Window.hide()` 切换可见性。本目录提供短命 C# Win32 辅助程序；它核验窗口句柄及进程归属，然后使用 `ShowWindowAsync` 隐藏或恢复真实窗口，并检查 `IsWindowVisible`、`IsIconic` 的结果。程序按 Windows GUI 子系统构建，不弹出辅助控制台。

在仓库根目录构建：

```powershell
& .\tools\native\build_bridge.ps1
```

默认编译器为 `%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe`，可通过 `-CompilerPath` 显式指定。源码兼容该编译器。输出 `tools/native/bin/DesktopWindowBridge.exe` 为本机构建产物，应由 Git 忽略。

调用协议：

```text
DesktopWindowBridge.exe <hide|restore|query> <HWND十进制> <预期进程ID>
```

标准输出为一行 UTF-8 JSON，包含 `ok`、`command`、`hwnd`、`pid`、`verified`、`visible`、`minimized`、`message`。仅退出码为 0、`ok=true` 且 `verified=true` 时成功；失败返回非零退出码及明确错误。`verified` 仅表示当前快照的窗口存在且进程归属相符，失败快照也可能具有该字段。

`hide` 只有确认实际不可见才成功。`restore` 只有确认实际可见且不再最小化才成功；Windows 可能限制抢占前台，因此前台焦点请求本身不作为成功判据。最多等待 3 秒，期间持续重验 HWND 归属。

Godot 控制器在工作线程中等待辅助程序，主线程逐帧等待完成，让窗口消息和唯一游戏模拟器继续执行。`hide_to_tray()`、`restore_window()` 必须 `await`；只有辅助程序核验成功后才发出成功信号。执行过程中可读取 `is_transitioning()`，退出流程应等待当前请求结束，再保存并 `shutdown()`。初始化的只读 `query` 不向窗口投递消息，可同步执行。

开发工程直接使用上述构建路径。导出应用时须将 `tools/native/bin/DesktopWindowBridge.exe` 作为外部文件放在游戏可执行文件旁的同名相对目录，不能只打包进 PCK。缺失程序或不支持平台时初始化会明确失败，不切换到其他隐藏方案。
