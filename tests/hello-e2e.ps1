<#
.SYNOPSIS
  End-to-end test of samples\Hello on WSLg: starts it on the Wayland compositor of a WSL distribution, drives it with
  real input from the Windows side (WSLg forwards it to the compositor over RDP), takes screenshots, checks the
  program's log and the clipboard (WSLg shares it with Windows).

.DESCRIPTION
  Needs an interactive Windows desktop (it moves the mouse and types; the mouse position is restored at the end).
  Build first: .\tools\build.ps1 -Project samples\Hello\Hello.dpr
  Screenshots and the log go to <BuildRoot>\shots\e2e.

.EXAMPLE
  .\tests\hello-e2e.ps1
#>
param(
  [string] $BuildRoot = 'D:\Work\FMXWayland-build',
  [string] $Distro = 'Ubuntu-26.04',
  [string] $Config = 'Release'
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $Root 'tools\WinInput.psm1') -Force
$capture = Join-Path $Root 'tools\capture-window.ps1'
$shots = Join-Path $BuildRoot 'shots\e2e'
New-Item -ItemType Directory -Force -Path $shots | Out-Null
Get-ChildItem $shots -Filter '*.png' | Remove-Item
$exe = Join-Path $BuildRoot "bin\Linux64\$Config\Hello"
if (-not (Test-Path $exe)) { throw "No $exe (build it first)" }
$wslExe = '/mnt/' + $exe.Substring(0, 1).ToLower() + $exe.Substring(2).Replace('\', '/')
$logFile = Join-Path $shots 'hello.log'
$wslLog = '/mnt/' + $logFile.Substring(0, 1).ToLower() + $logFile.Substring(2).Replace('\', '/')
Remove-Item $logFile -ErrorAction SilentlyContinue

$script = @"
export XDG_RUNTIME_DIR=/mnt/wslg/runtime-dir WAYLAND_DISPLAY=wayland-0 FMXWAYLAND_LOG=1
unset DISPLAY
cd "`$(dirname $wslExe)"
timeout 120 $wslExe --verbose --quit-after=75 > $wslLog 2>&1
echo "exit=`$?" >> $wslLog
"@
$scriptFile = Join-Path $shots 'run.sh'
[IO.File]::WriteAllText($scriptFile, ($script -replace "`r", ''), (New-Object Text.UTF8Encoding $false))
$wslScript = '/mnt/' + $scriptFile.Substring(0, 1).ToLower() + $scriptFile.Substring(2).Replace('\', '/')
$proc = Start-Process wsl -ArgumentList @('-d', $Distro, '-u', 'root', '--', 'sh', $wslScript) -PassThru -WindowStyle Hidden

$results = New-Object System.Collections.Generic.List[string]
function Check([string] $Name, [bool] $Ok, [string] $Detail = '') {
  $s = if ($Ok) { 'PASS' } else { 'FAIL' }
  $results.Add("$s  $Name $Detail")
  Write-Host "$s  $Name $Detail"
}
function Shot([string] $Name, [string] $Title = 'FMXWayland Hello', [int] $ExtendBottom = 0) {
  & $capture -Title $Title -Out (Join-Path $shots "$Name.png") -TimeoutSec 5 -ExtendBottom $ExtendBottom | Out-Null
}
function LogText { if (Test-Path $logFile) { Get-Content $logFile -Raw -Encoding UTF8 } else { '' } }
function WaitLog([string] $Pattern, [int] $TimeoutMs = 3000) {
  $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
  while ((Get-Date) -lt $deadline) {
    if ((LogText) -match $Pattern) { return $true }
    Start-Sleep -Milliseconds 100
  }
  return $false
}

$saved = Get-PointerPosition
$savedClipboard = Get-Clipboard -Raw -ErrorAction SilentlyContinue
try {
  $w = Find-TopWindow 'FMXWayland Hello' 30
  if (-not $w) { throw 'The Hello window did not appear' }
  Check 'window appears' $true "($($w.Width)x$($w.Height) at $($w.Left),$($w.Top))"
  Start-Sleep -Milliseconds 1500
  Shot '01-start'

  # Pointer: motion -> the label shows the position.
  Move-PointerTo $w 300 200
  Move-PointerTo $w 310 205
  Start-Sleep -Milliseconds 500
  Shot '02-mouse'

  # Button: three clicks.
  for ($i = 0; $i -lt 3; $i++) { Invoke-Click $w 75 213 }
  Check 'button clicks' (WaitLog 'click 3') ''

  # Double click on the button counts as a click too (two presses).
  # Edit: focus and type.
  Invoke-Click $w 150 258
  # Digits and spaces: the same on every keyboard layout (WSLg uses the layout of the Windows session).
  Send-Text '2026 123'
  Check 'keyboard input into TEdit' (WaitLog 'edit "2026 123"') ''
  Shot '03-edit'

  # Editing keys: Backspace, Home, End.
  Send-Key 0x08
  Check 'Backspace' (WaitLog 'edit "2026 12"') ''
  Send-Key 0x24
  Send-Text '9'
  Check 'Home + typing' (WaitLog 'edit "92026 12"') ''
  Send-Key 0x23
  Send-Text '3'
  Check 'End + typing' (WaitLog 'edit "92026 123"') ''

  # Clipboard: FMX -> Windows.
  Invoke-Click $w 85 353
  Start-Sleep -Milliseconds 1500
  $clip = Get-Clipboard -Raw
  Check 'copy to the clipboard (seen by Windows)' ($clip -eq '92026 123') "(Windows clipboard: '$clip')"

  # Clipboard: Windows -> FMX.
  Set-Clipboard -Value 'From Windows 42'
  Start-Sleep -Milliseconds 1500
  Invoke-Click $w 225 353
  Check 'paste from the clipboard (set by Windows)' (WaitLog 'pasted "From Windows 42"') ''
  Shot '04-clipboard'

  # Ctrl+A, Ctrl+X in the edit (FMX shortcuts through the keyboard path).
  Invoke-Click $w 150 258
  Send-Key 0x41 @(0x11)
  Send-Key 0x58 @(0x11)
  Check 'Ctrl+A, Ctrl+X in TEdit' (WaitLog 'edit ""') ''
  Start-Sleep -Milliseconds 1000
  $clip = Get-Clipboard -Raw
  Check 'Ctrl+X puts the text into the clipboard' ($clip -eq '92026 123') "(Windows clipboard: '$clip')"

  # Letters: what they give depends on the keyboard layout of the session; three keys must give three characters.
  Send-Text 'abc'
  Start-Sleep -Milliseconds 500
  $letters = ([regex]::Matches((LogText), 'edit "([^"]*)"') | Select-Object -Last 1).Groups[1].Value
  Check 'letters (any layout)' ($letters.Length -eq 3) "(typed a, b, c -> '$letters')"

  # Mouse wheel over the form.
  Move-PointerTo $w 600 300
  Invoke-Wheel 2
  Invoke-Wheel -1
  Check 'mouse wheel' (WaitLog 'wheel 240') ''

  # Combo box: the drop-down list is an xdg_popup.
  Invoke-Click $w 120 303
  Start-Sleep -Milliseconds 1200
  Shot '05-combo-open' -ExtendBottom 200
  $popupOpen = (LogText) -notmatch 'combo '
  Invoke-Click $w 120 365
  Start-Sleep -Milliseconds 800
  Check 'combo box popup: choose an item' (WaitLog 'combo (Green|Blue|Yellow|Purple)') ''
  Shot '06-combo-chosen'

  # Check box.
  Invoke-Click $w 250 303
  Check 'check box' (WaitLog 'check False') ''

  # Second form (non-modal toplevel).
  Invoke-Click $w 85 403
  $w2 = Find-TopWindow 'Second form 1' 10
  Check 'second form appears' ($null -ne $w2) ''
  if ($w2) {
    Start-Sleep -Milliseconds 1000
    Shot '07-second-form' 'Second form 1'
    Invoke-Click $w2 80 95
    Check 'second form closes with its button' (WaitLog 'second form closed') ''
  }

  # Modal form.
  Invoke-Click $w 225 403
  $w3 = Find-TopWindow 'Modal form' 10
  Check 'modal form appears' ($null -ne $w3) ''
  if ($w3) {
    Start-Sleep -Milliseconds 1000
    Shot '08-modal' 'Modal form'
    # The main window does not react while the modal form is up.
    Invoke-Click $w 75 213
    Start-Sleep -Milliseconds 500
    Check 'main window blocked while modal' ((LogText) -notmatch 'click 4') ''
    Invoke-Click $w3 80 105
    Check 'modal result OK' (WaitLog 'modal result 1') ''
  }

  # Second form closed by the compositor (WM_CLOSE -> WSLg -> xdg_toplevel.close -> FMX Close).
  Invoke-Click $w 85 403
  $w4 = Find-TopWindow 'Second form 2' 10
  Check 'another second form appears' ($null -ne $w4) ''
  if ($w4) {
    Start-Sleep -Milliseconds 800
    Close-TopWindow $w4
    Check 'close request from the compositor closes the form' (WaitLog 'second form closed[\s\S]*second form closed') ''
    Start-Sleep -Milliseconds 800
    Check 'its window is gone' (-not (Test-TopWindow 'Second form 2')) ''
  }

  # Maximize (xdg_toplevel.set_maximized -> configure with the new size -> FMX resize) and back.
  Invoke-Click $w 365 403
  Check 'maximize: the compositor resizes the window' (WaitLog 'resize \d+x\d+ state 2' 5000) ''
  Start-Sleep -Milliseconds 1000
  $wm = Find-TopWindow 'FMXWayland Hello' 5
  Check 'maximized window is larger' ($wm.Width -gt 1000) "($($wm.Width)x$($wm.Height))"
  Shot '09-maximized'
  Invoke-Click $wm 365 403
  Check 'restore: back to 700x540' (WaitLog 'resize 700x540 state 0' 5000) ''
  Start-Sleep -Milliseconds 1000
  $w = Find-TopWindow 'FMXWayland Hello' 5

  # Resize from code (FMX ClientWidth/ClientHeight -> new buffer size).
  Invoke-Click $w 505 403
  Check 'resize from code' (WaitLog 'resized by code to 760x560') ''
  Start-Sleep -Milliseconds 1000
  $w = Find-TopWindow 'FMXWayland Hello' 5
  Check 'window has the new size' (($w.Width -eq 760) -and ($w.Height -eq 560)) "($($w.Width)x$($w.Height))"

  Move-PointerTo $w 500 250
  Start-Sleep -Milliseconds 500
  Shot '10-end'
} finally {
  Set-PointerPosition $saved
  if ($savedClipboard) { Set-Clipboard -Value $savedClipboard }
}

# The program closes itself (--quit-after); it must exit cleanly.
$proc.WaitForExit(90000) | Out-Null
Check 'clean exit' ((LogText) -match 'exit=0') ''
$results | Set-Content (Join-Path $shots 'results.txt')
Write-Host "Log: $logFile"
$failed = @($results | Where-Object { $_ -like 'FAIL*' }).Count
if ($failed -gt 0) { Write-Host "$failed check(s) failed"; exit 1 }
Write-Host 'All checks passed'
