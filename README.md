# FMXWayland

A native Wayland platform for Delphi FireMonkey (FMX) on Linux, written in Object Pascal — without Embarcadero's
closed `libfmux.so` and without GTK.

Work in progress (phase 1). See the end of this file for the status.

## How it works

FMX for Linux (`FMX.Platform.Linux`, `FMX.Clipboard.Linux`, `FMX.Skia.Canvas`, ...) calls the closed library libfmux
(a GTK 3 wrapper) through the function-pointer variables of the unit `FMUX.Api`. The precompiled FMX units accept
another `FMUX.Api` with the same interface section, so FMXWayland generates one at build time
(`tools\gen-fmux-api.ps1`):

- the interface section is copied verbatim from the local Delphi installation (`$(BDS)\source\fmx\FMUX.Api.pas`).
  It is Embarcadero's code, so the generated file is never committed;
- the implementation section is FMXWayland's: every function pointer gets a stub that logs once and returns zero,
  then `FMXWayland.Fmux.AssignFmuxApi` assigns the implemented functions.

The platform logic of `FMX.Platform.Linux` stays Embarcadero's; FMXWayland implements what libfmux did.

## Building

```powershell
.\tools\build.ps1 -Project samples\Hello\Hello.dpr
```

needs Delphi 13 (RAD Studio 37.0) with the Linux platform and a Linux platform SDK (`tools\make-linux-sdk.ps1` makes
one from a WSL distribution). Output goes to `D:\Work\FMXWayland-build` (`-BuildRoot`).

## License

MIT, see [LICENSE](LICENSE).
