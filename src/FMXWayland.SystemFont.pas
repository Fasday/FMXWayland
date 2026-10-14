{ FMXWayland: native Wayland platform for Delphi FireMonkey on Linux.
  Copyright (c) 2026 Fasday. MIT license, see LICENSE. }

/// <summary>FMX's IFMXSystemFontService on Linux: the default family and size of TFont. Without it FMX falls back to
/// "Tahoma", which Linux systems do not have (fontconfig then substitutes one at every text layout).</summary>
/// <remarks>In a GNOME session (XDG_CURRENT_DESKTOP lists GNOME) the font is GNOME's interface font
/// (org.gnome.desktop.interface font-name, a Pango font description such as "Adwaita Sans 11") read through the
/// settings portal (org.freedesktop.portal.Settings, FMXWayland.Portal): the family as fontconfig resolves it, the
/// size from points to device-independent pixels (dp = pt * 96 / 72, as Windows' service reports its 9 pt message
/// font as 12). Elsewhere, without the portal or with FMXWAYLAND_PORTAL=0, the family is the desktop's sans-serif font
/// as fontconfig resolves it (libfontconfig.so.1, loaded with dlopen; Skia and Pango use the same configuration) and
/// the size FMX's default, 12 (TFont's own default): fontconfig's match carries no desktop size, and FMX's styles are
/// made for it. FMXWAYLAND_FONT="family[,size]" overrides both.</remarks>
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
    /// <summary>GNOME's interface font family, else the desktop's sans-serif family (fontconfig), else
    /// "sans-serif".</summary>
    function GetDefaultFontFamilyName: string;
    /// <summary>GNOME's interface font size in device-independent pixels, else 12 (FMX's default).</summary>
    function GetDefaultFontSize: Single;
  end;

/// <summary>The family fontconfig gives for APattern ("sans-serif", ...); '' without fontconfig.</summary>
function FontconfigMatchFamily(const APattern: string): string;

/// <summary>The first family and the size (device-independent pixels; 0 when it names none) of a Pango font
/// description ("Adwaita Sans 11", "Cantarell Bold Italic 10.5", "Noto Sans, Sans 14px"); False without a
/// family.</summary>
function ParseFontDescription(const ADescription: string; out AFamily: string; out ASize: Single): Boolean;

implementation

uses
  System.SysUtils, System.StrUtils, Posix.Dlfcn, FMXWayland.Log, FMXWayland.Portal;

const
  CDefaultFontSize = 12;
  /// <summary>Milliseconds for the settings portal's answer (the first call may start the portal).</summary>
  CSettingsTimeoutMs = 1500;
  CFcMatchPattern = 0;
  CFcResultMatch = 0;
  /// <summary>The style, variant, weight, stretch and gravity words of a Pango font description, between the
  /// families and the size.</summary>
  CPangoStyleWords: array[0..43] of string = ('Normal', 'Roman', 'Oblique', 'Italic', 'Small-Caps',
    'All-Small-Caps', 'Petite-Caps', 'All-Petite-Caps', 'Unicase', 'Title-Caps', 'Thin', 'Ultra-Light',
    'Extra-Light', 'Light', 'Semi-Light', 'Demi-Light', 'Book', 'Regular', 'Medium', 'Semi-Bold', 'Demi-Bold', 'Bold',
    'Ultra-Bold', 'Extra-Bold', 'Heavy', 'Black', 'Ultra-Black', 'Extra-Black', 'Ultra-Condensed', 'Extra-Condensed',
    'Condensed', 'Semi-Condensed', 'Semi-Expanded', 'Expanded', 'Extra-Expanded', 'Ultra-Expanded', 'Not-Rotated',
    'South', 'Upside-Down', 'North', 'Rotated-Left', 'East', 'Rotated-Right', 'West');

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

function ParseFontDescription(const ADescription: string; out AFamily: string; out ASize: Single): Boolean;
var
  Words: TArray<string>;
  Count, P: Integer;
  Word: string;
  Value: Double;
  Pixels: Boolean;
begin
  AFamily := '';
  ASize := 0;
  Words := ADescription.Split([' '], TStringSplitOptions.ExcludeEmpty);
  Count := Length(Words);
  // Font variations and features come last ("@wght=500", "#tnum=1").
  while (Count > 0) and (Words[Count - 1].StartsWith('@') or Words[Count - 1].StartsWith('#')) do
    Dec(Count);
  if Count > 0 then
  begin
    Word := Words[Count - 1];
    Pixels := Word.EndsWith('px', True);
    if Pixels then
      Word := Word.Substring(0, Word.Length - 2);
    if TryStrToFloat(Word, Value, TFormatSettings.Invariant) and (Value > 0) then
    begin
      // Points at 96 device-independent pixels per inch; "px" sizes are pixels already.
      if Pixels then
        ASize := Value
      else
        ASize := Value * 96 / 72;
      Dec(Count);
    end;
  end;
  while (Count > 0) and MatchText(Words[Count - 1], CPangoStyleWords) do
    Dec(Count);
  if Count > 0 then
    AFamily := string.Join(' ', Words, 0, Count);
  P := AFamily.IndexOf(',');
  if P >= 0 then
    AFamily := AFamily.Substring(0, P);
  AFamily := AFamily.Trim;
  Result := AFamily <> '';
end;

/// True in a GNOME session: XDG_CURRENT_DESKTOP lists GNOME ("GNOME", "ubuntu:GNOME", "GNOME-Classic:GNOME", ...).
function IsGnomeSession: Boolean;
var
  Desktop: string;
begin
  Result := False;
  for Desktop in GetEnvironmentVariable('XDG_CURRENT_DESKTOP').Split([':']) do
    if SameText(Desktop.Trim, 'GNOME') then
      Exit(True);
end;

{ TSystemFontService }

procedure TSystemFontService.Resolve;
var
  Env, Source, Description, Family: string;
  Size: Single;
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
    if IsGnomeSession and (GetEnvironmentVariable('FMXWAYLAND_PORTAL') <> '0') then
      try
        Description := PortalReadSettingString('org.gnome.desktop.interface', 'font-name', CSettingsTimeoutMs);
        if ParseFontDescription(Description, Family, Size) then
        begin
          // The installed family fontconfig gives for it (a substitute when GNOME's is not installed).
          FFamily := FontconfigMatchFamily(Family);
          if FFamily = '' then
            FFamily := Family;
          if Size > 0 then
            FSize := Size;
          Source := 'GNOME font-name "' + Description + '" through the settings portal';
        end
        else
          WlLog(TWlLogLevel.Debug, 'system font: GNOME font-name "%s" names no family', [Description]);
      except
        on E: Exception do
        begin
          FFamily := '';
          FSize := CDefaultFontSize;
          WlLog(TWlLogLevel.Debug, 'system font: no GNOME font-name through the settings portal (%s)', [E.Message]);
        end;
      end;
    if FFamily = '' then
    begin
      try
        FFamily := FontconfigMatchFamily('sans-serif');
      except
        FFamily := '';
      end;
      Source := 'fontconfig sans-serif';
    end;
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
