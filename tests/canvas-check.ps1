<#
.SYNOPSIS
  Compares FMX's two canvases on FMXWayland: builds tests\CanvasCheck with the Skia raster canvas and with FMX's
  cairo canvas (-Define NOSKIA), runs both on a private headless Weston in WSL at output scale 1 and 2, checks what
  the program measures (text positions with a surrogate pair, PtInPath, the PNG codec round trip, a degenerate
  matrix that must not stop the drawing) and puts the two frames side by side (<BuildRoot>\canvascheck-scale<n>.png,
  Skia left, cairo right) to look at.

.EXAMPLE
  .\tests\canvas-check.ps1
#>
param(
  [string] $BuildRoot = 'D:\Work\FMXWayland-build',
  [string] $Distro = 'Ubuntu-26.04',
  [switch] $NoBuild
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'HelloChecks.psm1') -Force
Add-Type -AssemblyName System.Drawing
$root = Split-Path $PSScriptRoot -Parent

$variants = [ordered]@{
  skia  = @{ Define = @(); Canvas = 'TSkRasterCanvas' }
  cairo = @{ Define = @('NOSKIA'); Canvas = 'TLinuxCanvas' }
}
$failed = 0
$frames = @{}
foreach ($v in $variants.Keys) {
  $vroot = Join-Path $BuildRoot "canvascheck-$v"
  if (-not $NoBuild) {
    & (Join-Path $root 'tools\build.ps1') -Project (Join-Path $PSScriptRoot 'CanvasCheck\CanvasCheck.dpr') `
      -BuildRoot $vroot -Define $variants[$v].Define | Out-Null
  }
  $exe = Join-Path $vroot 'bin\Linux64\Release\CanvasCheck'
  foreach ($scale in 1, 2) {
    $out = Join-Path $vroot "shots\scale$scale"
    if (Test-Path $out) { Remove-Item -Recurse -Force $out }
    wsl -d $Distro -u root -- sh (ConvertTo-WslPath (Join-Path $PSScriptRoot 'weston-headless.sh')) `
      (ConvertTo-WslPath $out) $scale (ConvertTo-WslPath $exe) --quit-after=4 2>&1 | Out-Null
    $log = Get-Content (Join-Path $out 'program.log') -Raw -Encoding UTF8
    $p = "$v scale $($scale)"
    $checks = [ordered]@{
      "$($p): canvas $($variants[$v].Canvas)" = $log -match "canvascheck: canvas $($variants[$v].Canvas)\b"
      "$($p): PNG saved and loaded 16x16" = $log -match 'canvascheck: png \d+ bytes, loaded 16x16'
      "$($p): PNG pixels" = $log -match 'canvascheck: png pixels FFFF0000 FF00FF00 FF0000FF FFFFFF00'
      "$($p): positions around a surrogate pair" = $log -match 'position at the right end 4, at the left end 0'
      "$($p): region of the pair" = $log -match 'region of the pair: \d+ rect\(s\), width>0 True'
      "$($p): region after the pair" = $log -match 'region of b starts after the pair: True'
      "$($p): PtInPath" = $log -match 'PtInPath inside True, outside False'
      "$($p): clean exit" = ($log -match 'canvascheck: done') -and ($log -match 'exit=0')
    }
    $dump = Get-ChildItem $out -Filter 'Canvascheck-*.bmp' | Select-Object -First 1
    $ok = $false
    if ($dump) {
      $img = [System.Drawing.Bitmap]::FromFile($dump.FullName)
      try {
        $frames["$v$scale"] = Join-Path $out 'frame.png'
        $img.Save($frames["$v$scale"], [System.Drawing.Imaging.ImageFormat]::Png)
        # The lime square drawn after the degenerate matrix.
        $ok = ($img.Width -eq 760 * $scale) -and ($img.GetPixel(725 * $scale, 525 * $scale).ToArgb() -eq -16711936)
      } finally {
        $img.Dispose()
      }
    }
    $checks["$($p): frame $(760 * $scale)x$(560 * $scale), drawing goes on after a degenerate matrix"] = $ok
    $failed += Write-Checks $checks
  }
}
foreach ($scale in 1, 2) {
  if (-not ($frames["skia$scale"] -and $frames["cairo$scale"])) { continue }
  $a = [System.Drawing.Image]::FromFile($frames["skia$scale"])
  $b = [System.Drawing.Image]::FromFile($frames["cairo$scale"])
  $both = New-Object System.Drawing.Bitmap ($a.Width + $b.Width + 8), ([Math]::Max($a.Height, $b.Height))
  $g = [System.Drawing.Graphics]::FromImage($both)
  $g.Clear([System.Drawing.Color]::DimGray)
  $g.DrawImage($a, 0, 0, $a.Width, $a.Height)
  $g.DrawImage($b, $a.Width + 8, 0, $b.Width, $b.Height)
  $file = Join-Path $BuildRoot "canvascheck-scale$scale.png"
  $both.Save($file, [System.Drawing.Imaging.ImageFormat]::Png)
  $g.Dispose(); $both.Dispose(); $a.Dispose(); $b.Dispose()
  Write-Host "Skia | cairo -> $file"
}
if ($failed -gt 0) { Write-Host "$failed check(s) failed"; exit 1 }
Write-Host 'All checks passed'
