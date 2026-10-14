<#
.SYNOPSIS
  Non-interactive test of samples\Hello on a private headless Weston in WSL, at output scale 1 and 2: the program must
  start, render (its own frame dump and a compositor screenshot are kept), report the buffer size of its window
  through IFMXWaylandNativeWindow, and exit cleanly. Needs the package weston in the distribution. Moves no mouse and
  types nothing (unlike tests\hello-e2e.ps1). -Canvas also checks the canvas class the program reports (TLinuxCanvas:
  FMX's cairo canvas, a build with -Define NOSKIA; TSkRasterCanvas: Skia).

.EXAMPLE
  .\tests\weston-headless.ps1
  .\tests\weston-headless.ps1 -BuildRoot D:\Work\FMXWayland-build\cairo -Canvas TLinuxCanvas
#>
param(
  [string] $BuildRoot = 'D:\Work\FMXWayland-build',
  [string] $Distro = 'Ubuntu-26.04',
  [string] $Config = 'Release',
  [string] $Canvas = ''
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'HelloChecks.psm1') -Force

$exe = Join-Path $BuildRoot "bin\Linux64\$Config\Hello"
if (-not (Test-Path $exe)) { throw "No $exe (build it first)" }
$failed = 0
foreach ($scale in 1, 2) {
  $out = Join-Path $BuildRoot "shots\weston-scale$scale"
  if (Test-Path $out) { Remove-Item -Recurse -Force $out }
  wsl -d $Distro -u root -- sh (ConvertTo-WslPath (Join-Path $PSScriptRoot 'weston-headless.sh')) (ConvertTo-WslPath $out) `
    $scale (ConvertTo-WslPath $exe) --selftest --quit-after=25 2>&1 | Out-Null
  $log = Get-Content (Join-Path $out 'program.log') -Raw -Encoding UTF8
  $checks = Get-HelloSelfTestChecks $log "scale $scale" $scale
  if ($Canvas) { $checks["scale $($scale): canvas $Canvas"] = $log -match "\[hello\] canvas $Canvas\b" }
  $checks["scale $($scale): compositor screenshot"] = [bool](Get-ChildItem $out -Filter 'wayland-screenshot*.png')
  $size = Convert-HelloFrameDump $out
  $checks["scale $($scale): frame dump $(700 * $scale)x$(540 * $scale)"] = ($null -ne $size) -and
    ($size.Width -eq 700 * $scale) -and ($size.Height -eq 540 * $scale)
  $failed += Write-Checks $checks
}
if ($failed -gt 0) { Write-Host "$failed check(s) failed"; exit 1 }
Write-Host 'All checks passed'
