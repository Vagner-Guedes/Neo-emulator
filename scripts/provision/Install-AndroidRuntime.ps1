[CmdletBinding()]
param(
    [string]$SdkRoot = (Join-Path $env:LOCALAPPDATA 'Android\Sdk'),
    [switch]$AcceptLicenses,
    [switch]$InstallArmImages
)

$ErrorActionPreference = 'Stop'

$commandLineToolsVersion = '15859902'
$commandLineToolsSha256 = '90AE805D20434428BFFCB699C290860F19BB5F66A67E6B330067E3DE801FB04A'
$commandLineToolsUrl = "https://dl.google.com/android/repository/commandlinetools-win-${commandLineToolsVersion}_latest.zip"

$javaHome = $env:JAVA_HOME
if (-not $javaHome) {
    $javaCommand = Get-Command 'java' -ErrorAction SilentlyContinue
    if ($javaCommand) {
        $javaHome = Split-Path -Parent (Split-Path -Parent $javaCommand.Source)
    }
}
if (-not $javaHome -or -not (Test-Path -LiteralPath (Join-Path $javaHome 'bin\java.exe'))) {
    throw 'Java 17 ou superior não encontrado. Defina JAVA_HOME antes de executar o provisionamento.'
}
$env:JAVA_HOME = $javaHome
$env:Path = (Join-Path $javaHome 'bin') + ';' + $env:Path

$downloadRoot = Join-Path $env:LOCALAPPDATA 'NeoNewsRuntime\downloads'
$archivePath = Join-Path $downloadRoot "commandlinetools-win-${commandLineToolsVersion}_latest.zip"
$extractRoot = Join-Path $downloadRoot "cmdline-tools-${commandLineToolsVersion}"
$latestRoot = Join-Path $SdkRoot 'cmdline-tools\latest'

New-Item -ItemType Directory -Force -Path $downloadRoot, $latestRoot | Out-Null

if (-not (Test-Path -LiteralPath $archivePath)) {
    Write-Host "Baixando command-line tools ${commandLineToolsVersion}..."
    Invoke-WebRequest -Uri $commandLineToolsUrl -OutFile $archivePath
}

$actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $archivePath).Hash
if ($actualHash -ne $commandLineToolsSha256) {
    throw "Checksum inválido para command-line tools. Esperado: $commandLineToolsSha256; recebido: $actualHash"
}

if (-not (Test-Path -LiteralPath (Join-Path $extractRoot 'cmdline-tools\bin\sdkmanager.bat'))) {
    if (Test-Path -LiteralPath $extractRoot) {
        Remove-Item -LiteralPath $extractRoot -Recurse -Force
    }
    Expand-Archive -LiteralPath $archivePath -DestinationPath $extractRoot
}

$sourceRoot = Join-Path $extractRoot 'cmdline-tools'
Copy-Item -Path (Join-Path $sourceRoot '*') -Destination $latestRoot -Recurse -Force

$sdkManager = Join-Path $latestRoot 'bin\sdkmanager.bat'
if (-not (Test-Path -LiteralPath $sdkManager)) {
    throw "sdkmanager não foi encontrado em $sdkManager"
}

$packages = @(
    'platform-tools',
    'emulator',
    'platforms;android-25',
    'build-tools;25.0.3',
    'system-images;android-25;google_apis;x86'
)

if ($InstallArmImages) {
    $packages += @(
        'system-images;android-25;google_apis;armeabi-v7a',
        'system-images;android-25;google_apis;arm64-v8a'
    )
}

if ($AcceptLicenses) {
    Write-Host 'Aceitando licenças solicitadas pelo SDK Manager...'
    1..50 | ForEach-Object { 'y' } | & $sdkManager "--sdk_root=$SdkRoot" '--licenses'
    if ($LASTEXITCODE -ne 0) {
        throw "Não foi possível aceitar as licenças do SDK (exit code $LASTEXITCODE)."
    }
}
else {
    Write-Host 'Licenças não foram aceitas automaticamente. Use -AcceptLicenses após revisar os termos.'
}

Write-Host 'Instalando pacotes Android necessários...'
& $sdkManager "--sdk_root=$SdkRoot" '--install' @packages
if ($LASTEXITCODE -ne 0) {
    throw "Falha ao instalar pacotes Android (exit code $LASTEXITCODE)."
}

Write-Host "SDK Android provisionado em $SdkRoot"
Write-Host "Pacotes instalados: $($packages -join ', ')"
