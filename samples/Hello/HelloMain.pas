unit HelloMain;

{ The main form of the FMXWayland sample. The controls are made in code (FormCreate), so the .fmx stays minimal. }

interface

uses
  System.SysUtils, System.Types, System.UITypes, System.Classes, System.Rtti, FMX.Types, FMX.Controls, FMX.Forms,
  FMX.Graphics, FMX.Objects, FMX.StdCtrls, FMX.Edit, FMX.ListBox, FMX.Ani, FMX.Layouts, FMX.Controls.Presentation;

type
  THelloForm = class(TForm)
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure FormMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Single);
    procedure FormKeyDown(Sender: TObject; var Key: Word; var KeyChar: Char; Shift: TShiftState);
    procedure FormMouseWheel(Sender: TObject; Shift: TShiftState; WheelDelta: Integer;
      var Handled: Boolean);
  private
    FVerbose: Boolean;
    FClicks: Integer;
    FTicks: Integer;
    FTickStart: TDateTime;
    FTitle: TText;
    FGradient: TRectangle;
    FCircle: TCircle;
    FSpinner: TRectangle;
    FMouseLabel: TLabel;
    FClickButton: TButton;
    FCountLabel: TLabel;
    FEdit: TEdit;
    FEchoLabel: TLabel;
    FCombo: TComboBox;
    FCheck: TCheckBox;
    FCopyButton: TButton;
    FPasteButton: TButton;
    FClipLabel: TLabel;
    FSecondButton: TButton;
    FModalButton: TButton;
    FMaximizeButton: TButton;
    FResizeButton: TButton;
    FStatusLabel: TLabel;
    FAnimTimer: TTimer;
    FQuitTimer: TTimer;
    FSecondCount: Integer;
    FSelfTimer: TTimer;
    FSelfStep: Integer;
    FSelfSecond: TForm;
    FEarlyPopup: TTimer;
    FEarlyPopupOnPaint: Boolean;
    FEarlyPopupOnCreate: Boolean;
    procedure Log(const AText: string);
    procedure LogFonts;
    procedure EarlyPopupTimer(Sender: TObject);
    procedure FormPaint(Sender: TObject; Canvas: TCanvas; const ARect: TRectF);
    procedure SelfTestStep(Sender: TObject);
    procedure SelfTestModalTimer(Sender: TObject);
    procedure SelfTestMessageTimer(Sender: TObject);
    function AddLabel(const AX, AY, AWidth: Single; const AText: string): TLabel;
    function AddButton(const AX, AY, AWidth: Single; const AText: string; const AOnClick: TNotifyEvent): TButton;
    procedure ClickButtonClick(Sender: TObject);
    procedure EditChangeTracking(Sender: TObject);
    procedure EditKeyDown(Sender: TObject; var Key: Word; var KeyChar: Char; Shift: TShiftState);
    procedure ComboChange(Sender: TObject);
    procedure CheckChange(Sender: TObject);
    procedure CopyButtonClick(Sender: TObject);
    procedure PasteButtonClick(Sender: TObject);
    procedure SecondButtonClick(Sender: TObject);
    procedure ModalButtonClick(Sender: TObject);
    procedure MaximizeButtonClick(Sender: TObject);
    procedure ResizeButtonClick(Sender: TObject);
    procedure MessageButtonClick(Sender: TObject);
    procedure AnimTimerTimer(Sender: TObject);
    procedure QuitTimerTimer(Sender: TObject);
    procedure NativeTimerTimer(Sender: TObject);
    procedure FormResize(Sender: TObject);
    procedure FormActivate(Sender: TObject);
    procedure FormDeactivate(Sender: TObject);
  end;

var
  HelloForm: THelloForm;

implementation

{$R *.fmx}

uses
  System.UIConsts, System.DateUtils, FMX.Platform, FMX.DialogService.Sync;

type
  /// The contract of FMXWayland.Native.IFMXWaylandNativeWindow, declared here again (same GUID, same methods) the way
  /// a library that does not depend on FMXWayland (FastCanvas) declares it.
  IWaylandNativeWindowContract = interface
    ['{B04A2FBC-1322-42BC-98A6-D526A7854F2C}']
    function GetWaylandDisplay: Pointer;
    function GetWaylandSurface(const AHandle: TWindowHandle): Pointer;
    function GetBufferSize(const AHandle: TWindowHandle): TSize;
    function GetScale(const AHandle: TWindowHandle): Single;
    procedure SetExternalPresentation(const AHandle: TWindowHandle; const AValue: Boolean);
  end;

const
  CComboColors: array[0..4] of TAlphaColor = (TAlphaColors.Crimson, TAlphaColors.Seagreen, TAlphaColors.Royalblue,
    TAlphaColors.Gold, TAlphaColors.Darkorchid);
  CComboNames: array[0..4] of string = ('Red', 'Green', 'Blue', 'Yellow', 'Purple');

procedure THelloForm.Log(const AText: string);
begin
  if FVerbose then
  begin
    Writeln('[hello] ', AText);
    Flush(Output);
  end;
end;

function THelloForm.AddLabel(const AX, AY, AWidth: Single; const AText: string): TLabel;
begin
  Result := TLabel.Create(Self);
  Result.Parent := Self;
  Result.Position.Point := PointF(AX, AY);
  Result.Width := AWidth;
  Result.Text := AText;
end;

function THelloForm.AddButton(const AX, AY, AWidth: Single; const AText: string;
  const AOnClick: TNotifyEvent): TButton;
begin
  Result := TButton.Create(Self);
  Result.Parent := Self;
  Result.Position.Point := PointF(AX, AY);
  Result.Width := AWidth;
  Result.Text := AText;
  Result.OnClick := AOnClick;
end;

procedure THelloForm.FormCreate(Sender: TObject);
var
  I, QuitAfter: Integer;
  Ani: TFloatAnimation;
  S: string;
begin
  // The log (stdout) is UTF-8 whatever the locale of the session.
  SetTextCodePage(Output, CP_UTF8);
  QuitAfter := 0;
  for I := 1 to ParamCount do
  begin
    S := ParamStr(I);
    if S.StartsWith('--quit-after=') then
      QuitAfter := StrToIntDef(S.Substring(Length('--quit-after=')), 0)
    else if S = '--verbose' then
      FVerbose := True
    else if S = '--early-popup' then
    begin
      // The combo box drop-down (an xdg_popup) opened at once, before the window's first configure.
      FVerbose := True;
      FEarlyPopup := TTimer.Create(Self);
      FEarlyPopup.Interval := 1;
      FEarlyPopup.OnTimer := EarlyPopupTimer;
      FEarlyPopup.Enabled := True;
    end
    else if S = '--early-popup=create' then
    begin
      // The drop-down opened in FormCreate, before the window is shown.
      FVerbose := True;
      FEarlyPopupOnCreate := True;
    end
    else if S = '--early-popup=paint' then
    begin
      // The drop-down opened while the window paints its first frame: configured, not mapped yet.
      FVerbose := True;
      FEarlyPopupOnPaint := True;
      OnPaint := FormPaint;
    end
    else if S = '--selftest' then
    begin
      FVerbose := True;
      FSelfTimer := TTimer.Create(Self);
      FSelfTimer.Interval := 600;
      FSelfTimer.OnTimer := SelfTestStep;
      FSelfTimer.Enabled := True;
    end;
  end;

  FTitle := TText.Create(Self);
  FTitle.Parent := Self;
  FTitle.SetBounds(20, 8, 460, 44);
  FTitle.Text := 'Hello, Wayland!';
  FTitle.TextSettings.Font.Size := 30;
  FTitle.TextSettings.Font.Style := [TFontStyle.fsBold];
  FTitle.TextSettings.FontColor := TAlphaColors.Steelblue;
  FTitle.TextSettings.HorzAlign := TTextAlign.Leading;

  FGradient := TRectangle.Create(Self);
  FGradient.Parent := Self;
  FGradient.SetBounds(20, 60, 180, 120);
  FGradient.XRadius := 16;
  FGradient.YRadius := 16;
  FGradient.Fill.Kind := TBrushKind.Gradient;
  FGradient.Fill.Gradient.Color := TAlphaColors.Deepskyblue;
  FGradient.Fill.Gradient.Color1 := TAlphaColors.Mediumpurple;
  FGradient.Stroke.Color := TAlphaColors.Darkslateblue;
  FGradient.Stroke.Thickness := 2;

  FCircle := TCircle.Create(Self);
  FCircle.Parent := Self;
  FCircle.SetBounds(220, 60, 120, 120);
  FCircle.Fill.Color := CComboColors[0];
  FCircle.Stroke.Kind := TBrushKind.None;
  Ani := TFloatAnimation.Create(Self);
  Ani.Parent := FCircle;
  Ani.PropertyName := 'Opacity';
  Ani.StartValue := 1;
  Ani.StopValue := 0.35;
  Ani.Duration := 1.5;
  Ani.AutoReverse := True;
  Ani.Loop := True;
  Ani.Enabled := True;

  FSpinner := TRectangle.Create(Self);
  FSpinner.Parent := Self;
  FSpinner.SetBounds(375, 80, 80, 80);
  FSpinner.Fill.Color := TAlphaColors.Orange;
  FSpinner.Stroke.Color := TAlphaColors.Saddlebrown;
  FSpinner.Stroke.Thickness := 3;
  FSpinner.XRadius := 6;
  FSpinner.YRadius := 6;

  FMouseLabel := AddLabel(480, 70, 210, 'Mouse: (move over the form)');
  FStatusLabel := AddLabel(480, 100, 210, 'Timer: -');

  FClickButton := AddButton(20, 200, 110, 'Click me', ClickButtonClick);
  FCountLabel := AddLabel(145, 203, 300, 'Clicks: 0');

  FEdit := TEdit.Create(Self);
  FEdit.Parent := Self;
  FEdit.SetBounds(20, 245, 300, 26);
  FEdit.TextPrompt := 'Type here';
  FEdit.OnChangeTracking := EditChangeTracking;
  FEdit.OnKeyDown := EditKeyDown;
  FEchoLabel := AddLabel(335, 248, 350, 'Echo: ');

  FCombo := TComboBox.Create(Self);
  FCombo.Parent := Self;
  FCombo.SetBounds(20, 290, 200, 26);
  for S in CComboNames do
    FCombo.Items.Add(S);
  FCombo.ItemIndex := 0;
  FCombo.OnChange := ComboChange;

  FCheck := TCheckBox.Create(Self);
  FCheck.Parent := Self;
  FCheck.SetBounds(240, 292, 160, 22);
  FCheck.Text := 'Spin the square';
  FCheck.IsChecked := True;
  FCheck.OnChange := CheckChange;

  FCopyButton := AddButton(20, 340, 130, 'Copy edit text', CopyButtonClick);
  FPasteButton := AddButton(160, 340, 130, 'Paste', PasteButtonClick);
  FClipLabel := AddLabel(305, 343, 380, 'Clipboard: -');

  FSecondButton := AddButton(20, 390, 130, 'Second form', SecondButtonClick);
  FModalButton := AddButton(160, 390, 130, 'Modal form', ModalButtonClick);
  FMaximizeButton := AddButton(300, 390, 130, 'Maximize', MaximizeButtonClick);
  FResizeButton := AddButton(440, 390, 130, 'Resize 760x560', ResizeButtonClick);
  AddButton(580, 390, 110, 'Message box', MessageButtonClick);

  with AddLabel(20, 440, 660, Format('FMXWayland: FMX on Wayland without libfmux and GTK; %s, wl_shm.',
    [TCanvasManager.DefaultCanvas.ClassName])) do
    TextSettings.FontColor := TAlphaColors.Gray;

  FAnimTimer := TTimer.Create(Self);
  FAnimTimer.Interval := 16;
  FAnimTimer.OnTimer := AnimTimerTimer;
  FAnimTimer.Enabled := True;
  FTickStart := Now;

  with TTimer.Create(Self) do
  begin
    Interval := 1500;
    OnTimer := NativeTimerTimer;
    Enabled := True;
  end;

  if QuitAfter > 0 then
  begin
    FQuitTimer := TTimer.Create(Self);
    FQuitTimer.Interval := QuitAfter * 1000;
    FQuitTimer.OnTimer := QuitTimerTimer;
    FQuitTimer.Enabled := True;
  end;
  OnResize := FormResize;
  OnActivate := FormActivate;
  OnDeactivate := FormDeactivate;
  Log('created');
  Log('canvas ' + TCanvasManager.DefaultCanvas.ClassName);
  LogFonts;
  if FEarlyPopupOnCreate then
  begin
    FCombo.DropDown;
    Log(Format('early popup: drop-down open %s', [BoolToStr(FCombo.DroppedDown, True)]));
  end;
end;

/// The default font of FMX (the platform's IFMXSystemFontService), what a styled label resolves, and the width of a
/// sample text in it on the canvas next to other families: equal widths would mean the canvas did not use it.
procedure THelloForm.LogFonts;
const
  CSample = 'Hello, Wayland! 0123456789';
var
  F: TFont;
  B: TBitmap;
  WDefault, WTahoma, WUbuntu: Single;
begin
  F := TFont.Create;
  try
    Log(Format('font: default "%s" %s', [F.Family, FormatFloat('0.0', F.Size, TFormatSettings.Invariant)]));
  finally
    F.Free;
  end;
  FCountLabel.ApplyStyleLookup;
  Log(Format('font: label "%s" %s', [FCountLabel.ResultingTextSettings.Font.Family,
    FormatFloat('0.0', FCountLabel.ResultingTextSettings.Font.Size, TFormatSettings.Invariant)]));
  B := TBitmap.Create(16, 16);
  try
    WDefault := B.Canvas.TextWidth(CSample);
    B.Canvas.Font.Family := 'Tahoma';
    WTahoma := B.Canvas.TextWidth(CSample);
    B.Canvas.Font.Family := 'Ubuntu';
    WUbuntu := B.Canvas.TextWidth(CSample);
    Log(Format('font: text width default %s, Tahoma %s, Ubuntu %s', [FormatFloat('0.0', WDefault,
      TFormatSettings.Invariant), FormatFloat('0.0', WTahoma, TFormatSettings.Invariant), FormatFloat('0.0', WUbuntu,
      TFormatSettings.Invariant)]));
  finally
    B.Free;
  end;
end;

procedure THelloForm.FormActivate(Sender: TObject);
begin
  Log('form activated');
end;

procedure THelloForm.FormDeactivate(Sender: TObject);
begin
  Log('form deactivated');
end;

procedure THelloForm.FormDestroy(Sender: TObject);
begin
  Log('destroyed');
end;

procedure THelloForm.FormResize(Sender: TObject);
begin
  Log(Format('resize %dx%d state %d', [ClientWidth, ClientHeight, Ord(WindowState)]));
  if FMaximizeButton <> nil then
    if WindowState = TWindowState.wsMaximized then
      FMaximizeButton.Text := 'Restore'
    else
      FMaximizeButton.Text := 'Maximize';
end;

procedure THelloForm.FormMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Single);
begin
  FMouseLabel.Text := Format('Mouse: %.0f, %.0f', [X, Y]);
end;

procedure THelloForm.FormKeyDown(Sender: TObject; var Key: Word; var KeyChar: Char; Shift: TShiftState);
begin
  if KeyChar >= ' ' then
    Log(Format('key down vk=%d char="%s"', [Key, KeyChar]))
  else
    Log(Format('key down vk=%d char=#%d', [Key, Ord(KeyChar)]));
end;

procedure THelloForm.FormMouseWheel(Sender: TObject; Shift: TShiftState; WheelDelta: Integer;
  var Handled: Boolean);
begin
  FSpinner.RotationAngle := FSpinner.RotationAngle + WheelDelta / 12;
  Log(Format('wheel %d', [WheelDelta]));
end;

procedure THelloForm.ClickButtonClick(Sender: TObject);
begin
  Inc(FClicks);
  FCountLabel.Text := Format('Clicks: %d', [FClicks]);
  Log(Format('click %d', [FClicks]));
end;

procedure THelloForm.EditChangeTracking(Sender: TObject);
begin
  FEchoLabel.Text := 'Echo: ' + FEdit.Text;
  Log('edit "' + FEdit.Text + '"');
end;

procedure THelloForm.EditKeyDown(Sender: TObject; var Key: Word; var KeyChar: Char; Shift: TShiftState);
begin
  Log(Format('edit key vk=%d char=#%d ctrl=%s shift=%s', [Key, Ord(KeyChar), BoolToStr(ssCtrl in Shift, True),
    BoolToStr(ssShift in Shift, True)]));
end;

procedure THelloForm.ComboChange(Sender: TObject);
begin
  if FCombo.ItemIndex >= 0 then
  begin
    FCircle.Fill.Color := CComboColors[FCombo.ItemIndex];
    Log('combo ' + FCombo.Items[FCombo.ItemIndex]);
  end;
end;

procedure THelloForm.CheckChange(Sender: TObject);
begin
  Log(Format('check %s', [BoolToStr(FCheck.IsChecked, True)]));
end;

procedure THelloForm.CopyButtonClick(Sender: TObject);
var
  Svc: IFMXClipboardService;
begin
  if TPlatformServices.Current.SupportsPlatformService(IFMXClipboardService, Svc) then
  begin
    Svc.SetClipboard(FEdit.Text);
    FClipLabel.Text := 'Copied: ' + FEdit.Text;
    Log('copied "' + FEdit.Text + '"');
  end;
end;

procedure THelloForm.PasteButtonClick(Sender: TObject);
var
  Svc: IFMXClipboardService;
  V: TValue;
begin
  if TPlatformServices.Current.SupportsPlatformService(IFMXClipboardService, Svc) then
  begin
    V := Svc.GetClipboard;
    if V.IsEmpty then
      FClipLabel.Text := 'Clipboard: (empty)'
    else
      FClipLabel.Text := 'Pasted: ' + V.ToString;
    Log('pasted "' + V.ToString + '"');
  end;
end;

type
  /// A form made in code (no .fmx): CreateNew.
  TSecondForm = class(TForm)
  private
    FOwnerForm: THelloForm;
    procedure CloseButtonClick(Sender: TObject);
    procedure ActivateMainClick(Sender: TObject);
    procedure SecondFormClose(Sender: TObject; var Action: TCloseAction);
  public
    constructor CreateSecond(const AOwnerForm: THelloForm; const ANumber: Integer);
  end;

constructor TSecondForm.CreateSecond(const AOwnerForm: THelloForm; const ANumber: Integer);
var
  L: TLabel;
  B: TButton;
begin
  inherited CreateNew(Application);
  FOwnerForm := AOwnerForm;
  Caption := Format('Second form %d', [ANumber]);
  ClientWidth := 360;
  ClientHeight := 200;
  Fill.Kind := TBrushKind.Solid;
  Fill.Color := TAlphaColors.Honeydew;
  L := TLabel.Create(Self);
  L.Parent := Self;
  L.SetBounds(20, 20, 320, 40);
  L.WordWrap := True;
  L.Text := Format('This is the second form (%d). Close it with the button or the title bar.', [ANumber]);
  B := TButton.Create(Self);
  B.Parent := Self;
  B.SetBounds(20, 80, 120, 30);
  B.Text := 'Close';
  B.OnClick := CloseButtonClick;
  B := TButton.Create(Self);
  B.Parent := Self;
  B.SetBounds(160, 80, 180, 30);
  B.Text := 'Activate main form';
  B.OnClick := ActivateMainClick;
  OnClose := SecondFormClose;
end;

procedure TSecondForm.CloseButtonClick(Sender: TObject);
begin
  Close;
end;

procedure TSecondForm.ActivateMainClick(Sender: TObject);
begin
  // The platform asks the compositor (xdg-activation on Wayland), which decides.
  FOwnerForm.Log('activate main form');
  FOwnerForm.Activate;
end;

procedure TSecondForm.SecondFormClose(Sender: TObject; var Action: TCloseAction);
begin
  Action := TCloseAction.caFree;
  FOwnerForm.Log('second form closed');
end;

procedure THelloForm.SecondButtonClick(Sender: TObject);
begin
  Inc(FSecondCount);
  TSecondForm.CreateSecond(Self, FSecondCount).Show;
  Log('second form shown');
end;

procedure THelloForm.ModalButtonClick(Sender: TObject);
var
  F: TForm;
  L: TLabel;
  OK, Cancel: TButton;
  R: TModalResult;
begin
  F := TForm.CreateNew(nil);
  try
    F.Caption := 'Modal form';
    F.ClientWidth := 320;
    F.ClientHeight := 150;
    F.Position := TFormPosition.MainFormCenter;
    L := TLabel.Create(F);
    L.Parent := F;
    L.SetBounds(20, 20, 280, 30);
    L.Text := 'A modal form: OK or Cancel?';
    OK := TButton.Create(F);
    OK.Parent := F;
    OK.SetBounds(20, 90, 120, 30);
    OK.Text := 'OK';
    OK.ModalResult := mrOk;
    Cancel := TButton.Create(F);
    Cancel.Parent := F;
    Cancel.SetBounds(160, 90, 120, 30);
    Cancel.Text := 'Cancel';
    Cancel.ModalResult := mrCancel;
    Log('modal shown');
    R := F.ShowModal;
    Log(Format('modal result %d', [R]));
    FClipLabel.Text := Format('Modal result: %d', [R]);
  finally
    F.Free;
  end;
end;

procedure THelloForm.MaximizeButtonClick(Sender: TObject);
begin
  if WindowState = TWindowState.wsMaximized then
    WindowState := TWindowState.wsNormal
  else
    WindowState := TWindowState.wsMaximized;
  Log('window state ' + IntToStr(Ord(WindowState)));
end;

procedure THelloForm.MessageButtonClick(Sender: TObject);
var
  R: Integer;
begin
  Log('message shown');
  R := TDialogServiceSync.MessageDialog('Do you like FMX on Wayland?', TMsgDlgType.mtConfirmation,
    [TMsgDlgBtn.mbYes, TMsgDlgBtn.mbNo], TMsgDlgBtn.mbYes, 0);
  Log(Format('message result %d', [R]));
  FClipLabel.Text := Format('Message result: %d', [R]);
end;

procedure THelloForm.ResizeButtonClick(Sender: TObject);
begin
  ClientWidth := 760;
  ClientHeight := 560;
  Log(Format('resized by code to %dx%d', [ClientWidth, ClientHeight]));
end;

procedure THelloForm.AnimTimerTimer(Sender: TObject);
var
  Secs: Double;
begin
  Inc(FTicks);
  if FCheck.IsChecked then
    FSpinner.RotationAngle := FSpinner.RotationAngle + 3;
  Secs := MilliSecondsBetween(Now, FTickStart) / 1000;
  if Secs >= 1 then
  begin
    FStatusLabel.Text := Format('Timer: %.0f ticks/s', [FTicks / Secs]);
    FTicks := 0;
    FTickStart := Now;
  end;
end;

procedure THelloForm.NativeTimerTimer(Sender: TObject);
var
  Svc: IWaylandNativeWindowContract;
  Size: TSize;
begin
  (Sender as TTimer).Enabled := False;
  if TPlatformServices.Current.SupportsPlatformService(IWaylandNativeWindowContract, Svc) then
  begin
    Size := Svc.GetBufferSize(Handle);
    Log(Format('native: display=%p surface=%p buffer=%dx%d scale=%.2f', [Svc.GetWaylandDisplay,
      Svc.GetWaylandSurface(Handle), Size.cx, Size.cy, Svc.GetScale(Handle)]));
  end
  else
    Log('native: no IFMXWaylandNativeWindow service');
end;

procedure THelloForm.SelfTestModalTimer(Sender: TObject);
begin
  // Runs inside the modal loop of ShowModal: timers keep working there.
  (Sender as TTimer).Enabled := False;
  TForm(TComponent(Sender).Owner).ModalResult := mrRetry;
end;

procedure THelloForm.SelfTestMessageTimer(Sender: TObject);
var
  I: Integer;
begin
  // Runs inside the modal loop of the message box (FMX's dialog form): answers No.
  (Sender as TTimer).Enabled := False;
  for I := Screen.FormCount - 1 downto 0 do
    if (Screen.Forms[I] <> Self) and Screen.Forms[I].Visible then
    begin
      Screen.Forms[I].ModalResult := mrNo;
      Exit;
    end;
end;

/// --selftest: steps without user input (threads, clipboard, popup, second form, maximize, modal loop, message box);
/// each step writes "selftest: ..." to the log; tests\weston-headless.ps1 checks them.
procedure THelloForm.SelfTestStep(Sender: TObject);
var
  Svc: IFMXClipboardService;
  V: TValue;
  F: TForm;
  T: TTimer;
  R: TModalResult;
begin
  Inc(FSelfStep);
  case FSelfStep of
    1:
      TThread.CreateAnonymousThread(
        procedure
        begin
          TThread.Synchronize(nil,
            procedure
            begin
              Log(Format('selftest: synchronize from a thread, on the main thread %s',
                [BoolToStr(TThread.Current.ThreadID = MainThreadID, True)]));
            end);
          TThread.Queue(nil,
            procedure
            begin
              Log(Format('selftest: queue from a thread, on the main thread %s',
                [BoolToStr(TThread.Current.ThreadID = MainThreadID, True)]));
            end);
        end).Start;
    2:
      if TPlatformServices.Current.SupportsPlatformService(IFMXClipboardService, Svc) then
      begin
        Svc.SetClipboard('selftest clipboard ' + #$2713);
        V := Svc.GetClipboard;
        Log('selftest: clipboard "' + V.ToString + '"');
      end;
    3:
      begin
        FCombo.DropDown;
        Log(Format('selftest: drop-down open %s', [BoolToStr(FCombo.DroppedDown, True)]));
      end;
    7:
      begin
        FCombo.DropDown;
        Log(Format('selftest: drop-down closed %s', [BoolToStr(not FCombo.DroppedDown, True)]));
      end;
    8:
      begin
        Inc(FSecondCount);
        FSelfSecond := TForm.CreateNew(Application);
        FSelfSecond.Caption := 'Self-test second form';
        FSelfSecond.ClientWidth := 300;
        FSelfSecond.ClientHeight := 120;
        FSelfSecond.Show;
        Log('selftest: second form shown');
      end;
    9:
      begin
        FSelfSecond.Free;
        FSelfSecond := nil;
        Log('selftest: second form freed');
      end;
    10:
      WindowState := TWindowState.wsMaximized;
    11:
      begin
        Log(Format('selftest: maximized %s %dx%d', [BoolToStr(WindowState = TWindowState.wsMaximized, True),
          ClientWidth, ClientHeight]));
        WindowState := TWindowState.wsNormal;
      end;
    12:
      Log(Format('selftest: restored %dx%d', [ClientWidth, ClientHeight]));
    13:
      begin
        FSelfTimer.Enabled := False;
        F := TForm.CreateNew(nil);
        try
          F.Caption := 'Self-test modal form';
          F.ClientWidth := 260;
          F.ClientHeight := 100;
          T := TTimer.Create(F);
          T.Interval := 700;
          T.OnTimer := SelfTestModalTimer;
          T.Enabled := True;
          R := F.ShowModal;
          Log(Format('selftest: modal result %d', [R]));
        finally
          F.Free;
        end;
        FSelfTimer.Enabled := True;
      end;
    14:
      begin
        FSelfTimer.Enabled := False;
        T := TTimer.Create(Self);
        try
          T.Interval := 700;
          T.OnTimer := SelfTestMessageTimer;
          T.Enabled := True;
          R := TDialogServiceSync.MessageDialog('Self-test message box', TMsgDlgType.mtConfirmation,
            [TMsgDlgBtn.mbYes, TMsgDlgBtn.mbNo], TMsgDlgBtn.mbYes, 0);
          Log(Format('selftest: message result %d', [R]));
        finally
          T.Free;
        end;
        FSelfTimer.Enabled := True;
      end;
    15:
      begin
        FSelfTimer.Enabled := False;
        Log('selftest: done');
        Close;
      end;
  end;
end;

procedure THelloForm.EarlyPopupTimer(Sender: TObject);
begin
  FEarlyPopup.Enabled := False;
  FCombo.DropDown;
  Log(Format('early popup: drop-down open %s', [BoolToStr(FCombo.DroppedDown, True)]));
end;

procedure THelloForm.FormPaint(Sender: TObject; Canvas: TCanvas; const ARect: TRectF);
begin
  if not FEarlyPopupOnPaint then
    Exit;
  FEarlyPopupOnPaint := False;
  FCombo.DropDown;
  Log(Format('early popup: drop-down open %s', [BoolToStr(FCombo.DroppedDown, True)]));
end;

procedure THelloForm.QuitTimerTimer(Sender: TObject);
begin
  FQuitTimer.Enabled := False;
  Log('quit timer: closing');
  Close;
end;

end.
