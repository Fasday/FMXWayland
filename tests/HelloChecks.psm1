<#
.SYNOPSIS
  Checks of the log of samples\Hello --selftest (FMXWAYLAND_LOG=2), shared by tests\weston-headless.ps1,
  tests\glibc-compat.ps1 and tests\compositors.ps1.
#>

# Converts a Windows path (D:\x\y) into the WSL one (/mnt/d/x/y).
function ConvertTo-WslPath([string] $Path) {
  '/mnt/' + $Path.Substring(0, 1).ToLower() + $Path.Substring(2).Replace('\', '/')
}

# The checks of the self-test of samples\Hello as an ordered dictionary "<prefix>: <name>" -> passed. Scale is the
# output scale the window had (1, 2, 1.5, ...): the buffer of the 700x540 window is that much larger.
function Get-HelloSelfTestChecks([string] $Log, [string] $Prefix, [double] $Scale = 1) {
  $bw = [int][Math]::Round(700 * $Scale)
  $bh = [int][Math]::Round(540 * $Scale)
  $s = $Scale.ToString('0.00', [Globalization.CultureInfo]::InvariantCulture)
  $nz = '[0-9A-F]*[1-9A-F][0-9A-F]*'
  [ordered]@{
    "$($Prefix): window created" = $Log -match '\[hello\] created'
    "$($Prefix): native buffer ${bw}x${bh} at scale $s" = $Log -match "native: display=$nz surface=$nz buffer=${bw}x${bh} scale=$s"
    "$($Prefix): TThread.Synchronize from a thread" = $Log -match 'selftest: synchronize from a thread, on the main thread True'
    "$($Prefix): TThread.Queue from a thread" = $Log -match 'selftest: queue from a thread, on the main thread True'
    "$($Prefix): clipboard round trip" = $Log -match ('selftest: clipboard "selftest clipboard ' + [char]0x2713 + '"')
    "$($Prefix): combo drop-down (xdg_popup) opens" = $Log -match 'selftest: drop-down open True'
    "$($Prefix): combo drop-down closes" = $Log -match 'selftest: drop-down closed True'
    "$($Prefix): second form shown and freed" = $Log -match 'selftest: second form shown[\s\S]*selftest: second form freed'
    "$($Prefix): maximize" = $Log -match 'selftest: maximized True'
    "$($Prefix): restore to 700x540" = $Log -match 'selftest: restored 700x540'
    "$($Prefix): modal loop ended by a timer (mrRetry)" = $Log -match 'selftest: modal result 4'
    "$($Prefix): self-test done" = $Log -match 'selftest: done'
    "$($Prefix): clean exit" = $Log -match 'exit=0'
  }
}

# The program's own frame dump (FMXWAYLAND_DUMP_DIR, a top-down BMP of the main window) as frame.png; its size.
function Convert-HelloFrameDump([string] $Dir) {
  Add-Type -AssemblyName System.Drawing
  $dump = Get-ChildItem $Dir -Filter 'FMXWaylandHello-*.bmp' -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $dump) { return $null }
  $img = [System.Drawing.Image]::FromFile($dump.FullName)
  try {
    $img.Save((Join-Path $Dir 'frame.png'), [System.Drawing.Imaging.ImageFormat]::Png)
    return [System.Drawing.Size]::new($img.Width, $img.Height)
  } finally {
    $img.Dispose()
  }
}

# Writes PASS/FAIL lines of the checks; returns the number of failures.
function Write-Checks($Checks) {
  $failed = 0
  foreach ($k in $Checks.Keys) {
    $r = if ($Checks[$k]) { 'PASS' } else { $failed++; 'FAIL' }
    Write-Host "$r  $k"
  }
  $failed
}

Export-ModuleMember -Function ConvertTo-WslPath, Get-HelloSelfTestChecks, Convert-HelloFrameDump, Write-Checks
