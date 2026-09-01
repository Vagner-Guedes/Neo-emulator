[CmdletBinding()]
param(
    [string]$OutputPath = "launcher\NeoNews.Runtime.Launcher\Assets\NeoNewsRuntime.ico"
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$targetPath = Join-Path $repositoryRoot $OutputPath
New-Item -ItemType Directory -Path (Split-Path $targetPath -Parent) -Force | Out-Null

$bitmap = New-Object System.Drawing.Bitmap 64, 64
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
$graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$graphics.Clear([System.Drawing.Color]::FromArgb(11, 16, 23))
$background = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(14, 116, 144))
$foreground = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(207, 250, 254))
$font = New-Object System.Drawing.Font("Segoe UI", 38, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
$graphics.FillRectangle($background, 4, 4, 56, 56)
$graphics.DrawString("N", $font, $foreground, 12, 7)
$handle = $bitmap.GetHicon()
$icon = [System.Drawing.Icon]::FromHandle($handle)
$stream = [System.IO.File]::Create($targetPath)
try { $icon.Save($stream) }
finally {
    $stream.Dispose()
    $icon.Dispose()
    $font.Dispose()
    $foreground.Dispose()
    $background.Dispose()
    $graphics.Dispose()
    $bitmap.Dispose()
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class NeoNewsIconNative { [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr handle); }
'@
    [NeoNewsIconNative]::DestroyIcon($handle) | Out-Null
}
Write-Host "Ícone criado em $targetPath"
