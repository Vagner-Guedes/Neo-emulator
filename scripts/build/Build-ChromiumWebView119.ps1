[CmdletBinding()]
param(
    [string]$Distro = 'Debian-NeoNews',
    [string]$CheckoutRoot = '/home/neonews/chromium',
    [string]$SourceArchive = '/home/neonews/chromium/chromium-119.0.6045.193-src.tar.gz',
    [string]$OutputDir = '/home/neonews/chromium/out/NeoNewsWebView119',
    [int]$Jobs = 3,
    [switch]$SkipSync,
    [switch]$SkipHooks,
    [switch]$SkipBuild,
    [string]$ReportPath = 'reports/webview-build-119.json'
)

$ErrorActionPreference = 'Stop'

if ($Jobs -lt 1 -or $Jobs -gt 8) {
    throw 'Jobs deve estar entre 1 e 8 neste host.'
}

$sourceTag = '119.0.6045.193'
$sourceCommit = 'baf84c2d246a45577b7ddd2b8d8d2e2cf36e12e2'
$sourceArchiveUrl = "https://chromium.googlesource.com/chromium/src/+archive/refs/tags/$sourceTag.tar.gz"
$sourceArchiveSha256 = 'de3b2b430a322e57e0515f69f42f5e348eccc86faa30a378295496914bb57164'
$sourceArchiveSize = 1367896317
$gclientSpec = "solutions=[{'name':'src','url':'https://chromium.googlesource.com/chromium/src.git','deps_file':'DEPS','managed':False}]; target_os=['android']"
$gnArgs = @'
target_os = "android"
target_cpu = "x64"
is_debug = false
is_official_build = true
is_component_build = false
is_chrome_branded = false
use_official_google_api_keys = false
disable_fieldtrial_testing_config = true
android_channel = "stable"
symbol_level = 0
system_webview_package_name = "com.android.webview"
skip_secondary_abi_for_cq = true
clang_use_default_sample_profile = false
'@
$gnArgs = $gnArgs.Trim()

function Quote-BashSingle([string]$Value) {
    $escaped = $Value.Replace("'", "'\''")
    return "'$escaped'"
}

function Invoke-WslBash {
    param([string]$Command)
    & wsl.exe -d $Distro -- bash -lc $Command
    if ($LASTEXITCODE -ne 0) {
        throw "Comando WSL falhou com exit code $LASTEXITCODE."
    }
}

function Invoke-WslCapture {
    param([string]$Command)
    $lines = @(& wsl.exe -d $Distro -- bash -lc $Command)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "Comando WSL falhou com exit code $exitCode.`n$($lines -join "`n")"
    }
    return $lines
}

function Test-WslPath([string]$Path) {
    return $Path -match '^/[A-Za-z0-9._+/:=-]+$'
}

foreach ($path in @($CheckoutRoot, $SourceArchive, $OutputDir)) {
    if (-not (Test-WslPath $path)) {
        throw "Caminho WSL inválido ou não determinístico: $path"
    }
}

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$reportFile = if ([System.IO.Path]::IsPathRooted($ReportPath)) {
    $ReportPath
} else {
    Join-Path $repositoryRoot ($ReportPath -replace '/', '\')
}
$reportDirectory = Split-Path -Parent $reportFile
if ($reportDirectory -and -not (Test-Path -LiteralPath $reportDirectory)) {
    New-Item -ItemType Directory -Path $reportDirectory -Force | Out-Null
}

$sourceDir = "$CheckoutRoot/src"
$depotTools = '/home/neonews/depot_tools'
$gn = "$sourceDir/buildtools/linux64/gn"
$ninja = "$sourceDir/third_party/ninja/ninja"

$report = [ordered]@{
    schema = 1
    status = 'NOT_STARTED'
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    host = [ordered]@{ distro = $Distro; checkoutRoot = $CheckoutRoot; jobs = $Jobs }
    source = [ordered]@{
        repository = 'https://chromium.googlesource.com/chromium/src'
        tag = $sourceTag
        commit = $sourceCommit
        archiveUrl = $sourceArchiveUrl
        archivePath = $SourceArchive
        expectedArchiveSize = $sourceArchiveSize
        expectedArchiveSha256 = $sourceArchiveSha256
        sourceDir = $sourceDir
    }
    dependencies = [ordered]@{ depotTools = $depotTools; gclientSpec = $gclientSpec; sync = (-not $SkipSync); hooks = (-not $SkipHooks) }
    gnArgs = $gnArgs -split "`r?`n"
    target = 'system_webview_apk'
    package = 'com.android.webview'
    artifact = @()
    guardrails = [ordered]@{
        officialSourceOnly = $true
        randomMirrorsUsed = $false
        qcow2Mutated = $false
        guestWebViewChanged = $false
        rhVoiceChanged = $false
        nativeBridgeChanged = $false
        debloatChanged = $false
    }
}

try {
    $archive = Quote-BashSingle $SourceArchive
    $checkout = Quote-BashSingle $CheckoutRoot
    $source = Quote-BashSingle $sourceDir
    $out = Quote-BashSingle $OutputDir
    $expectedHash = Quote-BashSingle $sourceArchiveSha256

    $prepare = @'
set -eu
archive=__ARCHIVE__
checkout=__CHECKOUT__
source=__SOURCE__
mkdir -p "$(dirname "$archive")" "$checkout"
if [ ! -f "$archive" ]; then
  curl --fail --location --retry 3 --retry-all-errors --output "$archive" __URL__
fi
actual="$(sha256sum "$archive" | awk '{print $1}')"
size="$(stat -c '%s' "$archive")"
[ "$actual" = __HASH__ ] || { echo "SOURCE_ARCHIVE_SHA256_MISMATCH size=$size sha256=$actual" >&2; exit 21; }
[ "$size" = '__SIZE__' ] || { echo "SOURCE_ARCHIVE_SIZE_MISMATCH size=$size" >&2; exit 22; }
if [ ! -d "$source" ]; then
  mkdir "$source"
  tar -xzf "$archive" -C "$source"
elif [ ! -f "$source/chrome/VERSION" ]; then
  echo "SOURCE_CHECKOUT_INCOMPLETE: $source existe, mas chrome/VERSION não existe; nenhuma sobrescrita automática será feita." >&2
  exit 23
fi
grep -qx 'MAJOR=119' "$source/chrome/VERSION"
grep -qx 'MINOR=0' "$source/chrome/VERSION"
grep -qx 'BUILD=6045' "$source/chrome/VERSION"
grep -qx 'PATCH=193' "$source/chrome/VERSION"
    '@.Replace('__ARCHIVE__', $archive).Replace('__CHECKOUT__', $checkout).Replace('__SOURCE__', $source).Replace('__URL__', (Quote-BashSingle $sourceArchiveUrl)).Replace('__HASH__', $expectedHash).Replace('__SIZE__', [string]$sourceArchiveSize)
    Invoke-WslBash $prepare

    $sourceEvidenceCommand = @'
set -eu
archive=__ARCHIVE__
printf '%s\t%s\n' "$(stat -c '%s' "$archive")" "$(sha256sum "$archive" | awk '{print $1}')"
'@.Replace('__ARCHIVE__', $archive)
    $sourceEvidence = Invoke-WslCapture $sourceEvidenceCommand
    $sourceEvidenceParts = ($sourceEvidence | Select-Object -Last 1) -split "`t", 2
    $report.source.actualArchiveSize = [int64]$sourceEvidenceParts[0]
    $report.source.actualArchiveSha256 = $sourceEvidenceParts[1].ToLowerInvariant()
    $report.source.archiveVerified = $report.source.actualArchiveSize -eq $sourceArchiveSize -and $report.source.actualArchiveSha256 -eq $sourceArchiveSha256

    $gclient = Quote-BashSingle "$CheckoutRoot/.gclient"
    $configure = @"
set -eu
if [ ! -f $gclient ]; then
  $depotTools/gclient config --spec=$(Quote-BashSingle $gclientSpec)
fi
grep -Fq "chromium.googlesource.com/chromium/src.git" $gclient
grep -Fq "target_os=['android']" $gclient
"@
    Invoke-WslBash $configure

    if (-not $SkipSync) {
        $sync = "cd $(Quote-BashSingle $CheckoutRoot) && $(Quote-BashSingle "$depotTools/gclient") sync --nohooks --no-history -j1 --no-bootstrap"
        Invoke-WslBash $sync
    }
    if (-not $SkipHooks) {
        $hooks = "cd $(Quote-BashSingle $CheckoutRoot) && $(Quote-BashSingle "$depotTools/gclient") runhooks"
        Invoke-WslBash $hooks
    }

    $argsForShell = Quote-BashSingle $gnArgs
    $gnCommand = "$(Quote-BashSingle $gn) gen $(Quote-BashSingle $OutputDir) --args=$argsForShell"
    Invoke-WslBash $gnCommand

    if (-not $SkipBuild) {
        $ninjaCommand = "$(Quote-BashSingle $ninja) -C $(Quote-BashSingle $OutputDir) system_webview_apk -j$Jobs"
        Invoke-WslBash $ninjaCommand
    }

    $artifactCommand = @'
set -eu
out=__OUT__
if [ ! -d "$out" ]; then exit 31; fi
found=0
while IFS= read -r -d '' apk; do
  found=1
  printf 'ARTIFACT\t%s\t%s\t%s\n' "$apk" "$(stat -c '%s' "$apk")" "$(sha256sum "$apk" | awk '{print $1}')"
done < <(find "$out" -type f -name '*.apk' -print0)
[ "$found" = 1 ]
'@.Replace('__OUT__', $out)
    $artifactLines = Invoke-WslCapture $artifactCommand
    $artifacts = @(
        $artifactLines |
            Where-Object { $_ -match '^ARTIFACT\t' } |
            ForEach-Object {
                $parts = $_ -split "`t", 4
                [ordered]@{ path = $parts[1]; size = [int64]$parts[2]; sha256 = $parts[3].ToLowerInvariant() }
            }
    )
    $report.artifact = $artifacts
    $report.status = if ($SkipBuild) { 'ARTIFACTS_INSPECTED' } else { 'BUILT' }
}
catch {
    $report.status = 'FAILED'
    $report.failure = $_.Exception.Message
    throw
}
finally {
    $report.generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    $report | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath $reportFile -Encoding utf8
    Write-Host "Relatório: $reportFile"
}

Write-Output ($report | ConvertTo-Json -Depth 14)
