unit DialogCheckMain;

{ The form of tests\DialogCheck: checks of FMXWayland's D-Bus client against a real bus (addresses, the
  authentication, method calls, error replies, timeouts, a dictionary of variants, signals, cancellation by the pump)
  and of the dialog backend (a test backend installed with SetWaylandDialogBackend: what TOpenDialog, TSaveDialog,
  SelectDirectory, TDialogService and the FMUX functions hand it, and what comes back). One step per timer tick; each
  writes "dialogcheck: ..." to stdout; tests\dialog-check.ps1 checks them. }

interface

uses
  System.SysUtils, System.Types, System.UITypes, System.Classes, FMX.Types, FMX.Forms;

type
  TDialogCheckForm = class(TForm)
  private
    FTimer: TTimer;
    FStep: Integer;
    procedure Log(const AText: string);
    procedure StepTimer(Sender: TObject);
    procedure CheckBus;
    procedure CheckBackend;
  public
    constructor Create(AOwner: TComponent); override;
  end;

var
  DialogCheckForm: TDialogCheckForm;

implementation

uses
  System.Generics.Collections, Posix.Unistd, FMX.Dialogs, FMX.DialogService.Sync, FMX.DialogService.Async,
  FMX.Platform, FMUX.Api, FMXWayland.Posix, FMXWayland.DBus, FMXWayland.Portal, FMXWayland.DialogTypes,
  FMXWayland.Dialogs;

type
  /// <summary>Answers without showing anything and logs what it was asked.</summary>
  TTestBackend = class(TFMXWaylandDialogBackend)
  public
    Form: TDialogCheckForm;
    ManyNames: Boolean;
    function FileDialog(const Request: TWaylandFileDialogRequest; out Files: TArray<string>;
      var FilterIndex: Integer): Boolean; override;
    function MessageDialog(const Message: string; DialogType: TMsgDlgType; Buttons: TMsgDlgButtons;
      DefaultButton: TMsgDlgBtn): TModalResult; override;
    function InputQuery(const Caption: string; const Prompts: TArray<string>;
      var Values: TArray<string>): Boolean; override;
  end;

var
  GTestBackend: TTestBackend;

function TTestBackend.FileDialog(const Request: TWaylandFileDialogRequest; out Files: TArray<string>;
  var FilterIndex: Integer): Boolean;
var
  S: string;
  F: TWaylandFileFilter;
  I: Integer;
begin
  S := '';
  for F in Request.Filters do
    S := S + Format('[%s: %s]', [F.Name, string.Join(' ', F.Patterns)]);
  Form.Log(Format('backend file dialog kind %d title "%s" file "%s" folder "%s" filters %s index %d multiple %s ' +
    'overwrite %s', [Ord(Request.Kind), Request.Title, Request.InitialFile, Request.InitialFolder, S,
    Request.FilterIndex, BoolToStr(Request.Multiple, True), BoolToStr(Request.ConfirmOverwrite, True)]));
  if ManyNames then
  begin
    // 30 names of 50 characters: FMX's buffer of 1024 characters holds 20 of them (with the line breaks).
    SetLength(Files, 30);
    for I := 0 to High(Files) do
      Files[I] := Format('/tmp/%.2d', [I]) + StringOfChar('x', 43);
  end
  else if Request.Kind = TWaylandFileDialogKind.SelectFolder then
    Files := ['/tmp/chosen folder']
  else if Request.Multiple then
    Files := ['/tmp/first file.txt', '/tmp/second.txt']
  else
    Files := ['/tmp/only.txt'];
  FilterIndex := 1;
  Result := True;
end;

function TTestBackend.MessageDialog(const Message: string; DialogType: TMsgDlgType; Buttons: TMsgDlgButtons;
  DefaultButton: TMsgDlgBtn): TModalResult;
begin
  Form.Log(Format('backend message "%s" type %d yes %s no %s default %d', [Message, Ord(DialogType),
    BoolToStr(TMsgDlgBtn.mbYes in Buttons, True), BoolToStr(TMsgDlgBtn.mbNo in Buttons, True), Ord(DefaultButton)]));
  Result := mrYes;
end;

function TTestBackend.InputQuery(const Caption: string; const Prompts: TArray<string>;
  var Values: TArray<string>): Boolean;
var
  I: Integer;
begin
  Form.Log(Format('backend input query "%s" %d prompts', [Caption, Length(Prompts)]));
  for I := 0 to High(Values) do
    Values[I] := UpperCase(Values[I]);
  Result := True;
end;

constructor TDialogCheckForm.Create(AOwner: TComponent);
begin
  inherited CreateNew(AOwner);
  SetTextCodePage(Output, CP_UTF8);
  Caption := 'Dialog check';
  ClientWidth := 400;
  ClientHeight := 200;
  FTimer := TTimer.Create(Self);
  FTimer.Interval := 400;
  FTimer.OnTimer := StepTimer;
  FTimer.Enabled := True;
end;

procedure TDialogCheckForm.Log(const AText: string);
begin
  Writeln('dialogcheck: ', AText);
  Flush(Output);
end;

procedure TDialogCheckForm.StepTimer(Sender: TObject);
begin
  FTimer.Enabled := False;
  Inc(FStep);
  try
    case FStep of
      1:
        CheckBus;
      2:
        CheckBackend;
    else
      begin
        Log('done');
        Close;
        Exit;
      end;
    end;
  except
    on E: Exception do
      Log(Format('step %d raised %s: %s', [FStep, E.ClassName, E.Message]));
  end;
  FTimer.Enabled := True;
end;

procedure TDialogCheckForm.CheckBus;
var
  A, B: TDBusConnection;
  Reply, Msg: TDBusMessage;
  Arg, Creds: TDBusValue;
  Names: TStringList;
  Child: TDBusValue;
  Started: UInt64;
  Version: Cardinal;
  Stop: Boolean;
begin
  // The session bus of the environment: a missing socket first, then an abstract one (with a guid=).
  A := TDBusConnection.Create;
  try
    Log('connected through "' + GetEnvironmentVariable('DBUS_SESSION_BUS_ADDRESS') + '" as ' + A.UniqueName);
    Reply := A.Call('org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus', 'GetId', []);
    try
      Log(Format('GetId: %d hex digits', [Length(Reply.Body[0].Text)]));
    finally
      Reply.Free;
    end;
    // as: the names on the bus, ours among them.
    Reply := A.Call('org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus', 'ListNames', []);
    Names := TStringList.Create;
    try
      for Child in Reply.Body[0].Children do
        Names.Add(Child.Text);
      Log(Format('ListNames: signature %s, own name listed %s', [Reply.Signature,
        BoolToStr(Names.IndexOf(A.UniqueName) >= 0, True)]));
    finally
      Names.Free;
      Reply.Free;
    end;
    // a{sv}: dictionary entries of variants.
    Arg := TDBusValue.Str(A.UniqueName);
    try
      Reply := A.Call('org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus',
        'GetConnectionCredentials', [Arg]);
    finally
      Arg.Free;
    end;
    try
      Creds := Reply.Body[0];
      Log(Format('credentials: signature %s, UnixUserID %d (getuid %d), ProcessID is ours %s', [Reply.Signature,
        Creds.Item('UnixUserID').Number, getuid, BoolToStr(Creds.Item('ProcessID').Number = UInt64(getpid), True)]));
    finally
      Reply.Free;
    end;
    // An error reply.
    try
      A.Call('org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus', 'NoSuchMethod', []).Free;
      Log('error reply: none');
    except
      on E: EDBusError do
        Log('error reply: ' + E.RemoteName);
    end;
    // The other address forms: a path with a guid, unix:runtime=yes ($XDG_RUNTIME_DIR/bus).
    B := TDBusConnection.Create(nil, 'unix:path=' + GetEnvironmentVariable('DC_BUS_PATH') + ',guid=0123456789abcdef');
    try
      Log('connected through a path as ' + B.UniqueName);
      // A call nobody answers (A serves nothing): a timeout.
      Started := TThread.GetTickCount64;
      try
        B.Call(A.UniqueName, '/', 'org.example.Nobody', 'Hello', [], 400).Free;
        Log('timeout: answered');
      except
        on E: EDBusTimeout do
          Log(Format('timeout: EDBusTimeout after %d ms', [TThread.GetTickCount64 - Started]));
      end;
      // A signal: A watches the bus's NameOwnerChanged of B, then B goes away.
      A.Subscribe('org.freedesktop.DBus', 'NameOwnerChanged');
      A.AddMatch('type=''signal'',sender=''org.freedesktop.DBus'',member=''NameOwnerChanged'',arg0=''' +
        B.UniqueName + '''');
    finally
      Log('B was ' + B.UniqueName);
      B.Free;
    end;
    Msg := A.WaitSignal('/org/freedesktop/DBus', 'org.freedesktop.DBus', 'NameOwnerChanged', 3000);
    try
      if Msg = nil then
        Log('signal: none')
      else
        Log(Format('signal: NameOwnerChanged %s, signature %s, new owner "%s"', [Msg.Body[0].Text, Msg.Signature,
          Msg.Body[2].Text]));
    finally
      Msg.Free;
    end;
  finally
    A.Free;
  end;
  A := TDBusConnection.Create(nil, 'unix:runtime=yes');
  try
    Log('connected through unix:runtime=yes as ' + A.UniqueName);
  finally
    A.Free;
  end;
  // A pump that says stop (after the connection is made): the wait ends with EDBusCancelled.
  Stop := False;
  A := TDBusConnection.Create;
  B := TDBusConnection.Create(
    function(const AFd, ATimeoutMs: Integer): Boolean
    var
      P: TPollFd;
    begin
      if not Stop then
      begin
        P.fd := AFd;
        P.events := POLLIN;
        P.revents := 0;
        poll(@P, 1, ATimeoutMs);
      end;
      Result := not Stop;
    end);
  Stop := True;
  try
    try
      B.Call(A.UniqueName, '/', 'org.example.Nobody', 'Hello', [], 3000).Free;
      Log('cancel: answered');
    except
      on E: EDBusCancelled do
        Log('cancel: EDBusCancelled');
      on E: EDBusError do
        Log('cancel: ' + E.ClassName);
    end;
  finally
    B.Free;
    A.Free;
  end;
  // No portal on this bus: unavailable, at once.
  Started := TThread.GetTickCount64;
  try
    Version := PortalFileChooserVersion;
    Log(Format('portal: version %d', [Version]));
  except
    on E: EPortalUnavailable do
      Log(Format('portal: unavailable (%s) after %d ms', [E.RemoteName, TThread.GetTickCount64 - Started]));
  end;
  // An address without a usable socket.
  try
    TDBusConnection.Create(nil, 'tcp:host=localhost,port=1;unix:path=/nonexistent/bus').Free;
    Log('bad address: connected');
  except
    on E: EDBusUnavailable do
      Log('bad address: EDBusUnavailable');
  end;
end;

procedure TDialogCheckForm.CheckBackend;
var
  Open: TOpenDialog;
  Save: TSaveDialog;
  Dir: string;
  R: Integer;
  Values: array of string;
  AsyncResult: TModalResult;
  Svc: IInterface;
  Buffer: array[0..63] of Char;
  Backend: IFMXWaylandDialogBackend;
begin
  GTestBackend := TTestBackend.Create;
  GTestBackend.Form := Self;
  Backend := GTestBackend;
  SetWaylandDialogBackend(Backend);
  TPlatformServices.Current.SupportsPlatformService(IFMXDialogServiceSync, Svc);
  Log('service with the backend: ' + (Svc as TObject).ClassName);
  Open := TOpenDialog.Create(nil);
  try
    Open.Title := 'Check open';
    Open.InitialDir := '/tmp';
    Open.FileName := 'start.a';
    Open.Filter := 'A files|*.a;*.b|C files (*.c)|*.c';
    Open.FilterIndex := 2;
    Open.Options := Open.Options + [TOpenOption.ofAllowMultiSelect];
    Log(Format('open: %s, %d files: %s, filter index %d', [BoolToStr(Open.Execute, True), Open.Files.Count,
      string.Join('|', Open.Files.ToStringArray), Open.FilterIndex]));
    GTestBackend.ManyNames := True;
    Open.Execute;
    Log(Format('many names: %d of 30 arrive', [Open.Files.Count]));
    GTestBackend.ManyNames := False;
  finally
    Open.Free;
  end;
  Save := TSaveDialog.Create(nil);
  try
    Save.Title := 'Check save';
    Save.FileName := '/tmp/existing.txt';
    Save.Options := Save.Options + [TOpenOption.ofOverwritePrompt];
    Log(Format('save: %s, %s', [BoolToStr(Save.Execute, True), Save.FileName]));
  finally
    Save.Free;
  end;
  Log(Format('folder: %s, %s', [BoolToStr(SelectDirectory('Check folder', '/tmp', Dir), True), Dir]));
  R := TDialogServiceSync.MessageDialog('Sync?', TMsgDlgType.mtConfirmation, [TMsgDlgBtn.mbYes, TMsgDlgBtn.mbNo],
    TMsgDlgBtn.mbNo, 0);
  Log(Format('sync message result %d', [R]));
  SetLength(Values, 2);
  Values[0] := 'abc';
  Values[1] := 'def';
  Log(Format('sync input query %s: %s %s', [BoolToStr(TDialogServiceSync.InputQuery('Query', ['One', 'Two'], Values),
    True), Values[0], Values[1]]));
  AsyncResult := mrNone;
  TDialogServiceAsync.MessageDialog('Async?', TMsgDlgType.mtWarning, [TMsgDlgBtn.mbYes, TMsgDlgBtn.mbNo],
    TMsgDlgBtn.mbYes, 0,
    procedure(const AResult: TModalResult)
    begin
      AsyncResult := AResult;
      Log(Format('async message result %d', [AResult]));
    end);
  Log(Format('async message queued, result yet %d', [AsyncResult]));
  // The FMUX functions themselves.
  R := FmuxMessageDialog(PChar('Fmux?'), 2, FMUX_BTN_Yes or FMUX_BTN_No);
  Log(Format('FmuxMessageDialog result %d', [R]));
  StrPCopy(Buffer, 'xyz');
  Log(Format('FmuxInputQuery %s: %s', [BoolToStr(FmuxInputQuery(PChar('Caption'), PChar('Prompt'), @Buffer[0],
    Length(Buffer)), True), string(PChar(@Buffer[0]))]));
  // The default again: FMX's own dialog services.
  SetWaylandDialogBackend(nil);
  TPlatformServices.Current.SupportsPlatformService(IFMXDialogServiceSync, Svc);
  Log('service without it: ' + (Svc as TObject).ClassName);
end;

end.
