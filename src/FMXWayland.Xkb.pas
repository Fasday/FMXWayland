{ FMXWayland: native Wayland platform for Delphi FireMonkey on Linux.
  Copyright (c) 2026 Fasday. MIT license, see LICENSE. }

/// <summary>Binding of libxkbcommon (loaded with dlopen at run time): keymaps from the compositor, keyboard state,
/// keysyms and their characters, and the compose (dead keys) tables.</summary>
unit FMXWayland.Xkb;

interface

type
  /// <summary>Opaque struct xkb_context.</summary>
  PXkbContext = type Pointer;
  /// <summary>Opaque struct xkb_keymap.</summary>
  PXkbKeymap = type Pointer;
  /// <summary>Opaque struct xkb_state.</summary>
  PXkbState = type Pointer;
  /// <summary>Opaque struct xkb_compose_table.</summary>
  PXkbComposeTable = type Pointer;
  /// <summary>Opaque struct xkb_compose_state.</summary>
  PXkbComposeState = type Pointer;

const
  XKB_CONTEXT_NO_FLAGS = 0;
  XKB_KEYMAP_FORMAT_TEXT_V1 = 1;
  XKB_KEYMAP_COMPILE_NO_FLAGS = 0;
  XKB_STATE_MODS_EFFECTIVE = 1 shl 3;
  XKB_MOD_NAME_SHIFT = 'Shift';
  XKB_MOD_NAME_CAPS = 'Lock';
  XKB_MOD_NAME_CTRL = 'Control';
  XKB_MOD_NAME_ALT = 'Mod1';
  XKB_MOD_NAME_NUM = 'Mod2';
  XKB_MOD_NAME_LOGO = 'Mod4';
  XKB_COMPOSE_FEED_IGNORED = 0;
  XKB_COMPOSE_FEED_ACCEPTED = 1;
  XKB_COMPOSE_NOTHING = 0;
  XKB_COMPOSE_COMPOSING = 1;
  XKB_COMPOSE_COMPOSED = 2;
  XKB_COMPOSE_CANCELLED = 3;

var
  xkb_context_new: function(AFlags: Integer): PXkbContext; cdecl;
  xkb_context_unref: procedure(AContext: PXkbContext); cdecl;
  xkb_keymap_new_from_string: function(AContext: PXkbContext; AString: PAnsiChar; AFormat: Integer;
    AFlags: Integer): PXkbKeymap; cdecl;
  xkb_keymap_unref: procedure(AKeymap: PXkbKeymap); cdecl;
  xkb_keymap_key_repeats: function(AKeymap: PXkbKeymap; AKey: UInt32): Integer; cdecl;
  xkb_keymap_key_get_syms_by_level: function(AKeymap: PXkbKeymap; AKey: UInt32; ALayout: UInt32; ALevel: UInt32;
    out ASyms: PCardinal): Integer; cdecl;
  xkb_state_new: function(AKeymap: PXkbKeymap): PXkbState; cdecl;
  xkb_state_unref: procedure(AState: PXkbState); cdecl;
  xkb_state_update_mask: function(AState: PXkbState; ADepressedMods, ALatchedMods, ALockedMods, ADepressedLayout,
    ALatchedLayout, ALockedLayout: UInt32): Integer; cdecl;
  xkb_state_key_get_one_sym: function(AState: PXkbState; AKey: UInt32): UInt32; cdecl;
  xkb_state_key_get_utf32: function(AState: PXkbState; AKey: UInt32): UInt32; cdecl;
  xkb_state_key_get_layout: function(AState: PXkbState; AKey: UInt32): UInt32; cdecl;
  xkb_state_mod_name_is_active: function(AState: PXkbState; AName: PAnsiChar; AType: Integer): Integer; cdecl;
  xkb_keysym_to_utf32: function(AKeysym: UInt32): UInt32; cdecl;
  // Compose (optional: missing in very old libxkbcommon)
  xkb_compose_table_new_from_locale: function(AContext: PXkbContext; ALocale: PAnsiChar;
    AFlags: Integer): PXkbComposeTable; cdecl;
  xkb_compose_table_unref: procedure(ATable: PXkbComposeTable); cdecl;
  xkb_compose_state_new: function(ATable: PXkbComposeTable; AFlags: Integer): PXkbComposeState; cdecl;
  xkb_compose_state_unref: procedure(AState: PXkbComposeState); cdecl;
  xkb_compose_state_feed: function(AState: PXkbComposeState; AKeysym: UInt32): Integer; cdecl;
  xkb_compose_state_reset: procedure(AState: PXkbComposeState); cdecl;
  xkb_compose_state_get_status: function(AState: PXkbComposeState): Integer; cdecl;
  xkb_compose_state_get_utf8: function(AState: PXkbComposeState; ABuffer: PAnsiChar; ASize: NativeUInt): Integer;
    cdecl;

/// <summary>Loads libxkbcommon.so.0 (once). False with AError = what is missing.</summary>
function LoadXkbCommon(out AError: string): Boolean;
/// <summary>True when the compose functions are available.</summary>
function XkbComposeAvailable: Boolean;

implementation

uses
  System.SysUtils, Posix.Dlfcn;

var
  GHandle: NativeUInt = 0;
  GLoaded: Boolean = False;

function XkbComposeAvailable: Boolean;
begin
  Result := GLoaded and Assigned(xkb_compose_table_new_from_locale) and Assigned(xkb_compose_state_new) and
    Assigned(xkb_compose_state_feed) and Assigned(xkb_compose_state_get_status) and
    Assigned(xkb_compose_state_get_utf8) and Assigned(xkb_compose_state_reset);
end;

function LoadXkbCommon(out AError: string): Boolean;
var
  Missing: string;

  function Sym(const AName: string; ARequired: Boolean = True): Pointer;
  var
    M: TMarshaller;
  begin
    Result := dlsym(GHandle, M.AsAnsi(AName).ToPointer);
    if (Result = nil) and ARequired then
      Missing := Missing + ' ' + AName;
  end;

begin
  AError := '';
  if GLoaded then
    Exit(True);
  if GHandle = 0 then
    GHandle := dlopen('libxkbcommon.so.0', RTLD_NOW);
  if GHandle = 0 then
  begin
    AError := 'cannot load libxkbcommon.so.0 (' + string(UTF8String(dlerror)) + '); install the package libxkbcommon0';
    Exit(False);
  end;
  Missing := '';
  xkb_context_new := Sym('xkb_context_new');
  xkb_context_unref := Sym('xkb_context_unref');
  xkb_keymap_new_from_string := Sym('xkb_keymap_new_from_string');
  xkb_keymap_unref := Sym('xkb_keymap_unref');
  xkb_keymap_key_repeats := Sym('xkb_keymap_key_repeats');
  xkb_keymap_key_get_syms_by_level := Sym('xkb_keymap_key_get_syms_by_level', False);
  xkb_state_new := Sym('xkb_state_new');
  xkb_state_unref := Sym('xkb_state_unref');
  xkb_state_update_mask := Sym('xkb_state_update_mask');
  xkb_state_key_get_one_sym := Sym('xkb_state_key_get_one_sym');
  xkb_state_key_get_utf32 := Sym('xkb_state_key_get_utf32');
  xkb_state_key_get_layout := Sym('xkb_state_key_get_layout', False);
  xkb_state_mod_name_is_active := Sym('xkb_state_mod_name_is_active');
  xkb_keysym_to_utf32 := Sym('xkb_keysym_to_utf32');
  xkb_compose_table_new_from_locale := Sym('xkb_compose_table_new_from_locale', False);
  xkb_compose_table_unref := Sym('xkb_compose_table_unref', False);
  xkb_compose_state_new := Sym('xkb_compose_state_new', False);
  xkb_compose_state_unref := Sym('xkb_compose_state_unref', False);
  xkb_compose_state_feed := Sym('xkb_compose_state_feed', False);
  xkb_compose_state_reset := Sym('xkb_compose_state_reset', False);
  xkb_compose_state_get_status := Sym('xkb_compose_state_get_status', False);
  xkb_compose_state_get_utf8 := Sym('xkb_compose_state_get_utf8', False);
  if Missing <> '' then
  begin
    AError := 'libxkbcommon.so.0 lacks:' + Missing;
    Exit(False);
  end;
  GLoaded := True;
  Result := True;
end;

end.
