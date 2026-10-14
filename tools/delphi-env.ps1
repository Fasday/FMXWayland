<#
.SYNOPSIS
  Where the local Delphi keeps FMX for Linux: dot-source this file (. .\tools\delphi-env.ps1) and call
  Find-FmxLinux.

.DESCRIPTION
  Delphi 13.0 ships FMX for Linux in the product: the precompiled units in $(BDS)\lib\linux64\<config>, the source of
  FMUX.Api in $(BDS)\source\fmx. Later releases (13.1) install it as a GetIt package under the catalog repository
  ($(BDSCOMMONDIR)\CatalogRepository\<package>), and add its folders to the Linux64 library path of the IDE. The
  interface of the generated FMUX.Api must be the one the precompiled FMX units were compiled with, so the source is
  taken next to the FMUX.Api.dcu that the build uses: the first one on the Linux64 library path (as the IDE orders it),
  then the catalog repository, then the product's lib folder.
#>

function Get-DelphiEnv([string] $Bds = '') {
  $ver = '37.0'
  if (-not $Bds) {
    $root = (Get-ItemProperty "HKCU:\Software\Embarcadero\BDS\$ver" -ErrorAction SilentlyContinue).RootDir
    $Bds = if ($root) { $root.TrimEnd('\') } else { "C:\Program Files (x86)\Embarcadero\Studio\$ver" }
  }
  $Bds = $Bds.TrimEnd('\')
  $ver = Split-Path $Bds -Leaf
  $vars = Get-ItemProperty "HKCU:\Software\Embarcadero\BDS\$ver\Environment Variables" -ErrorAction SilentlyContinue
  $common = if ($vars -and $vars.BDSCOMMONDIR) { $vars.BDSCOMMONDIR } else { Join-Path $env:PUBLIC "Documents\Embarcadero\Studio\$ver" }
  $catalog = if ($vars -and $vars.BDSCatalogRepositoryAllUsers) { $vars.BDSCatalogRepositoryAllUsers } else { Join-Path $common 'CatalogRepository' }
  $userCatalog = if ($vars -and $vars.BDSCatalogRepository) { $vars.BDSCatalogRepository } else { '' }
  [pscustomobject]@{
    Bds         = $Bds
    Version     = $ver
    CommonDir   = $common
    UserDir     = Join-Path ([Environment]::GetFolderPath('MyDocuments')) "Embarcadero\Studio\$ver"
    Catalogs    = @($catalog, $userCatalog) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique
  }
}

function Expand-DelphiPath($DelphiEnv, [string] $Path, [string] $Config = 'Release') {
  $map = @{
    'BDS' = $DelphiEnv.Bds; 'BDSLIB' = (Join-Path $DelphiEnv.Bds 'lib'); 'BDSCOMMONDIR' = $DelphiEnv.CommonDir
    'BDSUSERDIR' = $DelphiEnv.UserDir; 'BDSINCLUDE' = (Join-Path $DelphiEnv.Bds 'include'); 'Platform' = 'Linux64'
    'Config' = $Config; 'PUBLIC' = $env:PUBLIC
  }
  $vars = Get-ItemProperty "HKCU:\Software\Embarcadero\BDS\$($DelphiEnv.Version)\Environment Variables" -ErrorAction SilentlyContinue
  [regex]::Replace($Path, '\$\((\w+)\)', {
    param($m)
    $n = $m.Groups[1].Value
    if ($map.ContainsKey($n)) { $map[$n] }
    elseif ($vars -and $vars.$n) { $vars.$n }
    elseif ([Environment]::GetEnvironmentVariable($n)) { [Environment]::GetEnvironmentVariable($n) }
    else { $m.Value }
  })
}

function Get-Linux64LibraryPath($DelphiEnv, [string] $Config = 'Release', [string] $Value = 'Search Path') {
  $k = Get-ItemProperty "HKCU:\Software\Embarcadero\BDS\$($DelphiEnv.Version)\Library\Linux64" -ErrorAction SilentlyContinue
  if (-not $k -or -not $k.$Value) { return @() }
  @($k.$Value -split ';' | Where-Object { $_.Trim() } | ForEach-Object { Expand-DelphiPath $DelphiEnv $_.Trim() $Config } |
    Where-Object { $_ -notmatch '\$\(' -and (Test-Path $_) })
}

<#
  FMX for Linux of this Delphi: DcuDir, the folder of the FMUX.Api.dcu the build should use (the precompiled FMX Linux
  units are there); Source, the FMUX.Api.pas that matches it; Package, the GetIt package root ('' when it is part of
  the product). Throws with what was searched when nothing is found.
#>
function Find-FmxLinux($DelphiEnv, [string] $Config = 'Release') {
  $cfg = $Config.ToLower()
  $productLib = Join-Path $DelphiEnv.Bds "lib\linux64\$cfg"
  $dirs = @(Get-Linux64LibraryPath $DelphiEnv $Config)
  # GetIt packages that carry FMX for Linux, even when the IDE's library path was not updated (command-line builds).
  foreach ($c in $DelphiEnv.Catalogs) {
    $dirs += @(Get-ChildItem $c -Recurse -Filter 'FMUX.Api.dcu' -ErrorAction SilentlyContinue |
      Where-Object { $_.FullName -match '\\linux64\\' -and $_.FullName -match "\\$cfg\\" } |
      ForEach-Object { $_.DirectoryName })
  }
  $dirs += $productLib
  $dcuDir = $dirs | Where-Object { Test-Path (Join-Path $_ 'FMUX.Api.dcu') } | Select-Object -First 1
  if (-not $dcuDir) { throw "No FMUX.Api.dcu for Linux64 on the library path, in the catalog repository or in $productLib (is FMX for Linux installed?)" }

  # The package root: the catalog repository folder the dcu is in.
  $package = ''
  foreach ($c in $DelphiEnv.Catalogs) {
    if ($dcuDir.StartsWith($c, [StringComparison]::OrdinalIgnoreCase)) {
      $rel = $dcuDir.Substring($c.Length).TrimStart('\')
      $package = Join-Path $c ($rel -split '\\')[0]
    }
  }
  $candidates = @()
  if ($package) { $candidates += @(Get-ChildItem $package -Recurse -Filter 'FMUX.Api.pas' -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }) }
  $candidates += @(Get-Linux64LibraryPath $DelphiEnv $Config 'Browsing Path' | ForEach-Object { Join-Path $_ 'FMUX.Api.pas' } | Where-Object { Test-Path $_ })
  if (-not $package) { $candidates += Join-Path $DelphiEnv.Bds 'source\fmx\FMUX.Api.pas' }
  $source = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
  if (-not $source) { throw "FMUX.Api.dcu is in $dcuDir, but no FMUX.Api.pas was found for it (package '$package', the Linux64 browsing path, $($DelphiEnv.Bds)\source\fmx); pass -Source" }
  [pscustomobject]@{ DcuDir = $dcuDir; Source = $source; Package = $package; ProductLib = $productLib }
}
