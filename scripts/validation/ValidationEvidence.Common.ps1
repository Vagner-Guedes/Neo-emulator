$ErrorActionPreference = 'Stop'

function Resolve-ValidationReportPath {
    param(
        [string]$RepositoryRoot,
        [string]$ReportPath
    )

    if ([string]::IsNullOrWhiteSpace($ReportPath)) { return $null }
    if ([System.IO.Path]::IsPathRooted($ReportPath)) {
        return [System.IO.Path]::GetFullPath($ReportPath)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $RepositoryRoot ($ReportPath -replace '/', '\')))
}

function Initialize-ValidationReport {
    param(
        [string]$ReportPath,
        [string]$Validator,
        [hashtable]$Context
    )

    if ([string]::IsNullOrWhiteSpace($ReportPath)) { return $null }
    $fullPath = [System.IO.Path]::GetFullPath($ReportPath)
    $parent = Split-Path -Parent $fullPath
    if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $placeholder = [ordered]@{
        timestamp = [DateTimeOffset]::UtcNow.ToString('o')
        status = 'not-validated'
        evidenceState = 'invalidated'
        invalidationReason = 'validation-started'
        validator = $Validator
        context = if ($null -eq $Context) { [ordered]@{} } else { $Context }
    }
    $placeholder | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $fullPath -Encoding utf8
    return $fullPath
}
