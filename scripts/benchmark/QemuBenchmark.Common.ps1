$ErrorActionPreference = 'Stop'

function Resolve-QemuBenchmarkPaths {
    param(
        [string]$RepositoryRoot,
        [object]$Config
    )

    $resolve = {
        param([string]$Path)
        if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
        return [System.IO.Path]::GetFullPath((Join-Path $RepositoryRoot ($Path -replace '/', '\')))
    }

    $adb = & $resolve (Join-Path $Config.android.tooling.sdkRoot $Config.android.tooling.adbRelativePath)
    $qemu = & $resolve $Config.android.qemu.executable
    $disk = & $resolve $Config.android.qemu.disk
    [pscustomobject]@{
        Adb = $adb
        Qemu = $qemu
        Disk = $disk
    }
}

function Invoke-QemuBenchmarkAdb {
    param(
        [string]$AdbPath,
        [string]$Serial,
        [string[]]$Arguments
    )

    $raw = & $AdbPath -s $Serial @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    [pscustomobject]@{
        ExitCode = $exitCode
        Text = (($raw | Out-String).Trim())
    }
}

function Wait-QemuBenchmarkBoot {
    param(
        [string]$AdbPath,
        [string]$Serial,
        [int]$TimeoutSeconds
    )

    $null = & $AdbPath start-server 2>&1
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        if ($Serial -match ':') { $null = & $AdbPath connect $Serial 2>&1 }
        $state = Invoke-QemuBenchmarkAdb -AdbPath $AdbPath -Serial $Serial -Arguments @('get-state')
        if ($state.Text -match '(?im)^device$') {
            $boot = Invoke-QemuBenchmarkAdb -AdbPath $AdbPath -Serial $Serial -Arguments @('shell', 'getprop', 'sys.boot_completed')
            if ($boot.Text -match '(?im)^1$') { return $true }
        }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)
    return $false
}

function New-QemuBenchmarkArguments {
    param(
        [object]$Config,
        [string]$DiskPath,
        [string]$RepositoryRoot
    )

    $qemu = $Config.android.qemu
    $adb = $Config.android.adb
    $display = if ([bool]$qemu.showWindow) { 'default' } else { 'none' }
    $arguments = [System.Collections.Generic.List[string]]::new()
    $arguments.Add('-name')
    $arguments.Add([string]$qemu.windowTitle)
    $arguments.Add('-machine')
    $arguments.Add($(if ($qemu.machine) { [string]$qemu.machine } else { 'q35' }))
    $arguments.Add('-accel')
    $arguments.Add('whpx')
    $arguments.Add('-m')
    $arguments.Add([string][math]::Max(512, [int]$qemu.memoryMb))
    $arguments.Add('-smp')
    $arguments.Add([string][math]::Max(1, [math]::Min([int]$qemu.cpuCores, [Environment]::ProcessorCount)))
    $arguments.Add('-drive')
    $arguments.Add("file=$DiskPath,if=virtio,format=qcow2")
    $arguments.Add('-boot')
    $arguments.Add('order=c')
    $arguments.Add('-netdev')
    $arguments.Add("user,id=neonewsnet,hostfwd=tcp:$($adb.host):$($adb.hostPort)-:$($adb.guestPort)")
    $arguments.Add('-device')
    $arguments.Add('virtio-net-pci,netdev=neonewsnet')
    $arguments.Add('-qmp')
    $arguments.Add("tcp:127.0.0.1:$($qemu.qmpPort),server=on,wait=off")
    $arguments.Add('-no-reboot')
    $arguments.Add('-vga')
    $arguments.Add($(if ($qemu.gpu) { [string]$qemu.gpu } else { 'std' }))
    $arguments.Add('-display')
    $arguments.Add($display)
    if ($Config.android.optimization.audioOutput) {
        $arguments.Add('-audiodev')
        $arguments.Add('driver=dsound,id=neonewsaudio')
        $arguments.Add('-device')
        $arguments.Add('AC97,audiodev=neonewsaudio')
    }
    $imageConfigured = [string]$Config.android.qemu.androidImage
    if (-not [string]::IsNullOrWhiteSpace($imageConfigured)) {
        $image = if ([System.IO.Path]::IsPathRooted($imageConfigured)) { $imageConfigured } else { Join-Path $RepositoryRoot ($imageConfigured -replace '/', '\') }
        if (Test-Path -LiteralPath $image) {
            $arguments.Insert(0, $image)
            $arguments.Insert(0, '-cdrom')
        }
    }
    return $arguments.ToArray()
}

function Start-QemuBenchmarkProcess {
    param(
        [string]$Executable,
        [string[]]$Arguments,
        [string]$WorkingDirectory
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $Executable
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    foreach ($argument in $Arguments) { [void]$startInfo.ArgumentList.Add([string]$argument) }
    return [System.Diagnostics.Process]::Start($startInfo)
}

function Stop-QemuBenchmarkProcess {
    param(
        [System.Diagnostics.Process]$Process,
        [int]$QmpPort,
        [int]$TimeoutSeconds = 20
    )

    if (-not $Process) { return $true }
    try {
        $client = [System.Net.Sockets.TcpClient]::new()
        $connectTask = $client.ConnectAsync('127.0.0.1', $QmpPort)
        if ($connectTask.Wait(2000) -and $client.Connected) {
            $stream = $client.GetStream()
            $stream.ReadTimeout = 2000
            $greeting = New-Object byte[] 1024
            try { $null = $stream.Read($greeting, 0, $greeting.Length) } catch { }
            foreach ($command in @('{"execute":"qmp_capabilities"}', '{"execute":"quit"}')) {
                $payload = [System.Text.Encoding]::UTF8.GetBytes("$command`r`n")
                $stream.Write($payload, 0, $payload.Length)
                $stream.Flush()
            }
            $stream.Dispose()
        }
        $client.Dispose()
    } catch { }

    if (-not $Process.HasExited -and -not $Process.WaitForExit([math]::Max(5000, $TimeoutSeconds * 1000))) {
        try { $Process.Kill() } catch { }
        $null = $Process.WaitForExit(5000)
    }
    $exited = $Process.HasExited
    $Process.Dispose()
    return $exited
}

function Get-QemuBenchmarkLines {
    param([string]$Text, [int]$Count = 30)
    return @($Text -split "`r?`n" | Select-Object -First $Count)
}

function Get-QemuBenchmarkMetrics {
    param(
        [string]$AdbPath,
        [string]$Serial,
        [object]$Config
    )

    $read = {
        param([string[]]$Arguments)
        (Invoke-QemuBenchmarkAdb -AdbPath $AdbPath -Serial $Serial -Arguments $Arguments).Text
    }
    [ordered]@{
        release = & $read @('shell', 'getprop', 'ro.build.version.release')
        apiLevel = & $read @('shell', 'getprop', 'ro.build.version.sdk')
        abi = & $read @('shell', 'getprop', 'ro.product.cpu.abi')
        abiList = & $read @('shell', 'getprop', 'ro.product.cpu.abilist')
        logicalSize = & $read @('shell', 'wm', 'size')
        logicalDensity = & $read @('shell', 'wm', 'density')
        memory = Get-QemuBenchmarkLines -Text (& $read @('shell', 'dumpsys', 'meminfo')) -Count 30
        graphics = Get-QemuBenchmarkLines -Text (& $read @('shell', 'dumpsys', 'gfxinfo')) -Count 30
        packagePresent = ((& $read @('shell', 'pm', 'path', [string]$Config.neonews.packageName)) -match '^package:')
        activity = & $read @('shell', 'dumpsys', 'activity', 'activities')
    }
}
