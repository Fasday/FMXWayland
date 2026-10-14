<#
.SYNOPSIS
  Non-interactive test of samples\Hello on a private headless Weston in WSL, at output scale 1 and 2: the program must
  start, render (its own frame dump and a compositor screenshot are kept), report the buffer size of its window
  through IFMXWaylandNativeWindow, and exit cleanly. Needs the package weston in the distribution. Moves no mouse and
  types nothing (unlike tests\hello-e2e.ps1). -Canvas also checks the canvas class the program reports (TLinuxCanvas:
  FMX's cairo canvas, a build with -Define NOSKIA; TSkRasterCanvas: Skia).

.DESCRIPTION
  Besides the self-test at scale 1 and 2:
  - the default font (IFMXSystemFontService): fontconfig's sans-serif family at 12, and FMXWAYLAND_FONT taken by the
    canvas (a serif family: the text measures differently from the fallbacks);
  - popups of windows that are not mapped yet (Hello --early-popup, =paint, =create): the drop-down must become an
    xdg_popup of the main window once that is mapped, and both must be on the screen (pixels of the screenshot);
  - Hello --own-titlebar --selftest (IFMXWaylandWindowFrame without input): decorations off, states and capabilities
    through the listener, maximize/restore through the service, decorations on and off again; no FMXWayland title
    bar in the screenshot.

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

# One run of Hello on a fresh headless Weston: <BuildRoot>\shots\<Name>; returns the log and the screenshot.
function Invoke-WestonRun([string] $Name, [int] $Scale, [string[]] $Arguments, [string[]] $Environment = @(),
  [double] $ShotAfter = 3) {
  $out = Join-Path $BuildRoot "shots\$Name"
  if (Test-Path $out) { Remove-Item -Recurse -Force $out }
  $envArgs = @("SHOT_AFTER=$([string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0}', $ShotAfter))") +
    $Environment
  # --exec: the arguments as they are (a font name with a space).
  wsl -d $Distro -u root --exec env @envArgs timeout 120 sh `
    (ConvertTo-WslPath (Join-Path $PSScriptRoot 'weston-headless.sh')) (ConvertTo-WslPath $out) $Scale `
    (ConvertTo-WslPath $exe) @Arguments 2>&1 | Out-Null
  [pscustomobject]@{
    Dir = $out
    Log = "$(Get-Content (Join-Path $out 'program.log') -Raw -Encoding UTF8 -ErrorAction SilentlyContinue)"
    Shot = (Get-ChildItem $out -Filter 'wayland-screenshot*.png' -ErrorAction SilentlyContinue |
      Select-Object -First 1 -ExpandProperty FullName)
  }
}

# The desktop's sans-serif family as fontconfig resolves it in the distribution.
$family = "$(wsl -d $Distro -u root -- timeout 30 fc-match -f '%{family[0]}' sans-serif)".Trim()

foreach ($scale in 1, 2) {
  $r = Invoke-WestonRun "weston-scale$scale" $scale @('--selftest', '--quit-after=25')
  $checks = Get-HelloSelfTestChecks $r.Log "scale $scale" $scale
  if ($Canvas) { $checks["scale $($scale): canvas $Canvas"] = $r.Log -match "\[hello\] canvas $Canvas\b" }
  $checks["scale $($scale): compositor screenshot"] = [bool]$r.Shot
  $size = Convert-HelloFrameDump $r.Dir
  $checks["scale $($scale): frame dump $(700 * $scale)x$(540 * $scale)"] = ($null -ne $size) -and
    ($size.Width -eq 700 * $scale) -and ($size.Height -eq 540 * $scale)
  $fonts = Get-HelloFontChecks $r.Log "scale $($scale): font" $family
  foreach ($k in $fonts.Keys) { $checks[$k] = $fonts[$k] }
  $failed += Write-Checks $checks
}

# The default font from FMXWAYLAND_FONT: the canvas must measure (and draw) the default text in it.
$r = Invoke-WestonRun 'weston-font' 1 @('--verbose', '--quit-after=3') @('FMXWAYLAND_FONT=DejaVu Serif,13') 2
$failed += Write-Checks (Get-HelloFontChecks $r.Log 'FMXWAYLAND_FONT' 'DejaVu Serif' '13.0' -Distinct)

# Popups of windows that are not mapped yet.
foreach ($v in 'early-popup', 'early-popup=paint', 'early-popup=create') {
  $r = Invoke-WestonRun "weston-$($v -replace '=', '-')" 1 @("--$v", '--quit-after=5') @() 2.5
  $failed += Write-Checks (Get-HelloEarlyPopupChecks $r.Log $r.Shot "--$v")
}

# The window frame service without input. The program sizes the form (720x460, 1180x640; once more after the frame is
# attached) and turns the decorations off before the first show: the window opens at that size.
foreach ($run in @(@(1, 720, 460, @()), @(2, 720, 460, @()), @(1, 1180, 640, @('--size=1180x640')),
  @(2, 1180, 640, @('--size=1180x640')), @(1, 900, 600, @('--size=1180x640', '--size-after=900x600')))) {
  $scale, $w, $h, $extra = $run
  $r = Invoke-WestonRun "weston-own-titlebar-$($w)x$h-scale$scale" $scale (@('--own-titlebar', '--selftest',
    '--quit-after=25') + $extra) @() 3.5
  $p = if ($extra) { "own title bar $($extra -join ' '), scale $scale" } else { "own title bar, scale $scale" }
  $checks = Get-HelloOwnTitleBarChecks $r.Log $p $w $h $scale
  $shotOk, $detail = Test-HelloOwnTitleBarShot $r.Shot
  $checks["$($p): screenshot: the program's caption, no FMXWayland title bar ($detail)"] = $shotOk
  $checks["$($p): screenshot: the drop-down ($(Get-ColorCount $r.Shot 0x7EB0E6 6) highlight pixels)"] =
    (Get-ColorCount $r.Shot 0x7EB0E6 6) -gt 1500 * $scale * $scale
  $failed += Write-Checks $checks
}

if ($failed -gt 0) { Write-Host "$failed check(s) failed"; exit 1 }
Write-Host 'All checks passed'
