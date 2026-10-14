{ FMXWayland: native Wayland platform for Delphi FireMonkey on Linux.
  Copyright (c) 2026 Fasday. MIT license, see LICENSE. }

/// <summary>Diagnostics of FMXWayland: messages on stderr, prefixed "FMXWayland:".</summary>
/// <remarks>The environment variable FMXWAYLAND_LOG selects the level: 0 = errors only, 1 = also warnings and
/// "not implemented" notes (default), 2 = also debug messages, 3 = also traces of input and frames.</remarks>
unit FMXWayland.Log;

interface

type
  /// <summary>Severity of a message.</summary>
  TWlLogLevel = (Error, Warning, Debug, Trace);

/// <summary>True when messages of ALevel are written.</summary>
function WlLogEnabled(const ALevel: TWlLogLevel): Boolean;
/// <summary>Writes a message of ALevel to stderr (if that level is enabled).</summary>
procedure WlLog(const ALevel: TWlLogLevel; const AMessage: string); overload;
/// <summary>Writes a formatted message of ALevel to stderr (if that level is enabled).</summary>
procedure WlLog(const ALevel: TWlLogLevel; const AFormat: string; const AArgs: array of const); overload;
/// <summary>Writes a warning once per AKey (later calls with the same key are ignored).</summary>
procedure WlLogOnce(const AKey, AMessage: string);
/// <summary>Called by the generated stubs of FMUX.Api: notes once that an FMUX function is not implemented.</summary>
procedure FmuxStubCalled(const AName: string);

implementation

uses
  System.SysUtils, System.SyncObjs, System.Generics.Collections;

var
  GLevel: Integer = -1;
  GLock: TCriticalSection;
  GOnce: TDictionary<string, Boolean>;

function CurrentLevel: Integer;
var
  S: string;
begin
  if GLevel < 0 then
  begin
    S := GetEnvironmentVariable('FMXWAYLAND_LOG');
    GLevel := StrToIntDef(S, 1);
  end;
  Result := GLevel;
end;

function WlLogEnabled(const ALevel: TWlLogLevel): Boolean;
begin
  Result := Ord(ALevel) <= CurrentLevel;
end;

procedure WlLog(const ALevel: TWlLogLevel; const AMessage: string);
const
  CPrefix: array[TWlLogLevel] of string = ('error: ', 'warning: ', 'debug: ', 'trace: ');
begin
  if not WlLogEnabled(ALevel) then
    Exit;
  GLock.Enter;
  try
    Writeln(ErrOutput, 'FMXWayland: ' + CPrefix[ALevel] + AMessage);
    Flush(ErrOutput);
  finally
    GLock.Leave;
  end;
end;

procedure WlLog(const ALevel: TWlLogLevel; const AFormat: string; const AArgs: array of const);
begin
  if WlLogEnabled(ALevel) then
    WlLog(ALevel, Format(AFormat, AArgs));
end;

procedure WlLogOnce(const AKey, AMessage: string);
var
  First: Boolean;
begin
  GLock.Enter;
  try
    First := not GOnce.ContainsKey(AKey);
    if First then
      GOnce.Add(AKey, True);
  finally
    GLock.Leave;
  end;
  if First then
    WlLog(TWlLogLevel.Warning, AMessage);
end;

procedure FmuxStubCalled(const AName: string);
begin
  WlLogOnce('stub:' + AName, AName + ' is not implemented (stub returns zero)');
end;

initialization
  GLock := TCriticalSection.Create;
  GOnce := TDictionary<string, Boolean>.Create;

finalization
  FreeAndNil(GOnce);
  FreeAndNil(GLock);

end.
