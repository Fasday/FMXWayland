{ FMXWayland: native Wayland platform for Delphi FireMonkey on Linux.
  Copyright (c) 2026 Fasday. MIT license, see LICENSE. }

/// <summary>FMX's IFMXSystemFontService on Linux: the default family and size of TFont. Without it FMX falls back to
/// "Tahoma", which Linux systems do not have (fontconfig then substitutes one at every text layout).</summary>
/// <remarks>The family is the desktop's sans-serif font as fontconfig resolves it (libfontconfig.so.1, loaded with
/// dlopen; Skia and Pango use the same configuration). The size is FMX's default in device-independent pixels, 12
/// (TFont's own default; Windows' service reports 12 too, its 9 pt message font at 96 dpi): fontconfig's match
/// carries no desktop size, and FMX's styles are made for it. FMXWAYLAND_FONT="family[,size]" overrides both.
/// TODO: GNOME's font (org.gnome.desktop.interface font-name, through the settings portal on D-Bus) once FMXWayland
/// has a D-Bus client; its size is in points (dp = pt * 96 / 72).</remarks>
unit FMXWayland.SystemFont;

interface

uses
  FMX.Graphics;

type
  /// <summary>IFMXSystemFontService of FMXWayland (registered in FmuxInit).</summary>
  TSystemFontService = class(TInterfacedObject, IFMXSystemFontService)
  private
    FResolved: Boolean;
    FFamily: string;
    FSize: Single;
    procedure Resolve;
  public
    /// <summary>The desktop's sans-serif family (fontconfig), else "sans-serif".</summary>
    function GetDefaultFontFamilyName: string;
    /// <summary>12 device-independent pixels (FMX's default).</summary>
    function GetDefaultFontSize: Single;
  end;

/// <summary>The family fontconfig gives for APattern ("sans-serif", ...); '' without fontconfig.</summary>
function FontconfigMatchFamily(const APattern: string): string;

implementation

uses
  System.SysUtils, Posix.Dlfcn, FMXWayland.Log;

const
  CDefaultFontSize = 12;
  CFcMatchPattern = 0;
  CFcResultMatch = 0;

type
  TFcNameParse = function(AName: PAnsiChar): Pointer; cdecl;
  TFcConfigSubstitute = function(AConfig, APattern: Pointer; AKind: Integer): Integer; cdecl;
  TFcDefaultSubstitute = procedure(APattern: Pointer); cdecl;
  TFcFontMatch = function(AConfig, APattern: Pointer; out AResult: Integer): Pointer; cdecl;
  TFcPatternGetString = function(APattern: Pointer; AObject: PAnsiChar; AIndex: Integer;
    out AValue: PAnsiChar): Integer; cdecl;
  TFcPatternDestroy = procedure(APattern: Pointer); cdecl;

var
  GFcLoaded: Boolean = False;
  GFcLib: NativeUInt = 0;
  FcNameParse: TFcNameParse;
  FcConfigSubstitute: TFcConfigSubstitute;
  FcDefaultSubstitute: TFcDefaultSubstitute;
  FcFontMatch: TFcFontMatch;
  FcPatternGetString: TFcPatternGetString;
  FcPatternDestroy: TFcPatternDestroy;

function LoadFontconfig: Boolean;
begin
  if not GFcLoaded then
  begin
    GFcLoaded := True;
    GFcLib := dlopen('libfontconfig.so.1', RTLD_LAZY);
    if GFcLib <> 0 then
    begin
      @FcNameParse := dlsym(GFcLib, 'FcNameParse');
      @FcConfigSubstitute := dlsym(GFcLib, 'FcConfigSubstitute');
      @FcDefaultSubstitute := dlsym(GFcLib, 'FcDefaultSubstitute');
      @FcFontMatch := dlsym(GFcLib, 'FcFontMatch');
      @FcPatternGetString := dlsym(GFcLib, 'FcPatternGetString');
      @FcPatternDestroy := dlsym(GFcLib, 'FcPatternDestroy');
    end;
  end;
  Result := Assigned(FcNameParse) and Assigned(FcConfigSubstitute) and Assigned(FcDefaultSubstitute) and
    Assigned(FcFontMatch) and Assigned(FcPatternGetString) and Assigned(FcPatternDestroy);
end;

function FontconfigMatchFamily(const APattern: string): string;
var
  Pattern, Match: Pointer;
  Res: Integer;
  Value: PAnsiChar;
begin
  Result := '';
  if not LoadFontconfig then
    Exit;
  Pattern := FcNameParse(PAnsiChar(UTF8String(APattern)));
  if Pattern = nil then
    Exit;
  try
    // As every fontconfig client resolves a name: the configuration's substitutions, then the defaults.
    FcConfigSubstitute(nil, Pattern, CFcMatchPattern);
    FcDefaultSubstitute(Pattern);
    Match := FcFontMatch(nil, Pattern, Res);
    if Match = nil then
      Exit;
    try
      if (FcPatternGetString(Match, 'family', 0, Value) = CFcResultMatch) and (Value <> nil) then
        Result := UTF8ToString(Value);
    finally
      FcPatternDestroy(Match);
    end;
  finally
    FcPatternDestroy(Pattern);
  end;
end;

{ TSystemFontService }

procedure TSystemFontService.Resolve;
var
  Env, Source: string;
  P: Integer;
begin
  if FResolved then
    Exit;
  FResolved := True;
  FSize := CDefaultFontSize;
  Env := Trim(GetEnvironmentVariable('FMXWAYLAND_FONT'));
  if Env <> '' then
  begin
    P := Env.LastIndexOf(',');
    if P >= 0 then
    begin
      FSize := StrToFloatDef(Trim(Env.Substring(P + 1)), CDefaultFontSize, TFormatSettings.Invariant);
      Env := Trim(Env.Substring(0, P));
    end;
    FFamily := Env;
    Source := 'FMXWAYLAND_FONT';
  end
  else
  begin
    try
      FFamily := FontconfigMatchFamily('sans-serif');
    except
      FFamily := '';
    end;
    Source := 'fontconfig sans-serif';
  end;
  if FFamily = '' then
  begin
    // Without fontconfig: the generic name, which Skia and Pango resolve themselves.
    FFamily := 'sans-serif';
    Source := 'no fontconfig';
  end;
  if FSize <= 0 then
    FSize := CDefaultFontSize;
  WlLog(TWlLogLevel.Debug, 'system font: "%s" %.1f (%s)', [FFamily, FSize, Source]);
end;

function TSystemFontService.GetDefaultFontFamilyName: string;
begin
  Resolve;
  Result := FFamily;
end;

function TSystemFontService.GetDefaultFontSize: Single;
begin
  Resolve;
  Result := FSize;
end;

end.
