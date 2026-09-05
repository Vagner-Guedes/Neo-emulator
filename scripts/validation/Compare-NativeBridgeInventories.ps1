[CmdletBinding()]
param(
    [string]$RepositoryRoot,
    [string]$BaseReportPath = 'reports/nativebridge-base-inventory.json',
    [string]$PublishedReportPath = 'reports/nativebridge-published-current-inventory.json',
    [string]$ReportPath = 'reports/nativebridge-base-vs-publish.json'
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) { $RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path }
$RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path
function Resolve-ReportPath([string]$Path) { if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }; Join-Path $RepositoryRoot $Path }
function Read-Text([object]$Value) { if ($null -eq $Value) { return '' }; [string]$Value.text }
function Get-File([object]$Inventory, [string]$Path) { @($Inventory.files | Where-Object { $_.path -eq $Path } | Select-Object -First 1)[0] }

$base = Get-Content -LiteralPath (Resolve-ReportPath $BaseReportPath) -Raw -Encoding utf8 | ConvertFrom-Json
$published = Get-Content -LiteralPath (Resolve-ReportPath $PublishedReportPath) -Raw -Encoding utf8 | ConvertFrom-Json
$properties = @('persist.sys.nativebridge', 'ro.dalvik.vm.native.bridge', 'ro.enable.native.bridge', 'ro.product.cpu.abilist', 'ro.product.cpu.abilist32', 'ro.product.cpu.abilist64', 'ro.product.cpu.abi', 'ro.zygote')
$paths = @('/system/lib/libnb.so', '/system/lib64/libnb.so', '/system/lib/libhoudini.so', '/system/lib64/libhoudini.so', '/data/arm/houdini7_y.sfs', '/data/arm/houdini7_z.sfs')
$differences = @()
foreach ($property in $properties) {
    $left = Read-Text $base.properties.$property; $right = Read-Text $published.properties.$property
    if ($left -ne $right) { $differences += [ordered]@{ type = 'property'; key = $property; base = $left; published = $right } }
}
foreach ($path in $paths) {
    $left = Get-File $base $path; $right = Get-File $published $path
    $leftHash = if ($left) { Read-Text $left.sha256 } else { '' }; $rightHash = if ($right) { Read-Text $right.sha256 } else { '' }
    # An empty published hash with a nonzero command exit code is incomplete
    # transport evidence, not a claimed artifact difference.
    $rightExitCode = if ($right) { [int]$right.sha256.exitCode } else { -1 }
    if ($leftHash -ne $rightHash -and $rightExitCode -eq 0 -and $rightHash -notmatch '(?i)device offline') { $differences += [ordered]@{ type = 'sha256'; key = $path; base = $leftHash; published = $rightHash } }
}
$publishedTransportErrors = @($published.files | Where-Object { ((Read-Text $_.ls) + ' ' + (Read-Text $_.sha256)) -match '(?i)device offline|device not found|closed' } | ForEach-Object { $_.path })
$result = [ordered]@{
    timestamp = (Get-Date).ToUniversalTime().ToString('o')
    base = [ordered]@{ diskSha256 = $base.sourceDiskSha256; status = $base.status }
    published = [ordered]@{ diskSha256 = $published.sourceDiskSha256; status = $published.status }
    comparison = [ordered]@{ propertyKeys = $properties; artifactPaths = $paths; differences = $differences; publishedTransportErrors = $publishedTransportErrors }
    conclusion = if ($differences.Count -eq 0) { 'NATIVE_BRIDGE_STATE_MATCHES; published inventory had bounded ADB transport errors where listed.' } else { 'NATIVE_BRIDGE_STATE_DIFFERS; inspect differences before publication.' }
}
$full = Resolve-ReportPath $ReportPath
New-Item -ItemType Directory -Path (Split-Path -Parent $full) -Force | Out-Null
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $full -Encoding utf8
$result | ConvertTo-Json -Depth 8
if ($differences.Count -gt 0) { throw 'Native Bridge base/publish inventory differs.' }
