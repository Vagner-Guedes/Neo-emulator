[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('Audit', 'Apply', 'Rollback')]
    [string]$Mode = 'Audit',
    [string]$ConfigPath,
    [string]$PolicyPath,
    [string]$PlanPath = 'reports/android-debloat-plan.json',
    [string]$ReportPath = 'reports/android-optimization-result.json',
    [string]$InventoryPath = 'reports/android-packages-before.txt',
    [string]$ComparisonPath = 'reports/android-optimization-result.md',
    [string]$Serial,
    [int]$BootTimeoutSeconds = 180,
    [int]$SynthesisTimeoutSeconds = 90,
    [string]$SnapshotPath,
    [switch]$RunFullValidation
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $PSScriptRoot '..\..\config\runtime.json'
}
if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    throw "Configuração não encontrada: $ConfigPath"
}

$configPathFull = (Resolve-Path -LiteralPath $ConfigPath).Path
$repositoryRoot = [System.IO.Directory]::GetParent([System.IO.Directory]::GetParent($configPathFull).FullName).FullName
$config = Get-Content -LiteralPath $configPathFull -Raw -Encoding utf8 | ConvertFrom-Json

function Resolve-RepositoryPath {
    param([string]$ConfiguredPath)
    if ([string]::IsNullOrWhiteSpace($ConfiguredPath)) { return $null }
    if ([System.IO.Path]::IsPathRooted($ConfiguredPath)) { return [System.IO.Path]::GetFullPath($ConfiguredPath) }
    return [System.IO.Path]::GetFullPath((Join-Path $repositoryRoot ($ConfiguredPath -replace '/', '\')))
}

if ([string]::IsNullOrWhiteSpace($PolicyPath)) {
    $PolicyPath = if ($config.android.optimization.policyPath) { [string]$config.android.optimization.policyPath } else { 'config/android-package-policy.json' }
}
if ($config.android.optimization.inventoryPath -and $InventoryPath -eq 'reports/android-packages-before.txt') { $InventoryPath = [string]$config.android.optimization.inventoryPath }
if ($config.android.optimization.planPath -and $PlanPath -eq 'reports/android-debloat-plan.json') { $PlanPath = [string]$config.android.optimization.planPath }
if ($config.android.optimization.resultPath -and $ReportPath -eq 'reports/android-optimization-result.json') { $ReportPath = [string]$config.android.optimization.resultPath }
if ($config.android.optimization.comparisonPath -and $ComparisonPath -eq 'reports/android-optimization-result.md') { $ComparisonPath = [string]$config.android.optimization.comparisonPath }
if ([string]::IsNullOrWhiteSpace($SnapshotPath)) {
    $SnapshotPath = if ($config.android.optimization.snapshotPath) { [string]$config.android.optimization.snapshotPath } else { 'runtime/android/backups/neonews-before-debloat.qcow2' }
}

$policyFullPath = Resolve-RepositoryPath $PolicyPath
$planFullPath = Resolve-RepositoryPath $PlanPath
$reportFullPath = Resolve-RepositoryPath $ReportPath
$inventoryFullPath = Resolve-RepositoryPath $InventoryPath
$comparisonFullPath = Resolve-RepositoryPath $ComparisonPath
$snapshotFullPath = Resolve-RepositoryPath $SnapshotPath
$logFullPath = Resolve-RepositoryPath $(if ($config.android.optimization.logPath) { [string]$config.android.optimization.logPath } else { 'logs/android-optimization.log' })

foreach ($path in @($policyFullPath, $planFullPath, $reportFullPath, $inventoryFullPath, $comparisonFullPath, $logFullPath)) {
    $parent = Split-Path -Parent $path
    if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
}

$adbRelativePath = Join-Path ([string]$config.android.tooling.sdkRoot) ([string]$config.android.tooling.adbRelativePath)
$script:adbPath = Resolve-RepositoryPath $adbRelativePath
if (-not (Test-Path -LiteralPath $script:adbPath -PathType Leaf)) {
    throw "ADB não encontrado em $script:adbPath. O otimizador não usa PATH nem baixa ferramentas."
}
if ([string]::IsNullOrWhiteSpace($Serial)) {
    $Serial = if ([string]$config.android.adb.transport -eq 'tcp') {
        "$($config.android.adb.host):$($config.android.adb.hostPort)"
    } elseif (-not [string]::IsNullOrWhiteSpace([string]$config.android.adb.emulatorSerial)) {
        [string]$config.android.adb.emulatorSerial
    } else {
        "emulator-$($config.android.emulator.validationPort)"
    }
}
$script:Serial = $Serial

$script:result = [ordered]@{
    timestamp = [DateTimeOffset]::UtcNow.ToString('o')
    mode = $Mode
    status = 'NotOptimized'
    transport = [string]$config.android.adb.transport
    serial = $Serial
    policyPath = $policyFullPath
    planPath = $planFullPath
    inventoryPath = $inventoryFullPath
    snapshotPath = $snapshotFullPath
    policyBackupPath = $null
    voiceProtection = [ordered]@{
        enabled = $true
        baselineValidated = $false
        postChangeValidated = $false
        packages = @()
        failures = @()
    }
    appliedGroups = @()
    rollback = [ordered]@{ attempted = $false; succeeded = $false; packages = @(); detail = '' }
    fullValidation = [ordered]@{ requested = [bool]$RunFullValidation; status = 'not-run' }
}

function Write-AtomicText {
    param([string]$Path, [string]$Text)
    $temporaryPath = "$Path.$PID.tmp"
    Set-Content -LiteralPath $temporaryPath -Value $Text -Encoding utf8
    Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
}

function Write-JsonReport {
    param([string]$Path, [object]$Value)
    Write-AtomicText -Path $Path -Text ($Value | ConvertTo-Json -Depth 20)
}

function Add-OptimizationLog {
    param([string]$Event, [string]$Package = '', [string]$Detail = '')
    $line = "{0} {1}{2}{3}" -f [DateTimeOffset]::UtcNow.ToString('o'), $Event, $(if ($Package) { " $Package" } else { '' }), $(if ($Detail) { " $Detail" } else { '' })
    Add-Content -LiteralPath $logFullPath -Value $line -Encoding utf8
}

function Invoke-AdbResult {
    param([string[]]$Arguments)
    $output = & $script:adbPath @Arguments 2>&1
    [pscustomobject]@{
        ExitCode = [int]$LASTEXITCODE
        Text = (($output | Out-String).Trim())
    }
}

function Invoke-AdbShellResult {
    param([string[]]$Arguments)
    Invoke-AdbResult (@('-s', $script:Serial, 'shell') + @($Arguments))
}

function Get-TextLines {
    param([string]$Text)
    @($Text -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Get-PackageNames {
    param([string]$Text)
    @(Get-TextLines $Text | ForEach-Object { $_ -replace '^package:', '' } | Where-Object { $_ -match '^[A-Za-z0-9_.-]+$' } | Sort-Object -Unique)
}

function Get-PackageRecords {
    $result = Invoke-AdbShellResult @('pm', 'list', 'packages', '-f')
    if ($result.ExitCode -ne 0) { throw "Não foi possível inventariar os packages: $($result.Text)" }
    $records = New-Object System.Collections.Generic.List[object]
    foreach ($line in (Get-TextLines $result.Text)) {
        $entry = $line -replace '^package:', ''
        $separator = $entry.LastIndexOf('=')
        if ($separator -lt 1 -or $separator -ge ($entry.Length - 1)) { continue }
        $packagePath = $entry.Substring(0, $separator)
        $packageName = $entry.Substring($separator + 1)
        $records.Add([pscustomobject]@{
            package = $packageName
            path = $packagePath
            type = if ($packagePath -match '(?i)^/(system|vendor|product)/') { 'system' } else { 'third-party' }
        })
    }
    @($records | Sort-Object package -Unique)
}

function Wait-ForGuestReady {
    param([int]$TimeoutSeconds = 180)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastDetail = ''
    do {
        if ([string]$config.android.adb.transport -eq 'tcp') {
            $null = Invoke-AdbResult @('start-server')
            $null = Invoke-AdbResult @('connect', $script:Serial)
        }
        $state = Invoke-AdbResult @('-s', $script:Serial, 'get-state')
        if ($state.ExitCode -eq 0 -and $state.Text -eq 'device') {
            $boot = Invoke-AdbShellResult @('getprop', 'sys.boot_completed')
            $packages = Invoke-AdbShellResult @('pm', 'list', 'packages')
            $androidPath = Invoke-AdbShellResult @('pm', 'path', 'android')
            $settings = Invoke-AdbShellResult @('settings', 'get', 'global', 'window_animation_scale')
            $bootReady = $boot.ExitCode -eq 0 -and $boot.Text -match '(?m)^1$'
            $pmReady = $packages.ExitCode -eq 0 -and $packages.Text -match '(?m)^package:'
            $settingsReady = $settings.ExitCode -eq 0 -and $settings.Text -notmatch '(?i)error|unknown|exception'
            $dataReady = $androidPath.ExitCode -eq 0 -and $androidPath.Text -match '(?m)^package:'
            if ($bootReady -and $pmReady -and $settingsReady -and $dataReady) {
                return [pscustomobject]@{ ready = $true; bootCompleted = $true; packageManager = $true; settingsProvider = $true; data = $true; detail = 'Android, Package Manager, Settings Provider e filesystem prontos.' }
            }
            $lastDetail = "boot=$bootReady;pm=$pmReady;settings=$settingsReady;data=$dataReady"
        } else {
            $lastDetail = "ADB state=$($state.Text); exitCode=$($state.ExitCode)"
        }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)
    throw "Guest não atingiu o Ready Gate em $TimeoutSeconds segundos: $lastDetail"
}

function Get-Inventory {
    $commands = [ordered]@{
        'pm list packages' = @('pm', 'list', 'packages')
        'pm list packages -s' = @('pm', 'list', 'packages', '-s')
        'pm list packages -3' = @('pm', 'list', 'packages', '-3')
        'pm list packages -f' = @('pm', 'list', 'packages', '-f')
        'pm list packages -d' = @('pm', 'list', 'packages', '-d')
        'pm list packages -e' = @('pm', 'list', 'packages', '-e')
        'dumpsys package' = @('dumpsys', 'package')
        'dumpsys activity services' = @('dumpsys', 'activity', 'services')
        'dumpsys meminfo' = @('dumpsys', 'meminfo')
        'dumpsys procstats' = @('dumpsys', 'procstats')
        'dumpsys jobscheduler' = @('dumpsys', 'jobscheduler')
        'dumpsys alarm' = @('dumpsys', 'alarm')
        'dumpsys media.player' = @('dumpsys', 'media.player')
        'dumpsys audio' = @('dumpsys', 'audio')
        'dumpsys webviewupdate' = @('dumpsys', 'webviewupdate')
        'settings list global' = @('settings', 'list', 'global')
        'settings list secure' = @('settings', 'list', 'secure')
        'settings list system' = @('settings', 'list', 'system')
    }
    $sections = New-Object System.Collections.Generic.List[string]
    $results = [ordered]@{}
    foreach ($entry in $commands.GetEnumerator()) {
        $response = Invoke-AdbShellResult $entry.Value
        $results[$entry.Key] = $response
        $sections.Add("===== $($entry.Key) | exitCode=$($response.ExitCode) =====`r`n$($response.Text)")
    }
    Write-AtomicText -Path $inventoryFullPath -Text (($sections -join "`r`n`r`n") + "`r`n")
    $failed = @($results.GetEnumerator() | Where-Object { $_.Value.ExitCode -ne 0 } | ForEach-Object { $_.Key })
    if ($failed.Count -gt 0) { throw "O inventário não foi concluído; comandos com falha: $($failed -join ', ')" }
    [pscustomobject]@{ commands = $results; records = @(Get-PackageRecords) }
}

function Get-PropertyOrDefault {
    param([object]$Object, [string]$Name, [object]$Default)
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    $property.Value
}

function Get-StringArray {
    param([object]$Object, [string]$Name)
    $value = Get-PropertyOrDefault $Object $Name @()
    @($value | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
}

function Set-ObjectProperty {
    param([object]$Object, [string]$Name, [object]$Value)
    if ($null -eq $Object.PSObject.Properties[$Name]) {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    } else {
        $Object.$Name = $Value
    }
}

function Read-Policy {
    if (-not (Test-Path -LiteralPath $policyFullPath -PathType Leaf)) {
        return [pscustomobject]@{
            schemaVersion = 1
            generatedFromGuest = $null
            critical = @()
            required = @()
            optional = @()
            disabled = @()
            unknown = @()
            voiceProtection = [pscustomobject]@{
                enabled = $true
                expectedEngine = 'RHVoice'
                expectedLocale = 'pt-BR'
                synthesisRequired = $true
                discoveredPackages = @()
                baselineDefaultEngine = ''
                forbiddenAutomaticOperations = @('remove-voice-package', 'clear-voice-data', 'replace-voice-package', 'change-voice-engine')
            }
        }
    }
    $policy = Get-Content -LiteralPath $policyFullPath -Raw -Encoding utf8 | ConvertFrom-Json
    foreach ($name in @('critical', 'required', 'optional', 'disabled', 'unknown')) {
        if ($null -eq $policy.PSObject.Properties[$name]) { $policy | Add-Member -NotePropertyName $name -NotePropertyValue @() }
    }
    if ($null -eq $policy.PSObject.Properties['voiceProtection']) {
        $policy | Add-Member -NotePropertyName voiceProtection -NotePropertyValue ([pscustomobject]@{})
    }
    foreach ($name in @('enabled', 'expectedEngine', 'expectedLocale', 'synthesisRequired', 'discoveredPackages', 'baselineDefaultEngine')) {
        if ($null -eq $policy.voiceProtection.PSObject.Properties[$name]) {
            $default = switch ($name) { 'enabled' { $true } 'expectedEngine' { 'RHVoice' } 'expectedLocale' { 'pt-BR' } 'synthesisRequired' { $true } default { @() } }
            $policy.voiceProtection | Add-Member -NotePropertyName $name -NotePropertyValue $default
        }
    }
    $policy
}

function Find-RhvoiceEvidence {
    param([object[]]$Records)
    $matches = New-Object System.Collections.Generic.List[object]
    $recordByName = @{}
    foreach ($record in $Records) { $recordByName[[string]$record.package] = $record }
    $candidateNames = New-Object System.Collections.Generic.List[string]
    foreach ($record in $Records) {
        if ($record.package -match '(?i)rhvoice|tts|speech|svox|pico|voice') {
            $candidateNames.Add([string]$record.package)
        }
    }
    $packageDump = Invoke-AdbShellResult @('dumpsys', 'package')
    if ($packageDump.ExitCode -eq 0) {
        foreach ($block in ($packageDump.Text -split '(?m)(?=^\s*Package \[)')) {
            if ($block -notmatch '(?i)rhvoice') { continue }
            $nameMatch = [regex]::Match($block, '(?m)^\s*Package \[([^\]]+)\]')
            if ($nameMatch.Success -and -not $candidateNames.Contains($nameMatch.Groups[1].Value)) {
                $candidateNames.Add($nameMatch.Groups[1].Value)
            }
        }
    }
    foreach ($packageName in @($candidateNames | Sort-Object -Unique)) {
        $record = if ($recordByName.ContainsKey([string]$packageName)) { $recordByName[[string]$packageName] } else { $null }
        if ($null -eq $record) { continue }
        $dump = Invoke-AdbShellResult @('dumpsys', 'package', [string]$record.package)
        if ($dump.ExitCode -eq 0 -and (($record.package -match '(?i)rhvoice') -or ($dump.Text -match '(?i)rhvoice'))) {
            $packagePath = Invoke-AdbShellResult @('pm', 'path', [string]$record.package)
            $matches.Add([pscustomobject]@{
                    package = $record.package
                    path = $record.path
                    type = $record.type
                    packageDumpExitCode = $dump.ExitCode
                    packagePathExitCode = $packagePath.ExitCode
                    packagePath = $packagePath.Text
                    packagePathPresent = $packagePath.ExitCode -eq 0 -and $packagePath.Text -match '(?m)^package:'
                })
        }
    }
    $defaultResult = Invoke-AdbShellResult @('settings', 'get', 'secure', 'tts_default_synth')
    $localeResult = Invoke-AdbShellResult @('am', 'broadcast', '-a', 'android.speech.tts.engine.CHECK_TTS_DATA', '--es', 'language', 'por', '--es', 'country', 'BRA', '--es', 'variant', '')
    $disabledResult = Invoke-AdbShellResult @('pm', 'list', 'packages', '-d')
    $defaultEngine = $defaultResult.Text.Trim()
    $localeCheck = $localeResult.Text.Trim()
    $names = @($matches | ForEach-Object { [string]$_.package } | Sort-Object -Unique)
    [pscustomobject]@{
        packages = @($matches)
        packageNames = $names
        packageQueryExitCode = $packageDump.ExitCode
        defaultEngine = $defaultEngine
        defaultEngineExitCode = $defaultResult.ExitCode
        localeCheck = $localeCheck
        localeCheckExitCode = $localeResult.ExitCode
        disabledPackages = @(Get-PackageNames $disabledResult.Text)
        disabledQueryExitCode = $disabledResult.ExitCode
        present = $names.Count -gt 0
        defaultMatches = $defaultResult.ExitCode -eq 0 -and $defaultEngine -match '(?i)rhvoice'
        localeReady = $localeResult.ExitCode -eq 0 -and $localeCheck -match '(?i)result=1|CHECK_(VOICE|TTS)_DATA_PASS'
    }
}

function Test-VoicePackageSet {
    param([object]$Baseline, [object]$Current)
    $missing = @($Baseline.packageNames | Where-Object { $_ -notin @($Current.packageNames) })
    $disabled = @($Baseline.packageNames | Where-Object { $_ -in @($Current.disabledPackages) })
    $missingPaths = New-Object System.Collections.Generic.List[string]
    foreach ($package in @($Baseline.packageNames)) {
        $currentRecord = @($Current.packages | Where-Object { [string]$_.package -eq [string]$package } | Select-Object -First 1)
        if ($currentRecord.Count -eq 0 -or -not [bool]$currentRecord[0].packagePathPresent) {
            $missingPaths.Add([string]$package)
        }
    }
    [pscustomobject]@{ passed = $missing.Count -eq 0 -and $disabled.Count -eq 0 -and $missingPaths.Count -eq 0; missing = $missing; disabled = $disabled; missingPaths = @($missingPaths) }
}

function Invoke-TtsSynthesisGate {
    param([string]$Phase)
    $scriptPath = Join-Path $repositoryRoot 'scripts\validation\Test-TtsSynthesis.ps1'
    $ttsReportPath = Resolve-RepositoryPath "reports/tts-synthesis-optimization-$($Phase.ToLowerInvariant()).json"
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        return [pscustomobject]@{ passed = $false; status = 'missing-probe-script'; report = $ttsReportPath; detail = $scriptPath }
    }
    $invocationError = ''
    try {
        $null = & $scriptPath -ConfigPath $configPathFull -Serial $script:Serial -BootTimeoutSeconds $BootTimeoutSeconds -SynthesisTimeoutSeconds $SynthesisTimeoutSeconds -ReportPath $ttsReportPath -KeepProbe
    } catch {
        $invocationError = $_.Exception.Message
    }
    if (-not (Test-Path -LiteralPath $ttsReportPath -PathType Leaf)) {
        return [pscustomobject]@{ passed = $false; status = 'missing-report'; report = $ttsReportPath; detail = $invocationError }
    }
    try { $report = Get-Content -LiteralPath $ttsReportPath -Raw -Encoding utf8 | ConvertFrom-Json }
    catch { return [pscustomobject]@{ passed = $false; status = 'invalid-report'; report = $ttsReportPath; detail = $_.Exception.Message } }
    $audioBytes = [int64](Get-PropertyOrDefault (Get-PropertyOrDefault $report 'audio' $null) 'bytes' 0)
    $passed = [string]$report.status -eq 'validated' -and [bool]$report.defaultEngineMatches -and [bool]$report.probeLocale -and $audioBytes -gt 0
    [pscustomobject]@{
        passed = $passed
        status = [string](Get-PropertyOrDefault $report 'status' 'unknown')
        report = $ttsReportPath
        audioBytes = $audioBytes
        defaultEngineMatches = [bool](Get-PropertyOrDefault $report 'defaultEngineMatches' $false)
        probeLocale = [bool](Get-PropertyOrDefault $report 'probeLocale' $false)
        detail = if ($invocationError) { $invocationError } else { '' }
    }
}

function Assert-VoiceProtection {
    param([object]$Baseline, [string]$Phase, [switch]$RunSynthesis)
    $current = Find-RhvoiceEvidence -Records @(Get-PackageRecords)
    $setCheck = Test-VoicePackageSet -Baseline $Baseline -Current $current
    $sameDefault = $current.defaultEngine -eq [string]$Baseline.defaultEngine -and $current.defaultEngine -match '(?i)rhvoice'
    $passed = $setCheck.passed -and $sameDefault -and $current.defaultMatches
    $synthesis = $null
    if ($RunSynthesis) {
        $synthesis = Invoke-TtsSynthesisGate -Phase $Phase
        $passed = $passed -and $synthesis.passed
    } else {
        $passed = $passed -and $current.localeReady
    }
    $evidence = [ordered]@{
        phase = $Phase
        timestamp = [DateTimeOffset]::UtcNow.ToString('o')
        packages = @($current.packageNames)
        missingPackages = @($setCheck.missing)
        missingPackagePaths = @($setCheck.missingPaths)
        disabledPackages = @($setCheck.disabled)
        defaultEngineBefore = [string]$Baseline.defaultEngine
        defaultEngineAfter = [string]$current.defaultEngine
        defaultEngineUnchanged = $sameDefault
        localeCheck = [string]$current.localeCheck
        localeReady = [bool]$current.localeReady
        synthesis = $synthesis
        passed = $passed
    }
    if (-not $passed) {
        $failures = @()
        if ($setCheck.missing.Count -gt 0) { $failures += "Pacotes RHVoice ausentes: $($setCheck.missing -join ', ')" }
        if ($setCheck.disabled.Count -gt 0) { $failures += "Pacotes RHVoice desabilitados: $($setCheck.disabled -join ', ')" }
        if ($setCheck.missingPaths.Count -gt 0) { $failures += "Caminhos instalados dos pacotes RHVoice não puderam ser confirmados: $($setCheck.missingPaths -join ', ')" }
        if (-not $sameDefault) { $failures += "A engine padrão mudou ou não é RHVoice: antes='$($Baseline.defaultEngine)' depois='$($current.defaultEngine)'" }
        if (-not $current.localeReady) { $failures += 'O locale pt-BR da engine RHVoice não foi confirmado.' }
        if ($synthesis -and -not $synthesis.passed) { $failures += "A síntese RHVoice falhou: status=$($synthesis.status); bytes=$($synthesis.audioBytes)." }
        $evidence.failures = $failures
        throw "Proteção RHVoice falhou na fase '$Phase': $($failures -join ' | ')"
    }
    $evidence
}

function Assert-NoQemuUsingDisk {
    $disk = Resolve-RepositoryPath ([string]$config.android.qemu.disk)
    $diskNeedle = $disk.Replace('/', '\')
    $processes = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -match '(?i)^qemu-system.*\.exe$' -and [string]$_.CommandLine -like "*$diskNeedle*"
    })
    if ($processes.Count -gt 0) {
        throw 'O guest/QEMU ainda está usando o disco; pare o runtime antes de criar o snapshot de debloat.'
    }
}

function New-DebloatSnapshot {
    if (-not (Test-Path -LiteralPath $snapshotFullPath -PathType Leaf)) {
        $disk = Resolve-RepositoryPath ([string]$config.android.qemu.disk)
        if (-not (Test-Path -LiteralPath $disk -PathType Leaf) -or (Get-Item -LiteralPath $disk).Length -le 0) {
            throw "Disco Android persistente ausente ou vazio: $disk"
        }
        Assert-NoQemuUsingDisk
        $snapshotParent = Split-Path -Parent $snapshotFullPath
        if (-not (Test-Path -LiteralPath $snapshotParent -PathType Container)) { New-Item -ItemType Directory -Path $snapshotParent -Force | Out-Null }
        Copy-Item -LiteralPath $disk -Destination $snapshotFullPath -Force:$false
        Add-OptimizationLog 'SNAPSHOT_CREATED' '' "path=$snapshotFullPath sha256=$((Get-FileHash -LiteralPath $snapshotFullPath -Algorithm SHA256).Hash)"
    } else {
        if ((Get-Item -LiteralPath $snapshotFullPath).Length -le 0) { throw "Snapshot existente está vazio: $snapshotFullPath" }
        Add-OptimizationLog 'SNAPSHOT_REUSED' '' "path=$snapshotFullPath"
    }
    [ordered]@{ path = $snapshotFullPath; sha256 = (Get-FileHash -LiteralPath $snapshotFullPath -Algorithm SHA256).Hash; length = (Get-Item -LiteralPath $snapshotFullPath).Length }
}

function Get-CandidateReason {
    param([string]$Package)
    if ($Package -notmatch '(?i)(wallpaper|dream|daydream|screensaver|livewallpaper|email|exchange|calendar|contacts|dialer|telephony|sms|mms|messaging|camera|gallery|music|browser|calculator|deskclock|clock|voicedialer|demo|easteregg|feedback|print|bluetooth.*ui|nfc|maps|play|photos|gmail|drive|youtube|assistant|search|news|weather|sample|terminal|filemanager)') { return $null }
    "Candidato descoberto no guest por nome; requer prova de independência, grupo de teste e aprovação explícita."
}

function Update-PolicyFromInventory {
    param([object]$Policy, [object[]]$Records, [object]$Voice, [string]$AndroidRelease, [string]$ApiLevel)
    $allNames = @($Records | ForEach-Object { [string]$_.package } | Sort-Object -Unique)
    $voiceNames = @($Voice.packageNames)
    $criticalPatterns = @(
        'com.android.systemui', 'com.android.settings', 'com.android.providers.settings', 'com.android.providers.media',
        'com.android.providers.downloads', 'com.android.packageinstaller', 'com.google.android.webview', 'com.android.webview',
        'com.android.inputmethod', 'com.android.launcher', 'com.android.certinstaller', 'com.android.networkstack'
    )
    $criticalDiscovered = @($allNames | Where-Object { $candidate = $_; @($criticalPatterns | Where-Object { $candidate -like "*$_*" }).Count -gt 0 })
    $critical = @((Get-StringArray $Policy 'critical') + $voiceNames + $criticalDiscovered | Sort-Object -Unique)
    $required = @(Get-StringArray $Policy 'required')
    foreach ($requiredPackage in @([string]$config.neonews.packageName, [string]$config.webView.provider)) {
        if ($requiredPackage -and $requiredPackage -in $allNames) { $required += $requiredPackage }
    }
    $required = @($required | Sort-Object -Unique | Where-Object { $_ -notin $critical })
    $candidateNames = @($allNames | Where-Object { $null -ne (Get-CandidateReason $_) -and $_ -notin $critical -and $_ -notin $required })
    $optional = @((Get-StringArray $Policy 'optional') + $candidateNames | Sort-Object -Unique | Where-Object { $_ -in $allNames -and $_ -notin $critical -and $_ -notin $required })
    $disabled = @(Get-StringArray $Policy 'disabled' | Where-Object { $_ -notin $critical -and $_ -notin $voiceNames })
    $unknown = @($allNames | Where-Object { $_ -notin $critical -and $_ -notin $required -and $_ -notin $optional -and $_ -notin $disabled })
    Set-ObjectProperty $Policy 'schemaVersion' 1
    Set-ObjectProperty $Policy 'generatedFromGuest' ([ordered]@{ serial = $script:Serial; release = $AndroidRelease; apiLevel = $ApiLevel; timestamp = [DateTimeOffset]::UtcNow.ToString('o') })
    Set-ObjectProperty $Policy 'critical' $critical
    Set-ObjectProperty $Policy 'required' $required
    Set-ObjectProperty $Policy 'optional' $optional
    Set-ObjectProperty $Policy 'disabled' $disabled
    Set-ObjectProperty $Policy 'unknown' $unknown
    Set-ObjectProperty $Policy.voiceProtection 'enabled' $true
    Set-ObjectProperty $Policy.voiceProtection 'expectedEngine' ([string](Get-PropertyOrDefault $Policy.voiceProtection 'expectedEngine' 'RHVoice'))
    Set-ObjectProperty $Policy.voiceProtection 'expectedLocale' ([string](Get-PropertyOrDefault $Policy.voiceProtection 'expectedLocale' 'pt-BR'))
    Set-ObjectProperty $Policy.voiceProtection 'synthesisRequired' $true
    Set-ObjectProperty $Policy.voiceProtection 'discoveredPackages' $voiceNames
    Set-ObjectProperty $Policy.voiceProtection 'baselineDefaultEngine' ([string]$Voice.defaultEngine)
    $Policy
}

function New-DebloatPlan {
    param([object]$Policy, [object[]]$Records, [object]$Voice)
    $critical = Get-StringArray $Policy 'critical'
    $required = Get-StringArray $Policy 'required'
    $disabled = Get-StringArray $Policy 'disabled'
    $actions = foreach ($record in $Records) {
        $reason = Get-CandidateReason ([string]$record.package)
        if ($null -eq $reason -or $record.package -in $critical -or $record.package -in $required -or $record.package -in @($Voice.packageNames)) { continue }
        $isApproved = $record.package -in $disabled
        [ordered]@{
            group = 1
            package = [string]$record.package
            path = [string]$record.path
            type = [string]$record.type
            action = if ($isApproved) { 'disable-user' } else { 'none' }
            approved = $isApproved
            reason = $reason
            risk = if ($isApproved) { 'approved-by-policy' } else { 'unknown'
            }
            rollbackCommand = "pm enable $($record.package)"
        }
    }
    [ordered]@{
        schemaVersion = 1
        status = 'audit-complete'
        createdAt = [DateTimeOffset]::UtcNow.ToString('o')
        serial = $script:Serial
        android = [ordered]@{ release = [string]$config.android.release; apiLevel = [int]$config.android.apiLevel }
        policyPath = $policyFullPath
        inventoryPath = $inventoryFullPath
        snapshotRequired = $true
        applyRequiresExplicitApproval = $true
        voiceProtection = [ordered]@{
            packageNames = @($Voice.packageNames)
            defaultEngine = [string]$Voice.defaultEngine
            localeReady = [bool]$Voice.localeReady
            synthesisRequiredAfterEachGroup = $true
        }
        actions = @($actions)
    }
}

function Backup-PolicyBeforeAudit {
    if (-not (Test-Path -LiteralPath $policyFullPath -PathType Leaf)) { return $null }
    $stamp = [DateTimeOffset]::UtcNow.ToString('yyyyMMdd-HHmmssfff')
    $parent = Split-Path -Parent $policyFullPath
    $backupPath = Join-Path $parent "android-package-policy.before-audit-$stamp.json"
    Copy-Item -LiteralPath $policyFullPath -Destination $backupPath -Force
    Add-OptimizationLog 'POLICY_BACKUP' '' "path=$backupPath"
    return $backupPath
}

function Assert-AuditPlan {
    param([object]$Plan, [object]$Policy, [object[]]$Records, [string]$GuestRelease, [string]$GuestApi)
    if ([string]$Plan.status -ne 'audit-complete') {
        throw "Apply bloqueado: o plano precisa ter status audit-complete; status atual='$($Plan.status)'."
    }
    if ([string]$Plan.serial -ne [string]$script:Serial) {
        throw "Apply bloqueado: serial do plano '$($Plan.serial)' difere do serial atual '$script:Serial'."
    }
    $planAndroid = Get-PropertyOrDefault $Plan 'android' $null
    if ($null -eq $planAndroid -or [string]$planAndroid.release -ne [string]$GuestRelease -or [string]$planAndroid.apiLevel -ne [string]$GuestApi) {
        throw "Apply bloqueado: identidade Android do plano não coincide com o guest atual."
    }
    $critical = Get-StringArray $Policy 'critical'
    $required = Get-StringArray $Policy 'required'
    $disabled = Get-StringArray $Policy 'disabled'
    foreach ($action in @($Plan.actions)) {
        if ([string]$action.action -ne 'disable-user' -or $action.approved -ne $true) { continue }
        $package = [string]$action.package
        if ($package -in $critical -or $package -in $required -or $package -in @($Policy.voiceProtection.discoveredPackages)) {
            throw "Apply bloqueado: plano contém pacote protegido '$package'."
        }
        if ($package -notin $disabled) {
            throw "Apply bloqueado: '$package' não está mais aprovado em disabled."
        }
        $record = @($Records | Where-Object { [string]$_.package -eq $package } | Select-Object -First 1)
        if ($record.Count -eq 0) { throw "Apply bloqueado: '$package' não pertence ao inventário atual." }
        if ([string]$action.path -ne [string]$record[0].path) {
            throw "Apply bloqueado: caminho do pacote '$package' mudou desde o Audit."
        }
    }
}

function Invoke-GuestReboot {
    $reboot = Invoke-AdbShellResult @('reboot')
    if ($reboot.ExitCode -ne 0 -and $reboot.Text -notmatch '(?i)closed|offline|daemon') { throw "Reboot controlado falhou: $($reboot.Text)" }
    Add-OptimizationLog 'REBOOT_REQUESTED'
    Start-Sleep -Seconds 2
    Wait-ForGuestReady -TimeoutSeconds $BootTimeoutSeconds | Out-Null
}

function Invoke-PostOptimizationCoreGate {
    param([object]$BaselineVoice, [string]$Phase)
    $ready = Wait-ForGuestReady -TimeoutSeconds $BootTimeoutSeconds
    $neoNewsPath = Invoke-AdbShellResult @('pm', 'path', [string]$config.neonews.packageName)
    if ($neoNewsPath.ExitCode -ne 0 -or $neoNewsPath.Text -notmatch '(?m)^package:') { throw "NeoNews não está instalado após a otimização: $($neoNewsPath.Text)" }
    $neoNewsDump = Invoke-AdbShellResult @('dumpsys', 'package', [string]$config.neonews.packageName)
    if ($neoNewsDump.ExitCode -ne 0) { throw 'dumpsys package do NeoNews falhou após a otimização.' }
    $webView = Invoke-AdbShellResult @('dumpsys', 'webviewupdate')
    if ($webView.ExitCode -ne 0 -or $webView.Text -notmatch [regex]::Escape([string]$config.webView.provider)) { throw 'Provider WebView não pôde ser confirmado após a otimização.' }
    $voice = Assert-VoiceProtection -Baseline $BaselineVoice -Phase $Phase -RunSynthesis
    [ordered]@{ readyGate = $ready; neoNews = $true; webView = $true; voice = $voice; passed = $true }
}

function Invoke-FullValidationGate {
    param([string]$Phase, [DateTimeOffset]$MinimumTimestamp = [DateTimeOffset]::MinValue)
    # Evidence must be produced after the current optimization group. Merely
    # finding an old JSON file is never enough to authorize Optimized status.
    $requiredReports = [ordered]@{
        'reports/webview-provider.json' = { param($report) [string]$report.status -eq 'validated' }
        'reports/webview-content.json' = { param($report) [string]$report.status -eq 'validated' }
        'reports/tts-provider.json' = { param($report) [string]$report.status -like 'provider-and-locale-validated*' }
        'reports/tts-synthesis.json' = { param($report) [string]$report.status -eq 'validated' -and [bool]$report.defaultEngineMatches -and [bool]$report.probeLocale -and [bool]$report.audio.nonEmpty -and [int64]$report.audio.bytes -gt 0 }
        'reports/guest-network-media.json' = { param($report) [string]$report.status -eq 'validated' }
        'reports/runtime-stability.json' = { param($report) [string]$report.status -eq 'validated' -and [int]$report.observedDurationSeconds -ge 600 }
        'reports/homologation-checklist.json' = { param($report) [string]$report.status -eq 'validated' }
    }
    $missing = New-Object System.Collections.Generic.List[string]
    $invalid = New-Object System.Collections.Generic.List[string]
    $checked = New-Object System.Collections.Generic.List[object]
    foreach ($entry in $requiredReports.GetEnumerator()) {
        $path = Resolve-RepositoryPath $entry.Key
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            $missing.Add($entry.Key)
            continue
        }
        try { $report = Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json }
        catch { $invalid.Add("$($entry.Key): JSON inválido"); continue }
        $timestamp = [DateTimeOffset]::MinValue
        try { $timestamp = [DateTimeOffset]::Parse([string]$report.timestamp) } catch { }
        $identityMatches = [string]$report.transport -eq [string]$config.android.adb.transport -and [string]$report.serial -eq [string]$script:Serial
        $freshForGroup = $timestamp -ge $MinimumTimestamp
        $valid = $identityMatches -and $freshForGroup -and (& $entry.Value $report)
        $checked.Add([ordered]@{ path = $entry.Key; status = [string]$report.status; identityMatches = $identityMatches; freshForGroup = $freshForGroup; passed = $valid })
        if (-not $valid) { $invalid.Add($entry.Key) }
    }
    [ordered]@{
        phase = $Phase
        status = if ($missing.Count -gt 0) { 'pending' } elseif ($invalid.Count -gt 0) { 'failed' } else { 'validated' }
        missingReports = @($missing)
        invalidReports = @($invalid)
        reports = @($checked)
        minimumTimestamp = $MinimumTimestamp.ToString('o')
        passed = $missing.Count -eq 0 -and $invalid.Count -eq 0
    }
}

function Restore-ChangedGroup {
    param([object[]]$ChangedPackages, [string]$Reason)
    $script:result.rollback.attempted = $true
    $restored = New-Object System.Collections.Generic.List[string]
    try {
        Wait-ForGuestReady -TimeoutSeconds $BootTimeoutSeconds | Out-Null
        foreach ($package in ($ChangedPackages | Select-Object -Unique)) {
            $enable = Invoke-AdbShellResult @('pm', 'enable', [string]$package)
            if ($enable.ExitCode -ne 0) { throw "Não foi possível reativar ${package}: $($enable.Text)" }
            $restored.Add([string]$package)
            Add-OptimizationLog 'ROLLBACK_ENABLED' ([string]$package) $Reason
        }
        Invoke-GuestReboot
        $script:result.rollback.succeeded = $true
        $script:result.rollback.packages = @($restored)
        $script:result.rollback.detail = 'Pacotes do último grupo reativados e guest reiniciado.'
    } catch {
        $script:result.rollback.succeeded = $false
        $script:result.rollback.packages = @($restored)
        $script:result.rollback.detail = $_.Exception.Message
        throw
    }
}

function Invoke-Audit {
    $ready = Wait-ForGuestReady -TimeoutSeconds $BootTimeoutSeconds
    $inventory = Get-Inventory
    $guestReleaseResult = Invoke-AdbShellResult @('getprop', 'ro.build.version.release')
    $guestApiResult = Invoke-AdbShellResult @('getprop', 'ro.build.version.sdk')
    if ($guestReleaseResult.ExitCode -ne 0 -or $guestApiResult.ExitCode -ne 0) { throw 'Não foi possível confirmar a identidade do guest durante o inventário.' }
    if ($guestReleaseResult.Text.Trim() -ne [string]$config.android.release -or $guestApiResult.Text.Trim() -ne [string]$config.android.apiLevel) {
        throw "Guest divergente: release=$($guestReleaseResult.Text); api=$($guestApiResult.Text)."
    }
    $voice = Find-RhvoiceEvidence -Records $inventory.records
    $policy = Read-Policy
    $policy = Update-PolicyFromInventory -Policy $policy -Records $inventory.records -Voice $voice -AndroidRelease $guestReleaseResult.Text.Trim() -ApiLevel $guestApiResult.Text.Trim()
    $policyBackup = Backup-PolicyBeforeAudit
    if ($policyBackup) { $script:result.policyBackupPath = $policyBackup }
    Write-JsonReport -Path $policyFullPath -Value $policy
    $plan = New-DebloatPlan -Policy $policy -Records $inventory.records -Voice $voice
    Write-JsonReport -Path $planFullPath -Value $plan
    $script:result.status = 'AuditComplete'
    $script:result.readyGate = $ready
    $script:result.android = [ordered]@{ release = $guestReleaseResult.Text.Trim(); apiLevel = $guestApiResult.Text.Trim(); packageCount = $inventory.records.Count }
    $voiceSet = Test-VoicePackageSet -Baseline $voice -Current $voice
    $script:result.voiceProtection.baselineValidated = $voice.present -and $voiceSet.passed -and $voice.defaultMatches -and $voice.localeReady
    $script:result.voiceProtection.packages = @($voice.packageNames)
    $script:result.voiceProtection.defaultEngine = $voice.defaultEngine
    $script:result.voiceProtection.localeReady = $voice.localeReady
    $script:result.voiceProtection.synthesis = [ordered]@{ status = 'not-run-in-audit'; reason = 'Audit não altera o guest; a síntese real é gate obrigatório antes e depois do Apply.' }
    $script:result.plan = [ordered]@{ actionCount = @($plan.actions).Count; approvedActionCount = @($plan.actions | Where-Object { $_.approved -and $_.action -eq 'disable-user' }).Count; path = $planFullPath }
    Add-OptimizationLog 'AUDIT_COMPLETE' '' "packages=$($inventory.records.Count); rhvoice=$($voice.packageNames -join ',')"
    Write-JsonReport -Path $reportFullPath -Value $script:result
    Write-AtomicText -Path $comparisonFullPath -Text @"
# Android optimization result

Status: `AuditComplete`

O inventário foi criado em `$InventoryPath`. Nenhuma alteração foi feita no guest.

RHVoice detectado: `$($voice.packageNames -join ', ')`
Engine padrão observada: `$($voice.defaultEngine)`
Locale pt-BR confirmado: `$($voice.localeReady)`
Síntese real: pendente — será exigida antes do Apply e após cada grupo.

O plano `$PlanPath` contém somente candidatos. `Apply` exige aprovação explícita em `disabled` e `approved=true`; nenhum pacote de voz pode entrar no plano.
"@
    $script:result
}

function Invoke-Apply {
    $plan = if (Test-Path -LiteralPath $planFullPath -PathType Leaf) { Get-Content -LiteralPath $planFullPath -Raw -Encoding utf8 | ConvertFrom-Json } else { throw "Plano de debloat ausente: $planFullPath. Execute -Mode Audit primeiro." }
    $policy = Read-Policy
    $ready = Wait-ForGuestReady -TimeoutSeconds $BootTimeoutSeconds
    $records = @(Get-PackageRecords)
    $guestReleaseResult = Invoke-AdbShellResult @('getprop', 'ro.build.version.release')
    $guestApiResult = Invoke-AdbShellResult @('getprop', 'ro.build.version.sdk')
    if ($guestReleaseResult.ExitCode -ne 0 -or $guestApiResult.ExitCode -ne 0) { throw 'Apply bloqueado: não foi possível confirmar a identidade Android atual.' }
    if ($guestReleaseResult.Text.Trim() -ne [string]$config.android.release -or $guestApiResult.Text.Trim() -ne [string]$config.android.apiLevel) {
        throw "Apply bloqueado: guest divergente; release=$($guestReleaseResult.Text); api=$($guestApiResult.Text)."
    }
    Assert-AuditPlan -Plan $plan -Policy $policy -Records $records -GuestRelease $guestReleaseResult.Text.Trim() -GuestApi $guestApiResult.Text.Trim()
    $voice = Find-RhvoiceEvidence -Records $records
    $script:result.readyGate = $ready
    $script:result.voiceProtection.packages = @($voice.packageNames)
    $voiceSet = Test-VoicePackageSet -Baseline $voice -Current $voice
    if (-not $voice.present -or -not $voiceSet.passed -or -not $voice.defaultMatches) {
        throw 'Apply bloqueado: RHVoice precisa estar instalada, selecionada como engine padrão e com locale pt-BR disponível antes do debloat.'
    }
    $baselineVoice = $voice
    $approved = @($plan.actions | Where-Object { $_.approved -eq $true -and [string]$_.action -eq 'disable-user' })
    if ($approved.Count -eq 0) {
        $script:result.status = 'AuditComplete'
        $script:result.plan = [ordered]@{ actionCount = @($plan.actions).Count; approvedActionCount = 0; path = $planFullPath }
        $script:result.note = 'Nenhuma alteração aprovada. Edite disabled e approved no plano/política após revisar as evidências.'
        Write-JsonReport -Path $reportFullPath -Value $script:result
        return $script:result
    }
    $snapshot = New-DebloatSnapshot
    $script:result.snapshot = $snapshot
    $preSynthesis = Invoke-TtsSynthesisGate -Phase 'before'
    if (-not $preSynthesis.passed) { throw "Apply bloqueado: síntese RHVoice não validada antes do debloat: $($preSynthesis.status); bytes=$($preSynthesis.audioBytes)." }
    $script:result.voiceProtection.baselineValidated = $true
    $script:result.voiceProtection.synthesisBefore = $preSynthesis
    $groups = @($approved | Group-Object group | Sort-Object { [int]$_.Name })
    foreach ($group in $groups) {
        $groupStartedAt = [DateTimeOffset]::UtcNow
        $changed = New-Object System.Collections.Generic.List[string]
        try {
            foreach ($action in $group.Group) {
                $package = [string]$action.package
                if ($package -in @($policy.critical) -or $package -in @($policy.required) -or $package -in @($voice.packageNames)) {
                    throw "Ação recusada para pacote protegido: $package"
                }
                if ($package -notin @($policy.disabled)) { throw "Ação não está na lista disabled aprovada: $package" }
                if ($package -notin @($records.package)) { throw "Pacote não pertence ao inventário aprovado: $package" }
                if (-not $PSCmdlet.ShouldProcess($package, 'desabilitar para user 0')) { continue }
                $disable = Invoke-AdbShellResult @('pm', 'disable-user', '--user', '0', $package)
                if ($disable.ExitCode -ne 0 -or $disable.Text -notmatch '(?i)disabled|new state') { throw "Falha ao desabilitar ${package}: $($disable.Text)" }
                $changed.Add($package)
                Add-OptimizationLog 'DISABLED' $package "group=$($group.Name)"
            }
            if ($changed.Count -eq 0) { continue }
            Invoke-GuestReboot
            $gate = Invoke-PostOptimizationCoreGate -BaselineVoice $baselineVoice -Phase "after-group-$($group.Name)"
            $script:result.appliedGroups += [ordered]@{ group = [int]$group.Name; packages = @($changed); gate = $gate; timestamp = [DateTimeOffset]::UtcNow.ToString('o') }
            if ($RunFullValidation) {
                $full = Invoke-FullValidationGate -Phase "after-group-$($group.Name)" -MinimumTimestamp $groupStartedAt
                $script:result.fullValidation.last = $full
                if (-not $full.passed) { throw "Validação completa ainda não aprovada após o grupo $($group.Name)." }
            }
        } catch {
            $script:result.status = 'RollbackRequired'
            try { Restore-ChangedGroup -ChangedPackages @($changed) -Reason $_.Exception.Message } catch { }
            throw
        }
    }
    $script:result.status = if ($RunFullValidation) { 'Optimized' } else { 'DebloatApplied' }
    $script:result.voiceProtection.postChangeValidated = $true
    Add-OptimizationLog 'OPTIMIZATION_APPLIED' '' "status=$($script:result.status)"
    Write-JsonReport -Path $reportFullPath -Value $script:result
    Write-AtomicText -Path $comparisonFullPath -Text "# Android optimization result`r`n`r`nStatus: `$($script:result.status)`r`n`r`nO RHVoice foi validado antes e depois de cada grupo. A aprovação `Optimized` somente é permitida com `-RunFullValidation` e todas as evidências funcionais presentes.`r`n"
    $script:result
}

function Invoke-Rollback {
    $source = if (Test-Path -LiteralPath $reportFullPath -PathType Leaf) { Get-Content -LiteralPath $reportFullPath -Raw -Encoding utf8 | ConvertFrom-Json } else { $null }
    $lastGroup = if ($source -and $source.appliedGroups) { @($source.appliedGroups | Select-Object -Last 1) } else { @() }
    if ($lastGroup.Count -eq 0 -or @($lastGroup[0].packages).Count -eq 0) {
        $script:result.status = 'AuditComplete'
        $script:result.note = 'Nenhum grupo aplicado foi encontrado para rollback.'
        Write-JsonReport -Path $reportFullPath -Value $script:result
        return $script:result
    }
    $records = @(Get-PackageRecords)
    $baselineVoice = Find-RhvoiceEvidence -Records $records
    Restore-ChangedGroup -ChangedPackages @($lastGroup[0].packages) -Reason 'rollback explícito solicitado pelo operador'
    $voiceGate = Assert-VoiceProtection -Baseline $baselineVoice -Phase 'rollback' -RunSynthesis
    $script:result.status = 'RollbackRequired'
    $script:result.voiceProtection.postChangeValidated = $voiceGate.passed
    $script:result.rollback.voiceGate = $voiceGate
    Write-JsonReport -Path $reportFullPath -Value $script:result
    Write-AtomicText -Path $comparisonFullPath -Text "# Android optimization result`r`n`r`nStatus: `RollbackRequired``r`n`r`nO último grupo foi reativado e o gate RHVoice foi executado após o reboot. Nenhuma cópia de disco foi apagada ou sobrescrita.`r`n"
    $script:result
}

try {
    switch ($Mode) {
        'Audit' { Invoke-Audit | Out-Null }
        'Apply' { Invoke-Apply | Out-Null }
        'Rollback' { Invoke-Rollback | Out-Null }
    }
} catch {
    if ($script:result.status -eq 'NotOptimized') { $script:result.status = 'RollbackRequired' }
    $script:result.error = $_.Exception.Message
    try { Write-JsonReport -Path $reportFullPath -Value $script:result } catch { }
    Add-OptimizationLog 'FAILED' '' $_.Exception.Message
    throw
}

Write-JsonReport -Path $reportFullPath -Value $script:result
$script:result | ConvertTo-Json -Depth 20
