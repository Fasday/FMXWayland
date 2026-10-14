unit HelloTitleBar;

{ Hello --own-titlebar: a form that draws its own title bar, as FMR Ribbon does, through FMXWayland's
  IFMXWaylandWindowFrame service. The service is declared here again (same GUIDs, same methods) the way a library
  that does not depend on FMXWayland declares it. The platform's decorations are off; the blue caption moves the
  window (press and drag), maximizes or restores it (double click) and shows the compositor's window menu (right
  click); its buttons minimize, maximize/restore and close; thin grips at the edges resize the window. The states the
  compositor reports (activated, maximized, tiled, ...) show in a label and in the log. With --selftest it runs steps
  without input (tests\compositors.sh). }

interface

uses
  System.SysUtils, System.Types, System.UITypes, System.Classes, FMX.Types, FMX.Controls, FMX.Forms, FMX.Graphics,
  FMX.Objects, FMX.StdCtrls, FMX.ListBox, FMX.Layouts, FMX.Controls.Presentation;

const
  { Edges of IFMXWaylandWindowFrame.BeginResize: the values of xdg_toplevel.resize_edge. }
  FmxwEdgeNone = 0;
  FmxwEdgeTop = 1;
  FmxwEdgeBottom = 2;
  FmxwEdgeLeft = 4;
  FmxwEdgeTopLeft = 5;
  FmxwEdgeBottomLeft = 6;
  FmxwEdgeRight = 8;
  FmxwEdgeTopRight = 9;
  FmxwEdgeBottomRight = 10;

  { Bits of IFMXWaylandWindowFrame.GetStates: 1 shl <xdg_toplevel.state> of the last configure. }
  FmxwStateMaximized = 1 shl 1;
  FmxwStateFullscreen = 1 shl 2;
  FmxwStateResizing = 1 shl 3;
  FmxwStateActivated = 1 shl 4;
  FmxwStateTiledLeft = 1 shl 5;
  FmxwStateTiledRight = 1 shl 6;
  FmxwStateTiledTop = 1 shl 7;
  FmxwStateTiledBottom = 1 shl 8;
  FmxwStateSuspended = 1 shl 9;
  FmxwStateTiled = FmxwStateTiledLeft or FmxwStateTiledRight or FmxwStateTiledTop or FmxwStateTiledBottom;

  { Bits of IFMXWaylandWindowFrame.GetCapabilities: 1 shl <xdg_toplevel.wm_capabilities>; FmxwCapsUnknown when the
    compositor does not send them (xdg_wm_base before version 5: everything may work). }
  FmxwCapWindowMenu = 1 shl 1;
  FmxwCapMaximize = 1 shl 2;
  FmxwCapFullscreen = 1 shl 3;
  FmxwCapMinimize = 1 shl 4;
  FmxwCapsUnknown = Cardinal($FFFFFFFF);

type
  /// <summary>The contract of FMXWayland.Frame.IFMXWaylandWindowFrameListener, declared again.</summary>
  IFMXWaylandWindowFrameListener = interface
    ['{785C5760-E413-4153-82DF-E857D1AA70AC}']
    procedure WindowFrameChanged(const AHandle: TWindowHandle; const AStates, ACapabilities: Cardinal);
  end;

  /// <summary>The contract of FMXWayland.Frame.IFMXWaylandWindowFrame, declared again.</summary>
  IFMXWaylandWindowFrame = interface
    ['{547B5786-5639-43A4-A598-1A03B465783A}']
    procedure SetDecorated(const AHandle: TWindowHandle; const AValue: Boolean);
    function GetDecorated(const AHandle: TWindowHandle): Boolean;
    function BeginMove(const AHandle: TWindowHandle): Boolean;
    function BeginResize(const AHandle: TWindowHandle; const AEdges: Cardinal): Boolean;
    function ShowWindowMenu(const AHandle: TWindowHandle; const AClientPoint: TPointF): Boolean;
    procedure Minimize(const AHandle: TWindowHandle);
    procedure SetMaximized(const AHandle: TWindowHandle; const AValue: Boolean);
    function GetStates(const AHandle: TWindowHandle): Cardinal;
    function GetCapabilities(const AHandle: TWindowHandle): Cardinal;
    procedure SetFrameListener(const AHandle: TWindowHandle; const AListener: IFMXWaylandWindowFrameListener);
  end;

  /// <summary>The form of --own-titlebar (made in code).</summary>
  TTitleBarForm = class(TForm)
  private
    FFrame: IFMXWaylandWindowFrame;
    FListener: IFMXWaylandWindowFrameListener;
    FStates: Cardinal;
    FCaps: Cardinal;
    FCaption: TRectangle;
    FTitle: TLabel;
    FCloseButton: TRectangle;
    FMaxButton: TRectangle;
    FMinButton: TRectangle;
    FMaxGlyph: TPath;
    FStateLabel: TLabel;
    FSizeLabel: TLabel;
    FCombo: TComboBox;
    FBorder: TRectangle;
    FGrips: array[0..7] of TLayout;
    FOtherCount: Integer;
    FSelfTimer: TTimer;
    FSelfStep: Integer;
    FQuitTimer: TTimer;
    procedure Log(const AText: string);
    function AddButton(const AGlyph: string; const AOnClick: TNotifyEvent; out APath: TPath): TRectangle;
    procedure ButtonEnter(Sender: TObject);
    procedure ButtonLeave(Sender: TObject);
    procedure CaptionMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Single);
    procedure GripMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Single);
    procedure MinimizeClick(Sender: TObject);
    procedure MaximizeClick(Sender: TObject);
    procedure CloseClick(Sender: TObject);
    procedure OtherClick(Sender: TObject);
    procedure ComboChange(Sender: TObject);
    procedure FormResized(Sender: TObject);
    procedure FormActivated(Sender: TObject);
    procedure FormDeactivated(Sender: TObject);
    procedure FormDestroyed(Sender: TObject);
    procedure QuitTimerTimer(Sender: TObject);
    procedure PlaceGrips;
    procedure SelfTestStep(Sender: TObject);
    function SizeText: string;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    /// <summary>From the platform (the listener): new states or capabilities.</summary>
    procedure WindowFrameChanged(const AStates, ACapabilities: Cardinal);
  end;

/// <summary>True when the command line asks for the form with its own title bar (--own-titlebar).</summary>
function OwnTitleBarRequested: Boolean;
/// <summary>"maximized activated ..." for FmxwState* bits.</summary>
function StatesText(const AStates: Cardinal): string;
/// <summary>"window_menu maximize ..." for FmxwCap* bits ("unknown" for FmxwCapsUnknown).</summary>
function CapsText(const ACaps: Cardinal): string;

implementation

uses
  FMX.Platform;

const
  CCaptionHeight = 36;
  CButtonWidth = 46;
  CGripThickness = 5;
  CGripCorner = 14;
  CCaptionActive = $FF2B579A;
  CCaptionInactive = $FF8AA2C8;

type
  TTitleBarListener = class(TInterfacedObject, IFMXWaylandWindowFrameListener)
  private
    [Unsafe] FForm: TTitleBarForm;
  public
    procedure WindowFrameChanged(const AHandle: TWindowHandle; const AStates, ACapabilities: Cardinal);
  end;

function OwnTitleBarRequested: Boolean;
var
  I: Integer;
begin
  for I := 1 to ParamCount do
    if ParamStr(I) = '--own-titlebar' then
      Exit(True);
  Result := False;
end;

function StatesText(const AStates: Cardinal): string;
const
  CNames: array[1..9] of string = ('maximized', 'fullscreen', 'resizing', 'activated', 'tiled_left', 'tiled_right',
    'tiled_top', 'tiled_bottom', 'suspended');
var
  I: Integer;
begin
  Result := '';
  for I := Low(CNames) to High(CNames) do
    if AStates and (Cardinal(1) shl I) <> 0 then
      Result := Result + ' ' + CNames[I];
  Result := Result.Trim;
  if Result = '' then
    Result := '-';
end;

function CapsText(const ACaps: Cardinal): string;
const
  CNames: array[1..4] of string = ('window_menu', 'maximize', 'fullscreen', 'minimize');
var
  I: Integer;
begin
  if ACaps = FmxwCapsUnknown then
    Exit('unknown');
  Result := '';
  for I := Low(CNames) to High(CNames) do
    if ACaps and (Cardinal(1) shl I) <> 0 then
      Result := Result + ' ' + CNames[I];
  Result := Result.Trim;
  if Result = '' then
    Result := '-';
end;

{ TTitleBarListener }

procedure TTitleBarListener.WindowFrameChanged(const AHandle: TWindowHandle; const AStates, ACapabilities: Cardinal);
begin
  if (FForm <> nil) and (AHandle = FForm.Handle) then
    FForm.WindowFrameChanged(AStates, ACapabilities);
end;

{ TTitleBarForm }

constructor TTitleBarForm.Create(AOwner: TComponent);
const
  CEdges: array[0..7] of Cardinal = (FmxwEdgeTop, FmxwEdgeBottom, FmxwEdgeLeft, FmxwEdgeRight, FmxwEdgeTopLeft,
    FmxwEdgeTopRight, FmxwEdgeBottomLeft, FmxwEdgeBottomRight);
  CColors: array[0..4] of string = ('Red', 'Green', 'Blue', 'Yellow', 'Purple');
var
  I, QuitAfter: Integer;
  S: string;
  L: TLabel;
  B: TButton;
  Listener: TTitleBarListener;
  Glyph: TPath;
begin
  // A form without an .fmx file.
  inherited CreateNew(AOwner);
  SetTextCodePage(Output, CP_UTF8);
  Caption := 'FMXWayland own title bar';
  Fill.Kind := TBrushKind.Solid;
  Fill.Color := $FFF7F7F7;
  FStates := 0;
  FCaps := FmxwCapsUnknown;

  FCaption := TRectangle.Create(Self);
  FCaption.Parent := Self;
  FCaption.Align := TAlignLayout.Top;
  FCaption.Height := CCaptionHeight;
  FCaption.Fill.Color := CCaptionActive;
  FCaption.Stroke.Kind := TBrushKind.None;
  FCaption.HitTest := True;
  FCaption.OnMouseDown := CaptionMouseDown;
  // Align Right: the first one is the rightmost.
  FCloseButton := AddButton('M0,0 L10,10 M10,0 L0,10', CloseClick, Glyph);
  FMaxButton := AddButton('M0,0 L10,0 L10,10 L0,10 Z', MaximizeClick, FMaxGlyph);
  FMinButton := AddButton('M0,6 L10,6', MinimizeClick, Glyph);
  // A line alone has no height to stretch: drawn as it is, in the middle of the 10 x 10 box.
  Glyph.WrapMode := TPathWrapMode.Original;
  FTitle := TLabel.Create(Self);
  FTitle.Parent := FCaption;
  FTitle.Align := TAlignLayout.Client;
  FTitle.Margins.Left := 14;
  FTitle.HitTest := False;
  FTitle.StyledSettings := FTitle.StyledSettings - [TStyledSetting.FontColor, TStyledSetting.Style];
  FTitle.TextSettings.FontColor := TAlphaColors.White;
  FTitle.TextSettings.Font.Style := [TFontStyle.fsBold];
  FTitle.Text := 'FMXWayland: a title bar drawn by the program';

  L := TLabel.Create(Self);
  L.Parent := Self;
  L.SetBounds(16, 50, 600, 40);
  L.WordWrap := True;
  L.Text := 'Drag the blue bar to move the window, double-click it to maximize, right-click it for the window ' +
    'menu; drag the edges to resize.';
  FStateLabel := TLabel.Create(Self);
  FStateLabel.Parent := Self;
  FStateLabel.SetBounds(16, 96, 600, 20);
  FSizeLabel := TLabel.Create(Self);
  FSizeLabel.Parent := Self;
  FSizeLabel.SetBounds(16, 120, 600, 20);
  FCombo := TComboBox.Create(Self);
  FCombo.Parent := Self;
  FCombo.SetBounds(16, 156, 200, 26);
  for S in CColors do
    FCombo.Items.Add(S);
  FCombo.ItemIndex := 0;
  FCombo.OnChange := ComboChange;
  B := TButton.Create(Self);
  B.Parent := Self;
  B.SetBounds(236, 156, 140, 26);
  B.Text := 'Other window';
  B.OnClick := OtherClick;

  FBorder := TRectangle.Create(Self);
  FBorder.Parent := Self;
  FBorder.Align := TAlignLayout.Contents;
  FBorder.Fill.Kind := TBrushKind.None;
  FBorder.Stroke.Color := CCaptionActive;
  FBorder.HitTest := False;
  for I := 0 to High(FGrips) do
  begin
    FGrips[I] := TLayout.Create(Self);
    FGrips[I].Parent := Self;
    FGrips[I].Tag := CEdges[I];
    FGrips[I].HitTest := True;
    FGrips[I].OnMouseDown := GripMouseDown;
    case CEdges[I] of
      FmxwEdgeTop, FmxwEdgeBottom:
        FGrips[I].Cursor := crSizeNS;
      FmxwEdgeLeft, FmxwEdgeRight:
        FGrips[I].Cursor := crSizeWE;
      FmxwEdgeTopLeft, FmxwEdgeBottomRight:
        FGrips[I].Cursor := crSizeNWSE;
    else
      FGrips[I].Cursor := crSizeNESW;
    end;
  end;

  OnResize := FormResized;
  OnActivate := FormActivated;
  OnDeactivate := FormDeactivated;
  OnDestroy := FormDestroyed;
  if TPlatformServices.Current.SupportsPlatformService(IFMXWaylandWindowFrame, FFrame) then
  begin
    Log('frame: service found');
    Listener := TTitleBarListener.Create;
    Listener.FForm := Self;
    FListener := Listener;
    // The listener is called once at once.
    FFrame.SetFrameListener(Handle, FListener);
    FFrame.SetDecorated(Handle, False);
    Log(Format('frame: decorated %s', [BoolToStr(FFrame.GetDecorated(Handle), True)]));
  end
  else
    Log('frame: no IFMXWaylandWindowFrame service');
  // The client size after the decorations are off.
  ClientWidth := 640;
  ClientHeight := 420;
  PlaceGrips;

  QuitAfter := 0;
  for I := 1 to ParamCount do
  begin
    S := ParamStr(I);
    if S.StartsWith('--quit-after=') then
      QuitAfter := StrToIntDef(S.Substring(Length('--quit-after=')), 0)
    else if S = '--selftest' then
    begin
      FSelfTimer := TTimer.Create(Self);
      FSelfTimer.Interval := 700;
      FSelfTimer.OnTimer := SelfTestStep;
      FSelfTimer.Enabled := True;
    end;
  end;
  if QuitAfter > 0 then
  begin
    FQuitTimer := TTimer.Create(Self);
    FQuitTimer.Interval := QuitAfter * 1000;
    FQuitTimer.OnTimer := QuitTimerTimer;
    FQuitTimer.Enabled := True;
  end;
  Log('created ' + SizeText);
end;

destructor TTitleBarForm.Destroy;
begin
  if FListener <> nil then
    TTitleBarListener(FListener).FForm := nil;
  if (FFrame <> nil) and (Handle <> nil) then
    FFrame.SetFrameListener(Handle, nil);
  FListener := nil;
  FFrame := nil;
  inherited;
end;

procedure TTitleBarForm.Log(const AText: string);
begin
  Writeln('[hello] ', AText);
  Flush(Output);
end;

function TTitleBarForm.SizeText: string;
begin
  Result := Format('%dx%d', [ClientWidth, ClientHeight]);
end;

function TTitleBarForm.AddButton(const AGlyph: string; const AOnClick: TNotifyEvent; out APath: TPath): TRectangle;
begin
  Result := TRectangle.Create(Self);
  Result.Parent := FCaption;
  Result.Align := TAlignLayout.Right;
  Result.Width := CButtonWidth;
  Result.Fill.Kind := TBrushKind.None;
  Result.Stroke.Kind := TBrushKind.None;
  Result.HitTest := True;
  Result.OnClick := AOnClick;
  Result.OnMouseEnter := ButtonEnter;
  Result.OnMouseLeave := ButtonLeave;
  APath := TPath.Create(Self);
  APath.Parent := Result;
  APath.Align := TAlignLayout.Center;
  APath.Width := 10;
  APath.Height := 10;
  APath.HitTest := False;
  // The glyphs span a 10 x 10 box.
  APath.WrapMode := TPathWrapMode.Stretch;
  APath.Fill.Kind := TBrushKind.None;
  APath.Stroke.Color := TAlphaColors.White;
  APath.Stroke.Thickness := 1.2;
  APath.Data.Data := AGlyph;
end;

procedure TTitleBarForm.ButtonEnter(Sender: TObject);
begin
  TRectangle(Sender).Fill.Kind := TBrushKind.Solid;
  if Sender = FCloseButton then
    TRectangle(Sender).Fill.Color := $FFE81123
  else
    TRectangle(Sender).Fill.Color := $40FFFFFF;
end;

procedure TTitleBarForm.ButtonLeave(Sender: TObject);
begin
  TRectangle(Sender).Fill.Kind := TBrushKind.None;
end;

procedure TTitleBarForm.CaptionMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Single);
var
  P: TPointF;
  Maximize: Boolean;
begin
  if FFrame = nil then
    Exit;
  P := FCaption.LocalToAbsolute(PointF(X, Y));
  case Button of
    TMouseButton.mbLeft:
      if ssDouble in Shift then
      begin
        if FCaps and FmxwCapMaximize <> 0 then
        begin
          Maximize := FStates and FmxwStateMaximized = 0;
          Log(Format('frame: double click: SetMaximized %s', [BoolToStr(Maximize, True)]));
          FFrame.SetMaximized(Handle, Maximize);
        end
        else
          Log('frame: double click: no maximize capability');
      end
      else
        // The compositor moves the window until the button is released; a click without motion ends at once, so
        // the second press of a double click comes here again.
        Log(Format('frame: BeginMove %s', [BoolToStr(FFrame.BeginMove(Handle), True)]));
    TMouseButton.mbRight:
      Log(Format('frame: ShowWindowMenu at %.0f,%.0f %s', [P.X, P.Y,
        BoolToStr(FFrame.ShowWindowMenu(Handle, P), True)]));
  end;
end;

procedure TTitleBarForm.GripMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Single);
var
  Edges: Cardinal;
begin
  if (FFrame = nil) or (Button <> TMouseButton.mbLeft) then
    Exit;
  Edges := Cardinal(TLayout(Sender).Tag);
  Log(Format('frame: BeginResize %d %s', [Edges, BoolToStr(FFrame.BeginResize(Handle, Edges), True)]));
end;

procedure TTitleBarForm.MinimizeClick(Sender: TObject);
begin
  Log('frame: Minimize');
  if FFrame <> nil then
    FFrame.Minimize(Handle);
end;

procedure TTitleBarForm.MaximizeClick(Sender: TObject);
var
  Maximize: Boolean;
begin
  Maximize := FStates and FmxwStateMaximized = 0;
  Log(Format('frame: maximize button: SetMaximized %s', [BoolToStr(Maximize, True)]));
  if FFrame <> nil then
    FFrame.SetMaximized(Handle, Maximize);
end;

procedure TTitleBarForm.CloseClick(Sender: TObject);
begin
  Log('frame: close button');
  Close;
end;

procedure TTitleBarForm.OtherClick(Sender: TObject);
var
  F: TForm;
begin
  Inc(FOtherCount);
  F := TForm.CreateNew(Application);
  F.Caption := Format('Other window %d', [FOtherCount]);
  F.ClientWidth := 320;
  F.ClientHeight := 140;
  F.Show;
  Log(Format('other window %d shown', [FOtherCount]));
end;

procedure TTitleBarForm.ComboChange(Sender: TObject);
begin
  if FCombo.ItemIndex >= 0 then
    Log('combo ' + FCombo.Items[FCombo.ItemIndex]);
end;

procedure TTitleBarForm.WindowFrameChanged(const AStates, ACapabilities: Cardinal);
var
  Active, Maximized: Boolean;
begin
  FStates := AStates;
  FCaps := ACapabilities;
  Active := AStates and FmxwStateActivated <> 0;
  Maximized := AStates and (FmxwStateMaximized or FmxwStateFullscreen) <> 0;
  if Active then
    FCaption.Fill.Color := CCaptionActive
  else
    FCaption.Fill.Color := CCaptionInactive;
  FBorder.Stroke.Color := FCaption.Fill.Color;
  FBorder.Visible := not Maximized;
  // Restore: two overlapping squares.
  if Maximized then
    FMaxGlyph.Data.Data := 'M2,0 L10,0 L10,8 M0,2 L8,2 L8,10 L0,10 Z'
  else
    FMaxGlyph.Data.Data := 'M0,0 L10,0 L10,10 L0,10 Z';
  FMaxButton.Visible := ACapabilities and FmxwCapMaximize <> 0;
  FMinButton.Visible := ACapabilities and FmxwCapMinimize <> 0;
  FStateLabel.Text := Format('States: %s; window manager: %s', [StatesText(AStates), CapsText(ACapabilities)]);
  Log(Format('frame: states $%x (%s) capabilities $%x (%s)', [AStates, StatesText(AStates), ACapabilities,
    CapsText(ACapabilities)]));
  PlaceGrips;
end;

procedure TTitleBarForm.PlaceGrips;
var
  G: TLayout;
  W, H: Single;
  Show: Boolean;
begin
  W := ClientWidth;
  H := ClientHeight;
  // No resizing of a maximized, full screen or tiled window.
  Show := (FFrame <> nil) and (FStates and (FmxwStateMaximized or FmxwStateFullscreen or FmxwStateTiled) = 0);
  for G in FGrips do
  begin
    if G = nil then
      Continue;
    G.Visible := Show;
    case Cardinal(G.Tag) of
      FmxwEdgeTop:
        G.SetBounds(CGripCorner, 0, W - 2 * CGripCorner, CGripThickness);
      FmxwEdgeBottom:
        G.SetBounds(CGripCorner, H - CGripThickness, W - 2 * CGripCorner, CGripThickness);
      FmxwEdgeLeft:
        G.SetBounds(0, CGripCorner, CGripThickness, H - 2 * CGripCorner);
      FmxwEdgeRight:
        G.SetBounds(W - CGripThickness, CGripCorner, CGripThickness, H - 2 * CGripCorner);
      FmxwEdgeTopLeft:
        G.SetBounds(0, 0, CGripCorner, CGripThickness);
      FmxwEdgeTopRight:
        G.SetBounds(W - CGripCorner, 0, CGripCorner, CGripThickness);
      FmxwEdgeBottomLeft:
        G.SetBounds(0, H - CGripCorner, CGripCorner, CGripCorner);
      FmxwEdgeBottomRight:
        G.SetBounds(W - CGripCorner, H - CGripCorner, CGripCorner, CGripCorner);
    end;
    // Above the other controls (hit tests look at the last child first).
    G.BringToFront;
  end;
end;

procedure TTitleBarForm.FormResized(Sender: TObject);
begin
  if FSizeLabel = nil then
    Exit;
  FSizeLabel.Text := 'Client area: ' + SizeText;
  Log(Format('resize %s state %d', [SizeText, Ord(WindowState)]));
  PlaceGrips;
end;

procedure TTitleBarForm.FormActivated(Sender: TObject);
begin
  Log('form activated');
end;

procedure TTitleBarForm.FormDeactivated(Sender: TObject);
begin
  Log('form deactivated');
end;

procedure TTitleBarForm.FormDestroyed(Sender: TObject);
begin
  Log('destroyed');
end;

procedure TTitleBarForm.QuitTimerTimer(Sender: TObject);
begin
  FQuitTimer.Enabled := False;
  Log('quit timer: closing');
  Close;
end;

/// --selftest: the service without input (where no input can be injected, as on Weston).
procedure TTitleBarForm.SelfTestStep(Sender: TObject);
begin
  if FFrame = nil then
  begin
    Log('selftest: no frame service');
    FSelfTimer.Enabled := False;
    Close;
    Exit;
  end;
  Inc(FSelfStep);
  case FSelfStep of
    1:
      begin
        Log(Format('selftest: decorated %s, client %s, states (%s), capabilities (%s)',
          [BoolToStr(FFrame.GetDecorated(Handle), True), SizeText, StatesText(FFrame.GetStates(Handle)),
          CapsText(FFrame.GetCapabilities(Handle))]));
        // No press: nothing to start.
        Log(Format('selftest: without a press: BeginMove %s, BeginResize %s, ShowWindowMenu %s',
          [BoolToStr(FFrame.BeginMove(Handle), True), BoolToStr(FFrame.BeginResize(Handle, FmxwEdgeBottomRight),
          True), BoolToStr(FFrame.ShowWindowMenu(Handle, PointF(20, 20)), True)]));
      end;
    2:
      begin
        FCombo.DropDown;
        Log(Format('selftest: drop-down open %s', [BoolToStr(FCombo.DroppedDown, True)]));
      end;
    6:
      begin
        FCombo.DropDown;
        Log(Format('selftest: drop-down closed %s', [BoolToStr(not FCombo.DroppedDown, True)]));
      end;
    7:
      if FCaps and FmxwCapMaximize <> 0 then
        FFrame.SetMaximized(Handle, True)
      else
        Log('selftest: no maximize capability');
    8:
      if FCaps and FmxwCapMaximize <> 0 then
      begin
        Log(Format('selftest: maximized %s %s', [BoolToStr(FStates and FmxwStateMaximized <> 0, True), SizeText]));
        FFrame.SetMaximized(Handle, False);
      end;
    9:
      Log(Format('selftest: restored %s %s', [BoolToStr(FStates and FmxwStateMaximized = 0, True), SizeText]));
    10:
      begin
        FFrame.SetDecorated(Handle, True);
        Log(Format('selftest: decorations on: decorated %s, client %s', [BoolToStr(FFrame.GetDecorated(Handle),
          True), SizeText]));
      end;
    12:
      begin
        FFrame.SetDecorated(Handle, False);
        Log(Format('selftest: decorations off: decorated %s, client %s', [BoolToStr(FFrame.GetDecorated(Handle),
          True), SizeText]));
      end;
    14:
      begin
        FSelfTimer.Enabled := False;
        Log('selftest: done');
        Close;
      end;
  end;
end;

end.
