[CmdletBinding()]
param(
    [string]$WorkbookPath,
    [string]$PythonPath
)

$ErrorActionPreference = 'Stop'

# 默认使用本项目交付的 Excel，允许显式指定后续维护的工作簿位置。
$projectRoot = Split-Path -Parent $PSScriptRoot
if (-not $WorkbookPath) {
    $WorkbookPath = Join-Path $projectRoot 'outputs\01a1aebc-daa9-7ca0-9b2c-d4652fa3194d\高考冲刺七天_配置_v0.2.xlsx'
}

# 当前机器的 Python 命令是系统别名，因此显式使用已安装的配套运行时。
if (-not $PythonPath) {
    $PythonPath = Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
}
if (-not (Test-Path -LiteralPath $PythonPath -PathType Leaf)) {
    throw '未找到 Python。请使用 -PythonPath 指定真实的 Python 3.10 或更高版本可执行文件。'
}

$exporterPath = Join-Path $PSScriptRoot 'export_game_config.py'
$schemaPath = Join-Path $projectRoot 'config\config_schema.json'
$outputPath = Join-Path $projectRoot 'config\game_config.json'

# 失败会返回非零退出码；导出器只在整份配置通过后替换 JSON。
& $PythonPath -X utf8 $exporterPath $WorkbookPath --schema $schemaPath --output $outputPath
if ($LASTEXITCODE -ne 0) {
    throw "配置导出失败，退出码：$LASTEXITCODE。请按上方表名、行号和字段修正 Excel。"
}
