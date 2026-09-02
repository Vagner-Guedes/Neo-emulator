[CmdletBinding()]
param(
    [string]$RepositoryRoot,
    [string]$ReportPath
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
}
$scriptErrors = @()
$scriptFiles = @(Get-ChildItem -LiteralPath (Join-Path $RepositoryRoot 'scripts') -Filter '*.ps1' -Recurse)
foreach ($scriptFile in $scriptFiles) {
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($scriptFile.FullName, [ref]$null, [ref]$parseErrors) | Out-Null
    if ($parseErrors.Count -gt 0) {
        foreach ($parseError in $parseErrors) {
            $scriptErrors += [pscustomobject]@{
                file = $scriptFile.FullName.Substring($RepositoryRoot.Length + 1)
                message = $parseError.Message
                line = $parseError.Extent.StartLineNumber
            }
        }
    }
}

$configPath = Join-Path $RepositoryRoot 'config\runtime.json'
$configValid = $true
$configError = $null
try {
    $configObject = Get-Content -LiteralPath $configPath -Raw -Encoding utf8 | ConvertFrom-Json
    if ($configObject.schemaVersion -ne 2) { throw "runtime.json precisa usar schemaVersion=2." }
    if ($configObject.android.backend -ne 'qemu-android-x86') { throw "backend padrão precisa ser qemu-android-x86." }
    if ($configObject.android.adb.transport -ne 'tcp') { throw "ADB do backend QEMU precisa usar transporte tcp." }
} catch {
    $configValid = $false
    $configError = $_.Exception.Message
}

$requiredPaths = @(
    'config/runtime.json',
    'docs/AUDIT-ETAPA-1.md',
    'docs/ABI-ETAPA-3.md',
    'docs/WEBVIEW-ETAPA-4.md',
    'docs/TTS-ETAPA-5.md',
    'docs/NEONEWS-ETAPA-6.md',
    'docs/QEMU-API25-RUNTIME.md',
    'docs/FINAL-REPORT.md',
    'scripts/provision/Provision-QemuAndroidRuntime.ps1',
    'scripts/provision/Install-GuestComponents.ps1',
    'scripts/validation/Test-NativeBridge.ps1',
    'launcher/NeoNews.Runtime.Launcher/NeoNews.Runtime.Launcher.csproj'
)
$missingPaths = @($requiredPaths | Where-Object { -not (Test-Path -LiteralPath (Join-Path $RepositoryRoot $_)) })
$appIgnored = $false
Push-Location $RepositoryRoot
try {
    $ignoreResults = foreach ($candidate in @('app.apk', 'NeoNews.apk')) {
        git check-ignore --quiet -- $candidate
        $LASTEXITCODE -eq 0
    }
    $appIgnored = $ignoreResults -notcontains $false
} finally {
    Pop-Location
}

$result = [ordered]@{
    timestamp = (Get-Date).ToUniversalTime().ToString('o')
    scriptCount = $scriptFiles.Count
    scriptParseErrors = @($scriptErrors)
    configValid = $configValid
    configError = $configError
    missingRequiredPaths = $missingPaths
    proprietaryApkIgnored = $appIgnored
    status = if ($scriptErrors.Count -eq 0 -and $configValid -and $missingPaths.Count -eq 0 -and $appIgnored) { 'passed' } else { 'failed' }
}

$json = $result | ConvertTo-Json -Depth 8
if ($ReportPath) {
    $reportDirectory = Split-Path -Parent $ReportPath
    if ($reportDirectory -and -not (Test-Path -LiteralPath $reportDirectory)) { New-Item -ItemType Directory -Path $reportDirectory -Force | Out-Null }
    Set-Content -LiteralPath $ReportPath -Value $json -Encoding utf8
}
$json
