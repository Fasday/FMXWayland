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
    "$($Prefix): second form hidden and shown again (configured twice)" =
      ($Log -match 'selftest: second form hidden and shown again[\s\S]*selftest: second form visible True') -and
      ([regex]::Matches($Log, 'configure "Self-test second form"').Count -ge 2)
    "$($Prefix): maximize" = $Log -match 'selftest: maximized True'
    "$($Prefix): restore to ${Width}x${Height}" = $Log -match "selftest: restored ${Width}x${Height}"
    "$($Prefix): modal loop ended by a timer (mrRetry)" = $Log -match 'selftest: modal result 4'
    "$($Prefix): message box answered by a timer (mrNo)" = $Log -match 'selftest: message result 7'
    "$($Prefix): no portal: FMX's file dialog instead" =
      $Log -match 'portal: no file dialog \(.*\); FMX''s file dialog instead'
    "$($Prefix): file dialog lists the folder (filter *.txt, no hidden files)" =
      $Log -match 'selftest: file dialog "Self-test open" lists sub/,alpha\.txt,beta\.txt\r?\n'
    "$($Prefix): open: two files chosen (multiple selection)" =
      $Log -match 'selftest: open result True alpha\.txt,beta\.txt in the folder True filter 1'
    "$($Prefix): save: overwrite question answered" = $Log -match 'selftest: overwrite question answered Yes'
    "$($Prefix): save: existing file, other filter" =
      $Log -match 'selftest: save result True beta\.txt in the folder True filter 2'
    "$($Prefix): select folder" = $Log -match 'selftest: folder result True sub in the folder True'
    "$($Prefix): file dialog cancelled" = $Log -match 'selftest: cancelled dialog result False, 0 files'
    "$($Prefix): self-test done" = $Log -match 'selftest: done'
    "$($Prefix): no exception (Application.OnException)" = $Log -notmatch '\[hello\] exception'
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

# Checks of the log of Hello --own-titlebar --selftest (IFMXWaylandWindowFrame without input) whose form the program
# sized $Width x $Height before the frame was attached and before the first show: it must open at that size (FMX's
# form and the client area, the buffer at the scale). $Comp: the compositor (KWin and sway decorate themselves and keep
# the outer size when the decorations come or go: the client size after that is theirs; Weston and GNOME Shell get
# FMXWayland's title bar back, 4 + 4 and 30 + 4 pixels).
function Get-HelloOwnTitleBarChecks([string] $Log, [string] $Prefix, [int] $Width, [int] $Height, [double] $Scale = 1,
  [string] $Comp = 'weston') {
  $ssd = $Comp -in 'sway', 'sway-csd', 'kwin', 'kwin-virtual'
  $size = "${Width}x$Height"
  $onSize = if ($ssd) { '\d+x\d+' } else { "$($Width - 8)x$($Height - 34)" }
  $offSize = if ($ssd) { '\d+x\d+' } else { $size }
  $bw = [int][Math]::Round($Width * $Scale)
  $bh = [int][Math]::Round($Height * $Scale)
  $s = $Scale.ToString('0.00', [Globalization.CultureInfo]::InvariantCulture)
  $bigger = "$($Width + 40)x$($Height + 20)"
  [ordered]@{
    "$($Prefix): service found" = $Log -match 'frame: service found'
    "$($Prefix): decorations off" = $Log -match 'frame: decorated False'
    "$($Prefix): opens at the program's size $size (FMX's form and the client area)" =
      ($Log -match "shown: form $size, client $size") -and
      ($Log -match "selftest: decorated False, form $size, client $size")
    "$($Prefix): buffer ${bw}x$bh at scale $s" = $Log -match "selftest: buffer ${bw}x$bh, scale $s"
    "$($Prefix): listener told at once and after the configure" =
      ($Log -match 'frame: states \$0 \(-\) capabilities \$FFFFFFFF \(unknown\)') -and
      ($Log -match 'frame: states \$[0-9A-F]+ \([^)]*\) capabilities \$[0-9A-F]+ \((?!unknown)')
    "$($Prefix): BeginMove, BeginResize, ShowWindowMenu False without a press" =
      $Log -match 'selftest: without a press: BeginMove False, BeginResize False, ShowWindowMenu False'
    "$($Prefix): drop-down (xdg_popup of an undecorated window) placed where asked" =
      ($Log -match 'selftest: drop-down open True') -and
      ($Log -match 'popup configure (-?\d+),(-?\d+) \d+x\d+ \(asked \1,\2 ')
    "$($Prefix): SetMaximized True: maximized state" =
      $Log -match 'frame: states \$[0-9A-F]+ \([^)]*maximized[\s\S]*selftest: maximized True \d+x\d+'
    "$($Prefix): SetMaximized False: restored to $size" = $Log -match "selftest: restored True $size"
    "$($Prefix): SetDecorated True: decorations back" =
      $Log -match "selftest: decorations on: decorated True, client $onSize"
    "$($Prefix): SetDecorated False again" = $Log -match "selftest: decorations off: decorated False, client $offSize"
    "$($Prefix): size from code once shown: the client area" =
      ($Log -match "selftest: size from code: form $bigger, client $bigger") -and
      ($Log -match "selftest: size from code again: form $size, client $size")
    "$($Prefix): self-test done, clean exit" = ($Log -match 'selftest: done') -and ($Log -match 'exit=0')
    "$($Prefix): no protocol errors" = $Log -notmatch 'protocol error|FMXWayland: error'
  }
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
    "$($Prefix): an xdg_popup of the main window, made once that is mapped" =
      ($Log -notmatch 'shown as a toplevel') -and
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
    "$($Prefix): TFont default family `"$Family`" $Size" =
      $Log -match "font: default `"$([regex]::Escape($Family))`" $Size"
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
  Get-ColorCount, Get-HelloEarlyPopupChecks, Get-HelloFontChecks, Test-HelloOwnTitleBarShot, Get-HelloOwnTitleBarChecks
