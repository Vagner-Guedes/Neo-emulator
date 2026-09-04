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
    $androidImage = & $resolve $Config.android.qemu.androidImage
    $provisioningState = & $resolve $Config.android.provisioning.statePath
    [pscustomobject]@{
        Adb = $adb
        Qemu = $qemu
        Disk = $disk
        AndroidImage = $androidImage
        ProvisioningState = $provisioningState
    }
}

function Test-QemuBenchmarkNonEmptyFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try { return (Get-Item -LiteralPath $Path).Length -gt 0 } catch { return $false }
}

function Assert-QemuBenchmarkProvisionedRuntime {
    param(
        [object]$Config,
        [object]$Paths
    )

    foreach ($entry in @(
        [pscustomobject]@{ Name = 'qemu'; Path = $Paths.Qemu },
        [pscustomobject]@{ Name = 'adb'; Path = $Paths.Adb },
        [pscustomobject]@{ Name = 'disk'; Path = $Paths.Disk },
        [pscustomobject]@{ Name = 'installerImage'; Path = $Paths.AndroidImage }
    )) {
        if (-not (Test-QemuBenchmarkNonEmptyFile $entry.Path)) {
            throw "Componente-base '$($entry.Name)' ausente ou vazio: $($entry.Path). Execute o provisionamento aprovado antes do benchmark."
        }
    }

    if (-not (Test-Path -LiteralPath $Paths.ProvisioningState -PathType Leaf)) {
        throw "Estado de provisionamento não encontrado: $($Paths.ProvisioningState)."
    }
    try { $state = Get-Content -LiteralPath $Paths.ProvisioningState -Raw -Encoding utf8 | ConvertFrom-Json }
    catch { throw "O estado de provisionamento não pôde ser lido: $($Paths.ProvisioningState). $($_.Exception.Message)" }
    if ([string]::IsNullOrWhiteSpace([string]$state.androidImageVersion) -or [string]$state.androidImageVersion -ne [string]$Config.android.release) {
        throw "A release do estado de provisionamento diverge da configuração: registrada=$($state.androidImageVersion); esperada=$($Config.android.release)."
    }
    if ([string]$state.imageHash -notmatch '^[0-9a-fA-F]{64}$') {
        throw "O estado de provisionamento não possui SHA-256 forte do disco persistente."
    }
    foreach ($name in @('qemu', 'adb', 'disk', 'installerImage')) {
        $record = $state.provenance.$name
        if ($null -eq $record -or [string]$record.sha256 -notmatch '^[0-9a-fA-F]{64}$' -or [string]::IsNullOrWhiteSpace([string]$record.origin)) {
            throw "A provenance do componente-base '$name' é ausente, fraca ou sem origem."
        }
    }
    foreach ($entry in @(
        [pscustomobject]@{ Name = 'qemu'; Path = $Paths.Qemu },
        [pscustomobject]@{ Name = 'adb'; Path = $Paths.Adb },
        [pscustomobject]@{ Name = 'installerImage'; Path = $Paths.AndroidImage }
    )) {
        $currentHash = (Get-FileHash -LiteralPath $entry.Path -Algorithm SHA256).Hash
        $registeredHash = [string]$state.provenance.($entry.Name).sha256
        if (-not $currentHash.Equals($registeredHash, [StringComparison]::OrdinalIgnoreCase)) {
            throw "O hash do componente-base '$($entry.Name)' diverge do provisionamento: registrado=$registeredHash; atual=$currentHash."
        }
    }
}

function Invoke-QemuBenchmarkAdb {
    param(
        [string]$AdbPath,
        [string]$Serial,
        [string[]]$Arguments,
        [int]$ServerPort = 5038
    )

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        # Windows PowerShell 5.1 surfaces native stderr as an ErrorRecord. An
        # adb daemon banner or an offline-device diagnostic is expected input
        # to the evidence collector, not a terminating PowerShell exception.
        $ErrorActionPreference = 'Continue'
        $raw = @(& $AdbPath -P $ServerPort -s $Serial @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    [pscustomobject]@{
        ExitCode = $exitCode
        Text = (($raw | Out-String).Trim())
    }
}

function Invoke-QemuBenchmarkAdbHost {
    param(
        [string]$AdbPath,
        [string[]]$Arguments,
        [int]$ServerPort = 5038
    )

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $raw = @(& $AdbPath -P $ServerPort @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
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

    return (Wait-QemuBenchmarkMilestones -AdbPath $AdbPath -Serial $Serial -TimeoutSeconds $TimeoutSeconds).booted
}

function Wait-QemuBenchmarkMilestones {
    param(
        [string]$AdbPath,
        [string]$Serial,
        [int]$TimeoutSeconds
    )

    $startedAt = Get-Date
    $null = Invoke-QemuBenchmarkAdbHost -AdbPath $AdbPath -Arguments @('start-server')
    $deadline = $startedAt.AddSeconds($TimeoutSeconds)
    $adbReadyAt = $null
    $bootedAt = $null
    do {
        if ($Serial -match ':') { $null = Invoke-QemuBenchmarkAdbHost -AdbPath $AdbPath -Arguments @('connect', $Serial) }
        $state = Invoke-QemuBenchmarkAdb -AdbPath $AdbPath -Serial $Serial -Arguments @('get-state')
        if ($state.Text -match '(?im)^device$') {
            if ($null -eq $adbReadyAt) { $adbReadyAt = Get-Date }
            $boot = Invoke-QemuBenchmarkAdb -AdbPath $AdbPath -Serial $Serial -Arguments @('shell', 'getprop', 'sys.boot_completed')
            if ($boot.Text -match '(?im)^1$') { $bootedAt = Get-Date; break }
        }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)

    [ordered]@{
        adbReady = $null -ne $adbReadyAt
        booted = $null -ne $bootedAt
        bootedAt = $bootedAt
        adbReadySeconds = if ($adbReadyAt) { [math]::Round(($adbReadyAt - $startedAt).TotalSeconds, 2) } else { $null }
        bootSeconds = if ($bootedAt) { [math]::Round(($bootedAt - $startedAt).TotalSeconds, 2) } else { $null }
        adbToBootSeconds = if ($adbReadyAt -and $bootedAt) { [math]::Round(($bootedAt - $adbReadyAt).TotalSeconds, 2) } else { $null }
    }
}

function New-QemuBenchmarkArguments {
    param(
        [object]$Config,
        [string]$DiskPath,
        [string]$RepositoryRoot
    )

    $qemu = $Config.android.qemu
    $adb = $Config.android.adb
    # The bundled Windows QEMU build exposes the host window through GTK;
    # keep benchmark launches equivalent to the production backend so kiosk
    # and window-ownership measurements exercise the same display path.
    $display = if ([bool]$qemu.showWindow) { 'gtk' } else { 'none' }
    $requestedMemoryMb = [math]::Max(512, [int]$qemu.memoryMb)
    $availableMemoryMb = 0
    $gcMemoryInfoMethod = [System.GC].GetMethod('GetGCMemoryInfo', [type[]]@())
    if ($gcMemoryInfoMethod) {
        try { $availableMemoryMb = [math]::Floor(($gcMemoryInfoMethod.Invoke($null, $null).TotalAvailableMemoryBytes) / 1MB) } catch { $availableMemoryMb = 0 }
    }
    if ($availableMemoryMb -le 0) {
        try {
            $operatingSystem = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
            $availableMemoryMb = [math]::Floor(([double]$operatingSystem.TotalVisibleMemorySize * 1KB) / 1MB)
        }
        catch { $availableMemoryMb = 0 }
    }
    $memoryLimitMb = if ($availableMemoryMb -gt 0) { [math]::Max(512, [int]($availableMemoryMb * 0.75)) } else { $requestedMemoryMb }
    $effectiveMemoryMb = [math]::Min($requestedMemoryMb, $memoryLimitMb)
    $arguments = [System.Collections.Generic.List[string]]::new()
    $arguments.Add('-name')
    $arguments.Add([string]$qemu.windowTitle)
    $arguments.Add('-machine')
    $arguments.Add($(if ($qemu.machine) { [string]$qemu.machine } else { 'pc' }))
    $arguments.Add('-accel')
    $arguments.Add('whpx')
    $arguments.Add('-rtc')
    $arguments.Add('base=utc')
    $qemuExecutable = [string]$qemu.executable
    if (-not [System.IO.Path]::IsPathRooted($qemuExecutable)) {
        $qemuExecutable = [System.IO.Path]::GetFullPath((Join-Path $RepositoryRoot ($qemuExecutable -replace '/', '\')))
    }
    $qemuExecutableDirectory = Split-Path -Parent $qemuExecutable
    $qemuShareDirectory = Join-Path $qemuExecutableDirectory 'share'
    $arguments.Add('-L')
    $arguments.Add($qemuShareDirectory)
    $arguments.Add('-m')
    $arguments.Add([string]$effectiveMemoryMb)
    $arguments.Add('-smp')
    $arguments.Add([string][math]::Max(1, [math]::Min([int]$qemu.cpuCores, [Environment]::ProcessorCount)))
    $arguments.Add('-drive')
    $arguments.Add("file=$DiskPath,if=ide,format=qcow2")
    $arguments.Add('-boot')
    $arguments.Add('order=c')
    $arguments.Add('-netdev')
    $networkId = if ($qemu.networkId) { [string]$qemu.networkId } else { 'neonewsnet' }
    $networkCidr = if ($qemu.networkCidr) { [string]$qemu.networkCidr } else { '10.0.2.0/24' }
    $guestAddress = if ($qemu.guestAddress) { [string]$qemu.guestAddress } else { '10.0.2.15' }
    $nicModel = if ($qemu.nicModel) { [string]$qemu.nicModel } else { 'e1000' }
    if ($networkId -match '[\s,]' -or $networkCidr -match '[\s,]' -or $nicModel -match '[\s,]') {
        throw 'A configuração de rede do QEMU contém um token inválido.'
    }
    if ($networkCidr -notmatch '^\d{1,3}(?:\.\d{1,3}){3}/(?:[0-9]|[12]\d|3[0-2])$') {
        throw "O CIDR networkCidr do QEMU precisa ser IPv4: $networkCidr"
    }
    $guestIp = $null
    if (-not [System.Net.IPAddress]::TryParse($guestAddress, [ref]$guestIp) -or $guestIp.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
        throw "O endereço guestAddress do QEMU precisa ser IPv4: $guestAddress"
    }
    $arguments.Add("user,id=$networkId,net=$networkCidr,dhcpstart=$guestAddress,hostfwd=tcp:$($adb.host):$($adb.hostPort)-${guestAddress}:$($adb.guestPort)")
    $arguments.Add('-device')
    $arguments.Add("$nicModel,netdev=$networkId,id=neonewsnic")
    $arguments.Add('-qmp')
    $arguments.Add("tcp:127.0.0.1:$($qemu.qmpPort),server=on,wait=off")
    $arguments.Add('-monitor')
    $arguments.Add('none')
    $arguments.Add('-serial')
    $arguments.Add('none')
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
    # The installer image belongs to provisioning. Normal benchmark boots use
    # only the persistent qcow2, so an update cannot accidentally boot from an
    # ISO or mutate the guest setup.
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
    # Windows PowerShell 5.1 runs on .NET Framework, whose
    # ProcessStartInfo has no ArgumentList property. The configured runtime
    # paths may contain spaces, so quote each argument for the Win32 parser.
    $startInfo.Arguments = (($Arguments | ForEach-Object {
        $value = [string]$_
        if ($value -match '[\s"]') { '"' + $value.Replace('"', '\"') + '"' } else { $value }
    }) -join ' ')
    return [System.Diagnostics.Process]::Start($startInfo)
}

function Read-QemuQmpLine {
    param([System.IO.StreamReader]$Reader)

    try {
        while ($true) {
            $line = $Reader.ReadLine()
            if ($null -eq $line) { return $null }
            if (-not [string]::IsNullOrWhiteSpace($line)) { return $line }
        }
    }
    catch {
        return $null
    }
}

function Read-QemuQmpResponse {
    param(
        [System.IO.StreamReader]$Reader,
        [int]$MaxMessages = 32
    )

    for ($index = 0; $index -lt [math]::Max(1, $MaxMessages); $index++) {
        $line = Read-QemuQmpLine $Reader
        if ($null -eq $line) { return $null }
        try {
            $message = $line | ConvertFrom-Json
            $returnProperty = $message.PSObject.Properties['return']
            $errorProperty = $message.PSObject.Properties['error']
            if ($null -ne $returnProperty -or $null -ne $errorProperty) { return $line }
        }
        catch {
            # Preserve malformed JSON as the command response so the caller
            # rejects it instead of accidentally skipping a protocol error.
            return $line
        }
        # QMP events and other asynchronous messages do not acknowledge the
        # command that was just sent. Continue until a response is observed.
    }
    return $null
}

function Test-QemuQmpSuccess {
    param([string]$Message)

    if ([string]::IsNullOrWhiteSpace($Message)) { return $false }
    try {
        $response = $Message | ConvertFrom-Json
        $returnProperty = $response.PSObject.Properties['return']
        $errorProperty = $response.PSObject.Properties['error']
        return $null -ne $returnProperty -and $null -eq $errorProperty
    }
    catch {
        return $false
    }
}

function Stop-QemuBenchmarkProcess {
    param(
        [System.Diagnostics.Process]$Process,
        [int]$QmpPort,
        [int]$TimeoutSeconds = 20
    )

    if (-not $Process) {
        return [pscustomobject]@{
            Exited = $true
            QmpCapabilitiesSucceeded = $false
            QmpQuitSent = $false
            QmpQuitResponseSucceeded = $false
            QmpShutdownSucceeded = $false
            ForcedKill = $false
            QmpDetail = 'no-process'
        }
    }

    $qmpCapabilitiesSucceeded = $false
    $qmpQuitSent = $false
    $qmpQuitResponseSucceeded = $false
    $qmpDetail = 'QMP não conectado.'
    $client = $null
    $stream = $null
    $reader = $null
    $writer = $null
    try {
        $client = [System.Net.Sockets.TcpClient]::new()
        $connectTask = $client.ConnectAsync('127.0.0.1', $QmpPort)
        if ($connectTask.Wait(2000) -and $client.Connected) {
            $stream = $client.GetStream()
            $stream.ReadTimeout = 2000
            $qmpEncoding = [System.Text.UTF8Encoding]::new($false)
            $reader = [System.IO.StreamReader]::new($stream, $qmpEncoding, $false, 4096, $true)
            $writer = [System.IO.StreamWriter]::new($stream, $qmpEncoding, 4096, $true)
            $greeting = Read-QemuQmpLine $reader
            if ([string]::IsNullOrWhiteSpace($greeting)) {
                $qmpDetail = 'QMP não retornou o greeting JSON.'
            }
            else {
                $writer.WriteLine('{"execute":"qmp_capabilities"}')
                $writer.Flush()
                $capabilitiesResponse = Read-QemuQmpResponse $reader
                $qmpCapabilitiesSucceeded = Test-QemuQmpSuccess $capabilitiesResponse
                if (-not $qmpCapabilitiesSucceeded) {
                    $qmpDetail = "QMP qmp_capabilities sem retorno de sucesso: $capabilitiesResponse"
                }
                else {
                    $writer.WriteLine('{"execute":"quit"}')
                    $writer.Flush()
                    $qmpQuitSent = $true
                    $quitResponse = Read-QemuQmpResponse $reader
                    $qmpQuitResponseSucceeded = Test-QemuQmpSuccess $quitResponse
                    if ($qmpQuitResponseSucceeded) {
                        $qmpDetail = 'QMP qmp_capabilities e resposta de quit confirmadas.'
                    }
                    else {
                        $qmpDetail = "QMP quit sem retorno de sucesso: $quitResponse"
                    }
                }
            }
        }
        else {
            $qmpDetail = "QMP não aceitou conexão na porta $QmpPort."
        }
    }
    catch {
        $qmpDetail = "Falha ao negociar QMP: $($_.Exception.Message)"
    }
    finally {
        if ($writer) { try { $writer.Dispose() } catch { } }
        if ($reader) { try { $reader.Dispose() } catch { } }
        if ($stream) { try { $stream.Dispose() } catch { } }
        if ($client) { try { $client.Dispose() } catch { } }
    }

    $forcedKill = $false
    try {
        if (-not $Process.HasExited -and -not $Process.WaitForExit([math]::Max(5000, $TimeoutSeconds * 1000))) {
            try { $Process.Kill() } catch { }
            $forcedKill = $true
            $null = $Process.WaitForExit(5000)
        }
    }
    catch {
        $qmpDetail = "$qmpDetail Falha ao aguardar QEMU: $($_.Exception.Message)"
    }
    $exited = $false
    try { $exited = $Process.HasExited } catch { }
    $qmpShutdownSucceeded = $qmpCapabilitiesSucceeded -and $qmpQuitSent -and $qmpQuitResponseSucceeded -and $exited -and -not $forcedKill
    $Process.Dispose()
    return [pscustomobject]@{
        Exited = $exited
        QmpCapabilitiesSucceeded = $qmpCapabilitiesSucceeded
        QmpQuitSent = $qmpQuitSent
        QmpQuitResponseSucceeded = $qmpQuitResponseSucceeded
        QmpShutdownSucceeded = $qmpShutdownSucceeded
        ForcedKill = $forcedKill
        QmpDetail = $qmpDetail
    }
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
    $packageName = [string]$Config.neonews.packageName
    $packageDump = & $read @('shell', 'dumpsys', 'package', $packageName)
    $activityDump = & $read @('shell', 'dumpsys', 'activity', 'activities')
    [ordered]@{
        release = & $read @('shell', 'getprop', 'ro.build.version.release')
        apiLevel = & $read @('shell', 'getprop', 'ro.build.version.sdk')
        abi = & $read @('shell', 'getprop', 'ro.product.cpu.abi')
        abiList = & $read @('shell', 'getprop', 'ro.product.cpu.abilist')
        logicalSize = & $read @('shell', 'wm', 'size')
        logicalDensity = & $read @('shell', 'wm', 'density')
        memory = Get-QemuBenchmarkLines -Text (& $read @('shell', 'dumpsys', 'meminfo')) -Count 30
        graphics = Get-QemuBenchmarkLines -Text (& $read @('shell', 'dumpsys', 'gfxinfo')) -Count 30
        packagePresent = ((& $read @('shell', 'pm', 'path', $packageName)) -match '^package:')
        packageVersion = if ($packageDump -match 'versionName=([^\s]+)') { $Matches[1] } else { $null }
        primaryCpuAbi = if ($packageDump -match 'primaryCpuAbi=([^\s]+)') { $Matches[1] } else { $null }
        activity = $activityDump
    }
}

function Start-QemuBenchmarkNeoNews {
    param(
        [string]$AdbPath,
        [string]$Serial,
        [object]$Config,
        [int]$TimeoutSeconds = 120
    )

    $packageName = [string]$Config.neonews.packageName
    $configuredActivity = [string]$Config.neonews.launchActivity
    $activityName = if ($configuredActivity -match '/') { ($configuredActivity -split '/')[-1] } else { $configuredActivity }
    if ($activityName.StartsWith('.')) { $activityName = $activityName.Substring(1) }
    if ($activityName.StartsWith("$packageName.", [System.StringComparison]::Ordinal)) { $activityName = $activityName.Substring($packageName.Length + 1) }
    $component = "$packageName/.$activityName"
    $path = Invoke-QemuBenchmarkAdb -AdbPath $AdbPath -Serial $Serial -Arguments @('shell', 'pm', 'path', $packageName)
    if ($path.ExitCode -ne 0 -or $path.Text -notmatch '(?m)^package:') {
        return [ordered]@{ packagePresent = $false; launchSucceeded = $false; activityRunning = $false; component = $component; detail = $path.Text }
    }
    $null = Invoke-QemuBenchmarkAdb -AdbPath $AdbPath -Serial $Serial -Arguments @('shell', 'am', 'force-stop', $packageName)
    $startedAt = Get-Date
    $start = Invoke-QemuBenchmarkAdb -AdbPath $AdbPath -Serial $Serial -Arguments @('shell', 'am', 'start', '-W', '-n', $component)
    $launchSucceeded = $start.ExitCode -eq 0 -and $start.Text -notmatch '(?i)Error:|Exception|does not exist'
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $activityRunning = $false
    while ($launchSucceeded -and (Get-Date) -lt $deadline) {
        $dump = Invoke-QemuBenchmarkAdb -AdbPath $AdbPath -Serial $Serial -Arguments @('shell', 'dumpsys', 'activity', 'activities')
        $activityRunning = Test-QemuBenchmarkActivityRunning -Dump $dump.Text -Component $component
        if ($activityRunning) { break }
        Start-Sleep -Seconds 1
    }
    [ordered]@{
        packagePresent = $true
        launchSucceeded = $launchSucceeded
        activityRunning = $activityRunning
        component = $component
        launchSeconds = if ($activityRunning) { [math]::Round(((Get-Date) - $startedAt).TotalSeconds, 2) } else { $null }
        startOutput = $start.Text
    }
}

function Test-QemuBenchmarkActivityRunning {
    param(
        [string]$Dump,
        [string]$Component
    )

    if ([string]::IsNullOrWhiteSpace($Dump) -or [string]::IsNullOrWhiteSpace($Component)) { return $false }
    $parts = $Component -split '/', 2
    if ($parts.Count -ne 2) { return $false }
    $packageName = $parts[0]
    $activityName = $parts[1] -replace '^\.', ''
    $candidates = @(
        "$packageName/.$activityName",
        "$packageName/$activityName",
        "$packageName/$packageName.$activityName"
    )
    $foregroundMarkers = 'mResumedActivity|topResumedActivity|ResumedActivity|mFocusedActivity|mCurrentFocus'
    foreach ($line in ($Dump -split "`r?`n")) {
        if ($line -match "(?i)$foregroundMarkers" -and @($candidates | Where-Object { $line.IndexOf([string]$_, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 }).Count -gt 0) { return $true }
    }
    return $false
}

function Get-QemuHostMetrics {
    param(
        [System.Diagnostics.Process]$Process,
        [int]$SampleSeconds = 2
    )

    if (-not $Process) { return [ordered]@{ processAlive = $false } }
    try {
        $Process.Refresh()
        $beforeCpu = $Process.TotalProcessorTime.TotalSeconds
        $beforeAt = Get-Date
        Start-Sleep -Seconds ([math]::Max(1, $SampleSeconds))
        $Process.Refresh()
        $afterCpu = $Process.TotalProcessorTime.TotalSeconds
        $elapsed = ((Get-Date) - $beforeAt).TotalSeconds
        [ordered]@{
            processAlive = -not $Process.HasExited
            workingSetBytes = $Process.WorkingSet64
            privateMemoryBytes = $Process.PrivateMemorySize64
            cpuSeconds = [math]::Round($afterCpu, 3)
            cpuPercentOfHost = if ($elapsed -gt 0) { [math]::Round((($afterCpu - $beforeCpu) / $elapsed / [math]::Max(1, [Environment]::ProcessorCount)) * 100, 2) } else { $null }
            sampleSeconds = [math]::Round($elapsed, 2)
        }
    }
    catch {
        [ordered]@{ processAlive = $false; error = $_.Exception.Message }
    }
}

function Test-QemuBenchmarkStability {
    param(
        [System.Diagnostics.Process]$Process,
        [string]$AdbPath,
        [string]$Serial,
        [string]$ActivityComponent,
        [int]$DurationSeconds = 60,
        [int]$PollSeconds = 5
    )

    $samples = New-Object System.Collections.Generic.List[object]
    $deadline = (Get-Date).AddSeconds([math]::Max(0, $DurationSeconds))
    do {
        $processAlive = $false
        try { $Process.Refresh(); $processAlive = -not $Process.HasExited } catch { }
        $adbState = Invoke-QemuBenchmarkAdb -AdbPath $AdbPath -Serial $Serial -Arguments @('get-state')
        $activityRunning = $false
        if ($adbState.Text -match '(?im)^device$') {
            $activityDump = Invoke-QemuBenchmarkAdb -AdbPath $AdbPath -Serial $Serial -Arguments @('shell', 'dumpsys', 'activity', 'activities')
            $shortComponent = if ($ActivityComponent -match '/') {
                $parts = $ActivityComponent -split '/', 2
                "$($parts[0])/.$(($parts[1] -replace '^\.', ''))"
            } else { $ActivityComponent }
            $activityRunning = Test-QemuBenchmarkActivityRunning -Dump $activityDump.Text -Component $ActivityComponent
            if (-not $activityRunning -and $shortComponent -ne $ActivityComponent) {
                $activityRunning = Test-QemuBenchmarkActivityRunning -Dump $activityDump.Text -Component $shortComponent
            }
        }
        $samples.Add([ordered]@{ at = (Get-Date).ToUniversalTime().ToString('o'); processAlive = $processAlive; adbState = $adbState.Text; activityRunning = $activityRunning })
        if ((Get-Date) -lt $deadline) { Start-Sleep -Seconds ([math]::Max(1, $PollSeconds)) }
    } while ((Get-Date) -lt $deadline)
    $unstableSampleCount = @($samples | Where-Object {
        -not $_.processAlive -or
        $_.adbState -notmatch '(?im)^device$' -or
        -not $_.activityRunning
    }).Count
    [ordered]@{
        durationSeconds = [math]::Max(0, $DurationSeconds)
        samples = $samples.ToArray()
        stable = [bool]($unstableSampleCount -eq 0)
    }
}
