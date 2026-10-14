# Third-party notices

## Wayland protocol descriptions (`protocols/*.xml`)

The XML files in `protocols/` are copied unchanged from the Wayland projects (Ubuntu 26.04 packages `libwayland-dev`
1.24.0 and `wayland-protocols` 1.47):

| File | Origin |
|---|---|
| `wayland.xml` | wayland (core protocol) |
| `xdg-shell.xml` | wayland-protocols, stable |
| `viewporter.xml` | wayland-protocols, stable |
| `tablet-v2.xml` | wayland-protocols, stable (needed by cursor-shape-v1) |
| `xdg-decoration-unstable-v1.xml` | wayland-protocols, unstable |
| `text-input-unstable-v3.xml` | wayland-protocols, unstable |
| `fractional-scale-v1.xml` | wayland-protocols, staging |
| `cursor-shape-v1.xml` | wayland-protocols, staging |
| `xdg-activation-v1.xml` | wayland-protocols, staging |

They are under the MIT license (the "Expat"/X11 variant); each file carries its copyright notice and the license text
in its `<copyright>` element. The Pascal units in `src/Protocols/` are generated from them by `tools/gen-wayland.ps1`
and repeat these notices at their top.

## Embarcadero's FMUX.Api interface

`FMUX.Api.pas` is generated at build time (`tools/gen-fmux-api.ps1`): its interface section is copied from the user's
own Delphi installation (`$(BDS)\source\fmx\FMUX.Api.pas`, Copyright Eugene Kryukov / Embarcadero) and is not part
of this repository. FMXWayland's implementation section (`src/FMXWayland.FmuxApi.inc`, `src/FMXWayland.Fmux.pas`)
is original code under this repository's MIT license.

## Run-time libraries (not distributed)

FMXWayland loads at run time, with dlopen, libraries of the user's system: libwayland-client (MIT),
libwayland-cursor (MIT), libxkbcommon (MIT). Skia (`libsk4d.so`) comes with Delphi.
