[CmdletBinding()]
param(
    [string]$OutputDirectory = "dist\installer",
    [string]$PayloadDirectory = "dist\NeoNewsRuntime-current"
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$projectPath = Join-Path $repositoryRoot 'installer\NeoNews.Runtime.Installer\NeoNews.Runtime.Installer.csproj'
$payloadPath = [System.IO.Path]::GetFullPath((Join-Path $repositoryRoot $PayloadDirectory))
$outputPath = [System.IO.Path]::GetFullPath((Join-Path $repositoryRoot $OutputDirectory))
$localDotnet = Join-Path $env:LOCALAPPDATA 'NeoNewsRuntime\dotnet-sdk\dotnet.exe'
if (Test-Path -LiteralPath $localDotnet) { $dotnetPath = $localDotnet }
else {
    $dotnetCommand = Get-Command dotnet -ErrorAction SilentlyContinue
    if ($dotnetCommand) { $dotnetPath = $dotnetCommand.Source }
}
if (-not $dotnetPath) { throw 'SDK .NET 8 nao encontrado.' }
if (-not (Test-Path -LiteralPath $payloadPath -PathType Container)) { throw "Payload nao encontrado: $payloadPath" }
if (-not (Test-Path -LiteralPath (Join-Path $payloadPath 'NeoNewsRuntime.exe') -PathType Leaf)) { throw "Payload sem NeoNewsRuntime.exe: $payloadPath" }
New-Item -ItemType Directory -Path $outputPath -Force | Out-Null
& $dotnetPath publish $projectPath --configuration Release --runtime win-x64 --self-contained true `
    -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true `
    -p:PublishTrimmed=false -p:PublishReadyToRun=false --output $outputPath
if ($LASTEXITCODE -ne 0) { throw "Publicacao do instalador falhou: codigo $LASTEXITCODE." }
$setupPath = Join-Path $outputPath 'NeoNewsRuntime-Setup.exe'
if (-not (Test-Path -LiteralPath $setupPath -PathType Leaf)) { throw "Setup.exe nao foi gerado: $setupPath" }
Write-Host "NeoNewsRuntime-Setup.exe publicado em $setupPath"
