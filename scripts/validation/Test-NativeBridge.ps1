[CmdletBinding()]
param(
    [string]$RepositoryRoot,
    [string]$ApkPath,
    [string]$ReportPath = 'reports/nativebridge.json',
    [int]$TimeoutSeconds = 180,
    [int]$StabilitySeconds = 10,
    [int]$RestartCount = 1
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
}
$scriptRepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
. (Join-Path $scriptRepositoryRoot 'scripts\validation\ValidationEvidence.Common.ps1')
$fullReportPath = Initialize-ValidationReport -ReportPath (Resolve-ValidationReportPath -RepositoryRoot $RepositoryRoot -ReportPath $ReportPath) -Validator 'Test-NativeBridge'
if ($StabilitySeconds -lt 1) { throw 'StabilitySeconds precisa ser pelo menos 1 segundo.' }
$config = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'config\runtime.json') -Raw -Encoding utf8 | ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace($ApkPath)) {
    $ApkPath = Join-Path $RepositoryRoot ($config.neonews.apkPath -replace '/', '\')
    if (-not (Test-Path -LiteralPath $ApkPath)) { $ApkPath = Join-Path $RepositoryRoot 'app.apk' }
}
if (-not [System.IO.Path]::IsPathRooted($ApkPath)) { $ApkPath = Join-Path $RepositoryRoot $ApkPath }
if (-not (Test-Path -LiteralPath $ApkPath)) { throw "APK oficial não encontrado: $ApkPath" }
$adbPath = Join-Path $RepositoryRoot ($config.android.tooling.sdkRoot + '\' + $config.android.tooling.adbRelativePath)
if (-not (Test-Path -LiteralPath $adbPath)) { throw "ADB não encontrado em $adbPath. O teste não usa PATH nem baixa ferramentas." }
$serial = "$($config.android.adb.host):$($config.android.adb.hostPort)"
$packageName = $config.neonews.packageName
$activityName = [string]$config.neonews.launchActivity
if ($activityName -match '/') { $activityName = ($activityName -split '/')[-1] }
if ($activityName.StartsWith('.')) { $activityName = $activityName.Substring(1) }
if ($activityName.StartsWith("$packageName.", [System.StringComparison]::Ordinal)) { $activityName = $activityName.Substring($packageName.Length + 1) }
$activity = "$packageName/.$activityName"

function Invoke-AdbResult([string[]]$Arguments) {
    $output = & $adbPath @Arguments 2>&1
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Text = (($output | Out-String).Trim()) }
}

function Invoke-Adb([string[]]$Arguments) {
    return (Invoke-AdbResult $Arguments).Text
}

function Read-ApkUInt16([byte[]]$Data, [int]$Offset) {
    if ($Offset -lt 0 -or $Offset + 2 -gt $Data.Length) { throw "Leitura AXML fora dos limites em 0x$('{0:X}' -f $Offset)." }
    return [int]($Data[$Offset] -bor ([int]$Data[$Offset + 1] -shl 8))
}

function Read-ApkUInt32([byte[]]$Data, [int]$Offset) {
    if ($Offset -lt 0 -or $Offset + 4 -gt $Data.Length) { throw "Leitura AXML fora dos limites em 0x$('{0:X}' -f $Offset)." }
    return [uint32]($Data[$Offset] -bor ([uint32]$Data[$Offset + 1] -shl 8) -bor ([uint32]$Data[$Offset + 2] -shl 16) -bor ([uint32]$Data[$Offset + 3] -shl 24))
}

function Get-ApkAxmString {
    param(
        [byte[]]$Data,
        [int[]]$Offsets,
        [int]$StringsBase,
        [int]$PoolEnd,
        [bool]$Utf8,
        [uint32]$Index
    )

    if ($Index -eq [uint32]::MaxValue -or $Index -ge [uint32]$Offsets.Count) { return $null }
    $cursor = $StringsBase + $Offsets[[int]$Index]
    if ($cursor -lt $StringsBase -or $cursor -ge $PoolEnd) { throw 'String pool AXML fora dos limites.' }
    if ($Utf8) {
        $firstLength = [int]$Data[$cursor++]
        if (($firstLength -band 0x80) -ne 0) { $firstLength = (($firstLength -band 0x7F) -shl 8) -bor [int]$Data[$cursor++] }
        $byteLength = [int]$Data[$cursor++]
        if (($byteLength -band 0x80) -ne 0) { $byteLength = (($byteLength -band 0x7F) -shl 8) -bor [int]$Data[$cursor++] }
        if ($cursor -lt 0 -or $cursor + $byteLength -gt $PoolEnd) { throw 'String UTF-8 AXML fora dos limites.' }
        return [System.Text.Encoding]::UTF8.GetString($Data, $cursor, $byteLength)
    }

    $characterLength = Read-ApkUInt16 $Data $cursor
    $cursor += 2
    if (($characterLength -band 0x8000) -ne 0) {
        $secondLength = Read-ApkUInt16 $Data $cursor
        $cursor += 2
        $characterLength = (($characterLength -band 0x7FFF) -shl 16) -bor $secondLength
    }
    $byteLength = $characterLength * 2
    if ($cursor -lt 0 -or $cursor + $byteLength -gt $PoolEnd) { throw 'String UTF-16 AXML fora dos limites.' }
    return [System.Text.Encoding]::Unicode.GetString($Data, $cursor, $byteLength)
}

function Read-ApkManifestIdentity([string]$Path) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $entry = $archive.GetEntry('AndroidManifest.xml')
        if ($null -eq $entry) { throw 'O APK não contém AndroidManifest.xml.' }
        $entryStream = $entry.Open()
        $memory = [System.IO.MemoryStream]::new()
        try { $entryStream.CopyTo($memory); $data = $memory.ToArray() }
        finally { $memory.Dispose(); $entryStream.Dispose() }
    }
    finally { $archive.Dispose() }

    if ($data.Length -lt 8 -or (Read-ApkUInt16 $data 0) -ne 0x0003) { throw 'AndroidManifest.xml não está no formato AXML esperado.' }
    $xmlHeaderSize = Read-ApkUInt16 $data 2
    $xmlSize = [int](Read-ApkUInt32 $data 4)
    if ($xmlHeaderSize -lt 8 -or $xmlSize -gt $data.Length -or $xmlHeaderSize -gt $xmlSize) { throw 'Cabeçalho XML AXML inválido.' }

    $poolOffset = $xmlHeaderSize
    if ($poolOffset + 28 -gt $xmlSize -or (Read-ApkUInt16 $data $poolOffset) -ne 0x0001) { throw 'String pool AXML ausente ou inválido.' }
    $poolHeaderSize = Read-ApkUInt16 $data ($poolOffset + 2)
    $poolSize = [int](Read-ApkUInt32 $data ($poolOffset + 4))
    $stringCount = Read-ApkUInt32 $data ($poolOffset + 8)
    $flags = Read-ApkUInt32 $data ($poolOffset + 16)
    $stringsOffset = [int](Read-ApkUInt32 $data ($poolOffset + 20))
    if ($poolHeaderSize -lt 28 -or $poolSize -lt $poolHeaderSize -or $poolOffset + $poolSize -gt $xmlSize) { throw 'String pool AXML inválido.' }
    $offsetsBase = $poolOffset + $poolHeaderSize
    $offsetsEnd = $offsetsBase + ([int]$stringCount * 4)
    if ($offsetsBase -lt $poolOffset -or $offsetsEnd -gt $poolOffset + $poolSize) { throw 'Índices do string pool AXML inválidos.' }
    $offsets = New-Object int[] ([int]$stringCount)
    for ($index = 0; $index -lt [int]$stringCount; $index++) { $offsets[$index] = [int](Read-ApkUInt32 $data ($offsetsBase + $index * 4)) }
    $stringsBase = $poolOffset + $stringsOffset
    $poolEnd = $poolOffset + $poolSize
    $utf8 = (($flags -band 0x00000100) -ne 0)
    $packageName = $null
    $versionName = $null
    $versionCode = $null
    $offset = $poolOffset + $poolSize
    while ($offset + 8 -le $xmlSize) {
        $chunkType = Read-ApkUInt16 $data $offset
        $chunkHeaderSize = Read-ApkUInt16 $data ($offset + 2)
        $chunkSize = [int](Read-ApkUInt32 $data ($offset + 4))
        if ($chunkHeaderSize -lt 8 -or $chunkSize -lt $chunkHeaderSize -or $offset + $chunkSize -gt $xmlSize) { throw "Chunk AXML inválido em 0x$('{0:X}' -f $offset)." }
        if ($chunkType -eq 0x0102 -and $chunkHeaderSize -ge 16) {
            $extension = $offset + $chunkHeaderSize
            $nameIndex = Read-ApkUInt32 $data ($extension + 4)
            if ((Get-ApkAxmString $data $offsets $stringsBase $poolEnd $utf8 $nameIndex) -eq 'manifest') {
                $attributeStart = Read-ApkUInt16 $data ($extension + 8)
                $attributeSize = Read-ApkUInt16 $data ($extension + 10)
                $attributeCount = Read-ApkUInt16 $data ($extension + 12)
                if ($attributeSize -lt 20) { throw 'Atributos AXML inválidos.' }
                $attributes = $extension + $attributeStart
                $attributesEnd = $attributes + $attributeCount * $attributeSize
                if ($attributes -lt $extension -or $attributesEnd -gt $offset + $chunkSize) { throw 'Atributos AXML fora dos limites.' }
                for ($attributeIndex = 0; $attributeIndex -lt $attributeCount; $attributeIndex++) {
                    $attribute = $attributes + $attributeIndex * $attributeSize
                    $attributeName = Get-ApkAxmString $data $offsets $stringsBase $poolEnd $utf8 (Read-ApkUInt32 $data ($attribute + 4))
                    $rawValueIndex = Read-ApkUInt32 $data ($attribute + 8)
                    $valueType = [int]$data[$attribute + 15]
                    $valueData = Read-ApkUInt32 $data ($attribute + 16)
                    $value = if ($rawValueIndex -ne [uint32]::MaxValue) { Get-ApkAxmString $data $offsets $stringsBase $poolEnd $utf8 $rawValueIndex } elseif ($valueType -eq 0x03) { Get-ApkAxmString $data $offsets $stringsBase $poolEnd $utf8 $valueData } else { $null }
                    switch ($attributeName) {
                        'package' { $packageName = $value }
                        'versionName' { $versionName = $value }
                        'versionCode' { if ($valueType -eq 0x10 -or $valueType -eq 0x11) { $versionCode = [uint32]$valueData } }
                    }
                }
            }
        }
        $offset += $chunkSize
    }
    if ([string]::IsNullOrWhiteSpace($packageName)) { throw 'AndroidManifest.xml não contém o atributo package.' }
    return [pscustomobject]@{ PackageName = $packageName; VersionName = $versionName; VersionCode = $versionCode }
}

function Read-Asn1Node {
    param(
        [byte[]]$Data,
        [ref]$Offset,
        [int]$Limit
    )

    $start = [int]$Offset.Value
    if ($start -lt 0 -or $start + 2 -gt $Limit) { throw 'ASN.1 fora dos limites.' }
    $tag = [int]$Data[$Offset.Value]
    $Offset.Value++
    $lengthByte = [int]$Data[$Offset.Value]
    $Offset.Value++
    if (($lengthByte -band 0x80) -eq 0) {
        $length = $lengthByte
    }
    else {
        $lengthOctets = $lengthByte -band 0x7F
        if ($lengthOctets -eq 0 -or $lengthOctets -gt 4 -or $Offset.Value + $lengthOctets -gt $Limit) { throw 'Comprimento ASN.1 inválido.' }
        $length = 0
        for ($index = 0; $index -lt $lengthOctets; $index++) { $length = ($length -shl 8) -bor [int]$Data[$Offset.Value]; $Offset.Value++ }
    }
    $valueOffset = [int]$Offset.Value
    $end = $valueOffset + $length
    if ($length -lt 0 -or $end -gt $Limit) { throw 'Conteúdo ASN.1 fora dos limites.' }
    $Offset.Value = $end
    return [pscustomobject]@{ Tag = $tag; Start = $start; ValueOffset = $valueOffset; End = $end; Constructed = (($tag -band 0x20) -ne 0) }
}

function Find-ApkCertificateSha256 {
    param(
        [byte[]]$Data,
        [int]$Offset,
        [int]$Limit
    )

    while ($Offset -lt $Limit) {
        $cursor = $Offset
        $node = Read-Asn1Node $Data ([ref]$cursor) $Limit
        if ($node.Tag -eq 0x30) {
            try {
                $encoded = [byte[]]$Data[$node.Start..($node.End - 1)]
                $certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($encoded)
                try {
                    $sha256 = [System.Security.Cryptography.SHA256]::Create()
                    try { return ([BitConverter]::ToString($sha256.ComputeHash($certificate.RawData)) -replace '-', '').ToUpperInvariant() }
                    finally { $sha256.Dispose() }
                }
                finally { $certificate.Dispose() }
            }
            catch [System.Security.Cryptography.CryptographicException] { }
            catch [System.ArgumentException] { }
        }
        if ($node.Constructed -or $node.Tag -eq 0xA0) {
            $found = Find-ApkCertificateSha256 $Data $node.ValueOffset $node.End
            if ($found) { return $found }
        }
        $Offset = $node.End
    }
    return $null
}

function Read-ApkCertificateSha256([string]$Path) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $entry = $archive.Entries | Where-Object {
            $_.FullName -match '(?i)^META-INF/[^/]+\.(RSA|DSA|EC)$'
        } | Select-Object -First 1
        if ($null -eq $entry) { return $null }
        $entryStream = $entry.Open()
        $memory = [System.IO.MemoryStream]::new()
        try { $entryStream.CopyTo($memory); $data = $memory.ToArray() }
        finally { $memory.Dispose(); $entryStream.Dispose() }
    }
    finally { $archive.Dispose() }
    if ($data.Length -eq 0) { return $null }
    return Find-ApkCertificateSha256 $data 0 $data.Length
}

function Test-ActivityRunning([string]$Dump) {
    $candidates = @(
        $activity,
        "$packageName/.$activityName",
        "$packageName/$packageName.$activityName"
    )
    $foregroundMarkers = 'mResumedActivity|topResumedActivity|ResumedActivity|mFocusedActivity|mCurrentFocus'
    return @($Dump -split "`r?`n" | Where-Object {
        $line = $_
        ($line -match "(?i)$foregroundMarkers") -and @($candidates | Where-Object { $_ -and $line.IndexOf([string]$_, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 }).Count -gt 0
    }).Count -gt 0
}

$serverResult = Invoke-AdbResult @('start-server')
if ($serverResult.ExitCode -ne 0) { throw "ADB start-server falhou: $($serverResult.Text)" }
$null = Invoke-AdbResult @('connect', $serial)
$deadline = (Get-Date).ToUniversalTime().AddSeconds($TimeoutSeconds)
$state = ''
$boot = ''
while ((Get-Date).ToUniversalTime() -lt $deadline) {
    if ($serial -match ':') { $null = Invoke-Adb @('connect', $serial) }
    $stateResult = Invoke-AdbResult @('-s', $serial, 'get-state')
    $state = $stateResult.Text
    if ($stateResult.ExitCode -eq 0 -and $state -eq 'device') {
        $bootResult = Invoke-AdbResult @('-s', $serial, 'shell', 'getprop', 'sys.boot_completed')
        $boot = $bootResult.Text
        if ($bootResult.ExitCode -eq 0 -and $boot -eq '1') { break }
    }
    Start-Sleep -Seconds 2
}
if ($state -ne 'device' -or $boot -ne '1') { throw "ADB não ficou pronto. serial=$serial state=$state boot=$boot" }

$propertyResult = Invoke-AdbResult @('-s', $serial, 'shell', 'getprop', 'ro.dalvik.vm.native.bridge')
$guestAbiResult = Invoke-AdbResult @('-s', $serial, 'shell', 'getprop', 'ro.product.cpu.abi')
$guestAbiListResult = Invoke-AdbResult @('-s', $serial, 'shell', 'getprop', 'ro.product.cpu.abilist')
$abi2Result = Invoke-AdbResult @('-s', $serial, 'shell', 'getprop', 'ro.product.cpu.abi2')
$releaseResult = Invoke-AdbResult @('-s', $serial, 'shell', 'getprop', 'ro.build.version.release')
$apiLevelResult = Invoke-AdbResult @('-s', $serial, 'shell', 'getprop', 'ro.build.version.sdk')
$property = $propertyResult.Text
$guestAbi = $guestAbiResult.Text
$guestAbiList = $guestAbiListResult.Text
$abi2 = $abi2Result.Text
$release = $releaseResult.Text
$apiLevel = $apiLevelResult.Text
$propertyExitCodes = @($propertyResult, $guestAbiResult, $guestAbiListResult, $abi2Result, $releaseResult, $apiLevelResult) | ForEach-Object { [int]$_.ExitCode }
$guestPropertiesReadable = @($propertyExitCodes | Where-Object { $_ -ne 0 }).Count -eq 0
$guestIdentityMatches = $release -eq [string]$config.android.release -and $apiLevel -eq [string]$config.android.apiLevel
$bridgeReady = -not [string]::IsNullOrWhiteSpace($property) -and $property -ne '0' -and ($guestAbi -in @('x86', 'x86_64')) -and $guestAbiList -match '(?i)(^|,)(x86|x86_64)(,|$)'

$apkAbis = @()
if (Test-Path -LiteralPath $ApkPath) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ApkPath)
    try {
        $apkAbis = @($archive.Entries | ForEach-Object {
            if ($_.FullName -match '^lib/([^/]+)/') { $Matches[1] }
        } | Sort-Object -Unique)
    }
    finally { $archive.Dispose() }
}
$apkIdentity = Read-ApkManifestIdentity $ApkPath
if ($apkIdentity.PackageName -ne [string]$config.neonews.packageName) {
    throw "O APK oficial possui package '$($apkIdentity.PackageName)', esperado '$($config.neonews.packageName)'. Nenhuma instalação foi tentada."
}
if ($apkIdentity.VersionName -ne [string]$config.neonews.versionName -or [int64]$apkIdentity.VersionCode -ne [int64]$config.neonews.versionCode) {
    throw "O APK oficial possui versão '$($apkIdentity.VersionName)'/$($apkIdentity.VersionCode), esperada '$($config.neonews.versionName)'/$($config.neonews.versionCode). Nenhuma instalação foi tentada."
}
$expectedCertificateSha256 = ([string]$config.neonews.signingCertificateSha256 -replace '[^0-9A-Fa-f]', '').ToUpperInvariant()
if ($expectedCertificateSha256) {
    $actualCertificateSha256 = Read-ApkCertificateSha256 $ApkPath
    if (-not $actualCertificateSha256 -or $actualCertificateSha256 -ne $expectedCertificateSha256) {
        throw "A assinatura X.509 do APK oficial diverge da fingerprint autorizada. Encontrada='$actualCertificateSha256'; esperada='$expectedCertificateSha256'. Nenhuma instalação foi tentada."
    }
}
$preferredApkAbi = if ($config.android.nativeBridge.preferredAbi) { [string]$config.android.nativeBridge.preferredAbi } else { [string]$config.android.preferredApkAbi }
if ($apkAbis.Count -eq 0 -or ($preferredApkAbi -and $apkAbis -notcontains $preferredApkAbi)) {
    throw "O APK oficial não contém a ABI ARM autorizada '$preferredApkAbi'. ABIs encontradas: $($apkAbis -join ', '). Nenhuma instalação foi tentada."
}
if (@($apkAbis | Where-Object { $_ -in @('x86', 'x86_64') }).Count -gt 0) {
    throw "O APK oficial contém ABI x86/x86_64, que não é permitida no pacote ARM. ABIs encontradas: $($apkAbis -join ', '). Nenhuma instalação foi tentada."
}

$installOutput = ''
$installSucceeded = $false
if (Test-Path -LiteralPath $ApkPath) {
    $installResult = Invoke-AdbResult @('-s', $serial, 'install', '-r', $ApkPath)
    $installOutput = $installResult.Text
    $installExitCode = $installResult.ExitCode
    $installSucceeded = $installExitCode -eq 0 -and $installOutput -match '(?im)\bSuccess\b'
}
$packageDumpResult = Invoke-AdbResult @('-s', $serial, 'shell', 'dumpsys', 'package', $packageName)
$packageDump = $packageDumpResult.Text
$packageDumpExitCode = $packageDumpResult.ExitCode
$primaryCpuAbi = if ($packageDump -match 'primaryCpuAbi=([^\s]+)') { $Matches[1] } else { $null }
$selectedApkAbi = if ($primaryCpuAbi -and $apkAbis -contains $primaryCpuAbi -and $primaryCpuAbi -eq $preferredApkAbi) { $primaryCpuAbi } else { $null }
$launchOutput = ''
$launchSucceeded = $false
if ($installSucceeded -or $packageDump -match "Package \[$([regex]::Escape($packageName))\]") {
    $launchResult = Invoke-AdbResult @('-s', $serial, 'shell', 'am', 'start', '-W', '-n', $activity)
    $launchOutput = $launchResult.Text
    $launchExitCode = $launchResult.ExitCode
    $launchSucceeded = $launchExitCode -eq 0 -and $launchOutput -notmatch '(?im)(Error:|Exception|does not exist)'
}
Start-Sleep -Seconds ([math]::Max(1, $StabilitySeconds))
$activityDumpResult = Invoke-AdbResult @('-s', $serial, 'shell', 'dumpsys', 'activity', 'activities')
$activityDump = $activityDumpResult.Text
$activityDumpExitCode = $activityDumpResult.ExitCode
$activityRunning = $activityDumpExitCode -eq 0 -and (Test-ActivityRunning $activityDump)
$logcatResult = Invoke-AdbResult @('-s', $serial, 'shell', 'logcat', '-d', '-b', 'all', '-t', '240')
$logcat = $logcatResult.Text
$logcatExitCode = $logcatResult.ExitCode
$relevantLogcat = @($logcat -split "`r?`n" | Where-Object { $_ -match 'com\.in9midia\.neonews\.player|AndroidRuntime|linker|native bridge|SIGSEGV|FATAL|dex2oat|chromium|WebView' })
$failurePattern = 'UnsatisfiedLinkError|linker.*(error|fail)|SIGSEGV|FATAL EXCEPTION|dex2oat.*(error|fail)|zygote.*(error|fail)|chromium.*(error|fail)|WebView.*(error|fail)'
$initialErrors = @($relevantLogcat | Where-Object { $_ -match $failurePattern })
$runtimeStable = $guestPropertiesReadable -and $guestIdentityMatches -and $bridgeReady -and $installSucceeded -and $packageDumpExitCode -eq 0 -and $selectedApkAbi -and $launchSucceeded -and $activityRunning -and $logcatExitCode -eq 0 -and $initialErrors.Count -eq 0

$restartResults = New-Object System.Collections.Generic.List[object]
for ($restart = 1; $restart -le [math]::Max(0, $RestartCount) -and $runtimeStable; $restart++) {
    $rebootResult = Invoke-AdbResult @('-s', $serial, 'shell', 'reboot')
    $rebootOutput = $rebootResult.Text
    $rebootExitCode = $rebootResult.ExitCode
    $rebootBooted = $false
    $rebootDeadline = (Get-Date).ToUniversalTime().AddSeconds($TimeoutSeconds)
    do {
        if ($serial -match ':') { $null = Invoke-Adb @('connect', $serial) }
        $rebootStateResult = Invoke-AdbResult @('-s', $serial, 'get-state')
        $rebootState = $rebootStateResult.Text
        if ($rebootStateResult.ExitCode -eq 0 -and $rebootState -eq 'device') {
            $rebootBootResult = Invoke-AdbResult @('-s', $serial, 'shell', 'getprop', 'sys.boot_completed')
            $rebootBoot = $rebootBootResult.Text
            if ($rebootBootResult.ExitCode -eq 0 -and $rebootBoot -eq '1') { $rebootBooted = $true; break }
        }
        Start-Sleep -Seconds 2
    } while ((Get-Date).ToUniversalTime() -lt $rebootDeadline)

    $relaunchOutput = ''
    $relaunchExitCode = $null
    $relaunchSucceeded = $false
    $relaunchActivityRunning = $false
    $relaunchErrors = @()
    $relaunchActivityDumpExitCode = $null
    $relaunchLogcatExitCode = $null
    if ($rebootBooted) {
        $relaunchResult = Invoke-AdbResult @('-s', $serial, 'shell', 'am', 'start', '-W', '-n', $activity)
        $relaunchOutput = $relaunchResult.Text
        $relaunchExitCode = $relaunchResult.ExitCode
        $relaunchSucceeded = $relaunchExitCode -eq 0 -and $relaunchOutput -notmatch '(?im)(Error:|Exception|does not exist)'
        Start-Sleep -Seconds ([math]::Max(1, $StabilitySeconds))
        $relaunchActivityDumpResult = Invoke-AdbResult @('-s', $serial, 'shell', 'dumpsys', 'activity', 'activities')
        $relaunchActivityDumpExitCode = $relaunchActivityDumpResult.ExitCode
        $relaunchActivityRunning = $relaunchActivityDumpExitCode -eq 0 -and (Test-ActivityRunning $relaunchActivityDumpResult.Text)
        $relaunchLogcatResult = Invoke-AdbResult @('-s', $serial, 'shell', 'logcat', '-d', '-b', 'all', '-t', '240')
        $relaunchLogcatExitCode = $relaunchLogcatResult.ExitCode
        $relaunchErrors = @($relaunchLogcatResult.Text -split "`r?`n" | Where-Object { $_ -match $failurePattern })
    }
    $restartResults.Add([ordered]@{
        iteration = $restart
        rebootOutput = $rebootOutput
        rebootExitCode = $rebootExitCode
        booted = $rebootBooted
        launchSucceeded = $relaunchSucceeded
        launchExitCode = if ($null -ne $relaunchExitCode) { [int]$relaunchExitCode } else { $null }
        activityRunning = $relaunchActivityRunning
        activityDumpExitCode = $relaunchActivityDumpExitCode
        logcatExitCode = $relaunchLogcatExitCode
        relevantErrors = $relaunchErrors
        stable = $rebootExitCode -eq 0 -and $rebootBooted -and $relaunchSucceeded -and $relaunchActivityDumpExitCode -eq 0 -and $relaunchActivityRunning -and $relaunchLogcatExitCode -eq 0 -and $relaunchErrors.Count -eq 0
    })
}
$restartStable = @($restartResults | Where-Object { -not $_.stable }).Count -eq 0
$runtimeStable = $runtimeStable -and $restartStable

$report = [ordered]@{
    timestamp = (Get-Date).ToUniversalTime().ToString('o')
    status = if ($runtimeStable) { 'validated' } else { 'not-validated' }
    transport = 'tcp'
    serial = $serial
    androidRelease = $release
    androidApiLevel = $apiLevel
    guestIdentityMatches = $guestIdentityMatches
    guestAbi = $guestAbi
    guestAbiList = $guestAbiList
    nativeBridgeProperty = $property
    nativeBridgeAbi2 = $abi2
    nativeBridgeReady = $bridgeReady
    apkAbis = $apkAbis
    apkPackageName = $apkIdentity.PackageName
    apkVersionName = $apkIdentity.VersionName
    apkVersionCode = $apkIdentity.VersionCode
    apkIdentityMatches = $apkIdentity.PackageName -eq [string]$config.neonews.packageName -and $apkIdentity.VersionName -eq [string]$config.neonews.versionName -and [int64]$apkIdentity.VersionCode -eq [int64]$config.neonews.versionCode
    apkCertificateSha256 = $actualCertificateSha256
    apkSignatureMatches = [string]::IsNullOrWhiteSpace($expectedCertificateSha256) -or $actualCertificateSha256 -eq $expectedCertificateSha256
    selectedApkAbi = $selectedApkAbi
    installSucceeded = $installSucceeded
    primaryCpuAbi = $primaryCpuAbi
    launchSucceeded = $launchSucceeded
    activityRunning = $activityRunning
    runtimeStable = $runtimeStable
    stabilitySeconds = $StabilitySeconds
    guestPropertyExitCodes = $propertyExitCodes
    installExitCode = if ($null -ne $installExitCode) { [int]$installExitCode } else { $null }
    packageDumpExitCode = if ($null -ne $packageDumpExitCode) { [int]$packageDumpExitCode } else { $null }
    launchExitCode = if ($null -ne $launchExitCode) { [int]$launchExitCode } else { $null }
    activityDumpExitCode = $activityDumpExitCode
    logcatExitCode = $logcatExitCode
    restartCount = [math]::Max(0, $RestartCount)
    restartResults = @($restartResults)
    installOutput = $installOutput
    launchOutput = $launchOutput
    relevantLogcat = $relevantLogcat
}
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $fullReportPath -Encoding utf8
$report | ConvertTo-Json -Depth 8
if (-not $runtimeStable) { throw "Native Bridge não foi homologado: runtimeStable=false. Consulte $fullReportPath." }
