[CmdletBinding()]
param(
    [string]$RepositoryRoot,
    [string]$AndroidSdkRoot = (Join-Path $env:LOCALAPPDATA 'Android\Sdk'),
    [string]$BuildToolsVersion = '25.0.3',
    [string]$OutputPath = 'runtime/android/adb-relay.dex'
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
}

$sourcePath = Join-Path $RepositoryRoot 'scripts\adb\AdbIpv4Relay.java'
$androidJar = Join-Path $AndroidSdkRoot 'platforms\android-25\android.jar'
$dxJar = Join-Path $AndroidSdkRoot "build-tools\$BuildToolsVersion\lib\dx.jar"
$javac = if ($env:JAVA_HOME) { Join-Path $env:JAVA_HOME 'bin\javac.exe' } else { 'javac.exe' }
$java = if ($env:JAVA_HOME) { Join-Path $env:JAVA_HOME 'bin\java.exe' } else { 'java.exe' }
$buildDirectory = Join-Path $RepositoryRoot 'runtime\android\adb-relay-build'
$outputFile = if ([System.IO.Path]::IsPathRooted($OutputPath)) { $OutputPath } else { Join-Path $RepositoryRoot ($OutputPath -replace '/', '\') }

foreach ($required in @($sourcePath, $androidJar, $dxJar)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Componente local ausente: $required"
    }
}

New-Item -ItemType Directory -Path $buildDirectory -Force | Out-Null
New-Item -ItemType Directory -Path (Split-Path -Parent $outputFile) -Force | Out-Null

& $javac -source 7 -target 7 -classpath $androidJar -d $buildDirectory $sourcePath
if ($LASTEXITCODE -ne 0) { throw "javac falhou com o código $LASTEXITCODE." }

& $java -Xmx1024M -cp $dxJar com.android.dx.command.Main --dex --output=$outputFile $buildDirectory
if ($LASTEXITCODE -ne 0) { throw "dx falhou com o código $LASTEXITCODE." }

Get-FileHash -LiteralPath $outputFile -Algorithm SHA256
