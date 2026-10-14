<#
.SYNOPSIS
  Makes a Linux64 platform SDK for dcclinux64 (what tools\build.ps1 links against) from a WSL distribution.

.DESCRIPTION
  The linker (LLVM lld, run by dcclinux64) needs the startup objects, the C library and libgcc of a Linux system.
  The script copies them out of a WSL distribution: the top-level files of /usr/lib/x86_64-linux-gnu, of
  /usr/lib/gcc/x86_64-linux-gnu/<newest>, /lib64/ld-linux-x86-64.so.2 (symbolic links dereferenced: Windows tools do not
  follow them) and makes "lib" a junction to "usr\lib" (merged /usr). The distribution needs libc6-dev,
  libgcc-<n>-dev and zlib1g-dev (libz.so: System.ZLib links -lz) (-Install installs them).

  FMXWayland itself needs no Wayland library at link time (it loads libwayland-client.so.0 and libxkbcommon.so.0 with
  dlopen at run time), so the SDK does not have to contain them.

  Programs linked against the SDK need the SDK's glibc version or a newer one at run time. The default is Ubuntu
  22.04 (glibc 2.35, D:\LinuxSDK\ubuntu-22.04, the default SDK of tools\build.ps1): its programs run on Ubuntu 22.04
  and later, Debian 12, Fedora, ... (tests\glibc-compat.ps1). An SDK of a newer distribution stays selectable
  (-Distro Ubuntu-26.04 makes D:\LinuxSDK\ubuntu-26.04; build.ps1 -Sdk takes it).

  -CreateDistro installs the WSL distribution first when it is missing, without the first-run user prompt
  (wsl --install --no-launch --web-download --location <DistroRoot>\<Distro>); "wsl -d <Distro> -u root" works
  then.

.EXAMPLE
  .\tools\make-linux-sdk.ps1 -CreateDistro -Install
  .\tools\make-linux-sdk.ps1 -Distro Ubuntu-26.04 -Install
#>
param(
  [string] $Distro = 'Ubuntu-22.04',
  # Default: D:\LinuxSDK\<distro in lower case>.
  [string] $Sdk = '',
  [switch] $Install,
  # Install the WSL distribution when it is not there (non-interactive, into <DistroRoot>\<Distro>).
  [switch] $CreateDistro,
  [string] $DistroRoot = 'D:\WSL'
)

$ErrorActionPreference = 'Stop'

if (-not $Sdk) { $Sdk = Join-Path 'D:\LinuxSDK' $Distro.ToLower() }
# (wsl -l writes UTF-16.)
$installed = (wsl -l -q | Out-String) -replace "`0", '' -split "`r?`n" | ForEach-Object { $_.Trim() }
if ($installed -notcontains $Distro) {
  if (-not $CreateDistro) { throw "No WSL distribution $Distro (-CreateDistro installs it)" }
  Write-Host "Installing the WSL distribution $Distro into $(Join-Path $DistroRoot $Distro)"
  wsl --install -d $Distro --no-launch --web-download --location (Join-Path $DistroRoot $Distro)
  if ($LASTEXITCODE -ne 0) { throw "wsl --install -d $Distro failed ($LASTEXITCODE)" }
}

New-Item -ItemType Directory -Force -Path $Sdk | Out-Null
$SdkFull = (Resolve-Path $Sdk).Path
$wslSdk = '/mnt/' + $SdkFull.Substring(0, 1).ToLower() + $SdkFull.Substring(2).Replace('\', '/')

$script = @'
set -e
SDK="$1"
if [ "$2" = "install" ]; then
  GCCMAJOR=$(dpkg-query -W -f '${Version}' libgcc-s1 | sed 's/^\([0-9]*\).*/\1/')
  timeout 600 apt-get update -qq
  DEBIAN_FRONTEND=noninteractive timeout 900 apt-get install -y -qq libc6-dev "libgcc-$GCCMAJOR-dev" zlib1g-dev
fi
GCC=$(ls /usr/lib/gcc/x86_64-linux-gnu | sort -V | tail -1)
test -n "$GCC" || { echo "no /usr/lib/gcc/x86_64-linux-gnu/<version>: install libgcc-<n>-dev"; exit 1; }
test -f /usr/lib/x86_64-linux-gnu/crt1.o || { echo "no crt1.o: install libc6-dev"; exit 1; }
mkdir -p "$SDK/usr/lib/x86_64-linux-gnu" "$SDK/usr/lib/gcc/x86_64-linux-gnu/$GCC" "$SDK/lib64"
find -L /usr/lib/x86_64-linux-gnu -maxdepth 1 -type f -exec cp -L --preserve=timestamps -t "$SDK/usr/lib/x86_64-linux-gnu" {} +
find -L "/usr/lib/gcc/x86_64-linux-gnu/$GCC" -maxdepth 1 -type f -exec cp -L --preserve=timestamps -t "$SDK/usr/lib/gcc/x86_64-linux-gnu/$GCC" {} +
cp -L /lib64/ld-linux-x86-64.so.2 "$SDK/lib64/"
. /etc/os-release
echo "$PRETTY_NAME, glibc $(ldd --version | head -1 | awk '{print $NF}'), gcc $GCC" > "$SDK/sdk-info.txt"
'@
$scriptFile = Join-Path $SdkFull 'make-sdk.sh'
# Through a file: Windows PowerShell mangles quotes in the arguments of native programs.
[IO.File]::WriteAllText($scriptFile, ($script -replace "`r", ''), (New-Object Text.UTF8Encoding $false))
try {
  $mode = if ($Install) { 'install' } else { 'copy' }
  wsl -d $Distro -u root -- sh "$wslSdk/make-sdk.sh" $wslSdk $mode
  if ($LASTEXITCODE -ne 0) { throw "copying the libraries out of $Distro failed ($LASTEXITCODE)" }
} finally {
  Remove-Item $scriptFile -ErrorAction SilentlyContinue
}

$lib = Join-Path $SdkFull 'lib'
if (-not (Test-Path $lib)) {
  New-Item -ItemType Junction -Path $lib -Target (Join-Path $SdkFull 'usr\lib') | Out-Null
}
Write-Host "OK -> ${SdkFull}: $(Get-Content (Join-Path $SdkFull 'sdk-info.txt'))"
