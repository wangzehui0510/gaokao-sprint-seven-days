[CmdletBinding()]
param(
    # 明确指定本机Godot可执行文件；安装位置变化时由调用方传入新路径。
    [string]$GodotPath = 'D:\Godot_v4.7.2-stable_win64\Godot_v4.7.2-stable_win64_console.exe',

    # 开启后进入工程编辑器；省略时直接运行游戏主场景。
    [switch]$Editor
)

$ErrorActionPreference = 'Stop'

# 根据脚本位置定位唯一工程，不依赖调用命令时的工作目录。
$projectRoot = Split-Path -Parent $PSScriptRoot
$projectFile = Join-Path $projectRoot 'project.godot'
if (-not (Test-Path -LiteralPath $GodotPath -PathType Leaf)) {
    throw "未找到Godot可执行文件：$GodotPath。请使用 -GodotPath 指定实际安装路径。"
}
if (-not (Test-Path -LiteralPath $projectFile -PathType Leaf)) {
    throw "未找到Godot工程文件：$projectFile。请将脚本放在本项目的tools目录中。"
}

# 直接传递参数并保留引擎输出，非零退出码明确暴露启动或运行失败。
$godotArguments = @('--path', $projectRoot)
if ($Editor) {
    $godotArguments += '--editor'
}
& $GodotPath @godotArguments
if ($LASTEXITCODE -ne 0) {
    throw "Godot执行失败，退出码：$LASTEXITCODE。请查看上方引擎日志。"
}
