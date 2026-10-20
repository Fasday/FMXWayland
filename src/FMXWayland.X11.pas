{ FMXWayland: native X11 fallback for Delphi FireMonkey.
  Copyright (c) 2026 Fasday. MIT license, see LICENSE. }
unit FMXWayland.X11;

interface

/// <summary>Replaces the display-dependent FMUX functions; bitmap, canvas and dialog functions are shared.
/// Safe during FMUX.Api.LoadLib: does not connect or register FMX services.</summary>
procedure AssignX11Api;

implementation

uses
  System.SysUtils, System.Types, System.Classes, System.Math, System.UITypes,
  System.Generics.Collections,
  Posix.Stdlib, Posix.Unistd, FMUX.Api, FMX.Types, FMX.Graphics, FMX.Forms, FMX.Platform, FMX.Platform.Linux,
  FMXWayland.Xlib, FMXWayland.Posix, FMXWayland.Platform, FMXWayland.Cairo, FMXWayland.Keys,
  FMXWayland.Xkb, FMXWayland.Log, FMXWayland.Dialogs, FMXWayland.SystemFont, FMXWayland.Frame;

type
  TXWindow = class
    ID: TXID;
    Parent: TXWindow;
    PopupSerial: UInt64;
    NativeAncestors: TArray<TXID>;
    OriginDirty: Boolean;
    CreateInfo: TFmuxCreateStruct;
    Bounds: TRectF;
    Visible, Dirty, Painting, FullScreen: Boolean;
    State: TFmuxWindowState;
    Pixels: TArray<Cardinal>;
    PixelWidth, PixelHeight: Integer;
    GC: Pointer;
    Visual: Pointer;
    Depth: Integer;
    Colormap: TXID;
    Transparent, HasAlpha, UseShape: Boolean;
    Decorated, ManualMaximized: Boolean;
    RestoreBounds: TRectF;
    FrameHandle: TWindowHandle;
    FrameListener: IFMXWaylandWindowFrameListener;
    Shape: TXRectangles;
    function FrameStates: Cardinal;
    procedure NotifyFrame;
    procedure UpdateShape(const Data: TArray<Cardinal>; Width, Height: Integer);
    procedure Paint;
    destructor Destroy; override;
  end;
  TXWindowRef = record
    Window: TXWindow;
    ID: TXID;
  end;
  TXTimer = record
    Interval: Integer;
    Due: Int64;
    Proc: TFmuxTimerProc;
    Data, Code: Pointer;
  end;
  TXTransfer = record
    Requestor, Prop, Target: TXID;
    Text: TBytes;
    Offset: Integer;
    Deadline: Int64;
  end;
  TXFrameService = class(TInterfacedObject, IFMXWaylandWindowFrame)
  private
    function WindowOf(const Handle: TWindowHandle): TXWindow;
    function StartDrag(const Handle: TWindowHandle; Edges: Cardinal): Boolean;
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
  TXFrameDrag = record
    Window: TXWindow;
    Edges: Cardinal;
    StartPoint: TPointF;
    Bounds: TRectF;
    Started, Native: Boolean;
  end;

const
  CEventMask = (1 shl 0) or (1 shl 1) or (1 shl 2) or (1 shl 3) or (1 shl 5) or
    (1 shl 6) or (1 shl 15) or (1 shl 17) or (1 shl 21) or (1 shl 22);
  CRootMask = (1 shl 19) or (1 shl 20);

var
  GDisplay: Pointer;
  GScreen: Integer;
  GScreenWidth, GScreenHeight: Cardinal;
  GRoot, GSelectionWindow, GCursor: TXID;
  GCursorShape: Cardinal;
  GWindows: TList<TXWindow>;
  GModal: TList<TXWindow>;
  GTimers: TDictionary<NativeInt, TXTimer>;
  GNextTimer: NativeInt;
  GMain, GFocus, GActive, GPopup: TXWindow;
  GFocusDirty: Boolean;
  GOriginsDirty: Boolean;
  GGrabWindow: TXWindow;
  GGrabIsPopup: Boolean;
  GQuit: Boolean;
  GWakeFd: Integer = -1;
  GWakeProc: TFmuxWakeMainThreadProc;
  GIdle: TFmuxIdleProc;
  GClipboard, GReceived: string;
  GSelectionDone, GSelectionBusy: Boolean;
  GSelectionIncr: Boolean;
  GSelectionProperty: TXID;
  GReadWindow: TXID;
  GSelectionBytes: TBytes;
  GTransfers: TList<TXTransfer>;
  GPreviousErrorHandler: Pointer;
  GContext: PXkbContext;
  GComposeTable: PXkbComposeTable;
  GCompose: PXkbComposeState;
  GLastClickTime: NativeUInt;
  GLastClickWindow: TXID;
  GLastClickButton: Cardinal;
  GLastClickPos: TPoint;
  GInputState: Integer;
  GLeftPressed: Boolean;
  GPressWindow: TXWindow;
  GPressPoint: TPointF;
  GFrameDrag: TXFrameDrag;
  GWMAtoms: TArray<TXID>;
  GWMAtomsLoaded: Boolean;
  GPopupSerial: UInt64;

procedure EndFrameDrag(Notify: Boolean = True); forward;
function HandleFrameDrag(const E: TXEvent): Boolean; forward;
procedure XDestroyWindowFmux(Wnd: Pointer); cdecl; forward;
procedure Disconnect; forward;

function Atom(const Name: UTF8String): TXID;
begin
  Result := XInternAtom(GDisplay, PAnsiChar(Name), 0);
end;

function Alive(W: TXWindow): Boolean;
begin
  Result := (W <> nil) and (GWindows <> nil) and GWindows.Contains(W);
end;

function SameWindow(W: TXWindow; ID: TXID): Boolean;
begin
  // A callback can free a window and allocate its replacement at exactly the same Pascal address.
  Result := Alive(W) and (W.ID = ID);
end;

function WindowSnapshot: TArray<TXWindowRef>;
var
  I: Integer;
begin
  SetLength(Result, GWindows.Count);
  for I := 0 to GWindows.Count - 1 do
  begin
    Result[I].Window := GWindows[I];
    Result[I].ID := GWindows[I].ID;
  end;
end;

function FindWindow(ID: TXID): TXWindow;
var
  W: TXWindow;
begin
  for W in GWindows do
    if W.ID = ID then
      Exit(W);
  Result := nil;
end;

function HasAncestor(W: TXWindow; ID: TXID): Boolean;
var
  Ancestor: TXID;
begin
  for Ancestor in W.NativeAncestors do
    if Ancestor = ID then Exit(True);
  Result := False;
end;

procedure WatchAncestors(W: TXWindow);
var
  Node, Root, Parent: TXID;
  Children: Pointer;
  Count: Cardinal;
begin
  W.NativeAncestors := nil;
  Node := W.ID;
  while True do
  begin
    Children := nil;
    if XQueryTree(GDisplay, Node, @Root, @Parent, @Children, @Count) = 0 then Break;
    if Children <> nil then XFree(Children);
    if (Parent = 0) or (Parent = GRoot) then Break;
    W.NativeAncestors := W.NativeAncestors + [Parent];
    // Moving a WM frame changes our root origin even if the WM sends no synthetic client ConfigureNotify.
    // StructureNotify can be selected by multiple clients; never request the WM's exclusive redirect mask.
    if FindWindow(Parent) <> nil then XSelectInput(GDisplay, Parent, CEventMask)
    else XSelectInput(GDisplay, Parent, 1 shl 17);
    Node := Parent;
  end;
  W.OriginDirty := True;
  GOriginsDirty := True;
end;

procedure SetClientOrigin(W: TXWindow; X, Y: Integer);
var
  R: TRectF;
begin
  W.OriginDirty := False;
  if (W.Bounds.Left = X) and (W.Bounds.Top = Y) then Exit;
  R := W.Bounds;
  R.Offset(X - R.Left, Y - R.Top);
  WlLog(TWlLogLevel.Trace, 'X11 origin $%x: %d,%d', [W.ID, X, Y]);
  W.Bounds := R;
  if Assigned(W.CreateInfo.BoundsChanged) then W.CreateInfo.BoundsChanged(W.CreateInfo.Data, R);
end;

procedure RefreshOrigins;
var
  W: TXWindow;
  Ref: TXWindowRef;
  X, Y: Integer;
  Child: TXID;
begin
  if not GOriginsDirty then Exit;
  GOriginsDirty := False;
  for Ref in WindowSnapshot do
  begin
    W := Ref.Window;
    if SameWindow(W, Ref.ID) and W.OriginDirty then
      if XTranslateCoordinates(GDisplay, W.ID, GRoot, 0, 0, @X, @Y, @Child) <> 0 then
        SetClientOrigin(W, X, Y);
  end;
end;

function HasWindowAncestor(W, Ancestor: TXWindow): Boolean;
var
  Steps: Integer;
begin
  for Steps := 0 to GWindows.Count do
  begin
    if (W <> nil) and (W = Ancestor) then Exit(True);
    if not Alive(W) then Break;
    W := W.Parent;
  end;
  Result := False;
end;

function ActivationWindow(W: TXWindow): TXWindow;
var
  Steps: Integer;
begin
  Result := nil;
  for Steps := 0 to GWindows.Count do
  begin
    if not Alive(W) then Exit;
    if not W.CreateInfo.Popup then Exit(W);
    W := W.Parent;
  end;
end;

function InputAllowed(W: TXWindow): Boolean;
begin
  Result := (GModal.Count = 0) or
    ((GModal.Last <> nil) and (ActivationWindow(W) = GModal.Last));
end;

procedure RefreshFocus;
var
  Focus: TXID;
  RevertTo: Integer;
  OldActive, NewActive: TXWindow;
  OldID, NewID: TXID;
begin
  if not GFocusDirty then Exit;
  GFocusDirty := False;
  // Consume a FocusOut/FocusIn sequence as one transition. In particular, Weston/WSLg gives real X keyboard
  // focus to an override-redirect popup. Telling FMX that its owner deactivated closes that very popup.
  // Query only on focus changes, never in the mouse-motion/hit-testing path.
  XGetInputFocus(GDisplay, @Focus, @RevertTo);
  GFocus := FindWindow(Focus);
  NewActive := ActivationWindow(GFocus);
  OldActive := GActive;
  if OldActive = NewActive then Exit;
  OldID := 0;
  NewID := 0;
  if Alive(OldActive) then OldID := OldActive.ID;
  if Alive(NewActive) then NewID := NewActive.ID;
  GActive := nil;
  if Alive(OldActive) then OldActive.NotifyFrame;
  if GCompose <> nil then xkb_compose_state_reset(GCompose);
  if SameWindow(OldActive, OldID) and InputAllowed(OldActive) and Assigned(OldActive.CreateInfo.Activate) then
    OldActive.CreateInfo.Activate(OldActive.CreateInfo.Data, False);
  // The deactivation callback may close popups or destroy forms.
  if SameWindow(NewActive, NewID) and InputAllowed(NewActive) then
  begin
    GActive := NewActive;
    NewActive.NotifyFrame;
    if SameWindow(NewActive, NewID) and Assigned(NewActive.CreateInfo.Activate) then
      NewActive.CreateInfo.Activate(NewActive.CreateInfo.Data, True);
  end;
end;

procedure GrabPointer(W: TXWindow; Popup: Boolean);
begin
  if not Alive(W) or not W.Visible or not InputAllowed(W) then Exit;
  if XGrabPointer(GDisplay, W.ID, Ord(Popup), (1 shl 2) or (1 shl 3) or (1 shl 6),
    1, 1, 0, 0, 0) = 0 then
  begin
    GGrabWindow := W;
    GGrabIsPopup := Popup;
  end;
end;

procedure UngrabPointer(W: TXWindow = nil);
begin
  if (W <> nil) and (GGrabWindow <> W) then Exit;
  // nil releases even an implicit X11 button grab, e.g. when a dialog opens from a MouseDown handler.
  if GDisplay <> nil then XUngrabPointer(GDisplay, 0);
  GGrabWindow := nil;
  GGrabIsPopup := False;
end;

procedure RestorePopupGrab;
var
  W: TXWindow;
begin
  GPopup := nil;
  for W in GWindows do
    if W.Visible and W.CreateInfo.Popup and InputAllowed(W) and
      ((GPopup = nil) or (W.PopupSerial > GPopup.PopupSerial)) then GPopup := W;
  if (GGrabWindow <> nil) and not GGrabIsPopup then Exit;
  if GPopup <> nil then
  begin
    if (GGrabWindow <> GPopup) or not GGrabIsPopup then GrabPointer(GPopup, True);
  end
  else if GGrabIsPopup then UngrabPointer;
end;

procedure HideOwnedPopups(Owner: TXWindow);
var
  W: TXWindow;
  Children: TArray<TXWindow>;
begin
  Children := nil;
  for W in GWindows do
    if W.CreateInfo.Popup and HasWindowAncestor(W.Parent, Owner) then Children := Children + [W];
  // No FMX callbacks during owner destruction: its controls may already be partially torn down.
  for W in Children do
  begin
    W.Parent := nil;
    W.Visible := False;
    UngrabPointer(W);
    XUnmapWindow(GDisplay, W.ID);
  end;
end;

function HandleXError(Display: Pointer; Error: PXErrorEvent): Integer; cdecl;
begin
  // A foreign selection requestor may disappear between requests. Do not let Xlib's default handler exit().
  WlLog(TWlLogLevel.Warning, 'X11 error %d, request %d.%d, resource $%x',
    [Error.ErrorCode, Error.RequestCode, Error.MinorCode, Error.ResourceID]);
  Result := 0;
end;

procedure Connect;
var
  Error, Locale: string;
  Root: TXID;
  X, Y: Integer;
  Border, Depth: Cardinal;
begin
  if GDisplay <> nil then
    Exit;
  LoadXlib;
  IgnoreSigPipe; // match the Wayland backend: a disconnected peer (including portal D-Bus) is not SIGPIPE-fatal
  GDisplay := XOpenDisplay(nil);
  if GDisplay = nil then
    raise Exception.CreateFmt('FMXWayland: cannot connect to X11 (DISPLAY="%s")',
      [GetEnvironmentVariable('DISPLAY')]);
  try
    GScreen := XDefaultScreen(GDisplay);
    GPreviousErrorHandler := XSetErrorHandler(@HandleXError);
    GRoot := XRootWindow(GDisplay, GScreen);
    // Xlib's Screen fields can retain WSLg's initial 640x480 after the desktop grows. Observe root geometry
    // directly and keep it current, otherwise FMX clamps popup placement to obsolete screen/work-area bounds.
    XSelectInput(GDisplay, GRoot, (1 shl 17) or (1 shl 22));
    if (XGetGeometry(GDisplay, GRoot, @Root, @X, @Y, @GScreenWidth, @GScreenHeight, @Border, @Depth) = 0) or
      (GScreenWidth = 0) or (GScreenHeight = 0) then
      raise Exception.Create('FMXWayland: cannot read X11 screen geometry');
    GWindows := TList<TXWindow>.Create;
    GModal := TList<TXWindow>.Create;
    GTimers := TDictionary<NativeInt, TXTimer>.Create;
    GTransfers := TList<TXTransfer>.Create;
    GWakeFd := eventfd(0, EFD_CLOEXEC or EFD_NONBLOCK);
    if GWakeFd < 0 then
      raise Exception.Create('FMXWayland: cannot create X11 wake eventfd');
    GSelectionWindow := XCreateSimpleWindow(GDisplay, GRoot, 0, 0, 1, 1, 0, 0, 0);
    XSelectInput(GDisplay, GSelectionWindow, 1 shl 22);
    if LoadXkbCommon(Error) then
    begin
      GContext := xkb_context_new(0);
      if (GContext <> nil) and XkbComposeAvailable then
      begin
        Locale := GetEnvironmentVariable('LC_ALL');
        if Locale = '' then Locale := GetEnvironmentVariable('LC_CTYPE');
        if Locale = '' then Locale := GetEnvironmentVariable('LANG');
        if Locale = '' then Locale := 'C.UTF-8';
        GComposeTable := xkb_compose_table_new_from_locale(GContext, PAnsiChar(UTF8String(Locale)), 0);
        if GComposeTable <> nil then
          GCompose := xkb_compose_state_new(GComposeTable, 0);
      end;
    end;
    WlLog(TWlLogLevel.Debug, 'backend: X11 (DISPLAY="%s")', [GetEnvironmentVariable('DISPLAY')]);
  except
    Disconnect;
    raise;
  end;
end;

destructor TXWindow.Destroy;
begin
  if GDisplay <> nil then
  begin
    if GC <> nil then XFreeGC(GDisplay, GC);
    if ID <> 0 then XDestroyWindow(GDisplay, ID);
    if Colormap <> 0 then XFreeColormap(GDisplay, Colormap);
  end;
  inherited;
end;

function IsCairoCanvas: Boolean;
var
  C: TClass;
begin
  C := TCanvasManager.DefaultCanvas;
  while C <> nil do
  begin
    if C.ClassName = 'TLinuxCanvas' then
      Exit(True);
    C := C.ClassParent;
  end;
  Result := False;
end;

procedure TXWindow.UpdateShape(const Data: TArray<Cardinal>; Width, Height: Integer);
var
  Rects: TXRectangles;
  Count, X, Y, Start: Integer;
begin
  if not UseShape then Exit;
  Count := 0;
  SetLength(Rects, Height);
  for Y := 0 to Height - 1 do
  begin
    X := 0;
    while X < Width do
    begin
      while (X < Width) and (Data[Y * Width + X] shr 24 < 128) do Inc(X);
      Start := X;
      while (X < Width) and (Data[Y * Width + X] shr 24 >= 128) do Inc(X);
      if Start = X then Break;
      if (Count > 0) and (Rects[Count - 1].X = Start) and (Rects[Count - 1].Width = X - Start) and
        (Rects[Count - 1].Y + Rects[Count - 1].Height = Y) then
        Inc(Rects[Count - 1].Height)
      else
      begin
        if Count = Length(Rects) then SetLength(Rects, Max(16, Count * 2));
        Rects[Count].X := Start;
        Rects[Count].Y := Y;
        Rects[Count].Width := X - Start;
        Rects[Count].Height := 1;
        Inc(Count);
      end;
    end;
  end;
  SetLength(Rects, Count);
  if (Length(Shape) = Count) and ((Count = 0) or CompareMem(@Shape[0], @Rects[0], Count * SizeOf(TXRectangle))) then
    Exit;
  SetXShape(GDisplay, ID, Rects);
  Shape := Rects;
end;

procedure TXWindow.Paint;
var
  WindowID: TXID;
  Frame: TWlFrame;
  R: TRectF;
  Context: Pointer;
  Image: PXImage;
  Data: TArray<Cardinal>;
  X, Y: Integer;
  Pixel: Cardinal;
  NativePixel: NativeUInt;

  function Component(Value: Cardinal; Mask: NativeUInt): NativeUInt;
  var
    Shift: Integer;
  begin
    Shift := 0;
    if Mask = 0 then Exit(0);
    while (Mask and 1) = 0 do
    begin
      Inc(Shift);
      Mask := Mask shr 1;
    end;
    Result := ((Value * Mask + 127) div 255) shl Shift;
  end;

begin
  if not Visible or not Dirty or Painting or not Assigned(CreateInfo.PaintCallback) then
    Exit;
  Dirty := False;
  WindowID := ID;
  Painting := True;
  try
    Frame := Default(TWlFrame);
    Frame.Width := Max(1, Round(Bounds.Width));
    Frame.Height := Max(1, Round(Bounds.Height));
    Frame.Stride := Frame.Width * 4;
    Frame.Scale := 1;
    if (PixelWidth <> Frame.Width) or (PixelHeight <> Frame.Height) then
    begin
      Pixels := nil;
      SetLength(Pixels, NativeInt(Frame.Width) * Frame.Height);
      PixelWidth := Frame.Width;
      PixelHeight := Frame.Height;
    end;
    Data := Pixels; // A callback may destroy the window: keep its frame alive until it returns.
    // This backend paints a whole frame. Do not accumulate premultiplied shadows over the preceding frame.
    if Transparent then FillChar(Data[0], Length(Data) * SizeOf(Cardinal), 0);
    Frame.Bits := @Data[0];
    R := RectF(0, 0, Frame.Width, Frame.Height);
    if IsCairoCanvas then
    begin
      Context := CreateCairoFrame(Frame.Bits, Frame.Width, Frame.Height, Frame.Stride, 1);
      try
        CreateInfo.PaintCallback(CreateInfo.Data, Context, PRectFArray(@R), 1);
        Frame.Drawn := True;
      finally
        DestroyCairoFrame(Context);
      end;
    end
    else
      CreateInfo.PaintCallback(CreateInfo.Data, @Frame, PRectFArray(@R), 1);
    if not SameWindow(Self, WindowID) or not Frame.Drawn then
      Exit;
    Image := XCreateImage(GDisplay, Visual, Depth,
      2, 0, nil, Frame.Width, Frame.Height, 32, 0);
    if Image = nil then
      raise Exception.Create('XCreateImage failed');
    try
      Image.Data := malloc(NativeUInt(Image.BytesPerLine) * NativeUInt(Frame.Height));
      if Image.Data = nil then
        raise EOutOfMemory.Create('X11 frame allocation failed');
      if (Image.BitsPerPixel = 32) and (Image.ByteOrder = 0) and
        (Image.RedMask = $FF0000) and (Image.GreenMask = $FF00) and (Image.BlueMask = $FF) then
        for Y := 0 to Frame.Height - 1 do
          Move(Data[Y * Frame.Width], (PByte(Image.Data) + NativeInt(Y) * Image.BytesPerLine)^, Frame.Stride)
      else
        for Y := 0 to Frame.Height - 1 do
          for X := 0 to Frame.Width - 1 do
          begin
            Pixel := Data[Y * Frame.Width + X];
            NativePixel := Component((Pixel shr 16) and 255, Image.RedMask) or
              Component((Pixel shr 8) and 255, Image.GreenMask) or Component(Pixel and 255, Image.BlueMask);
            if HasAlpha then NativePixel := NativePixel or (Pixel and $FF000000);
            XPutPixel(Image, X, Y, NativePixel);
          end;
      XPutImage(GDisplay, ID, GC, Image, 0, 0, 0, 0, Frame.Width, Frame.Height);
      UpdateShape(Data, Frame.Width, Frame.Height);
    finally
      XDestroyImage(Image); // Xlib owns the malloc-allocated data, never Delphi's frame.
    end;
  finally
    if SameWindow(Self, WindowID) then
      Painting := False;
  end;
end;

function Modifiers(State: Cardinal): Integer;
begin
  Result := 0;
  if State and 1 <> 0 then Result := Result or FMUX_STATE_SHIFT;
  if State and 4 <> 0 then Result := Result or FMUX_STATE_CTRL;
  if State and 8 <> 0 then Result := Result or FMUX_STATE_ALT;
  if State and 64 <> 0 then Result := Result or FMUX_STATE_SUPER;
  if State and 256 <> 0 then Result := Result or FMUX_STATE_LEFT;
  if State and 512 <> 0 then Result := Result or FMUX_STATE_MIDDLE;
  if State and 1024 <> 0 then Result := Result or FMUX_STATE_RIGHT;
end;

procedure SendWM(W: TXWindow; const Message: UTF8String; A, B, C: NativeInt; D: NativeInt = 0; F: NativeInt = 0);
var
  E: TXEvent;
begin
  E := Default(TXEvent);
  E.Client.Header.Kind := 33;
  E.Client.Header.Display := GDisplay;
  E.Client.Header.Window := W.ID;
  E.Client.MessageType := Atom(Message);
  E.Client.Format := 32;
  E.Client.Data[0] := A;
  E.Client.Data[1] := B;
  E.Client.Data[2] := C;
  E.Client.Data[3] := D;
  E.Client.Data[4] := F;
  XSendEvent(GDisplay, GRoot, 0, CRootMask, @E);
end;

function ReadProperty(W, Prop: TXID; out Typ: TXID; out Format: Integer): TBytes;
var
  Count, Left: TXID;
  P: Pointer;
  Size: NativeInt;
begin
  Result := nil;
  P := nil;
  Typ := 0;
  Format := 0;
  if XGetWindowProperty(GDisplay, W, Prop, 0, 4 * 1024 * 1024, 0, 0,
    @Typ, @Format, @Count, @Left, @P) <> 0 then
    Exit;
  try
    if (P = nil) or (Left <> 0) then Exit;
    if Format = 32 then Size := Count * SizeOf(NativeUInt)
    else Size := NativeInt(Count) * (Format div 8);
    SetLength(Result, Size);
    if Size > 0 then Move(P^, Result[0], Size);
  finally
    if P <> nil then XFree(P);
  end;
end;

function WMHas(const Name: UTF8String): Boolean;
var
  Bytes: TBytes;
  Typ, Wanted, Value: TXID;
  Format: Integer;
begin
  if not GWMAtomsLoaded then
  begin
    Bytes := ReadProperty(GRoot, Atom('_NET_SUPPORTED'), Typ, Format);
    GWMAtoms := nil;
    if (Typ = 4) and (Format = 32) then
    begin
      SetLength(GWMAtoms, Length(Bytes) div SizeOf(TXID));
      if Length(GWMAtoms) > 0 then Move(Bytes[0], GWMAtoms[0], Length(GWMAtoms) * SizeOf(TXID));
    end;
    GWMAtomsLoaded := True;
  end;
  Wanted := Atom(Name);
  for Value in GWMAtoms do
    if Value = Wanted then Exit(True);
  Result := False;
end;

function FrameCapabilities: Cardinal;
begin
  // Move/resize and maximize have client-side fallbacks for legacy WMs, including Xming's multiwindow WM.
  Result := FmxwCapMinimize or FmxwCapMaximize;
  if WMHas('_NET_WM_STATE_FULLSCREEN') then Result := Result or FmxwCapFullscreen;
  if WMHas('_GTK_SHOW_WINDOW_MENU') then Result := Result or FmxwCapWindowMenu;
end;

function ScreenWorkArea: TRectF;
var
  Bytes, Desktop: TBytes;
  Typ: TXID;
  Format, Index: Integer;
  Values: PXID;
  R: TRectF;
begin
  Result := RectF(0, 0, GScreenWidth, GScreenHeight);
  Index := 0;
  Desktop := ReadProperty(GRoot, Atom('_NET_CURRENT_DESKTOP'), Typ, Format);
  if (Typ = 6) and (Format = 32) and (Length(Desktop) >= SizeOf(TXID)) then
    Index := Integer(PXID(@Desktop[0])^);
  Bytes := ReadProperty(GRoot, Atom('_NET_WORKAREA'), Typ, Format);
  if (Typ <> 6) or (Format <> 32) or (Index < 0) or
    (Index >= Length(Bytes) div (4 * SizeOf(TXID))) then Exit;
  Values := PXID(@Bytes[Index * 4 * SizeOf(TXID)]);
  R.Left := NativeInt(Values^);
  Inc(Values);
  R.Top := NativeInt(Values^);
  Inc(Values);
  R.Right := R.Left + NativeInt(Values^);
  Inc(Values);
  R.Bottom := R.Top + NativeInt(Values^);
  R.Intersect(Result);
  if not R.IsEmpty then Result := R;
end;

procedure SelectionRequest(const Request: TXSelectionRequest);
var
  E: TXEvent;
  Prop: TXID;
  Targets: array[0..2] of TXID;
  Text: TBytes;
  Transfer: TXTransfer;
  Size: NativeUInt;
  I: Integer;
begin
  WlLog(TWlLogLevel.Debug, 'X11 selection request: selection %d target %d property %d',
    [Request.Selection, Request.Target, Request.Prop]);
  E := Default(TXEvent);
  E.Selection.Header.Kind := 31;
  E.Selection.Header.Display := GDisplay;
  E.Selection.Header.Window := Request.Requestor;
  E.Selection.Selection := Request.Selection;
  E.Selection.Target := Request.Target;
  E.Selection.Time := Request.Time;
  Prop := Request.Prop;
  if Prop = 0 then Prop := Request.Target;
  if Request.Selection = Atom('CLIPBOARD') then
  begin
    if Request.Target = Atom('TARGETS') then
    begin
      Targets[0] := Atom('TARGETS');
      Targets[1] := Atom('UTF8_STRING');
      Targets[2] := 31; // XA_STRING
      XChangeProperty(GDisplay, Request.Requestor, Prop, 4, 32, 0, @Targets[0], Length(Targets));
      E.Selection.Prop := Prop;
    end
    else if (Request.Target = Atom('UTF8_STRING')) or (Request.Target = 31) then
    begin
      if Request.Target = 31 then
      begin
        SetLength(Text, Length(GClipboard));
        for I := 1 to Length(GClipboard) do
          if Ord(GClipboard[I]) <= 255 then Text[I - 1] := Ord(GClipboard[I])
          else Text[I - 1] := Ord('?');
      end
      else Text := TEncoding.UTF8.GetBytes(GClipboard);
      if Length(Text) <= 65536 then
        XChangeProperty(GDisplay, Request.Requestor, Prop, Request.Target, 8, 0, Pointer(Text), Length(Text))
      else
      begin
        Transfer.Requestor := Request.Requestor;
        Transfer.Prop := Prop;
        Transfer.Target := Request.Target;
        Transfer.Text := Text;
        Transfer.Offset := 0;
        Transfer.Deadline := MonotonicMs + 5000;
        GTransfers.Add(Transfer);
        XSelectInput(GDisplay, Request.Requestor, 1 shl 22);
        Size := Length(Text);
        XChangeProperty(GDisplay, Request.Requestor, Prop, Atom('INCR'), 32, 0, @Size, 1);
      end;
      E.Selection.Prop := Prop;
    end;
  end;
  XSendEvent(GDisplay, Request.Requestor, 0, 0, @E);
end;

procedure PropertyChanged(const E: TXPropertyEvent);
var
  I, N, Format: Integer;
  Transfer: TXTransfer;
  Bytes: TBytes;
  Typ: TXID;
begin
  if E.State = 1 then // PropertyDelete acknowledges the previous INCR chunk.
    for I := GTransfers.Count - 1 downto 0 do
    begin
      Transfer := GTransfers[I];
      if (Transfer.Requestor <> E.Header.Window) or (Transfer.Prop <> E.Atom) then Continue;
      N := Min(65536, Length(Transfer.Text) - Transfer.Offset);
      XChangeProperty(GDisplay, Transfer.Requestor, Transfer.Prop, Transfer.Target, 8, 0,
        PByte(Transfer.Text) + Transfer.Offset, N);
      if N = 0 then GTransfers.Delete(I)
      else
      begin
        Inc(Transfer.Offset, N);
        Transfer.Deadline := MonotonicMs + 5000;
        GTransfers[I] := Transfer;
      end;
    end;
  if GSelectionBusy and GSelectionIncr and (E.State = 0) and
    (E.Header.Window = GReadWindow) and (E.Atom = GSelectionProperty) then
  begin
    Bytes := ReadProperty(GReadWindow, E.Atom, Typ, Format);
    XDeleteProperty(GDisplay, GReadWindow, E.Atom);
    if (Format <> 8) or (Length(GSelectionBytes) + Length(Bytes) > 16 * 1024 * 1024) then
    begin
      GSelectionDone := True;
      GSelectionIncr := False;
      Exit;
    end;
    if Length(Bytes) = 0 then
    begin
      GReceived := TEncoding.UTF8.GetString(GSelectionBytes);
      GSelectionDone := True;
      GSelectionIncr := False;
    end
    else GSelectionBytes := GSelectionBytes + Bytes;
  end;
end;

procedure Dispatch(var E: TXEvent);
var
  WindowID: TXID;
  W, Changed: TXWindow;
  Info: TFmuxCreateStruct;
  R: TRectF;
  Child, Sym, Typ: TXID;
  X, Y, State, N, Format, Modifier: Integer;
  NewState: TFmuxWindowState;
  MaximizedH, MaximizedV, Hidden: Boolean;
  StateAtom: TXID;
  Kind: TFmuxMotionKind;
  Buffer: array[0..127] of AnsiChar;
  Text: string;
  C: Char;
  Key: Word;
  Codepoint: Cardinal;
  Bytes: TBytes;
  PointerPos: TPointF;
begin
  case E.Any.Kind of
    21:
      for Changed in GWindows.ToArray do
        if (Changed.ID = E.Reparent.Window) or HasAncestor(Changed, E.Reparent.Window) then
          WatchAncestors(Changed);
    22:
    begin
      if E.Configure.Window = GRoot then
      begin
        GScreenWidth := Max(1, E.Configure.Width);
        GScreenHeight := Max(1, E.Configure.Height);
        Screen.UpdateDisplayInformation;
        WlLog(TWlLogLevel.Debug, 'X11 screen: %dx%d', [GScreenWidth, GScreenHeight]);
        Exit;
      end;
      for Changed in GWindows do
        if HasAncestor(Changed, E.Configure.Window) then
        begin
          Changed.OriginDirty := True;
          GOriginsDirty := True;
        end;
    end;
    28:
      begin
        PropertyChanged(E.Prop);
        if (E.Any.Window = GRoot) and (E.Prop.Atom = Atom('_NET_SUPPORTED')) then GWMAtomsLoaded := False;
      end;
    30: begin SelectionRequest(E.Request); Exit end;
    31:
      begin
        if GSelectionBusy and (E.Selection.Header.Window = GReadWindow) and
          (E.Selection.Selection = Atom('CLIPBOARD')) and
          ((E.Selection.Prop = 0) or (E.Selection.Prop = GSelectionProperty)) then
        begin
          GSelectionDone := True;
          GReceived := '';
          if E.Selection.Prop <> 0 then
          begin
            Bytes := ReadProperty(GReadWindow, E.Selection.Prop, Typ, Format);
            if (Format = 8) and (Typ = Atom('UTF8_STRING')) then
              GReceived := TEncoding.UTF8.GetString(Bytes);
            if Typ = Atom('INCR') then
            begin
              GSelectionDone := False;
              GSelectionIncr := True;
            end;
            XDeleteProperty(GDisplay, GReadWindow, E.Selection.Prop);
          end;
        end;
        Exit;
      end;
    34: begin XRefreshKeyboardMapping(@E); Exit end;
  end;
  W := FindWindow(E.Any.Window);
  if W = nil then Exit;
  if (E.Any.Kind in [2, 3, 4, 5, 6, 8]) and not W.Visible then Exit;
  WindowID := W.ID;
  // Input carries both root and client coordinates. Refresh before FMX hit-tests or positions a popup from
  // this event, including when a native frame move has not yet been drained from our event queue.
  if (E.Any.Kind in [2, 3, 4, 5, 6]) and (E.Key.SameScreen <> 0) then
  begin
    SetClientOrigin(W, E.Key.RootX - E.Key.X, E.Key.RootY - E.Key.Y);
    if not SameWindow(W, WindowID) then Exit;
  end;
  // FMX keeps the originating control's keyboard handling on its owner (e.g. ComboBox toggles its list on
  // Return). Use the same callback whether the WM focuses that owner or the override-redirect popup itself.
  if (E.Any.Kind in [2, 3]) and W.CreateInfo.Popup and Alive(ActivationWindow(W)) then
    W := ActivationWindow(W);
  WindowID := W.ID;
  if (E.Any.Kind = 4) and (E.Key.KeyCode = 1) then
  begin
    GLeftPressed := True;
    GPressWindow := W;
    GPressPoint := PointF(E.Key.RootX, E.Key.RootY);
  end;
  if (E.Any.Kind = 5) and (E.Key.KeyCode = 1) then GLeftPressed := False;
  if (E.Any.Kind = 6) and (E.Key.State and 256 = 0) then
  begin
    GLeftPressed := False;
    EndFrameDrag;
  end;
  if HandleFrameDrag(E) then Exit;
  if not SameWindow(W, WindowID) then Exit;
  Info := W.CreateInfo;
  case E.Any.Kind of
    12: W.Dirty := True; // Expose
    19:
      begin
        W.Visible := True;
        W.Dirty := True;
        if Ord(W.State) = 1 then
        begin
          if W.ManualMaximized then W.State := TFmuxWindowState(2) else W.State := TFmuxWindowState(0);
          if Assigned(Info.StateChanged) then Info.StateChanged(Info.Data, W.State);
          if SameWindow(W, WindowID) then W.NotifyFrame;
        end;
      end;
    18: W.Visible := False;
    28:
      if E.Prop.Atom = Atom('_NET_WM_STATE') then
      begin
        Bytes := ReadProperty(W.ID, E.Prop.Atom, Typ, Format);
        if (Typ <> 4) or (Format <> 32) then Exit;
        MaximizedH := False;
        MaximizedV := False;
        Hidden := False;
        W.FullScreen := False;
        for N := 0 to Length(Bytes) div SizeOf(TXID) - 1 do
        begin
          StateAtom := PXID(@Bytes[N * SizeOf(TXID)])^;
          if StateAtom = Atom('_NET_WM_STATE_FULLSCREEN') then W.FullScreen := True;
          if StateAtom = Atom('_NET_WM_STATE_MAXIMIZED_HORZ') then MaximizedH := True;
          if StateAtom = Atom('_NET_WM_STATE_MAXIMIZED_VERT') then MaximizedV := True;
          if StateAtom = Atom('_NET_WM_STATE_HIDDEN') then Hidden := True;
        end;
        NewState := TFmuxWindowState(0);
        if Hidden then NewState := TFmuxWindowState(1)
        else if (MaximizedH and MaximizedV) or W.ManualMaximized then NewState := TFmuxWindowState(2);
        if W.State <> NewState then
        begin
          W.State := NewState;
          if Assigned(Info.StateChanged) then Info.StateChanged(Info.Data, NewState);
        end;
        if SameWindow(W, WindowID) then W.NotifyFrame;
      end
      else if E.Prop.Atom = Atom('WM_STATE') then
      begin
        Bytes := ReadProperty(W.ID, E.Prop.Atom, Typ, Format);
        if (Format <> 32) or (Length(Bytes) < SizeOf(TXID)) then Exit;
        NewState := W.State;
        if PXID(@Bytes[0])^ = 3 then NewState := TFmuxWindowState(1)
        else if (PXID(@Bytes[0])^ = 1) and (Ord(W.State) = 1) then
          if W.ManualMaximized then NewState := TFmuxWindowState(2) else NewState := TFmuxWindowState(0);
        if W.State <> NewState then
        begin
          W.State := NewState;
          if Assigned(Info.StateChanged) then Info.StateChanged(Info.Data, NewState);
          if SameWindow(W, WindowID) then W.NotifyFrame;
        end;
      end;
    22:
      begin
        // Synthetic ICCCM events already contain root coordinates. Do not subtract a queried tree position:
        // a round-trip can observe a *later* move than this queued event and invent a permanent false offset.
        if E.Any.SendEvent <> 0 then
        begin
          X := E.Configure.X;
          Y := E.Configure.Y;
        end
        else
          XTranslateCoordinates(GDisplay, W.ID, GRoot, 0, 0, @X, @Y, @Child);
        W.OriginDirty := False;
        WlLog(TWlLogLevel.Trace, 'X11 configure $%x: synthetic %d root %d,%d',
          [W.ID, E.Any.SendEvent, X, Y]);
        R := RectF(X, Y, X + E.Configure.Width, Y + E.Configure.Height);
        if R <> W.Bounds then
        begin
          W.Bounds := R;
          W.Dirty := True;
          if Assigned(Info.BoundsChanged) then Info.BoundsChanged(Info.Data, R);
        end;
      end;
    9, 10:
      begin
        WlLog(TWlLogLevel.Trace, 'X11 focus: window $%x popup %s event %d mode %d detail %d',
          [W.ID, BoolToStr(W.CreateInfo.Popup, True), E.Any.Kind, E.Focus.Mode, E.Focus.Detail]);
        if E.Focus.Mode in [1, 2] then Exit; // temporary focus changes during a grab
        // Legacy Windows-backed WMs can restore native focus without publishing WM_STATE or remapping X.
        if (E.Any.Kind = 9) and (Ord(W.State) = 1) then
        begin
          if W.ManualMaximized then W.State := TFmuxWindowState(2) else W.State := TFmuxWindowState(0);
          if Assigned(Info.StateChanged) then Info.StateChanged(Info.Data, W.State);
          if SameWindow(W, WindowID) then W.NotifyFrame;
        end;
        GFocusDirty := True;
      end;
    33:
      if (E.Client.MessageType = Atom('WM_PROTOCOLS')) and
        (TXID(E.Client.Data[0]) = Atom('WM_DELETE_WINDOW')) and InputAllowed(W) and Assigned(Info.Close) then
        Info.Close(Info.Data);
    2, 3:
      if InputAllowed(W) and Assigned(Info.Key) then
      begin
        Sym := 0;
        XLookupString(@E.Key, @Buffer[0], Length(Buffer), @Sym, nil);
        Key := KeyToVirtualKey(Sym, E.Key.KeyCode - 8);
        Text := '';
        if E.Any.Kind = 2 then
        begin
          Codepoint := 0;
          if Assigned(xkb_keysym_to_utf32) then Codepoint := xkb_keysym_to_utf32(Sym)
          else if Sym < 256 then Codepoint := Sym;
          if GCompose <> nil then
          begin
            xkb_compose_state_feed(GCompose, Sym);
            case xkb_compose_state_get_status(GCompose) of
              XKB_COMPOSE_COMPOSING: Codepoint := 0;
              XKB_COMPOSE_COMPOSED:
                begin
                  N := xkb_compose_state_get_utf8(GCompose, @Buffer[0], Length(Buffer));
                  if (N > 0) and (N < Length(Buffer)) then Text := UTF8ToString(PAnsiChar(@Buffer[0]));
                  Codepoint := 0;
                  xkb_compose_state_reset(GCompose);
                end;
              XKB_COMPOSE_CANCELLED: begin Codepoint := 0; xkb_compose_state_reset(GCompose) end;
            end;
          end;
          if (Codepoint >= 32) and (Codepoint <> 127) and (Codepoint <= $10FFFF) then
            if Codepoint <= $FFFF then Text := Char(Codepoint)
            else Text := Char($D800 + ((Codepoint - $10000) shr 10)) + Char($DC00 + ((Codepoint - $10000) and $3FF));
          if (E.Key.State and (4 or 8)) <> 0 then Text := '';
        end;
        State := Modifiers(E.Key.State);
        Modifier := 0;
        case Key of
          vkShift: Modifier := FMUX_STATE_SHIFT;
          vkControl: Modifier := FMUX_STATE_CTRL;
          vkMenu: Modifier := FMUX_STATE_ALT;
          vkLWin, vkRWin: Modifier := FMUX_STATE_SUPER;
        end;
        if E.Any.Kind = 2 then State := State or Modifier
        else State := State and not Modifier;
        GInputState := State;
        if Text = '' then
          Info.Key(Info.Data, TFmuxKeyKind(E.Any.Kind - 2), Key, #0, State)
        else
          for C in Text do
          begin
            if not SameWindow(W, WindowID) then Break;
            Info.Key(Info.Data, TFmuxKeyKind.Down, Key, C, State);
            Key := 0;
          end;
      end;
    4, 5, 6:
      if InputAllowed(W) and Assigned(Info.Motion) then
      begin
        PointerPos := W.Bounds.TopLeft + PointF(E.Key.X, E.Key.Y);
        if (E.Any.Kind = 4) and Alive(GPopup) and
          not GPopup.Bounds.Contains(PointerPos) then
        begin
          Info := GPopup.CreateInfo;
          if Assigned(Info.Close) then Info.Close(Info.Data);
          Exit;
        end;
        State := Modifiers(E.Key.State);
        GInputState := State;
        Kind := TFmuxMotionKind.Move;
        if E.Any.Kind <> 6 then
        begin
          if E.Key.KeyCode in [4, 5, 6, 7] then
          begin
            if E.Any.Kind = 4 then
              Info.Motion(Info.Data, TFmuxMotionKind.Scroll, 0, IfThen(E.Key.KeyCode in [4, 6], 120, -120), State);
            Exit;
          end;
          case E.Key.KeyCode of
            1: State := State or FMUX_STATE_LEFT;
            2: State := State or FMUX_STATE_MIDDLE;
            3: State := State or FMUX_STATE_RIGHT;
          end;
          if E.Any.Kind = 4 then
          begin
            Kind := TFmuxMotionKind.Down;
            if (GLastClickWindow = W.ID) and (GLastClickButton = E.Key.KeyCode) and
              (E.Key.Time - GLastClickTime < 400) and
              (Abs(PointerPos.X - GLastClickPos.X) <= 4) and (Abs(PointerPos.Y - GLastClickPos.Y) <= 4) then
            begin
              State := State or FMUX_STATE_DOUBLE;
              GLastClickWindow := 0;
            end
            else
            begin
              GLastClickWindow := W.ID;
              GLastClickButton := E.Key.KeyCode;
              GLastClickTime := E.Key.Time;
              GLastClickPos := PointerPos.Round;
            end;
          end
          else Kind := TFmuxMotionKind.Up;
        end;
        Info.Motion(Info.Data, Kind, PointerPos.X, PointerPos.Y, State);
      end;
    8:
      if InputAllowed(W) and (Info.Data <> nil) then
        TCommonCustomForm(Info.Data).MouseLeave;
  end;
end;

function ProcessEvents(Timeout: Integer): Boolean;
var
  Fds: array[0..1] of TPollFd;
  E: TXEvent;
  Value: UInt64;
  Proc: TFmuxWakeMainThreadProc;
  ID: NativeInt;
  Timer: TXTimer;
  Now: Int64;
  W: TXWindow;
  Ref: TXWindowRef;
  Budget, I: Integer;
begin
  Connect;
  Result := False;
  Now := MonotonicMs;
  for Timer in GTimers.Values do
    Timeout := Min(Timeout, Integer(EnsureRange(Timer.Due - Now, Int64(0), Int64(MaxInt))));
  for W in GWindows do
    if W.Visible and W.Dirty then Timeout := 0;
  if XPending(GDisplay) > 0 then Timeout := 0;
  Fds[0].fd := XConnectionNumber(GDisplay);
  Fds[0].events := POLLIN;
  Fds[0].revents := 0;
  Fds[1].fd := GWakeFd;
  Fds[1].events := POLLIN;
  Fds[1].revents := 0;
  XFlush(GDisplay);
  poll(@Fds[0], Length(Fds), Timeout);
  if Fds[0].revents and (POLLERR or POLLHUP or POLLNVAL) <> 0 then
    raise Exception.Create('FMXWayland: X11 connection lost');
  if Fds[1].revents and POLLIN <> 0 then
  begin
    __read(GWakeFd, @Value, SizeOf(Value));
    Proc := GWakeProc;
    if Assigned(Proc) then Proc();
    Result := True;
  end;
  // Bound each batch so a busy server cannot starve timers or FMX's idle processing.
  Budget := 256;
  while (Budget > 0) and (XPending(GDisplay) > 0) do
  begin
    XNextEvent(GDisplay, @E);
    if E.Any.Kind in [2, 3, 4, 5, 6] then
    begin
      RefreshOrigins;
      RefreshFocus;
    end;
    Dispatch(E);
    Dec(Budget);
    Result := True;
  end;
  RefreshOrigins;
  RefreshFocus;
  Now := MonotonicMs;
  for I := GTransfers.Count - 1 downto 0 do
    if GTransfers[I].Deadline <= Now then GTransfers.Delete(I);
  for ID in GTimers.Keys.ToArray do
    if GTimers.TryGetValue(ID, Timer) and (Timer.Due <= Now) then
    begin
      Timer.Due := Now + Timer.Interval;
      GTimers[ID] := Timer;
      Timer.Proc(Timer.Data, Timer.Code);
      Result := True;
    end;
  for Ref in WindowSnapshot do
  begin
    W := Ref.Window;
    if SameWindow(W, Ref.ID) and W.Visible and W.Dirty and not W.Painting then
    begin
      W.Paint;
      Result := True;
    end;
  end;
  XFlush(GDisplay);
end;

procedure XInit(Flags: Integer); cdecl;
begin
  try
    Connect;
  except
    on E: Exception do
    begin
      WlLog(TWlLogLevel.Error, E.Message);
      Halt(1);
    end;
  end;
  if not TPlatformServices.Current.SupportsPlatformService(IFMXSystemFontService) then
    TPlatformServices.Current.AddPlatformService(IFMXSystemFontService, TSystemFontService.Create);
  if not TPlatformServices.Current.SupportsPlatformService(IFMXWaylandWindowFrame) then
    TPlatformServices.Current.AddPlatformService(IFMXWaylandWindowFrame, TXFrameService.Create);
end;

procedure XRun(Idle: TFmuxIdleProc); cdecl;
begin
  GIdle := Idle;
  while not GQuit do
  begin
    ProcessEvents(0);
    if Assigned(GIdle) then GIdle();
    if not GQuit then ProcessEvents(10);
  end;
end;

procedure XTerminate; cdecl;
begin
  GQuit := True;
end;

function XHandleMessage: Boolean; cdecl;
begin
  Result := ProcessEvents(0);
end;

procedure XWakeMainThread(Proc: TFmuxWakeMainThreadProc); cdecl;
var
  Value: UInt64;
begin
  // No Xlib calls from worker threads. eventfd wakes the main-thread event pump.
  GWakeProc := Proc;
  Value := 1;
  if GWakeFd >= 0 then __write(GWakeFd, @Value, SizeOf(Value));
end;

function XCreateTimer(Interval: Integer; Proc: TFmuxTimerProc; Data, Code: Pointer): NativeInt; cdecl;
var
  Timer: TXTimer;
begin
  Connect;
  if not Assigned(Proc) then Exit(0);
  Inc(GNextTimer);
  Result := GNextTimer;
  Timer.Interval := Max(1, Interval);
  Timer.Due := MonotonicMs + Timer.Interval;
  Timer.Proc := Proc;
  Timer.Data := Data;
  Timer.Code := Code;
  GTimers.Add(Result, Timer);
end;

function XDestroyTimer(Timer: NativeInt): Boolean; cdecl;
begin
  Result := (GTimers <> nil) and GTimers.ContainsKey(Timer);
  if Result then GTimers.Remove(Timer);
end;

function XIsWayland: Boolean; cdecl;
begin
  Result := False;
end;

procedure XSetTitle(Wnd: Pointer; Title: PChar); cdecl;
var
  Text: UTF8String;
begin
  if not Alive(Wnd) then Exit;
  Text := UTF8String(string(Title));
  XStoreName(GDisplay, TXWindow(Wnd).ID, PAnsiChar(Text));
  XChangeProperty(GDisplay, TXWindow(Wnd).ID, Atom('_NET_WM_NAME'), Atom('UTF8_STRING'), 8, 0,
    PAnsiChar(Text), Length(Text));
end;

function XCreateWindow(var Info: TFmuxCreateStruct): Pointer; cdecl;
var
  W: TXWindow;
  Protocol: TXID;
  Attr: TXSetWindowAttributes;
  Hints: array[0..4] of NativeUInt;
  Name: UTF8String;
  Mask: NativeUInt;
  AlphaVisual: Pointer;
begin
  Connect;
  W := TXWindow.Create;
  try
    W.CreateInfo := Info;
    W.CreateInfo.Title := nil;
    W.Decorated := not Info.Popup and (Info.BorderStyle <> TFmuxBorderStyle.None);
    W.Transparent := Info.Transparent or Info.Popup;
    W.Visual := XDefaultVisual(GDisplay, GScreen);
    W.Depth := XDefaultDepth(GDisplay, GScreen);
    if W.Transparent then
    begin
      if XGetSelectionOwner(GDisplay, Atom(UTF8String('_NET_WM_CM_S' + GScreen.ToString))) <> 0 then
      begin
        AlphaVisual := FindARGBVisual(GDisplay, GScreen);
        if AlphaVisual <> nil then
        begin
          W.Visual := AlphaVisual;
          W.Depth := 32;
          W.Colormap := XCreateColormap(GDisplay, GRoot, W.Visual, 0);
          if W.Colormap = 0 then raise Exception.Create('XCreateColormap failed');
          W.HasAlpha := True;
        end;
      end;
      W.UseShape := not W.HasAlpha and HasXShape(GDisplay);
    end;
    W.Bounds := RectF(Round(Info.X), Round(Info.Y), Round(Info.X) + Max(1, Round(Info.Width)),
      Round(Info.Y) + Max(1, Round(Info.Height)));
    WlLog(TWlLogLevel.Trace, 'X11 create: popup %s at %.0f,%.0f %.0fx%.0f',
      [BoolToStr(Info.Popup, True), W.Bounds.Left, W.Bounds.Top, W.Bounds.Width, W.Bounds.Height]);
    // The WM observes override_redirect in CreateNotify. Changing it after XCreateSimpleWindow is too late
    // for Weston/WSLg: it caches a managed toplevel role and can place the popup at an unrelated screen position.
    Attr := Default(TXSetWindowAttributes);
    Attr.OverrideRedirect := Ord(Info.Popup);
    Attr.EventMask := CEventMask;
    Mask := (1 shl 1) or (1 shl 3) or (1 shl 9) or (1 shl 11); // background/border pixel, override, events
    if W.Colormap <> 0 then
    begin
      Attr.Colormap := W.Colormap;
      Mask := Mask or (1 shl 13);
    end;
    W.ID := XCreateWindowNative(GDisplay, GRoot, Round(W.Bounds.Left), Round(W.Bounds.Top),
      Round(W.Bounds.Width), Round(W.Bounds.Height), 0, W.Depth, 1, W.Visual, Mask, @Attr);
    if W.ID = 0 then raise Exception.Create('XCreateWindow failed');
    W.GC := XCreateGC(GDisplay, W.ID, 0, nil);
    if W.GC = nil then raise Exception.Create('XCreateGC failed');
    if W.UseShape then SetXShape(GDisplay, W.ID, nil); // no opaque flash before the first transparent frame
    if W.Transparent then
      WlLog(TWlLogLevel.Debug, 'X11 transparency: depth %d, alpha %s, shape %s',
        [W.Depth, BoolToStr(W.HasAlpha, True), BoolToStr(W.UseShape, True)]);
    if Info.Popup then
    begin
      Protocol := Atom('_NET_WM_WINDOW_TYPE_POPUP_MENU');
      XChangeProperty(GDisplay, W.ID, Atom('_NET_WM_WINDOW_TYPE'), 4, 32, 0, @Protocol, 1);
    end;
    if Info.Popup or (Info.BorderStyle = TFmuxBorderStyle.None) then
    begin
      FillChar(Hints, SizeOf(Hints), 0);
      Hints[0] := 2; // MWM_HINTS_DECORATIONS
      XChangeProperty(GDisplay, W.ID, Atom('_MOTIF_WM_HINTS'), Atom('_MOTIF_WM_HINTS'), 32, 0, @Hints[0], 5);
    end;
    Protocol := Atom('WM_DELETE_WINDOW');
    XSetWMProtocols(GDisplay, W.ID, @Protocol, 1);
    Name := UTF8String(ChangeFileExt(ExtractFileName(ParamStr(0)), ''));
    Name := Name + #0 + Name + #0;
    XChangeProperty(GDisplay, W.ID, Atom('WM_CLASS'), 31, 8, 0, PAnsiChar(Name), Length(Name));
    if GCursor <> 0 then XDefineCursor(GDisplay, W.ID, GCursor);
    GWindows.Add(W);
    XSetTitle(W, Info.Title);
    Result := W;
  except
    if Alive(W) then XDestroyWindowFmux(W) else W.Free;
    raise;
  end;
end;

procedure XDestroyWindowFmux(Wnd: Pointer); cdecl;
var
  W, Child: TXWindow;
  I: Integer;
begin
  W := Wnd;
  if not Alive(W) then Exit;
  GWindows.Remove(W); // detach before releasing listener interfaces, which can call platform services
  HideOwnedPopups(W);
  if GMain = W then GMain := nil;
  if GFocus = W then GFocus := nil;
  if GActive = W then GActive := nil;
  W.FrameListener := nil;
  W.FrameHandle := nil;
  if GPressWindow = W then
  begin
    GPressWindow := nil;
    GLeftPressed := False;
  end;
  if GFrameDrag.Window = W then EndFrameDrag(False);
  if GPopup = W then
    GPopup := nil;
  UngrabPointer(W);
  for Child in GWindows do
    if Child.Parent = W then Child.Parent := nil;
  for I := 0 to GModal.Count - 1 do
    if GModal[I] = W then GModal[I] := nil;
  W.Free;
  RestorePopupGrab;
end;

procedure XSetMainWindow(Wnd: Pointer); cdecl;
begin
  GMain := Wnd;
end;

procedure XShowWindow(Wnd: Pointer; Show: Boolean); cdecl;
var
  W, Parent: TXWindow;
  WindowID: TXID;
begin
  W := Wnd;
  if not Alive(W) then Exit;
  WindowID := W.ID;
  WlLog(TWlLogLevel.Trace, 'X11 show: window $%x popup %s visible %s',
    [W.ID, BoolToStr(W.CreateInfo.Popup, True), BoolToStr(Show, True)]);
  W.Visible := Show;
  if Show then
  begin
    Parent := GFocus;
    if (Parent = nil) and (GModal.Count > 0) then Parent := GModal.Last;
    if Parent = nil then Parent := GMain;
    if HasWindowAncestor(Parent, W) then Parent := nil;
    if (Parent <> W) and Alive(Parent) and W.CreateInfo.Popup then
    begin
      W.Parent := Parent;
      XSetTransientForHint(GDisplay, W.ID, Parent.ID);
    end;
    XMapRaised(GDisplay, W.ID);
    W.Dirty := True;
    if W.CreateInfo.Popup then
    begin
      GPopup := W;
      Inc(GPopupSerial);
      W.PopupSerial := GPopupSerial;
      GrabPointer(W, True);
    end;
  end
  else
  begin
    if GFrameDrag.Window = W then EndFrameDrag;
    if not SameWindow(W, WindowID) then Exit;
    HideOwnedPopups(W);
    if GPopup = W then
      GPopup := nil;
    UngrabPointer(W);
    XUnmapWindow(GDisplay, W.ID);
    RestorePopupGrab;
  end;
  XFlush(GDisplay);
end;

procedure XGetWindowRect(Wnd: Pointer; var R: TRectF); cdecl;
begin
  if Alive(Wnd) then R := TXWindow(Wnd).Bounds else R := TRectF.Empty;
end;

procedure XSetWindowRect(Wnd: Pointer; R: TRectF); cdecl;
var
  W: TXWindow;
begin
  W := Wnd;
  if not Alive(W) then Exit;
  R := RectF(Round(R.Left), Round(R.Top), Round(R.Left) + Max(1, Round(R.Width)),
    Round(R.Top) + Max(1, Round(R.Height)));
  // BoundsChanged is an acknowledgement of server geometry, not a request to move the window again.
  if R = W.Bounds then Exit;
  WlLog(TWlLogLevel.Trace, 'X11 set bounds $%x: %.0f,%.0f %.0fx%.0f',
    [W.ID, R.Left, R.Top, R.Width, R.Height]);
  W.Bounds := R;
  W.Dirty := True;
  XMoveResizeWindow(GDisplay, W.ID, Round(R.Left), Round(R.Top), Round(R.Width), Round(R.Height));
  if Assigned(W.CreateInfo.BoundsChanged) then W.CreateInfo.BoundsChanged(W.CreateInfo.Data, R);
end;

procedure XGetClientSize(Wnd: Pointer; var R: TPointF); cdecl;
begin
  if Alive(Wnd) then R := PointF(TXWindow(Wnd).Bounds.Width, TXWindow(Wnd).Bounds.Height)
  else R := PointF(0, 0);
end;

procedure XSetClientSize(Wnd: Pointer; R: TPointF); cdecl;
var
  B: TRectF;
begin
  if not Alive(Wnd) then Exit;
  B := TXWindow(Wnd).Bounds;
  XSetWindowRect(Wnd, RectF(B.Left, B.Top, B.Left + R.X, B.Top + R.Y));
end;

procedure XInvalidateRect(Wnd: Pointer; R: TRectF); cdecl;
begin
  if Alive(Wnd) then TXWindow(Wnd).Dirty := True;
end;

procedure XProcessUpdates(Wnd: Pointer); cdecl;
begin
  if Alive(Wnd) then TXWindow(Wnd).Paint;
end;

function XClientToScreen(Wnd: Pointer; Point: TPointF): TPointF; cdecl;
begin
  Result := Point;
  // FMX calls this for every control it hit-tests during mouse motion. A synchronous XTranslateCoordinates
  // here multiplied one event into dozens of server round-trips (especially expensive with XWayland/WSLg).
  // Client/frame configure and reparent events refresh the origin; input supplies a current origin too.
  if Alive(Wnd) then
    Result := Point + TXWindow(Wnd).Bounds.TopLeft;
end;

function XScreenToClient(Wnd: Pointer; Point: TPointF): TPointF; cdecl;
begin
  Result := Point - XClientToScreen(Wnd, PointF(0, 0));
end;

function XWindowScale(Wnd: Pointer): Single; cdecl;
begin
  Result := 1;
end;

function XScreenScale: Single; cdecl;
begin
  Result := 1;
end;

procedure XActivateWindow(Wnd: Pointer); cdecl;
begin
  if not Alive(Wnd) then Exit;
  WlLog(TWlLogLevel.Trace, 'X11 activate: window $%x popup %s',
    [TXWindow(Wnd).ID, BoolToStr(TXWindow(Wnd).CreateInfo.Popup, True)]);
  if TXWindow(Wnd).CreateInfo.Popup then Exit;
  if (GFocus = TXWindow(Wnd)) or (GActive = TXWindow(Wnd)) then Exit;
  XRaiseWindow(GDisplay, TXWindow(Wnd).ID);
  SendWM(Wnd, '_NET_ACTIVE_WINDOW', 1, 0, 0);
end;

procedure XSendToBack(Wnd: Pointer); cdecl;
begin
  if Alive(Wnd) then XLowerWindow(GDisplay, TXWindow(Wnd).ID);
end;

procedure XSetWindowState(Wnd: Pointer; State: TFmuxWindowState); cdecl;
var
  W: TXWindow;
  Restore: TRectF;
  WindowID: TXID;
begin
  W := Wnd;
  if not Alive(W) then Exit;
  WindowID := W.ID;
  if W.State = State then Exit;
  if GFrameDrag.Window = W then EndFrameDrag;
  if not SameWindow(W, WindowID) then Exit;
  if Ord(State) = 1 then XIconifyWindow(GDisplay, W.ID, GScreen)
  else
  begin
    XMapRaised(GDisplay, W.ID);
    if (Ord(State) = 0) and W.ManualMaximized then
    begin
      Restore := W.RestoreBounds;
      W.ManualMaximized := False;
      W.State := State;
      XSetWindowRect(W, Restore);
    end
    else if (Ord(State) = 2) and not (WMHas('_NET_WM_STATE_MAXIMIZED_VERT') and
      WMHas('_NET_WM_STATE_MAXIMIZED_HORZ')) then
    begin
      W.RestoreBounds := W.Bounds;
      W.ManualMaximized := True;
      W.State := State;
      XSetWindowRect(W, ScreenWorkArea);
    end
    else
      SendWM(W, '_NET_WM_STATE', Ord(Ord(State) = 2), Atom('_NET_WM_STATE_MAXIMIZED_VERT'),
        Atom('_NET_WM_STATE_MAXIMIZED_HORZ'));
  end;
  if not SameWindow(W, WindowID) then Exit;
  W.State := State;
  if Assigned(W.CreateInfo.StateChanged) then W.CreateInfo.StateChanged(W.CreateInfo.Data, State);
  if SameWindow(W, WindowID) then W.NotifyFrame;
end;

function XGetFullScreen(Wnd: Pointer): Boolean; cdecl;
begin
  Result := Alive(Wnd) and TXWindow(Wnd).FullScreen;
end;

procedure XSetFullScreen(Wnd: Pointer; Value: Boolean); cdecl;
begin
  if not Alive(Wnd) then Exit;
  TXWindow(Wnd).FullScreen := Value;
  SendWM(Wnd, '_NET_WM_STATE', Ord(Value), Atom('_NET_WM_STATE_FULLSCREEN'), 0);
  TXWindow(Wnd).NotifyFrame;
end;

procedure XSetCapture(Wnd: Pointer); cdecl;
begin
  GrabPointer(Wnd, False);
end;

procedure XReleaseCapture(Wnd: Pointer); cdecl;
begin
  // A parent MouseUp can return after a nested popup/modal loop: it must not release another window's grab.
  if (GGrabWindow <> TXWindow(Wnd)) or GGrabIsPopup then Exit;
  UngrabPointer(Wnd);
  RestorePopupGrab;
end;

function XNativeHandle(Wnd: Pointer): Pointer; cdecl;
begin
  if Alive(Wnd) then Result := Pointer(TXWindow(Wnd).ID) else Result := nil;
end;

function XShowModal(Wnd: Pointer; Proc: TFmuxModal): Integer; cdecl;
var
  W, Parent: TXWindow;
  Level: Integer;
  WindowID: TXID;
begin
  Result := 0;
  W := Wnd;
  if not Alive(W) then Exit;
  WindowID := W.ID;
  Parent := GMain;
  if GModal.Count > 0 then Parent := GModal.Last;
  if Alive(Parent) and (Parent <> W) then XSetTransientForHint(GDisplay, W.ID, Parent.ID);
  // FMX invokes OnClick before the parent's MouseUp has released capture. A synchronous modal loop entered
  // from that callback would otherwise keep routing every click to the now-blocked parent indefinitely.
  EndFrameDrag;
  if not SameWindow(W, WindowID) then Exit;
  UngrabPointer;
  Level := GModal.Count;
  GModal.Add(W);
  try
    while not GQuit and SameWindow(W, WindowID) do
    begin
      Proc(W.CreateInfo.Data, Result);
      if (Result <> 0) or not SameWindow(W, WindowID) then Break;
      ProcessEvents(0);
      if Assigned(GIdle) then GIdle();
      if not GQuit then ProcessEvents(10);
    end;
  finally
    UngrabPointer(W);
    GModal.Delete(Level);
    RestorePopupGrab;
  end;
end;

function XScreenSize: TPointF; cdecl;
begin
  Connect;
  Result := PointF(GScreenWidth, GScreenHeight);
end;

function XDisplayInfo(Info: PFmuxDisplayInfo; Index: Integer): Integer; cdecl;
var
  Size: TPointF;
begin
  Size := XScreenSize;
  Result := 1;
  if (Info = nil) or (Index <> 0) then Exit;
  Info.Primary := True;
  Info.BoundsRect := Rect(0, 0, Round(Size.X), Round(Size.Y));
  Info.WorkareaRect := Info.BoundsRect;
end;

function XDisplayFromPoint(Point: TPoint): Integer; cdecl;
begin
  Result := 0;
end;

function XDisplayFromWindow(Wnd: Pointer): Integer; cdecl;
begin
  Result := 0;
end;

function XMousePos: TPointF; cdecl;
var
  Root, Child: TXID;
  RX, RY, X, Y: Integer;
  Mask: Cardinal;
begin
  Connect;
  RX := 0;
  RY := 0;
  XQueryPointer(GDisplay, GRoot, @Root, @Child, @RX, @RY, @X, @Y, @Mask);
  Result := PointF(RX, RY);
end;

function XKeyState: Integer; cdecl;
begin
  // FMX asks while handling a queued key event. Querying the server here would observe later key releases.
  Result := GInputState;
end;

procedure XSetCursor(Cursor: Integer); cdecl;
var
  Shape: Cardinal;
  NewCursor: TXID;
  W: TXWindow;
begin
  Connect;
  case Cursor of
    crCross: Shape := 34;
    crIBeam: Shape := 152;
    crSizeNS: Shape := 116;
    crSizeWE: Shape := 108;
    crSizeNWSE: Shape := 134;
    crSizeNESW: Shape := 136;
    crSizeAll: Shape := 52;
    crHourGlass, crAppStart: Shape := 150;
    crHandPoint: Shape := 60;
    crNo: Shape := 0;
  else
    Shape := 68;
  end;
  // FMX repeatedly requests the same cursor during hit-testing. Recreating and redefining it for every motion
  // causes cursor-image churn/flicker in XWayland/WSLg and floods X11 with needless resource requests.
  if (GCursor <> 0) and (GCursorShape = Shape) then Exit;
  NewCursor := XCreateFontCursor(GDisplay, Shape);
  if NewCursor = 0 then Exit;
  for W in GWindows do XDefineCursor(GDisplay, W.ID, NewCursor);
  if GCursor <> 0 then XFreeCursor(GDisplay, GCursor);
  GCursor := NewCursor;
  GCursorShape := Shape;
end;

procedure XClipboardSetText(Text: PChar); cdecl;
begin
  Connect;
  GClipboard := string(Text);
  WlLog(TWlLogLevel.Debug, 'X11 clipboard: %d characters', [Length(GClipboard)]);
  XSetSelectionOwner(GDisplay, Atom('CLIPBOARD'), GSelectionWindow, 0);
  XFlush(GDisplay);
end;

function XClipboardHasText: Boolean; cdecl;
begin
  Connect;
  Result := XGetSelectionOwner(GDisplay, Atom('CLIPBOARD')) <> 0;
end;

function XClipboardGetText: PChar; cdecl;
var
  Deadline: Int64;
begin
  Connect;
  if XGetSelectionOwner(GDisplay, Atom('CLIPBOARD')) = GSelectionWindow then Exit(PChar(GClipboard));
  if GSelectionBusy then Exit(nil);
  GSelectionBusy := True;
  try
    GReceived := '';
    GSelectionDone := False;
    GSelectionIncr := False;
    GSelectionBytes := nil;
    // A fresh requestor isolates late replies after a timeout without leaking an atom for every paste.
    GReadWindow := XCreateSimpleWindow(GDisplay, GRoot, 0, 0, 1, 1, 0, 0, 0);
    XSelectInput(GDisplay, GReadWindow, 1 shl 22);
    GSelectionProperty := Atom('_FMX_SELECTION');
    XConvertSelection(GDisplay, Atom('CLIPBOARD'), Atom('UTF8_STRING'), GSelectionProperty, GReadWindow, 0);
    Deadline := MonotonicMs + 5000;
    while not GSelectionDone and not GQuit and (MonotonicMs < Deadline) do ProcessEvents(10);
    Result := PChar(GReceived);
  finally
    GSelectionBusy := False;
    GSelectionIncr := False;
    GSelectionBytes := nil;
    XDestroyWindow(GDisplay, GReadWindow);
    GReadWindow := 0;
  end;
end;

function DialogPump(const Fd, Timeout: Integer): Boolean;
var
  PollFd: TPollFd;
  Deadline: Int64;
begin
  Deadline := MonotonicMs + Timeout;
  PollFd.fd := Fd;
  PollFd.events := POLLIN;
  repeat
    PollFd.revents := 0;
    if poll(@PollFd, 1, 0) > 0 then Break;
    ProcessEvents(Integer(EnsureRange(Deadline - MonotonicMs, Int64(0), Int64(10))));
    if Assigned(GIdle) then GIdle();
  until GQuit or (MonotonicMs >= Deadline);
  Result := not GQuit;
end;

function DialogBeginModal: string;
var
  W: TXWindow;
begin
  Connect;
  EndFrameDrag;
  UngrabPointer;
  W := GFocus;
  if GModal.Count > 0 then W := GModal.Last;
  if W = nil then W := GMain;
  Result := '';
  if Alive(W) then Result := 'x11:' + IntToHex(W.ID, 1);
  GModal.Add(nil);
end;

procedure DialogEndModal;
begin
  if (GModal <> nil) and (GModal.Count > 0) then GModal.Delete(GModal.Count - 1);
  if GWindows <> nil then RestorePopupGrab;
end;

function TXWindow.FrameStates: Cardinal;
begin
  Result := 0;
  if GActive = Self then Result := Result or FmxwStateActivated;
  if Ord(State) = 2 then Result := Result or FmxwStateMaximized;
  if Ord(State) = 1 then Result := Result or FmxwStateSuspended;
  if FullScreen then Result := Result or FmxwStateFullscreen;
  if (GFrameDrag.Window = Self) and GFrameDrag.Started and (GFrameDrag.Edges <> 0) then
    Result := Result or FmxwStateResizing;
end;

procedure TXWindow.NotifyFrame;
var
  Listener: IFMXWaylandWindowFrameListener;
  Handle: TWindowHandle;
begin
  Listener := FrameListener;
  Handle := FrameHandle;
  if (Listener = nil) or (Handle = nil) then Exit;
  try
    Listener.WindowFrameChanged(Handle, FrameStates, FrameCapabilities);
  except
    Application.HandleException(nil);
  end;
end;

procedure EndFrameDrag(Notify: Boolean);
var
  W: TXWindow;
begin
  W := GFrameDrag.Window;
  if W = nil then Exit;
  GFrameDrag := Default(TXFrameDrag);
  UngrabPointer(W);
  if Notify and Alive(W) then W.NotifyFrame;
end;

function ResizeDirection(Edges: Cardinal): Integer;
begin
  case Edges of
    FmxwEdgeTopLeft: Result := 0;
    FmxwEdgeTop: Result := 1;
    FmxwEdgeTopRight: Result := 2;
    FmxwEdgeRight: Result := 3;
    FmxwEdgeBottomRight: Result := 4;
    FmxwEdgeBottom: Result := 5;
    FmxwEdgeBottomLeft: Result := 6;
    FmxwEdgeLeft: Result := 7;
  else
    Result := 8; // move
  end;
end;

function HandleFrameDrag(const E: TXEvent): Boolean;
var
  W: TXWindow;
  Drag: TXFrameDrag;
  R: TRectF;
  Delta: TPointF;
  MinW, MinH, MaxW, MaxH, Width, Height, Fraction: Single;
  Form: TCommonCustomForm;
  WindowID: TXID;
begin
  Result := False;
  W := GFrameDrag.Window;
  if W = nil then Exit;
  if not Alive(W) or not GLeftPressed then
  begin
    EndFrameDrag;
    Exit; // FMX must receive MouseUp too, to clear the originating control's pressed/capture state.
  end;
  if E.Any.Kind <> 6 then Exit;
  WindowID := W.ID;
  Delta := PointF(E.Key.RootX, E.Key.RootY) - GFrameDrag.StartPoint;
  WlLog(TWlLogLevel.Trace, 'X11 frame motion: root %d,%d start %.0f,%.0f delta %.0f,%.0f bounds %.0f,%.0f',
    [E.Key.RootX, E.Key.RootY, GFrameDrag.StartPoint.X, GFrameDrag.StartPoint.Y, Delta.X, Delta.Y,
      GFrameDrag.Bounds.Left, GFrameDrag.Bounds.Top]);
  if not GFrameDrag.Started then
  begin
    if (Abs(Delta.X) < 4) and (Abs(Delta.Y) < 4) then Exit;
    GFrameDrag.Started := True;
  end;
  Result := True;
  if GFrameDrag.Native then
  begin
    Drag := GFrameDrag;
    EndFrameDrag(False);
    SendWM(W, '_NET_WM_MOVERESIZE', Round(Drag.StartPoint.X), Round(Drag.StartPoint.Y),
      ResizeDirection(Drag.Edges), 1, 1);
    XFlush(GDisplay);
    Exit;
  end;
  if (GFrameDrag.Edges = 0) and W.ManualMaximized then
  begin
    Drag := GFrameDrag;
    GFrameDrag := Default(TXFrameDrag);
    XSetWindowState(W, TFmuxWindowState(0));
    if not SameWindow(W, WindowID) then Exit;
    Fraction := EnsureRange((Drag.StartPoint.X - Drag.Bounds.Left) / Max(1.0, Drag.Bounds.Width), 0.0, 1.0);
    R := W.Bounds;
    R.Offset(E.Key.RootX - R.Left - R.Width * Fraction,
      E.Key.RootY - R.Top - Min(40.0, Drag.StartPoint.Y - Drag.Bounds.Top));
    XSetWindowRect(W, R);
    if not SameWindow(W, WindowID) then Exit;
    Drag.Bounds := R;
    Drag.StartPoint := PointF(E.Key.RootX, E.Key.RootY);
    GFrameDrag := Drag;
    GrabPointer(W, False);
    Exit;
  end;
  R := GFrameDrag.Bounds;
  if GFrameDrag.Edges = 0 then R.Offset(Delta)
  else
  begin
    if GFrameDrag.Edges and FmxwEdgeLeft <> 0 then R.Left := R.Left + Delta.X;
    if GFrameDrag.Edges and FmxwEdgeRight <> 0 then R.Right := R.Right + Delta.X;
    if GFrameDrag.Edges and FmxwEdgeTop <> 0 then R.Top := R.Top + Delta.Y;
    if GFrameDrag.Edges and FmxwEdgeBottom <> 0 then R.Bottom := R.Bottom + Delta.Y;
    MinW := 64;
    MinH := 48;
    MaxW := MaxSingle;
    MaxH := MaxSingle;
    Form := TCommonCustomForm(W.CreateInfo.Data);
    if Form <> nil then
    begin
      MinW := Max(MinW, Form.Constraints.MinWidth);
      MinH := Max(MinH, Form.Constraints.MinHeight);
      if Form.Constraints.MaxWidth > 0 then MaxW := Max(MinW, Form.Constraints.MaxWidth);
      if Form.Constraints.MaxHeight > 0 then MaxH := Max(MinH, Form.Constraints.MaxHeight);
    end;
    Width := EnsureRange(R.Width, MinW, MaxW);
    Height := EnsureRange(R.Height, MinH, MaxH);
    if GFrameDrag.Edges and FmxwEdgeLeft <> 0 then R.Left := R.Right - Width else R.Right := R.Left + Width;
    if GFrameDrag.Edges and FmxwEdgeTop <> 0 then R.Top := R.Bottom - Height else R.Bottom := R.Top + Height;
  end;
  XSetWindowRect(W, R);
end;

function TXFrameService.WindowOf(const Handle: TWindowHandle): TXWindow;
var
  W: TXWindow;
begin
  Result := nil;
  if not (Handle is TLinuxWindowHandle) then Exit;
  W := TXWindow(TLinuxWindowHandle(Handle).Window);
  if Alive(W) and not W.CreateInfo.Popup then Result := W;
end;

procedure TXFrameService.SetDecorated(const AHandle: TWindowHandle; const AValue: Boolean);
var
  W: TXWindow;
  Hints: array[0..4] of NativeUInt;
begin
  W := WindowOf(AHandle);
  if (W = nil) or (W.Decorated = AValue) then Exit;
  W.Decorated := AValue;
  FillChar(Hints, SizeOf(Hints), 0);
  Hints[0] := 2; // MWM_HINTS_DECORATIONS
  Hints[2] := Ord(AValue); // MWM_DECOR_ALL or no decorations
  XChangeProperty(GDisplay, W.ID, Atom('_MOTIF_WM_HINTS'), Atom('_MOTIF_WM_HINTS'), 32, 0, @Hints[0], 5);
  XFlush(GDisplay);
  WlLog(TWlLogLevel.Debug, 'X11 custom frame: window $%x decorated %s', [W.ID, BoolToStr(AValue, True)]);
end;

function TXFrameService.GetDecorated(const AHandle: TWindowHandle): Boolean;
var
  W: TXWindow;
begin
  W := WindowOf(AHandle);
  Result := (W <> nil) and W.Decorated;
end;

function TXFrameService.StartDrag(const Handle: TWindowHandle; Edges: Cardinal): Boolean;
var
  W: TXWindow;
  WindowID: TXID;
begin
  W := WindowOf(Handle);
  Result := (W <> nil) and W.Visible and InputAllowed(W) and GLeftPressed and (GPressWindow = W) and
    not W.FullScreen and ((Edges = 0) or (Ord(W.State) <> 2));
  if not Result then Exit;
  WindowID := W.ID;
  EndFrameDrag;
  if not SameWindow(W, WindowID) then Exit(False);
  GFrameDrag.Window := W;
  GFrameDrag.StartPoint := GPressPoint;
  GFrameDrag.Bounds := W.Bounds;
  GFrameDrag.Edges := Edges;
  GFrameDrag.Started := Edges <> 0;
  GFrameDrag.Native := WMHas('_NET_WM_MOVERESIZE');
  WlLog(TWlLogLevel.Trace, 'X11 frame drag: root %.0f,%.0f bounds %.0f,%.0f edges %d native %s',
    [GPressPoint.X, GPressPoint.Y, W.Bounds.Left, W.Bounds.Top, Edges, BoolToStr(GFrameDrag.Native, True)]);
  GrabPointer(W, False);
  Result := GGrabWindow = W;
  if not Result then GFrameDrag := Default(TXFrameDrag)
  else W.NotifyFrame;
end;

function TXFrameService.BeginMove(const AHandle: TWindowHandle): Boolean;
begin
  Result := StartDrag(AHandle, 0);
end;

function TXFrameService.BeginResize(const AHandle: TWindowHandle; const AEdges: Cardinal): Boolean;
begin
  Result := (AEdges in [FmxwEdgeTop, FmxwEdgeBottom, FmxwEdgeLeft, FmxwEdgeRight, FmxwEdgeTopLeft,
    FmxwEdgeTopRight, FmxwEdgeBottomLeft, FmxwEdgeBottomRight]) and StartDrag(AHandle, AEdges);
end;

function TXFrameService.ShowWindowMenu(const AHandle: TWindowHandle; const AClientPoint: TPointF): Boolean;
var
  W: TXWindow;
begin
  W := WindowOf(AHandle);
  Result := (W <> nil) and WMHas('_GTK_SHOW_WINDOW_MENU');
  if Result then
    SendWM(W, '_GTK_SHOW_WINDOW_MENU', 0, Round(W.Bounds.Left + AClientPoint.X), Round(W.Bounds.Top + AClientPoint.Y));
end;

procedure TXFrameService.Minimize(const AHandle: TWindowHandle);
var
  W: TXWindow;
begin
  W := WindowOf(AHandle);
  if W <> nil then XSetWindowState(W, TFmuxWindowState(1));
end;

procedure TXFrameService.SetMaximized(const AHandle: TWindowHandle; const AValue: Boolean);
var
  W: TXWindow;
begin
  W := WindowOf(AHandle);
  if W <> nil then XSetWindowState(W, TFmuxWindowState(Ord(AValue) * 2));
end;

function TXFrameService.GetStates(const AHandle: TWindowHandle): Cardinal;
var
  W: TXWindow;
begin
  W := WindowOf(AHandle);
  if W <> nil then Result := W.FrameStates else Result := 0;
end;

function TXFrameService.GetCapabilities(const AHandle: TWindowHandle): Cardinal;
begin
  if WindowOf(AHandle) <> nil then Result := FrameCapabilities else Result := 0;
end;

procedure TXFrameService.SetFrameListener(const AHandle: TWindowHandle;
  const AListener: IFMXWaylandWindowFrameListener);
var
  W: TXWindow;
begin
  W := WindowOf(AHandle);
  if W = nil then Exit;
  W.FrameHandle := AHandle;
  W.FrameListener := AListener;
  if AListener = nil then W.FrameHandle := nil else W.NotifyFrame;
end;

procedure AssignX11Api;
begin
  FMUX.Api.FmuxInit := XInit;
  FMUX.Api.FmuxRun := XRun;
  FMUX.Api.FmuxTerminate := XTerminate;
  FMUX.Api.FmuxHandleMessage := XHandleMessage;
  FMUX.Api.FmuxWakeMainThread := XWakeMainThread;
  FMUX.Api.FmuxCreateTimer := XCreateTimer;
  FMUX.Api.FmuxDestroyTimer := XDestroyTimer;
  FMUX.Api.FmuxGetKeyState := XKeyState;
  FMUX.Api.IsWayland := XIsWayland;
  FMUX.Api.FmuxCreateWindow := XCreateWindow;
  FMUX.Api.FmuxDestroyWindow := XDestroyWindowFmux;
  FMUX.Api.FmuxSetMainWindow := XSetMainWindow;
  FMUX.Api.FmuxShowWindow := XShowWindow;
  FMUX.Api.FmuxSetWindowState := XSetWindowState;
  FMUX.Api.FmuxSetWindowTitle := XSetTitle;
  FMUX.Api.FmuxActivateWindow := XActivateWindow;
  FMUX.Api.FmuxWindowBringToFront := XActivateWindow;
  FMUX.Api.FmuxWindowSendToBack := XSendToBack;
  FMUX.Api.FmuxGetClientSize := XGetClientSize;
  FMUX.Api.FmuxSetClientSize := XSetClientSize;
  FMUX.Api.FmuxGetWindowRect := XGetWindowRect;
  FMUX.Api.FmuxSetWindowRect := XSetWindowRect;
  FMUX.Api.FmuxInvalidateRect := XInvalidateRect;
  FMUX.Api.FmuxProcessUpdates := XProcessUpdates;
  FMUX.Api.FmuxClientToScreen := XClientToScreen;
  FMUX.Api.FmuxScreenToClient := XScreenToClient;
  FMUX.Api.FmuxGetWindowScale := XWindowScale;
  FMUX.Api.FmuxGetWindowFullScreen := XGetFullScreen;
  FMUX.Api.FmuxSetWindowFullScreen := XSetFullScreen;
  FMUX.Api.FmuxSetCapture := XSetCapture;
  FMUX.Api.FmuxReleaseCapture := XReleaseCapture;
  FMUX.Api.FmuxGetWindowNativeHandle := XNativeHandle;
  FMUX.Api.FmuxGetWindowNativeDrawingHandle := XNativeHandle;
  FMUX.Api.FmuxShowModal := XShowModal;
  FMUX.Api.FmuxGetScreenSize := XScreenSize;
  FMUX.Api.FmuxGetScreenScale := XScreenScale;
  FMUX.Api.FmuxGetDisplayInfo := XDisplayInfo;
  FMUX.Api.FmuxGetDisplayFromWindow := XDisplayFromWindow;
  FMUX.Api.FmuxGetDisplayFromPoint := XDisplayFromPoint;
  FMUX.Api.FmuxGetMousePos := XMousePos;
  FMUX.Api.FmuxSetCursor := XSetCursor;
  FMUX.Api.FmuxClipboardHasText := XClipboardHasText;
  FMUX.Api.FmuxClipboardGetText := XClipboardGetText;
  FMUX.Api.FmuxClipboardSetText := XClipboardSetText;
  ConfigureWaylandDialogHooks(DialogPump, DialogBeginModal, DialogEndModal);
end;

procedure Disconnect;
var
  W: TXWindow;
begin
  if GDisplay = nil then Exit;
  if GWindows <> nil then
    for W in GWindows.ToArray do XDestroyWindowFmux(W);
  if GCompose <> nil then xkb_compose_state_unref(GCompose);
  if GComposeTable <> nil then xkb_compose_table_unref(GComposeTable);
  if GContext <> nil then xkb_context_unref(GContext);
  if GCursor <> 0 then XFreeCursor(GDisplay, GCursor);
  XCloseDisplay(GDisplay);
  XSetErrorHandler(GPreviousErrorHandler);
  GDisplay := nil;
  GCompose := nil;
  GComposeTable := nil;
  GContext := nil;
  GCursor := 0;
  GSelectionWindow := 0;
  GWMAtoms := nil;
  GWMAtomsLoaded := False;
  CloseFd(GWakeFd);
  FreeAndNil(GTimers);
  FreeAndNil(GTransfers);
  FreeAndNil(GModal);
  FreeAndNil(GWindows);
end;

initialization
finalization
  Disconnect;

end.
