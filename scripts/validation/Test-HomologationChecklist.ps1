[CmdletBinding()]
param(
    [string]$RepositoryRoot,
    [string]$ReportDirectory = 'reports',
    [string]$ReportPath = 'reports/homologation-checklist.json'
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) { $RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path }
$RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$configPath = Join-Path $RepositoryRoot 'config\runtime.json'
$config = Get-Content -LiteralPath $configPath -Raw -Encoding utf8 | ConvertFrom-Json
$reportRoot = if ([System.IO.Path]::IsPathRooted($ReportDirectory)) { $ReportDirectory } else { Join-Path $RepositoryRoot $ReportDirectory }

function Read-Report {
    param([string]$Name)
    $path = Join-Path $reportRoot $Name
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try { return Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json }
    catch { return [pscustomobject]@{ status = 'invalid-report'; error = $_.Exception.Message } }
}

function Has-PropertyValue {
    param([object]$Object, [string]$Path, [object]$Expected)
    if ($null -eq $Object) { return $false }
    $current = $Object
    foreach ($segment in ($Path -split '\.')) {
        if ($null -eq $current) { return $false }
        if ($current -is [System.Collections.IList] -and $segment -match '^\d+$') {
            $index = [int]$segment
            if ($index -lt 0 -or $index -ge $current.Count) { return $false }
            $current = $current[$index]
            continue
        }
        $property = $current.PSObject.Properties[$segment]
        if ($null -eq $property) { return $false }
        $current = $property.Value
    }
    if ($Expected -is [scriptblock]) { return & $Expected $current }
    return [string]$current -eq [string]$Expected
}

function Add-ChecklistItem {
    param(
        [System.Collections.Generic.List[object]]$Items,
        [string]$Id,
        [string]$Requirement,
        [string]$Evidence,
        [bool]$Pass,
        [string]$Details,
        [bool]$EvidenceAvailable = $true
    )
    $status = if ($Pass) { 'pass' } elseif (-not $EvidenceAvailable) { 'pending' } else { 'fail' }
    [void]$Items.Add([ordered]@{ id = $Id; requirement = $Requirement; evidence = $Evidence; status = $status; details = $Details })
}

$diagnostics = Read-Report 'diagnostics.json'
$native = Read-Report 'nativebridge.json'
$webViewProvider = Read-Report 'webview-provider.json'
$webViewContent = Read-Report 'webview-content.json'
$ttsProvider = Read-Report 'tts-provider.json'
$ttsSynthesis = Read-Report 'tts-synthesis.json'
$networkMedia = Read-Report 'guest-network-media.json'
$persistence = Read-Report 'qemu-persistence.json'
$benchmark = Read-Report 'qemu-benchmark.json'
$launcherSmoke = Read-Report 'launcher-smoke.json'
$items = New-Object System.Collections.Generic.List[object]

$configBackend = $config.android.backend -eq 'qemu-android-x86'
$configWhpx = $config.android.qemu.acceleration -eq 'whpx'
$configIdentity = $config.android.release -eq '7.1.2' -and $config.android.apiLevel -eq 25
$configDisk = -not [string]::IsNullOrWhiteSpace([string]$config.android.qemu.disk)
$configAdb = $config.android.adb.transport -eq 'tcp' -and $config.android.adb.host -eq '127.0.0.1' -and $config.android.adb.hostPort -eq 5556 -and $config.android.adb.guestPort -eq 5555
$configKiosk = -not [string]::IsNullOrWhiteSpace([string]$config.android.kiosk.displaySize) -and [int]$config.android.kiosk.displayDensity -gt 0
$configHotkey = -not [string]::IsNullOrWhiteSpace([string]$config.runtime.hotkey)
$configNative = [bool]$config.android.nativeBridge.required
$configApk = $config.neonews.packageName -eq 'com.in9midia.neonews.player' -and $config.neonews.versionName -eq '9.0.3' -and [int]$config.neonews.versionCode -eq 522 -and $config.neonews.launchActivity -match 'TerminalActivity'
$configWebView = $config.webView.provider -eq 'com.google.android.webview' -and $config.webView.homologatedVersion -eq '119.0.6045.193'
$configTts = $config.tts.engine -match '(?i)rhvoice' -and $config.tts.locale -eq 'pt-BR'
$expectedRotation = switch ([string]$config.android.kiosk.orientation) {
    'portrait' { '0'; break }
    'reverse-portrait' { '2'; break }
    'reverse-landscape' { '3'; break }
    default { '1' }
}
$configNoAndroidStudio = -not [bool]$config.android.tooling.allowEnvironmentFallback -and
    [string]$config.android.qemu.executable -match '(?i)^runtime[\\/]' -and
    [string]$config.android.qemu.disk -match '(?i)^runtime[\\/]'

Add-ChecklistItem $items 'backend-qemu-whpx' 'QEMU x86_64 com WHPX configurado' 'config/runtime.json + diagnostics.json + launcher-smoke.json' ($configBackend -and $configWhpx -and $configNoAndroidStudio -and (Has-PropertyValue $diagnostics 'tools.backend' 'QEMU Android-x86') -and (Has-PropertyValue $diagnostics 'tools.whpx.available' $true) -and (Has-PropertyValue $launcherSmoke 'manualEvidence.qemuNoConsoleObserved' $true)) 'Configuração e WHPX devem coincidir; o diagnóstico e a observação live precisam confirmar QEMU sem console.' ($null -ne $diagnostics -or $null -ne $launcherSmoke)
Add-ChecklistItem $items 'guest-identity' 'Android-x86 7.1.2/API 25 confirmado' 'diagnostics.json ou nativebridge.json' ($configIdentity -and ((Has-PropertyValue $diagnostics 'android.identityMatches' $true) -or (Has-PropertyValue $native 'guestIdentityMatches' $true))) 'Release, API e sys.boot_completed precisam ser confirmados no guest.' ($null -ne $diagnostics -or $null -ne $native)
Add-ChecklistItem $items 'persistent-disk' 'qcow2 persistente configurado e reutilizado' 'config/runtime.json + qemu-persistence.json + launcher-smoke.json' ($configDisk -and (Has-PropertyValue $persistence 'status' 'validated') -and (Has-PropertyValue $launcherSmoke 'manualEvidence.windowsRestartObserved' $true)) 'O marcador deve sobreviver a processos QEMU; a persistência após reinício do Windows requer observação explícita.' ($null -ne $persistence -or $null -ne $launcherSmoke)
Add-ChecklistItem $items 'adb-tcp' 'ADB TCP host 127.0.0.1:5556 para guest 5555' 'config/runtime.json + diagnostics.json' ($configAdb -and (Has-PropertyValue $diagnostics 'android.adb.serial' '127.0.0.1:5556')) 'O serial e o encaminhamento precisam ser observados no runtime.' ($null -ne $diagnostics)
Add-ChecklistItem $items 'qmp-shutdown' 'Desligamento QEMU via QMP sem adb emu kill' 'qemu-benchmark.json ou qemu-persistence.json' ((Has-PropertyValue $benchmark 'acceleration' 'whpx') -and ((Has-PropertyValue $persistence 'firstShutdownSucceeded' $true) -or (Has-PropertyValue $benchmark 'runs.0.stopped' $true))) 'O relatório live deve registrar encerramento controlado.' ($null -ne $benchmark -or $null -ne $persistence)
Add-ChecklistItem $items 'native-bridge-property' 'Native Bridge ARM declarado e operacional' 'nativebridge.json ou diagnostics.json' ($configNative -and ((Has-PropertyValue $native 'nativeBridgeReady' $true) -or (Has-PropertyValue $diagnostics 'abiCompatibility.nativeBridgeReady' $true))) 'Property isolada não basta; o relatório precisa incluir a execução do APK.' ($null -ne $native -or $null -ne $diagnostics)
Add-ChecklistItem $items 'official-apk-identity' 'APK oficial, pacote, versão e activity corretos' 'config/runtime.json + diagnostics.json' ($configApk -and (Has-PropertyValue $diagnostics 'tools.requiredFiles.neoNewsApk.exists' $true)) 'A presença do arquivo é pré-condição; a assinatura é validada separadamente.' ($null -ne $diagnostics)
Add-ChecklistItem $items 'official-apk-signature' 'Certificado SHA-256 autorizado confirmado' 'diagnostics.json' (Has-PropertyValue $diagnostics 'abiCompatibility.signature.valid' $true) 'O certificado observado deve coincidir com a fingerprint configurada.' ($null -ne $diagnostics)
Add-ChecklistItem $items 'official-apk-abis' 'APK contém arm64-v8a e armeabi-v7a' 'diagnostics.json' ((Has-PropertyValue $diagnostics 'abiCompatibility.apkAbis' { param($v) @($v) -contains 'arm64-v8a' -and @($v) -contains 'armeabi-v7a' })) 'As duas ABIs ARM do APK oficial devem ser observadas.' ($null -ne $diagnostics)
Add-ChecklistItem $items 'apk-install' 'adb install -r retornou Success e preservou dados' 'nativebridge.json + launcher-smoke.json' ((Has-PropertyValue $native 'installSucceeded' $true) -and (Has-PropertyValue $launcherSmoke 'manualEvidence.updatePreservationObserved' $true)) 'A instalação deve retornar Success e a atualização deve preservar dados, sem uninstall ou clear data.' ($null -ne $native -or $null -ne $launcherSmoke)
Add-ChecklistItem $items 'abi-selection' 'primaryCpuAbi selecionada pela instalação' 'nativebridge.json' ((Has-PropertyValue $native 'selectedApkAbi' { param($v) @('arm64-v8a','armeabi-v7a') -contains [string]$v }) -and (Has-PropertyValue $native 'primaryCpuAbi' { param($v) @('arm64-v8a','armeabi-v7a') -contains [string]$v })) 'A ABI selecionada precisa ser a ABI observada no package dump.' ($null -ne $native)
Add-ChecklistItem $items 'activity-launch' 'TerminalActivity abriu no guest' 'nativebridge.json' (Has-PropertyValue $native 'launchSucceeded' $true -and Has-PropertyValue $native 'activityRunning' $true) 'O launch e a atividade em primeiro plano precisam ser confirmados.' ($null -ne $native)
Add-ChecklistItem $items 'initial-stability' 'NeoNews permaneceu estável após o primeiro launch' 'nativebridge.json' (Has-PropertyValue $native 'runtimeStable' $true) 'Logcat filtrado não pode conter falhas de linker, WebView ou crash.' ($null -ne $native)
Add-ChecklistItem $items 'restart-stability' 'NeoNews sobreviveu a reinício do guest' 'nativebridge.json' ((Has-PropertyValue $native 'restartCount' { param($v) [int]$v -ge 1 }) -and (Has-PropertyValue $native 'restartResults' { param($v) @($v).Count -ge 1 -and @($v | Where-Object { $_.stable -ne $true }).Count -eq 0 })) 'Cada reinício deve voltar a boot, launch e estabilidade.' ($null -ne $native)
Add-ChecklistItem $items 'kiosk-display' 'Kiosk aplicou display, density e rotação configurados' 'config/runtime.json + diagnostics.json + launcher-smoke.json' $configKiosk 'A configuração é necessária; diagnóstico live e observação visual devem conter os valores do guest.' ($null -ne $config)
Add-ChecklistItem $items 'hotkey' 'Hotkey de saída do kiosk está configurado' 'config/runtime.json + launcher-smoke.json' $configHotkey 'A configuração precisa conter a combinação operacional documentada.' ($null -ne $config)
Add-ChecklistItem $items 'watchdog' 'Watchdog reabre activity e recupera QEMU' 'diagnostics.json + launcher-smoke.json' ((Has-PropertyValue $diagnostics 'watchdog.active' $true) -and [bool]$config.supervisor.restartOnActivityLoss -and (Has-PropertyValue $launcherSmoke 'manualEvidence.watchdogActivityObserved' $true) -and (Has-PropertyValue $launcherSmoke 'manualEvidence.watchdogQemuObserved' $true)) 'A política e as duas recuperações precisam ser observadas; Native Bridge indisponível não pode iniciar loop de reinstalação.' ($null -ne $diagnostics -or $null -ne $launcherSmoke)
Add-ChecklistItem $items 'startup-exe' 'Startup usa diretamente NeoNewsRuntime.exe --autostart' 'diagnostics.json + config/runtime.json' ((Has-PropertyValue $diagnostics 'startup.valid' $true) -and [string]$config.startup.script -match 'NeoNewsRuntime\.exe\s+--autostart') 'Nenhum PowerShell/cmd deve compor o caminho de startup.' ($null -ne $diagnostics)
Add-ChecklistItem $items 'launcher-cli-single-instance' 'Launcher, CLI, tray e instância única funcionam' 'launcher-smoke.json' ((Has-PropertyValue $launcherSmoke 'status' 'validated') -and (Has-PropertyValue $launcherSmoke 'manualEvidence.noConsoleObserved' $true) -and (Has-PropertyValue $launcherSmoke 'manualEvidence.trayObserved' $true) -and (Has-PropertyValue $launcherSmoke 'singleInstance.passed' $true) -and (Has-PropertyValue $launcherSmoke 'outsideProject' $true) -and (Has-PropertyValue $launcherSmoke 'pathWithSpaces.passed' $true)) 'O smoke deve confirmar janela responsiva, segunda invocação, --exit sem residual, ausência de console, tray, execução fora do projeto e caminho com espaços.' ($null -ne $launcherSmoke)
Add-ChecklistItem $items 'webview-package' 'Pacote WebView esperado está instalado' 'webview-provider.json' (Has-PropertyValue $webViewProvider 'provider.packagePresent' $true) 'Provider ausente não pode ser tratado como pronto.' ($null -ne $webViewProvider)
Add-ChecklistItem $items 'webview-active' 'Provider WebView esperado está ativo' 'webview-provider.json' (Has-PropertyValue $webViewProvider 'provider.providerActive' $true) 'A linha Current WebView package deve apontar ao provider esperado.' ($null -ne $webViewProvider)
Add-ChecklistItem $items 'webview-version' 'WebView ativo é 119.0.6045.193' 'webview-provider.json ou webview-content.json' ($configWebView -and ((Has-PropertyValue $webViewProvider 'provider.versionMatches' $true) -or (Has-PropertyValue $webViewContent 'provider.versionMatches' $true))) 'A versão instalada deve coincidir exatamente com a configuração.' ($null -ne $webViewProvider -or $null -ne $webViewContent)
Add-ChecklistItem $items 'webview-native-abi' 'WebView possui ABI nativa x86/x86_64' 'webview-provider.json ou webview-content.json' ((Has-PropertyValue $webViewProvider 'provider.nativeAbiMatches' $true) -or (Has-PropertyValue $webViewContent 'provider.nativeAbiMatches' $true)) 'Não aceitar provider ARM-only no guest x86.' ($null -ne $webViewProvider -or $null -ne $webViewContent)
Add-ChecklistItem $items 'webview-html-css-js' 'WebView executa HTML, CSS e JavaScript reais' 'webview-content.json' (Has-PropertyValue $webViewContent 'content.validated' $true -and (Has-PropertyValue $webViewContent 'content.result' { param($v) [string]$v -match '(?i)localHtml=True.*localCss=True.*localJs=True' })) 'O probe deve executar conteúdo local e retornar as três fases.' ($null -ne $webViewContent)
Add-ChecklistItem $items 'webview-https' 'WebView carrega conteúdo HTTPS real' 'webview-content.json' (Has-PropertyValue $webViewContent 'content.validated' $true -and (Has-PropertyValue $webViewContent 'content.result' { param($v) [string]$v -match '(?i)remoteHttps=True.*remoteContent=True' })) 'HTTPS e corpo não vazio devem ser observados.' ($null -ne $webViewContent)
Add-ChecklistItem $items 'rhvoice-provider' 'RHVoice é engine padrão e locale pt-BR disponível' 'tts-synthesis.json ou tts-provider.json' ($configTts -and (Has-PropertyValue $ttsSynthesis 'defaultEngineMatches' $true) -and (Has-PropertyValue $ttsSynthesis 'probeLocale' $true) -and (Has-PropertyValue $ttsProvider 'status' { param($v) [string]$v -like 'provider-and-locale-validated*' })) 'Provider, engine selecionada e dados de locale devem coincidir.' ($null -ne $ttsSynthesis -or $null -ne $ttsProvider)
Add-ChecklistItem $items 'rhvoice-audio' 'RHVoice produziu áudio não vazio' 'tts-synthesis.json' (Has-PropertyValue $ttsSynthesis 'audio.nonEmpty' $true -and Has-PropertyValue $ttsSynthesis 'status' 'validated') 'Presença do pacote não é prova de síntese.' ($null -ne $ttsSynthesis)
Add-ChecklistItem $items 'network-online' 'DNS, HTTP e HTTPS funcionam no guest' 'guest-network-media.json' ((Has-PropertyValue $networkMedia 'online.validated' $true) -and (Has-PropertyValue $networkMedia 'online.raw' { param($v) [string]$v -match '(?i)dns=true.*http=true.*https=true' })) 'Use URLs aprovadas pelo ambiente.' ($null -ne $networkMedia)
Add-ChecklistItem $items 'hls-playback' 'Playlist HLS/m3u8 e reprodução MediaPlayer funcionam' 'guest-network-media.json' ((Has-PropertyValue $networkMedia 'online.validated' $true) -and (Has-PropertyValue $networkMedia 'online.raw' { param($v) [string]$v -match '(?i)hlsPlaylist=true.*hlsPlayable=true' })) 'O teste deve registrar playlist válida e playback efetivo.' ($null -ne $networkMedia)
Add-ChecklistItem $items 'offline-cache' 'Cache permanece legível e a rede falha ao desligar a NIC' 'guest-network-media.json' ((Has-PropertyValue $networkMedia 'offline.validated' $true) -and (Has-PropertyValue $networkMedia 'offline.networkLinkToggled' $true)) 'A perda de rede precisa ser reversível e registrada.' ($null -ne $networkMedia)

# These two items deliberately require explicit visual evidence. A configured
# tray or hotkey is not the same as observing it in the published executable.
$kioskItem = $items | Where-Object { $_.id -eq 'kiosk-display' } | Select-Object -First 1
if ($kioskItem) {
    $kioskLive = (Has-PropertyValue $diagnostics 'android.displaySize' { param($v) [string]$v -match [regex]::Escape([string]$config.android.kiosk.displaySize) }) -and
        (Has-PropertyValue $diagnostics 'android.displayDensity' { param($v) [string]$v -match [regex]::Escape([string]$config.android.kiosk.displayDensity) }) -and
        (Has-PropertyValue $diagnostics 'android.kiosk.rotation' { param($v) [string]$v.Trim() -eq [string]$expectedRotation }) -and
        (Has-PropertyValue $diagnostics 'android.kiosk.policyControl' { param($v) [string]$v -match [regex]::Escape([string]$config.android.kiosk.immersivePolicy) }) -and
        (Has-PropertyValue $diagnostics 'android.kiosk.screenOffTimeout' { param($v) [string]$v.Trim() -eq [string]$config.android.kiosk.screenOffTimeoutMs }) -and
        (Has-PropertyValue $diagnostics 'android.kiosk.stayAwake' { param($v) [string]$v.Trim() -eq [string]$config.android.kiosk.stayAwakePluggedIn })
    $kioskItem.status = if ($null -eq $launcherSmoke -or $null -eq $diagnostics) { 'pending' } elseif ($configKiosk -and $kioskLive -and (Has-PropertyValue $launcherSmoke 'manualEvidence.kioskObserved' $true)) { 'pass' } else { 'fail' }
}
$hotkeyItem = $items | Where-Object { $_.id -eq 'hotkey' } | Select-Object -First 1
if ($hotkeyItem) {
    $hotkeyItem.status = if ($null -eq $launcherSmoke) { 'pending' } elseif ($configHotkey -and (Has-PropertyValue $launcherSmoke 'manualEvidence.hotkeyObserved' $true)) { 'pass' } else { 'fail' }
}
$launcherItem = $items | Where-Object { $_.id -eq 'launcher-cli-single-instance' } | Select-Object -First 1
if ($launcherItem) {
    $launcherItem.requirement = 'Launcher, CLI and single instance work'
    $launcherItem.details = 'O smoke deve confirmar janela responsiva, segunda invocação, --exit sem residual, tray e ausência de console; caminhos com espaços são verificados quando solicitados.'
}

$failed = @($items | Where-Object { $_.status -eq 'fail' })
$pending = @($items | Where-Object { $_.status -eq 'pending' })
$passed = @($items | Where-Object { $_.status -eq 'pass' })
$result = [ordered]@{
    timestamp = (Get-Date).ToUniversalTime().ToString('o')
    itemCount = $items.Count
    passed = $passed.Count
    failed = $failed.Count
    pending = $pending.Count
    items = $items.ToArray()
    status = if ($items.Count -eq 30 -and $failed.Count -eq 0 -and $pending.Count -eq 0) { 'validated' } else { 'not-approved' }
}
$json = $result | ConvertTo-Json -Depth 12
$fullReportPath = if ([System.IO.Path]::IsPathRooted($ReportPath)) { $ReportPath } else { Join-Path $RepositoryRoot $ReportPath }
$reportParent = Split-Path -Parent $fullReportPath
if ($reportParent -and -not (Test-Path -LiteralPath $reportParent)) { New-Item -ItemType Directory -Path $reportParent -Force | Out-Null }
Set-Content -LiteralPath $fullReportPath -Value $json -Encoding utf8
$json
if ($result.status -ne 'validated') { exit 2 }
