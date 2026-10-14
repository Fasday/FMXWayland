{ FMXWayland: native Wayland platform for Delphi FireMonkey on Linux.
  Copyright (c) 2026 Fasday. MIT license, see LICENSE. }

/// <summary>Fills the function pointers of the generated FMUX.Api (FMUX.Api.LoadLib) before any of FMX's units that
/// call them initializes.</summary>
/// <remarks>FMUX.Api's implementation uses FMXWayland.Fmux, which uses FMX, whose FMX.Platform.Linux uses FMUX.Api:
/// a cycle, so the order of their initializations depends on which of them the program reaches first. When a unit
/// such as FMX.Clipboard.Linux reaches FMUX.Api before FMX.Platform.Linux is reached, FMX.Platform.Linux initializes
/// first (in the middle of FMUX.Api's implementation uses) and calls FmuxSetLog, which FMUX.Api's own initialization
/// has not assigned yet: an access violation at address 0 before the program starts (found with FastCanvas's
/// PortProbe). The generated FMUX.Api names this unit in its implementation uses before FMXWayland.Fmux; it uses
/// nothing of FMX, so it is initialized before anything FMXWayland.Fmux leads to, in every order. LoadLib runs once;
/// what it assigns (FMXWayland.Fmux.AssignFmuxApi) needs no initialized unit.</remarks>
unit FMXWayland.FmuxLoad;

interface

implementation

uses
  FMUX.Api;

initialization
  LoadLib;

end.
