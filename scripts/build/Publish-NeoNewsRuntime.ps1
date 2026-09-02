[CmdletBinding()]
param(
    [string]$OutputDirectory = "dist\NeoNewsRuntime"
)

$ErrorActionPreference = "Stop"
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$projectPath = Join-Path $repositoryRoot "launcher\NeoNews.Runtime.Launcher\NeoNews.Runtime.Launcher.csproj"
$localDotnet = Join-Path $env:LOCALAPPDATA "NeoNewsRuntime\dotnet-sdk\dotnet.exe"
if (Test-Path $localDotnet) {
    $dotnetPath = $localDotnet
}
else {
    $dotnetCommand = Get-Command dotnet -ErrorAction SilentlyContinue
    if ($dotnetCommand) { $dotnetPath = $dotnetCommand.Source }
}
if (-not $dotnetPath) { throw "SDK .NET 8 não encontrado." }

$outputPath = Join-Path $repositoryRoot $OutputDirectory
& $dotnetPath publish $projectPath --configuration Release --runtime win-x64 --self-contained true `
    -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true `
    -p:PublishTrimmed=false -p:PublishReadyToRun=false --output $outputPath
if ($LASTEXITCODE -ne 0) { throw "A publicação falhou com código $LASTEXITCODE." }
$layoutDirectories = @(
    "config",
    "runtime",
    "runtime\qemu",
    "runtime\android",
    "runtime\adb",
    "runtime\state",
    "packages",
    "packages\neonews",
    "packages\webview",
    "packages\tts",
    "packages\nativebridge",
    "logs",
    "reports",
    "docs"
)
foreach ($directory in $layoutDirectories) {
    New-Item -ItemType Directory -Path (Join-Path $outputPath $directory) -Force | Out-Null
}
Copy-Item -Path (Join-Path $repositoryRoot "config\runtime.json") -Destination (Join-Path $outputPath "config\runtime.json") -Force
Copy-Item -Path (Join-Path $repositoryRoot "docs\*") -Destination (Join-Path $outputPath "docs") -Recurse -Force
Copy-Item -Path (Join-Path $repositoryRoot "README.md") -Destination $outputPath -Force

# Runtime binaries and guest images are intentionally external to the EXE.
# Copy only the local runtime directories required by the portable layout;
# never download, synthesize, or copy application/component packages during
# publication. The operator provisions those packages separately in the
# destination directory after checking their license and provenance.
foreach ($runtimeDirectory in @("qemu", "android", "adb")) {
    $sourceDirectory = Join-Path $repositoryRoot ("runtime\" + $runtimeDirectory)
    $destinationDirectory = Join-Path $outputPath ("runtime\" + $runtimeDirectory)
    if (Test-Path -LiteralPath $sourceDirectory) {
        Copy-Item -LiteralPath $sourceDirectory -Destination $destinationDirectory -Recurse -Force
    }
}
Write-Host "NeoNewsRuntime publicado em $outputPath"
