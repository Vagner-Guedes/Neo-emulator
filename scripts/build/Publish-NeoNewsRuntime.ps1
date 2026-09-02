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
$runtimeConfig = Get-Content -LiteralPath (Join-Path $repositoryRoot "config\runtime.json") -Raw -Encoding utf8 | ConvertFrom-Json
$persistentDiskRelativePath = ([string]$runtimeConfig.android.qemu.disk) -replace '/', '\'
$persistentDiskSourcePath = [System.IO.Path]::GetFullPath((Join-Path $repositoryRoot $persistentDiskRelativePath))
$persistentDiskTargetPath = [System.IO.Path]::GetFullPath((Join-Path $outputPath $persistentDiskRelativePath))
& $dotnetPath publish $projectPath --configuration Release --runtime win-x64 --self-contained true `
    -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true `
    -p:PublishTrimmed=false -p:PublishReadyToRun=false --output $outputPath
if ($LASTEXITCODE -ne 0) { throw "A publicação falhou com código $LASTEXITCODE." }
$layoutDirectories = @(
    "config",
    "scripts",
    "scripts\provision",
    "scripts\validation",
    "tools",
    "tools\tts-probe",
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
Copy-Item -Path (Join-Path $repositoryRoot "config\android-package-policy.json") -Destination (Join-Path $outputPath "config\android-package-policy.json") -Force
Copy-Item -Path (Join-Path $repositoryRoot "docs\*") -Destination (Join-Path $outputPath "docs") -Recurse -Force
Copy-Item -Path (Join-Path $repositoryRoot "README.md") -Destination $outputPath -Force

# Keep the operator-side optimization and voice-evidence workflow available in
# the portable publication. These are scripts/probes only; no APK is copied.
foreach ($supportFile in @(
    "scripts\provision\Optimize-AndroidGuest.ps1",
    "scripts\validation\Test-TtsSynthesis.ps1",
    "scripts\validation\ValidationEvidence.Common.ps1"
)) {
    $sourceSupportFile = Join-Path $repositoryRoot $supportFile
    $destinationSupportFile = Join-Path $outputPath $supportFile
    Copy-Item -LiteralPath $sourceSupportFile -Destination $destinationSupportFile -Force
}
Copy-Item -Path (Join-Path $repositoryRoot "tools\tts-probe\*") -Destination (Join-Path $outputPath "tools\tts-probe") -Recurse -Force

# Runtime binaries and guest images are intentionally external to the EXE.
# Copy only the local runtime directories required by the portable layout;
# never download, synthesize, or copy application/component packages during
# publication. The operator provisions those packages separately in the
# destination directory after checking their license and provenance.
foreach ($runtimeDirectory in @("qemu", "android", "adb")) {
    $sourceDirectory = Join-Path $repositoryRoot ("runtime\" + $runtimeDirectory)
    $destinationDirectory = Join-Path $outputPath ("runtime\" + $runtimeDirectory)
    if (Test-Path -LiteralPath $sourceDirectory) {
        foreach ($item in @(Get-ChildItem -LiteralPath $sourceDirectory -Force)) {
            $itemSourcePath = [System.IO.Path]::GetFullPath($item.FullName)
            if ($itemSourcePath.Equals($persistentDiskSourcePath, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $persistentDiskTargetPath)) {
                Write-Host "Preservando disco persistente existente: $persistentDiskTargetPath"
                continue
            }
            Copy-Item -LiteralPath $item.FullName -Destination $destinationDirectory -Recurse -Force
        }
    }
}
$sourceStateDirectory = Join-Path $repositoryRoot "runtime\state"
$targetStateDirectory = Join-Path $outputPath "runtime\state"
if (Test-Path -LiteralPath $sourceStateDirectory) {
    Copy-Item -Path (Join-Path $sourceStateDirectory '*') -Destination $targetStateDirectory -Recurse -Force
}
Write-Host "NeoNewsRuntime publicado em $outputPath"
