[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$RepositoryRoot,
    [string]$ConfigPath,
    [string]$Serial,
    [switch]$DownloadOfficial,
    [int]$BootTimeoutSeconds = 180,
    [int]$RebootTimeoutSeconds = 180,
    [string]$ReportPath = 'reports/nativebridge-official-provisioning.json'
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
}
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $RepositoryRoot 'config\runtime.json'
}
$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding utf8 | ConvertFrom-Json

function Resolve-ConfiguredPath([string]$ConfiguredPath) {
    if ([System.IO.Path]::IsPathRooted($ConfiguredPath)) { return $ConfiguredPath }
    return [System.IO.Path]::GetFullPath((Join-Path $RepositoryRoot ($ConfiguredPath -replace '/', '\')))
}

function Get-ConfiguredValue {
    param(
        [object]$Object,
        [string]$Name,
        [object]$Default
    )
    if ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]) {
        $value = $Object.PSObject.Properties[$Name].Value
        if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value)) { return $value }
    }
    return $Default
}

function Test-NonEmptyFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try { return (Get-Item -LiteralPath $Path).Length -gt 0 } catch { return $false }
}

function Test-Sha256([string]$Value) {
    return -not [string]::IsNullOrWhiteSpace($Value) -and $Value -match '^[0-9a-fA-F]{64}$'
}

function Invoke-AdbResult([string[]]$Arguments) {
    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& $script:AdbPath @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previous }
    [pscustomobject]@{
        ExitCode = $exitCode
        Text = (($output | Out-String).Trim())
    }
}

function Invoke-Guest([string[]]$Arguments) {
    return Invoke-AdbResult (@('-s', $script:Serial, 'shell') + $Arguments)
}

function Save-Report {
    param([object]$Report)
    $reportPath = if ([System.IO.Path]::IsPathRooted($ReportPath)) { $ReportPath } else { Join-Path $RepositoryRoot $ReportPath }
    $directory = Split-Path -Parent $reportPath
    if ($directory -and -not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    $Report | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath $reportPath -Encoding utf8
    return $reportPath
}

function New-ArtifactRecord {
    param(
        [string]$Variant,
        [string]$Architecture,
        [string]$FileName,
        [string]$ArtifactPath,
        [string]$OfficialUrl,
        [int64]$ExpectedSize,
        [string]$ExpectedSha256,
        [string]$GuestPath
    )
    [ordered]@{
        component = 'Native Bridge / Houdini'
        variant = $Variant
        architecture = $Architecture
        function = 'Android-x86 Native Bridge ARM translation'
        fileName = $FileName
        localPath = $ArtifactPath
        officialUrl = $OfficialUrl
        expectedSize = $ExpectedSize
        expectedSha256 = $ExpectedSha256
        guestPath = $GuestPath
        downloadedThisRun = $false
        present = $false
        actualSize = $null
        actualSha256 = $null
        verified = $false
    }
}

function Ensure-OfficialArtifact {
    param([System.Collections.IDictionary]$Artifact)
    $allowedUrls = @(
        'http://dl.android-x86.org/houdini/7_y/houdini.sfs',
        'http://dl.android-x86.org/houdini/7_z/houdini.sfs'
    )
    if ($Artifact.officialUrl -notin $allowedUrls) {
        throw "EXTERNAL_ARTIFACT_REQUIRED: origem não permitida para $($Artifact.fileName): $($Artifact.officialUrl). Nenhum mirror será consultado."
    }
    if (-not (Test-Sha256 $Artifact.expectedSha256)) {
        throw "EXTERNAL_ARTIFACT_REQUIRED: SHA-256 esperado ausente ou inválido para $($Artifact.fileName)."
    }

    if (-not (Test-Path -LiteralPath $Artifact.localPath -PathType Leaf)) {
        if (-not $DownloadOfficial) {
            throw "EXTERNAL_ARTIFACT_REQUIRED: componente=Native Bridge; arquivo=$($Artifact.fileName); variante=$($Artifact.variant); arquitetura=$($Artifact.architecture); função=Android-x86 Native Bridge ARM translation; origem tentada=$($Artifact.officialUrl); motivo=artefato local ausente e DownloadOfficial não foi solicitado."
        }
        $directory = Split-Path -Parent $Artifact.localPath
        if ($directory -and -not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
        $temporaryPath = $Artifact.localPath + '.download'
        try {
            Invoke-WebRequest -UseBasicParsing -Uri $Artifact.officialUrl -OutFile $temporaryPath
            $downloadedHash = (Get-FileHash -LiteralPath $temporaryPath -Algorithm SHA256).Hash
            $downloadedSize = (Get-Item -LiteralPath $temporaryPath).Length
            if ($downloadedSize -ne $Artifact.expectedSize -or -not $downloadedHash.Equals($Artifact.expectedSha256, [StringComparison]::OrdinalIgnoreCase)) {
                throw "artefato baixado não corresponde ao tamanho/SHA-256 oficial: size=$downloadedSize/$($Artifact.expectedSize); sha256=$downloadedHash/$($Artifact.expectedSha256)"
            }
            Move-Item -LiteralPath $temporaryPath -Destination $Artifact.localPath -Force
            $Artifact.downloadedThisRun = $true
        }
        catch {
            if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue }
            throw "EXTERNAL_ARTIFACT_REQUIRED: componente=Native Bridge; arquivo=$($Artifact.fileName); variante=$($Artifact.variant); arquitetura=$($Artifact.architecture); função=Android-x86 Native Bridge ARM translation; origem tentada=$($Artifact.officialUrl); motivo=$($_.Exception.Message)"
        }
    }

    $Artifact.present = Test-NonEmptyFile $Artifact.localPath
    if (-not $Artifact.present) {
        throw "EXTERNAL_ARTIFACT_REQUIRED: componente=Native Bridge; arquivo=$($Artifact.fileName); variante=$($Artifact.variant); arquitetura=$($Artifact.architecture); função=Android-x86 Native Bridge ARM translation; origem tentada=$($Artifact.officialUrl); motivo=arquivo ausente ou vazio após aquisição."
    }
    $Artifact.actualSize = (Get-Item -LiteralPath $Artifact.localPath).Length
    $Artifact.actualSha256 = (Get-FileHash -LiteralPath $Artifact.localPath -Algorithm SHA256).Hash
    $Artifact.verified = $Artifact.actualSize -eq $Artifact.expectedSize -and $Artifact.actualSha256.Equals($Artifact.expectedSha256, [StringComparison]::OrdinalIgnoreCase)
    if (-not $Artifact.verified) {
        throw "EXTERNAL_ARTIFACT_REQUIRED: componente=Native Bridge; arquivo=$($Artifact.fileName); variante=$($Artifact.variant); arquitetura=$($Artifact.architecture); função=Android-x86 Native Bridge ARM translation; origem tentada=$($Artifact.officialUrl); motivo=arquivo local diverge do tamanho/SHA-256 oficial: size=$($Artifact.actualSize)/$($Artifact.expectedSize); sha256=$($Artifact.actualSha256)/$($Artifact.expectedSha256)"
    }
}

function Wait-ForBoot([int]$TimeoutSeconds) {
    $deadline = (Get-Date).ToUniversalTime().AddSeconds($TimeoutSeconds)
    while ((Get-Date).ToUniversalTime() -lt $deadline) {
        $state = Invoke-AdbResult @('-s', $script:Serial, 'get-state')
        if ($state.ExitCode -eq 0 -and $state.Text -eq 'device') {
            $boot = Invoke-Guest @('getprop', 'sys.boot_completed')
            if ($boot.ExitCode -eq 0 -and $boot.Text -eq '1') { return $true }
        }
        Start-Sleep -Seconds 2
    }
    return $false
}

function Read-GuestFileEvidence([string]$Path) {
    $ls = Invoke-Guest @('ls', '-ln', $Path)
    $length = $null
    if ($ls.Text -match '(?m)^\S+\s+\S+\s+\S+\s+\S+\s+(?<length>\d+)\s+') { $length = [int64]$Matches['length'] }
    $hash = Invoke-Guest @('sha256sum', $Path)
    $sha256 = if ($hash.Text -match '(?m)^(?<sha>[0-9a-fA-F]{64})\s+') { $Matches['sha'].ToUpperInvariant() } else { $null }
    [ordered]@{
        path = $Path
        exists = $ls.ExitCode -eq 0
        length = if ($null -eq $length) { 0 } else { $length }
        sha256 = $sha256
        lsExitCode = $ls.ExitCode
        hashExitCode = $hash.ExitCode
        detail = $ls.Text
    }
}

function Read-BridgeSnapshot([string]$Phase) {
    $scriptResult = Invoke-Guest @('sha256sum', $script:EnableScriptPath)
    $scriptContent = Invoke-Guest @('cat', $script:EnableScriptPath)
    $mounts = Invoke-Guest @('mount')
    $binfmtStatus = Invoke-Guest @('cat', '/proc/sys/fs/binfmt_misc/status')
    $armDyn = Invoke-Guest @('cat', '/proc/sys/fs/binfmt_misc/arm_dyn')
    $arm64Dyn = Invoke-Guest @('cat', '/proc/sys/fs/binfmt_misc/arm64_dyn')
    $scriptHash = if ($scriptResult.Text -match '(?m)^(?<sha>[0-9a-fA-F]{64})\s+') { $Matches['sha'].ToUpperInvariant() } else { $null }
    [ordered]@{
        phase = $Phase
        persistNativeBridge = (Invoke-Guest @('getprop', 'persist.sys.nativebridge')).Text
        nativeBridgeProperty = (Invoke-Guest @('getprop', 'ro.dalvik.vm.native.bridge')).Text
        guestAbi = (Invoke-Guest @('getprop', 'ro.product.cpu.abi')).Text
        guestAbiList = (Invoke-Guest @('getprop', 'ro.product.cpu.abilist')).Text
        zygote = (Invoke-Guest @('getprop', 'ro.zygote')).Text
        script = [ordered]@{
            path = $script:EnableScriptPath
            exists = $scriptResult.ExitCode -eq 0
            sha256 = $scriptHash
            expectedSha256 = $script:EnableScriptSha256
            sha256Matches = $scriptHash -and $scriptHash.Equals($script:EnableScriptSha256, [StringComparison]::OrdinalIgnoreCase)
            content = $scriptContent.Text
            hashExitCode = $scriptResult.ExitCode
            contentExitCode = $scriptContent.ExitCode
        }
        libNb32 = Read-GuestFileEvidence '/system/lib/libnb.so'
        libNb64 = Read-GuestFileEvidence '/system/lib64/libnb.so'
        houdini32 = Read-GuestFileEvidence '/system/lib/libhoudini.so'
        houdini64 = Read-GuestFileEvidence '/system/lib64/libhoudini.so'
        file32 = (Invoke-Guest @('file', '/system/lib/libhoudini.so')).Text
        file64 = (Invoke-Guest @('file', '/system/lib64/libhoudini.so')).Text
        mounts = @($mounts.Text -split "`r?`n" | Where-Object { $_ -match 'libhoudini|/system/lib/arm|/system/lib64/arm64|binfmt_misc' })
        binfmt = [ordered]@{
            status = $binfmtStatus.Text
            armDyn = $armDyn.Text
            arm64Dyn = $arm64Dyn.Text
            statusExitCode = $binfmtStatus.ExitCode
            armDynExitCode = $armDyn.ExitCode
            arm64DynExitCode = $arm64Dyn.ExitCode
        }
    }
}

$state = [ordered]@{
    timestamp = (Get-Date).ToUniversalTime().ToString('o')
    status = 'not-validated'
    transport = 'tcp'
    serial = $null
    officialSourcePolicy = 'allowlist-only; no random mirrors'
    mutations = @('mkdir /data/arm when absent', 'adb push verified Houdini SFS files', 'setprop persist.sys.nativebridge 1', 'execute /system/bin/enable_nativebridge', 'guest reboot')
    artifacts = @()
    preflight = $null
    enable = $null
    preReboot = $null
    reboot = $null
    postReboot = $null
}
$fullReportPath = $null

try {
    $script:AdbPath = Resolve-ConfiguredPath (Join-Path $config.android.tooling.sdkRoot $config.android.tooling.adbRelativePath)
    if (-not (Test-NonEmptyFile $script:AdbPath)) { throw "ADB não encontrado ou vazio: $script:AdbPath" }
    if ([string]::IsNullOrWhiteSpace($Serial)) { $Serial = "$($config.android.adb.host):$($config.android.adb.hostPort)" }
    $script:Serial = $Serial
    $state.serial = $Serial

    $official = $config.android.nativeBridge.officialProvisioning
    $script:EnableScriptPath = [string](Get-ConfiguredValue $official 'enableScriptPath' '/system/bin/enable_nativebridge')
    $script:EnableScriptSha256 = ([string](Get-ConfiguredValue $official 'enableScriptSha256' '')).ToUpperInvariant()
    if (-not (Test-Sha256 $script:EnableScriptSha256)) { throw 'Configuração Native Bridge sem SHA-256 forte do enable_nativebridge.' }

    $arm32 = Get-ConfiguredValue $official 'arm32' $null
    $arm64 = Get-ConfiguredValue $official 'arm64' $null
    $artifact32 = New-ArtifactRecord '7_y' 'ARM32' 'houdini7_y.sfs' (Resolve-ConfiguredPath (Get-ConfiguredValue $arm32 'artifactPath' 'packages/nativebridge/houdini7_y.sfs')) 'http://dl.android-x86.org/houdini/7_y/houdini.sfs' 37728256 '56FD08C448840578386A71819C07139122F0AF39F011059CE728EA0F3C60B665' '/data/arm/houdini7_y.sfs'
    $artifact64 = New-ArtifactRecord '7_z' 'ARM64' 'houdini7_z.sfs' (Resolve-ConfiguredPath (Get-ConfiguredValue $arm64 'artifactPath' 'packages/nativebridge/houdini7_z.sfs')) 'http://dl.android-x86.org/houdini/7_z/houdini.sfs' 37253120 '7EEDC42015E6FB84A11A406A099241EFCCC20D4E020D476335A5FDB6E69A33D2' '/data/arm/houdini7_z.sfs'
    $state.artifacts = @($artifact32, $artifact64)
    Ensure-OfficialArtifact $artifact32
    Ensure-OfficialArtifact $artifact64

    $server = Invoke-AdbResult @('start-server')
    $null = Invoke-AdbResult @('connect', $Serial)
    if ($server.ExitCode -ne 0 -or -not (Wait-ForBoot $BootTimeoutSeconds)) { throw "ADB/guest não ficou pronto em $Serial." }
    $rootBefore = Invoke-Guest @('id')
    $root = Invoke-AdbResult @('root')
    if ($root.ExitCode -ne 0) { throw "ADB root falhou: $($root.Text)" }
    Start-Sleep -Seconds 2
    if (-not (Wait-ForBoot $BootTimeoutSeconds)) { throw "Guest não voltou após adb root: $Serial." }
    $rootAfter = Invoke-Guest @('id')
    if ($rootAfter.ExitCode -ne 0 -or $rootAfter.Text -notmatch 'uid=0\(root\)') { throw "Root real não confirmado: $($rootAfter.Text)" }

    $state.preflight = [ordered]@{
        server = [ordered]@{ exitCode = $server.ExitCode; output = $server.Text }
        rootBefore = $rootBefore.Text
        root = [ordered]@{ exitCode = $root.ExitCode; output = $root.Text }
        rootAfter = $rootAfter.Text
        bridge = Read-BridgeSnapshot 'pre-provision'
    }
    if (-not $state.preflight.bridge.script.exists -or -not $state.preflight.bridge.script.sha256Matches) {
        throw "EXTERNAL_ARTIFACT_REQUIRED: /system/bin/enable_nativebridge ausente ou SHA-256 divergente; esperado=$script:EnableScriptSha256; encontrado=$($state.preflight.bridge.script.sha256)"
    }

    if (-not $PSCmdlet.ShouldProcess($Serial, 'provisionar Native Bridge oficial ARM32/ARM64 no guest descartável')) {
        $state.status = 'whatif'
        $fullReportPath = Save-Report $state
        $state | ConvertTo-Json -Depth 14
        return
    }

    $mkdir = Invoke-Guest @('mkdir', '-p', '/data/arm')
    if ($mkdir.ExitCode -ne 0) { throw "Não foi possível preparar /data/arm: $($mkdir.Text)" }
    foreach($artifact in @($artifact32, $artifact64)) {
        $remote = Invoke-Guest @('sha256sum', $artifact.guestPath)
        $remoteHash = if ($remote.Text -match '(?m)^(?<sha>[0-9a-fA-F]{64})\s+') { $Matches['sha'].ToUpperInvariant() } else { $null }
        if ($remoteHash -and $remoteHash.Equals($artifact.expectedSha256, [StringComparison]::OrdinalIgnoreCase)) {
            $artifact.push = [ordered]@{ skipped = $true; exitCode = 0; output = 'guest artifact already matches expected SHA-256' }
        }
        else {
            $push = & $script:AdbPath -s $Serial push $artifact.localPath $artifact.guestPath 2>&1
            $pushExitCode = $LASTEXITCODE
            $artifact.push = [ordered]@{ skipped = $false; exitCode = $pushExitCode; output = (($push | Out-String).Trim()) }
            if ($pushExitCode -ne 0) { throw "Falha ao enviar $($artifact.fileName): $($artifact.push.output)" }
        }
        $verify = Invoke-Guest @('sha256sum', $artifact.guestPath)
        $guestHash = if ($verify.Text -match '(?m)^(?<sha>[0-9a-fA-F]{64})\s+') { $Matches['sha'].ToUpperInvariant() } else { $null }
        $artifact.guestSha256 = $guestHash
        $artifact.guestSha256Matches = $guestHash -and $guestHash.Equals($artifact.expectedSha256, [StringComparison]::OrdinalIgnoreCase)
        if (-not $artifact.guestSha256Matches) { throw "Hash guest divergente para $($artifact.fileName): esperado=$($artifact.expectedSha256); encontrado=$guestHash" }
    }

    $setProp = Invoke-Guest @('setprop', 'persist.sys.nativebridge', '1')
    if ($setProp.ExitCode -ne 0) { throw "setprop persist.sys.nativebridge 1 falhou: $($setProp.Text)" }
    $enable = Invoke-Guest @('enable_nativebridge')
    $state.enable = [ordered]@{
        setprop = [ordered]@{ exitCode = $setProp.ExitCode; output = $setProp.Text; value = (Invoke-Guest @('getprop', 'persist.sys.nativebridge')).Text }
        command = [ordered]@{ command = 'enable_nativebridge'; exitCode = $enable.ExitCode; output = $enable.Text }
    }
    if ($enable.ExitCode -ne 0) { throw "enable_nativebridge falhou: $($enable.Text)" }
    $state.preReboot = Read-BridgeSnapshot 'post-provision-pre-reboot'
    if ($state.preReboot.persistNativeBridge -notmatch '^(1|true|yes|on)$' -or
        $state.preReboot.nativeBridgeProperty -ne 'libnb.so' -or
        $state.preReboot.houdini32.length -le 0 -or
        $state.preReboot.houdini64.length -le 0) {
        throw 'Native Bridge não passou na validação estrutural antes do reboot.'
    }

    $reboot = Invoke-Guest @('reboot')
    $state.reboot = [ordered]@{ command = 'adb shell reboot'; exitCode = $reboot.ExitCode; output = $reboot.Text; booted = $false }
    # Some Android-x86/QEMU combinations close the QEMU process on a guest
    # reboot when -no-reboot is active. In that case this script reports the
    # exact restart limitation instead of treating a disconnected ADB as pass.
    $state.reboot.booted = Wait-ForBoot $RebootTimeoutSeconds
    if (-not $state.reboot.booted) { throw 'Guest não voltou após reboot; reinicie o mesmo QEMU/overlay e execute a validação pós-reboot novamente.' }
    $state.postReboot = Read-BridgeSnapshot 'post-reboot'
    if ($state.postReboot.persistNativeBridge -notmatch '^(1|true|yes|on)$' -or
        $state.postReboot.nativeBridgeProperty -ne 'libnb.so' -or
        $state.postReboot.houdini32.length -le 0 -or
        $state.postReboot.houdini64.length -le 0) {
        throw 'Native Bridge não persistiu após reboot.'
    }
    $state.status = 'validated-structural-persistence'
    $fullReportPath = Save-Report $state
    $state | ConvertTo-Json -Depth 14
}
catch {
    $state.status = if ($_.Exception.Message -match '^EXTERNAL_ARTIFACT_REQUIRED') { 'EXTERNAL_ARTIFACT_REQUIRED' } else { 'not-validated' }
    $state.error = $_.Exception.Message
    try { $fullReportPath = Save-Report $state } catch { }
    if ($fullReportPath) { Write-Error "Native Bridge provisioning failed; report=$fullReportPath; $($_.Exception.Message)" }
    throw
}
