[CmdletBinding()]
param(
    [string]$RepositoryRoot,
    [string]$DiskPath,
    [string]$Label = 'base',
    [string]$ReportPath = 'reports/nativebridge-inventory.json',
    [int]$BootTimeoutSeconds = 240,
    [switch]$KeepOverlay
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
}
$RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path
. (Join-Path $RepositoryRoot 'scripts\benchmark\QemuBenchmark.Common.ps1')

$config = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'config\runtime.json') -Raw -Encoding utf8 | ConvertFrom-Json
$paths = Resolve-QemuBenchmarkPaths -RepositoryRoot $RepositoryRoot -Config $config
if ([string]::IsNullOrWhiteSpace($DiskPath)) { $DiskPath = $paths.Disk }
if (-not [System.IO.Path]::IsPathRooted($DiskPath)) { $DiskPath = Join-Path $RepositoryRoot $DiskPath }
$DiskPath = (Resolve-Path -LiteralPath $DiskPath).Path
if (-not (Test-QemuBenchmarkNonEmptyFile $DiskPath)) { throw "Disco ausente ou vazio: $DiskPath" }

$reportFullPath = if ([System.IO.Path]::IsPathRooted($ReportPath)) { $ReportPath } else { Join-Path $RepositoryRoot $ReportPath }
New-Item -ItemType Directory -Path (Split-Path -Parent $reportFullPath) -Force | Out-Null
$qemuImg = Join-Path (Split-Path -Parent $paths.Qemu) 'qemu-img.exe'
if (-not (Test-QemuBenchmarkNonEmptyFile $qemuImg)) { throw "qemu-img.exe ausente: $qemuImg" }

function Invoke-InventoryAdb {
    param([string[]]$Arguments, [int]$TimeoutSeconds = 30)
    Invoke-QemuBenchmarkAdb -AdbPath $paths.Adb -Serial $serial -Arguments $Arguments -ServerPort $serverPort -TimeoutSeconds $TimeoutSeconds
}

function Read-InventoryCommand {
    param([string[]]$Arguments, [int]$TimeoutSeconds = 30)
    $result = Invoke-InventoryAdb -Arguments $Arguments -TimeoutSeconds $TimeoutSeconds
    [ordered]@{ exitCode = $result.ExitCode; text = $result.Text }
}

function Read-GuestPath {
    param([string]$Path)
    [ordered]@{
        path = $Path
        ls = Read-InventoryCommand @('shell', 'ls', '-lan', $Path)
        link = Read-InventoryCommand @('shell', 'readlink', $Path)
        sha256 = Read-InventoryCommand @('shell', 'sha256sum', $Path)
        file = Read-InventoryCommand @('shell', 'file', $Path)
    }
}

function Read-GuestDirectory {
    param([string]$Path)
    [ordered]@{
        path = $Path
        listing = Read-InventoryCommand @('shell', 'ls', '-la', $Path) 45
        mounts = Read-InventoryCommand @('shell', 'mount') 30
    }
}

$serverPort = [int]$config.android.adb.serverPort
$serial = "$($config.android.adb.host):$($config.android.adb.hostPort)"
$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) 'NeoNewsRuntimeNativeBridge'
New-Item -ItemType Directory -Path $temporaryRoot -Force | Out-Null
$overlayPath = Join-Path $temporaryRoot ("$Label-$([guid]::NewGuid().ToString('N')).qcow2")
$process = $null
$stop = $null
$result = [ordered]@{
    timestamp = (Get-Date).ToUniversalTime().ToString('o')
    label = $Label
    status = 'not-validated'
    sourceDisk = $DiskPath
    sourceDiskSha256 = (Get-FileHash -LiteralPath $DiskPath -Algorithm SHA256).Hash
    overlay = $overlayPath
    transport = 'tcp'
    serial = $serial
    root = $null
    boot = $null
    properties = [ordered]@{}
    files = @()
    directories = @()
    mounts = $null
    packageManager = [ordered]@{}
    enableNativeBridge = [ordered]@{}
    qmp = $null
    error = $null
}

try {
    $createOutput = @(& $qemuImg create -f qcow2 -F qcow2 -b $DiskPath $overlayPath 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "Falha ao criar overlay: $(($createOutput | Out-String).Trim())" }

    # This inspection does not require a visible Android window. It keeps the
    # production CPU/network parameters while avoiding a UI side effect.
    $config.android.qemu.showWindow = $false
    $arguments = New-QemuBenchmarkArguments -Config $config -DiskPath $overlayPath -RepositoryRoot $RepositoryRoot
    $process = Start-QemuBenchmarkProcess -Executable $paths.Qemu -Arguments $arguments -WorkingDirectory $RepositoryRoot
    $result.boot = Wait-QemuBenchmarkMilestones -AdbPath $paths.Adb -Serial $serial -TimeoutSeconds $BootTimeoutSeconds
    if (-not $result.boot.booted) { throw "Guest nao concluiu boot em $BootTimeoutSeconds segundos." }

    $rootRequest = Invoke-QemuBenchmarkAdbHost -AdbPath $paths.Adb -Arguments @('root') -ServerPort $serverPort -TimeoutSeconds 30
    $rootDeadline = (Get-Date).AddSeconds(60)
    do {
        Start-Sleep -Seconds 2
        $identity = Invoke-InventoryAdb @('shell', 'id')
        if ($identity.Text -match 'uid=0\(root\)') { break }
    } while ((Get-Date) -lt $rootDeadline)
    $result.root = [ordered]@{ request = [ordered]@{ exitCode = $rootRequest.ExitCode; text = $rootRequest.Text }; identity = [ordered]@{ exitCode = $identity.ExitCode; text = $identity.Text }; ready = $identity.Text -match 'uid=0\(root\)' }
    if (-not $result.root.ready) { throw "ADB root nao foi confirmado: $($identity.Text)" }

    foreach ($property in @(
        'persist.sys.nativebridge',
        'ro.dalvik.vm.native.bridge',
        'ro.enable.native.bridge',
        'ro.product.cpu.abilist',
        'ro.product.cpu.abilist32',
        'ro.product.cpu.abilist64',
        'ro.product.cpu.abi',
        'ro.zygote'
    )) {
        $result.properties[$property] = Read-InventoryCommand @('shell', 'getprop', $property)
    }

    foreach ($path in @(
        '/system/lib/libnb.so',
        '/system/lib64/libnb.so',
        '/system/lib/libhoudini.so',
        '/system/lib64/libhoudini.so',
        '/system/bin/houdini',
        '/system/bin/houdini64',
        '/data/arm/houdini7_y.sfs',
        '/data/arm/houdini7_z.sfs'
    )) { $result.files += Read-GuestPath $path }

    foreach ($path in @('/data/arm', '/system/lib', '/system/lib64', '/system/bin')) { $result.directories += Read-GuestDirectory $path }
    $result.mounts = Read-InventoryCommand @('shell', 'mount') 45
    $result.enableNativeBridge = [ordered]@{
        path = '/system/bin/enable_nativebridge'
        ls = Read-InventoryCommand @('shell', 'ls', '-lan', '/system/bin/enable_nativebridge')
        sha256 = Read-InventoryCommand @('shell', 'sha256sum', '/system/bin/enable_nativebridge')
        content = Read-InventoryCommand @('shell', 'cat', '/system/bin/enable_nativebridge') 45
    }
    $result.packageManager = [ordered]@{
        neoNews = Read-InventoryCommand @('shell', 'dumpsys', 'package', $config.neonews.packageName) 45
        primaryCpuAbi = Read-InventoryCommand @('shell', 'cmd', 'package', 'dump', $config.neonews.packageName) 45
        packages = Read-InventoryCommand @('shell', 'pm', 'list', 'packages', $config.neonews.packageName)
    }
    $result.status = 'captured'
}
catch {
    $result.error = $_.Exception.Message
}
finally {
    if ($process) {
        try { $stop = Stop-QemuBenchmarkProcess -Process $process -QmpPort ([int]$config.android.qemu.qmpPort) -TimeoutSeconds ([int]$config.timeouts.qemuShutdownSeconds) } catch { $stop = [ordered]@{ error = $_.Exception.Message } }
    }
    $result.qmp = $stop
    try { $null = Invoke-QemuBenchmarkAdbHost -AdbPath $paths.Adb -Arguments @('disconnect', $serial) -ServerPort $serverPort } catch { }
    try { $null = Invoke-QemuBenchmarkAdbHost -AdbPath $paths.Adb -Arguments @('kill-server') -ServerPort $serverPort } catch { }
    if (-not $KeepOverlay -and (Test-Path -LiteralPath $overlayPath)) { Remove-Item -LiteralPath $overlayPath -Force -ErrorAction SilentlyContinue }
}

$result | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $reportFullPath -Encoding utf8
$result | ConvertTo-Json -Depth 16
if ($result.status -ne 'captured') { throw "Inventario Native Bridge falhou: $($result.error)" }
