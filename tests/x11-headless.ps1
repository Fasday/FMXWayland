<#
.SYNOPSIS
  Build and test Cairo/Skia on a private Xvfb or Xorg, or on an explicitly supplied existing X server.
.EXAMPLE
  .\tests\x11-headless.ps1 -Server Xorg
  .\tests\x11-headless.ps1 -Server Existing -Display 172.27.16.1:92 -XAuthority C:\Temp\Xauthority
#>
param(
  [ValidateSet('Xvfb', 'Xorg', 'Existing')] [string] $Server = 'Xvfb',
  [ValidateSet('Both', 'Cairo', 'Skia')] [string] $Canvas = 'Both',
  [string] $BuildRoot = 'D:\Work\FMXWayland-build\x11-release',
  [string] $Distro = 'Ubuntu-26.04',
  [string] $Display = '',
  [string] $XAuthority = '',
  [switch] $SkipBuild,
  [switch] $SkipLargeClipboard
)
$ErrorActionPreference = 'Stop'
$BuildRoot = [IO.Path]::GetFullPath($BuildRoot)
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $PSScriptRoot 'HelloChecks.psm1') -Force
if ($Server -eq 'Existing' -and -not $Display) { throw '-Server Existing requires -Display' }
$probeRoot = Join-Path $BuildRoot 'probe'
if (-not $SkipBuild) {
  & (Join-Path $root 'tools\build.ps1') -Project (Join-Path $PSScriptRoot 'BackendCheck\BackendCheck.dpr') -BuildRoot $probeRoot
}
$probe = Join-Path $probeRoot 'bin\Linux64\Release\BackendCheck'
if (-not (Test-Path $probe)) { throw "No $probe" }
$canvases = if ($Canvas -eq 'Both') { @('Cairo', 'Skia') } else { @($Canvas) }
$savedClipboard = if ($Server -eq 'Existing') { Get-Clipboard -Raw -ErrorAction SilentlyContinue } else { $null }
try {
  foreach ($kind in $canvases) {
    $canvasRoot = Join-Path $BuildRoot $kind.ToLower()
    if (-not $SkipBuild) {
      $buildArgs = @{ Project = (Join-Path $root 'samples\Hello\Hello.dpr'); BuildRoot = $canvasRoot }
      if ($kind -eq 'Cairo') { $buildArgs.Define = @('NOSKIA') }
      & (Join-Path $root 'tools\build.ps1') @buildArgs
    }
    $exe = Join-Path $canvasRoot 'bin\Linux64\Release\Hello'
    if (-not (Test-Path $exe)) { throw "No $exe" }
    $out = Join-Path $canvasRoot "checks\$($Server.ToLower())"
    $environment = @("X11_SERVER=$($Server.ToLower())")
    if ($Display) { $environment += "DISPLAY=$Display" }
    if ($XAuthority) { $environment += 'XAUTHORITY=' + (ConvertTo-WslPath (Resolve-Path $XAuthority).Path) }
    if ($SkipLargeClipboard) { $environment += 'X11_SKIP_LARGE_CLIPBOARD=1' }
    $command = @('bash', (ConvertTo-WslPath (Join-Path $PSScriptRoot 'x11-headless.sh')),
      (ConvertTo-WslPath $out), (ConvertTo-WslPath $exe), (ConvertTo-WslPath $probe))
    if ($Server -ne 'Existing') {
      $command = @('unshare', '--mount', 'bash', (ConvertTo-WslPath (Join-Path $PSScriptRoot 'x11-private.sh'))) + $command[1..4]
    }
    Write-Host "Testing $kind on $Server -> $out"
    wsl -d $Distro -u root --exec env @environment @command
    if ($LASTEXITCODE -ne 0) { throw "$kind / $Server failed ($LASTEXITCODE): $out" }
  }
} finally {
  if ($null -ne $savedClipboard) { Set-Clipboard -Value $savedClipboard }
}
Write-Host 'All requested X11 checks passed'
