# FMXWayland

A native Wayland platform for Delphi FireMonkey (FMX) on Linux, written in Object Pascal — without Embarcadero's
closed `libfmux.so` and without GTK. FMX programs talk to the Wayland compositor directly (libwayland-client and
libxkbcommon, loaded at run time) and draw into shared-memory buffers with FMX's default Linux canvas (cairo and
Pango, as with libfmux) or, optionally, with its Skia canvas.

![The Hello sample on WSLg](docs/screenshots/hello.png)

Phase 1 (this state): an FMX program with the usual controls runs on WSLg and on Weston — windows, popups, mouse,
keyboard, clipboard, timers, modal forms, message boxes, HiDPI (integer) scale, client-side decorations, on both of
FMX's Linux canvases. See
[Status](#status) and [What does not work](#what-does-not-work-yet).

## How it works

FMX for Linux (`FMX.Platform.Linux`, `FMX.Canvas.Linux`, `FMX.Clipboard.Linux`, `FMX.Skia.Canvas`, ...) calls the
closed library libfmux (a GTK 3 wrapper) through the ~186 function-pointer variables of the unit `FMUX.Api`. The
precompiled FMX units accept another `FMUX.Api` with the same interface section, so FMXWayland generates one at build
time (`tools\gen-fmux-api.ps1`):

- the **interface section** is copied verbatim from the local Delphi installation
  (`$(BDS)\source\fmx\FMUX.Api.pas`). It is Embarcadero's code: the generated file is never committed
  (`.gitignore`);
- the **implementation section** is FMXWayland's: every function pointer first gets a generated stub with the
  declared signature (logs its name once, returns zero/nil/False), then `FMXWayland.Fmux.AssignFmuxApi` assigns the
  implemented functions; the helper routines of the interface (`FmuxStateToShiftState`, `MsgDlgButtonsToButtons`,
  ...) are in `src\FMXWayland.FmuxApi.inc`. There is no libfmux resource and no `dlopen` of libfmux.

The platform logic of `FMX.Platform.Linux` (forms, menus loop, text service, ...) stays Embarcadero's; FMXWayland
implements what libfmux did:

| Unit | What it is |
|---|---|
| `FMXWayland.Fmux` | The FMUX functions: windows (`TFmuxWindow` forwards Wayland events to FMX's callbacks), the paint context, bitmaps, timers, the loop, clipboard, modal loops, message boxes, `IFMXWaylandNativeWindow` |
| `FMXWayland.Cairo`, `FMXWayland.CairoApi` | FMX's default Linux canvas (`FMX.Canvas.Linux`) served by the FMUX canvas, text layout, bitmap codec and font functions on the system's cairo, Pango and gdk-pixbuf (loaded with `dlopen` on first use); contributed by Hemul GM |
| `FMXWayland.Platform` | The Wayland side, independent of FMX: connection and globals, outputs, the event loop (display fd + eventfd for wake-ups + timers, `prepare_read`/`read_events` so other readers such as Vulkan WSI can share the display), `TWlWindow` (xdg_toplevel / xdg_popup, wl_shm double/triple buffering, frame callbacks, damage, scale, client-side decorations), pointer, keyboard (xkbcommon keymap, key repeat, compose/dead keys), cursors (cursor-shape-v1 or an Xcursor theme through libwayland-cursor), clipboard (wl_data_device) |
| `FMXWayland.Wayland`, `FMXWayland.Xkb`, `FMXWayland.WaylandCursor` | Bindings of libwayland-client, libxkbcommon, libwayland-cursor, loaded with `dlopen`: programs start without link-time dependencies and say what is missing |
| `src\Protocols\FMXWayland.Protocol.*` | Generated from the protocol XML files in `protocols\` by `tools\gen-wayland.ps1`, a small wayland-scanner for Pascal |
| `FMXWayland.Keys` | XKB keysyms / evdev codes -> FMX virtual keys |
| `FMXWayland.Native` | `IFMXWaylandNativeWindow`, the contract for GPU canvases (below) |

**Painting.** Both of FMX's Linux canvases work; the frames go to the compositor as wl_shm buffers, attached with the
damaged rectangle and committed; frame callbacks pace the repaints.

- **FMX's default canvas** (`FMX.Canvas.Linux`, `TLinuxCanvas`: what an FMX program uses unless it sets
  `GlobalUseSkia`) calls the FMUX canvas functions (paths, fills, strokes, gradients, clips, bitmaps), text layouts and
  bitmap codecs. libfmux implemented them with cairo, Pango and gdk-pixbuf; `FMXWayland.Cairo` does the same on the
  system's libraries. The paint context is a cairo context over the window's retained frame: FMX repaints only the
  damaged region, and each wl_shm buffer (they rotate, so a buffer holds an older frame) gets the regions that changed
  since its frame. Text is antialiased in grayscale (a Wayland client does not know the subpixel order of the screen).
- **The Skia raster canvas** (`FMX.Skia`, `GlobalUseSkia := True`, `libsk4d.so` next to the program) gets the frame
  as its context, renders the window into an FMUX bitmap (plain memory) and copies it with `FmuxCanvasDrawBitmap`.

The two draw the same layout; antialiasing, hinting and Pango's line spacing differ a little
(`tests\canvas-check.ps1` puts both side by side, below).

**Coordinates.** Wayland clients do not know where their windows are. Every window keeps a virtual origin (what FMX
set with `SetWindowRect`); `ClientToScreen`/`ScreenToClient` and the screen positions of mouse events use it, so
FMX's own conversions stay consistent. Popups (combo box lists, popup menus — FMX forms with `FormStyle = Popup`)
become xdg_popups placed relative to their parent (the form of their placement target) and take the position the
compositor gives them.

**Decorations.** With `zxdg_decoration_manager_v1` the compositor draws the title bar. Without it (WSLg, Weston,
GNOME) FMXWayland draws client-side decorations: a subsurface around the window with the title (rendered by FMX's
canvas), minimize/maximize/close buttons, moving, resizing at the edges and the window menu. FMX's form rectangle
includes them, like a frame on other platforms. `FMXWAYLAND_CSD=0` turns them off.

## Requirements

- Delphi 13 (RAD Studio 37.0) with the Linux platform (Enterprise/Architect) and FMX for Linux with its sources:
  in Delphi 13.0 part of the product (`source\fmx\FMUX.Api.pas`, units in `lib\linux64`), in later releases (13.1) a
  GetIt package in the catalog repository. `tools\delphi-env.ps1` finds the `FMUX.Api.dcu` the build uses (the
  Linux64 library path of the IDE, then the catalog repository, then `lib\linux64`) and the `FMUX.Api.pas` next to it:
  the generated interface must be the one those precompiled FMX units were compiled with. `gen-fmux-api.ps1 -Source`
  overrides it.
- A Linux platform SDK to link against: `tools\make-linux-sdk.ps1` makes one from a WSL distribution (or use the
  IDE's SDK manager). The default is Ubuntu 22.04's: programs need glibc 2.35 or later (Ubuntu 22.04+, Debian 12+,
  Fedora 36+, ...; see [Tests](#tests), `tests\glibc-compat.ps1`).
- At run time: a Wayland compositor with `wl_compositor`, `wl_shm` and `xdg_wm_base`; the libraries
  libwayland-client0 and libxkbcommon0 (libwayland-cursor0 for cursors on compositors without cursor-shape-v1); for
  FMX's default canvas cairo, Pango, pangocairo and gdk-pixbuf with fontconfig and fonts (Debian/Ubuntu: `libcairo2
  libpango-1.0-0 libpangocairo-1.0-0 libgdk-pixbuf-2.0-0`, present on any desktop); with the Skia canvas instead,
  `libsk4d.so` (Skia, `$(BDS)\Redist\linux64`) next to the program. No GTK, no X11, no libfmux.

## Using it in a project

1. Generate `FMUX.Api.pas` (`.\tools\gen-fmux-api.ps1 -Out <dir>\FMUX.Api.pas`) and put `<dir>`, `src` and
   `src\Protocols` **first** on the unit search path (the IDE/`dcclinux64` then compile it instead of linking
   Embarcadero's precompiled `FMUX.Api`).
2. That is all for FMX's default canvas (cairo). For the Skia canvas instead, in the .dpr:

   ```pascal
   uses
     System.StartUpCopy, FMX.Forms, FMX.Types, FMX.Skia, MainForm in 'MainForm.pas';
   begin
     GlobalUseSkia := True;
     Application.Initialize;
     ...
   ```

Nothing else changes in the program. `samples\Hello\Hello.dproj` does this with `..\..\gen` (generate with
`-Out gen\FMUX.Api.pas`); Hello uses Skia unless it is built with the define `NOSKIA`.

## Building

```powershell
.\tools\make-linux-sdk.ps1 -CreateDistro -Install    # once: libc, crt*.o, libgcc, libz of Ubuntu 22.04 (WSL)
.\tools\build.ps1 -Project samples\Hello\Hello.dpr   # Release; -Config Debug
.\tools\build.ps1 -Project samples\Hello\Hello.dpr -Define NOSKIA -BuildRoot D:\Work\FMXWayland-build\cairo
```

The SDK decides the oldest glibc the program runs with. `make-linux-sdk.ps1` copies it out of a WSL distribution
(default `Ubuntu-22.04` into `D:\LinuxSDK\ubuntu-22.04`; `-CreateDistro` installs the distribution first when it is
missing, without the first-run prompt: `wsl --install -d Ubuntu-22.04 --no-launch --web-download --location
D:\WSL\Ubuntu-22.04`; `-Install` installs `libc6-dev`, `libgcc-<n>-dev` and `zlib1g-dev` in it). Linked against it,
Hello needs `GLIBC_2.34` at most and `libsk4d.so` `GLIBC_2.29`. Another SDK stays selectable:
`make-linux-sdk.ps1 -Distro Ubuntu-26.04 -Install` makes `D:\LinuxSDK\ubuntu-26.04` (glibc 2.43), `build.ps1 -Sdk
D:\LinuxSDK\ubuntu-26.04` links against it.

`build.ps1` generates `FMUX.Api.pas` into `<BuildRoot>\gen`, compiles with `dcclinux64` (linking with its lld against
the SDK: `--syslibroot`, `--libpath`), copies `libsk4d.so` next to the program when it links FMX's Skia units (its
map file lists `System.Skia.API`; a program on FMX's default canvas needs none). Everything goes to `-BuildRoot`
(default `D:\Work\FMXWayland-build`: `bin\Linux64\<Config>\`, `dcu\`). It also works around the missing Linux64
`FMX.Filter.res` of Delphi 13. msbuild builds the .dproj too, given the SDK:

```
msbuild samples\Hello\Hello.dproj /p:Config=Release /p:Platform=Linux64 /p:DCC_SysLibRoot=<sdk>
  /p:DCC_LibraryPath=<bds>\lib\linux64\release%3B<sdk>\usr\lib\x86_64-linux-gnu%3B<sdk>\usr\lib\gcc\x86_64-linux-gnu\<n>
```

The protocol units are committed; after adding or updating an XML file in `protocols\` run `.\tools\gen-wayland.ps1`.

## Running

On WSLg (Windows 11, WSL 2):

```sh
export XDG_RUNTIME_DIR=/mnt/wslg/runtime-dir WAYLAND_DISPLAY=wayland-0
unset DISPLAY
./Hello --verbose
```

Environment variables: `FMXWAYLAND_LOG` = 0 errors only, 1 warnings and "not implemented" notes (default), 2 debug,
3 input traces; `FMXWAYLAND_DUMP_DIR=<dir>` writes the latest frame of each window as a BMP (debugging);
`FMXWAYLAND_CSD=0` no client-side decorations; `FMXWAYLAND_APP_ID` the xdg app id (default: the program name);
`XCURSOR_THEME`, `XCURSOR_SIZE` for cursor themes.

## Tests

- `tests\hello-e2e.ps1` — end to end on WSLg with **real input**: it moves the Windows mouse and types (WSLg forwards
  Windows input to its compositor over RDP, so events take the real wl_pointer/wl_keyboard path), takes screenshots
  of the windows and checks the program's log: pointer, button clicks, typing (any keyboard layout), editing keys,
  Ctrl+A/Ctrl+X, mouse wheel, clipboard both ways (WSLg shares it with Windows), combo box popup, check box, second
  form, modal form (the main window must not react meanwhile), close request from the compositor, the close and
  maximize buttons of the client-side title bar, maximize/restore, resize from code, clean exit. Needs an
  interactive desktop nobody else is using (it takes the mouse for about a minute).
- `tests\weston-headless.ps1` — non-interactive: the sample on a private headless Weston 14 at output scale 1 and
  2 (buffer size through `IFMXWaylandNativeWindow`, the self-test steps up to a message box answered by a timer, the
  program's frame dumps, a compositor screenshot, clean exit). `-BuildRoot <root of a NOSKIA build> -Canvas
  TLinuxCanvas` runs it on FMX's default canvas.
- `tests\canvas-check.ps1` — builds `tests\CanvasCheck` for both canvases and runs them on headless Weston at scale 1
  and 2: the same drawing (gradients, opacity, dashes and caps, bitmap brushes, scaled and partial bitmaps, the PNG
  codec, text beyond the BMP, wrapping, alignment, trimming, styles, rotation, text as a path, a degenerate matrix),
  checks of what the program measures (positions around a surrogate pair, PtInPath, the PNG round trip) and the two
  frames side by side, Skia left, cairo right.
- `tests\glibc-compat.ps1` — the glibc symbol versions Hello and `libsk4d.so` need (`objdump -T`, at most 2.35),
  then Hello's self-test on the headless Weston of other distributions in Docker containers (no screen, no GPU;
  images with the run-time libraries, built once as `fmxwayland-compat:<image>`): `ubuntu:22.04` (glibc 2.35,
  Weston 9), `debian:12` (glibc 2.36, Weston 10), `fedora:latest` (Fedora 44, glibc 2.43, Weston 15) by default;
  `-Images` takes others. Needs Docker Desktop (Linux containers). On glibc 2.31 (Debian 11) the loader refuses the
  program (`GLIBC_2.34 not found`).

Evidence of the last runs: all checks of the first two passed (WSLg on Windows 11 with Ubuntu 26.04, Weston 14.0.2
headless), and all of `glibc-compat.ps1` with the program linked against the Ubuntu 22.04 SDK (2026-10-14);
`Hello --selftest` also runs to the end on WSLg (its seat appears only after the RDP client connects, a second or so
after the program starts: the clipboard falls back to a process-local one until then).

| | |
|---|---|
| ![combo box popup](docs/screenshots/hello-combo-popup.png) | ![message box](docs/screenshots/hello-message-dialog.png) ![modal form](docs/screenshots/hello-modal.png) |

Headless Weston, output scale 2 (2x rendering, client-side decorations, the combo box drop-down as an xdg_popup):

![Weston at scale 2](docs/screenshots/weston-headless-scale2.png)

FMX's default canvas (cairo and Pango, `-Define NOSKIA`) on headless Weston, and `tests\canvas-check.ps1` (Skia
left, cairo right): weston-headless and canvas-check passed with both canvases at scale 1 and 2, and the self-test of
both runs to the end on headless sway 1.11 too (which tiles the window: its size there is sway's, not 700x540)
(2026-10-14).

![Hello on FMX's cairo canvas](docs/screenshots/hello-cairo.png)

![Skia and cairo side by side](docs/screenshots/canvas-check.png)

## IFMXWaylandNativeWindow (contract for GPU canvases)

A GPU canvas (FastCanvas on Vulkan) creates its own `VkSurfaceKHR` for a window with
`vkCreateWaylandSurfaceKHR(wl_display, wl_surface)`. FMXWayland registers, when it connects (in `FmuxInit`, during
the initialization of `FMX.Platform`), an FMX platform service:

```pascal
type
  IFMXWaylandNativeWindow = interface
    ['{B04A2FBC-1322-42BC-98A6-D526A7854F2C}']
    function GetWaylandDisplay: Pointer;                                   // wl_display*
    function GetWaylandSurface(const AHandle: TWindowHandle): Pointer;     // wl_surface*, nil if not an FMXWayland window
    function GetBufferSize(const AHandle: TWindowHandle): TSize;           // buffer pixels = client size x scale
    function GetScale(const AHandle: TWindowHandle): Single;               // buffer pixels per logical pixel
    procedure SetExternalPresentation(const AHandle: TWindowHandle; const AValue: Boolean);
  end;
```

A library that must not depend on FMXWayland declares the same interface (same GUID, same methods in the same order,
same signatures; Delphi's default calling convention) and asks with
`TPlatformServices.Current.SupportsPlatformService(IFMXWaylandNativeWindow, Svc)` (`samples\Hello` does exactly
that). Never change this declaration; extensions get a new interface with a new GUID. The rules:

- The `wl_surface` is the window's content surface: it lives as long as the FMX window handle (also across
  hide/show; popups get new xdg_popup objects at each show, the surface stays). Its size is the client area — the
  client-side decorations are a separate subsurface.
- `GetBufferSize`/`GetScale` change on resize and scale changes; FMX resizes its canvas then (form resize, and
  `TScaleChangedMessage` for scale changes).
- `SetExternalPresentation(Handle, True)`: FMXWayland keeps calling FMX's paint (the canvas renders and presents in
  `EndScene`), but stops attaching its own wl_shm frames. FMXWayland still sets the surface's buffer scale (or the
  viewport destination with fractional scaling) and the decoration subsurface; that state is double-buffered and
  takes effect with the presenter's next commit (`vkQueuePresentKHR`).
- Everything is on the main thread; FMXWayland dispatches only the default event queue, with the
  `wl_display_prepare_read` protocol, so Vulkan WSI's own queue can coexist.

## Status

Tested on WSLg (Weston-based, RDP; xdg_wm_base 1, no xdg-decoration, no cursor-shape, no fractional-scale) and
Weston 14 headless (scale 1 and 2). 102 of 186 FMUX functions are assigned (76 fully, 26 partly); the full list:
[docs/FMUX-STATUS.md](docs/FMUX-STATUS.md).

| Area | FMUX functions | Status |
|---|---|---|
| Application, loop, threads | FmuxInit, FmuxRun, FmuxHandleMessage, FmuxTerminate, FmuxWakeMainThread, FmuxGetKeyState, FmuxGet/SetVersionInfo | implemented |
| Timers | FmuxCreateTimer, FmuxDestroyTimer | implemented |
| Windows | FmuxCreateWindow, FmuxDestroyWindow, FmuxShowWindow, FmuxSetWindowState, FmuxSetWindowTitle, FmuxGet/SetClientSize, FmuxGetWindowRect, FmuxInvalidateRect, FmuxProcessUpdates, FmuxClientToScreen, FmuxScreenToClient, FmuxGetWindowScale, FmuxGet/SetWindowFullScreen, FmuxShowModal, FmuxSetMainWindow | implemented |
| Windows (Wayland limits) | FmuxSetWindowRect (position virtual), FmuxActivateWindow/FmuxWindowBringToFront (xdg-activation request), FmuxWindowSendToBack (no-op), FmuxSetWindowIcon (ignored), FmuxSetCapture/ReleaseCapture (implicit grab), FmuxGetWindowNativeHandle/DrawingHandle (wl_surface) | partial |
| Popups | through FmuxCreateWindow (Popup) / FmuxShowWindow | implemented (xdg_popup, no grab) |
| Screens | FmuxGetScreenSize, FmuxGetScreenScale, FmuxGetDisplayFromWindow, FmuxGetDisplayFromPoint; FmuxGetDisplayInfo (work area = output) | implemented / partial |
| Mouse, cursor | FmuxGetMousePos (partial: last position over an own window), FmuxSetCursor | implemented |
| Keyboard | (FmuxKey callback): xkbcommon, repeat, compose, layout-independent shortcuts | implemented |
| Painting, bitmaps (both canvases) | FmuxBitmapCreate, FmuxBitmapDestroy, FmuxGetBitmapInfo, FmuxCanvasDrawBitmap | implemented |
| FMX's default canvas (cairo, Pango, gdk-pixbuf) | FmuxCreateContext, FmuxDestroyContext, FmuxSave/Restore, FmuxSetClipRects, FmuxIntersect/ExcludeClipRect, FmuxCanvas* (paths, fills, strokes, dashes, gradients, bitmap brushes, matrix, quality, clear, PtInPath), FmuxCreateTextLayout ... FmuxLayoutToPath, FmuxBitmapLoad, FmuxBitmapSave | implemented |
| Clipboard | FmuxClipboardHas/Get/SetText | implemented |
| Clipboard, other formats | FmuxClipboardHas/GetImage, FmuxClipboardHas/GetCustom (report "none"); FmuxClipboardSetImage/SetCustom/SetArray | partial / stub |
| Dialogs | FmuxMessageDialog (FMX's own dialog form) | partial |
| Dialogs | FmuxFilesDialog, FmuxInputQuery (FMX uses its own input query anyway) | stub |
| IME | FmuxImeEnterControl/ExitControl/SetCaretPos (no-ops: characters come from xkbcommon) | partial |
| Tooltips, gestures | FmuxAddTooltip/RemoveTooltip, FmuxAdd/RemoveGestureRecognizer (no-ops) | partial |
| OpenGL contexts, PDF canvas | FmuxCreateSharedContext, FmuxCreateThreadContext, FmuxMakeCurrentContext, FmuxFlushBuffer, FmuxCreatePDFContext... | stub |
| Fonts | FmuxGetFontCount, FmuxGetFontName (the system's families); FmuxAddCustomFont, FmuxAddCustomFontFromData | partial / stub |
| Main menu (native menu bar) | FmuxCreateMainMenu, FmuxCreateMenu, FmuxCreateMenuItem, FmuxMenuAddItem, FmuxSetSubmenu, FmuxUpdateMenuItem | stub (no menu bar shown) |
| Printing, PDF | FmuxEnumPrinters ... FmuxSetAlwaysAskOutputFile | stub |
| Web view, media, video capture | FmuxCreateWebView..., FmuxCreateMedia..., FmuxCaptureDeviceEnum... | stub |
| Shell | FmuxOpenFile, FmuxOpenUrl, FmuxGetFileIcon, FmuxGetFileType | stub |
| Drag and drop | FmuxBeginDragDrop (and the Drag callback) | stub |
| Synthetic events, screenshots | FmuxGen*, FmuxTakeScreenshot, FmuxGetCursor... | stub |

## What does not work yet

- FMX's default canvas: custom fonts (`TFontManager` / `FmuxAddCustomFont`: fontconfig application fonts are not
  wired yet), printing and PDF (`FmuxCreatePDFContext`), OpenGL contexts. Pango spaces wrapped lines by the font's
  metrics, a little wider than Skia for some fonts (Ubuntu); FMX's own dialogs size themselves to it.
- `TMainMenu` (a native menu bar under GTK): not shown. Popup menus (`TPopupMenu`) are FMX forms and work.
- Drag and drop (also between applications), file dialogs, clipboard images and custom formats, IME (text-input-v3),
  touch and gestures, tooltips, window icons, printing, web browser, media player.
- Window positions are not under the program's control (Wayland); `Position = poScreenCenter` and the like have no
  effect. Popups do not grab the pointer (xdg_popup.grab): they close like other FMX popups (a click elsewhere in
  the program, or the form losing activation when another application is clicked).
- Fractional scaling (wp_fractional_scale_v1 + wp_viewporter) is implemented but untested (neither WSLg nor Weston 14
  offer it); scale changes after start (moving a window to a monitor with another scale) are reported to FMX with
  `TScaleChangedMessage` but not tested.
- `FmuxActivateWindow`/`FmuxWindowBringToFront` ask for activation with an xdg-activation token (the compositor
  decides); untested, neither WSLg nor Weston 14 offer xdg_activation_v1.

## Next steps

1. **FastCanvas (Vulkan)**: FastCanvas declares `IFMXWaylandNativeWindow` (contract above), creates its
   `VkSurfaceKHR` on Wayland and calls `SetExternalPresentation`; test both canvases side by side.
2. **IME** with text-input-unstable-v3 (the protocol unit exists): FmuxImeEnterControl/ExitControl/SetCaretPos to
   `enable`/`set_cursor_rectangle`, preedit to FMX's marked text.
3. **Decorations**: polish the client-side ones (shadows, theme colors, `prefers-color-scheme` through the portal);
   use xdg-decoration where offered (done) and test on KDE/sway and GNOME.
4. **Drag and drop** over wl_data_device (FMX's Drag callback, FmuxBeginDragDrop), clipboard images and custom
   formats, primary selection.
5. **File dialogs** through xdg-desktop-portal (D-Bus `org.freedesktop.portal.FileChooser`), `FmuxOpenUrl`/
   `FmuxOpenFile` through the OpenURI portal or `xdg-open`.
6. **Menus**: draw `TMainMenu` as an FMX menu bar inside the window.
7. Popup grabs (`xdg_popup.grab` for menus), `xdg_popup.reposition` (version 3), window icons
   (xdg-toplevel-icon), touch (wl_touch -> FMX touch/gesture callbacks).
8. **X11 fallback backend** sharing the FMX adapter (`FMXWayland.Fmux` talks to the Wayland core through
   `TWlWindow`'s events; an X11 core with the same shape would plug in).
9. Packaging: a design-time/package setup so the IDE builds Linux FMX projects with FMXWayland without copying paths.

## Contributors

- **Hemul GM** — FMX's default Linux canvas on cairo, Pango and gdk-pixbuf (`FMXWayland.Cairo`,
  `FMXWayland.CairoApi`): ordinary FMX programs draw on FMXWayland without Skia.

Thank you!

## License

MIT, see [LICENSE](LICENSE). Third-party notices: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
