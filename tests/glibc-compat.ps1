<#
.SYNOPSIS
  Does samples\Hello, linked against the default SDK (Ubuntu 22.04, glibc 2.35), run on other Linux distributions?
  1. The glibc symbol versions the program and libsk4d.so need (objdump -T in WSL) must be at most -MaxGlibc.
  2. In a Docker container of each image (no screen, no GPU): the distribution's own headless Weston, the program's
     self-test on it (the same checks as tests\weston-headless.ps1 at scale 1), a compositor screenshot.

.DESCRIPTION
  Needs Docker with Linux containers (Docker Desktop on its WSL 2 engine). The images get the packages a user of the
  program would install (libwayland-client, libxkbcommon, libwayland-cursor, fontconfig, libGL for libsk4d.so, a font)
  plus weston: they are built once as fmxwayland-compat:<image> (-Rebuild makes them again). Output, screenshots and
  logs: <BuildRoot>\shots\compat-<image>.

.EXAMPLE
  .\tests\glibc-compat.ps1
  .\tests\glibc-compat.ps1 -Images ubuntu:24.04, debian:13
#>
param(
  [string[]] $Images = @('ubuntu:22.04', 'debian:12', 'fedora:latest'),
  [string] $BuildRoot = 'D:\Work\FMXWayland-build',
  [string] $Config = 'Release',
  # The WSL distribution that runs objdump.
  [string] $Distro = 'Ubuntu-26.04',
  [string] $MaxGlibc = '2.35',
  [switch] $Rebuild
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'HelloChecks.psm1') -Force

$binDir = Join-Path $BuildRoot "bin\Linux64\$Config"
$exe = Join-Path $binDir 'Hello'
if (-not (Test-Path $exe)) { throw "No $exe (build it first: tools\build.ps1 -Project samples\Hello\Hello.dpr)" }
$failed = 0

# 1. The newest GLIBC_x.y symbol version each file needs.
$checks = [ordered]@{}
foreach ($f in $exe, (Join-Path $binDir 'libsk4d.so')) {
  $versions = wsl -d $Distro -u root --exec objdump -T (ConvertTo-WslPath $f) |
    Select-String -Pattern 'GLIBC_([0-9.]+)' -AllMatches | ForEach-Object { $_.Matches } |
    ForEach-Object { [version]($_.Groups[1].Value + '.0') } | Sort-Object -Unique
  $newest = $versions | Select-Object -Last 1
  $name = Split-Path $f -Leaf
  $checks["$($name): needs GLIBC_$($newest.Major).$($newest.Minor) <= $MaxGlibc"] =
    ($null -ne $newest) -and ($newest -le [version]($MaxGlibc + '.0'))
}
$failed += Write-Checks $checks

# 2. The containers. (Native programs' stderr redirected: error records that must not stop the script.)
$ErrorActionPreference = 'Continue'
docker info --format '{{.OSType}}' 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Docker does not answer (Docker Desktop: docker desktop start)' }
foreach ($image in $Images) {
  $name = $image -replace '[:/]', '-'
  $tag = "fmxwayland-compat:$name"
  if ($image -match '^(fedora|rockylinux|almalinux|centos)') {
    $install = 'dnf install -y -q --setopt=install_weak_deps=False weston wayland-utils libwayland-client ' +
      'libwayland-cursor libxkbcommon fontconfig mesa-libGL dejavu-sans-fonts zlib && dnf clean all'
  } else {
    $install = 'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends ' +
      'weston libwayland-client0 libwayland-cursor0 libxkbcommon0 libfontconfig1 libgl1 ' +
      'fonts-dejavu-core zlib1g && rm -rf /var/lib/apt/lists/*'
  }
  $out = Join-Path $BuildRoot "shots\compat-$name"
  if (Test-Path $out) { Remove-Item -Recurse -Force $out }
  New-Item -ItemType Directory -Force -Path $out | Out-Null
  docker image inspect $tag 2>&1 | Out-Null
  if ($Rebuild -or $LASTEXITCODE -ne 0) {
    Write-Host "Building the image $tag"
    "FROM $image`nRUN $install`n" | docker build -t $tag - 2>&1 | ForEach-Object { "$_" } |
      Set-Content (Join-Path $out 'docker-build.log')
    if ($LASTEXITCODE -ne 0) { throw "docker build of $tag failed, see $out\docker-build.log" }
  }
  # --init: GNU timeout 9.10 (Fedora 44) runs nothing as the container's PID 1.
  docker run --rm --init -v "${binDir}:/app:ro" -v "${PSScriptRoot}:/tests:ro" -v "${out}:/out" $tag `
    timeout 120 sh /tests/glibc-compat.sh /out /app/Hello --selftest --quit-after=25 2>&1 | ForEach-Object { "$_" } |
    Set-Content (Join-Path $out 'docker-run.log')
  $system = Get-Content (Join-Path $out 'system.txt') -ErrorAction SilentlyContinue
  Write-Host "$($image): $system"
  $log = Get-Content (Join-Path $out 'program.log') -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
  $checks = Get-HelloSelfTestChecks "$log" $image 1
  $checks["$($image): runs on glibc $($system -replace '.*glibc ([0-9.]+).*', '$1')"] = $log -match '\[hello\] created'
  $checks["$($image): compositor screenshot"] = [bool](Get-ChildItem $out -Filter 'wayland-screenshot*.png')
  $size = Convert-HelloFrameDump $out
  $checks["$($image): frame dump 700x540"] = ($null -ne $size) -and ($size.Width -eq 700) -and ($size.Height -eq 540)
  $failed += Write-Checks $checks
}
if ($failed -gt 0) { Write-Host "$failed check(s) failed"; exit 1 }
Write-Host 'All checks passed'
