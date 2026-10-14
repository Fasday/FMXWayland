<#
.SYNOPSIS
  samples\Hello on real compositors started headless in WSL: Weston, sway (wlroots), KWin, GNOME Shell (Mutter), at
  scale 1, 2 and fractional 1.5 where the compositor offers wp-fractional-scale-v1. Nothing is shown on the desktop
  and no Windows input is used.

.DESCRIPTION
  For each run (<compositor>:<scale>) tests\compositors.sh starts the compositor in a private runtime directory, home
  and D-Bus session of the WSL distribution and runs
  1. Hello --selftest (threads, clipboard, combo box drop-down, second form, maximize/restore, modal loop: the checks
     of tests\weston-headless.ps1), with a compositor screenshot while the drop-down is open;
  2. where the compositor can be driven from outside (sway: virtual pointer/keyboard; KWin: fake input and scripts;
     GNOME Shell: Clutter virtual devices through org.gnome.Shell.Eval, made possible by a test extension), a scenario
     with input (tests\wltool.py): clicks, keyboard text and shortcuts, wheel, clipboard both ways with another
     application, the combo box popup (placed where asked, an item clicked), check box, second form, xdg-activation
     of the main form from it, close from the compositor, the client-side title bar's buttons, a modal form (the main
     form blocked meanwhile), FMX's own file dialogs (no portal on the program's bus: a double click opens a file, a
     typed name saves, Escape cancels), maximize/restore from the program, the compositor and the title bar, resize
     from code, close of the main form by the compositor and a clean exit;
  3. on sway, KWin and GNOME Shell the portal's file dialog (xdg-desktop-portal with xdg-desktop-portal-gtk, -kde,
     and -gtk under GNOME Shell: -gnome hands file dialogs to Nautilus, which does not run as root): the request, the
     dialog as a child of the program's window (xdg-foreign), the program's loop running and its main window ignoring
     a close meanwhile, a file chosen and a name typed with the keyboard, Escape, a request that another client may not
     close, the program ending while the dialog is open (its request closed, the dialog gone).
  Compositors: weston (client-side decorations; self-test only: no input injection), sway (server-side title bar),
  sway-csd (sway with "border csd": the program's title bar through xdg-decoration), kwin (nested in a headless sway,
  whose output grim captures: KWin's ScreenShot2 needs OpenGL, which its virtual backend lacks in WSL), kwin-virtual
  (kwin_wayland --virtual: self-test and frame dumps only; its --scale 1.5 makes a 1920x1200 output at scale 1, so
  KWin's scales are tested nested), gnome (gnome-shell --headless --virtual-monitor; gdctl sets the scale).

  Output: <BuildRoot>\shots\compositors\<compositor>-<scale>\ (results.txt, steps.log, the program's logs, PNG
  screenshots, frame dumps) and <BuildRoot>\shots\compositors\summary.md (the matrix). Packages (Ubuntu 26.04):
  weston sway grim kwin-wayland kwin-common kwin-style-breeze gnome-shell mutter python3-dbus wayland-utils; for part 3
  xdg-desktop-portal xdg-desktop-portal-gtk xdg-desktop-portal-kde xdg-desktop-portal-gnome qt6-wayland.

.EXAMPLE
  .\tests\compositors.ps1
  .\tests\compositors.ps1 -Runs gnome:1.5, kwin:1.5
#>
param(
  [string[]] $Runs = @('weston:1', 'weston:2', 'sway:1', 'sway:2', 'sway:1.5', 'sway-csd:1', 'sway-csd:1.5', 'kwin:1',
    'kwin:2', 'kwin:1.5', 'kwin-virtual:1', 'gnome:1', 'gnome:2', 'gnome:1.5'),
  [string] $BuildRoot = 'D:\Work\FMXWayland-build',
  [string] $Distro = 'Ubuntu-26.04',
  [string] $Config = 'Release'
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'HelloChecks.psm1') -Force

$exe = Join-Path $BuildRoot "bin\Linux64\$Config\Hello"
if (-not (Test-Path $exe)) { throw "No $exe (build it first: tools\build.ps1 -Project samples\Hello\Hello.dpr)" }
$root = Join-Path $BuildRoot 'shots\compositors'
New-Item -ItemType Directory -Force -Path $root | Out-Null
$all = [ordered]@{}
$columns = @()
foreach ($run in $Runs) {
  $comp, $scale = $run -split ':'
  $label = "$comp scale $scale"
  $columns += $label
  $out = Join-Path $root "$comp-$scale"
  Write-Host "== $label"
  # Native stderr redirected: error records that must not stop the script.
  $ErrorActionPreference = 'Continue'
  wsl -d $Distro -u root --exec timeout 720 bash (ConvertTo-WslPath (Join-Path $PSScriptRoot 'compositors.sh')) $comp `
    $scale (ConvertTo-WslPath $out) (ConvertTo-WslPath $exe) 2>&1 | Out-Null
  $ErrorActionPreference = 'Stop'
  $lines = @(Get-Content (Join-Path $out 'results.txt') -Encoding UTF8 -ErrorAction SilentlyContinue)
  # The self-test, checked as tests\weston-headless.ps1 does.
  $log = "$(Get-Content (Join-Path $out 'selftest.log') -Raw -Encoding UTF8 -ErrorAction SilentlyContinue)"
  # Sway keeps the outer size (700x540) of a window it switches to client-side decorations: the client area is
  # smaller by the program's title bar and borders.
  $cw, $ch = if ($comp -eq 'sway-csd') { 692, 506 } else { 700, 540 }
  $self = Get-HelloSelfTestChecks $log "$($label): self-test" ([double]::Parse($scale,
    [Globalization.CultureInfo]::InvariantCulture)) $cw $ch
  $noMax = ($log -match 'wm capabilities of "FMXWayland Hello":(.*)') -and ($Matches[1] -notmatch 'maximize')
  $selfLines = foreach ($k in $self.Keys) {
    if ($noMax -and ($k -match 'maximize|restore')) { "SKIP  $k (no maximize in the window manager's capabilities)" }
    elseif ($self[$k]) { "PASS  $k" } else { "FAIL  $k" }
  }
  $frames = Join-Path $out 'selftest-frames'
  $size = Convert-HelloFrameDump $frames
  $bw = [int][Math]::Round($cw * [double]::Parse($scale, [Globalization.CultureInfo]::InvariantCulture))
  $bh = [int][Math]::Round($ch * [double]::Parse($scale, [Globalization.CultureInfo]::InvariantCulture))
  $selfLines += if (($null -ne $size) -and ($size.Width -eq $bw) -and ($size.Height -eq $bh)) {
    "PASS  $($label): self-test: frame dump ${bw}x${bh}" } else { "FAIL  $($label): self-test: frame dump ${bw}x${bh}" }
  if ($comp -ne 'kwin-virtual') {
    $selfLines += if (Test-Path (Join-Path $out 'selftest-dropdown.png')) {
      "PASS  $($label): self-test: compositor screenshot" } else { "FAIL  $($label): self-test: compositor screenshot" }
  }
  $lines = @($selfLines) + $lines
  $lines | Set-Content (Join-Path $out 'results-all.txt') -Encoding UTF8
  foreach ($l in $lines) {
    Write-Host $l
    if ($l -match '^(PASS|FAIL|SKIP)  ([^:]+): (.*?)( \(.*\))?$') {
      $name = $Matches[3] -replace ' \(.*$', ''
      if (-not $all.Contains($name)) { $all[$name] = @{} }
      $all[$name][$label] = $Matches[1]
    }
  }
  $p = @($lines | Where-Object { $_ -like 'PASS*' }).Count
  $f = @($lines | Where-Object { $_ -like 'FAIL*' }).Count
  $s = @($lines | Where-Object { $_ -like 'SKIP*' }).Count
  Write-Host "-- $($label): $p passed, $f failed, $s skipped"
}

# The matrix: checks x runs.
$md = @('| Check | ' + ($columns -join ' | ') + ' |', '|---|' + (($columns | ForEach-Object { '---' }) -join '|') + '|')
foreach ($name in $all.Keys) {
  $cells = foreach ($c in $columns) {
    switch ($all[$name][$c]) { 'PASS' { 'pass' } 'FAIL' { '**FAIL**' } 'SKIP' { 'n/a' } default { '' } }
  }
  $md += "| $name | " + ($cells -join ' | ') + ' |'
}
$md | Set-Content (Join-Path $root 'summary.md') -Encoding UTF8
$failed = @($all.Keys | Where-Object { $all[$_].Values -contains 'FAIL' }).Count
Write-Host "Summary: $(Join-Path $root 'summary.md')"
if ($failed -gt 0) { Write-Host "$failed check(s) failed somewhere"; exit 1 }
Write-Host 'All checks passed'
