<#
.SYNOPSIS
  Checks FMXWayland's D-Bus client against a real bus and the dialog backend: builds tests\DialogCheck (FMX's default
  canvas) and runs it on a private headless Weston in WSL with a private session bus (tests\dialog-check.sh).

.DESCRIPTION
  D-Bus: an address list whose first socket does not exist, an abstract socket with guid=, a path, unix:runtime=yes,
  a non-Unix address (EDBusUnavailable); SASL EXTERNAL; method calls with strings, arrays and a dictionary of variants
  (GetConnectionCredentials: our uid and pid); an error reply with its name; a call nobody answers (timeout); a signal
  (NameOwnerChanged of a connection that goes away, kept while other calls wait); a pump that cancels; no portal on
  the bus (unavailable at once). Dialog backend: a test backend installed with SetWaylandDialogBackend gets what
  TOpenDialog (filters, filter index, multiple), TSaveDialog (overwrite prompt), SelectDirectory, TDialogService (sync
  and async message, input query) and FmuxMessageDialog/FmuxInputQuery hand it; what fits into FMX's buffer of 1024
  characters arrives; nil restores FMX's own dialog services. Default font: Pango font descriptions; the settings
  portal (tests\settings-portal.py on two more buses: ReadOne, and an old portal with only Read) read for GNOME's
  font-name in a GNOME session only (not in KDE, not with FMXWAYLAND_PORTAL=0), a missing key, no portal (fontconfig
  at once).

.EXAMPLE
  .\tests\dialog-check.ps1
#>
param(
  [string] $BuildRoot = 'D:\Work\FMXWayland-build\dialogcheck',
  [string] $Distro = 'Ubuntu-26.04',
  [switch] $NoBuild
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'HelloChecks.psm1') -Force
$root = Split-Path $PSScriptRoot -Parent
if (-not $NoBuild) {
  & (Join-Path $root 'tools\build.ps1') -Project (Join-Path $PSScriptRoot 'DialogCheck\DialogCheck.dpr') `
    -BuildRoot $BuildRoot -Define NOSKIA | Out-Null
}
$exe = Join-Path $BuildRoot 'bin\Linux64\Release\DialogCheck'
$out = Join-Path $BuildRoot 'shots'
if (Test-Path $out) { Remove-Item -Recurse -Force $out }
wsl -d $Distro -u root -- timeout 150 sh (ConvertTo-WslPath (Join-Path $PSScriptRoot 'dialog-check.sh')) `
  (ConvertTo-WslPath $out) (ConvertTo-WslPath $exe) 2>&1 | Out-Null
$log = Get-Content (Join-Path $out 'program.log') -Raw -Encoding UTF8
# What the settings portals were asked; the desktop's sans-serif family as fontconfig resolves it.
$calls = @(Get-Content (Join-Path $out 'portal-calls.log') -Encoding UTF8 -ErrorAction SilentlyContinue)
$oldCalls = @(Get-Content (Join-Path $out 'old-portal-calls.log') -Encoding UTF8 -ErrorAction SilentlyContinue)
$family = "$(wsl -d $Distro -u root -- timeout 30 fc-match -f '%{family[0]}' sans-serif)".Trim()
$checks = [ordered]@{
  'bus: address list (a missing socket, then an abstract one with guid=)' =
    $log -match 'dialogcheck: connected through "unix:path=[^;]+;unix:abstract=[^"]+" as :1\.\d+'
  'bus: GetId (s)' = $log -match 'GetId: 32 hex digits'
  'bus: ListNames (as) with our own name' = $log -match 'ListNames: signature as, own name listed True'
  'bus: GetConnectionCredentials (a{sv}): our uid and pid' =
    $log -match 'credentials: signature a\{sv\}, UnixUserID (\d+) \(getuid \1\), ProcessID is ours True'
  'bus: error reply with its name' = $log -match 'error reply: org\.freedesktop\.DBus\.Error\.UnknownMethod'
  'bus: unix:path= with guid=' = $log -match 'connected through a path as :1\.\d+'
  'bus: a call nobody answers times out (400 ms)' = $log -match 'timeout: EDBusTimeout after (3[89]\d|4\d\d|5\d\d) ms'
  'bus: a signal subscribed to (NameOwnerChanged, sss)' =
    $log -match 'signal: NameOwnerChanged :1\.\d+, signature sss, new owner ""'
  'bus: unix:runtime=yes' = $log -match 'connected through unix:runtime=yes as :1\.\d+'
  'bus: a pump that says stop cancels the wait' = $log -match 'cancel: EDBusCancelled'
  'bus: no portal on the bus: unavailable at once' =
    $log -match 'portal: unavailable \(org\.freedesktop\.DBus\.Error\.ServiceUnknown\) after \d{1,3} ms'
  'bus: no Unix socket in the address: EDBusUnavailable' = $log -match 'bad address: EDBusUnavailable'
  'backend: installed, it serves TDialogService' = $log -match 'service with the backend: TWaylandDialogService'
  'backend: TOpenDialog request (filters, index, multiple)' = $log -match ('backend file dialog kind 0 title ' +
    '"Check open" file "start\.a" folder "/tmp" filters \[A files: \*\.a \*\.b\]\[C files \(\*\.c\): \*\.c\] index 2 ' +
    'multiple True overwrite False')
  'backend: TOpenDialog result (two files, filter index)' =
    $log -match 'open: True, 2 files: /tmp/first file\.txt\|/tmp/second\.txt, filter index 1'
  "backend: a long selection keeps what fits into FMX's buffer" = $log -match 'many names: 20 of 30 arrive'
  'backend: TSaveDialog request (overwrite prompt)' =
    $log -match 'backend file dialog kind 1 title "Check save" file "/tmp/existing\.txt" .* overwrite True'
  'backend: TSaveDialog result' = $log -match 'save: True, /tmp/only\.txt'
  'backend: SelectDirectory' =
    ($log -match 'backend file dialog kind 2 title "Check folder" file "" folder "/tmp"') -and
    ($log -match 'folder: True, /tmp/chosen folder')
  'backend: sync message (default button passed)' =
    ($log -match 'backend message "Sync\?" type 3 yes True no True default 1') -and
    ($log -match 'sync message result 6')
  'backend: sync input query' = $log -match 'sync input query True: ABC DEF'
  'backend: async message queued, answered later' =
    ($log -match 'async message queued, result yet 0') -and ($log -match 'async message result 6')
  'backend: FmuxMessageDialog' = $log -match 'FmuxMessageDialog result 6'
  'backend: FmuxInputQuery' = $log -match 'FmuxInputQuery True: XYZ'
  "backend: nil restores FMX's dialog services" = $log -match 'service without it: TFMXDialogService'
  'font: Pango descriptions (family, points to pixels, px, style words, variations, a list)' =
    ($log -match 'font description "Adwaita Sans 11": True "Adwaita Sans" 14\.67') -and
    ($log -match 'font description "Cantarell Bold Italic 10\.5": True "Cantarell" 14\.00') -and
    ($log -match 'font description "Noto Sans, Sans 14px": True "Noto Sans" 14\.00') -and
    ($log -match 'font description "Ubuntu Sans Medium 11 @wght=500": True "Ubuntu Sans" 14\.67') -and
    ($log -match 'font description "Monospace": True "Monospace" 0\.00') -and
    ($log -match 'font description "12": False ""')
  'font: settings without a portal: unavailable at once' =
    $log -match 'settings without a portal: unavailable \(org\.freedesktop\.DBus\.Error\.ServiceUnknown\) after \d{1,3} ms'
  "font: GNOME without a portal: fontconfig's sans-serif at 12, at once" =
    $log -match "font service GNOME without a portal: `"$([regex]::Escape($family))`" 12\.0 after \d{1,3} ms"
  'font: settings portal ReadOne' = $log -match 'settings ReadOne: "DejaVu Serif Bold 10\.5"'
  'font: settings portal, a missing key: NotFound' =
    $log -match 'settings missing key: unavailable \(org\.freedesktop\.portal\.Error\.NotFound\)'
  "font: GNOME (ubuntu:GNOME): GNOME's font-name, 10.5 pt = 14 px" =
    $log -match 'font service GNOME: "DejaVu Serif" 14\.0'
  "font: KDE: fontconfig's sans-serif, the portal not asked" =
    ($log -match "font service KDE: `"$([regex]::Escape($family))`" 12\.0") -and
    (@($calls | Select-String 'ReadOne org\.gnome\.desktop\.interface font-name').Count -eq 2)
  "font: FMXWAYLAND_PORTAL=0: fontconfig's sans-serif" =
    $log -match "font service GNOME with FMXWAYLAND_PORTAL=0: `"$([regex]::Escape($family))`" 12\.0"
  'font: an old portal (Read, a variant in a variant)' =
    ($log -match 'settings Read: "DejaVu Serif Bold 10\.5"') -and
    ($log -match 'font service GNOME, old portal: "DejaVu Serif" 14\.0') -and
    (@($oldCalls | Select-String '^Read org\.gnome\.desktop\.interface font-name').Count -eq 2)
  'no step raised' = $log -notmatch 'raised'
  'clean exit' = ($log -match 'dialogcheck: done') -and ($log -match 'exit=0')
}
$failed = Write-Checks $checks
if ($failed -gt 0) { Write-Host "$failed check(s) failed (log: $(Join-Path $out 'program.log'))"; exit 1 }
Write-Host 'All checks passed'
