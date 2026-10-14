<#
  Windows-side input injection and window lookup for end-to-end tests of FMXWayland programs on WSLg: WSLg shows
  Wayland windows as Windows windows and forwards Windows input to its compositor over RDP, so mouse and keyboard
  events sent with SendInput reach the program through the real Wayland path (wl_pointer, wl_keyboard).

  Import-Module .\tools\WinInput.psm1
  $w = Find-TopWindow 'FMXWayland Hello'
  Invoke-Click $w 60 210
  Send-Text 'Hello'
#>

Add-Type -AssemblyName System.Drawing
if (-not ('FwInput2' -as [type])) {
  Add-Type @'
using System;
using System.Text;
using System.Threading;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class FwInput2 {
  public delegate bool EnumProc(IntPtr h, IntPtr p);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc f, IntPtr p);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int a, out RECT r, int size);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
  [DllImport("user32.dll")] public static extern uint MapVirtualKey(uint code, uint type);
  [StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr extra; }
  [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr extra; }
  [StructLayout(LayoutKind.Explicit)] public struct INPUTUNION { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
  [StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public INPUTUNION u; }
  [DllImport("user32.dll", SetLastError = true)] public static extern uint SendInput(uint n, INPUT[] inputs, int size);
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
  static void Send(INPUT i) { SendInput(1, new INPUT[] { i }, Marshal.SizeOf(typeof(INPUT))); }
  public static void Mouse(uint flags, uint data) {
    var i = new INPUT(); i.type = 0; i.u.mi.dwFlags = flags; i.u.mi.mouseData = data; Send(i);
  }
  // Keys go as scan codes (what RDP forwards to the compositor), extended keys flagged.
  public static void Key(ushort vk, bool up) {
    var i = new INPUT(); i.type = 1;
    i.u.ki.wScan = (ushort)MapVirtualKey(vk, 0);
    i.u.ki.dwFlags = 0x0008 | (up ? 0x0002u : 0u);
    if (vk == 0x25 || vk == 0x26 || vk == 0x27 || vk == 0x28 || vk == 0x2D || vk == 0x2E || vk == 0x24 || vk == 0x23 || vk == 0x21 || vk == 0x22)
      i.u.ki.dwFlags |= 0x0001;
    Send(i);
  }
}
'@
}
[void][FwInput2]::SetProcessDPIAware()

function Find-TopWindow([string] $Title, [int] $TimeoutSec = 20, [switch] $Exact) {
  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  while ((Get-Date) -lt $deadline) {
    foreach ($w in [FwInput2]::Windows()) {
      if (($Exact -and $w.Value -eq $Title) -or (-not $Exact -and $w.Value -like "*$Title*")) {
        $r = New-Object FwInput2+RECT
        if ([FwInput2]::DwmGetWindowAttribute($w.Key, 9, [ref]$r, 16) -ne 0) { [void][FwInput2]::GetWindowRect($w.Key, [ref]$r) }
        return [pscustomobject]@{ Handle = $w.Key; Title = $w.Value; Left = $r.Left; Top = $r.Top
          Width = $r.Right - $r.Left; Height = $r.Bottom - $r.Top }
      }
    }
    Start-Sleep -Milliseconds 200
  }
  return $null
}

function Test-TopWindow([string] $Title) {
  foreach ($w in [FwInput2]::Windows()) { if ($w.Value -like "*$Title*") { return $true } }
  return $false
}

function Move-PointerTo($Window, [int] $X, [int] $Y) {
  [void][FwInput2]::SetCursorPos($Window.Left + $X, $Window.Top + $Y)
  Start-Sleep -Milliseconds 120
}

function Invoke-Click($Window, [int] $X, [int] $Y, [ValidateSet('Left', 'Right', 'Middle')] [string] $Button = 'Left') {
  Move-PointerTo $Window $X $Y
  $down, $up = switch ($Button) { 'Left' { 0x2, 0x4 } 'Right' { 0x8, 0x10 } 'Middle' { 0x20, 0x40 } }
  [FwInput2]::Mouse($down, 0)
  Start-Sleep -Milliseconds 60
  [FwInput2]::Mouse($up, 0)
  Start-Sleep -Milliseconds 250
}

function Invoke-Wheel([int] $Notches) {
  [FwInput2]::Mouse(0x0800, [BitConverter]::ToUInt32([BitConverter]::GetBytes([int32]($Notches * 120)), 0))
  Start-Sleep -Milliseconds 200
}

function Send-Key([int] $Vk, [int[]] $Modifiers = @()) {
  foreach ($m in $Modifiers) { [FwInput2]::Key($m, $false); Start-Sleep -Milliseconds 30 }
  [FwInput2]::Key($Vk, $false)
  Start-Sleep -Milliseconds 40
  [FwInput2]::Key($Vk, $true)
  foreach ($m in $Modifiers) { Start-Sleep -Milliseconds 30; [FwInput2]::Key($m, $true) }
  Start-Sleep -Milliseconds 80
}

# Letters, digits and space (US layout positions); upper case letters with Shift.
function Send-Text([string] $Text) {
  foreach ($c in $Text.ToCharArray()) {
    if ($c -ge 'a' -and $c -le 'z') { Send-Key ([int][char]::ToUpper($c)) }
    elseif ($c -ge 'A' -and $c -le 'Z') { Send-Key ([int]$c) @(0x10) }
    elseif ($c -ge '0' -and $c -le '9') { Send-Key ([int]$c) }
    elseif ($c -eq ' ') { Send-Key 0x20 }
    elseif ($c -eq '.') { Send-Key 0xBE }
    elseif ($c -eq ',') { Send-Key 0xBC }
    elseif ($c -eq '-') { Send-Key 0xBD }
    elseif ($c -eq '!') { Send-Key 0x31 @(0x10) }
    else { throw "Send-Text: no key for '$c'" }
  }
}

# Asks the window to close (WM_CLOSE: WSLg turns it into xdg_toplevel.close).
function Close-TopWindow($Window) { [void][FwInput2]::PostMessage($Window.Handle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) }

function Get-PointerPosition {
  $p = New-Object FwInput2+POINT
  [void][FwInput2]::GetCursorPos([ref]$p)
  return $p
}

function Set-PointerPosition($Point) { [void][FwInput2]::SetCursorPos($Point.X, $Point.Y) }

Export-ModuleMember -Function Find-TopWindow, Test-TopWindow, Close-TopWindow, Move-PointerTo, Invoke-Click, Invoke-Wheel, Send-Key,
  Send-Text, Get-PointerPosition, Set-PointerPosition
