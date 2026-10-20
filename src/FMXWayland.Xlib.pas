{ FMXWayland: minimal LP64 Xlib bindings, loaded only for the X11 backend.
  Copyright (c) 2026 Fasday. MIT license, see LICENSE. }
unit FMXWayland.Xlib;

interface

{$ALIGN 8}

type
  TXID = NativeUInt;
  PXID = ^TXID;
  TXVisualInfo = record
    Visual: Pointer;
    VisualID: TXID;
    Screen, Depth, VisualClass: Integer;
    RedMask, GreenMask, BlueMask: NativeUInt;
    ColormapSize, BitsPerRGB: Integer;
  end;
  PXVisualInfo = ^TXVisualInfo;
  TXRectangle = record
    X, Y: SmallInt;
    Width, Height: Word;
  end;
  TXRectangles = TArray<TXRectangle>;
  TXAnyEvent = record
    Kind: Integer;
    Serial: NativeUInt;
    SendEvent: Integer;
    Display: Pointer;
    Window: TXID;
  end;
  TXKeyEvent = record
    Header: TXAnyEvent;
    Root, Subwindow, Time: TXID;
    X, Y, RootX, RootY: Integer;
    State, KeyCode: Cardinal;
    SameScreen: Integer;
  end;
  TXConfigureEvent = record
    Header: TXAnyEvent;
    Window: TXID;
    X, Y, Width, Height, BorderWidth: Integer;
    Above: TXID;
    OverrideRedirect: Integer;
  end;
  TXFocusEvent = record
    Header: TXAnyEvent;
    Mode, Detail: Integer;
  end;
  TXReparentEvent = record
    Header: TXAnyEvent;
    Window, Parent: TXID;
    X, Y, OverrideRedirect: Integer;
  end;
  TXPropertyEvent = record
    Header: TXAnyEvent;
    Atom, Time: TXID;
    State: Integer;
  end;
  TXErrorEvent = record
    Kind: Integer;
    Display: Pointer;
    ResourceID, Serial: NativeUInt;
    ErrorCode, RequestCode, MinorCode: Byte;
  end;
  PXErrorEvent = ^TXErrorEvent;
  TXClientEvent = record
    Header: TXAnyEvent;
    MessageType: TXID;
    Format: Integer;
    Data: array[0..4] of NativeInt;
  end;
  TXSelectionEvent = record
    Header: TXAnyEvent;
    Selection, Target, Prop, Time: TXID;
  end;
  TXSelectionRequest = record
    Header: TXAnyEvent;
    Requestor, Selection, Target, Prop, Time: TXID;
  end;
  TXEvent = record
    case Integer of
      0: (Any: TXAnyEvent);
      1: (Key: TXKeyEvent);
      2: (Configure: TXConfigureEvent);
      3: (Client: TXClientEvent);
      4: (Selection: TXSelectionEvent);
      5: (Request: TXSelectionRequest);
      6: (Pad: array[0..23] of NativeInt);
      7: (Focus: TXFocusEvent);
      8: (Prop: TXPropertyEvent);
      9: (Reparent: TXReparentEvent);
  end;
  PXEvent = ^TXEvent;
  TXSetWindowAttributes = record
    BackgroundPixmap, BackgroundPixel, BorderPixmap, BorderPixel: TXID;
    BitGravity, WinGravity, BackingStore: Integer;
    BackingPlanes, BackingPixel: NativeUInt;
    SaveUnder: Integer;
    EventMask, DoNotPropagateMask: NativeInt;
    OverrideRedirect: Integer;
    Colormap, Cursor: TXID;
  end;
  PXImage = ^TXImage;
  TXImage = record
    Width, Height, Offset, Format: Integer;
    Data: Pointer;
    ByteOrder, BitmapUnit, BitmapBitOrder, BitmapPad, Depth, BytesPerLine, BitsPerPixel: Integer;
    RedMask, GreenMask, BlueMask: NativeUInt;
    ObData: Pointer;
    Functions: array[0..5] of Pointer;
  end;

var
  XOpenDisplay: function(Name: PAnsiChar): Pointer; cdecl;
  XCloseDisplay: function(D: Pointer): Integer; cdecl;
  XSetErrorHandler: function(Handler: Pointer): Pointer; cdecl;
  XDefaultScreen: function(D: Pointer): Integer; cdecl;
  XRootWindow: function(D: Pointer; Screen: Integer): TXID; cdecl;
  XDefaultVisual: function(D: Pointer; Screen: Integer): Pointer; cdecl;
  XDefaultDepth: function(D: Pointer; Screen: Integer): Integer; cdecl;
  XGetVisualInfo: function(D: Pointer; Mask: NativeInt; Template: PXVisualInfo; Count: PInteger): PXVisualInfo; cdecl;
  XCreateColormap: function(D: Pointer; W: TXID; Visual: Pointer; Alloc: Integer): TXID; cdecl;
  XFreeColormap: function(D: Pointer; Colormap: TXID): Integer; cdecl;
  XDisplayWidth: function(D: Pointer; Screen: Integer): Integer; cdecl;
  XDisplayHeight: function(D: Pointer; Screen: Integer): Integer; cdecl;
  XConnectionNumber: function(D: Pointer): Integer; cdecl;
  XPending: function(D: Pointer): Integer; cdecl;
  XNextEvent: function(D: Pointer; E: PXEvent): Integer; cdecl;
  XFlush: function(D: Pointer): Integer; cdecl;
  XCreateSimpleWindow: function(D: Pointer; Parent: TXID; X, Y: Integer; W, H, Border: Cardinal;
    BorderPixel, Background: NativeUInt): TXID; cdecl;
  XCreateWindowNative: function(D: Pointer; Parent: TXID; X, Y: Integer; W, H, Border: Cardinal;
    Depth: Integer; WindowClass: Cardinal; Visual: Pointer; Mask: NativeUInt; Attr: Pointer): TXID; cdecl;
  XChangeWindowAttributes: function(D: Pointer; W: TXID; Mask: NativeUInt; Attr: Pointer): Integer; cdecl;
  XSelectInput: function(D: Pointer; W: TXID; Mask: NativeInt): Integer; cdecl;
  XDestroyWindow: function(D: Pointer; W: TXID): Integer; cdecl;
  XMapRaised: function(D: Pointer; W: TXID): Integer; cdecl;
  XUnmapWindow: function(D: Pointer; W: TXID): Integer; cdecl;
  XRaiseWindow: function(D: Pointer; W: TXID): Integer; cdecl;
  XLowerWindow: function(D: Pointer; W: TXID): Integer; cdecl;
  XMoveResizeWindow: function(D: Pointer; W: TXID; X, Y: Integer; Width, Height: Cardinal): Integer; cdecl;
  XStoreName: function(D: Pointer; W: TXID; Name: PAnsiChar): Integer; cdecl;
  XInternAtom: function(D: Pointer; Name: PAnsiChar; OnlyIfExists: Integer): TXID; cdecl;
  XSetWMProtocols: function(D: Pointer; W: TXID; Protocols: PXID; Count: Integer): Integer; cdecl;
  XSetTransientForHint: function(D: Pointer; W, Parent: TXID): Integer; cdecl;
  XChangeProperty: function(D: Pointer; W, Prop, Typ: TXID; Format, Mode: Integer;
    Data: Pointer; Count: Integer): Integer; cdecl;
  XGetWindowProperty: function(D: Pointer; W, Prop: TXID; Offset, Count: NativeInt;
    Delete: Integer; ReqType: TXID; ActualType: PXID; Format: PInteger;
    Items, Left: PXID; Data: PPointer): Integer; cdecl;
  XDeleteProperty: function(D: Pointer; W, Prop: TXID): Integer; cdecl;
  XFree: function(Data: Pointer): Integer; cdecl;
  XSendEvent: function(D: Pointer; W: TXID; Propagate: Integer; Mask: NativeInt; E: PXEvent): Integer; cdecl;
  XIconifyWindow: function(D: Pointer; W: TXID; Screen: Integer): Integer; cdecl;
  XTranslateCoordinates: function(D: Pointer; Src, Dst: TXID; X, Y: Integer;
    DX, DY: PInteger; Child: PXID): Integer; cdecl;
  XQueryTree: function(D: Pointer; W: TXID; Root, Parent: PXID; Children: PPointer; Count: PCardinal): Integer; cdecl;
  XGetGeometry: function(D: Pointer; Drawable: TXID; Root: PXID; X, Y: PInteger;
    Width, Height, Border, Depth: PCardinal): Integer; cdecl;
  XQueryPointer: function(D: Pointer; W: TXID; Root, Child: PXID; RX, RY, X, Y: PInteger;
    Mask: PCardinal): Integer; cdecl;
  XGetInputFocus: function(D: Pointer; Focus: PXID; RevertTo: PInteger): Integer; cdecl;
  XGrabPointer: function(D: Pointer; W: TXID; OwnerEvents: Integer; Mask: Cardinal;
    PointerMode, KeyboardMode: Integer; Confine, Cursor, Time: TXID): Integer; cdecl;
  XUngrabPointer: function(D: Pointer; Time: TXID): Integer; cdecl;
  XLookupString: function(E: Pointer; Buffer: PAnsiChar; Size: Integer; Sym: PXID; Compose: Pointer): Integer; cdecl;
  XRefreshKeyboardMapping: function(E: Pointer): Integer; cdecl;
  XCreateGC: function(D: Pointer; Drawable: TXID; Mask: NativeUInt; Values: Pointer): Pointer; cdecl;
  XFreeGC: function(D, GC: Pointer): Integer; cdecl;
  XCreateImage: function(D, Visual: Pointer; Depth: Cardinal; Format, Offset: Integer; Data: Pointer;
    Width, Height: Cardinal; Pad, BytesPerLine: Integer): PXImage; cdecl;
  XDestroyImage: function(Image: PXImage): Integer; cdecl;
  XPutPixel: function(Image: PXImage; X, Y: Integer; Pixel: NativeUInt): Integer; cdecl;
  XPutImage: function(D: Pointer; W: TXID; GC: Pointer; Image: PXImage;
    SX, SY, DX, DY: Integer; Width, Height: Cardinal): Integer; cdecl;
  XCreateFontCursor: function(D: Pointer; Shape: Cardinal): TXID; cdecl;
  XDefineCursor: function(D: Pointer; W, Cursor: TXID): Integer; cdecl;
  XFreeCursor: function(D: Pointer; Cursor: TXID): Integer; cdecl;
  XSetSelectionOwner: function(D: Pointer; Selection, Owner, Time: TXID): Integer; cdecl;
  XGetSelectionOwner: function(D: Pointer; Selection: TXID): TXID; cdecl;
  XConvertSelection: function(D: Pointer; Selection, Target, Prop, Requestor, Time: TXID): Integer; cdecl;

procedure LoadXlib;
/// <summary>Standard premultiplied ARGB32 visual, validated with XRender; nil if unavailable.</summary>
function FindARGBVisual(D: Pointer; Screen: Integer): Pointer;
/// <summary>Shape extension, used for binary transparency on non-composited X11 desktops.</summary>
function HasXShape(D: Pointer): Boolean;
procedure SetXShape(D: Pointer; W: TXID; const Rects: TXRectangles);

implementation

uses
  System.SysUtils, Posix.Dlfcn;

var
  GLib: NativeUInt;
  GLoaded: Boolean;

procedure LoadXlib;

  function Sym(const Name: UTF8String): Pointer;
  begin
    Result := dlsym(GLib, PAnsiChar(Name));
    if Result = nil then
      raise Exception.Create('libX11.so.6 lacks ' + string(Name));
  end;

begin
  if GLoaded then
    Exit;
  if GLib = 0 then
    GLib := dlopen('libX11.so.6', RTLD_NOW or RTLD_LOCAL);
  if GLib = 0 then
    raise Exception.Create('Cannot load libX11.so.6: ' + string(UTF8String(dlerror)));
  XOpenDisplay := Sym('XOpenDisplay');
  XCloseDisplay := Sym('XCloseDisplay');
  XSetErrorHandler := Sym('XSetErrorHandler');
  XDefaultScreen := Sym('XDefaultScreen');
  XRootWindow := Sym('XRootWindow');
  XDefaultVisual := Sym('XDefaultVisual');
  XDefaultDepth := Sym('XDefaultDepth');
  XGetVisualInfo := Sym('XGetVisualInfo');
  XCreateColormap := Sym('XCreateColormap');
  XFreeColormap := Sym('XFreeColormap');
  XDisplayWidth := Sym('XDisplayWidth');
  XDisplayHeight := Sym('XDisplayHeight');
  XConnectionNumber := Sym('XConnectionNumber');
  XPending := Sym('XPending');
  XNextEvent := Sym('XNextEvent');
  XFlush := Sym('XFlush');
  XCreateSimpleWindow := Sym('XCreateSimpleWindow');
  XCreateWindowNative := Sym('XCreateWindow');
  XChangeWindowAttributes := Sym('XChangeWindowAttributes');
  XSelectInput := Sym('XSelectInput');
  XDestroyWindow := Sym('XDestroyWindow');
  XMapRaised := Sym('XMapRaised');
  XUnmapWindow := Sym('XUnmapWindow');
  XRaiseWindow := Sym('XRaiseWindow');
  XLowerWindow := Sym('XLowerWindow');
  XMoveResizeWindow := Sym('XMoveResizeWindow');
  XStoreName := Sym('XStoreName');
  XInternAtom := Sym('XInternAtom');
  XSetWMProtocols := Sym('XSetWMProtocols');
  XSetTransientForHint := Sym('XSetTransientForHint');
  XChangeProperty := Sym('XChangeProperty');
  XGetWindowProperty := Sym('XGetWindowProperty');
  XDeleteProperty := Sym('XDeleteProperty');
  XFree := Sym('XFree');
  XSendEvent := Sym('XSendEvent');
  XIconifyWindow := Sym('XIconifyWindow');
  XTranslateCoordinates := Sym('XTranslateCoordinates');
  XQueryTree := Sym('XQueryTree');
  XGetGeometry := Sym('XGetGeometry');
  XQueryPointer := Sym('XQueryPointer');
  XGetInputFocus := Sym('XGetInputFocus');
  XGrabPointer := Sym('XGrabPointer');
  XUngrabPointer := Sym('XUngrabPointer');
  XLookupString := Sym('XLookupString');
  XRefreshKeyboardMapping := Sym('XRefreshKeyboardMapping');
  XCreateGC := Sym('XCreateGC');
  XFreeGC := Sym('XFreeGC');
  XCreateImage := Sym('XCreateImage');
  XDestroyImage := Sym('XDestroyImage');
  XPutPixel := Sym('XPutPixel');
  XPutImage := Sym('XPutImage');
  XCreateFontCursor := Sym('XCreateFontCursor');
  XDefineCursor := Sym('XDefineCursor');
  XFreeCursor := Sym('XFreeCursor');
  XSetSelectionOwner := Sym('XSetSelectionOwner');
  XGetSelectionOwner := Sym('XGetSelectionOwner');
  XConvertSelection := Sym('XConvertSelection');
  GLoaded := True;
end;

type
  TXRenderDirectFormat = record
    Red, RedMask, Green, GreenMask, Blue, BlueMask, Alpha, AlphaMask: SmallInt;
  end;
  TXRenderPictFormat = record
    ID: TXID;
    Kind, Depth: Integer;
    Direct: TXRenderDirectFormat;
    Colormap: TXID;
  end;
  PXRenderPictFormat = ^TXRenderPictFormat;

var
  GRenderLib, GShapeLib: NativeUInt;
  GRenderTried, GShapeTried: Boolean;
  XRenderFindVisualFormat: function(D, Visual: Pointer): PXRenderPictFormat; cdecl;
  XShapeQueryExtension: function(D: Pointer; EventBase, ErrorBase: PInteger): Integer; cdecl;
  XShapeCombineRectangles: procedure(D: Pointer; W: TXID; Kind, X, Y: Integer;
    Rectangles: Pointer; Count, Operation, Ordering: Integer); cdecl;

function FindARGBVisual(D: Pointer; Screen: Integer): Pointer;
var
  Template: TXVisualInfo;
  Visuals, Visual: PXVisualInfo;
  Format: PXRenderPictFormat;
  Count, I: Integer;
begin
  Result := nil;
  if not GRenderTried then
  begin
    GRenderTried := True;
    GRenderLib := dlopen('libXrender.so.1', RTLD_NOW or RTLD_LOCAL);
    if GRenderLib <> 0 then XRenderFindVisualFormat := dlsym(GRenderLib, 'XRenderFindVisualFormat');
  end;
  if not Assigned(XRenderFindVisualFormat) then Exit;
  Template := Default(TXVisualInfo);
  Template.Screen := Screen;
  Template.Depth := 32;
  Template.VisualClass := 4; // TrueColor
  Visuals := XGetVisualInfo(D, 2 or 4 or 8, @Template, @Count);
  if Visuals = nil then Exit;
  try
    for I := 0 to Count - 1 do
    begin
      Visual := PXVisualInfo(PByte(Visuals) + I * SizeOf(TXVisualInfo));
      Format := XRenderFindVisualFormat(D, Visual.Visual);
      if (Format <> nil) and (Format.Kind = 1) and (Format.Depth = 32) and
        (Format.Direct.Red = 16) and (Format.Direct.RedMask = 255) and
        (Format.Direct.Green = 8) and (Format.Direct.GreenMask = 255) and
        (Format.Direct.Blue = 0) and (Format.Direct.BlueMask = 255) and
        (Format.Direct.Alpha = 24) and (Format.Direct.AlphaMask = 255) then
        Exit(Visual.Visual);
    end;
  finally
    XFree(Visuals);
  end;
end;

function HasXShape(D: Pointer): Boolean;
var
  EventBase, ErrorBase: Integer;
begin
  if not GShapeTried then
  begin
    GShapeTried := True;
    GShapeLib := dlopen('libXext.so.6', RTLD_NOW or RTLD_LOCAL);
    if GShapeLib <> 0 then
    begin
      XShapeQueryExtension := dlsym(GShapeLib, 'XShapeQueryExtension');
      XShapeCombineRectangles := dlsym(GShapeLib, 'XShapeCombineRectangles');
    end;
  end;
  Result := Assigned(XShapeQueryExtension) and Assigned(XShapeCombineRectangles);
  if Result then Result := XShapeQueryExtension(D, @EventBase, @ErrorBase) <> 0;
end;

procedure SetXShape(D: Pointer; W: TXID; const Rects: TXRectangles);
var
  Offset, Count, Operation: Integer;
begin
  // Keep each request below the core protocol size limit. First replace, then union further chunks.
  Offset := 0;
  Operation := 0; // ShapeSet
  repeat
    Count := Length(Rects) - Offset;
    if Count > 2048 then Count := 2048;
    if Count = 0 then
      XShapeCombineRectangles(D, W, 0, 0, 0, nil, 0, Operation, 0)
    else
      XShapeCombineRectangles(D, W, 0, 0, 0, @Rects[Offset], Count, Operation, 0);
    Inc(Offset, Count);
    Operation := 1; // ShapeUnion
  until Offset >= Length(Rects);
end;

end.
