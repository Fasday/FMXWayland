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
# output scale the window had (1, 2, 1.5, ...): the buffer of the window (client area Width x Height, 700x540 unless
# the compositor sizes it otherwise) is that much larger.
function Get-HelloSelfTestChecks([string] $Log, [string] $Prefix, [double] $Scale = 1, [int] $Width = 700,
  [int] $Height = 540) {
  $bw = [int][Math]::Round($Width * $Scale)
  $bh = [int][Math]::Round($Height * $Scale)
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
    "$($Prefix): restore to ${Width}x${Height}" = $Log -match "selftest: restored ${Width}x${Height}"
    "$($Prefix): modal loop ended by a timer (mrRetry)" = $Log -match 'selftest: modal result 4'
    "$($Prefix): message box answered by a timer (mrNo)" = $Log -match 'selftest: message result 7'
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

Add-Type -AssemblyName System.Drawing
if (-not ('FmxwPixels' -as [type])) {
  Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
public static class FmxwPixels {
  // Pixels of an image within the tolerance (per channel) of the color 0xRRGGBB, in the rectangle x0..x1-1,
  // y0..y1-1 (x1 = -1: all): { count, left, top, right, bottom } (the bounding box of those pixels).
  public static int[] Find(string path, int rgb, int tolerance, int x0, int y0, int x1, int y1) {
    using (var src = new Bitmap(path))
    using (var bmp = src.Clone(new Rectangle(0, 0, src.Width, src.Height), PixelFormat.Format32bppArgb)) {
      var data = bmp.LockBits(new Rectangle(0, 0, bmp.Width, bmp.Height), ImageLockMode.ReadOnly,
        PixelFormat.Format32bppArgb);
      var bytes = new byte[data.Stride * data.Height];
      Marshal.Copy(data.Scan0, bytes, 0, bytes.Length);
      bmp.UnlockBits(data);
      if (x1 < 0) { x0 = 0; y0 = 0; x1 = data.Width; y1 = data.Height; }
      x0 = Math.Max(0, x0); y0 = Math.Max(0, y0); x1 = Math.Min(data.Width, x1); y1 = Math.Min(data.Height, y1);
      int r = (rgb >> 16) & 255, g = (rgb >> 8) & 255, b = rgb & 255, n = 0;
      int l = int.MaxValue, t = int.MaxValue, rr = -1, bb = -1;
      for (int y = y0; y < y1; y++)
        for (int x = x0; x < x1; x++) {
          int i = y * data.Stride + x * 4;
          if (Math.Abs(bytes[i + 2] - r) <= tolerance && Math.Abs(bytes[i + 1] - g) <= tolerance &&
              Math.Abs(bytes[i] - b) <= tolerance) {
            n++; l = Math.Min(l, x); t = Math.Min(t, y); rr = Math.Max(rr, x + 1); bb = Math.Max(bb, y + 1);
          }
        }
      return new int[] { n, l, t, rr, bb };
    }
  }
  public static int Count(string path, int rgb, int tolerance) {
    return Find(path, rgb, tolerance, 0, 0, -1, -1)[0];
  }
  // The rows with at least minPerRow pixels of the color: { rows, left, top, right, bottom } of those pixels.
  public static int[] Band(string path, int rgb, int tolerance, int minPerRow) {
    using (var src = new Bitmap(path))
    using (var bmp = src.Clone(new Rectangle(0, 0, src.Width, src.Height), PixelFormat.Format32bppArgb)) {
      var data = bmp.LockBits(new Rectangle(0, 0, bmp.Width, bmp.Height), ImageLockMode.ReadOnly,
        PixelFormat.Format32bppArgb);
      var bytes = new byte[data.Stride * data.Height];
      Marshal.Copy(data.Scan0, bytes, 0, bytes.Length);
      bmp.UnlockBits(data);
      int r = (rgb >> 16) & 255, g = (rgb >> 8) & 255, b = rgb & 255, rows = 0;
      int l = int.MaxValue, t = int.MaxValue, rr = -1, bb = -1;
      for (int y = 0; y < data.Height; y++) {
        int n = 0, rl = int.MaxValue, rr2 = -1;
        for (int x = 0; x < data.Width; x++) {
          int i = y * data.Stride + x * 4;
          if (Math.Abs(bytes[i + 2] - r) <= tolerance && Math.Abs(bytes[i + 1] - g) <= tolerance &&
              Math.Abs(bytes[i] - b) <= tolerance) { n++; rl = Math.Min(rl, x); rr2 = x + 1; }
        }
        if (n >= minPerRow) {
          rows++; l = Math.Min(l, rl); rr = Math.Max(rr, rr2); t = Math.Min(t, y); bb = y + 1;
        }
      }
      return new int[] { rows, l, t, rr, bb };
    }
  }
}
'@
}

# The number of pixels of a PNG within $Tolerance of the color $Rgb (0xRRGGBB).
function Get-ColorCount([string] $Path, [int] $Rgb, [int] $Tolerance = 8) {
  if (-not (Test-Path $Path)) { return -1 }
  [FmxwPixels]::Count($Path, $Rgb, $Tolerance)
}

# Checks of a screenshot of Hello --own-titlebar: its caption (active or inactive blue) is there, and no title bar of
# FMXWayland's (its light gray, active or inactive) right above it. Returns @(passed, detail).
function Test-HelloOwnTitleBarShot([string] $Path) {
  if (-not (Test-Path $Path)) { return @($false, 'no screenshot') }
  # The caption: rows of at least 300 pixels of its color (active or inactive).
  $best = $null
  foreach ($c in 0x2B579A, 0x8AA2C8) {
    $f = [FmxwPixels]::Band($Path, $c, 6, 300)
    if (($null -eq $best) -or ($f[0] -gt $best[0])) { $best = $f }
  }
  if ($best[0] -lt 20) { return @($false, "caption: $($best[0]) rows") }
  # 40 rows above the caption's top edge, as wide as the caption.
  $deco = 0
  foreach ($c in 0xE6E6E4, 0xF4F4F2) {
    $deco += [FmxwPixels]::Find($Path, $c, 1, $best[1], $best[2] - 40, $best[3], $best[2])[0]
  }
  @(($deco -lt 50), ("caption {0}x{1} at {2},{3}; {4} pixels of a title bar above it" -f ($best[3] - $best[1]),
    $best[0], $best[1], $best[2], $deco))
}

# Checks of Hello --early-popup[=...] (its log and a compositor screenshot while the drop-down is open): the popup
# became an xdg_popup of the main window (not a toplevel) once that was mapped, was not dismissed, and both are on the
# screen (the main window's steel blue title and the drop-down's highlighted item in the screenshot). -Activates:
# the compositor activates the new window, and FMX closes the popups of a form whenever its activation changes
# (FmuxWindowActivate): the drop-down may be gone then.
function Get-HelloEarlyPopupChecks([string] $Log, [string] $Shot, [string] $Prefix, [switch] $Activates) {
  $blue = Get-ColorCount $Shot 0x4682B4 10
  $item = Get-ColorCount $Shot 0x7EB0E6 6
  $closedByFmx = $Activates -and ($Log -match '\[hello\] form activated') -and ($item -lt 100)
  [ordered]@{
    "$($Prefix): drop-down opened" = $Log -match 'early popup: drop-down open True'
    "$($Prefix): an xdg_popup of the main window, made once that is mapped" = ($Log -notmatch 'shown as a toplevel') -and
      (($Log -match 'the popup is made now') -or (($Log -match 'popup configure') -and ($Log -notmatch 'popup waits')))
    "$($Prefix): not dismissed by the compositor" = $Log -notmatch 'popup dismissed'
    "$($Prefix): main window on the screen ($blue title pixels)" = $blue -gt 300
    "$($Prefix): drop-down on the screen ($(if ($closedByFmx) { 'closed by FMX when the window was activated' }
      else { "$item highlight pixels" }))" = ($item -gt 1500) -or $closedByFmx
    "$($Prefix): clean exit" = $Log -match 'exit=0'
  }
}

# Checks of the default font in Hello's log (FMXWayland's IFMXSystemFontService): the family and size FMX's TFont
# takes, what a styled label resolves, and that the canvas measures text in it (not in the fallback of a missing
# family: Tahoma is missing on Linux, Skia falls back to Ubuntu, Pango to fontconfig's default).
function Get-HelloFontChecks([string] $Log, [string] $Prefix, [string] $Family, [string] $Size = '12.0',
  [switch] $Distinct) {
  $checks = [ordered]@{
    "$($Prefix): TFont default family `"$Family`" $Size" = $Log -match "font: default `"$([regex]::Escape($Family))`" $Size"
    "$($Prefix): styled label in `"$Family`"" = $Log -match "font: label `"$([regex]::Escape($Family))`""
  }
  if ($Distinct) {
    $ok = ($Log -match 'font: text width default ([0-9.]+), Tahoma ([0-9.]+), Ubuntu ([0-9.]+)') -and
      ($Matches[1] -ne $Matches[2]) -and ($Matches[1] -ne $Matches[3])
    $checks["$($Prefix): the canvas measures the default text in it (not as Tahoma or Ubuntu)"] = [bool]$ok
  }
  $checks
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

Export-ModuleMember -Function ConvertTo-WslPath, Get-HelloSelfTestChecks, Convert-HelloFrameDump, Write-Checks,
  Get-ColorCount, Get-HelloEarlyPopupChecks, Get-HelloFontChecks, Test-HelloOwnTitleBarShot
