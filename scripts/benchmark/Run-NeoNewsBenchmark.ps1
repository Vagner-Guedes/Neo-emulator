[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$AvdName,
    [int]$Port = 5556,
    [int]$Iterations = 3,
    [int]$BootTimeoutSeconds = 180,
    [string]$ReportPath
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $PSScriptRoot '..\..\config\runtime.json' }
if ([string]::IsNullOrWhiteSpace($ReportPath)) { $ReportPath = Join-Path $PSScriptRoot '..\..\reports\benchmark.json' }

function Resolve-SdkRoot {
    if ($env:ANDROID_SDK_ROOT) { return $env:ANDROID_SDK_ROOT }
    if ($env:ANDROID_HOME) { return $env:ANDROID_HOME }
    return (Join-Path $env:LOCALAPPDATA 'Android\Sdk')
}

function Invoke-Adb {
    param([string]$AdbPath, [string]$Serial, [string[]]$Arguments)
    $output = & $AdbPath -s $Serial @Arguments 2>&1
    return (($output | Out-String).Trim())
}

function Wait-ForBoot {
    param([string]$AdbPath, [string]$Serial, [int]$TimeoutSeconds)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        try {
            $state = (& $AdbPath -s $Serial get-state 2>&1 | Out-String).Trim()
        } catch {
            $state = ''
        }
        if ($state -eq 'device') {
            try {
                $boot = (& $AdbPath -s $Serial shell getprop sys.boot_completed 2>&1 | Out-String).Trim()
            } catch {
                $boot = ''
            }
            if ($boot -match '(?m)^1$') { return $true }
        }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)
    return $false
}

function Stop-EmulatorIfRunning {
    param([string]$AdbPath, [string]$Serial)
    try {
        & $AdbPath -s $Serial emu kill 2>$null | Out-Null
    } catch {
        # Um serial ausente já está parado; não deve invalidar o próximo ensaio.
    }
}

if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "Configuração não encontrada: $ConfigPath" }
$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding utf8 | ConvertFrom-Json
if (-not $AvdName) { $AvdName = $config.android.preferredAvd }
if ($Iterations -lt 1) { throw 'Iterations deve ser maior ou igual a 1.' }

$sdkRoot = Resolve-SdkRoot
$adbPath = Join-Path $sdkRoot 'platform-tools\adb.exe'
$emulatorPath = Join-Path $sdkRoot 'emulator\emulator.exe'
if (-not (Test-Path -LiteralPath $adbPath)) { throw "ADB não encontrado: $adbPath" }
if (-not (Test-Path -LiteralPath $emulatorPath)) { throw "Emulator não encontrado: $emulatorPath" }

$env:ANDROID_HOME = $sdkRoot
$env:ANDROID_SDK_ROOT = $sdkRoot
$serial = "emulator-$Port"
$runs = @()

for ($iteration = 1; $iteration -le $Iterations; $iteration++) {
    Stop-EmulatorIfRunning -AdbPath $adbPath -Serial $serial
    Start-Sleep -Seconds 2
    $startAt = Get-Date
    $process = Start-Process -FilePath $emulatorPath -ArgumentList @('-avd', $AvdName, '-no-window', '-gpu', 'swiftshader', '-no-boot-anim', '-no-snapshot', '-accel', 'auto', '-timezone', $config.runtime.timezone, '-port', $Port) -WindowStyle Hidden -PassThru
    $booted = Wait-ForBoot -AdbPath $adbPath -Serial $serial -TimeoutSeconds $BootTimeoutSeconds
    $bootSeconds = if ($booted) { [math]::Round(((Get-Date) - $startAt).TotalSeconds, 2) } else { $null }
    $packageName = [string]$config.neonews.packageName
    $packageInstalled = $false
    $adbLatencyMs = $null
    if ($booted) {
        $latencyStart = Get-Date
        $null = Invoke-Adb -AdbPath $adbPath -Serial $serial -Arguments @('shell', 'getprop', 'ro.build.version.sdk')
        $adbLatencyMs = [math]::Round(((Get-Date) - $latencyStart).TotalMilliseconds, 2)
        $packageInstalled = (Invoke-Adb -AdbPath $adbPath -Serial $serial -Arguments @('shell', 'pm', 'path', $packageName)) -match '^package:'
    }
    $runs += [pscustomobject]@{
        iteration = $iteration
        booted = $booted
        bootSeconds = $bootSeconds
        adbLatencyMs = $adbLatencyMs
        packageInstalled = $packageInstalled
        processId = $process.Id
    }
    Stop-EmulatorIfRunning -AdbPath $adbPath -Serial $serial
    Start-Sleep -Seconds 2
}

$bootValues = @($runs | Where-Object { $null -ne $_.bootSeconds } | ForEach-Object { [double]$_.bootSeconds })
$latencyValues = @($runs | Where-Object { $null -ne $_.adbLatencyMs } | ForEach-Object { [double]$_.adbLatencyMs })
$successfulRuns = @($runs | Where-Object { $_.booted })
$missingPackageRuns = @($runs | Where-Object { -not $_.packageInstalled })
$result = [ordered]@{
    timestamp = (Get-Date).ToUniversalTime().ToString('o')
    avd = $AvdName
    serial = $serial
    iterations = $Iterations
    runs = @($runs)
    summary = [ordered]@{
        bootMinSeconds = if ($bootValues.Count) { ($bootValues | Measure-Object -Minimum).Minimum } else { $null }
        bootAverageSeconds = if ($bootValues.Count) { [math]::Round(($bootValues | Measure-Object -Average).Average, 2) } else { $null }
        bootMaxSeconds = if ($bootValues.Count) { ($bootValues | Measure-Object -Maximum).Maximum } else { $null }
        adbAverageMs = if ($latencyValues.Count) { [math]::Round(($latencyValues | Measure-Object -Average).Average, 2) } else { $null }
        packageInstalledInAllRuns = $missingPackageRuns.Count -eq 0
    }
    status = if ($successfulRuns.Count -eq $Iterations) { 'base-runtime-measured' } else { 'incomplete' }
}

$json = $result | ConvertTo-Json -Depth 8
if ($ReportPath) {
    $reportDirectory = Split-Path -Parent $ReportPath
    if ($reportDirectory -and -not (Test-Path -LiteralPath $reportDirectory)) { New-Item -ItemType Directory -Path $reportDirectory -Force | Out-Null }
    Set-Content -LiteralPath $ReportPath -Value $json -Encoding utf8
}
$json
