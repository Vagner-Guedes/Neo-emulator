[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path,
    [string]$ReportPath
)

$ErrorActionPreference = 'Stop'
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
    $null = Get-Content -LiteralPath $configPath -Raw -Encoding utf8 | ConvertFrom-Json
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
    'launcher/NeoNews.Runtime.Launcher/NeoNews.Runtime.Launcher.csproj'
)
$missingPaths = @($requiredPaths | Where-Object { -not (Test-Path -LiteralPath (Join-Path $RepositoryRoot $_)) })
$appIgnored = $false
Push-Location $RepositoryRoot
try {
    git check-ignore --quiet -- app.apk
    $appIgnored = $LASTEXITCODE -eq 0
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
