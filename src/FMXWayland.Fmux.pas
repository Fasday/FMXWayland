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
/// depends on FMX's canvas. FMX's default Linux canvas (FMX.Canvas.Linux: cairo and Pango, FMXWayland.Cairo) gets a
/// cairo context over the window's retained frame; what changed is then copied into the wl_shm buffer that is
/// attached to the surface. The Skia raster canvas (GlobalUseSkia) gets the PWlFrame, renders into an FMUX bitmap
/// (plain memory) and copies it with FmuxCanvasDrawBitmap into the frame.</para>
/// <para>Dialogs: file dialogs (FmuxFilesDialog: TOpenDialog, TSaveDialog, SelectDirectory) and message dialogs go
/// to the backend of FMXWayland.Dialogs (by default the xdg-desktop-portal FileChooser, FMX's own forms without a
/// portal). While a portal dialog is open the loop keeps running (DialogPump) and the program's windows are blocked
/// as under a modal form (a nil entry on the modal stack); the dialog's parent is the window exported with
/// xdg-foreign.</para>
/// <para>The function list with their status is in docs/FMUX-STATUS.md; gen-fmux-api.ps1 reads the assignments in
/// AssignFmuxApi and FMXWayland.Cairo.AssignCairoApi (a "// partial: ..." comment after an assignment marks a function
/// that is only partly done).</para>
/// </remarks>
unit FMXWayland.Fmux;

interface

/// <summary>Assigns the implemented function pointers of FMUX.Api (called by the generated FMUX.Api.LoadLib after it
/// has assigned the stubs).</summary>
procedure AssignFmuxApi;

implementation

uses
  System.SysUtils, System.Types, System.Classes, System.UITypes, System.Math, System.Messaging,
  System.Generics.Collections, FMX.Types, FMX.Graphics, FMX.Forms, FMX.Controls, FMX.Dialogs, FMX.DialogHelper,
  FMX.Platform, FMX.Platform.Linux, FMUX.Api,
  FMXWayland.Log, FMXWayland.Posix, FMXWayland.Platform, FMXWayland.Native, FMXWayland.Frame,
  FMXWayland.SystemFont, FMXWayland.Cairo, FMXWayland.DBus, FMXWayland.DialogTypes, FMXWayland.Dialogs,
  FMXWayland.Backend, FMXWayland.X11;

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
    // FMX's cairo canvas paints into FRetained, the window's latest frame (buffer pixels, no row padding); the
    // wl_shm buffers rotate and hold older frames, so each gets what changed since the frame it holds.
    FRetained: TArray<Cardinal>;
    FRetainedWidth: Integer;
    FRetainedHeight: Integer;
    FRetainedSerial: Int64;
    FDamage: array[0..7] of TRect;
    FBufferSerials: TArray<TPair<Pointer, Int64>>;
    // IFMXWaylandWindowFrame.SetFrameListener (released with the window).
    FFrameListener: IFMXWaylandWindowFrameListener;
    // The client size FMX was last told about (ReportBounds).
    FReportedWidth: Integer;
    FReportedHeight: Integer;
    function Form: TCommonCustomForm;
    function WindowRect: TRectF;
    procedure SetWindowRect(const ARect: TRectF);
    procedure ReportBounds;
    procedure DumpFrame(const AFrame: PWlFrame);
    procedure PaintCairo(const AFrame: PWlFrame; const ADirty: TRectF);
    procedure CopyRetained(const AFrame: PWlFrame; const ARect: TRect);
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
    procedure DoFrameChanged; override;
  end;

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

  /// <summary>IFMXWaylandWindowFrame, registered as a platform service: the window frame of toplevels for programs
  /// that draw their own title bar.</summary>
  TWindowFrameService = class(TInterfacedObject, IFMXWaylandWindowFrame)
  private
    function ToplevelOf(const AHandle: TWindowHandle): TFmuxWindow;
  public
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

{$SCOPEDENUMS ON}
  /// <summary>FMX's default canvas: its cairo canvas (FMX.Canvas.Linux) or another (Skia, a GPU canvas).</summary>
  TFmuxCanvasKind = (Unknown, Cairo, Other);
{$SCOPEDENUMS OFF}

var
  GWakeProc: TFmuxWakeMainThreadProc = nil;
  GMainWindow: TFmuxWindow = nil;
  // The windows of the modal loops, innermost last; nil for a dialog of another client (a portal's).
  GModalStack: TList<TFmuxWindow> = nil;
  // For each open portal dialog: the window exported as its parent (nil: none).
  GDialogParents: TList<TFmuxWindow> = nil;
  GVersionInfo: TFmuxVersionInfo;
  GClipboardText: string;
  GDumpDir: string;
  GNativeServiceRegistered: Boolean = False;
  GCanvasKind: TFmuxCanvasKind = TFmuxCanvasKind.Unknown;

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

/// Input goes to the top modal window and to popups only while a modal loop runs (none of the program's windows
/// while another client's dialog is on top).
function InputAllowed(const AWindow: TWlWindow): Boolean;
begin
  Result := (GModalStack = nil) or (GModalStack.Count = 0) or (AWindow = GModalStack.Last) or
    (AWindow.Kind = TWlWindowKind.Popup);
end;

/// The window of the innermost modal form (other clients' dialogs skipped), or nil.
function TopModalWindow: TFmuxWindow;
var
  I: Integer;
begin
  Result := nil;
  if GModalStack <> nil then
    for I := GModalStack.Count - 1 downto 0 do
      if GModalStack[I] <> nil then
        Exit(GModalStack[I]);
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

type
  /// <summary>Access to the protected steps of TCommonCustomForm.SetBounds.</summary>
  TFormAccess = class(TCommonCustomForm);

procedure TFmuxWindow.ReportBounds;
var
  R: TRectF;
  F: TCommonCustomForm;
  SameSize, ClientChanged: Boolean;
begin
  if not Assigned(FCreate.BoundsChanged) then
    Exit;
  R := WindowRect;
  F := Form;
  SameSize := (F <> nil) and (R.Truncate.Width = F.Width) and (R.Truncate.Height = F.Height);
  ClientChanged := (Width <> FReportedWidth) or (Height <> FReportedHeight);
  FReportedWidth := Width;
  FReportedHeight := Height;
  FCreate.BoundsChanged(FCreate.Data, R);
  if SameSize and ClientChanged and (F.Handle <> nil) then
    try
      // FMX resizes its canvas and realigns only when its window rectangle changes size. Here the client area
      // changed in a window of the same size (the decorations came or went): the steps of SetBounds for a new size.
      TFormAccess(F).ResizeHandle;
      TFormAccess(F).Resize;
      TMessageManager.DefaultManager.SendMessage(F, TSizeChangedMessage.Create(TSize.Create(F.Width, F.Height)));
    except
      Application.HandleException(F);
    end;
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

/// True when FMX draws with its cairo canvas (FMX.Canvas.Linux: GlobalUseSkia is False).
function DefaultCanvasIsCairo: Boolean;
var
  C: TClass;
begin
  if GCanvasKind = TFmuxCanvasKind.Unknown then
  begin
    C := TCanvasManager.DefaultCanvas;
    if C = nil then
      Exit(False);
    GCanvasKind := TFmuxCanvasKind.Other;
    while C <> nil do
    begin
      if C.ClassName = 'TLinuxCanvas' then
        GCanvasKind := TFmuxCanvasKind.Cairo;
      C := C.ClassParent;
    end;
  end;
  Result := GCanvasKind = TFmuxCanvasKind.Cairo;
end;

procedure TFmuxWindow.DoPaint(const AFrame: PWlFrame; const ADirty: TRectF);
var
  R: TRectF;
begin
  if not Assigned(FCreate.PaintCallback) then
    Exit;
  if DefaultCanvasIsCairo then
    PaintCairo(AFrame, ADirty)
  else
  begin
    // The Skia raster canvas renders the whole window and copies it into the frame (FmuxCanvasDrawBitmap).
    R := ADirty;
    FCreate.PaintCallback(FCreate.Data, AFrame, PRectFArray(@R), 1);
  end;
  if (GDumpDir <> '') and AFrame.Drawn then
    DumpFrame(AFrame);
end;

procedure TFmuxWindow.PaintCairo(const AFrame: PWlFrame; const ADirty: TRectF);
var
  D: TRect;
  R: TRectF;
  Context: Pointer;
  Held, Serial: Int64;
  I: Integer;
begin
  if AFrame.Bits = nil then
    Exit;
  if (FRetainedWidth <> AFrame.Width) or (FRetainedHeight <> AFrame.Height) then
  begin
    FRetained := nil;
    SetLength(FRetained, NativeInt(AFrame.Width) * AFrame.Height);
    FRetainedWidth := AFrame.Width;
    FRetainedHeight := AFrame.Height;
    FBufferSerials := nil;
    // A new frame holds nothing yet: FMX paints all of it.
    D := Rect(0, 0, AFrame.Width, AFrame.Height);
  end
  else
  begin
    // Whole buffer pixels, the ones Wayland is told are damaged: FMX also repaints the controls that touch a
    // partly covered pixel.
    D := Rect(Floor(ADirty.Left * AFrame.Scale), Floor(ADirty.Top * AFrame.Scale), Ceil(ADirty.Right * AFrame.Scale),
      Ceil(ADirty.Bottom * AFrame.Scale));
    D.Intersect(Rect(0, 0, AFrame.Width, AFrame.Height));
  end;
  R := RectF(D.Left / AFrame.Scale, D.Top / AFrame.Scale, D.Right / AFrame.Scale, D.Bottom / AFrame.Scale);
  try
    Context := CreateCairoFrame(@FRetained[0], AFrame.Width, AFrame.Height, AFrame.Width * 4, AFrame.Scale);
  except
    on E: Exception do
    begin
      WlLogOnce('cairo', E.Message);
      Exit;
    end;
  end;
  try
    FCreate.PaintCallback(FCreate.Data, Context, PRectFArray(@R), 1);
  finally
    DestroyCairoFrame(Context);
  end;
  Inc(FRetainedSerial);
  FDamage[FRetainedSerial mod Length(FDamage)] := D;
  // The buffer holds the frame it was last given (Held), or nothing known: copy what changed since then.
  Held := 0;
  for I := 0 to High(FBufferSerials) do
    if FBufferSerials[I].Key = AFrame.Bits then
      Held := FBufferSerials[I].Value;
  if (Held <= 0) or (FRetainedSerial - Held > Length(FDamage)) then
    CopyRetained(AFrame, Rect(0, 0, AFrame.Width, AFrame.Height))
  else
    for Serial := Held + 1 to FRetainedSerial do
      CopyRetained(AFrame, FDamage[Serial mod Length(FDamage)]);
  I := High(FBufferSerials);
  while (I >= 0) and (FBufferSerials[I].Key <> AFrame.Bits) do
    Dec(I);
  if I < 0 then
  begin
    // Buffers are freed only when the size changes (FBufferSerials starts again then); a few are alive at a time.
    if Length(FBufferSerials) >= 8 then
      Delete(FBufferSerials, 0, 1);
    FBufferSerials := FBufferSerials + [TPair<Pointer, Int64>.Create(AFrame.Bits, FRetainedSerial)];
  end
  else
    FBufferSerials[I].Value := FRetainedSerial;
  AFrame.Drawn := True;
end;

procedure TFmuxWindow.CopyRetained(const AFrame: PWlFrame; const ARect: TRect);
var
  R: TRect;
  Y: Integer;
begin
  R := ARect;
  R.Intersect(Rect(0, 0, Min(AFrame.Width, FRetainedWidth), Min(AFrame.Height, FRetainedHeight)));
  if R.IsEmpty then
    Exit;
  for Y := R.Top to R.Bottom - 1 do
    Move(FRetained[NativeInt(Y) * FRetainedWidth + R.Left],
      (PByte(AFrame.Bits) + NativeInt(Y) * AFrame.Stride + R.Left * 4)^, R.Width * 4);
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
  // A window below a modal one that the compositor activates (the user clicked it) stays inactive for FMX; the modal
  // window asks to be activated instead, as on other platforms (a portal's dialog is the compositor's business).
  if AActive and not InputAllowed(Self) then
  begin
    if GModalStack.Last <> nil then
      GModalStack.Last.Activate;
    Exit;
  end;
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
    // As FMX's Windows platform does for WM_DPICHANGED: the form's canvas (and a TForm3D's context) is made again,
    // since a canvas takes the window's scale when it is made. A new window often starts at the output's integer
    // scale and gets the fractional one a moment later: FastCanvas, which sizes its frames by the buffer, drew them
    // at the scale before (a form at 2 in a buffer of 1.5).
    F.RecreateResources;
    TMessageManager.DefaultManager.SendMessage(nil, TScaleChangedMessage.Create(F));
  except
    Application.HandleException(F);
  end;
end;

procedure TFmuxWindow.DoFrameChanged;
var
  F: TCommonCustomForm;
  L: IFMXWaylandWindowFrameListener;
begin
  WlLog(TWlLogLevel.Debug, 'frame of "%s": states $%x capabilities $%x', [Title, StateBits, CapabilityBits]);
  L := FFrameListener;
  F := Form;
  if (L = nil) or (F = nil) or (F.Handle = nil) then
    Exit;
  try
    L.WindowFrameChanged(F.Handle, StateBits, CapabilityBits);
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

{$REGION 'TWindowFrameService'}

function TWindowFrameService.ToplevelOf(const AHandle: TWindowHandle): TFmuxWindow;
var
  P: Pointer;
begin
  Result := nil;
  if (AHandle is TLinuxWindowHandle) and (WlDisplay <> nil) then
  begin
    P := TLinuxWindowHandle(AHandle).Window;
    if (P <> nil) and WlDisplay.Windows.Contains(TWlWindow(P)) and
      (TWlWindow(P).Kind = TWlWindowKind.Toplevel) then
      Result := TFmuxWindow(P);
  end;
end;

procedure TWindowFrameService.SetDecorated(const AHandle: TWindowHandle; const AValue: Boolean);
var
  W: TFmuxWindow;
begin
  W := ToplevelOf(AHandle);
  if W <> nil then
    W.SetDecorated(AValue);
end;

function TWindowFrameService.GetDecorated(const AHandle: TWindowHandle): Boolean;
var
  W: TFmuxWindow;
begin
  W := ToplevelOf(AHandle);
  Result := (W <> nil) and W.HasDecorations;
end;

function TWindowFrameService.BeginMove(const AHandle: TWindowHandle): Boolean;
var
  W: TFmuxWindow;
begin
  W := ToplevelOf(AHandle);
  Result := (W <> nil) and W.BeginMove;
end;

function TWindowFrameService.BeginResize(const AHandle: TWindowHandle; const AEdges: Cardinal): Boolean;
var
  W: TFmuxWindow;
begin
  W := ToplevelOf(AHandle);
  Result := (W <> nil) and W.BeginResize(AEdges);
end;

function TWindowFrameService.ShowWindowMenu(const AHandle: TWindowHandle; const AClientPoint: TPointF): Boolean;
var
  W: TFmuxWindow;
begin
  W := ToplevelOf(AHandle);
  // Client coordinates are the surface's (the client-side decorations are a subsurface around it).
  Result := (W <> nil) and W.ShowWindowMenu(Round(AClientPoint.X), Round(AClientPoint.Y));
end;

procedure TWindowFrameService.Minimize(const AHandle: TWindowHandle);
var
  W: TFmuxWindow;
begin
  W := ToplevelOf(AHandle);
  if W <> nil then
    W.Minimize;
end;

procedure TWindowFrameService.SetMaximized(const AHandle: TWindowHandle; const AValue: Boolean);
var
  W: TFmuxWindow;
begin
  W := ToplevelOf(AHandle);
  if W <> nil then
    W.SetMaximized(AValue);
end;

function TWindowFrameService.GetStates(const AHandle: TWindowHandle): Cardinal;
var
  W: TFmuxWindow;
begin
  W := ToplevelOf(AHandle);
  if W <> nil then
    Result := W.StateBits
  else
    Result := 0;
end;

function TWindowFrameService.GetCapabilities(const AHandle: TWindowHandle): Cardinal;
var
  W: TFmuxWindow;
begin
  W := ToplevelOf(AHandle);
  if W <> nil then
    Result := W.CapabilityBits
  else
    Result := 0;
end;

procedure TWindowFrameService.SetFrameListener(const AHandle: TWindowHandle;
  const AListener: IFMXWaylandWindowFrameListener);
var
  W: TFmuxWindow;
begin
  W := ToplevelOf(AHandle);
  if W = nil then
    Exit;
  W.FFrameListener := AListener;
  if AListener <> nil then
    AListener.WindowFrameChanged(AHandle, W.StateBits, W.CapabilityBits);
end;

{$ENDREGION}

{$REGION 'Application'}

procedure WlInit(Flags: Integer); cdecl;
var
  Services: TPlatformServices;
begin
  try
    WlConnect;
  except
    on E: Exception do
    begin
      if not AllowX11Fallback then
      begin
        WlLog(TWlLogLevel.Error, E.Message);
        Halt(1);
      end;
      WlLog(TWlLogLevel.Warning, 'Wayland unavailable: %s; trying X11', [E.Message]);
      AssignX11Api;
      FMUX.Api.FmuxInit(Flags);
      Exit;
    end;
  end;
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
    TPlatformServices.Current.AddPlatformService(IFMXWaylandWindowFrame, TWindowFrameService.Create);
    // TFont's default family and size (FMX falls back to Tahoma without it), unless someone registered one.
    Services := TPlatformServices.Current;
    if not Services.SupportsPlatformService(IFMXSystemFontService) then
      Services.AddPlatformService(IFMXSystemFontService, TSystemFontService.Create);
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
  W.FReportedWidth := W.Width;
  W.FReportedHeight := W.Height;
  WlLog(TWlLogLevel.Debug, 'CreateWindow %p "%s" popup %s %.0f,%.0f %.0fx%.0f', [Pointer(W), W.Title,
    BoolToStr(CreateStruct.Popup, True), CreateStruct.X, CreateStruct.Y, CreateStruct.Width, CreateStruct.Height]);
  Result := W;
end;

procedure WlDestroyWindow(Wnd: Pointer); cdecl;
var
  W: TFmuxWindow;
  I: Integer;
begin
  W := Win(Wnd);
  if W = nil then
    Exit;
  if GMainWindow = W then
    GMainWindow := nil;
  if GModalStack <> nil then
    GModalStack.Remove(W);
  // Its export for a portal dialog ends with it.
  if GDialogParents <> nil then
    for I := 0 to GDialogParents.Count - 1 do
      if GDialogParents[I] = W then
        GDialogParents[I] := nil;
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
        // Its form is not on the screen yet (a popup opened in FormCreate or OnShow): the popup waits for it
        // (TWlWindow.Show).
        if (P <> nil) and (P <> Pointer(AWindow)) and Disp.Windows.Contains(TWlWindow(P)) then
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
  // Wayland clients cannot raise or focus windows themselves: an xdg-activation token tied to the last input event.
  if Wnd <> nil then
    Win(Wnd).Activate;
end;

procedure WlWindowBringToFront(Wnd: Pointer); cdecl;
begin
  if Wnd <> nil then
    Win(Wnd).Activate;
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
    if TopModalWindow <> nil then
      W.Parent := TopModalWindow
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
  // FMX's cairo canvas (its window and bitmap contexts); the Skia raster canvas passes the frame.
  if IsCairoContext(Ctx) then
  begin
    CairoDrawBitmap(Ctx, Bitmap, Src, Dst, Opacity, HighSpeed);
    Exit;
  end;
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

{$REGION 'Dialogs'}

const
  CDialogButtonBits: array[TMsgDlgBtn] of Integer = (FMUX_BTN_Yes, FMUX_BTN_No, FMUX_BTN_OK, FMUX_BTN_Cancel,
    FMUX_BTN_Abort, FMUX_BTN_Retry, FMUX_BTN_Ignore, FMUX_BTN_All, FMUX_BTN_NoToAll, FMUX_BTN_YesToAll,
    FMUX_BTN_Help, FMUX_BTN_Close);

function WlMessageDialog(AMessage: PChar; DlgType, Buttons: Integer): Integer; cdecl;
var
  Btns: TMsgDlgButtons;
  B, Default: TMsgDlgBtn;
begin
  // FMX passes no default button: the first affirmative one is.
  Btns := [];
  for B := Low(TMsgDlgBtn) to High(TMsgDlgBtn) do
    if Buttons and CDialogButtonBits[B] <> 0 then
      Include(Btns, B);
  if Btns = [] then
    Btns := [TMsgDlgBtn.mbOK];
  Default := TMsgDlgBtn.mbOK;
  for B in [TMsgDlgBtn.mbOK, TMsgDlgBtn.mbYes, TMsgDlgBtn.mbRetry, TMsgDlgBtn.mbIgnore, TMsgDlgBtn.mbClose] do
    if B in Btns then
    begin
      Default := B;
      Break;
    end;
  // The backend's message dialog: by default FMX's own dialog form (FMX.DialogHelper), modal.
  Result := GetWaylandDialogBackend.MessageDialog(string(AMessage),
    TMsgDlgType(EnsureRange(DlgType, Ord(Low(TMsgDlgType)), Ord(High(TMsgDlgType)))), Btns, Default);
end;

function WlInputQuery(ACaption, APromt, AValue: PChar; MaxLength: Integer): Boolean; cdecl;
var
  Values: TArray<string>;
begin
  // FMX's own input queries use its form directly; this serves direct callers. MaxLength counts the NUL.
  Values := [string(AValue)];
  Result := GetWaylandDialogBackend.InputQuery(string(ACaption), [string(APromt)], Values);
  if Result and (AValue <> nil) and (MaxLength > 0) and (Length(Values) = 1) then
    StrPLCopy(AValue, Values[0], MaxLength - 1);
end;

/// The filters of an FMX filter string: "name|patterns|name|patterns..." with patterns separated by ';'.
function ParseFilter(const AFilter: string): TArray<TWaylandFileFilter>;
var
  Parts, Patterns: TArray<string>;
  Pattern: string;
  F: TWaylandFileFilter;
  I: Integer;
begin
  Result := nil;
  if AFilter.Trim = '' then
    Exit;
  Parts := AFilter.Split(['|']);
  I := 0;
  while I < Length(Parts) do
  begin
    Patterns := nil;
    if I + 1 < Length(Parts) then
      for Pattern in Parts[I + 1].Split([';']) do
        if Pattern.Trim <> '' then
          Patterns := Patterns + [Pattern.Trim];
    if Patterns = nil then
      Patterns := ['*'];
    F.Name := Parts[I].Trim;
    if F.Name = '' then
      F.Name := string.Join(';', Patterns);
    F.Patterns := Patterns;
    Result := Result + [F];
    Inc(I, 2);
  end;
end;

function WlFilesDialog(Title, Filter, InitialName, InitialDir, Files: PChar; MaxLength: Integer;
  var FilterIndex: Integer; AOptions: Integer): Boolean; cdecl;
var
  Request: TWaylandFileDialogRequest;
  Chosen: TArray<string>;
  Text, Next: string;
  Index, Kept, I: Integer;
begin
  // FMX (TPlatformLinux.DialogOpenFiles/DialogSaveFiles) passes a buffer of MaxLength characters (with the NUL) and
  // reads it as text, one file per line; FilterIndex is one based both ways.
  Result := False;
  if (Files = nil) or (MaxLength <= 0) then
    Exit;
  Files^ := #0;
  if AOptions and FMUX_FilesDialog_SAVE <> 0 then
    Request.Kind := TWaylandFileDialogKind.SaveFile
  else if AOptions and FMUX_FilesDialog_FOLDER <> 0 then
    Request.Kind := TWaylandFileDialogKind.SelectFolder
  else
    Request.Kind := TWaylandFileDialogKind.OpenFile;
  Request.Title := string(Title);
  Request.InitialFile := string(InitialName);
  Request.InitialFolder := string(InitialDir);
  Request.Filters := ParseFilter(string(Filter));
  Request.FilterIndex := FilterIndex;
  Request.Multiple := (AOptions and FMUX_FilesDialog_MULTY <> 0) and
    (Request.Kind <> TWaylandFileDialogKind.SaveFile);
  Request.ConfirmOverwrite := AOptions and FMUX_FilesDialog_OVERWRITE <> 0;
  WlLog(TWlLogLevel.Debug, 'files dialog kind %d "%s" filter "%s" name "%s" folder "%s" options $%x',
    [Ord(Request.Kind), Request.Title, string(Filter), Request.InitialFile, Request.InitialFolder, AOptions]);
  Index := FilterIndex;
  if not GetWaylandDialogBackend.FileDialog(Request, Chosen, Index) or (Chosen = nil) then
    Exit;
  // Whole names only: what does not fit into FMX's buffer is left out (and logged).
  Text := '';
  Kept := 0;
  for I := 0 to High(Chosen) do
  begin
    if Kept = 0 then
      Next := Chosen[I]
    else
      Next := Text + sLineBreak + Chosen[I];
    if Length(Next) >= MaxLength then
      Break;
    Text := Next;
    Inc(Kept);
  end;
  if Kept < Length(Chosen) then
    WlLog(TWlLogLevel.Warning, 'files dialog: %d of %d names fit into FMX''s buffer of %d characters',
      [Kept, Length(Chosen), MaxLength]);
  if Kept = 0 then
    Exit;
  Move(PChar(Text)^, Files^, Length(Text) * SizeOf(Char));
  Files[Length(Text)] := #0;
  FilterIndex := Index;
  Result := True;
end;

/// Waits for AFd (the portal's D-Bus connection) the way a modal form waits: the loop goes on (events, timers,
/// painting, FMX's idle processing) until AFd is readable, ATimeoutMs pass or the application terminates (False).
function DialogPump(const AFd, ATimeoutMs: Integer): Boolean;
var
  D: TWlDisplay;
  Ready: Boolean;
  Watch: NativeInt;
  Deadline, Left: Int64;
begin
  D := Disp;
  Ready := False;
  Watch := D.AddFdWatch(AFd, POLLIN,
    procedure
    begin
      Ready := True;
    end);
  try
    Deadline := MonotonicMs + ATimeoutMs;
    while not Ready and not D.Terminated do
    begin
      if not D.ProcessEvents(0) then
      begin
        if Assigned(D.IdleProc) then
          D.IdleProc();
        Left := Deadline - MonotonicMs;
        if Ready or D.Terminated or (Left <= 0) then
          Break;
        D.ProcessEvents(Integer(Left));
      end;
      if MonotonicMs >= Deadline then
        Break;
    end;
  finally
    D.RemoveFdWatch(Watch);
  end;
  Result := not D.Terminated;
end;

/// The toplevel a dialog opened now belongs to: the innermost modal form, else the focused window (the toplevel of
/// a focused popup), else the main window.
function DialogOwner: TFmuxWindow;
var
  W: TWlWindow;
begin
  Result := TopModalWindow;
  if Result <> nil then
    Exit;
  W := Disp.KeyboardWindow;
  if W = nil then
    W := Disp.LastInputWindow;
  while (W <> nil) and (W.Kind = TWlWindowKind.Popup) do
    W := W.Parent;
  if (W <> nil) and Disp.Windows.Contains(W) and W.Visible then
    Exit(TFmuxWindow(W));
  Result := GMainWindow;
end;

/// A portal dialog opens: the program's windows take no input meanwhile, as under a modal form; its owner is
/// exported with xdg-foreign so that the portal can make its dialog a child of it ('' without xdg-foreign).
function DialogBeginModal: string;
var
  W: TFmuxWindow;
  Handle: string;
begin
  if GModalStack = nil then
    GModalStack := TList<TFmuxWindow>.Create;
  if GDialogParents = nil then
    GDialogParents := TList<TFmuxWindow>.Create;
  W := DialogOwner;
  GModalStack.Add(nil);
  Handle := '';
  if W <> nil then
    Handle := W.ExportToplevel;
  if Handle <> '' then
  begin
    GDialogParents.Add(W);
    Result := 'wayland:' + Handle;
  end
  else
  begin
    GDialogParents.Add(nil);
    Result := '';
  end;
end;

/// The portal dialog of the last DialogBeginModal is closed.
procedure DialogEndModal;
var
  W: TFmuxWindow;
  I: Integer;
begin
  if (GDialogParents <> nil) and (GDialogParents.Count > 0) then
  begin
    W := GDialogParents.Last;
    GDialogParents.Delete(GDialogParents.Count - 1);
    if W <> nil then
      W.UnexportToplevel;
  end;
  if GModalStack <> nil then
    for I := GModalStack.Count - 1 downto 0 do
      if GModalStack[I] = nil then
      begin
        GModalStack.Delete(I);
        Break;
      end;
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
  FMUX.Api.FmuxActivateWindow := WlActivateWindow; // partial: xdg-activation request (compositor decides)
  FMUX.Api.FmuxWindowBringToFront := WlWindowBringToFront; // partial: xdg-activation request (compositor decides)
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

  FMUX.Api.FmuxMessageDialog := WlMessageDialog; // partial: FMX's own dialog form (or the dialog backend's)
  FMUX.Api.FmuxInputQuery := WlInputQuery; // partial: the dialog backend's (FMX uses its own form anyway)
  FMUX.Api.FmuxFilesDialog := WlFilesDialog;
  ConfigureWaylandDialogHooks(DialogPump, DialogBeginModal, DialogEndModal);

  FMUX.Api.FmuxImeEnterControl := WlImeEnterControl; // partial: no-op (text-input-v3 not used yet)
  FMUX.Api.FmuxImeExitControl := WlImeExitControl; // partial: no-op
  FMUX.Api.FmuxImeSetCaretPos := WlImeSetCaretPos; // partial: no-op
  AssignCairoApi;
  if PreferX11 then
    AssignX11Api;
end;

initialization
  FillChar(GVersionInfo, SizeOf(GVersionInfo), 0);

finalization
  FreeAndNil(GDialogParents);
  FreeAndNil(GModalStack);
  WlDisconnect;

end.
