[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$Serial,
    [int]$MaxLogLines = 120,
    [string]$ExecutablePath,
    [string]$ReportPath
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $repositoryRoot 'config\runtime.json' }
$configFullPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$runtimeRoot = Split-Path -Parent (Split-Path -Parent $configFullPath)
$config = Get-Content -LiteralPath $configFullPath -Raw -Encoding utf8 | ConvertFrom-Json

$expectedSerial = if ($config.android.adb.transport -eq 'tcp') {
    "$($config.android.adb.host):$($config.android.adb.hostPort)"
} elseif ($config.android.adb.emulatorSerial) {
    [string]$config.android.adb.emulatorSerial
} else {
    "emulator-$($config.android.emulator.validationPort)"
}
if (-not [string]::IsNullOrWhiteSpace($Serial) -and $Serial -ne $expectedSerial) {
    throw "O diagnóstico do launcher usa o serial configurado '$expectedSerial'; não é seguro substituir a identidade por '$Serial'."
}

if (-not [string]::IsNullOrWhiteSpace($ExecutablePath)) {
    $launcherPath = [System.IO.Path]::GetFullPath($ExecutablePath)
    if (-not (Test-Path -LiteralPath $launcherPath -PathType Leaf)) {
        throw "NeoNewsRuntime.exe não encontrado no caminho explícito: $launcherPath"
    }
}
else {
    $launcherCandidates = @(
        (Join-Path $runtimeRoot 'NeoNewsRuntime.exe'),
        (Join-Path $runtimeRoot 'launcher\NeoNews.Runtime.Launcher\bin\Release\net8.0-windows\NeoNewsRuntime.exe'),
        (Join-Path $runtimeRoot 'dist\NeoNewsRuntime\NeoNewsRuntime.exe')
    )
    $launcherCandidates += @(Get-ChildItem -LiteralPath (Join-Path $runtimeRoot 'dist') -Filter 'NeoNewsRuntime.exe' -File -Recurse -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -ExpandProperty FullName)
    $launcherPath = $launcherCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}
if ([string]::IsNullOrWhiteSpace($launcherPath)) {
    throw 'NeoNewsRuntime.exe não encontrado. Publique o launcher antes de coletar o diagnóstico.'
}
$launcherPath = (Resolve-Path -LiteralPath $launcherPath).Path
$reportRelativePath = [string]$config.diagnostics.defaultReport
$launcherRoot = Split-Path -Parent $launcherPath
$canonicalReportPath = if ([System.IO.Path]::IsPathRooted($reportRelativePath)) {
    $reportRelativePath
} else {
    Join-Path $launcherRoot ($reportRelativePath -replace '/', '\')
}
. (Join-Path $repositoryRoot 'scripts\validation\ValidationEvidence.Common.ps1')
$null = Initialize-ValidationReport -ReportPath $canonicalReportPath -Validator 'Collect-Diagnostics'

$before = if (Test-Path -LiteralPath $canonicalReportPath) {
    (Get-Item -LiteralPath $canonicalReportPath).LastWriteTimeUtc
} else {
    [datetime]::MinValue
}
$process = Start-Process -FilePath $launcherPath -ArgumentList '--diagnostics' -WorkingDirectory (Split-Path -Parent $launcherPath) -WindowStyle Hidden -PassThru -Wait
if ($process.ExitCode -ne 0) { throw "A coleta de diagnóstico falhou com código $($process.ExitCode)." }

$fresh = $false
$deadline = (Get-Date).ToUniversalTime().AddSeconds(30)
do {
    if (Test-Path -LiteralPath $canonicalReportPath) {
        $fresh = (Get-Item -LiteralPath $canonicalReportPath).LastWriteTimeUtc -gt $before
    }
    if (-not $fresh) { Start-Sleep -Milliseconds 250 }
} while (-not $fresh -and (Get-Date).ToUniversalTime() -lt $deadline)
if (-not $fresh) { throw "O launcher não produziu um relatório novo em $canonicalReportPath." }

$jsonText = Get-Content -LiteralPath $canonicalReportPath -Raw -Encoding utf8
$json = $jsonText | ConvertFrom-Json
if (-not $json.tools -or -not $json.android -or -not $json.timestamp) {
    throw 'O relatório não possui o schema canônico de identidade do runtime.'
}

$outputPath = if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $canonicalReportPath
} elseif ([System.IO.Path]::IsPathRooted($ReportPath)) {
    $ReportPath
} else {
    Join-Path $repositoryRoot ($ReportPath -replace '/', '\')
}
if (-not [System.IO.Path]::GetFullPath($outputPath).Equals([System.IO.Path]::GetFullPath($canonicalReportPath), [StringComparison]::OrdinalIgnoreCase)) {
    $outputDirectory = Split-Path -Parent $outputPath
    if ($outputDirectory) { New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null }
    Copy-Item -LiteralPath $canonicalReportPath -Destination $outputPath -Force
}

$jsonText
