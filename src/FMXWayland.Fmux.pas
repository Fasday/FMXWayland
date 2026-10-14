{ FMXWayland: native Wayland platform for Delphi FireMonkey on Linux.
  Copyright (c) 2026 Fasday. MIT license, see LICENSE. }

/// <summary>The FMUX API (the function pointers of FMUX.Api that FMX for Linux calls) implemented over
/// FMXWayland.Platform.</summary>
/// <remarks>
/// <para>Windows: FMX's window handle (TLinuxWindowHandle.Window) is a TFmuxWindow, a TWlWindow that forwards the
/// Wayland events to the callbacks of TFmuxCreateStruct.</para>
/// <para>Coordinates: Wayland has no global coordinates. Every window keeps a virtual origin (what FMX set with
/// SetWindowRect); ClientToScreen/ScreenToClient and the screen positions of mouse events use it, so FMX's own
/// conversions stay consistent; popups are placed relative to their parent and take the origin the compositor gives
/// them.</para>
/// <para>Painting: the paint context handed to FMX (the Ctx of TFmuxPaintCallback, the context handle of the canvas)
/// is a PWlFrame; FMX's Skia raster canvas renders into an FMUX bitmap (plain memory here) and copies it with
/// FmuxCanvasDrawBitmap into the frame, a wl_shm buffer that is then attached to the surface. FMX's cairo canvas
/// (FMX.Canvas.Linux, used when GlobalUseSkia is False) is not supported.</para>
/// <para>The function list with their status is in README.md; gen-fmux-api.ps1 reads the assignments in
/// AssignFmuxApi (a "// partial: ..." comment after an assignment marks a function that is only partly done).</para>
/// </remarks>
unit FMXWayland.Fmux;

interface

/// <summary>Assigns the implemented function pointers of FMUX.Api (called by the generated FMUX.Api.LoadLib after it
/// has assigned the stubs).</summary>
procedure AssignFmuxApi;

implementation

uses
  System.SysUtils, System.Types, System.Classes, System.UITypes, System.Math, System.Messaging,
  System.Generics.Collections, FMX.Types, FMX.Graphics, FMX.Forms, FMX.Controls, FMX.Platform, FMX.Platform.Linux,
  FMUX.Api,
  FMXWayland.Log, FMXWayland.Platform, FMXWayland.Native;

type
  /// <summary>An FMX window.</summary>
  TFmuxWindow = class(TWlWindow)
  private
    FCreate: TFmuxCreateStruct;
    FLastDump: Int64;
    FDumpIndex: Integer;
    FTitleKey: string;
    FTitlePixels: TArray<Cardinal>;
    FTitleWidth: Integer;
    FTitleHeight: Integer;
    function Form: TCommonCustomForm;
    function WindowRect: TRectF;
    procedure SetWindowRect(const ARect: TRectF);
    procedure ReportBounds;
    procedure DumpFrame(const AFrame: PWlFrame);
    procedure RenderTitle(const AWidth, AHeight: Integer; const ATitle: string; const AActive: Boolean;
      const AScale: Single);
  protected
    procedure DoDrawTitle(const AFrame: PWlFrame; const ARect: TRect; const ATitle: string; const AActive: Boolean);
      override;
    procedure DoPaint(const AFrame: PWlFrame; const ADirty: TRectF); override;
    procedure DoResized; override;
    procedure DoMoved; override;
    procedure DoStateChanged(const AState: TWlWindowState); override;
    procedure DoActivate(const AActive: Boolean); override;
    procedure DoCloseRequest; override;
    procedure DoPopupDone; override;
    procedure DoPointer(const AEvent: TWlPointerEvent; const AX, AY: Single; const AState, AWheelDelta: Integer);
      override;
    procedure DoKey(const AEvent: TWlKeyEvent; const AKey: Word; const AChar: Char; const AState: Integer); override;
    procedure DoScaleChanged; override;
  end;

  /// <summary>An FMUX bitmap: plain memory, premultiplied BGRA, 4 bytes per pixel, no padding.</summary>
  TFmuxBitmap = record
    Width: Integer;
    Height: Integer;
    Data: Pointer;
    OwnsData: Boolean;
  end;
  PFmuxBitmap = ^TFmuxBitmap;

  /// <summary>IFMXWaylandNativeWindow, registered as a platform service.</summary>
  TNativeWindowService = class(TInterfacedObject, IFMXWaylandNativeWindow)
  private
    function WindowOf(const AHandle: TWindowHandle): TFmuxWindow;
  public
    function GetWaylandDisplay: Pointer;
    function GetWaylandSurface(const AHandle: TWindowHandle): Pointer;
    function GetBufferSize(const AHandle: TWindowHandle): TSize;
    function GetScale(const AHandle: TWindowHandle): Single;
    procedure SetExternalPresentation(const AHandle: TWindowHandle; const AValue: Boolean);
  end;

var
  GWakeProc: TFmuxWakeMainThreadProc = nil;
  GMainWindow: TFmuxWindow = nil;
  GModalStack: TList<TFmuxWindow> = nil;
  GVersionInfo: TFmuxVersionInfo;
  GClipboardText: string;
  GDumpDir: string;
  GNativeServiceRegistered: Boolean = False;
  GCanvasChecked: Boolean = False;

{$REGION 'Helpers'}

/// The connection; connects on first use (FMX skips FmuxInit when FMUX.Config.DoNotCallFmuxInit is set).
function Disp: TWlDisplay;
begin
  Result := WlDisplay;
  if Result = nil then
  begin
    try
      Result := WlConnect;
    except
      on E: Exception do
      begin
        WlLog(TWlLogLevel.Error, E.Message);
        Halt(1);
      end;
    end;
  end;
end;

/// The window of an FMUX window pointer, if it is still alive.
function Win(const AWnd: Pointer): TFmuxWindow; inline;
begin
  Result := TFmuxWindow(AWnd);
end;

/// Input goes to the top modal window and to popups only while a modal loop runs.
function InputAllowed(const AWindow: TWlWindow): Boolean;
begin
  Result := (GModalStack = nil) or (GModalStack.Count = 0) or (AWindow = GModalStack.Last) or
    (AWindow.Kind = TWlWindowKind.Popup);
end;

{$ENDREGION}

{$REGION 'TFmuxWindow'}

function TFmuxWindow.Form: TCommonCustomForm;
begin
  Result := TCommonCustomForm(FCreate.Data);
end;

function TFmuxWindow.WindowRect: TRectF;
var
  Ins: TRect;
begin
  // FMX's window rectangle includes the frame (client-side decorations); the origin is the client area's.
  Ins := DecorationInsets;
  Result := RectF(Origin.X - Ins.Left, Origin.Y - Ins.Top, Origin.X + Width + Ins.Right,
    Origin.Y + Height + Ins.Bottom);
end;

procedure TFmuxWindow.SetWindowRect(const ARect: TRectF);
var
  Ins: TRect;
begin
  Ins := DecorationInsets;
  SetBounds(ARect.Left + Ins.Left, ARect.Top + Ins.Top, Round(ARect.Width) - Ins.Left - Ins.Right,
    Round(ARect.Height) - Ins.Top - Ins.Bottom);
end;

procedure TFmuxWindow.ReportBounds;
begin
  if Assigned(FCreate.BoundsChanged) then
    FCreate.BoundsChanged(FCreate.Data, WindowRect);
end;

procedure TFmuxWindow.RenderTitle(const AWidth, AHeight: Integer; const ATitle: string; const AActive: Boolean;
  const AScale: Single);
var
  B: TBitmap;
  Data: TBitmapData;
  Y: Integer;
begin
  FTitleWidth := 0;
  FTitleHeight := 0;
  FTitlePixels := nil;
  B := TBitmap.Create(AWidth, AHeight);
  try
    B.Clear(0);
    if B.Canvas.BeginScene then
      try
        if AActive then
          B.Canvas.Fill.Color := $FF2E3436
        else
          B.Canvas.Fill.Color := $FF8A8F8F;
        B.Canvas.Font.Size := 13 * AScale;
        B.Canvas.Font.Style := [TFontStyle.fsBold];
        B.Canvas.FillText(RectF(0, 0, AWidth, AHeight), ATitle, False, 1, [], TTextAlign.Center,
          TTextAlign.Center);
      finally
        B.Canvas.EndScene;
      end;
    if B.Map(TMapAccess.Read, Data) then
      try
        if Data.PixelFormat <> TPixelFormat.BGRA then
          Exit;
        SetLength(FTitlePixels, AWidth * AHeight);
        for Y := 0 to AHeight - 1 do
          Move(Data.GetScanline(Y)^, FTitlePixels[Y * AWidth], AWidth * 4);
        FTitleWidth := AWidth;
        FTitleHeight := AHeight;
      finally
        B.Unmap(Data);
      end;
  finally
    B.Free;
  end;
end;

procedure TFmuxWindow.DoDrawTitle(const AFrame: PWlFrame; const ARect: TRect; const ATitle: string;
  const AActive: Boolean);
var
  Key: string;
  X, Y: Integer;
  Src, Dst: PCardinal;
  A: Cardinal;
begin
  if (ARect.Width <= 0) or (ARect.Height <= 0) or (ATitle = '') then
    Exit;
  Key := Format('%s|%d|%d|%d|%.2f', [ATitle, ARect.Width, ARect.Height, Ord(AActive), AFrame.Scale]);
  if Key <> FTitleKey then
  begin
    FTitleKey := Key;
    try
      RenderTitle(ARect.Width, ARect.Height, ATitle, AActive, AFrame.Scale);
    except
      on E: Exception do
      begin
        FTitlePixels := nil;
        WlLogOnce('title', 'cannot draw window titles: ' + E.Message);
      end;
    end;
  end;
  if FTitlePixels = nil then
    Exit;
  // Source-over of the premultiplied title onto the (opaque) title bar.
  for Y := 0 to FTitleHeight - 1 do
  begin
    if (ARect.Top + Y < 0) or (ARect.Top + Y >= AFrame.Height) then
      Continue;
    Src := @FTitlePixels[Y * FTitleWidth];
    Dst := PCardinal(PByte(AFrame.Bits) + NativeInt(ARect.Top + Y) * AFrame.Stride + ARect.Left * 4);
    for X := 0 to FTitleWidth - 1 do
    begin
      A := Src^ shr 24;
      if A = 255 then
        Dst^ := Src^
      else if A > 0 then
        Dst^ := Src^ + (((((Dst^ and $00FF00FF) * (255 - A)) shr 8) and $00FF00FF) or
          ((((Dst^ shr 8) and $00FF00FF) * (255 - A)) and $FF00FF00));
      Inc(Src);
      Inc(Dst);
    end;
  end;
end;

procedure TFmuxWindow.DoPaint(const AFrame: PWlFrame; const ADirty: TRectF);
var
  R: TRectF;
begin
  if not Assigned(FCreate.PaintCallback) then
    Exit;
  if not GCanvasChecked then
  begin
    // (FMX.Skia cannot be used here to set GlobalUseSkia: its canvas service must initialize after FMX.Platform.)
    GCanvasChecked := True;
    if (TCanvasManager.DefaultCanvas <> nil) and (TCanvasManager.DefaultCanvas.ClassName = 'TLinuxCanvas') then
      WlLog(TWlLogLevel.Error, 'FMX''s cairo canvas (FMX.Canvas.Linux) is not supported by FMXWayland and draws ' +
        'nothing: add FMX.Skia to the uses of the program and set GlobalUseSkia := True before ' +
        'Application.Initialize.');
  end;
  R := ADirty;
  FCreate.PaintCallback(FCreate.Data, AFrame, PRectFArray(@R), 1);
  if (GDumpDir <> '') and AFrame.Drawn then
    DumpFrame(AFrame);
end;

procedure TFmuxWindow.DumpFrame(const AFrame: PWlFrame);
var
  Now: Int64;
  Name: string;
  C: Char;
  S: TFileStream;
  Header: packed record
    Magic: Word;
    FileSize: Cardinal;
    Reserved: Cardinal;
    Offset: Cardinal;
    Size: Cardinal;
    Width: Integer;
    Height: Integer;
    Planes: Word;
    BitCount: Word;
    Compression: Cardinal;
    ImageSize: Cardinal;
    XPels: Integer;
    YPels: Integer;
    ClrUsed: Cardinal;
    ClrImportant: Cardinal;
  end;
  Y: Integer;
begin
  // Debug aid (FMXWAYLAND_DUMP_DIR): the latest frame of each window as a BMP, at most every 300 ms.
  Now := TThread.GetTickCount64;
  if (FLastDump <> 0) and (Now - FLastDump < 300) then
    Exit;
  FLastDump := Now;
  Inc(FDumpIndex);
  Name := '';
  for C in Title do
    if CharInSet(C, ['A'..'Z', 'a'..'z', '0'..'9', '-', '_']) then
      Name := Name + C;
  if Kind = TWlWindowKind.Popup then
    Name := 'popup';
  if Name = '' then
    Name := 'window';
  Name := Format('%s-%p.bmp', [Name, Pointer(Self)]);
  FillChar(Header, SizeOf(Header), 0);
  Header.Magic := $4D42;
  Header.Offset := SizeOf(Header);
  Header.FileSize := SizeOf(Header) + Cardinal(AFrame.Width * AFrame.Height * 4);
  Header.Size := 40;
  Header.Width := AFrame.Width;
  Header.Height := -AFrame.Height;
  Header.Planes := 1;
  Header.BitCount := 32;
  Header.ImageSize := AFrame.Width * AFrame.Height * 4;
  try
    S := TFileStream.Create(IncludeTrailingPathDelimiter(GDumpDir) + Name, fmCreate);
    try
      S.WriteBuffer(Header, SizeOf(Header));
      for Y := 0 to AFrame.Height - 1 do
        S.WriteBuffer((PByte(AFrame.Bits) + Y * AFrame.Stride)^, AFrame.Width * 4);
    finally
      S.Free;
    end;
  except
    on E: Exception do
      WlLogOnce('dump', 'cannot write frame dumps to ' + GDumpDir + ': ' + E.Message);
  end;
end;

procedure TFmuxWindow.DoResized;
begin
  ReportBounds;
end;

procedure TFmuxWindow.DoMoved;
begin
  ReportBounds;
end;

procedure TFmuxWindow.DoStateChanged(const AState: TWlWindowState);
begin
  if Assigned(FCreate.StateChanged) then
    FCreate.StateChanged(FCreate.Data, TFmuxWindowState(Ord(AState)));
end;

procedure TFmuxWindow.DoActivate(const AActive: Boolean);
begin
  if Assigned(FCreate.Activate) then
    FCreate.Activate(FCreate.Data, AActive);
end;

procedure TFmuxWindow.DoCloseRequest;
begin
  if Assigned(FCreate.Close) and InputAllowed(Self) then
    FCreate.Close(FCreate.Data);
end;

procedure TFmuxWindow.DoPopupDone;
begin
  if Assigned(FCreate.Close) then
    FCreate.Close(FCreate.Data);
end;

procedure TFmuxWindow.DoPointer(const AEvent: TWlPointerEvent; const AX, AY: Single; const AState,
  AWheelDelta: Integer);
var
  P: TPointF;
  F: TCommonCustomForm;
begin
  if not InputAllowed(Self) or not Assigned(FCreate.Motion) then
    Exit;
  // FMX takes screen coordinates (virtual: origin + position in the window).
  P := ClientToScreen(PointF(AX, AY));
  case AEvent of
    TWlPointerEvent.Move:
      FCreate.Motion(FCreate.Data, TFmuxMotionKind.Move, P.X, P.Y, AState);
    TWlPointerEvent.Down:
      FCreate.Motion(FCreate.Data, TFmuxMotionKind.Down, P.X, P.Y, AState);
    TWlPointerEvent.Up:
      FCreate.Motion(FCreate.Data, TFmuxMotionKind.Up, P.X, P.Y, AState);
    TWlPointerEvent.Wheel:
      // FMX reads the wheel delta from Y (WHEEL_DELTA = 120 per notch, positive = up).
      FCreate.Motion(FCreate.Data, TFmuxMotionKind.Scroll, 0, AWheelDelta, AState);
    TWlPointerEvent.Leave:
      begin
        F := Form;
        try
          if F <> nil then
            F.MouseLeave;
        except
          Application.HandleException(F);
        end;
      end;
  end;
end;

procedure TFmuxWindow.DoKey(const AEvent: TWlKeyEvent; const AKey: Word; const AChar: Char; const AState: Integer);
begin
  if not InputAllowed(Self) or not Assigned(FCreate.Key) then
    Exit;
  FCreate.Key(FCreate.Data, TFmuxKeyKind(Ord(AEvent)), AKey, AChar, AState);
end;

procedure TFmuxWindow.DoScaleChanged;
var
  F: TCommonCustomForm;
begin
  F := Form;
  if (F = nil) or (F.Handle = nil) then
    Exit;
  try
    TMessageManager.DefaultManager.SendMessage(nil, TScaleChangedMessage.Create(F));
  except
    Application.HandleException(F);
  end;
end;

{$ENDREGION}

{$REGION 'TNativeWindowService'}

function TNativeWindowService.WindowOf(const AHandle: TWindowHandle): TFmuxWindow;
var
  P: Pointer;
begin
  Result := nil;
  if (AHandle is TLinuxWindowHandle) and (WlDisplay <> nil) then
  begin
    P := TLinuxWindowHandle(AHandle).Window;
    if (P <> nil) and WlDisplay.Windows.Contains(TWlWindow(P)) then
      Result := TFmuxWindow(P);
  end;
end;

function TNativeWindowService.GetWaylandDisplay: Pointer;
begin
  if WlDisplay <> nil then
    Result := WlDisplay.Display
  else
    Result := nil;
end;

function TNativeWindowService.GetWaylandSurface(const AHandle: TWindowHandle): Pointer;
var
  W: TFmuxWindow;
begin
  W := WindowOf(AHandle);
  if W <> nil then
    Result := W.Surface
  else
    Result := nil;
end;

function TNativeWindowService.GetBufferSize(const AHandle: TWindowHandle): TSize;
var
  W: TFmuxWindow;
begin
  W := WindowOf(AHandle);
  if W <> nil then
    Result := TSize.Create(W.BufferWidth, W.BufferHeight)
  else
    Result := TSize.Create(0, 0);
end;

function TNativeWindowService.GetScale(const AHandle: TWindowHandle): Single;
var
  W: TFmuxWindow;
begin
  W := WindowOf(AHandle);
  if W <> nil then
    Result := W.Scale
  else
    Result := 1;
end;

procedure TNativeWindowService.SetExternalPresentation(const AHandle: TWindowHandle; const AValue: Boolean);
var
  W: TFmuxWindow;
begin
  W := WindowOf(AHandle);
  if W <> nil then
    W.ExternalPresentation := AValue;
end;

{$ENDREGION}

{$REGION 'Application'}

procedure WlInit(Flags: Integer); cdecl;
begin
  Disp.WakeProc :=
    procedure
    begin
      if Assigned(GWakeProc) then
        GWakeProc();
    end;
  if not GNativeServiceRegistered then
  begin
    GNativeServiceRegistered := True;
    TPlatformServices.Current.AddPlatformService(IFMXWaylandNativeWindow, TNativeWindowService.Create);
  end;
end;

procedure WlRun(IdleProc: TFmuxIdleProc); cdecl;
begin
  Disp.IdleProc :=
    procedure
    begin
      if Assigned(IdleProc) then
        IdleProc();
    end;
  Disp.RunLoop(nil);
end;

procedure WlTerminate; cdecl;
begin
  if WlDisplay <> nil then
    WlDisplay.Terminate;
end;

function WlHandleMessage: Boolean; cdecl;
begin
  Result := Disp.ProcessEvents(0);
end;

procedure WlWakeMainThread(Proc: TFmuxWakeMainThreadProc); cdecl;
var
  D: TWlDisplay;
begin
  // Any thread (TThread.Synchronize/Queue): the procedure runs on the main thread when the loop wakes.
  GWakeProc := Proc;
  D := WlDisplay;
  if D <> nil then
    D.Wake;
end;

function WlCreateTimer(Interval: Integer; TimerFunc: TFmuxTimerProc; Data, Code: Pointer): NativeInt; cdecl;
begin
  Result := Disp.CreateTimer(Interval,
    procedure
    begin
      TimerFunc(Data, Code);
    end);
end;

function WlDestroyTimer(Timer: NativeInt): Boolean; cdecl;
begin
  Result := (WlDisplay <> nil) and WlDisplay.DestroyTimer(Timer);
end;

function WlGetKeyState: Integer; cdecl;
begin
  Result := Disp.ModState;
end;

procedure WlSetLog(Log: TFmuxLog); cdecl;
begin
  // FMX passes a procedure that writes to stdout; FMXWayland logs to stderr itself (FMXWAYLAND_LOG).
end;

procedure WlGetVersionInfo(var VI: TFmuxVersionInfo); cdecl;
begin
  VI := GVersionInfo;
end;

procedure WlSetVersionInfo(var VI: TFmuxVersionInfo); cdecl;
begin
  GVersionInfo := VI;
end;

function WlIsWayland: Boolean; cdecl;
begin
  Result := True;
end;

function WlIsBroadway: Boolean; cdecl;
begin
  Result := False;
end;

{$ENDREGION}

{$REGION 'Windows'}

function WlCreateWindow(var CreateStruct: TFmuxCreateStruct): Pointer; cdecl;
var
  W: TFmuxWindow;
  Kind: TWlWindowKind;
begin
  if CreateStruct.Popup then
    Kind := TWlWindowKind.Popup
  else
    Kind := TWlWindowKind.Toplevel;
  W := TFmuxWindow.Create(Disp, Kind, CreateStruct.Transparent or CreateStruct.Popup);
  W.FCreate := CreateStruct;
  W.FCreate.Title := nil;
  W.Borderless := CreateStruct.BorderStyle = TFmuxBorderStyle.None;
  W.PrepareDecorations;
  if CreateStruct.Title <> nil then
    W.SetTitle(CreateStruct.Title);
  W.SetWindowRect(RectF(CreateStruct.X, CreateStruct.Y, CreateStruct.X + CreateStruct.Width,
    CreateStruct.Y + CreateStruct.Height));
  WlLog(TWlLogLevel.Debug, 'CreateWindow %p "%s" popup %s %.0f,%.0f %.0fx%.0f', [Pointer(W), W.Title,
    BoolToStr(CreateStruct.Popup, True), CreateStruct.X, CreateStruct.Y, CreateStruct.Width, CreateStruct.Height]);
  Result := W;
end;

procedure WlDestroyWindow(Wnd: Pointer); cdecl;
var
  W: TFmuxWindow;
begin
  W := Win(Wnd);
  if W = nil then
    Exit;
  if GMainWindow = W then
    GMainWindow := nil;
  if GModalStack <> nil then
    GModalStack.Remove(W);
  W.Free;
end;

procedure WlSetMainWindow(Wnd: Pointer); cdecl;
begin
  GMainWindow := Win(Wnd);
end;

/// The window a popup belongs to: the form of its placement target, else where the user just was.
function PopupParent(const AWindow: TFmuxWindow): TWlWindow;

  function Usable(const W: TWlWindow): Boolean;
  begin
    Result := (W <> nil) and (W <> AWindow) and W.Visible and (W.XdgSurface <> nil) and
      Disp.Windows.Contains(W);
  end;

var
  F: TCommonCustomForm;
  Target: TControl;
  Root: TFmxObject;
  P: Pointer;
begin
  Result := nil;
  F := AWindow.Form;
  if F is TCustomPopupForm then
  begin
    Target := TCustomPopupForm(F).PlacementTarget;
    if (Target <> nil) and (Target.Root <> nil) then
    begin
      Root := Target.Root.GetObject;
      if (Root is TCommonCustomForm) and (TCommonCustomForm(Root).Handle <> nil) then
      begin
        P := FormToWnd(TCommonCustomForm(Root));
        if Usable(TWlWindow(P)) then
          Exit(TWlWindow(P));
      end;
    end;
  end;
  if Usable(Disp.PointerWindow) then
    Exit(Disp.PointerWindow);
  if Usable(Disp.LastInputWindow) then
    Exit(Disp.LastInputWindow);
  if Usable(Disp.KeyboardWindow) then
    Exit(Disp.KeyboardWindow);
  if Usable(GMainWindow) then
    Exit(GMainWindow);
end;

procedure WlShowWindow(Wnd: Pointer; Show: Boolean); cdecl;
var
  W: TFmuxWindow;
begin
  W := Win(Wnd);
  if W = nil then
    Exit;
  if Show then
  begin
    if W.Kind = TWlWindowKind.Popup then
      W.Parent := PopupParent(W);
    W.Show;
  end
  else
    W.Hide;
end;

procedure WlSetWindowState(Wnd: Pointer; AState: TFmuxWindowState); cdecl;
begin
  if Wnd <> nil then
    Win(Wnd).SetState(TWlWindowState(Ord(AState)));
end;

procedure WlSetWindowTitle(Wnd: Pointer; Title: PChar); cdecl;
begin
  if Wnd <> nil then
    Win(Wnd).SetTitle(Title);
end;

procedure WlSetWindowIcon(Wnd: Pointer; Data: Pointer; Size: Integer); cdecl;
begin
  // xdg-toplevel-icon-v1 is not bound yet; the compositor shows the icon of the .desktop file of the app id.
end;

procedure WlActivateWindow(Wnd: Pointer); cdecl;
begin
  // Wayland clients cannot raise or focus their windows without an activation token from the user's action.
end;

procedure WlWindowBringToFront(Wnd: Pointer); cdecl;
begin
end;

procedure WlWindowSendToBack(Wnd: Pointer); cdecl;
begin
end;

procedure WlGetClientSize(Wnd: Pointer; var R: TPointF); cdecl;
begin
  if Wnd <> nil then
    R := PointF(Win(Wnd).Width, Win(Wnd).Height)
  else
    R := PointF(0, 0);
end;

procedure WlSetClientSize(Wnd: Pointer; R: TPointF); cdecl;
var
  W: TFmuxWindow;
  OldW, OldH: Integer;
begin
  if Wnd = nil then
    Exit;
  WlLog(TWlLogLevel.Debug, 'SetClientSize %p %.0fx%.0f', [Wnd, R.X, R.Y]);
  W := Win(Wnd);
  OldW := W.Width;
  OldH := W.Height;
  W.SetSize(Round(R.X), Round(R.Y));
  // FMX reads the new bounds back from the platform (TCommonCustomForm.SetClientWidth sets its bounds from FBounds
  // right after this call), as GTK's synchronous size allocation did for libfmux.
  if (W.Width <> OldW) or (W.Height <> OldH) then
    W.ReportBounds;
end;

procedure WlGetWindowRect(Wnd: Pointer; var R: TRectF); cdecl;
var
  W: TFmuxWindow;
begin
  W := Win(Wnd);
  if W <> nil then
    R := W.WindowRect
  else
    R := TRectF.Empty;
end;

procedure WlSetWindowRect(Wnd: Pointer; R: TRectF); cdecl;
begin
  if Wnd = nil then
    Exit;
  WlLog(TWlLogLevel.Debug, 'SetWindowRect %p %.0f,%.0f %.0fx%.0f', [Wnd, R.Left, R.Top, R.Width, R.Height]);
  Win(Wnd).SetWindowRect(R);
end;

procedure WlInvalidateRect(Wnd: Pointer; R: TRectF); cdecl;
begin
  if Wnd <> nil then
    Win(Wnd).Invalidate(R);
end;

procedure WlProcessUpdates(Wnd: Pointer); cdecl;
begin
  if Wnd <> nil then
    Win(Wnd).PaintNow;
end;

function WlClientToScreen(Wnd: Pointer; Point: TPointF): TPointF; cdecl;
begin
  if Wnd <> nil then
    Result := Win(Wnd).ClientToScreen(Point)
  else
    Result := Point;
end;

function WlScreenToClient(Wnd: Pointer; Point: TPointF): TPointF; cdecl;
begin
  if Wnd <> nil then
    Result := Win(Wnd).ScreenToClient(Point)
  else
    Result := Point;
end;

function WlGetWindowScale(Wnd: Pointer): Single; cdecl;
begin
  if Wnd <> nil then
    Result := Win(Wnd).Scale
  else
    Result := 1;
end;

function WlGetWindowFullScreen(Wnd: Pointer): Boolean; cdecl;
begin
  Result := (Wnd <> nil) and Win(Wnd).FullScreen;
end;

procedure WlSetWindowFullScreen(Wnd: Pointer; AValue: Boolean); cdecl;
begin
  if Wnd <> nil then
    Win(Wnd).SetFullScreen(AValue);
end;

procedure WlSetCapture(Wnd: Pointer); cdecl;
begin
  // Wayland grabs the pointer implicitly while a button is held: the window keeps getting the events.
end;

procedure WlReleaseCapture(Wnd: Pointer); cdecl;
begin
end;

function WlGetWindowNativeHandle(Wnd: Pointer): Pointer; cdecl;
begin
  // Not a GtkWindow: the wl_surface (see also IFMXWaylandNativeWindow).
  if Wnd <> nil then
    Result := Win(Wnd).Surface
  else
    Result := nil;
end;

procedure WlAddTooltip(Wnd: Pointer; Text: PChar); cdecl;
begin
end;

procedure WlRemoveTooltip(Wnd: Pointer); cdecl;
begin
end;

procedure WlAddGestureRecognizer(Wnd: Pointer; ARec: Integer); cdecl;
begin
end;

procedure WlRemoveGestureRecognizer(Wnd: Pointer; ARec: Integer); cdecl;
begin
end;

function WlShowModal(Wnd: Pointer; Proc: TFmuxModal): Integer; cdecl;
var
  W: TFmuxWindow;
  R: Integer;
begin
  Result := 0;
  W := Win(Wnd);
  if W = nil then
    Exit;
  if GModalStack = nil then
    GModalStack := TList<TFmuxWindow>.Create;
  if (W.Parent = nil) and (W.Kind = TWlWindowKind.Toplevel) then
  begin
    if GModalStack.Count > 0 then
      W.Parent := GModalStack.Last
    else if (GMainWindow <> nil) and (GMainWindow <> W) then
      W.Parent := GMainWindow;
    W.SetTransientParent;
  end;
  GModalStack.Add(W);
  try
    R := 0;
    Disp.RunLoop(
      function: Boolean
      begin
        if not Disp.Windows.Contains(W) then
          Exit(True);
        R := 0;
        Proc(W.FCreate.Data, R);
        Result := R <> 0;
      end);
    Result := R;
  finally
    GModalStack.Remove(W);
  end;
end;

{$ENDREGION}

{$REGION 'Screens and pointer'}

function WlGetScreenSize: TPointF; cdecl;
var
  O: TWlOutput;
begin
  O := Disp.PrimaryOutput;
  if O <> nil then
    Result := PointF(O.LogicalBounds.Width, O.LogicalBounds.Height)
  else
    Result := PointF(1920, 1080);
end;

function WlGetScreenScale: Single; cdecl;
var
  O: TWlOutput;
begin
  O := Disp.PrimaryOutput;
  if O <> nil then
    Result := O.Scale
  else
    Result := 1;
end;

function WlGetDisplayInfo(DisplayInfo: PFmuxDisplayInfo; Index: Integer): Integer; cdecl;
var
  Outs: TArray<TWlOutput>;
begin
  Outs := Disp.OrderedOutputs;
  Result := Max(1, Length(Outs));
  if (DisplayInfo = nil) or (Index < 0) or (Index >= Result) then
    Exit;
  DisplayInfo.Primary := Index = 0;
  if Length(Outs) = 0 then
    DisplayInfo.BoundsRect := Rect(0, 0, 1920, 1080)
  else
    DisplayInfo.BoundsRect := Outs[Index].LogicalBounds;
  DisplayInfo.WorkareaRect := DisplayInfo.BoundsRect;
end;

function WlGetDisplayFromPoint(Point: TPoint): Integer; cdecl;
var
  Outs: TArray<TWlOutput>;
  I: Integer;
begin
  Outs := Disp.OrderedOutputs;
  for I := 0 to High(Outs) do
    if Outs[I].LogicalBounds.Contains(Point) then
      Exit(I);
  Result := -1;
end;

function WlGetDisplayFromWindow(Wnd: Pointer): Integer; cdecl;
var
  Outs: TArray<TWlOutput>;
  O: TWlOutput;
  I: Integer;
begin
  Result := 0;
  if Wnd = nil then
    Exit;
  Outs := Disp.OrderedOutputs;
  O := Win(Wnd).CurrentOutput;
  for I := 0 to High(Outs) do
    if Outs[I] = O then
      Exit(I);
  Result := Max(0, WlGetDisplayFromPoint(Win(Wnd).Origin.Round));
end;

function WlGetMousePos: TPointF; cdecl;
begin
  Result := Disp.PointerScreenPos;
end;

procedure WlSetCursor(Cursor: Integer); cdecl;
begin
  Disp.SetCursor(Cursor);
end;

{$ENDREGION}

{$REGION 'Bitmaps and the paint context'}

function WlBitmapCreate(Width, Height: Integer; Bits: Pointer): Pointer; cdecl;
var
  B: PFmuxBitmap;
begin
  New(B);
  B.Width := Max(0, Width);
  B.Height := Max(0, Height);
  B.OwnsData := Bits = nil;
  if B.OwnsData then
    B.Data := AllocMem(NativeInt(B.Width) * B.Height * 4)
  else
    B.Data := Bits;
  Result := B;
end;

procedure WlBitmapDestroy(Bitmap: Pointer); cdecl;
var
  B: PFmuxBitmap;
begin
  B := Bitmap;
  if B = nil then
    Exit;
  if B.OwnsData then
    FreeMem(B.Data);
  Dispose(B);
end;

procedure WlGetBitmapInfo(Bitmap: Pointer; var Width, Height: Integer; var Data: Pointer); cdecl;
var
  B: PFmuxBitmap;
begin
  B := Bitmap;
  if B = nil then
  begin
    Width := 0;
    Height := 0;
    Data := nil;
    Exit;
  end;
  Width := B.Width;
  Height := B.Height;
  Data := B.Data;
end;

/// Source-over of premultiplied ASrc with opacity AOpacity (0..256) onto ADst.
function Blend(const ADst, ASrc: Cardinal; const AOpacity: Cardinal): Cardinal; inline;
var
  SA, InvA: Cardinal;
  RB, G: Cardinal;
begin
  RB := (((ASrc and $00FF00FF) * AOpacity) shr 8) and $00FF00FF;
  G := (((ASrc shr 8) and $00FF00FF) * AOpacity) and $FF00FF00;
  SA := G shr 24;
  InvA := 255 - SA;
  Result := (RB or G) + ((((ADst and $00FF00FF) * InvA) shr 8) and $00FF00FF) +
    ((((ADst shr 8) and $00FF00FF) * InvA) and $FF00FF00);
end;

procedure WlCanvasDrawBitmap(Ctx, Bitmap: Pointer; Src, Dst: TRectF; Opacity: Single; HighSpeed: Boolean); cdecl;
var
  F: PWlFrame;
  B: PFmuxBitmap;
  DX, DY, DW, DH, SX, SY, SW, SH, X, Y, CX, CY, CW, CH, SrcX, SrcY: Integer;
  DRow, SRow: PCardinal;
  Op: Cardinal;
begin
  F := Ctx;
  B := Bitmap;
  if (F = nil) or (B = nil) or (B.Data = nil) then
    Exit;
  if F.Bits = nil then
  begin
    // External presentation: nothing to copy, but the frame counts as painted.
    F.Drawn := True;
    Exit;
  end;
  // Destination in buffer pixels; source in bitmap pixels.
  DX := Round(Dst.Left * F.Scale);
  DY := Round(Dst.Top * F.Scale);
  DW := Round(Dst.Width * F.Scale);
  DH := Round(Dst.Height * F.Scale);
  SX := Round(Src.Left);
  SY := Round(Src.Top);
  SW := Round(Src.Width);
  SH := Round(Src.Height);
  if (DW <= 0) or (DH <= 0) or (SW <= 0) or (SH <= 0) then
    Exit;
  Op := EnsureRange(Round(Opacity * 256), 0, 256);
  // Clip the destination to the frame.
  CX := Max(DX, 0);
  CY := Max(DY, 0);
  CW := Min(DX + DW, F.Width) - CX;
  CH := Min(DY + DH, F.Height) - CY;
  if (CW <= 0) or (CH <= 0) then
    Exit;
  if (DW = SW) and (DH = SH) and (Op >= 256) then
  begin
    // 1:1 copy (the Skia raster canvas always draws so): rows clipped to the bitmap too.
    SrcX := SX + (CX - DX);
    CW := Min(CW, B.Width - SrcX);
    for Y := CY to CY + CH - 1 do
    begin
      SrcY := SY + (Y - DY);
      if (SrcY < 0) or (SrcY >= B.Height) or (CW <= 0) or (SrcX < 0) then
        Continue;
      Move((PByte(B.Data) + (NativeInt(SrcY) * B.Width + SrcX) * 4)^,
        (PByte(F.Bits) + NativeInt(Y) * F.Stride + CX * 4)^, CW * 4);
    end;
  end
  else
  begin
    // Scaled (nearest neighbour) and/or with opacity.
    for Y := CY to CY + CH - 1 do
    begin
      SrcY := SY + ((Y - DY) * SH) div DH;
      if (SrcY < 0) or (SrcY >= B.Height) then
        Continue;
      SRow := PCardinal(PByte(B.Data) + NativeInt(SrcY) * B.Width * 4);
      DRow := PCardinal(PByte(F.Bits) + NativeInt(Y) * F.Stride + CX * 4);
      for X := CX to CX + CW - 1 do
      begin
        SrcX := SX + ((X - DX) * SW) div DW;
        if (SrcX >= 0) and (SrcX < B.Width) then
        begin
          if Op >= 256 then
            DRow^ := PCardinal(PByte(SRow) + SrcX * 4)^
          else
            DRow^ := Blend(DRow^, PCardinal(PByte(SRow) + SrcX * 4)^, Op);
        end;
        Inc(DRow);
      end;
    end;
  end;
  F.Drawn := True;
end;

{$ENDREGION}

{$REGION 'Clipboard'}

function WlClipboardHasText: Boolean; cdecl;
begin
  Result := Disp.ClipboardHasText;
end;

function WlClipboardGetText: PChar; cdecl;
begin
  // The string lives until the next call (FMX copies it at once).
  GClipboardText := Disp.ClipboardGetText;
  Result := PChar(GClipboardText);
end;

procedure WlClipboardSetText(Text: PChar); cdecl;
begin
  Disp.ClipboardSetText(Text);
end;

function WlClipboardHasImage: Boolean; cdecl;
begin
  Result := False;
end;

procedure WlClipboardGetImage(Data: Pointer; var W, H: Integer); cdecl;
begin
  W := 0;
  H := 0;
end;

function WlClipboardHasCustom(Format: PChar): Boolean; cdecl;
begin
  Result := False;
end;

procedure WlClipboardGetCustom(Format: PChar; Data: Pointer; var Size: Integer); cdecl;
begin
  Size := 0;
end;

{$ENDREGION}

{$REGION 'Input method'}

procedure WlImeEnterControl(Wnd: Pointer; StartProc, ChangedProc, CommitProc: TFmuxImeCommitProc; Rect: TRect;
  Data: Pointer); cdecl;
begin
  // text-input-unstable-v3 is not used yet: characters come from the keyboard (xkbcommon, with compose sequences).
end;

procedure WlImeExitControl(Wnd: Pointer); cdecl;
begin
end;

procedure WlImeSetCaretPos(Value: TPoint); cdecl;
begin
end;

{$ENDREGION}

procedure AssignFmuxApi;
begin
  GDumpDir := GetEnvironmentVariable('FMXWAYLAND_DUMP_DIR');
  FMUX.Api.FmuxInit := WlInit;
  FMUX.Api.FmuxRun := WlRun;
  FMUX.Api.FmuxTerminate := WlTerminate;
  FMUX.Api.FmuxHandleMessage := WlHandleMessage;
  FMUX.Api.FmuxWakeMainThread := WlWakeMainThread;
  FMUX.Api.FmuxCreateTimer := WlCreateTimer;
  FMUX.Api.FmuxDestroyTimer := WlDestroyTimer;
  FMUX.Api.FmuxGetKeyState := WlGetKeyState;
  FMUX.Api.FmuxSetLog := WlSetLog; // partial: FMXWayland logs to stderr itself (FMXWAYLAND_LOG)
  FMUX.Api.FmuxGetVersionInfo := WlGetVersionInfo;
  FMUX.Api.FmuxSetVersionInfo := WlSetVersionInfo;
  FMUX.Api.IsWayland := WlIsWayland;
  FMUX.Api.IsBroadway := WlIsBroadway;

  FMUX.Api.FmuxCreateWindow := WlCreateWindow;
  FMUX.Api.FmuxDestroyWindow := WlDestroyWindow;
  FMUX.Api.FmuxSetMainWindow := WlSetMainWindow;
  FMUX.Api.FmuxShowWindow := WlShowWindow;
  FMUX.Api.FmuxSetWindowState := WlSetWindowState;
  FMUX.Api.FmuxSetWindowTitle := WlSetWindowTitle;
  FMUX.Api.FmuxSetWindowIcon := WlSetWindowIcon; // partial: ignored (no xdg-toplevel-icon yet)
  FMUX.Api.FmuxActivateWindow := WlActivateWindow; // partial: no-op (needs an xdg-activation token)
  FMUX.Api.FmuxWindowBringToFront := WlWindowBringToFront; // partial: no-op on Wayland
  FMUX.Api.FmuxWindowSendToBack := WlWindowSendToBack; // partial: no-op on Wayland
  FMUX.Api.FmuxGetClientSize := WlGetClientSize;
  FMUX.Api.FmuxSetClientSize := WlSetClientSize;
  FMUX.Api.FmuxGetWindowRect := WlGetWindowRect;
  FMUX.Api.FmuxSetWindowRect := WlSetWindowRect; // partial: the position of toplevels is virtual
  FMUX.Api.FmuxInvalidateRect := WlInvalidateRect;
  FMUX.Api.FmuxProcessUpdates := WlProcessUpdates;
  FMUX.Api.FmuxClientToScreen := WlClientToScreen;
  FMUX.Api.FmuxScreenToClient := WlScreenToClient;
  FMUX.Api.FmuxGetWindowScale := WlGetWindowScale;
  FMUX.Api.FmuxGetWindowFullScreen := WlGetWindowFullScreen;
  FMUX.Api.FmuxSetWindowFullScreen := WlSetWindowFullScreen;
  FMUX.Api.FmuxSetCapture := WlSetCapture; // partial: Wayland's implicit grab
  FMUX.Api.FmuxReleaseCapture := WlReleaseCapture; // partial: Wayland's implicit grab
  FMUX.Api.FmuxGetWindowNativeHandle := WlGetWindowNativeHandle; // partial: returns the wl_surface
  FMUX.Api.FmuxGetWindowNativeDrawingHandle := WlGetWindowNativeHandle; // partial: returns the wl_surface
  FMUX.Api.FmuxAddTooltip := WlAddTooltip; // partial: no-op (no native tooltips)
  FMUX.Api.FmuxRemoveTooltip := WlRemoveTooltip; // partial: no-op
  FMUX.Api.FmuxAddGestureRecognizer := WlAddGestureRecognizer; // partial: no-op (no touch gestures yet)
  FMUX.Api.FmuxRemoveGestureRecognizer := WlRemoveGestureRecognizer; // partial: no-op
  FMUX.Api.FmuxShowModal := WlShowModal;

  FMUX.Api.FmuxGetScreenSize := WlGetScreenSize;
  FMUX.Api.FmuxGetScreenScale := WlGetScreenScale;
  FMUX.Api.FmuxGetDisplayInfo := WlGetDisplayInfo; // partial: work area = whole output
  FMUX.Api.FmuxGetDisplayFromWindow := WlGetDisplayFromWindow;
  FMUX.Api.FmuxGetDisplayFromPoint := WlGetDisplayFromPoint;
  FMUX.Api.FmuxGetMousePos := WlGetMousePos; // partial: last position over an own window
  FMUX.Api.FmuxSetCursor := WlSetCursor;

  FMUX.Api.FmuxBitmapCreate := WlBitmapCreate;
  FMUX.Api.FmuxBitmapDestroy := WlBitmapDestroy;
  FMUX.Api.FmuxGetBitmapInfo := WlGetBitmapInfo;
  FMUX.Api.FmuxCanvasDrawBitmap := WlCanvasDrawBitmap;

  FMUX.Api.FmuxClipboardHasText := WlClipboardHasText;
  FMUX.Api.FmuxClipboardGetText := WlClipboardGetText;
  FMUX.Api.FmuxClipboardSetText := WlClipboardSetText;
  FMUX.Api.FmuxClipboardHasImage := WlClipboardHasImage; // partial: no images yet (always False)
  FMUX.Api.FmuxClipboardGetImage := WlClipboardGetImage; // partial: no images yet
  FMUX.Api.FmuxClipboardHasCustom := WlClipboardHasCustom; // partial: no custom formats yet (always False)
  FMUX.Api.FmuxClipboardGetCustom := WlClipboardGetCustom; // partial: no custom formats yet

  FMUX.Api.FmuxImeEnterControl := WlImeEnterControl; // partial: no-op (text-input-v3 not used yet)
  FMUX.Api.FmuxImeExitControl := WlImeExitControl; // partial: no-op
  FMUX.Api.FmuxImeSetCaretPos := WlImeSetCaretPos; // partial: no-op
end;

initialization
  FillChar(GVersionInfo, SizeOf(GVersionInfo), 0);

finalization
  FreeAndNil(GModalStack);
  WlDisconnect;

end.
