<#
.SYNOPSIS
  Checks that no Embarcadero code is in the repository: every line (whitespace-normalized, at least -MinLength
  characters) of the tracked sources that occurs verbatim in the Delphi sources ($(BDS)\source), and Embarcadero
  markers (copyright lines, product names). Run before every push; hits must be explained (generic one-liners) or
  rewritten. The generated FMUX.Api.pas is ignored by git and never checked in.

.EXAMPLE
  .\tools\check-no-embarcadero.ps1 -Tracked
#>
param(
  [string] $Repo = (Split-Path $PSScriptRoot -Parent),
  [string] $Source = 'C:\Program Files (x86)\Embarcadero\Studio\37.0\source',
  [int] $MinLength = 40,
  [switch] $Tracked
)
# Lines of the repository that occur verbatim (whitespace-normalized) in Delphi's sources, and Embarcadero markers.
$norm = { param($s) (($s -replace '\s+', ' ').Trim()).ToLowerInvariant() }
$set = New-Object 'System.Collections.Generic.HashSet[string]'
Get-ChildItem $Source -Recurse -Include *.pas, *.inc -File -ErrorAction SilentlyContinue | ForEach-Object {
  foreach ($l in [IO.File]::ReadLines($_.FullName)) {
    $n = & $norm $l
    if ($n.Length -ge $MinLength) { [void]$set.Add($n) }
  }
}
"Delphi source lines indexed: $($set.Count)"
if ($Tracked) { $files = git -C $Repo ls-files | ForEach-Object { Join-Path $Repo $_ } }
else { $files = Get-ChildItem $Repo -Recurse -File | Where-Object { $_.FullName -notmatch '\\\.git\\' } | ForEach-Object { $_.FullName } }
$hits = 0
foreach ($f in $files) {
  if ($f -notmatch '\.(pas|inc|dpr|ps1|md|txt)$') { continue }
  $i = 0
  foreach ($l in [IO.File]::ReadLines($f)) {
    $i++
    $n = & $norm $l
    if ($n -match 'embarcadero technologies|codegear|copyright\(c\) 1995|all rights reserved|fmxlinux|eugene kryukov|ksdev') {
      "MARKER {0}:{1}: {2}" -f $f.Substring($Repo.Length + 1), $i, $l.Trim(); $hits++
    }
    elseif ($n.Length -ge $MinLength -and $set.Contains($n)) {
      "COPY   {0}:{1}: {2}" -f $f.Substring($Repo.Length + 1), $i, $l.Trim(); $hits++
    }
  }
}
"hits: $hits"
