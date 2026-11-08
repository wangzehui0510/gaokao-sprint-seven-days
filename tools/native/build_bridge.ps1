param(
    [string]$CompilerPath = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
)

$ErrorActionPreference = 'Stop'

# 使用 Windows 自带 .NET Framework 编译器；不下载工具或切换备用实现。
if (-not (Test-Path -LiteralPath $CompilerPath -PathType Leaf)) {
    throw "找不到 C# 编译器：$CompilerPath。请使用 -CompilerPath 指定 .NET Framework csc.exe。"
}
$bridgeSource = Join-Path $PSScriptRoot 'DesktopWindowBridge.cs'
$bridgeOutputDirectory = Join-Path $PSScriptRoot 'bin'
$bridgeExecutable = Join-Path $bridgeOutputDirectory 'DesktopWindowBridge.exe'
New-Item -ItemType Directory -Path $bridgeOutputDirectory -Force | Out-Null

# winexe 不分配控制台；Godot 以标准输出管道读取 JSON 结果。
& $CompilerPath /nologo /target:winexe /platform:anycpu /optimize+ /warnaserror+ "/out:$bridgeExecutable" $bridgeSource
if ($LASTEXITCODE -ne 0) {
    throw "Windows 窗口辅助程序构建失败，退出码 $LASTEXITCODE。"
}
if (-not (Test-Path -LiteralPath $bridgeExecutable -PathType Leaf)) {
    throw "编译器未生成预期辅助程序：$bridgeExecutable。"
}
Write-Output "已构建 Windows 窗口辅助程序：$bridgeExecutable"
