[CmdletBinding()]
param(
    [string]$RepositoryRoot,
    [string]$ReportPath
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
}
$RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path
if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $RepositoryRoot 'reports\text-encoding.json'
} elseif (-not [System.IO.Path]::IsPathRooted($ReportPath)) {
    $ReportPath = Join-Path $RepositoryRoot ($ReportPath.Replace('/', [char]92))
}

$extensions = @('.cs', '.json', '.md', '.ps1', '.txt', '.xaml', '.xml')
$files = @(Get-ChildItem -LiteralPath $RepositoryRoot -Recurse -File -ErrorAction Stop |
    Where-Object {
        $relative = $_.FullName.Substring($RepositoryRoot.Length + 1)
        $extension = $_.Extension.ToLowerInvariant()
        $extension -in $extensions -and
        $relative -notlike 'reports\*' -and
        $relative -notlike 'dist\*' -and
        $relative -notlike 'bin\*' -and
        $relative -notlike 'obj\*' -and
        $relative -notlike 'tools\*\build\*'
    })

$strictUtf8 = [System.Text.UTF8Encoding]::new($false, $true)
$mojibakePattern = [regex]'[\u00C2\u00C3][\u00A0-\u00BF]|\uFFFD'
$errors = @()
foreach ($file in $files) {
    $relative = $file.FullName.Substring($RepositoryRoot.Length + 1).Replace('\', '/')
    try {
        $text = $strictUtf8.GetString([System.IO.File]::ReadAllBytes($file.FullName))
    } catch {
        $errors += [ordered]@{ file = $relative; kind = 'invalid-utf8'; detail = $_.Exception.Message }
        continue
    }

    $match = $mojibakePattern.Match($text)
    if ($match.Success) {
        $line = ($text.Substring(0, $match.Index) -split "`r?`n").Count
        $errors += [ordered]@{ file = $relative; kind = 'mojibake'; line = $line; detail = $match.Value }
    }
}

$result = [ordered]@{
    timestamp = (Get-Date).ToUniversalTime().ToString('o')
    scope = 'versionable-source-config-docs'
    scannedFiles = $files.Count
    excluded = @('reports/**', 'dist/**', 'bin/**', 'obj/**', 'tools/**/build/**')
    errors = $errors
    status = if ($errors.Count -eq 0) { 'passed' } else { 'failed' }
}
$json = $result | ConvertTo-Json -Depth 8
$reportDirectory = Split-Path -Parent $ReportPath
if ($reportDirectory -and -not (Test-Path -LiteralPath $reportDirectory)) {
    New-Item -ItemType Directory -Path $reportDirectory -Force | Out-Null
}
Set-Content -LiteralPath $ReportPath -Value $json -Encoding utf8
$json
if ($errors.Count -gt 0) { exit 1 }
