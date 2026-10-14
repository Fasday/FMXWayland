<#
.SYNOPSIS
  Builds a Delphi FMX program for Linux64 with FMXWayland (command line, dcclinux64, no PAServer).

.DESCRIPTION
  1. Generates FMUX.Api.pas from the installed Delphi (tools\gen-fmux-api.ps1) into <BuildRoot>\gen.
  2. Compiles the project with dcclinux64; the unit path starts with <BuildRoot>\gen and src, so the compiler uses the
     generated FMUX.Api instead of Embarcadero's precompiled one (which loads libfmux).
  3. Links against a Linux platform SDK: a copy of a Linux system's libraries (see README.md, "Building"; the default is the
     SDK that FMXFastCanvas's tools\make-linux-sdk.ps1 makes from the WSL distribution Ubuntu-26.04). dcclinux64 links
     with LLVM lld; --syslibroot is the SDK, --libpath the folders with libc, crt*.o, libgcc and Delphi's librtlhelper.
  4. Copies libsk4d.so (Skia, from $(BDS)\Redist\linux64) next to the program.

  All output goes to <BuildRoot> (default D:\Work\FMXWayland-build): bin\Linux64\<Config>\<Name>,
  dcu\Linux64\<Config>\<Name>\.

.EXAMPLE
  .\tools\build.ps1 -Project samples\Hello\Hello.dpr
  .\tools\build.ps1 -Project samples\Hello\Hello.dpr -Config Debug
#>
param(
  [Parameter(Mandatory = $true)] [string] $Project,
  [ValidateSet('Release', 'Debug')] [string] $Config = 'Release',
  [string[]] $SearchPath = @(),
  [string[]] $Define = @(),
  [string] $BuildRoot = 'D:\Work\FMXWayland-build',
  [string] $Sdk = 'D:\LinuxSDK\ubuntu-26.04',
  # Delphi's folder; '' = from the registry (RootDir of 37.0).
  [string] $Bds = ''
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'delphi-env.ps1')
$DelphiEnv = Get-DelphiEnv $Bds
$Bds = $DelphiEnv.Bds
# FMX for Linux: in the product (Delphi 13.0) or a GetIt package (later releases); see tools\delphi-env.ps1.
$Fmx = Find-FmxLinux $DelphiEnv $Config

$Root = Split-Path $PSScriptRoot -Parent
$Dcc = Join-Path $Bds 'bin\dcclinux64.exe'
if (-not (Test-Path $Dcc)) { throw "No $Dcc" }
if (-not (Test-Path (Join-Path $Sdk 'usr\lib\x86_64-linux-gnu\libc.so.6'))) {
  throw "No Linux SDK at $Sdk (see README.md, 'Building'; tools\make-linux-sdk.ps1 makes one)"
}
$Sdk = (Resolve-Path $Sdk).Path
$gccDir = Get-ChildItem (Join-Path $Sdk 'usr\lib\gcc\x86_64-linux-gnu') -Directory |
  Sort-Object { [int]($_.Name -replace '\D.*', '') } | Select-Object -Last 1
if (-not $gccDir) { throw "No usr\lib\gcc\x86_64-linux-gnu\<version> in $Sdk" }

$ProjectPath = (Resolve-Path $Project).Path
$Name = [IO.Path]::GetFileNameWithoutExtension($ProjectPath)
$GenDir = Join-Path $BuildRoot 'gen'
$OutDir = Join-Path $BuildRoot "bin\Linux64\$Config"
$DcuDir = Join-Path $BuildRoot "dcu\Linux64\$Config\$Name"
New-Item -ItemType Directory -Force -Path $GenDir, $OutDir, $DcuDir | Out-Null

& (Join-Path $PSScriptRoot 'gen-fmux-api.ps1') -Bds $Bds -Out (Join-Path $GenDir 'FMUX.Api.pas') -Source $Fmx.Source -Config $Config

$env:BDS = $Bds
$env:BDSINCLUDE = Join-Path $Bds 'include'
$env:BDSCOMMONDIR = $DelphiEnv.CommonDir
$env:PATH = "$Bds\bin;$Bds\bin64;$env:PATH"

$paths = @($GenDir, (Join-Path $Root 'src'), (Join-Path $Root 'src\Protocols'), (Split-Path $ProjectPath -Parent))
$paths += $SearchPath | ForEach-Object { (Resolve-Path $_).Path }
$delphiLib = Join-Path $Bds "lib\linux64\$($Config.ToLower())"
# The precompiled FMX for Linux units first when they come from a GetIt package.
if ($Fmx.DcuDir -ne $delphiLib) { $paths += $Fmx.DcuDir }
$paths += $delphiLib
# Delphi 13 ships no FMX.Filter.res for Linux64 (FMX.Filter links it); resources are platform-independent, so the
# Win64 one goes into a folder on the resource path.
if (-not (Test-Path (Join-Path $delphiLib 'FMX.Filter.res'))) {
  $resFix = Join-Path $BuildRoot 'linux64-res'
  New-Item -ItemType Directory -Force -Path $resFix | Out-Null
  Copy-Item (Join-Path $Bds "lib\win64\$($Config.ToLower())\FMX.Filter.res") $resFix -Force
  $paths += $resFix
}
$pathArg = ($paths -join ';')
$libPaths = @($Fmx.DcuDir, $delphiLib, (Join-Path $Sdk 'usr\lib\x86_64-linux-gnu'), $gccDir.FullName)
$defines = @($Define)
$flags = @(
  '-B', '-Q',
  '-NSSystem;Xml;Data;Datasnap;Web;Soap;FMX;Posix;Linuxapi',
  "-E$OutDir", "-NU$DcuDir",
  "-U$pathArg", "-I$pathArg", "-R$pathArg",
  "--syslibroot:$Sdk", "--libpath:$($libPaths -join ';')",
  '-GD'
)
if ($Config -eq 'Release') {
  $flags += '-$O+', '-$C-', '-$D+', '-$L+', '-$W-'
  $defines += 'RELEASE'
} else {
  $flags += '-$O-', '-$C+', '-$D+', '-$L+', '-$W+', '-V'
  $defines += 'DEBUG'
}
$flags += '-D' + ($defines -join ';')

Write-Host "dcclinux64 $Name [$Config], SDK $Sdk"
$out = & $Dcc @flags $ProjectPath 2>&1
$code = $LASTEXITCODE
$out | Where-Object { "$_" -notmatch '^(Linker command line:|Embarcadero|Copyright)' } | ForEach-Object { Write-Host "$_" }
if ($code -ne 0) { throw "dcclinux64 failed ($code)" }

Copy-Item (Join-Path $Bds 'Redist\linux64\libsk4d.so') $OutDir -Force
Write-Host "OK -> $(Join-Path $OutDir $Name)"
