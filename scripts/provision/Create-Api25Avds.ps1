[CmdletBinding()]
param(
    [string]$SdkRoot = (Join-Path $env:LOCALAPPDATA 'Android\Sdk'),
    [string]$DeviceId = 'pixel_2',
    [switch]$SkipArmVariants
)

$ErrorActionPreference = 'Stop'

$avdManager = Join-Path $SdkRoot 'cmdline-tools\latest\bin\avdmanager.bat'
if (-not (Test-Path -LiteralPath $avdManager)) {
    throw "avdmanager não encontrado em $avdManager. Execute Install-AndroidRuntime.ps1 primeiro."
}

function New-NeoNewsAvd([string]$Name, [string]$Package) {
    Write-Host "Criando AVD $Name ($Package)..."
    'no' | & $avdManager create avd --name $Name --package $Package --device $DeviceId --force
    if ($LASTEXITCODE -ne 0) {
        throw "Falha ao criar o AVD $Name (exit code $LASTEXITCODE)."
    }

    $iniPath = Join-Path $env:USERPROFILE ".android\avd\${Name}.ini"
    if (-not (Test-Path -LiteralPath $iniPath)) {
        throw "O AVD $Name não foi criado: $iniPath não existe."
    }
}

New-NeoNewsAvd 'NeoNews_API25_x86' 'system-images;android-25;google_apis;x86'

if (-not $SkipArmVariants) {
    New-NeoNewsAvd 'NeoNews_API25_arm32' 'system-images;android-25;google_apis;armeabi-v7a'
    New-NeoNewsAvd 'NeoNews_API25_arm64' 'system-images;android-25;google_apis;arm64-v8a'
}

Write-Host 'AVDs NeoNews API 25 criados.'
