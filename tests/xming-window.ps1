param(
  [string] $Title = 'FMXWayland own title bar',
  [long] $Handle = 0,
  [switch] $Find,
  [switch] $Restore
)
$ErrorActionPreference = 'Stop'
Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class XmingWindowState {
  public delegate bool EnumProc(IntPtr window, IntPtr data);
  [DllImport("user32.dll")]
  public static extern bool EnumWindows(EnumProc callback, IntPtr data);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)]
  public static extern int GetWindowText(IntPtr window, StringBuilder text, int length);
  public static IntPtr FindWindow(string title) {
    IntPtr found = IntPtr.Zero;
    EnumWindows((window, data) => {
      var text = new StringBuilder(512);
      GetWindowText(window, text, text.Capacity);
      if (text.ToString() != title) return true;
      found = window;
      return false;
    }, IntPtr.Zero);
    return found;
  }
  [DllImport("user32.dll")]
  public static extern bool IsIconic(IntPtr window);
  [DllImport("user32.dll")]
  public static extern bool ShowWindow(IntPtr window, int command);
}
'@
$window = if ($Handle) { [IntPtr]$Handle } else { [XmingWindowState]::FindWindow($Title) }
if ($window -eq [IntPtr]::Zero) { throw "No native Xming window '$Title'" }
if ($Find) { $window.ToInt64(); return }
if ($Restore) { [void][XmingWindowState]::ShowWindow($window, 9) }
[XmingWindowState]::IsIconic($window)
