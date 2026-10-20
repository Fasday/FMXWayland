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
    FDialogDir: string;
    FDialogLabel: TLabel;
    FDialogOpen: Boolean;
    FFolderDialogSince: TDateTime;
    FQuitInFolderDialog: Integer;
    FSelfDir: string;
    FSelfTries: Integer;
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
    procedure SelfTestDialogs;
    procedure SelfTestDialogTimer(Sender: TObject);
    procedure SelfTestConfirmTimer(Sender: TObject);
    function StartSelfTestTimer(const AHandler: TNotifyEvent): TTimer;
    procedure OpenButtonClick(Sender: TObject);
    procedure SaveButtonClick(Sender: TObject);
    procedure FolderButtonClick(Sender: TObject);
    procedure ShowDialogResult(const AKind: string; const AResult: Boolean; const AFiles: string;
      const AFilterIndex: Integer);
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
    procedure AppException(Sender: TObject; E: Exception);
  end;

var
  HelloForm: THelloForm;
  /// <summary>Set by Hello.dpr with another canvas than FMX's (FastCanvas, -Define FASTCANVAS): a line about it for
  /// the log.</summary>
  HelloCanvasInfo: TFunc<string>;
  /// <summary>Likewise: writes the frame the canvas presented last in the form's window to a file (the frame dump
  /// when FMXWayland has none: FMXWAYLAND_DUMP_DIR), and returns a line for the log.</summary>
  HelloSaveFrame: TFunc<TCommonCustomForm, string, string>;
  /// <summary>How the frames reach the compositor, for the form's text.</summary>
  HelloPresentation: string = 'wl_shm';

implementation

{$R *.fmx}

uses
{$IFDEF LINUX}
  FMUX.Api,
{$ENDIF}
  System.UIConsts, System.DateUtils, System.IOUtils, FMX.Platform, FMX.DialogService.Sync, FMX.Dialogs;

function BackendName: string;
begin
{$IFDEF LINUX}
  if Assigned(FMUX.Api.IsWayland) and FMUX.Api.IsWayland() then
    Result := 'Wayland'
  else
    Result := 'X11';
{$ELSE}
  Result := 'FMX';
{$ENDIF}
end;

function PresentationName: string;
begin
  Result := HelloPresentation;
  if (Result = 'wl_shm') and (BackendName = 'X11') then
    Result := 'XPutImage';
end;

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
    else if S.StartsWith('--dialog-dir=') then
      FDialogDir := S.Substring(Length('--dialog-dir='))
    else if S.StartsWith('--quit-in-folder-dialog=') then
      FQuitInFolderDialog := StrToIntDef(S.Substring(Length('--quit-in-folder-dialog=')), 0)
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
  FTitle.Text := 'Hello, ' + BackendName + '!';
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

  with AddLabel(20, 440, 660, Format('FMXWayland: FMX on %s without libfmux and GTK; %s, %s.',
    [BackendName, TCanvasManager.DefaultCanvas.ClassName, PresentationName])) do
    TextSettings.FontColor := TAlphaColors.Gray;

  // File dialogs: the portal's when there is one, FMX's own otherwise.
  AddButton(20, 470, 110, 'Open file...', OpenButtonClick);
  AddButton(140, 470, 110, 'Save file...', SaveButtonClick);
  AddButton(260, 470, 120, 'Select folder...', FolderButtonClick);
  FDialogLabel := AddLabel(395, 473, 295, 'Dialog: -');
  if FDialogDir = '' then
    FDialogDir := GetEnvironmentVariable('HOME');

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
  Application.OnException := AppException;
  Log('created');
  Log('backend: ' + BackendName + '; presentation: ' + PresentationName);
  Log('canvas ' + TCanvasManager.DefaultCanvas.ClassName);
  if Assigned(HelloCanvasInfo) then
    Log('canvas info: ' + HelloCanvasInfo());
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

procedure THelloForm.AppException(Sender: TObject; E: Exception);
begin
  // In the log (tests: no exception may pass unnoticed), then FMX's message box as without a handler.
  Log(Format('exception %s: %s (at %p)', [E.ClassName, E.Message, ExceptAddr]));
  Application.ShowException(E);
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
  R := TDialogServiceSync.MessageDialog('Do you like FMX on ' + BackendName + '?', TMsgDlgType.mtConfirmation,
    [TMsgDlgBtn.mbYes, TMsgDlgBtn.mbNo], TMsgDlgBtn.mbYes, 0);
  Log(Format('message result %d', [R]));
  FClipLabel.Text := Format('Message result: %d', [R]);
end;

procedure THelloForm.ShowDialogResult(const AKind: string; const AResult: Boolean; const AFiles: string;
  const AFilterIndex: Integer);
begin
  Log(Format('%s dialog result %s files "%s" filter %d', [AKind, BoolToStr(AResult, True), AFiles, AFilterIndex]));
  if AResult then
    FDialogLabel.Text := AKind + ': ' + AFiles
  else
    FDialogLabel.Text := AKind + ': cancelled';
end;

procedure THelloForm.OpenButtonClick(Sender: TObject);
var
  D: TOpenDialog;
  R: Boolean;
begin
  D := TOpenDialog.Create(nil);
  try
    D.Title := 'Hello: open a file';
    D.InitialDir := FDialogDir;
    D.Filter := 'Text files (*.txt)|*.txt|All files (*.*)|*.*';
    D.FilterIndex := 1;
    Log('open dialog shown');
    FDialogOpen := True;
    try
      R := D.Execute;
    finally
      FDialogOpen := False;
    end;
    ShowDialogResult('open', R, D.Files.CommaText, D.FilterIndex);
  finally
    D.Free;
  end;
end;

procedure THelloForm.SaveButtonClick(Sender: TObject);
var
  D: TSaveDialog;
  R: Boolean;
begin
  D := TSaveDialog.Create(nil);
  try
    D.Title := 'Hello: save a file';
    D.InitialDir := FDialogDir;
    D.FileName := 'hello.txt';
    D.Filter := 'Text files (*.txt)|*.txt|All files (*.*)|*.*';
    D.Options := D.Options + [TOpenOption.ofOverwritePrompt];
    Log('save dialog shown');
    FDialogOpen := True;
    try
      R := D.Execute;
    finally
      FDialogOpen := False;
    end;
    ShowDialogResult('save', R, D.FileName, D.FilterIndex);
  finally
    D.Free;
  end;
end;

procedure THelloForm.FolderButtonClick(Sender: TObject);
var
  Dir: string;
  R: Boolean;
begin
  Log('folder dialog shown');
  FDialogOpen := True;
  FFolderDialogSince := Now;
  try
    R := SelectDirectory('Hello: select a folder', FDialogDir, Dir);
  finally
    FDialogOpen := False;
    FFolderDialogSince := 0;
  end;
  ShowDialogResult('folder', R, Dir, 0);
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
    // The loop must go on while another program's (a portal's) file dialog is open.
    if FDialogOpen then
      Log(Format('timer during the dialog: %.0f ticks/s', [FTicks / Secs]));
    // Tests: the program ends while a folder dialog is open (the dialog must be closed with it).
    if (FQuitInFolderDialog > 0) and (FFolderDialogSince <> 0) and
      (SecondsBetween(Now, FFolderDialogSince) >= FQuitInFolderDialog) then
    begin
      FFolderDialogSince := 0;
      Log('closing during the folder dialog');
      Close;
    end;
    FTicks := 0;
    FTickStart := Now;
  end;
end;

procedure THelloForm.NativeTimerTimer(Sender: TObject);
var
  Svc: IWaylandNativeWindowContract;
  Size: TSize;
  Dir: string;
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
  // A canvas that presents the window itself: FMXWayland has no frame of it to dump, the canvas has.
  Dir := GetEnvironmentVariable('FMXWAYLAND_DUMP_DIR');
  if Assigned(HelloSaveFrame) and (Dir <> '') then
    try
      Log('canvas frame: ' + HelloSaveFrame(Self, TPath.Combine(Dir, 'FMXWaylandHello-canvas.bmp')));
    except
      on E: Exception do
        Log('canvas frame: ' + E.Message);
    end;
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

function THelloForm.StartSelfTestTimer(const AHandler: TNotifyEvent): TTimer;
begin
  Result := TTimer.Create(Self);
  Result.Interval := 700;
  Result.OnTimer := AHandler;
  Result.Enabled := True;
end;

/// The visible file dialog form of FMXWayland (by its class name: the sample does not use FMXWayland's units).
function FindFileDialog: TCommonCustomForm;
var
  I: Integer;
begin
  for I := 0 to Screen.FormCount - 1 do
    if Screen.Forms[I].Visible and (Screen.Forms[I].ClassName = 'TFMXWaylandFileDialog') then
      Exit(Screen.Forms[I]);
  Result := nil;
end;

/// The names of AFiles, comma separated, and whether all of them are in ADir.
function DescribeFiles(const AFiles: TStrings; const ADir: string): string;
var
  S: string;
  InDir: Boolean;
begin
  Result := '';
  InDir := AFiles.Count > 0;
  for S in AFiles do
  begin
    if Result <> '' then
      Result := Result + ',';
    Result := Result + TPath.GetFileName(S);
    InDir := InDir and (TPath.GetDirectoryName(S) = ADir);
  end;
  Result := Result + ' in the folder ' + BoolToStr(InDir, True);
end;

procedure THelloForm.SelfTestDialogs;
const
  CFiles: array[0..3] of string = ('alpha.txt', 'beta.txt', 'gamma.log', '.hidden.txt');
var
  Open: TOpenDialog;
  Save: TSaveDialog;
  Files: TStringList;
  Dir: string;
  R: Boolean;
begin
  FSelfTries := 0;
  case FSelfStep of
    15:
      begin
        // A folder of known files: the dialog must list sub/, alpha.txt, beta.txt (not gamma.log, not hidden).
        FSelfDir := TPath.Combine(TPath.GetTempPath, Format('fmxw-selftest-%d', [MainThreadID]));
        TDirectory.CreateDirectory(TPath.Combine(FSelfDir, 'sub'));
        for Dir in CFiles do
          TFile.WriteAllText(TPath.Combine(FSelfDir, Dir), Dir);
        Open := TOpenDialog.Create(nil);
        try
          Open.Title := 'Self-test open';
          Open.InitialDir := FSelfDir;
          Open.Filter := 'Text files (*.txt)|*.txt|Logs|*.log';
          Open.FilterIndex := 1;
          Open.Options := Open.Options + [TOpenOption.ofAllowMultiSelect];
          StartSelfTestTimer(SelfTestDialogTimer);
          R := Open.Execute;
          Log(Format('selftest: open result %s %s filter %d', [BoolToStr(R, True), DescribeFiles(Open.Files,
            FSelfDir), Open.FilterIndex]));
        finally
          Open.Free;
        end;
      end;
    16:
      begin
        Save := TSaveDialog.Create(nil);
        Files := TStringList.Create;
        try
          Save.Title := 'Self-test save';
          Save.InitialDir := FSelfDir;
          Save.FileName := 'new.txt';
          Save.Filter := 'Text files (*.txt)|*.txt|All files|*';
          Save.Options := Save.Options + [TOpenOption.ofOverwritePrompt];
          StartSelfTestTimer(SelfTestDialogTimer);
          R := Save.Execute;
          if R then
            Files.Add(Save.FileName);
          Log(Format('selftest: save result %s %s filter %d', [BoolToStr(R, True), DescribeFiles(Files, FSelfDir),
            Save.FilterIndex]));
        finally
          Files.Free;
          Save.Free;
        end;
      end;
    17:
      begin
        StartSelfTestTimer(SelfTestDialogTimer);
        R := SelectDirectory('Self-test folder', FSelfDir, Dir);
        Log(Format('selftest: folder result %s %s in the folder %s', [BoolToStr(R, True), TPath.GetFileName(Dir),
          BoolToStr(TPath.GetDirectoryName(Dir) = FSelfDir, True)]));
      end;
    18:
      begin
        Open := TOpenDialog.Create(nil);
        try
          Open.Title := 'Self-test cancel';
          Open.InitialDir := FSelfDir;
          StartSelfTestTimer(SelfTestDialogTimer);
          R := Open.Execute;
          Log(Format('selftest: cancelled dialog result %s, %d files', [BoolToStr(R, True), Open.Files.Count]));
        finally
          Open.Free;
        end;
      end;
  end;
end;

procedure THelloForm.SelfTestDialogTimer(Sender: TObject);
var
  F: TCommonCustomForm;
  List: TListBox;
  Accept: TButton;
  Names: string;
  I: Integer;
begin
  // Runs inside the modal loop of the file dialog (FMX's own: the self-test runs without a portal).
  F := FindFileDialog;
  if F = nil then
  begin
    Inc(FSelfTries);
    if FSelfTries >= 15 then
    begin
      (Sender as TTimer).Enabled := False;
      Log('selftest: no FMX file dialog appeared');
    end;
    Exit;
  end;
  (Sender as TTimer).Enabled := False;
  List := F.FindComponent('FileList') as TListBox;
  Accept := F.FindComponent('AcceptButton') as TButton;
  Names := '';
  for I := 0 to List.Count - 1 do
  begin
    if Names <> '' then
      Names := Names + ',';
    Names := Names + List.ListItems[I].Text;
  end;
  Log(Format('selftest: file dialog "%s" lists %s', [F.Caption, Names]));
  case FSelfStep of
    15:
      begin
        // Two files of a multiple selection.
        for I := 0 to List.Count - 1 do
          List.ListItems[I].IsSelected := (List.ListItems[I].Text = 'alpha.txt') or
            (List.ListItems[I].Text = 'beta.txt');
        Accept.OnClick(Accept);
      end;
    16:
      begin
        // Another filter, and a name that exists: the question to replace it is answered by another timer.
        (F.FindComponent('FilterCombo') as TComboBox).ItemIndex := 1;
        (F.FindComponent('NameEdit') as TEdit).Text := 'beta.txt';
        StartSelfTestTimer(SelfTestConfirmTimer);
        Accept.OnClick(Accept);
      end;
    17:
      begin
        for I := 0 to List.Count - 1 do
          if List.ListItems[I].Text = 'sub/' then
            List.ItemIndex := I;
        Accept.OnClick(Accept);
      end;
  else
    F.ModalResult := mrCancel;
  end;
end;

procedure THelloForm.SelfTestConfirmTimer(Sender: TObject);
var
  I: Integer;
begin
  // Runs inside the modal loop of the question whether to replace the file: answers Yes.
  (Sender as TTimer).Enabled := False;
  for I := Screen.FormCount - 1 downto 0 do
    if (Screen.Forms[I] <> Self) and Screen.Forms[I].Visible and
      (Screen.Forms[I].ClassName <> 'TFMXWaylandFileDialog') then
    begin
      Log('selftest: overwrite question answered Yes');
      Screen.Forms[I].ModalResult := mrYes;
      Exit;
    end;
end;

/// --selftest: steps without user input (threads, clipboard, popup, second form, maximize, modal loop, message box,
/// file dialogs); each step writes "selftest: ..." to the log; tests\weston-headless.ps1 checks them.
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
        // Hidden and shown again: the window is unmapped and mapped again (a canvas that presents itself stops and
        // starts again).
        FSelfSecond.Hide;
        FSelfSecond.Show;
        Log('selftest: second form hidden and shown again');
      end;
    10:
      begin
        Log(Format('selftest: second form visible %s', [BoolToStr(FSelfSecond.Visible, True)]));
        FSelfSecond.Free;
        FSelfSecond := nil;
        Log('selftest: second form freed');
        WindowState := TWindowState.wsMaximized;
      end;
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
    15..18:
      begin
        FSelfTimer.Enabled := False;
        SelfTestDialogs;
        FSelfTimer.Enabled := True;
      end;
    19:
      begin
        FSelfTimer.Enabled := False;
        if FSelfDir <> '' then
          TDirectory.Delete(FSelfDir, True);
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
  // FMX frees a form's children after its handle: a combo box whose drop-down is still open then asks the gone
  // window for its client size (TCustomForm.DoRemoveObject), an access violation on Linux. The title
  // bar's close button closes the popups first (FmuxClose); this timer has to do it itself.
  if FCombo.DroppedDown then
    FCombo.DropDown;
  Close;
end;

end.
