{ FMXWayland: replaceable dialog services.
  Written by Hemul GM. Copyright (c) 2026 Fasday and contributors. MIT license, see LICENSE. }

/// <summary>Dialog services of FMXWayland behind a replaceable backend (IFMXWaylandDialogBackend): file dialogs
/// through the xdg-desktop-portal FileChooser with an automatic fallback to FMX's own file dialog form; message
/// dialogs and input queries with FMX's dialog forms.</summary>
/// <remarks>
/// <para>FMXWayland.Fmux routes FMX's file dialogs (TOpenDialog, TSaveDialog, SelectDirectory: FmuxFilesDialog) and
/// FMX's synchronous message dialogs (FmuxMessageDialog) to GetWaylandDialogBackend, and installs the hooks of the
/// platform (ConfigureWaylandDialogHooks): its event loop keeps running while a portal dialog is open, and the
/// program's windows are blocked as under a modal form.</para>
/// <para>The default backend tries the portal and falls back to FMX's file dialog when there is none (no session
/// bus, no xdg-desktop-portal, no FileChooser, folder selection before FileChooser version 3, or the environment
/// variable FMXWAYLAND_PORTAL=0).</para>
/// <para>SetWaylandDialogBackend installs another backend; it then also serves FMX's dialog services (TDialogService:
/// message dialogs and input queries, synchronous and asynchronous; the asynchronous ones are queued and shown
/// modally, since a backend is synchronous). Main thread only.</para>
/// </remarks>
unit FMXWayland.Dialogs;

interface

uses
  System.SysUtils, System.UITypes, FMX.Dialogs, FMXWayland.DialogTypes, FMXWayland.DBus;

type
  /// <summary>A complete FMX backend: FMX's file dialog form (FMXWayland.FileDialog), FMX's message dialog and input
  /// query forms. Override individual methods to use your own forms.</summary>
  TFMXWaylandDialogBackend = class(TInterfacedObject, IFMXWaylandDialogBackend)
  public
    function FileDialog(const Request: TWaylandFileDialogRequest; out Files: TArray<string>;
      var FilterIndex: Integer): Boolean; virtual;
    function MessageDialog(const Message: string; DialogType: TMsgDlgType; Buttons: TMsgDlgButtons;
      DefaultButton: TMsgDlgBtn): TModalResult; virtual;
    function InputQuery(const Caption: string; const Prompts: TArray<string>;
      var Values: TArray<string>): Boolean; virtual;
  end;

/// <summary>Replaces the dialog backend; it also takes FMX's dialog services over (TDialogService...). nil restores
/// the default: the portal with automatic FMX fallback, and FMX's own dialog services. Main thread only.</summary>
procedure SetWaylandDialogBackend(const Backend: IFMXWaylandDialogBackend);
/// <summary>The dialog backend (the default one unless SetWaylandDialogBackend installed another).</summary>
function GetWaylandDialogBackend: IFMXWaylandDialogBackend;
/// <summary>Called by the platform (FMXWayland.Fmux): Pump keeps the application's events going while a portal
/// request waits; BeginModal blocks the program's windows as a modal form would and returns the portal's name of
/// the window the dialog belongs to ('wayland:&lt;handle&gt;' or ''); EndModal undoes it. FMX backends use
/// ShowModal themselves and need none of them.</summary>
procedure ConfigureWaylandDialogHooks(const Pump: TDBusPump; const BeginModal: TFunc<string>;
  const EndModal: TProc);

implementation

uses
  System.Classes, FMX.Platform, FMX.Dialogs.Linux, FMX.DialogHelper, FMX.Dialogs.Default,
  FMXWayland.Portal, FMXWayland.FileDialog, FMXWayland.Log;

type
  /// <summary>File dialogs through the portal, FMX's file dialog when there is none.</summary>
  TPortalDialogBackend = class(TFMXWaylandDialogBackend)
  public
    function FileDialog(const Request: TWaylandFileDialogRequest; out Files: TArray<string>;
      var FilterIndex: Integer): Boolean; override;
  end;

  /// <summary>FMX's dialog services (TDialogService...) through an installed backend.</summary>
  TWaylandDialogService = class(TInterfacedObject, IFMXDialogServiceSync, IFMXDialogServiceAsync)
  public
    procedure ShowMessageSync(const AMessage: string);
    function MessageDialogSync(const AMessage: string; const ADialogType: TMsgDlgType;
      const AButtons: TMsgDlgButtons; const ADefaultButton: TMsgDlgBtn; const AHelpCtx: THelpContext): Integer;
    function InputQuerySync(const ACaption: string; const APrompts: array of string;
      var AValues: array of string): Boolean;
    procedure ShowMessageAsync(const AMessage: string); overload;
    procedure ShowMessageAsync(const AMessage: string; const ACloseDialogProc: TInputCloseDialogProc); overload;
    procedure ShowMessageAsync(const AMessage: string; const ACloseDialogEvent: TInputCloseDialogEvent;
      const AContext: TObject = nil); overload;
    procedure MessageDialogAsync(const AMessage: string; const ADialogType: TMsgDlgType;
      const AButtons: TMsgDlgButtons; const ADefaultButton: TMsgDlgBtn; const AHelpCtx: THelpContext;
      const ACloseDialogProc: TInputCloseDialogProc); overload;
    procedure MessageDialogAsync(const AMessage: string; const ADialogType: TMsgDlgType;
      const AButtons: TMsgDlgButtons; const ADefaultButton: TMsgDlgBtn; const AHelpCtx: THelpContext;
      const ACloseDialogEvent: TInputCloseDialogEvent; const AContext: TObject = nil); overload;
    procedure InputQueryAsync(const ACaption: string; const APrompts: array of string;
      const ADefaultValues: array of string; const ACloseDialogProc: TInputCloseQueryProc); overload;
    procedure InputQueryAsync(const ACaption: string; const APrompts: array of string;
      const ADefaultValues: array of string; const ACloseQueryEvent: TInputCloseQueryWithResultEvent;
      const AContext: TObject = nil); overload;
  end;

var
  GBackend: IFMXWaylandDialogBackend;
  GPump: TDBusPump;
  GBeginModal: TFunc<string>;
  GEndModal: TProc;
  GService: IInterface;
  // FMX's own dialog services (FMX.Dialogs.Linux) while an installed backend replaces them.
  GInstalled: Boolean;
  GFMXSync: IInterface;
  GFMXAsync: IInterface;

function CopyStrings(const Values: array of string): TArray<string>;
var
  I: Integer;
begin
  SetLength(Result, Length(Values));
  for I := 0 to High(Values) do
    Result[I] := Values[I];
end;

procedure ReplaceService(const AGuid: TGUID; const AService: IInterface);
begin
  TPlatformServices.Current.RemovePlatformService(AGuid);
  if AService <> nil then
    TPlatformServices.Current.AddPlatformService(AGuid, AService);
end;

procedure InstallService;
begin
  if GInstalled then
    Exit;
  if GService = nil then
    GService := TWaylandDialogService.Create;
  if not TPlatformServices.Current.SupportsPlatformService(IFMXDialogServiceSync, GFMXSync) then
    GFMXSync := nil;
  if not TPlatformServices.Current.SupportsPlatformService(IFMXDialogServiceAsync, GFMXAsync) then
    GFMXAsync := nil;
  ReplaceService(IFMXDialogServiceSync, GService);
  ReplaceService(IFMXDialogServiceAsync, GService);
  GInstalled := True;
end;

procedure RestoreService;
begin
  if not GInstalled then
    Exit;
  ReplaceService(IFMXDialogServiceSync, GFMXSync);
  ReplaceService(IFMXDialogServiceAsync, GFMXAsync);
  GFMXSync := nil;
  GFMXAsync := nil;
  GInstalled := False;
end;

procedure SetWaylandDialogBackend(const Backend: IFMXWaylandDialogBackend);
begin
  MessageDialogCheckInUIThread;
  GBackend := Backend;
  if Backend <> nil then
    InstallService
  else
    RestoreService;
end;

function GetWaylandDialogBackend: IFMXWaylandDialogBackend;
begin
  if GBackend = nil then
    GBackend := TPortalDialogBackend.Create;
  Result := GBackend;
end;

procedure ConfigureWaylandDialogHooks(const Pump: TDBusPump; const BeginModal: TFunc<string>;
  const EndModal: TProc);
begin
  GPump := Pump;
  GBeginModal := BeginModal;
  GEndModal := EndModal;
end;

{$REGION 'TFMXWaylandDialogBackend'}

function TFMXWaylandDialogBackend.MessageDialog(const Message: string; DialogType: TMsgDlgType;
  Buttons: TMsgDlgButtons; DefaultButton: TMsgDlgBtn): TModalResult;
var
  R: TModalResult;
begin
  MessageDialogCheckInUIThread;
  R := mrNone;
  TDialogHelper.MessageDialog(Message, DialogType, Buttons, DefaultButton, 0,
    procedure(const AResult: TModalResult)
    begin
      R := AResult;
    end, True);
  Result := R;
end;

function TFMXWaylandDialogBackend.InputQuery(const Caption: string; const Prompts: TArray<string>;
  var Values: TArray<string>): Boolean;
begin
  MessageDialogCheckInUIThread;
  Result := DefaultInputQuery(Caption, Prompts, Values, nil);
end;

function TFMXWaylandDialogBackend.FileDialog(const Request: TWaylandFileDialogRequest;
  out Files: TArray<string>; var FilterIndex: Integer): Boolean;
begin
  Result := ExecuteFMXFileDialog(Request, Files, FilterIndex);
end;

{$ENDREGION}

{$REGION 'TPortalDialogBackend'}

function TPortalDialogBackend.FileDialog(const Request: TWaylandFileDialogRequest;
  out Files: TArray<string>; var FilterIndex: Integer): Boolean;
var
  Fallback: Boolean;
  Parent: string;
begin
  MessageDialogCheckInUIThread;
  Files := nil;
  if GetEnvironmentVariable('FMXWAYLAND_PORTAL') = '0' then
    Exit(inherited FileDialog(Request, Files, FilterIndex));
  Fallback := False;
  Result := False;
  Parent := '';
  if Assigned(GBeginModal) then
    Parent := GBeginModal();
  try
    try
      Result := PortalFileDialog(Request, Parent, Files, FilterIndex, GPump);
    except
      on E: EDBusCancelled do
      begin
        WlLog(TWlLogLevel.Debug, 'portal: file dialog cancelled (%s)', [E.Message]);
        Result := False;
      end;
      on E: EPortalUnavailable do
      begin
        WlLog(TWlLogLevel.Debug, 'portal: no file dialog (%s); FMX''s file dialog instead', [E.Message]);
        Fallback := True;
      end;
      on E: EDBusError do
      begin
        WlLog(TWlLogLevel.Warning, 'portal: file dialog failed: %s', [E.Message]);
        Result := False;
      end;
    end;
  finally
    if Assigned(GEndModal) then
      GEndModal();
  end;
  // External modality ends before FMX's form opens: its input would be blocked too.
  if Fallback then
    Result := inherited FileDialog(Request, Files, FilterIndex);
  if not Result then
    Files := nil;
end;

{$ENDREGION}

{$REGION 'TWaylandDialogService'}

procedure TWaylandDialogService.ShowMessageSync(const AMessage: string);
begin
  MessageDialogSync(AMessage, TMsgDlgType.mtCustom, [TMsgDlgBtn.mbOK], TMsgDlgBtn.mbOK, 0);
end;

function TWaylandDialogService.MessageDialogSync(const AMessage: string; const ADialogType: TMsgDlgType;
  const AButtons: TMsgDlgButtons; const ADefaultButton: TMsgDlgBtn; const AHelpCtx: THelpContext): Integer;
var
  Backend: IFMXWaylandDialogBackend;
begin
  MessageDialogCheckInUIThread;
  Backend := GetWaylandDialogBackend;
  Result := Backend.MessageDialog(AMessage, ADialogType, AButtons, ADefaultButton);
end;

function TWaylandDialogService.InputQuerySync(const ACaption: string; const APrompts: array of string;
  var AValues: array of string): Boolean;
var
  Backend: IFMXWaylandDialogBackend;
  Prompts, Values: TArray<string>;
  I: Integer;
begin
  MessageDialogCheckInUIThread;
  Backend := GetWaylandDialogBackend;
  Prompts := CopyStrings(APrompts);
  Values := CopyStrings(AValues);
  Result := Backend.InputQuery(ACaption, Prompts, Values);
  if Result then
  begin
    if Length(Values) <> Length(AValues) then
      raise EArgumentException.Create('Dialog backend changed the value count');
    for I := 0 to High(AValues) do
      AValues[I] := Values[I];
  end;
end;

procedure TWaylandDialogService.ShowMessageAsync(const AMessage: string);
var
  Callback: TInputCloseDialogProc;
begin
  Callback := nil;
  ShowMessageAsync(AMessage, Callback);
end;

procedure TWaylandDialogService.ShowMessageAsync(const AMessage: string;
  const ACloseDialogProc: TInputCloseDialogProc);
begin
  MessageDialogAsync(AMessage, TMsgDlgType.mtCustom, [TMsgDlgBtn.mbOK], TMsgDlgBtn.mbOK, 0, ACloseDialogProc);
end;

procedure TWaylandDialogService.ShowMessageAsync(const AMessage: string;
  const ACloseDialogEvent: TInputCloseDialogEvent; const AContext: TObject);
begin
  ShowMessageAsync(AMessage,
    procedure(const R: TModalResult)
    begin
      if Assigned(ACloseDialogEvent) then
        ACloseDialogEvent(AContext, R);
    end);
end;

procedure TWaylandDialogService.MessageDialogAsync(const AMessage: string; const ADialogType: TMsgDlgType;
  const AButtons: TMsgDlgButtons; const ADefaultButton: TMsgDlgBtn; const AHelpCtx: THelpContext;
  const ACloseDialogProc: TInputCloseDialogProc);
var
  Backend: IFMXWaylandDialogBackend;
begin
  MessageDialogCheckInUIThread;
  // A switch affects subsequent requests, not an already queued dialog.
  Backend := GetWaylandDialogBackend;
  TThread.ForceQueue(nil,
    procedure
    var
      R: TModalResult;
    begin
      R := Backend.MessageDialog(AMessage, ADialogType, AButtons, ADefaultButton);
      if Assigned(ACloseDialogProc) then
        ACloseDialogProc(R);
    end);
end;

procedure TWaylandDialogService.MessageDialogAsync(const AMessage: string; const ADialogType: TMsgDlgType;
  const AButtons: TMsgDlgButtons; const ADefaultButton: TMsgDlgBtn; const AHelpCtx: THelpContext;
  const ACloseDialogEvent: TInputCloseDialogEvent; const AContext: TObject);
begin
  MessageDialogAsync(AMessage, ADialogType, AButtons, ADefaultButton, AHelpCtx,
    procedure(const R: TModalResult)
    begin
      if Assigned(ACloseDialogEvent) then
        ACloseDialogEvent(AContext, R);
    end);
end;

procedure TWaylandDialogService.InputQueryAsync(const ACaption: string; const APrompts: array of string;
  const ADefaultValues: array of string; const ACloseDialogProc: TInputCloseQueryProc);
var
  Backend: IFMXWaylandDialogBackend;
  Prompts, Values: TArray<string>;
begin
  MessageDialogCheckInUIThread;
  Backend := GetWaylandDialogBackend;
  Prompts := CopyStrings(APrompts);
  Values := CopyStrings(ADefaultValues);
  TThread.ForceQueue(nil,
    procedure
    var
      R: TModalResult;
      EditedValues: TArray<string>;
    begin
      EditedValues := Copy(Values);
      if Backend.InputQuery(ACaption, Prompts, EditedValues) then
      begin
        if Length(EditedValues) <> Length(Values) then
          raise EArgumentException.Create('Dialog backend changed the value count');
        R := mrOK;
        Values := EditedValues;
      end
      else
        R := mrCancel;
      if Assigned(ACloseDialogProc) then
        ACloseDialogProc(R, Values);
    end);
end;

procedure TWaylandDialogService.InputQueryAsync(const ACaption: string; const APrompts: array of string;
  const ADefaultValues: array of string; const ACloseQueryEvent: TInputCloseQueryWithResultEvent;
  const AContext: TObject);
begin
  InputQueryAsync(ACaption, APrompts, ADefaultValues,
    procedure(const R: TModalResult; const Values: array of string)
    begin
      if Assigned(ACloseQueryEvent) then
        ACloseQueryEvent(AContext, R, Values);
    end);
end;

{$ENDREGION}

initialization

finalization
  GBackend := nil;
  GService := nil;
  GFMXSync := nil;
  GFMXAsync := nil;
  GPump := nil;
  GBeginModal := nil;
  GEndModal := nil;

end.
