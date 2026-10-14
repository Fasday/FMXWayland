<#
.SYNOPSIS
  Non-interactive test of samples\Hello on a private headless Weston in WSL, at output scale 1 and 2: the program must
  start, render (its own frame dump and a compositor screenshot are kept), report the buffer size of its window
  through IFMXWaylandNativeWindow, and exit cleanly. Needs the package weston in the distribution. Moves no mouse and
  types nothing (unlike tests\hello-e2e.ps1).

.EXAMPLE
  .\tests\weston-headless.ps1
#>
param(
  [string] $BuildRoot = 'D:\Work\FMXWayland-build',
  [string] $Distro = 'Ubuntu-26.04',
  [string] $Config = 'Release'
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
function WslPath([string] $p) { '/mnt/' + $p.Substring(0, 1).ToLower() + $p.Substring(2).Replace('\', '/') }

$Root = Split-Path $PSScriptRoot -Parent
$exe = Join-Path $BuildRoot "bin\Linux64\$Config\Hello"
if (-not (Test-Path $exe)) { throw "No $exe (build it first)" }
$failed = 0
foreach ($scale in 1, 2) {
  $out = Join-Path $BuildRoot "shots\weston-scale$scale"
  if (Test-Path $out) { Remove-Item -Recurse -Force $out }
  wsl -d $Distro -u root -- sh (WslPath (Join-Path $PSScriptRoot 'weston-headless.sh')) (WslPath $out) $scale `
    (WslPath $exe) --verbose --quit-after=6 2>&1 | Out-Null
  $log = Get-Content (Join-Path $out 'program.log') -Raw -Encoding UTF8
  $bw = 700 * $scale
  $bh = 540 * $scale
  $checks = [ordered]@{
    "scale $($scale): window created" = $log -match '\[hello\] created'
    "scale $($scale): native buffer ${bw}x${bh}" = $log -match "native: display=[0-9A-F]*[1-9A-F][0-9A-F]* surface=[0-9A-F]*[1-9A-F][0-9A-F]* buffer=${bw}x${bh} scale=$scale"
    "scale $($scale): clean exit" = $log -match 'exit=0'
    "scale $($scale): compositor screenshot" = [bool](Get-ChildItem $out -Filter 'wayland-screenshot*.png')
  }
  # The program's own frame dump (BMP, top-down) -> PNG.
  $dump = Get-ChildItem $out -Filter 'FMXWaylandHello-*.bmp' | Select-Object -First 1
  $checks["scale $($scale): frame dump ${bw}x${bh}"] = $false
  if ($dump) {
    $img = [System.Drawing.Image]::FromFile($dump.FullName)
    $checks["scale $($scale): frame dump ${bw}x${bh}"] = ($img.Width -eq $bw) -and ($img.Height -eq $bh)
    $img.Save((Join-Path $out 'frame.png'), [System.Drawing.Imaging.ImageFormat]::Png)
    $img.Dispose()
  }
  foreach ($k in $checks.Keys) {
    $s = if ($checks[$k]) { 'PASS' } else { $failed++; 'FAIL' }
    Write-Host "$s  $k"
  }
}
if ($failed -gt 0) { Write-Host "$failed check(s) failed"; exit 1 }
Write-Host 'All checks passed'
