<#
.SYNOPSIS
  Start an isolated authenticated Xming display and run the X11 suite against it.
.EXAMPLE
  .\tests\xming.ps1 -XmingExe 'C:\Program Files (x86)\Xming\Xming.exe'
.NOTES
  Uses an already installed Xming; no installer/download is performed. Tests move the pointer and create windows.
  The Windows clipboard bridge is off by default. The public 6.9.0.31 bridge has a known large-INCR issue.
#>
param(
  [Parameter(Mandatory = $true)] [string] $XmingExe,
  [ValidateSet('Both', 'Cairo', 'Skia')] [string] $Canvas = 'Both',
  [string] $BuildRoot = 'D:\Work\FMXWayland-build\x11-release',
  [string] $Distro = 'Ubuntu-26.04',
  [string] $HostAddress = '',
  [switch] $ClipboardBridge,
  [switch] $SkipLargeClipboard,
  [switch] $SkipBuild
)
$ErrorActionPreference = 'Stop'
$BuildRoot = [IO.Path]::GetFullPath($BuildRoot)
$XmingExe = (Resolve-Path $XmingExe).Path
$directory = Split-Path $XmingExe -Parent
Import-Module (Join-Path $PSScriptRoot 'HelloChecks.psm1') -Force
if (-not $HostAddress) {
  $route = (wsl -d $Distro --exec ip -4 route show default) -join ' '
  if ($route -notmatch '\bvia\s+([0-9.]+)') { throw 'Cannot determine the Windows host; pass -HostAddress' }
  $HostAddress = $Matches[1]
}
$number = 0
foreach ($candidate in 92..119) {
  $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Any, 6000 + $candidate)
  try { $listener.Start(); $number = $candidate; break } catch { } finally { $listener.Stop() }
}
if (-not $number) { throw 'No free Xming TCP display in 92..119' }
$out = Join-Path $BuildRoot ('xming-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force $out | Out-Null
$auth = Join-Path $out 'Xauthority'
$stream = [IO.MemoryStream]::new()
function Write-AuthField([byte[]] $Bytes) {
  $stream.WriteByte([byte]($Bytes.Length -shr 8))
  $stream.WriteByte([byte]($Bytes.Length -band 255))
  $stream.Write($Bytes, 0, $Bytes.Length)
}
$cookie = New-Object byte[] 16
$random = [Security.Cryptography.RandomNumberGenerator]::Create()
$random.GetBytes($cookie)
$random.Dispose()
$stream.WriteByte(255)
$stream.WriteByte(255) # FamilyWild; works for the server's loopback WM and the WSL client
Write-AuthField ([byte[]]@())
Write-AuthField ([Text.Encoding]::ASCII.GetBytes([string]$number))
Write-AuthField ([Text.Encoding]::ASCII.GetBytes('MIT-MAGIC-COOKIE-1'))
Write-AuthField $cookie
[IO.File]::WriteAllBytes($auth, $stream.ToArray())
$stream.Dispose()
$oldAuth, $oldLocale = $env:XAUTHORITY, $env:XLOCALEDIR
$process = $null
try {
  $env:XAUTHORITY = $auth
  $env:XLOCALEDIR = Join-Path $directory 'locale'
  $arguments = @(":$number", '-multiwindow', '-auth', ('"' + $auth + '"'),
    '-logfile', ('"' + (Join-Path $out 'Xming.log') + '"'))
  if ($ClipboardBridge) { $arguments += '-clipboard' }
  $process = Start-Process $XmingExe -WorkingDirectory $directory -ArgumentList $arguments -PassThru
  $display = "${HostAddress}:$number"
  $ready = $false
  $deadline = (Get-Date).AddSeconds(20)
  while ((Get-Date) -lt $deadline) {
    if ($process.HasExited) { throw "Xming exited ($($process.ExitCode)); see $out" }
    $info = wsl -d $Distro -u root --exec env "DISPLAY=$display" "XAUTHORITY=$(ConvertTo-WslPath $auth)" timeout 2 xdpyinfo 2>&1
    if ($LASTEXITCODE -eq 0) { $ready = $true; break }
    Start-Sleep -Milliseconds 200
  }
  if (-not $ready) { throw "Cannot connect to Xming at $display; see $out and check the WSL-to-Windows TCP connection" }
  $info | Set-Content (Join-Path $out 'display.txt') -Encoding UTF8
  (Get-Item $XmingExe).VersionInfo | Format-List FileVersion,ProductVersion | Out-File (Join-Path $out 'version.txt')
  Write-Host "Xming $((Get-Item $XmingExe).VersionInfo.FileVersion), $display; clipboard bridge: $ClipboardBridge"
  & (Join-Path $PSScriptRoot 'x11-headless.ps1') -Server Existing -Canvas $Canvas -BuildRoot $BuildRoot `
    -Distro $Distro -Display $display -XAuthority $auth -SkipBuild:$SkipBuild -SkipLargeClipboard:$SkipLargeClipboard
  if ($process.HasExited) { throw 'Xming exited during the tests' }
  'PASS: Xming remained running after the suite' | Set-Content (Join-Path $out 'PASSED')
} finally {
  if ($process -and -not $process.HasExited) { Stop-Process -Id $process.Id }
  $env:XAUTHORITY, $env:XLOCALEDIR = $oldAuth, $oldLocale
  Remove-Item $auth -ErrorAction SilentlyContinue
}
