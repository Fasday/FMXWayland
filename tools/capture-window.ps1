<#
.SYNOPSIS
  Screenshot of a top-level window on the Windows desktop (for WSLg: Wayland windows of WSL appear as Windows
  windows), found by its title, saved as PNG.

.DESCRIPTION
  Test helper: WSLg's compositor offers no screen capture protocol to clients, so tests of FMXWayland programs in WSL
  look at their windows from the Windows side. -Mode Screen copies the window's rectangle from the screen (what the
  user sees, including the window decorations of WSLg); -Mode Print asks the window to paint itself (PrintWindow,
  works when it is covered).

.EXAMPLE
  .\tools\capture-window.ps1 -Title 'FMXWayland Hello' -Out D:\Work\FMXWayland-build\shots\hello.png
#>
param(
  [Parameter(Mandatory = $true)] [string] $Title,
  [Parameter(Mandatory = $true)] [string] $Out,
  [ValidateSet('Screen', 'Print')] [string] $Mode = 'Screen',
  [int] $TimeoutSec = 20,
  [switch] $Exact,
  [switch] $Activate,
  # Pixels added to the captured rectangle on the right and at the bottom (popups next to the window).
  [int] $ExtendRight = 0,
  [int] $ExtendBottom = 0
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
if (-not ('FwCapture' -as [type])) {
  Add-Type @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class FwCapture {
  public delegate bool EnumProc(IntPtr h, IntPtr p);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc f, IntPtr p);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int a, out RECT r, int size);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  public static List<KeyValuePair<IntPtr, string>> Windows() {
    var list = new List<KeyValuePair<IntPtr, string>>();
    EnumWindows((h, p) => {
      if (IsWindowVisible(h)) {
        var sb = new StringBuilder(512);
        GetWindowText(h, sb, 512);
        if (sb.Length > 0) list.Add(new KeyValuePair<IntPtr, string>(h, sb.ToString()));
      }
      return true;
    }, IntPtr.Zero);
    return list;
  }
}
'@
}
[void][FwCapture]::SetProcessDPIAware()

$deadline = (Get-Date).AddSeconds($TimeoutSec)
$hwnd = [IntPtr]::Zero
while ((Get-Date) -lt $deadline) {
  foreach ($w in [FwCapture]::Windows()) {
    if (($Exact -and $w.Value -eq $Title) -or (-not $Exact -and $w.Value -like "*$Title*")) { $hwnd = $w.Key; break }
  }
  if ($hwnd -ne [IntPtr]::Zero) { break }
  Start-Sleep -Milliseconds 250
}
if ($hwnd -eq [IntPtr]::Zero) { throw "No window titled '$Title'" }
if ($Activate) { [void][FwCapture]::SetForegroundWindow($hwnd); Start-Sleep -Milliseconds 300 }

$r = New-Object FwCapture+RECT
# DWMWA_EXTENDED_FRAME_BOUNDS (9): the visible bounds without the invisible resize borders.
if ([FwCapture]::DwmGetWindowAttribute($hwnd, 9, [ref]$r, 16) -ne 0) { [void][FwCapture]::GetWindowRect($hwnd, [ref]$r) }
$w = $r.Right - $r.Left + $ExtendRight
$h = $r.Bottom - $r.Top + $ExtendBottom
if ($w -le 0 -or $h -le 0) { throw "Window '$Title' has an empty rectangle" }
$bmp = New-Object System.Drawing.Bitmap $w, $h
$g = [System.Drawing.Graphics]::FromImage($bmp)
if ($Mode -eq 'Print') {
  $dc = $g.GetHdc()
  [void][FwCapture]::PrintWindow($hwnd, $dc, 2)
  $g.ReleaseHdc($dc)
} else {
  $g.CopyFromScreen($r.Left, $r.Top, 0, 0, (New-Object System.Drawing.Size $w, $h))
}
$g.Dispose()
New-Item -ItemType Directory -Force -Path (Split-Path $Out -Parent) | Out-Null
$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
Write-Host "$Out ($w x $h at $($r.Left),$($r.Top))"
