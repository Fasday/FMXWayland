{ FMXWayland: replaceable dialog services.
  Written by Hemul GM. Copyright (c) 2026 Fasday and contributors. MIT license, see LICENSE. }

/// <summary>Dialog services of FMXWayland behind a replaceable backend (IFMXWaylandDialogBackend): file dialogs
/// through the xdg-desktop-portal FileChooser with an automatic fallback to FMX's own dialogs; message dialogs and
/// input queries with FMX's dialog forms.</summary>
unit FMXWayland.Dialogs;

interface

uses
  System.SysUtils, System.UITypes, FMX.Dialogs, FMXWayland.DialogTypes;

type
  /// <summary>A complete FMX backend; override individual methods to use your own forms.</summary>
  TFMXWaylandDialogBackend = class(TInterfacedObject, IFMXWaylandDialogBackend)
  public
    function FileDialog(const Request: TWaylandFileDialogRequest; out Files: TArray<string>;
      var FilterIndex: Integer): Boolean; virtual;
    function MessageDialog(const Message: string; DialogType: TMsgDlgType; Buttons: TMsgDlgButtons;
      DefaultButton: TMsgDlgBtn): TModalResult; virtual;
    function InputQuery(const Caption: string; const Prompts: TArray<string>;
      var Values: TArray<string>): Boolean; virtual;
  end;

/// <summary>Replaces the dialog backend. Call from the UI thread; nil restores the portal with automatic FMX
/// fallback.</summary>
procedure SetWaylandDialogBackend(const Backend: IFMXWaylandDialogBackend);
/// <summary>The dialog backend.</summary>
function GetWaylandDialogBackend: IFMXWaylandDialogBackend;
/// <summary>Platform event processing and external modality; custom FMX backends use ShowModal themselves.</summary>
procedure ConfigureWaylandDialogHooks(const Pump: TFunc<Boolean>; const BeginModal, EndModal: TProc);

implementation

uses
  System.Classes, FMX.Platform, FMX.Dialogs.Linux, FMX.DialogHelper, FMX.Dialogs.Default,
  FMXWayland.Portal, FMXWayland.DBus, FMXWayland.FileDialog;

type
  /// <summary>File dialogs through the portal, FMX's dialogs when there is none.</summary>
  TPortalDialogBackend = class(TFMXWaylandDialogBackend)
  public
    function FileDialog(const Request: TWaylandFileDialogRequest; out Files: TArray<string>;
      var FilterIndex: Integer): Boolean; override;
  end;

  /// <summary>FMX's dialog services (TDialogService...) through the backend.</summary>
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
  GPump: TFunc<Boolean>;
  GBeginModal: TProc;
  GEndModal: TProc;
  GService: IInterface;

function CopyStrings(const Values: array of string): TArray<string>;
var
  I: Integer;
begin
  SetLength(Result, Length(Values));
  for I := 0 to High(Values) do
    Result[I] := Values[I];
end;

procedure RegisterService;
begin
  if GService = nil then
    GService := TWaylandDialogService.Create;
  TPlatformServices.Current.RemovePlatformService(IFMXDialogServiceSync);
  TPlatformServices.Current.RemovePlatformService(IFMXDialogServiceAsync);
  TPlatformServices.Current.AddPlatformService(IFMXDialogServiceSync, GService);
  TPlatformServices.Current.AddPlatformService(IFMXDialogServiceAsync, GService);
end;

procedure SetWaylandDialogBackend(const Backend: IFMXWaylandDialogBackend);
begin
  MessageDialogCheckInUIThread;
  GBackend := Backend;
  RegisterService;
end;

function GetWaylandDialogBackend: IFMXWaylandDialogBackend;
begin
  if GBackend = nil then
    GBackend := TPortalDialogBackend.Create;
  Result := GBackend;
end;

procedure ConfigureWaylandDialogHooks(const Pump: TFunc<Boolean>; const BeginModal, EndModal: TProc);
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
begin
  MessageDialogCheckInUIThread;
  Fallback := False;
  Result := False;
  if Assigned(GBeginModal) then
    GBeginModal();
  try
    try
      Result := PortalFileDialog(Request, Files, FilterIndex, GPump);
    except
      on E: EDBusCancelled do
      begin
        Files := nil;
        Result := False;
      end;
      on E: EPortalUnavailable do
        Fallback := True;
    end;
  finally
    if Assigned(GEndModal) then
      GEndModal();
  end;
  // End external modality before opening an FMX form, otherwise its input would also be blocked.
  if Fallback then
    Result := inherited FileDialog(Request, Files, FilterIndex);
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
  RegisterService;

finalization
  GBackend := nil;
  GService := nil;
  GPump := nil;
  GBeginModal := nil;
  GEndModal := nil;

end.
