{ FMXWayland: native Linux backends for Delphi FireMonkey.
  Copyright (c) 2026 Fasday. MIT license, see LICENSE. }
unit FMXWayland.Backend;

interface

function PreferX11: Boolean;
function AllowX11Fallback: Boolean;

implementation

uses
  System.SysUtils, FMXWayland.Wayland, FMXWayland.Log;

function AllowX11Fallback: Boolean;
begin
  Result := not SameText(Trim(GetEnvironmentVariable('FMXWAYLAND_BACKEND')), 'wayland');
end;

function PreferX11: Boolean;
var
  Backend, Error: string;
  Display: Pointer;
begin
  Backend := LowerCase(Trim(GetEnvironmentVariable('FMXWAYLAND_BACKEND')));
  if (Backend <> '') and (Backend <> 'auto') and (Backend <> 'wayland') and (Backend <> 'x11') then
  begin
    // Unit initialization precedes FMX's exception handler: report a useful error instead of runtime error 217.
    WlLog(TWlLogLevel.Error, 'FMXWAYLAND_BACKEND must be auto, wayland or x11');
    Halt(1);
  end;
  if Backend = 'x11' then
    Exit(True);
  if Backend = 'wayland' then
    Exit(False);
  // An inherited WAYLAND_SOCKET is a single-use fd. Probing it would consume the application's connection.
  if GetEnvironmentVariable('WAYLAND_SOCKET') <> '' then
    Exit(False);
  if (GetEnvironmentVariable('XDG_RUNTIME_DIR') = '') and
    not GetEnvironmentVariable('WAYLAND_DISPLAY').StartsWith('/') then
    Exit(True);
  // Probe only the transport here: LoadLib can run before FMX and the generated protocol units initialize.
  // The real connection (and its globals) is established by FmuxInit.
  if not LoadWaylandClient(Error) then
    Exit(True);
  Display := wl_display_connect(nil);
  Result := Display = nil;
  if Display <> nil then
    wl_display_disconnect(Display);
end;

end.
