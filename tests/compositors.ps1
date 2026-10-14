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
  3. Hello --own-titlebar --selftest (IFMXWaylandWindowFrame without input: the window opens at the program's size,
     the listener, SetMaximized, SetDecorated, sizes from code) and, where the compositor can be driven, Hello
     --own-titlebar with input: no decorations, move and resize from the program's title bar, maximize and restore
     by button and double click, the compositor's window menu, activation, a popup, minimize, close;
  4. Hello --early-popup (=paint, =create): popups opened before their window is mapped (log and screenshots);
  5. on sway, KWin and GNOME Shell the portal's file dialog (xdg-desktop-portal with xdg-desktop-portal-gtk, -kde,
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
  weston sway grim kwin-wayland kwin-common kwin-style-breeze gnome-shell mutter python3-dbus wayland-utils; for part 5
  xdg-desktop-portal xdg-desktop-portal-gtk xdg-desktop-portal-kde xdg-desktop-portal-gnome qt6-wayland.

.EXAMPLE
  .\tests\compositors.ps1
  .\tests\compositors.ps1 -Runs gnome:1.5, kwin:1.5
  .\tests\compositors.ps1 -BuildRoot D:\Work\FMXWayland-build\fastcanvas -Canvas TFastCanvas
#>
param(
  [string[]] $Runs = @('weston:1', 'weston:2', 'sway:1', 'sway:2', 'sway:1.5', 'sway-csd:1', 'sway-csd:1.5', 'kwin:1',
    'kwin:2', 'kwin:1.5', 'kwin-virtual:1', 'gnome:1', 'gnome:2', 'gnome:1.5'),
  [string] $BuildRoot = 'D:\Work\FMXWayland-build',
  [string] $Distro = 'Ubuntu-26.04',
  [string] $Config = 'Release',
  # Parts of tests\compositors.sh: selftest, frame-selftest, early, scenario, frame, portal.
  [string[]] $Parts = @('selftest', 'frame-selftest', 'early', 'scenario', 'frame', 'portal'),
  # The canvas class the self-test must report (TSkRasterCanvas, TLinuxCanvas, TFastCanvas); '' = not checked.
  [string] $Canvas = ''
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'HelloChecks.psm1') -Force

$exe = Join-Path $BuildRoot "bin\Linux64\$Config\Hello"
if (-not (Test-Path $exe)) { throw "No $exe (build it first: tools\build.ps1 -Project samples\Hello\Hello.dpr)" }
$root = Join-Path $BuildRoot 'shots\compositors'
New-Item -ItemType Directory -Force -Path $root | Out-Null
# The desktop's sans-serif family as fontconfig resolves it: FMX's default font (IFMXSystemFontService).
$family = "$(wsl -d $Distro -u root -- timeout 30 fc-match -f '%{family[0]}' sans-serif)".Trim()

# PASS/FAIL lines of a dictionary of checks.
function Get-ResultLines($Checks) {
  foreach ($k in $Checks.Keys) { if ($Checks[$k]) { "PASS  $k" } else { "FAIL  $k" } }
}

# Hello --own-titlebar --selftest (IFMXWaylandWindowFrame without input; the program sizes the form 720x460 before it
# turns the decorations off and before the first show): its log and the screenshot taken while the undecorated window
# had its drop-down open.
function Get-FrameSelfTestLines([string] $Out, [string] $Label, [string] $Comp, [double] $Scale) {
  $log = "$(Get-Content (Join-Path $Out 'frame-selftest.log') -Raw -Encoding UTF8 -ErrorAction SilentlyContinue)"
  $p = "$($Label): own title bar self-test"
  $checks = Get-HelloOwnTitleBarChecks $log $p 720 460 $Scale $Comp
  $noMax = $log -match 'selftest: no maximize capability'
  foreach ($k in $checks.Keys) {
    if ($noMax -and ($k -match 'SetMaximized')) { "SKIP  $k (no maximize in the window manager's capabilities)" }
    elseif ($checks[$k]) { "PASS  $k" } else { "FAIL  $k" }
  }
  if ($Comp -ne 'kwin-virtual') {
    $shot = Join-Path $Out 'frame-selftest-dropdown.png'
    $ok, $detail = Test-HelloOwnTitleBarShot $shot
    $r = if ($ok) { 'PASS' } else { 'FAIL' }
    "$r  $($p): screenshot: the program's caption, no FMXWayland title bar ($detail)"
    $item = Get-ColorCount $shot 0x7EB0E6 6
    "$(if ($item -gt 1500) { 'PASS' } else { 'FAIL' })  $($p): screenshot: the drop-down ($item highlight pixels)"
  }
}
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
  wsl -d $Distro -u root --exec timeout 1600 bash (ConvertTo-WslPath (Join-Path $PSScriptRoot 'compositors.sh')) `
    $comp $scale (ConvertTo-WslPath $out) (ConvertTo-WslPath $exe) ($Parts -join ' ') 2>&1 | Out-Null
  $ErrorActionPreference = 'Stop'
  $lines = @(Get-Content (Join-Path $out 'results.txt') -Encoding UTF8 -ErrorAction SilentlyContinue)
  $selfLines = @()
  if ($Parts -contains 'selftest') {
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
    if ($Canvas) {
      $selfLines += if ($log -match "\[hello\] canvas $Canvas\b") { "PASS  $($label): self-test: canvas $Canvas" }
        else { "FAIL  $($label): self-test: canvas $Canvas" }
    }
    $frames = Join-Path $out 'selftest-frames'
    $size = Convert-HelloFrameDump $frames
    $bw = [int][Math]::Round($cw * [double]::Parse($scale, [Globalization.CultureInfo]::InvariantCulture))
    $bh = [int][Math]::Round($ch * [double]::Parse($scale, [Globalization.CultureInfo]::InvariantCulture))
    $selfLines += if (($null -ne $size) -and ($size.Width -eq $bw) -and ($size.Height -eq $bh)) {
      "PASS  $($label): self-test: frame dump ${bw}x${bh}"
    } else { "FAIL  $($label): self-test: frame dump ${bw}x${bh}" }
    if ($comp -ne 'kwin-virtual') {
      $selfLines += if (Test-Path (Join-Path $out 'selftest-dropdown.png')) {
        "PASS  $($label): self-test: compositor screenshot"
      } else { "FAIL  $($label): self-test: compositor screenshot" }
    }
    $selfLines += Get-ResultLines (Get-HelloFontChecks $log "$($label): self-test: font" $family)
  }
  if ($Parts -contains 'frame-selftest') {
    $selfLines += Get-FrameSelfTestLines $out $label $comp ([double]::Parse($scale,
      [Globalization.CultureInfo]::InvariantCulture))
  }
  if (($Parts -contains 'early') -and ($comp -ne 'kwin-virtual')) {
    foreach ($v in 'early-popup', 'early-popup=paint', 'early-popup=create') {
      $n = $v -replace '=', '-'
      $elog = "$(Get-Content (Join-Path $out "$n.log") -Raw -Encoding UTF8 -ErrorAction SilentlyContinue)"
      $selfLines += Get-ResultLines (Get-HelloEarlyPopupChecks $elog (Join-Path $out "$n.png") "$($label): --$v" `
        -Activates)
    }
    if ($comp -eq 'gnome') {
      # These programs run on the session's bus: GNOME's font-name through the settings portal ("Adwaita Sans 11":
      # the family fontconfig gives for it, 11 pt = 14.7 device-independent pixels).
      $gnomeFont = "$(Get-Content (Join-Path $out 'gnome-font-name.txt') -Raw -ErrorAction SilentlyContinue)".Trim()
      $words = @($gnomeFont -split ' ' | Where-Object { $_ })
      $pt = 0.0
      if (($words.Count -gt 1) -and [double]::TryParse($words[-1], [Globalization.NumberStyles]::Float,
        [Globalization.CultureInfo]::InvariantCulture, [ref]$pt)) {
        $gnomeFamily = "$(wsl -d $Distro -u root -- timeout 30 fc-match -f '%{family[0]}' ($words[0..($words.Count - 2)] -join ' '))".Trim()
        $gnomeSize = ($pt * 96 / 72).ToString('0.0', [Globalization.CultureInfo]::InvariantCulture)
        $elog = "$(Get-Content (Join-Path $out 'early-popup.log') -Raw -Encoding UTF8 -ErrorAction SilentlyContinue)"
        $selfLines += Get-ResultLines (Get-HelloFontChecks $elog "$($label): GNOME's font-name `"$gnomeFont`" through the settings portal" `
          $gnomeFamily $gnomeSize)
      } else {
        $selfLines += "FAIL  $($label): GNOME's font-name read (`"$gnomeFont`")"
      }
    }
  }
  if (($Parts -contains 'frame') -and (Test-Path (Join-Path $out 'frame-01-start.png'))) {
    $ok, $detail = Test-HelloOwnTitleBarShot (Join-Path $out 'frame-01-start.png')
    $selfLines += "$(if ($ok) { 'PASS' } else { 'FAIL' })  $($label): own title bar: screenshot: no FMXWayland " +
      "title bar ($detail)"
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
