{ FMXWayland: native Wayland platform for Delphi FireMonkey on Linux.
  Copyright (c) 2026 Fasday. MIT license, see LICENSE. }

/// <summary>Binding of libwayland-cursor (optional, loaded with dlopen): Xcursor themes as wl_buffers, for compositors
/// without the cursor-shape-v1 protocol.</summary>
unit FMXWayland.WaylandCursor;

interface

uses
  FMXWayland.Protocol.Wayland;

type
  /// <summary>struct wl_cursor_image.</summary>
  Twl_cursor_image = record
    width: UInt32;
    height: UInt32;
    hotspot_x: UInt32;
    hotspot_y: UInt32;
    delay: UInt32;
  end;
  Pwl_cursor_image = ^Twl_cursor_image;
  TWlCursorImageArray = array[0..1023] of Pwl_cursor_image;
  PWlCursorImageArray = ^TWlCursorImageArray;

  /// <summary>struct wl_cursor.</summary>
  Twl_cursor = record
    image_count: Cardinal;
    images: PWlCursorImageArray;
    name: PAnsiChar;
  end;
  Pwl_cursor = ^Twl_cursor;

  /// <summary>Opaque struct wl_cursor_theme.</summary>
  Pwl_cursor_theme = type Pointer;

var
  wl_cursor_theme_load: function(AName: PAnsiChar; ASize: Integer; AShm: Pwl_shm): Pwl_cursor_theme; cdecl;
  wl_cursor_theme_destroy: procedure(ATheme: Pwl_cursor_theme); cdecl;
  wl_cursor_theme_get_cursor: function(ATheme: Pwl_cursor_theme; AName: PAnsiChar): Pwl_cursor; cdecl;
  wl_cursor_image_get_buffer: function(AImage: Pwl_cursor_image): Pwl_buffer; cdecl;

/// <summary>Loads libwayland-cursor.so.0 (once); False if it is not installed.</summary>
function LoadWaylandCursor: Boolean;

implementation

uses
  Posix.Dlfcn;

var
  GTried: Boolean = False;
  GLoaded: Boolean = False;

function LoadWaylandCursor: Boolean;
var
  H: NativeUInt;
begin
  if not GTried then
  begin
    GTried := True;
    H := dlopen('libwayland-cursor.so.0', RTLD_NOW);
    if H <> 0 then
    begin
      @wl_cursor_theme_load := dlsym(H, 'wl_cursor_theme_load');
      @wl_cursor_theme_destroy := dlsym(H, 'wl_cursor_theme_destroy');
      @wl_cursor_theme_get_cursor := dlsym(H, 'wl_cursor_theme_get_cursor');
      @wl_cursor_image_get_buffer := dlsym(H, 'wl_cursor_image_get_buffer');
      GLoaded := Assigned(wl_cursor_theme_load) and Assigned(wl_cursor_theme_destroy) and
        Assigned(wl_cursor_theme_get_cursor) and Assigned(wl_cursor_image_get_buffer);
    end;
  end;
  Result := GLoaded;
end;

end.
