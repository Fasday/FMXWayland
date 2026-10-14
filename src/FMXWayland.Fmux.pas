{ FMXWayland: native Wayland platform for Delphi FireMonkey on Linux.
  Copyright (c) 2026 Fasday. MIT license, see LICENSE. }

/// <summary>The FMUX API (the function pointers of FMUX.Api that FMX for Linux calls) implemented over Wayland.
/// </summary>
unit FMXWayland.Fmux;

interface

/// <summary>Assigns the implemented function pointers of FMUX.Api (called by the generated FMUX.Api.LoadLib after it
/// has assigned the stubs).</summary>
procedure AssignFmuxApi;

implementation

uses
  FMUX.Api;

procedure AssignFmuxApi;
begin
end;

end.
