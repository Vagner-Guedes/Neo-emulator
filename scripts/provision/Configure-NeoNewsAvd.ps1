[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath,
    [string]$AvdName,
    [string]$AvdRoot = (Join-Path $env:USERPROFILE '.android\avd'),
    [switch]$SkipBackup
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $PSScriptRoot '..\..\config\runtime.json' }

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Configuração não encontrada: $ConfigPath"
}

$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding utf8 | ConvertFrom-Json
if (-not $AvdName) {
    $AvdName = $config.android.preferredAvd
}

$avdDirectory = Join-Path $AvdRoot "$AvdName.avd"
$iniPath = Join-Path $avdDirectory 'config.ini'
if (-not (Test-Path -LiteralPath $iniPath)) {
    throw "config.ini do AVD não encontrado: $iniPath"
}

$optimization = $config.android.optimization
$settings = [ordered]@{
    'hw.lcd.width' = [string]$optimization.screen.width
    'hw.lcd.height' = [string]$optimization.screen.height
    'hw.lcd.density' = [string]$optimization.screen.density
    'hw.ramSize' = [string]$optimization.ramMb
    'hw.cpu.ncore' = [string]$optimization.cpuCores
    'disk.dataPartition.size' = [string]$optimization.dataPartitionSize
    'hw.gpu.enabled' = 'yes'
    'hw.gpu.mode' = [string]$optimization.gpuMode
    'hw.audioInput' = 'yes'
    'hw.audioOutput' = 'yes'
    'showDeviceFrame' = 'no'
    'skin.dynamic' = 'no'
    'hw.initialOrientation' = 'landscape'
}

$lines = @(Get-Content -LiteralPath $iniPath -Encoding utf8)
foreach ($entry in $settings.GetEnumerator()) {
    $key = [regex]::Escape($entry.Key)
    $replacement = "$($entry.Key)=$($entry.Value)"
    $found = $false
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -match "^$key=") {
            $lines[$index] = $replacement
            $found = $true
            break
        }
    }

    if (-not $found) {
        $lines += $replacement
    }
}

$backupPath = "$iniPath.before-neonews-optimization.bak"
if (-not $SkipBackup -and -not (Test-Path -LiteralPath $backupPath)) {
    Copy-Item -LiteralPath $iniPath -Destination $backupPath
}

if ($PSCmdlet.ShouldProcess($iniPath, "aplicar perfil NeoNews ao AVD $AvdName")) {
    Set-Content -LiteralPath $iniPath -Value $lines -Encoding utf8
}

[ordered]@{
    avd = $AvdName
    configPath = $iniPath
    backupPath = if ($SkipBackup) { $null } else { $backupPath }
    applied = -not [bool]$WhatIfPreference
    settings = $settings
} | ConvertTo-Json -Depth 6
