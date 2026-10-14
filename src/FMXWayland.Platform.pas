{ FMXWayland: native Wayland platform for Delphi FireMonkey on Linux.
  Copyright (c) 2026 Fasday. MIT license, see LICENSE. }

/// <summary>The Wayland side of FMXWayland, independent of FMX: the connection and its globals, outputs, the event
/// loop (display fd + eventfd for wake-ups + timers), windows (xdg_toplevel / xdg_popup surfaces painted through
/// wl_shm buffers), pointer, keyboard (xkbcommon, key repeat, compose), cursors and the clipboard.</summary>
/// <remarks>Everything runs on the main thread except TWlDisplay.Wake. FMXWayland.Fmux adapts this to the FMUX API
/// that FMX for Linux calls.</remarks>
unit FMXWayland.Platform;

interface

{$SCOPEDENUMS ON}

uses
  System.SysUtils, System.Types, System.Classes, System.Generics.Collections, System.Generics.Defaults,
  FMXWayland.Wayland, FMXWayland.Protocol.Wayland, FMXWayland.Protocol.XdgShell,
  FMXWayland.Protocol.XdgDecorationUnstableV1, FMXWayland.Protocol.Viewporter, FMXWayland.Protocol.FractionalScaleV1,
  FMXWayland.Protocol.CursorShapeV1, FMXWayland.Protocol.XdgActivationV1, FMXWayland.Xkb, FMXWayland.WaylandCursor;

const
  /// <summary>Bits of the modifier and button state passed with input events (the values of FMUX_STATE_*).</summary>
  WL_STATE_SHIFT = 1;
  WL_STATE_ALT = 2;
  WL_STATE_CTRL = 4;
  WL_STATE_LEFT = 8;
  WL_STATE_RIGHT = 16;
  WL_STATE_MIDDLE = 32;
  WL_STATE_DOUBLE = 64;
  WL_STATE_SUPER = 128;

type
  TWlDisplay = class;
  TWlWindow = class;

  /// <summary>What a window is on the Wayland side.</summary>
  TWlWindowKind = (Toplevel, Popup);
  /// <summary>State of a toplevel (the values of TFmuxWindowState / FMX TWindowState).</summary>
  TWlWindowState = (Normal, Minimized, Maximized);
  /// <summary>Kinds of pointer events delivered to windows.</summary>
  TWlPointerEvent = (Move, Down, Up, Wheel, Leave);
  /// <summary>Kinds of key events delivered to windows.</summary>
  TWlKeyEvent = (Down, Up);

  /// <summary>A wl_shm buffer (shared memory, 4 bytes per pixel, premultiplied BGRA in memory).</summary>
  TWlBuffer = class
  private
    FDisplay: TWlDisplay;
    FBuffer: Pwl_buffer;
    FData: Pointer;
    FSize: NativeInt;
    FWidth: Integer;
    FHeight: Integer;
    FStride: Integer;
    FBusy: Boolean;
  public
    constructor Create(const ADisplay: TWlDisplay; const AWidth, AHeight: Integer; const AFormat: UInt32);
    destructor Destroy; override;
    property Buffer: Pwl_buffer read FBuffer;
    property Data: Pointer read FData;
    property Width: Integer read FWidth;
    property Height: Integer read FHeight;
    property Stride: Integer read FStride;
    /// <summary>Attached to a surface and not yet released by the compositor.</summary>
    property Busy: Boolean read FBusy write FBusy;
  end;

  /// <summary>The pixels of a frame being painted (handed to the canvas as its context): a wl_shm buffer of the
  /// window, premultiplied BGRA, Width x Height buffer pixels = logical size x Scale.</summary>
  TWlFrame = record
    Bits: Pointer;
    Stride: Integer;
    Width: Integer;
    Height: Integer;
    Scale: Single;
    /// <summary>Set by whoever drew into Bits: only then the buffer is attached and committed.</summary>
    Drawn: Boolean;
  end;
  PWlFrame = ^TWlFrame;

  /// <summary>A wl_output (monitor).</summary>
  TWlOutput = class
  private
    FDisplay: TWlDisplay;
    FOutput: Pwl_output;
    FGlobalName: UInt32;
    FX: Integer;
    FY: Integer;
    FModeWidth: Integer;
    FModeHeight: Integer;
    FRefresh: Integer;
    FScale: Integer;
    FTransform: Integer;
    FPhysicalWidth: Integer;
    FPhysicalHeight: Integer;
    FMake: string;
    FModel: string;
    FName: string;
    FDescription: string;
    function GetLogicalBounds: TRect;
  public
    destructor Destroy; override;
    property Output: Pwl_output read FOutput;
    property GlobalName: UInt32 read FGlobalName;
    /// <summary>Position and size in logical pixels (mode size / scale).</summary>
    property LogicalBounds: TRect read GetLogicalBounds;
    property Scale: Integer read FScale;
    property ModeWidth: Integer read FModeWidth;
    property ModeHeight: Integer read FModeHeight;
    property Refresh: Integer read FRefresh;
    property Name: string read FName;
    property Description: string read FDescription;
    property Make: string read FMake;
    property Model: string read FModel;
  end;

  /// <summary>A window: a wl_surface with the xdg_toplevel or xdg_popup role, painted through wl_shm buffers.
  /// Its position is virtual (Wayland clients do not know where their windows are): toplevels keep the position FMX
  /// gives them, popups are placed relative to their parent and report where the compositor put them.</summary>
  /// <remarks>Subclasses receive the events by overriding the Do* methods.</remarks>
  TWlWindow = class
  private
    FDisplay: TWlDisplay;
    FKind: TWlWindowKind;
    FSurface: Pwl_surface;
    FXdgSurface: Pxdg_surface;
    FToplevel: Pxdg_toplevel;
    FPopup: Pxdg_popup;
    FDecoration: Pzxdg_toplevel_decoration_v1;
    FViewport: Pwp_viewport;
    FFractional: Pwp_fractional_scale_v1;
    FFrameCallback: Pwl_callback;
    FFrameRequestedAt: Int64;
    FBuffers: TObjectList<TWlBuffer>;
    FParent: TWlWindow;
    FOrigin: TPointF;
    FWidth: Integer;
    FHeight: Integer;
    FNormalWidth: Integer;
    FNormalHeight: Integer;
    FScale: Single;
    FIntScale: Integer;
    FFractionalScale: Single;
    FPreferredIntScale: Integer;
    FEnteredOutputs: TList<Pwl_output>;
    FTitle: string;
    FAppId: string;
    FTransparent: Boolean;
    FBorderless: Boolean;
    FVisible: Boolean;
    FConfigured: Boolean;
    FMapped: Boolean;
    FDirty: TRectF;
    FFullDamage: Boolean;
    FState: TWlWindowState;
    FFullScreen: Boolean;
    FActivated: Boolean;
    FPendingWidth: Integer;
    FPendingHeight: Integer;
    FPendingMaximized: Boolean;
    FPendingFullScreen: Boolean;
    FPendingActivated: Boolean;
    FLastBufferScale: Integer;
    FOpaqueWidth: Integer;
    FOpaqueHeight: Integer;
    FExternalPresentation: Boolean;
    FMinWidth: Integer;
    FMinHeight: Integer;
    procedure CreateToplevelRole;
    procedure CreatePopupRole;
    procedure DestroyRole;
    procedure HideChildPopups;
    function AcquireBuffer(const AWidth, AHeight: Integer): TWlBuffer;
    procedure UpdateScale;
    procedure HandleXdgConfigure(const ASerial: UInt32);
    function NeedsPaint(const ANow: Int64): Boolean;
    function GetBufferWidth: Integer;
    function GetBufferHeight: Integer;
  protected
    /// <summary>Paint ADirty (logical coordinates) into AFrame; set AFrame.Drawn when the frame was drawn.</summary>
    procedure DoPaint(const AFrame: PWlFrame; const ADirty: TRectF); virtual;
    /// <summary>The compositor changed the size (Width/Height are already the new ones).</summary>
    procedure DoResized; virtual;
    /// <summary>The compositor placed a popup elsewhere than requested (Origin is already the new one).</summary>
    procedure DoMoved; virtual;
    /// <summary>The compositor changed the state (maximized/normal).</summary>
    procedure DoStateChanged(const AState: TWlWindowState); virtual;
    /// <summary>The toplevel became the active window or stopped being it.</summary>
    procedure DoActivate(const AActive: Boolean); virtual;
    /// <summary>The user asked to close the window (close button of the decorations).</summary>
    procedure DoCloseRequest; virtual;
    /// <summary>The compositor dismissed a popup.</summary>
    procedure DoPopupDone; virtual;
    /// <summary>Pointer event at (AX, AY) in logical window coordinates; AState = WL_STATE_* bits; AWheelDelta in
    /// 1/120 of a notch, positive = away from the user (scroll up), for Wheel.</summary>
    procedure DoPointer(const AEvent: TWlPointerEvent; const AX, AY: Single; const AState, AWheelDelta: Integer);
      virtual;
    /// <summary>Key event: AKey = FMX virtual key (0 for pure characters), AChar = character or #0.</summary>
    procedure DoKey(const AEvent: TWlKeyEvent; const AKey: Word; const AChar: Char; const AState: Integer); virtual;
    /// <summary>The window's scale changed.</summary>
    procedure DoScaleChanged; virtual;
  public
    constructor Create(const ADisplay: TWlDisplay; const AKind: TWlWindowKind; const ATransparent: Boolean);
    destructor Destroy; override;
    /// <summary>Maps the window (toplevel: commits the role and waits for the configure; popup: creates the xdg_popup
    /// at Origin relative to Parent).</summary>
    procedure Show;
    /// <summary>Unmaps the window (and its popups).</summary>
    procedure Hide;
    /// <summary>Sets the virtual position and the size (logical pixels).</summary>
    procedure SetBounds(const AX, AY: Single; const AWidth, AHeight: Integer);
    /// <summary>Sets the size (logical pixels).</summary>
    procedure SetSize(const AWidth, AHeight: Integer);
    procedure SetTitle(const ATitle: string);
    procedure SetAppId(const AAppId: string);
    procedure SetState(const AState: TWlWindowState);
    procedure SetFullScreen(const AValue: Boolean);
    procedure SetMinSize(const AWidth, AHeight: Integer);
    /// <summary>Tells the compositor that a toplevel belongs to Parent (dialogs stay above it).</summary>
    procedure SetTransientParent;
    /// <summary>Marks a rectangle (logical coordinates) for repainting.</summary>
    procedure Invalidate(const ARect: TRectF);
    /// <summary>Marks the whole window for repainting.</summary>
    procedure InvalidateAll;
    /// <summary>Paints now if something is dirty (does not wait for the frame callback).</summary>
    procedure PaintNow;
    function ClientToScreen(const APoint: TPointF): TPointF;
    function ScreenToClient(const APoint: TPointF): TPointF;
    /// <summary>The output the window is on (the first it entered), or nil.</summary>
    function CurrentOutput: TWlOutput;
    property Display: TWlDisplay read FDisplay;
    property Kind: TWlWindowKind read FKind;
    property Surface: Pwl_surface read FSurface;
    property XdgSurface: Pxdg_surface read FXdgSurface;
    property Toplevel: Pxdg_toplevel read FToplevel;
    /// <summary>Parent of a popup (or transient parent of a toplevel, e.g. a modal dialog).</summary>
    property Parent: TWlWindow read FParent write FParent;
    property Origin: TPointF read FOrigin write FOrigin;
    property Width: Integer read FWidth;
    property Height: Integer read FHeight;
    /// <summary>Buffer pixels per logical pixel.</summary>
    property Scale: Single read FScale;
    property BufferWidth: Integer read GetBufferWidth;
    property BufferHeight: Integer read GetBufferHeight;
    property Visible: Boolean read FVisible;
    property Mapped: Boolean read FMapped;
    property State: TWlWindowState read FState;
    property FullScreen: Boolean read FFullScreen;
    property Activated: Boolean read FActivated;
    property Title: string read FTitle;
    property Borderless: Boolean read FBorderless write FBorderless;
    /// <summary>Someone else (a GPU canvas through Vulkan WSI) presents to the surface: no wl_shm frames.</summary>
    property ExternalPresentation: Boolean read FExternalPresentation write FExternalPresentation;
  end;

  /// <summary>A data offer (clipboard or drag-and-drop) and its MIME types.</summary>
  TWlDataOffer = class
  private
    FOffer: Pwl_data_offer;
    FMimeTypes: TList<string>;
  public
    constructor Create(const AOffer: Pwl_data_offer);
    destructor Destroy; override;
    function HasMimeType(const AMimeType: string): Boolean;
    property Offer: Pwl_data_offer read FOffer;
    property MimeTypes: TList<string> read FMimeTypes;
  end;

  /// <summary>A timer of the event loop.</summary>
  TWlTimer = class
  private
    FId: NativeInt;
    FInterval: Integer;
    FDue: Int64;
    FProc: TProc;
  end;

  /// <summary>The connection to the compositor (one per process: WlDisplay).</summary>
  TWlDisplay = class
  private
    FDisplay: Pwl_display;
    FRegistry: Pwl_registry;
    FCompositor: Pwl_compositor;
    FCompositorVersion: UInt32;
    FShm: Pwl_shm;
    FWmBase: Pxdg_wm_base;
    FSeat: Pwl_seat;
    FSeatVersion: UInt32;
    FSeatName: UInt32;
    FDataDeviceManager: Pwl_data_device_manager;
    FDataDevice: Pwl_data_device;
    FViewporter: Pwp_viewporter;
    FFractionalScaleManager: Pwp_fractional_scale_manager_v1;
    FCursorShapeManager: Pwp_cursor_shape_manager_v1;
    FDecorationManager: Pzxdg_decoration_manager_v1;
    FActivation: Pxdg_activation_v1;
    FGlobals: TStringList;
    FOutputs: TObjectList<TWlOutput>;
    FWindows: TList<TWlWindow>;
    FWakeFd: Integer;
    FWakeProc: TProc;
    FIdleProc: TProc;
    FTerminated: Boolean;
    FTimers: TObjectDictionary<NativeInt, TWlTimer>;
    FNextTimerId: NativeInt;
    FAppId: string;
    // pointer
    FPointer: Pwl_pointer;
    FCursorShapeDevice: Pwp_cursor_shape_device_v1;
    FPointerWindow: TWlWindow;
    FPointerPos: TPointF;
    FPointerSerial: UInt32;
    FButtons: Integer;
    FAxisValue: Double;
    FAxisDiscrete: Integer;
    FAxis120: Integer;
    FAxisRemainder: Double;
    FHasAxis: Boolean;
    FLastClickTime: UInt32;
    FLastClickButton: Integer;
    FLastClickPos: TPointF;
    FLastClickWindow: TWlWindow;
    FCursor: Integer;
    FCursorTheme: Pwl_cursor_theme;
    FCursorThemeScale: Integer;
    FCursorSurface: Pwl_surface;
    // keyboard
    FKeyboard: Pwl_keyboard;
    FKeyboardWindow: TWlWindow;
    FXkbContext: PXkbContext;
    FXkbKeymap: PXkbKeymap;
    FXkbState: PXkbState;
    FComposeTable: PXkbComposeTable;
    FComposeState: PXkbComposeState;
    FModState: Integer;
    FRepeatRate: Integer;
    FRepeatDelay: Integer;
    FRepeatKey: UInt32;
    FRepeatTimer: NativeInt;
    FLastInputSerial: UInt32;
    FLastInputWindow: TWlWindow;
    // clipboard
    FOffers: TObjectDictionary<Pwl_data_offer, TWlDataOffer>;
    FSelection: TWlDataOffer;
    FDragOffer: TWlDataOffer;
    FOwnSource: Pwl_data_source;
    FOwnText: UTF8String;
    procedure HandleGlobal(const AName: UInt32; const AInterface: string; const AVersion: UInt32);
    procedure HandleGlobalRemove(const AName: UInt32);
    procedure HandleCapabilities(const ACapabilities: UInt32);
    procedure CheckConnection;
    function RunTimers: Boolean;
    function NextTimerDue: Int64;
    function PaintWindows: Boolean;
    procedure DrainWake;
    function WindowFromSurface(const ASurface: Pwl_surface): TWlWindow;
    procedure RemoveWindow(const AWindow: TWlWindow);
    procedure ApplyCursor;
    function LoadCursorTheme: Boolean;
    procedure HandleKeymap(const AFormat: UInt32; const AFd: Integer; const ASize: UInt32);
    procedure HandleKey(const AKey: UInt32; const APressed: Boolean);
    procedure HandleModifiers(const ADepressed, ALatched, ALocked, AGroup: UInt32);
    procedure StopKeyRepeat;
    procedure DeliverKeyDown(const AKey: UInt32);
    procedure FlushAxis;
    procedure ReleaseXkb;
    function ReadOffer(const AOffer: TWlDataOffer; const AMimeType: string; out AData: TBytes): Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    /// <summary>Connects (WAYLAND_DISPLAY), binds the globals and waits for the outputs, the seat and the keymap.
    /// Raises an exception with an explanation when that is not possible.</summary>
    procedure Connect;
    /// <summary>One round of the event loop: dispatches events, runs due timers, paints dirty windows; waits up to
    /// ATimeoutMs for something to happen (-1 = until something happens, 0 = do not wait). True if anything was
    /// done.</summary>
    function ProcessEvents(const ATimeoutMs: Integer): Boolean;
    /// <summary>Runs the loop until Terminate or ADone returns True; calls the idle procedure each time the loop
    /// runs out of work.</summary>
    procedure RunLoop(const ADone: TFunc<Boolean>);
    /// <summary>Makes RunLoop return.</summary>
    procedure Terminate;
    /// <summary>Wakes the loop (any thread); the wake procedure then runs on the main thread.</summary>
    procedure Wake;
    /// <summary>Calls wl_display_flush.</summary>
    procedure Flush;
    /// <summary>A periodic timer of the loop; returns its id (never 0).</summary>
    function CreateTimer(const AIntervalMs: Integer; const AProc: TProc): NativeInt;
    function DestroyTimer(const AId: NativeInt): Boolean;
    /// <summary>Sets the pointer cursor (a System.UITypes TCursor value: crDefault, crIBeam, ...).</summary>
    procedure SetCursor(const ACursor: Integer);
    /// <summary>The primary output (at 0,0 or the first one), or nil.</summary>
    function PrimaryOutput: TWlOutput;
    /// <summary>Outputs with the primary one first.</summary>
    function OrderedOutputs: TArray<TWlOutput>;
    /// <summary>Pointer position in virtual screen coordinates.</summary>
    function PointerScreenPos: TPointF;
    /// <summary>True when the clipboard holds text.</summary>
    function ClipboardHasText: Boolean;
    /// <summary>Text of the clipboard ('' if none); waits for the owner up to 2 seconds.</summary>
    function ClipboardGetText: string;
    /// <summary>Puts text into the clipboard (this client becomes the selection owner).</summary>
    procedure ClipboardSetText(const AText: string);
    /// <summary>Wraps a protocol global's name ('wl_compositor 4', ...) for diagnostics.</summary>
    function GlobalsText: string;
    property Display: Pwl_display read FDisplay;
    property Compositor: Pwl_compositor read FCompositor;
    property Shm: Pwl_shm read FShm;
    property WmBase: Pxdg_wm_base read FWmBase;
    property Seat: Pwl_seat read FSeat;
    property Viewporter: Pwp_viewporter read FViewporter;
    property FractionalScaleManager: Pwp_fractional_scale_manager_v1 read FFractionalScaleManager;
    property DecorationManager: Pzxdg_decoration_manager_v1 read FDecorationManager;
    property Outputs: TObjectList<TWlOutput> read FOutputs;
    property Windows: TList<TWlWindow> read FWindows;
    property PointerWindow: TWlWindow read FPointerWindow;
    property KeyboardWindow: TWlWindow read FKeyboardWindow;
    /// <summary>The window of the last button press or key press.</summary>
    property LastInputWindow: TWlWindow read FLastInputWindow;
    property LastInputSerial: UInt32 read FLastInputSerial;
    /// <summary>WL_STATE_* bits of the modifiers and buttons held now.</summary>
    property ModState: Integer read FModState;
    property Buttons: Integer read FButtons;
    property Terminated: Boolean read FTerminated;
    property AppId: string read FAppId write FAppId;
    /// <summary>Runs when the loop is woken by Wake (on the main thread).</summary>
    property WakeProc: TProc read FWakeProc write FWakeProc;
    /// <summary>Runs each time RunLoop runs out of work.</summary>
    property IdleProc: TProc read FIdleProc write FIdleProc;
  end;

/// <summary>The connection, after WlConnect.</summary>
function WlDisplay: TWlDisplay;
/// <summary>Creates and connects the connection (once).</summary>
function WlConnect: TWlDisplay;
/// <summary>Disconnects and frees the connection.</summary>
procedure WlDisconnect;

implementation

uses
  System.Math, System.UITypes, Posix.Unistd, Posix.SysMman, Posix.Errno, FMXWayland.Posix, FMXWayland.Log,
  FMXWayland.Keys;

var
  GDisplay: TWlDisplay = nil;

function WlDisplay: TWlDisplay;
begin
  Result := GDisplay;
end;

function WlConnect: TWlDisplay;
begin
  if GDisplay = nil then
  begin
    GDisplay := TWlDisplay.Create;
    try
      GDisplay.Connect;
    except
      FreeAndNil(GDisplay);
      raise;
    end;
  end;
  Result := GDisplay;
end;

procedure WlDisconnect;
begin
  FreeAndNil(GDisplay);
end;

function Utf8ToStr(const AValue: PAnsiChar): string;
begin
  if AValue = nil then
    Result := ''
  else
    Result := UTF8ToString(AValue);
end;

{$REGION 'Listeners: registry, output, wm_base, buffer, callback'}

procedure RegistryGlobal(AData: Pointer; AWlRegistry: Pwl_registry; AName: UInt32; AInterface: PAnsiChar;
  AVersion: UInt32); cdecl;
begin
  TWlDisplay(AData).HandleGlobal(AName, Utf8ToStr(AInterface), AVersion);
end;

procedure RegistryGlobalRemove(AData: Pointer; AWlRegistry: Pwl_registry; AName: UInt32); cdecl;
begin
  TWlDisplay(AData).HandleGlobalRemove(AName);
end;

const
  CRegistryListener: Twl_registry_listener = (global: RegistryGlobal; global_remove: RegistryGlobalRemove);

procedure OutputGeometry(AData: Pointer; AWlOutput: Pwl_output; AX, AY, APhysicalWidth, APhysicalHeight,
  ASubpixel: Int32; AMake, AModel: PAnsiChar; ATransform: Int32); cdecl;
var
  O: TWlOutput;
begin
  O := TWlOutput(AData);
  O.FX := AX;
  O.FY := AY;
  O.FPhysicalWidth := APhysicalWidth;
  O.FPhysicalHeight := APhysicalHeight;
  O.FMake := Utf8ToStr(AMake);
  O.FModel := Utf8ToStr(AModel);
  O.FTransform := ATransform;
end;

procedure OutputMode(AData: Pointer; AWlOutput: Pwl_output; AFlags: UInt32; AWidth, AHeight, ARefresh: Int32); cdecl;
var
  O: TWlOutput;
begin
  if AFlags and WL_OUTPUT_MODE_CURRENT <> 0 then
  begin
    O := TWlOutput(AData);
    O.FModeWidth := AWidth;
    O.FModeHeight := AHeight;
    O.FRefresh := ARefresh;
  end;
end;

procedure OutputDone(AData: Pointer; AWlOutput: Pwl_output); cdecl;
var
  O: TWlOutput;
begin
  O := TWlOutput(AData);
  WlLog(TWlLogLevel.Debug, 'output %s "%s %s": %dx%d+%d+%d scale %d', [O.FName, O.FMake, O.FModel, O.FModeWidth,
    O.FModeHeight, O.FX, O.FY, O.FScale]);
end;

procedure OutputScale(AData: Pointer; AWlOutput: Pwl_output; AFactor: Int32); cdecl;
begin
  TWlOutput(AData).FScale := Max(1, AFactor);
end;

procedure OutputName(AData: Pointer; AWlOutput: Pwl_output; AName: PAnsiChar); cdecl;
begin
  TWlOutput(AData).FName := Utf8ToStr(AName);
end;

procedure OutputDescription(AData: Pointer; AWlOutput: Pwl_output; ADescription: PAnsiChar); cdecl;
begin
  TWlOutput(AData).FDescription := Utf8ToStr(ADescription);
end;

const
  COutputListener: Twl_output_listener = (geometry: OutputGeometry; mode: OutputMode; done: OutputDone;
    scale: OutputScale; name: OutputName; description: OutputDescription);

procedure WmBasePing(AData: Pointer; AXdgWmBase: Pxdg_wm_base; ASerial: UInt32); cdecl;
begin
  xdg_wm_base_pong(AXdgWmBase, ASerial);
end;

const
  CWmBaseListener: Txdg_wm_base_listener = (ping: WmBasePing);

procedure BufferRelease(AData: Pointer; AWlBuffer: Pwl_buffer); cdecl;
begin
  TWlBuffer(AData).FBusy := False;
end;

const
  CBufferListener: Twl_buffer_listener = (release: BufferRelease);

procedure FrameDone(AData: Pointer; AWlCallback: Pwl_callback; ACallbackData: UInt32); cdecl;
var
  W: TWlWindow;
begin
  W := TWlWindow(AData);
  if W.FFrameCallback = AWlCallback then
    W.FFrameCallback := nil;
  wl_callback_destroy(AWlCallback);
end;

const
  CFrameListener: Twl_callback_listener = (done: FrameDone);

{$ENDREGION}

{$REGION 'Listeners: surface, xdg_surface, xdg_toplevel, xdg_popup, decoration, fractional scale'}

procedure SurfaceEnter(AData: Pointer; AWlSurface: Pwl_surface; AOutput: Pwl_output); cdecl;
var
  W: TWlWindow;
begin
  W := TWlWindow(AData);
  if not W.FEnteredOutputs.Contains(AOutput) then
    W.FEnteredOutputs.Add(AOutput);
  W.UpdateScale;
end;

procedure SurfaceLeave(AData: Pointer; AWlSurface: Pwl_surface; AOutput: Pwl_output); cdecl;
var
  W: TWlWindow;
begin
  W := TWlWindow(AData);
  W.FEnteredOutputs.Remove(AOutput);
  W.UpdateScale;
end;

procedure SurfacePreferredBufferScale(AData: Pointer; AWlSurface: Pwl_surface; AFactor: Int32); cdecl;
var
  W: TWlWindow;
begin
  W := TWlWindow(AData);
  W.FPreferredIntScale := Max(1, AFactor);
  W.UpdateScale;
end;

procedure SurfacePreferredBufferTransform(AData: Pointer; AWlSurface: Pwl_surface; ATransform: UInt32); cdecl;
begin
end;

const
  CSurfaceListener: Twl_surface_listener = (enter: SurfaceEnter; leave: SurfaceLeave;
    preferred_buffer_scale: SurfacePreferredBufferScale; preferred_buffer_transform: SurfacePreferredBufferTransform);

procedure XdgSurfaceConfigure(AData: Pointer; AXdgSurface: Pxdg_surface; ASerial: UInt32); cdecl;
begin
  TWlWindow(AData).HandleXdgConfigure(ASerial);
end;

const
  CXdgSurfaceListener: Txdg_surface_listener = (configure: XdgSurfaceConfigure);

procedure ToplevelConfigure(AData: Pointer; AXdgToplevel: Pxdg_toplevel; AWidth, AHeight: Int32;
  AStates: Pwl_array); cdecl;
var
  W: TWlWindow;
  P: PCardinal;
  I: Integer;
begin
  W := TWlWindow(AData);
  W.FPendingWidth := AWidth;
  W.FPendingHeight := AHeight;
  W.FPendingMaximized := False;
  W.FPendingFullScreen := False;
  W.FPendingActivated := False;
  if (AStates <> nil) and (AStates.data <> nil) then
  begin
    P := AStates.data;
    for I := 0 to Integer(AStates.size div SizeOf(Cardinal)) - 1 do
    begin
      case P^ of
        XDG_TOPLEVEL_STATE_MAXIMIZED:
          W.FPendingMaximized := True;
        XDG_TOPLEVEL_STATE_FULLSCREEN:
          W.FPendingFullScreen := True;
        XDG_TOPLEVEL_STATE_ACTIVATED:
          W.FPendingActivated := True;
      end;
      Inc(P);
    end;
  end;
end;

procedure ToplevelClose(AData: Pointer; AXdgToplevel: Pxdg_toplevel); cdecl;
begin
  TWlWindow(AData).DoCloseRequest;
end;

procedure ToplevelConfigureBounds(AData: Pointer; AXdgToplevel: Pxdg_toplevel; AWidth, AHeight: Int32); cdecl;
begin
end;

procedure ToplevelWmCapabilities(AData: Pointer; AXdgToplevel: Pxdg_toplevel; ACapabilities: Pwl_array); cdecl;
begin
end;

const
  CToplevelListener: Txdg_toplevel_listener = (configure: ToplevelConfigure; close: ToplevelClose;
    configure_bounds: ToplevelConfigureBounds; wm_capabilities: ToplevelWmCapabilities);

procedure PopupConfigure(AData: Pointer; AXdgPopup: Pxdg_popup; AX, AY, AWidth, AHeight: Int32); cdecl;
var
  W: TWlWindow;
  NewOrigin: TPointF;
begin
  W := TWlWindow(AData);
  if W.FParent <> nil then
  begin
    NewOrigin := PointF(W.FParent.FOrigin.X + AX, W.FParent.FOrigin.Y + AY);
    if (Abs(NewOrigin.X - W.FOrigin.X) >= 1) or (Abs(NewOrigin.Y - W.FOrigin.Y) >= 1) then
    begin
      W.FOrigin := NewOrigin;
      W.DoMoved;
    end;
  end;
  if (AWidth > 0) and (AHeight > 0) and ((AWidth <> W.FWidth) or (AHeight <> W.FHeight)) then
  begin
    W.FWidth := AWidth;
    W.FHeight := AHeight;
    W.DoResized;
  end;
end;

procedure PopupDone(AData: Pointer; AXdgPopup: Pxdg_popup); cdecl;
begin
  TWlWindow(AData).DoPopupDone;
end;

procedure PopupRepositioned(AData: Pointer; AXdgPopup: Pxdg_popup; AToken: UInt32); cdecl;
begin
end;

const
  CPopupListener: Txdg_popup_listener = (configure: PopupConfigure; popup_done: PopupDone;
    repositioned: PopupRepositioned);

procedure DecorationConfigure(AData: Pointer; AZxdgToplevelDecorationV1: Pzxdg_toplevel_decoration_v1;
  AMode: UInt32); cdecl;
begin
  WlLog(TWlLogLevel.Debug, 'decoration mode %d', [AMode]);
end;

const
  CDecorationListener: Tzxdg_toplevel_decoration_v1_listener = (configure: DecorationConfigure);

procedure FractionalPreferredScale(AData: Pointer; AWpFractionalScaleV1: Pwp_fractional_scale_v1;
  AScale: UInt32); cdecl;
var
  W: TWlWindow;
begin
  W := TWlWindow(AData);
  W.FFractionalScale := AScale / 120;
  W.UpdateScale;
end;

const
  CFractionalListener: Twp_fractional_scale_v1_listener = (preferred_scale: FractionalPreferredScale);

{$ENDREGION}

{$REGION 'Listeners: seat, pointer, keyboard'}

procedure SeatCapabilities(AData: Pointer; AWlSeat: Pwl_seat; ACapabilities: UInt32); cdecl;
begin
  TWlDisplay(AData).HandleCapabilities(ACapabilities);
end;

procedure SeatName(AData: Pointer; AWlSeat: Pwl_seat; AName: PAnsiChar); cdecl;
begin
end;

const
  CSeatListener: Twl_seat_listener = (capabilities: SeatCapabilities; name: SeatName);

const
  BTN_LEFT = $110;
  BTN_RIGHT = $111;
  BTN_MIDDLE = $112;
  // Double-click: the second press of the same button within this time and distance.
  CDoubleClickMs = 400;
  CDoubleClickDistance = 4;

procedure PointerEnter(AData: Pointer; AWlPointer: Pwl_pointer; ASerial: UInt32; ASurface: Pwl_surface;
  ASurfaceX, ASurfaceY: Twl_fixed); cdecl;
var
  D: TWlDisplay;
begin
  D := TWlDisplay(AData);
  D.FPointerWindow := D.WindowFromSurface(ASurface);
  D.FPointerSerial := ASerial;
  D.FPointerPos := PointF(wl_fixed_to_double(ASurfaceX), wl_fixed_to_double(ASurfaceY));
  D.ApplyCursor;
  if D.FPointerWindow <> nil then
    D.FPointerWindow.DoPointer(TWlPointerEvent.Move, D.FPointerPos.X, D.FPointerPos.Y, D.FModState or D.FButtons, 0);
end;

procedure PointerLeave(AData: Pointer; AWlPointer: Pwl_pointer; ASerial: UInt32; ASurface: Pwl_surface); cdecl;
var
  D: TWlDisplay;
  W: TWlWindow;
begin
  D := TWlDisplay(AData);
  W := D.FPointerWindow;
  D.FPointerWindow := nil;
  D.FButtons := 0;
  if W <> nil then
    W.DoPointer(TWlPointerEvent.Leave, D.FPointerPos.X, D.FPointerPos.Y, D.FModState, 0);
end;

procedure PointerMotion(AData: Pointer; AWlPointer: Pwl_pointer; ATime: UInt32; ASurfaceX,
  ASurfaceY: Twl_fixed); cdecl;
var
  D: TWlDisplay;
begin
  D := TWlDisplay(AData);
  D.FPointerPos := PointF(wl_fixed_to_double(ASurfaceX), wl_fixed_to_double(ASurfaceY));
  if D.FPointerWindow <> nil then
    D.FPointerWindow.DoPointer(TWlPointerEvent.Move, D.FPointerPos.X, D.FPointerPos.Y, D.FModState or D.FButtons, 0);
end;

procedure PointerButton(AData: Pointer; AWlPointer: Pwl_pointer; ASerial, ATime, AButton, AState: UInt32); cdecl;
var
  D: TWlDisplay;
  Bit, State: Integer;
  W: TWlWindow;
begin
  D := TWlDisplay(AData);
  case AButton of
    BTN_LEFT:
      Bit := WL_STATE_LEFT;
    BTN_RIGHT:
      Bit := WL_STATE_RIGHT;
    BTN_MIDDLE:
      Bit := WL_STATE_MIDDLE;
  else
    Exit;
  end;
  W := D.FPointerWindow;
  D.FLastInputSerial := ASerial;
  if AState = WL_POINTER_BUTTON_STATE_PRESSED then
  begin
    D.FLastInputWindow := W;
    D.FButtons := D.FButtons or Bit;
    State := D.FModState or Bit;
    if (D.FLastClickButton = Bit) and (D.FLastClickWindow = W) and (ATime - D.FLastClickTime <= CDoubleClickMs) and
      (Abs(D.FLastClickPos.X - D.FPointerPos.X) <= CDoubleClickDistance) and
      (Abs(D.FLastClickPos.Y - D.FPointerPos.Y) <= CDoubleClickDistance) then
    begin
      State := State or WL_STATE_DOUBLE;
      D.FLastClickButton := 0;
    end
    else
    begin
      D.FLastClickButton := Bit;
      D.FLastClickTime := ATime;
      D.FLastClickPos := D.FPointerPos;
      D.FLastClickWindow := W;
    end;
    if W <> nil then
      W.DoPointer(TWlPointerEvent.Down, D.FPointerPos.X, D.FPointerPos.Y, State, 0);
  end
  else
  begin
    D.FButtons := D.FButtons and not Bit;
    if W <> nil then
      W.DoPointer(TWlPointerEvent.Up, D.FPointerPos.X, D.FPointerPos.Y, D.FModState or Bit, 0);
  end;
end;

procedure PointerAxis(AData: Pointer; AWlPointer: Pwl_pointer; ATime, AAxis: UInt32; AValue: Twl_fixed); cdecl;
var
  D: TWlDisplay;
begin
  if AAxis <> WL_POINTER_AXIS_VERTICAL_SCROLL then
    Exit;
  D := TWlDisplay(AData);
  D.FAxisValue := D.FAxisValue + wl_fixed_to_double(AValue);
  D.FHasAxis := True;
  // Before wl_pointer version 5 there are no frame events: deliver at once.
  if D.FSeatVersion < 5 then
    D.FlushAxis;
end;

procedure PointerFrame(AData: Pointer; AWlPointer: Pwl_pointer); cdecl;
begin
  TWlDisplay(AData).FlushAxis;
end;

procedure PointerAxisSource(AData: Pointer; AWlPointer: Pwl_pointer; AAxisSource: UInt32); cdecl;
begin
end;

procedure PointerAxisStop(AData: Pointer; AWlPointer: Pwl_pointer; ATime, AAxis: UInt32); cdecl;
begin
end;

procedure PointerAxisDiscrete(AData: Pointer; AWlPointer: Pwl_pointer; AAxis: UInt32; ADiscrete: Int32); cdecl;
begin
  if AAxis = WL_POINTER_AXIS_VERTICAL_SCROLL then
    Inc(TWlDisplay(AData).FAxisDiscrete, ADiscrete);
end;

procedure PointerAxisValue120(AData: Pointer; AWlPointer: Pwl_pointer; AAxis: UInt32; AValue120: Int32); cdecl;
begin
  if AAxis = WL_POINTER_AXIS_VERTICAL_SCROLL then
    Inc(TWlDisplay(AData).FAxis120, AValue120);
end;

procedure PointerAxisRelativeDirection(AData: Pointer; AWlPointer: Pwl_pointer; AAxis, ADirection: UInt32); cdecl;
begin
end;

const
  CPointerListener: Twl_pointer_listener = (enter: PointerEnter; leave: PointerLeave; motion: PointerMotion;
    button: PointerButton; axis: PointerAxis; frame: PointerFrame; axis_source: PointerAxisSource;
    axis_stop: PointerAxisStop; axis_discrete: PointerAxisDiscrete; axis_value120: PointerAxisValue120;
    axis_relative_direction: PointerAxisRelativeDirection);

procedure KeyboardKeymap(AData: Pointer; AWlKeyboard: Pwl_keyboard; AFormat: UInt32; AFd: Int32; ASize: UInt32);
  cdecl;
begin
  TWlDisplay(AData).HandleKeymap(AFormat, AFd, ASize);
end;

procedure KeyboardEnter(AData: Pointer; AWlKeyboard: Pwl_keyboard; ASerial: UInt32; ASurface: Pwl_surface;
  AKeys: Pwl_array); cdecl;
var
  D: TWlDisplay;
begin
  D := TWlDisplay(AData);
  D.FKeyboardWindow := D.WindowFromSurface(ASurface);
  D.FLastInputSerial := ASerial;
end;

procedure KeyboardLeave(AData: Pointer; AWlKeyboard: Pwl_keyboard; ASerial: UInt32; ASurface: Pwl_surface); cdecl;
var
  D: TWlDisplay;
begin
  D := TWlDisplay(AData);
  D.StopKeyRepeat;
  D.FKeyboardWindow := nil;
end;

procedure KeyboardKey(AData: Pointer; AWlKeyboard: Pwl_keyboard; ASerial, ATime, AKey, AState: UInt32); cdecl;
var
  D: TWlDisplay;
begin
  D := TWlDisplay(AData);
  D.FLastInputSerial := ASerial;
  D.HandleKey(AKey, AState = WL_KEYBOARD_KEY_STATE_PRESSED);
end;

procedure KeyboardModifiers(AData: Pointer; AWlKeyboard: Pwl_keyboard; ASerial, AModsDepressed, AModsLatched,
  AModsLocked, AGroup: UInt32); cdecl;
begin
  TWlDisplay(AData).HandleModifiers(AModsDepressed, AModsLatched, AModsLocked, AGroup);
end;

procedure KeyboardRepeatInfo(AData: Pointer; AWlKeyboard: Pwl_keyboard; ARate, ADelay: Int32); cdecl;
var
  D: TWlDisplay;
begin
  D := TWlDisplay(AData);
  D.FRepeatRate := ARate;
  D.FRepeatDelay := ADelay;
end;

const
  CKeyboardListener: Twl_keyboard_listener = (keymap: KeyboardKeymap; enter: KeyboardEnter; leave: KeyboardLeave;
    key: KeyboardKey; modifiers: KeyboardModifiers; repeat_info: KeyboardRepeatInfo);

{$ENDREGION}

{$REGION 'Listeners: data device, offers, sources'}

procedure DataOfferOffer(AData: Pointer; AWlDataOffer: Pwl_data_offer; AMimeType: PAnsiChar); cdecl;
var
  Mime: string;
begin
  Mime := Utf8ToStr(AMimeType);
  if not TWlDataOffer(AData).FMimeTypes.Contains(Mime) then
    TWlDataOffer(AData).FMimeTypes.Add(Mime);
end;

procedure DataOfferSourceActions(AData: Pointer; AWlDataOffer: Pwl_data_offer; ASourceActions: UInt32); cdecl;
begin
end;

procedure DataOfferAction(AData: Pointer; AWlDataOffer: Pwl_data_offer; ADndAction: UInt32); cdecl;
begin
end;

const
  CDataOfferListener: Twl_data_offer_listener = (offer: DataOfferOffer; source_actions: DataOfferSourceActions;
    action: DataOfferAction);

procedure DataDeviceDataOffer(AData: Pointer; AWlDataDevice: Pwl_data_device; AId: Pwl_data_offer); cdecl;
var
  D: TWlDisplay;
  O: TWlDataOffer;
begin
  D := TWlDisplay(AData);
  O := TWlDataOffer.Create(AId);
  D.FOffers.AddOrSetValue(AId, O);
  wl_data_offer_add_listener(AId, @CDataOfferListener, O);
end;

procedure DataDeviceEnter(AData: Pointer; AWlDataDevice: Pwl_data_device; ASerial: UInt32; ASurface: Pwl_surface;
  AX, AY: Twl_fixed; AId: Pwl_data_offer); cdecl;
var
  D: TWlDisplay;
begin
  // Drag and drop is not implemented yet: refuse everything.
  D := TWlDisplay(AData);
  if AId <> nil then
  begin
    D.FOffers.TryGetValue(AId, D.FDragOffer);
    wl_data_offer_accept(AId, ASerial, nil);
  end;
end;

procedure DataDeviceLeave(AData: Pointer; AWlDataDevice: Pwl_data_device); cdecl;
var
  D: TWlDisplay;
begin
  D := TWlDisplay(AData);
  if D.FDragOffer <> nil then
  begin
    wl_data_offer_destroy(D.FDragOffer.FOffer);
    D.FOffers.Remove(D.FDragOffer.FOffer);
    D.FDragOffer := nil;
  end;
end;

procedure DataDeviceMotion(AData: Pointer; AWlDataDevice: Pwl_data_device; ATime: UInt32; AX, AY: Twl_fixed); cdecl;
begin
end;

procedure DataDeviceDrop(AData: Pointer; AWlDataDevice: Pwl_data_device); cdecl;
begin
end;

procedure DataDeviceSelection(AData: Pointer; AWlDataDevice: Pwl_data_device; AId: Pwl_data_offer); cdecl;
var
  D: TWlDisplay;
  O: TWlDataOffer;
begin
  D := TWlDisplay(AData);
  O := nil;
  if AId <> nil then
    D.FOffers.TryGetValue(AId, O);
  if (D.FSelection <> nil) and (D.FSelection <> O) then
  begin
    wl_data_offer_destroy(D.FSelection.FOffer);
    D.FOffers.Remove(D.FSelection.FOffer);
  end;
  D.FSelection := O;
end;

const
  CDataDeviceListener: Twl_data_device_listener = (data_offer: DataDeviceDataOffer; enter: DataDeviceEnter;
    leave: DataDeviceLeave; motion: DataDeviceMotion; drop: DataDeviceDrop; selection: DataDeviceSelection);

procedure DataSourceTarget(AData: Pointer; AWlDataSource: Pwl_data_source; AMimeType: PAnsiChar); cdecl;
begin
end;

procedure DataSourceSend(AData: Pointer; AWlDataSource: Pwl_data_source; AMimeType: PAnsiChar; AFd: Int32); cdecl;
var
  D: TWlDisplay;
  Fd: Integer;
begin
  D := TWlDisplay(AData);
  Fd := AFd;
  if (AWlDataSource = D.FOwnSource) and (Length(D.FOwnText) > 0) then
    WriteAll(Fd, PAnsiChar(D.FOwnText), Length(D.FOwnText));
  CloseFd(Fd);
end;

procedure DataSourceCancelled(AData: Pointer; AWlDataSource: Pwl_data_source); cdecl;
var
  D: TWlDisplay;
begin
  D := TWlDisplay(AData);
  if D.FOwnSource = AWlDataSource then
  begin
    D.FOwnSource := nil;
    D.FOwnText := '';
  end;
  wl_data_source_destroy(AWlDataSource);
end;

procedure DataSourceDndDropPerformed(AData: Pointer; AWlDataSource: Pwl_data_source); cdecl;
begin
end;

procedure DataSourceDndFinished(AData: Pointer; AWlDataSource: Pwl_data_source); cdecl;
begin
end;

procedure DataSourceAction(AData: Pointer; AWlDataSource: Pwl_data_source; ADndAction: UInt32); cdecl;
begin
end;

const
  CDataSourceListener: Twl_data_source_listener = (target: DataSourceTarget; send: DataSourceSend;
    cancelled: DataSourceCancelled; dnd_drop_performed: DataSourceDndDropPerformed;
    dnd_finished: DataSourceDndFinished; action: DataSourceAction);

{$ENDREGION}

{ TWlBuffer }

constructor TWlBuffer.Create(const ADisplay: TWlDisplay; const AWidth, AHeight: Integer; const AFormat: UInt32);
var
  Fd: Integer;
  Pool: Pwl_shm_pool;
  P: Pointer;
begin
  inherited Create;
  FDisplay := ADisplay;
  FWidth := AWidth;
  FHeight := AHeight;
  FStride := AWidth * 4;
  FSize := NativeInt(FStride) * AHeight;
  Fd := CreateAnonymousFile(FSize);
  if Fd < 0 then
    raise EOSError.CreateFmt('FMXWayland: cannot create shared memory of %d bytes (errno %d)', [FSize, errno]);
  try
    P := mmap(nil, FSize, PROT_READ or PROT_WRITE, MAP_SHARED, Fd, 0);
    if P = Pointer(-1) then
      raise EOSError.CreateFmt('FMXWayland: mmap of %d bytes failed (errno %d)', [FSize, errno]);
    FData := P;
    Pool := wl_shm_create_pool(ADisplay.FShm, Fd, FSize);
    FBuffer := wl_shm_pool_create_buffer(Pool, 0, AWidth, AHeight, FStride, AFormat);
    wl_shm_pool_destroy(Pool);
  finally
    CloseFd(Fd);
  end;
  wl_buffer_add_listener(FBuffer, @CBufferListener, Self);
end;

destructor TWlBuffer.Destroy;
begin
  if FBuffer <> nil then
    wl_buffer_destroy(FBuffer);
  if FData <> nil then
    munmap(FData, FSize);
  inherited;
end;

{ TWlOutput }

destructor TWlOutput.Destroy;
begin
  if FOutput <> nil then
  begin
    if wl_output_get_version(FOutput) >= WL_OUTPUT_RELEASE_SINCE_VERSION then
      wl_output_release(FOutput)
    else
      wl_output_destroy(FOutput);
  end;
  inherited;
end;

function TWlOutput.GetLogicalBounds: TRect;
var
  W, H, S: Integer;
begin
  S := Max(1, FScale);
  W := FModeWidth div S;
  H := FModeHeight div S;
  // 90 and 270 degree transforms (odd values) swap the sides.
  if Odd(FTransform) then
    Result := Rect(FX, FY, FX + H, FY + W)
  else
    Result := Rect(FX, FY, FX + W, FY + H);
end;

{ TWlDataOffer }

constructor TWlDataOffer.Create(const AOffer: Pwl_data_offer);
begin
  inherited Create;
  FOffer := AOffer;
  FMimeTypes := TList<string>.Create;
end;

destructor TWlDataOffer.Destroy;
begin
  FMimeTypes.Free;
  inherited;
end;

function TWlDataOffer.HasMimeType(const AMimeType: string): Boolean;
begin
  Result := FMimeTypes.Contains(AMimeType);
end;

{ TWlWindow }

constructor TWlWindow.Create(const ADisplay: TWlDisplay; const AKind: TWlWindowKind; const ATransparent: Boolean);
begin
  inherited Create;
  FDisplay := ADisplay;
  FKind := AKind;
  FTransparent := ATransparent;
  FBuffers := TObjectList<TWlBuffer>.Create(True);
  FEnteredOutputs := TList<Pwl_output>.Create;
  FWidth := 1;
  FHeight := 1;
  FScale := 1;
  FIntScale := 1;
  FLastBufferScale := 1;
  FDirty := TRectF.Empty;
  FSurface := wl_compositor_create_surface(ADisplay.FCompositor);
  // The listener's data is the proxy's user data: WindowFromSurface finds the window through it.
  wl_surface_add_listener(FSurface, @CSurfaceListener, Self);
  if ADisplay.FFractionalScaleManager <> nil then
  begin
    FFractional := wp_fractional_scale_manager_v1_get_fractional_scale(ADisplay.FFractionalScaleManager, FSurface);
    wp_fractional_scale_v1_add_listener(FFractional, @CFractionalListener, Self);
    if ADisplay.FViewporter <> nil then
      FViewport := wp_viewporter_get_viewport(ADisplay.FViewporter, FSurface);
  end;
  ADisplay.FWindows.Add(Self);
  UpdateScale;
end;

destructor TWlWindow.Destroy;
var
  W: TWlWindow;
begin
  if FDisplay <> nil then
  begin
    if FVisible then
      Hide;
    for W in FDisplay.FWindows.ToArray do
      if W.FParent = Self then
        W.FParent := nil;
    FDisplay.RemoveWindow(Self);
  end;
  if FFrameCallback <> nil then
    wl_callback_destroy(FFrameCallback);
  DestroyRole;
  if FViewport <> nil then
    wp_viewport_destroy(FViewport);
  if FFractional <> nil then
    wp_fractional_scale_v1_destroy(FFractional);
  FBuffers.Free;
  if FSurface <> nil then
    wl_surface_destroy(FSurface);
  FEnteredOutputs.Free;
  if FDisplay <> nil then
    FDisplay.Flush;
  inherited;
end;

procedure TWlWindow.DoActivate(const AActive: Boolean);
begin
end;

procedure TWlWindow.DoCloseRequest;
begin
end;

procedure TWlWindow.DoKey(const AEvent: TWlKeyEvent; const AKey: Word; const AChar: Char; const AState: Integer);
begin
end;

procedure TWlWindow.DoMoved;
begin
end;

procedure TWlWindow.DoPaint(const AFrame: PWlFrame; const ADirty: TRectF);
begin
end;

procedure TWlWindow.DoPointer(const AEvent: TWlPointerEvent; const AX, AY: Single; const AState,
  AWheelDelta: Integer);
begin
end;

procedure TWlWindow.DoPopupDone;
begin
end;

procedure TWlWindow.DoResized;
begin
end;

procedure TWlWindow.DoScaleChanged;
begin
end;

procedure TWlWindow.DoStateChanged(const AState: TWlWindowState);
begin
end;

function TWlWindow.GetBufferWidth: Integer;
begin
  Result := Max(1, Round(FWidth * FScale));
end;

function TWlWindow.GetBufferHeight: Integer;
begin
  Result := Max(1, Round(FHeight * FScale));
end;

procedure TWlWindow.UpdateScale;
var
  NewScale: Single;
  NewInt, I: Integer;
  O: TWlOutput;
begin
  if (FFractionalScale > 0) and (FViewport <> nil) then
  begin
    NewScale := FFractionalScale;
    NewInt := 1;
  end
  else
  begin
    NewInt := 0;
    if FPreferredIntScale > 0 then
      NewInt := FPreferredIntScale
    else
      for I := 0 to FEnteredOutputs.Count - 1 do
        for O in FDisplay.FOutputs do
          if O.FOutput = FEnteredOutputs[I] then
            NewInt := Max(NewInt, O.FScale);
    if NewInt = 0 then
    begin
      O := FDisplay.PrimaryOutput;
      if O <> nil then
        NewInt := O.FScale;
    end;
    NewInt := Max(1, NewInt);
    NewScale := NewInt;
  end;
  if (NewScale <> FScale) or (NewInt <> FIntScale) then
  begin
    FScale := NewScale;
    FIntScale := NewInt;
    FFullDamage := True;
    InvalidateAll;
    WlLog(TWlLogLevel.Debug, 'window scale %.3f', [FScale]);
    DoScaleChanged;
  end;
end;

procedure TWlWindow.CreateToplevelRole;
begin
  FXdgSurface := xdg_wm_base_get_xdg_surface(FDisplay.FWmBase, FSurface);
  xdg_surface_add_listener(FXdgSurface, @CXdgSurfaceListener, Self);
  FToplevel := xdg_surface_get_toplevel(FXdgSurface);
  xdg_toplevel_add_listener(FToplevel, @CToplevelListener, Self);
  if FDisplay.FDecorationManager <> nil then
  begin
    FDecoration := zxdg_decoration_manager_v1_get_toplevel_decoration(FDisplay.FDecorationManager, FToplevel);
    zxdg_toplevel_decoration_v1_add_listener(FDecoration, @CDecorationListener, Self);
    if FBorderless then
      zxdg_toplevel_decoration_v1_set_mode(FDecoration, ZXDG_TOPLEVEL_DECORATION_V1_MODE_CLIENT_SIDE)
    else
      zxdg_toplevel_decoration_v1_set_mode(FDecoration, ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE);
  end;
end;

procedure TWlWindow.CreatePopupRole;
var
  Positioner: Pxdg_positioner;
  RelX, RelY, AX, AY: Integer;
begin
  Positioner := xdg_wm_base_create_positioner(FDisplay.FWmBase);
  xdg_positioner_set_size(Positioner, Max(1, FWidth), Max(1, FHeight));
  RelX := Round(FOrigin.X - FParent.FOrigin.X);
  RelY := Round(FOrigin.Y - FParent.FOrigin.Y);
  // The anchor point stays inside the parent; the rest of the distance is an offset.
  AX := EnsureRange(RelX, 0, Max(0, FParent.FWidth - 1));
  AY := EnsureRange(RelY, 0, Max(0, FParent.FHeight - 1));
  xdg_positioner_set_anchor_rect(Positioner, AX, AY, 1, 1);
  xdg_positioner_set_anchor(Positioner, XDG_POSITIONER_ANCHOR_TOP_LEFT);
  xdg_positioner_set_gravity(Positioner, XDG_POSITIONER_GRAVITY_BOTTOM_RIGHT);
  xdg_positioner_set_offset(Positioner, RelX - AX, RelY - AY);
  xdg_positioner_set_constraint_adjustment(Positioner, XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_SLIDE_X or
    XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_SLIDE_Y);
  FXdgSurface := xdg_wm_base_get_xdg_surface(FDisplay.FWmBase, FSurface);
  xdg_surface_add_listener(FXdgSurface, @CXdgSurfaceListener, Self);
  FPopup := xdg_surface_get_popup(FXdgSurface, FParent.FXdgSurface, Positioner);
  xdg_popup_add_listener(FPopup, @CPopupListener, Self);
  xdg_positioner_destroy(Positioner);
end;

procedure TWlWindow.DestroyRole;
begin
  if FPopup <> nil then
  begin
    xdg_popup_destroy(FPopup);
    FPopup := nil;
  end;
  if FDecoration <> nil then
  begin
    zxdg_toplevel_decoration_v1_destroy(FDecoration);
    FDecoration := nil;
  end;
  if FToplevel <> nil then
  begin
    xdg_toplevel_destroy(FToplevel);
    FToplevel := nil;
  end;
  if FXdgSurface <> nil then
  begin
    xdg_surface_destroy(FXdgSurface);
    FXdgSurface := nil;
  end;
end;

procedure TWlWindow.SetTransientParent;
var
  P: Pxdg_toplevel;
begin
  if FToplevel = nil then
    Exit;
  P := nil;
  if (FParent <> nil) and (FParent.FToplevel <> nil) and FParent.FVisible then
    P := FParent.FToplevel;
  xdg_toplevel_set_parent(FToplevel, P);
end;

procedure TWlWindow.Show;
var
  UsePopup: Boolean;
begin
  if FVisible then
    Exit;
  UsePopup := (FKind = TWlWindowKind.Popup) and (FParent <> nil) and FParent.FVisible and
    (FParent.FXdgSurface <> nil);
  if (FKind = TWlWindowKind.Popup) and not UsePopup then
    WlLog(TWlLogLevel.Debug, 'popup without a visible parent: shown as a toplevel', []);
  if UsePopup then
    CreatePopupRole
  else
  begin
    if FToplevel = nil then
    begin
      DestroyRole;
      CreateToplevelRole;
    end;
    xdg_toplevel_set_title(FToplevel, PAnsiChar(UTF8String(FTitle)));
    if FAppId <> '' then
      xdg_toplevel_set_app_id(FToplevel, PAnsiChar(UTF8String(FAppId)))
    else
      xdg_toplevel_set_app_id(FToplevel, PAnsiChar(UTF8String(FDisplay.FAppId)));
    SetTransientParent;
    if (FMinWidth > 0) or (FMinHeight > 0) then
      xdg_toplevel_set_min_size(FToplevel, FMinWidth, FMinHeight);
    if FState = TWlWindowState.Maximized then
      xdg_toplevel_set_maximized(FToplevel);
    if FFullScreen then
      xdg_toplevel_set_fullscreen(FToplevel, nil);
  end;
  FVisible := True;
  FConfigured := False;
  FMapped := False;
  FFullDamage := True;
  InvalidateAll;
  // The initial commit without a buffer; the configure event that answers it allows the first frame.
  wl_surface_commit(FSurface);
  FDisplay.Flush;
end;

procedure TWlWindow.HideChildPopups;
var
  Ws: TArray<TWlWindow>;
  I: Integer;
begin
  Ws := FDisplay.FWindows.ToArray;
  for I := High(Ws) downto 0 do
    if (Ws[I].FParent = Self) and Ws[I].FVisible and (Ws[I].FPopup <> nil) then
      Ws[I].Hide;
end;

procedure TWlWindow.Hide;
begin
  if not FVisible then
    Exit;
  HideChildPopups;
  FVisible := False;
  FConfigured := False;
  FMapped := False;
  if FFrameCallback <> nil then
  begin
    wl_callback_destroy(FFrameCallback);
    FFrameCallback := nil;
  end;
  if FPopup <> nil then
  begin
    // A popup gets a new xdg_surface/xdg_popup at each show (its position is fixed at creation).
    xdg_popup_destroy(FPopup);
    FPopup := nil;
    xdg_surface_destroy(FXdgSurface);
    FXdgSurface := nil;
  end;
  // Unmaps: a toplevel keeps its role objects and must do the initial commit again when shown.
  wl_surface_attach(FSurface, nil, 0, 0);
  wl_surface_commit(FSurface);
  FDisplay.Flush;
end;

procedure TWlWindow.HandleXdgConfigure(const ASerial: UInt32);
var
  WasConfigured, SizeChanged, StateChanged: Boolean;
  W, H: Integer;
  NewState: TWlWindowState;
begin
  xdg_surface_ack_configure(FXdgSurface, ASerial);
  if FToplevel <> nil then
    WlLog(TWlLogLevel.Debug, 'configure "%s": %dx%d maximized %s fullscreen %s activated %s (now %dx%d)', [FTitle,
      FPendingWidth, FPendingHeight, BoolToStr(FPendingMaximized, True), BoolToStr(FPendingFullScreen, True),
      BoolToStr(FPendingActivated, True), FWidth, FHeight]);
  WasConfigured := FConfigured;
  FConfigured := True;
  SizeChanged := False;
  if FToplevel <> nil then
  begin
    if FPendingMaximized then
      NewState := TWlWindowState.Maximized
    else
      NewState := TWlWindowState.Normal;
    W := FPendingWidth;
    H := FPendingHeight;
    if (FState = TWlWindowState.Normal) and not FFullScreen and (FPendingMaximized or FPendingFullScreen) then
    begin
      FNormalWidth := FWidth;
      FNormalHeight := FHeight;
    end;
    if ((W <= 0) or (H <= 0)) and ((FState = TWlWindowState.Maximized) or FFullScreen) and
      not (FPendingMaximized or FPendingFullScreen) and (FNormalWidth > 0) then
    begin
      // Back from maximized/fullscreen with "you choose the size": the size from before.
      W := FNormalWidth;
      H := FNormalHeight;
    end;
    if (W > 0) and (H > 0) and ((W <> FWidth) or (H <> FHeight)) then
    begin
      FWidth := W;
      FHeight := H;
      SizeChanged := True;
      FFullDamage := True;
    end;
    FFullScreen := FPendingFullScreen;
    StateChanged := (NewState <> FState) and (FState <> TWlWindowState.Minimized);
    if FState = TWlWindowState.Minimized then
      StateChanged := NewState = TWlWindowState.Maximized;
    FState := NewState;
    if SizeChanged then
      DoResized;
    if StateChanged then
      DoStateChanged(FState);
    if FPendingActivated <> FActivated then
    begin
      FActivated := FPendingActivated;
      DoActivate(FActivated);
    end;
  end;
  if not WasConfigured or SizeChanged then
    InvalidateAll;
end;

function TWlWindow.NeedsPaint(const ANow: Int64): Boolean;
begin
  // A frame callback that does not come (the compositor does not show the window) must not stop painting forever.
  Result := FVisible and FConfigured and not FDirty.IsEmpty and
    ((FFrameCallback = nil) or (ANow - FFrameRequestedAt > 1000));
end;

function TWlWindow.AcquireBuffer(const AWidth, AHeight: Integer): TWlBuffer;
var
  I: Integer;
  Format: UInt32;
begin
  for I := 0 to FBuffers.Count - 1 do
    if not FBuffers[I].Busy and (FBuffers[I].Width = AWidth) and (FBuffers[I].Height = AHeight) then
      Exit(FBuffers[I]);
  for I := FBuffers.Count - 1 downto 0 do
    if not FBuffers[I].Busy and ((FBuffers[I].Width <> AWidth) or (FBuffers[I].Height <> AHeight)) then
      FBuffers.Delete(I);
  if FBuffers.Count >= 3 then
    Exit(nil);
  if FTransparent then
    Format := WL_SHM_FORMAT_ARGB8888
  else
    Format := WL_SHM_FORMAT_XRGB8888;
  Result := TWlBuffer.Create(FDisplay, AWidth, AHeight, Format);
  FBuffers.Add(Result);
end;

procedure TWlWindow.PaintNow;
var
  Buf: TWlBuffer;
  Frame: TWlFrame;
  Dirty: TRectF;
  BW, BH: Integer;
  R: TRect;
  Region: Pwl_region;
begin
  if not (FVisible and FConfigured) or FDirty.IsEmpty then
    Exit;
  BW := BufferWidth;
  BH := BufferHeight;
  Buf := nil;
  if not FExternalPresentation then
  begin
    Buf := AcquireBuffer(BW, BH);
    if Buf = nil then
      Exit; // all buffers are with the compositor: paint when one comes back
  end;
  Dirty := FDirty;
  FDirty := TRectF.Empty;
  FillChar(Frame, SizeOf(Frame), 0);
  if Buf <> nil then
  begin
    Frame.Bits := Buf.Data;
    Frame.Stride := Buf.Stride;
  end;
  Frame.Width := BW;
  Frame.Height := BH;
  Frame.Scale := FScale;
  DoPaint(@Frame, Dirty);
  if not FVisible then
    Exit;
  // The scale state is double-buffered: with an external presenter it applies at its next commit.
  if FViewport <> nil then
    wp_viewport_set_destination(FViewport, FWidth, FHeight)
  else if (FIntScale <> FLastBufferScale) and (wl_surface_get_version(FSurface) >= 3) then
  begin
    wl_surface_set_buffer_scale(FSurface, FIntScale);
    FLastBufferScale := FIntScale;
  end;
  if (Buf = nil) or not Frame.Drawn then
    Exit;
  wl_surface_attach(FSurface, Buf.Buffer, 0, 0);
  if FFullDamage then
    R := Rect(0, 0, BW, BH)
  else
  begin
    R := Rect(Floor(Dirty.Left * FScale), Floor(Dirty.Top * FScale), Ceil(Dirty.Right * FScale),
      Ceil(Dirty.Bottom * FScale));
    R.Intersect(Rect(0, 0, BW, BH));
  end;
  if wl_surface_get_version(FSurface) >= 4 then
    wl_surface_damage_buffer(FSurface, R.Left, R.Top, R.Width, R.Height)
  else
    wl_surface_damage(FSurface, 0, 0, FWidth, FHeight);
  if not FTransparent and ((FOpaqueWidth <> FWidth) or (FOpaqueHeight <> FHeight)) then
  begin
    Region := wl_compositor_create_region(FDisplay.FCompositor);
    wl_region_add(Region, 0, 0, FWidth, FHeight);
    wl_surface_set_opaque_region(FSurface, Region);
    wl_region_destroy(Region);
    FOpaqueWidth := FWidth;
    FOpaqueHeight := FHeight;
  end;
  if FFrameCallback = nil then
  begin
    FFrameCallback := wl_surface_frame(FSurface);
    wl_callback_add_listener(FFrameCallback, @CFrameListener, Self);
    FFrameRequestedAt := MonotonicMs;
  end;
  wl_surface_commit(FSurface);
  Buf.Busy := True;
  FMapped := True;
  FFullDamage := False;
end;

procedure TWlWindow.Invalidate(const ARect: TRectF);
var
  R: TRectF;
begin
  R := TRectF.Intersect(ARect, RectF(0, 0, FWidth, FHeight));
  if R.IsEmpty then
    Exit;
  if FDirty.IsEmpty then
    FDirty := R
  else
    FDirty := TRectF.Union(FDirty, R);
end;

procedure TWlWindow.InvalidateAll;
begin
  FDirty := RectF(0, 0, FWidth, FHeight);
end;

procedure TWlWindow.SetBounds(const AX, AY: Single; const AWidth, AHeight: Integer);
var
  Moved: Boolean;
begin
  Moved := (Abs(AX - FOrigin.X) >= 0.5) or (Abs(AY - FOrigin.Y) >= 0.5);
  FOrigin := PointF(AX, AY);
  if Moved and (FPopup <> nil) and FVisible and (AWidth = FWidth) and (AHeight = FHeight) then
  begin
    // xdg_popup (version 1 to 2) cannot move: a new one at the new place.
    Hide;
    Show;
  end
  else
    SetSize(AWidth, AHeight);
end;

procedure TWlWindow.SetSize(const AWidth, AHeight: Integer);
var
  W, H: Integer;
begin
  W := Max(1, AWidth);
  H := Max(1, AHeight);
  if (W = FWidth) and (H = FHeight) then
    Exit;
  if (FToplevel <> nil) and FConfigured and ((FState = TWlWindowState.Maximized) or FFullScreen) then
  begin
    // The compositor decides the size of a maximized/fullscreen window; this is the size to come back to.
    FNormalWidth := W;
    FNormalHeight := H;
    Exit;
  end;
  FWidth := W;
  FHeight := H;
  FFullDamage := True;
  InvalidateAll;
  if (FPopup <> nil) and FVisible then
  begin
    Hide;
    Show;
  end;
end;

procedure TWlWindow.SetTitle(const ATitle: string);
begin
  FTitle := ATitle;
  if FToplevel <> nil then
  begin
    xdg_toplevel_set_title(FToplevel, PAnsiChar(UTF8String(ATitle)));
    FDisplay.Flush;
  end;
end;

procedure TWlWindow.SetAppId(const AAppId: string);
begin
  FAppId := AAppId;
  if FToplevel <> nil then
    xdg_toplevel_set_app_id(FToplevel, PAnsiChar(UTF8String(AAppId)));
end;

procedure TWlWindow.SetState(const AState: TWlWindowState);
begin
  if (FToplevel = nil) or not FVisible then
  begin
    if AState <> TWlWindowState.Minimized then
      FState := AState;
    Exit;
  end;
  case AState of
    TWlWindowState.Normal:
      if FState = TWlWindowState.Maximized then
        xdg_toplevel_unset_maximized(FToplevel);
    TWlWindowState.Maximized:
      if FState <> TWlWindowState.Maximized then
        xdg_toplevel_set_maximized(FToplevel);
    TWlWindowState.Minimized:
      xdg_toplevel_set_minimized(FToplevel);
  end;
  FDisplay.Flush;
end;

procedure TWlWindow.SetFullScreen(const AValue: Boolean);
begin
  if (FToplevel = nil) or not FVisible then
  begin
    FFullScreen := AValue;
    Exit;
  end;
  if AValue then
    xdg_toplevel_set_fullscreen(FToplevel, nil)
  else
    xdg_toplevel_unset_fullscreen(FToplevel);
  FDisplay.Flush;
end;

procedure TWlWindow.SetMinSize(const AWidth, AHeight: Integer);
begin
  FMinWidth := Max(0, AWidth);
  FMinHeight := Max(0, AHeight);
  if FToplevel <> nil then
    xdg_toplevel_set_min_size(FToplevel, FMinWidth, FMinHeight);
end;

function TWlWindow.ClientToScreen(const APoint: TPointF): TPointF;
begin
  Result := APoint + FOrigin;
end;

function TWlWindow.ScreenToClient(const APoint: TPointF): TPointF;
begin
  Result := APoint - FOrigin;
end;

function TWlWindow.CurrentOutput: TWlOutput;
var
  O: TWlOutput;
begin
  if FEnteredOutputs.Count > 0 then
    for O in FDisplay.FOutputs do
      if O.FOutput = FEnteredOutputs[0] then
        Exit(O);
  Result := nil;
end;

{ TWlDisplay }

var
  GXkbAvailable: Boolean = False;

constructor TWlDisplay.Create;
var
  S: string;
begin
  inherited Create;
  FGlobals := TStringList.Create;
  FOutputs := TObjectList<TWlOutput>.Create(True);
  FWindows := TList<TWlWindow>.Create;
  FTimers := TObjectDictionary<NativeInt, TWlTimer>.Create([doOwnsValues]);
  FOffers := TObjectDictionary<Pwl_data_offer, TWlDataOffer>.Create([doOwnsValues]);
  FWakeFd := -1;
  FRepeatRate := 25;
  FRepeatDelay := 600;
  FRepeatKey := High(UInt32);
  FCursor := crDefault;
  S := GetEnvironmentVariable('FMXWAYLAND_APP_ID');
  if S = '' then
    S := ChangeFileExt(ExtractFileName(ParamStr(0)), '');
  FAppId := S;
end;

destructor TWlDisplay.Destroy;
var
  W: TWlWindow;
begin
  StopKeyRepeat;
  FTimers.Clear;
  // Windows still alive belong to their owners; they only lose the connection.
  for W in FWindows.ToArray do
    W.FDisplay := nil;
  FWindows.Clear;
  if FDisplay <> nil then
  begin
    if FOwnSource <> nil then
      wl_data_source_destroy(FOwnSource);
    for var O in FOffers.Values do
      wl_data_offer_destroy(O.FOffer);
    FOffers.Clear;
    if FDataDevice <> nil then
    begin
      if wl_data_device_get_version(FDataDevice) >= WL_DATA_DEVICE_RELEASE_SINCE_VERSION then
        wl_data_device_release(FDataDevice)
      else
        wl_data_device_destroy(FDataDevice);
    end;
    if FCursorShapeDevice <> nil then
      wp_cursor_shape_device_v1_destroy(FCursorShapeDevice);
    if FPointer <> nil then
      wl_pointer_destroy(FPointer);
    if FKeyboard <> nil then
      wl_keyboard_destroy(FKeyboard);
    if FCursorSurface <> nil then
      wl_surface_destroy(FCursorSurface);
    if FCursorTheme <> nil then
      wl_cursor_theme_destroy(FCursorTheme);
    FOutputs.Clear;
    wl_display_flush(FDisplay);
    wl_display_disconnect(FDisplay);
    FDisplay := nil;
  end;
  ReleaseXkb;
  if FXkbContext <> nil then
    xkb_context_unref(FXkbContext);
  CloseFd(FWakeFd);
  FOffers.Free;
  FTimers.Free;
  FWindows.Free;
  FOutputs.Free;
  FGlobals.Free;
  inherited;
end;

procedure TWlDisplay.Connect;
var
  Err: string;
begin
  if not LoadWaylandClient(Err) then
    raise Exception.Create('FMXWayland: ' + Err);
  GXkbAvailable := LoadXkbCommon(Err);
  if not GXkbAvailable then
    WlLog(TWlLogLevel.Error, '%s: no keyboard input', [Err]);
  FDisplay := wl_display_connect(nil);
  if FDisplay = nil then
    raise Exception.CreateFmt('FMXWayland: cannot connect to a Wayland compositor (WAYLAND_DISPLAY="%s", ' +
      'XDG_RUNTIME_DIR="%s"). FMXWayland needs a Wayland session.',
      [GetEnvironmentVariable('WAYLAND_DISPLAY'), GetEnvironmentVariable('XDG_RUNTIME_DIR')]);
  FWakeFd := eventfd(0, EFD_CLOEXEC or EFD_NONBLOCK);
  IgnoreSigPipe;
  FRegistry := wl_display_get_registry(FDisplay);
  wl_registry_add_listener(FRegistry, @CRegistryListener, Self);
  wl_display_roundtrip(FDisplay);
  if (FCompositor = nil) or (FShm = nil) or (FWmBase = nil) then
    raise Exception.Create('FMXWayland: the compositor lacks wl_compositor, wl_shm or xdg_wm_base (globals: ' +
      GlobalsText + ')');
  // Output modes and scales, seat capabilities, then the keymap of the keyboard created on the way.
  wl_display_roundtrip(FDisplay);
  wl_display_roundtrip(FDisplay);
  CheckConnection;
  WlLog(TWlLogLevel.Debug, 'connected; globals: %s', [GlobalsText]);
end;

function TWlDisplay.GlobalsText: string;
begin
  Result := FGlobals.CommaText;
end;

procedure TWlDisplay.HandleGlobal(const AName: UInt32; const AInterface: string; const AVersion: UInt32);
var
  O: TWlOutput;
begin
  FGlobals.Add(AInterface + ':' + AVersion.ToString);
  if AInterface = 'wl_compositor' then
  begin
    FCompositorVersion := Min(AVersion, 6);
    FCompositor := wl_registry_bind(FRegistry, AName, @wl_compositor_interface, FCompositorVersion);
  end
  else if AInterface = 'wl_shm' then
    FShm := wl_registry_bind(FRegistry, AName, @wl_shm_interface, 1)
  else if AInterface = 'xdg_wm_base' then
  begin
    FWmBase := wl_registry_bind(FRegistry, AName, @xdg_wm_base_interface, Min(AVersion, 6));
    xdg_wm_base_add_listener(FWmBase, @CWmBaseListener, Self);
  end
  else if (AInterface = 'wl_seat') and (FSeat = nil) then
  begin
    FSeatVersion := Min(AVersion, 8);
    FSeatName := AName;
    FSeat := wl_registry_bind(FRegistry, AName, @wl_seat_interface, FSeatVersion);
    wl_seat_add_listener(FSeat, @CSeatListener, Self);
  end
  else if AInterface = 'wl_output' then
  begin
    O := TWlOutput.Create;
    O.FDisplay := Self;
    O.FGlobalName := AName;
    O.FScale := 1;
    O.FName := 'output-' + AName.ToString;
    O.FOutput := wl_registry_bind(FRegistry, AName, @wl_output_interface, Min(AVersion, 4));
    wl_output_add_listener(O.FOutput, @COutputListener, O);
    FOutputs.Add(O);
  end
  else if AInterface = 'wl_data_device_manager' then
    FDataDeviceManager := wl_registry_bind(FRegistry, AName, @wl_data_device_manager_interface, Min(AVersion, 3))
  else if AInterface = 'wp_viewporter' then
    FViewporter := wl_registry_bind(FRegistry, AName, @wp_viewporter_interface, 1)
  else if AInterface = 'wp_fractional_scale_manager_v1' then
    FFractionalScaleManager := wl_registry_bind(FRegistry, AName, @wp_fractional_scale_manager_v1_interface, 1)
  else if AInterface = 'wp_cursor_shape_manager_v1' then
    FCursorShapeManager := wl_registry_bind(FRegistry, AName, @wp_cursor_shape_manager_v1_interface, 1)
  else if AInterface = 'zxdg_decoration_manager_v1' then
    FDecorationManager := wl_registry_bind(FRegistry, AName, @zxdg_decoration_manager_v1_interface, 1)
  else if AInterface = 'xdg_activation_v1' then
    FActivation := wl_registry_bind(FRegistry, AName, @xdg_activation_v1_interface, 1);
  // Globals can come late (WSLg adds the seat when its RDP client connects).
  if (FDataDevice = nil) and (FDataDeviceManager <> nil) and (FSeat <> nil) then
  begin
    FDataDevice := wl_data_device_manager_get_data_device(FDataDeviceManager, FSeat);
    wl_data_device_add_listener(FDataDevice, @CDataDeviceListener, Self);
  end;
end;

procedure TWlDisplay.HandleGlobalRemove(const AName: UInt32);
var
  I: Integer;
  W: TWlWindow;
begin
  for I := FOutputs.Count - 1 downto 0 do
    if FOutputs[I].FGlobalName = AName then
    begin
      for W in FWindows do
        W.FEnteredOutputs.Remove(FOutputs[I].FOutput);
      FOutputs.Delete(I);
    end;
end;

procedure TWlDisplay.HandleCapabilities(const ACapabilities: UInt32);
var
  HasPointer, HasKeyboard: Boolean;
begin
  HasPointer := ACapabilities and WL_SEAT_CAPABILITY_POINTER <> 0;
  HasKeyboard := ACapabilities and WL_SEAT_CAPABILITY_KEYBOARD <> 0;
  if HasPointer and (FPointer = nil) then
  begin
    FPointer := wl_seat_get_pointer(FSeat);
    wl_pointer_add_listener(FPointer, @CPointerListener, Self);
    if FCursorShapeManager <> nil then
      FCursorShapeDevice := wp_cursor_shape_manager_v1_get_pointer(FCursorShapeManager, FPointer);
  end
  else if not HasPointer and (FPointer <> nil) then
  begin
    if FCursorShapeDevice <> nil then
      wp_cursor_shape_device_v1_destroy(FCursorShapeDevice);
    FCursorShapeDevice := nil;
    if FSeatVersion >= WL_POINTER_RELEASE_SINCE_VERSION then
      wl_pointer_release(FPointer)
    else
      wl_pointer_destroy(FPointer);
    FPointer := nil;
    FPointerWindow := nil;
  end;
  if HasKeyboard and (FKeyboard = nil) then
  begin
    FKeyboard := wl_seat_get_keyboard(FSeat);
    wl_keyboard_add_listener(FKeyboard, @CKeyboardListener, Self);
  end
  else if not HasKeyboard and (FKeyboard <> nil) then
  begin
    StopKeyRepeat;
    if FSeatVersion >= WL_KEYBOARD_RELEASE_SINCE_VERSION then
      wl_keyboard_release(FKeyboard)
    else
      wl_keyboard_destroy(FKeyboard);
    FKeyboard := nil;
    FKeyboardWindow := nil;
  end;
end;

procedure TWlDisplay.CheckConnection;
var
  Err: Integer;
  Code, Id: UInt32;
  Iface: Pwl_interface;
  IfaceName: string;
begin
  if FDisplay = nil then
    Exit;
  Err := wl_display_get_error(FDisplay);
  if Err = 0 then
    Exit;
  if (Err = EPROTO) and Assigned(wl_display_get_protocol_error) then
  begin
    Iface := nil;
    Id := 0;
    Code := wl_display_get_protocol_error(FDisplay, Iface, Id);
    if Iface <> nil then
      IfaceName := Utf8ToStr(Iface.name)
    else
      IfaceName := '?';
    WlLog(TWlLogLevel.Error, 'Wayland protocol error %d on %s@%d: the program ends', [Code, IfaceName, Id]);
  end
  else
    WlLog(TWlLogLevel.Error, 'the connection to the Wayland compositor is broken (errno %d): the program ends', [Err]);
  FTerminated := True;
  Halt(1);
end;

procedure TWlDisplay.Flush;
begin
  if FDisplay <> nil then
    wl_display_flush(FDisplay);
end;

procedure TWlDisplay.Terminate;
begin
  FTerminated := True;
  Wake;
end;

procedure TWlDisplay.Wake;
var
  V: UInt64;
begin
  if FWakeFd >= 0 then
  begin
    V := 1;
    __write(FWakeFd, @V, SizeOf(V));
  end;
end;

procedure TWlDisplay.DrainWake;
var
  V: UInt64;
begin
  while __read(FWakeFd, @V, SizeOf(V)) = SizeOf(V) do
    ;
end;

function TWlDisplay.CreateTimer(const AIntervalMs: Integer; const AProc: TProc): NativeInt;
var
  T: TWlTimer;
begin
  Inc(FNextTimerId);
  T := TWlTimer.Create;
  T.FId := FNextTimerId;
  T.FInterval := Max(1, AIntervalMs);
  T.FDue := MonotonicMs + T.FInterval;
  T.FProc := AProc;
  FTimers.Add(T.FId, T);
  Result := T.FId;
end;

function TWlDisplay.DestroyTimer(const AId: NativeInt): Boolean;
begin
  Result := FTimers.ContainsKey(AId);
  if Result then
    FTimers.Remove(AId);
end;

function TWlDisplay.NextTimerDue: Int64;
var
  T: TWlTimer;
begin
  Result := -1;
  for T in FTimers.Values do
    if (Result < 0) or (T.FDue < Result) then
      Result := T.FDue;
end;

function TWlDisplay.RunTimers: Boolean;
var
  Now: Int64;
  Due: TList<TWlTimer>;
  T: TWlTimer;
  Ids: TArray<NativeInt>;
  I: Integer;
  Proc: TProc;
begin
  Result := False;
  if FTimers.Count = 0 then
    Exit;
  Now := MonotonicMs;
  Due := TList<TWlTimer>.Create;
  try
    for T in FTimers.Values do
      if T.FDue <= Now then
        Due.Add(T);
    if Due.Count = 0 then
      Exit;
    Due.Sort(TComparer<TWlTimer>.Construct(
      function(const A, B: TWlTimer): Integer
      begin
        Result := CompareValue(A.FDue, B.FDue);
      end));
    SetLength(Ids, Due.Count);
    for I := 0 to Due.Count - 1 do
      Ids[I] := Due[I].FId;
  finally
    Due.Free;
  end;
  for I := 0 to High(Ids) do
    // A timer can be destroyed by the one before it, or by itself (the local reference keeps its procedure alive).
    if FTimers.TryGetValue(Ids[I], T) then
    begin
      T.FDue := MonotonicMs + T.FInterval;
      Proc := T.FProc;
      Proc();
      Result := True;
    end;
end;

function TWlDisplay.PaintWindows: Boolean;
var
  Now: Int64;
  W: TWlWindow;
begin
  Result := False;
  Now := MonotonicMs;
  for W in FWindows.ToArray do
    if FWindows.Contains(W) and W.NeedsPaint(Now) then
    begin
      W.PaintNow;
      Result := True;
    end;
end;

function TWlDisplay.ProcessEvents(const ATimeoutMs: Integer): Boolean;
var
  Fds: array[0..1] of TPollFd;
  Timeout, N: Integer;
  Due, Now: Int64;
  Readable: Boolean;
begin
  Result := False;
  if FDisplay = nil then
    Exit;
  if wl_display_dispatch_pending(FDisplay) > 0 then
    Result := True;
  if RunTimers then
    Result := True;
  if PaintWindows then
    Result := True;
  Timeout := ATimeoutMs;
  if Result or FTerminated then
    Timeout := 0;
  while wl_display_prepare_read(FDisplay) <> 0 do
    if wl_display_dispatch_pending(FDisplay) > 0 then
    begin
      Result := True;
      Timeout := 0;
    end;
  if (wl_display_flush(FDisplay) < 0) and (errno <> EAGAIN) then
  begin
    wl_display_cancel_read(FDisplay);
    CheckConnection;
    Exit;
  end;
  Due := NextTimerDue;
  if Due >= 0 then
  begin
    Now := MonotonicMs;
    if (Timeout < 0) or (Due - Now < Timeout) then
      Timeout := Max(0, Integer(Min(Due - Now, Int64(MaxInt))));
  end;
  Fds[0].fd := wl_display_get_fd(FDisplay);
  Fds[0].events := POLLIN;
  Fds[0].revents := 0;
  Fds[1].fd := FWakeFd;
  Fds[1].events := POLLIN;
  Fds[1].revents := 0;
  N := poll(@Fds[0], 2, Timeout);
  Readable := (N > 0) and (Fds[0].revents and (POLLIN or POLLERR or POLLHUP) <> 0);
  if Readable then
  begin
    if wl_display_read_events(FDisplay) < 0 then
      CheckConnection;
  end
  else
    wl_display_cancel_read(FDisplay);
  if (N > 0) and (Fds[1].revents and POLLIN <> 0) then
  begin
    DrainWake;
    Result := True;
    if Assigned(FWakeProc) then
      FWakeProc();
  end;
  if wl_display_dispatch_pending(FDisplay) > 0 then
    Result := True;
  if RunTimers then
    Result := True;
  if PaintWindows then
    Result := True;
  wl_display_flush(FDisplay);
  CheckConnection;
end;

procedure TWlDisplay.RunLoop(const ADone: TFunc<Boolean>);
begin
  while not FTerminated and not (Assigned(ADone) and ADone()) do
    if not ProcessEvents(0) then
    begin
      if Assigned(FIdleProc) then
        FIdleProc();
      if FTerminated or (Assigned(ADone) and ADone()) then
        Break;
      ProcessEvents(-1);
    end;
end;

function TWlDisplay.WindowFromSurface(const ASurface: Pwl_surface): TWlWindow;
var
  P: Pointer;
begin
  Result := nil;
  if ASurface = nil then
    Exit;
  P := wl_surface_get_user_data(ASurface);
  if (P <> nil) and FWindows.Contains(TWlWindow(P)) then
    Result := TWlWindow(P);
end;

procedure TWlDisplay.RemoveWindow(const AWindow: TWlWindow);
begin
  FWindows.Remove(AWindow);
  if FPointerWindow = AWindow then
    FPointerWindow := nil;
  if FKeyboardWindow = AWindow then
  begin
    StopKeyRepeat;
    FKeyboardWindow := nil;
  end;
  if FLastInputWindow = AWindow then
    FLastInputWindow := nil;
  if FLastClickWindow = AWindow then
    FLastClickWindow := nil;
end;

function TWlDisplay.PrimaryOutput: TWlOutput;
var
  O: TWlOutput;
begin
  for O in FOutputs do
    if (O.FX = 0) and (O.FY = 0) then
      Exit(O);
  if FOutputs.Count > 0 then
    Result := FOutputs[0]
  else
    Result := nil;
end;

function TWlDisplay.OrderedOutputs: TArray<TWlOutput>;
var
  P, O: TWlOutput;
begin
  Result := [];
  P := PrimaryOutput;
  if P <> nil then
    Result := [P];
  for O in FOutputs do
    if O <> P then
      Result := Result + [O];
end;

function TWlDisplay.PointerScreenPos: TPointF;
begin
  if FPointerWindow <> nil then
    Result := FPointerWindow.ClientToScreen(FPointerPos)
  else if FLastInputWindow <> nil then
    Result := FLastInputWindow.ClientToScreen(FPointerPos)
  else
    Result := FPointerPos;
end;

procedure TWlDisplay.FlushAxis;
var
  Delta, I: Integer;
  T: Double;
begin
  if not FHasAxis and (FAxis120 = 0) and (FAxisDiscrete = 0) then
    Exit;
  if FAxis120 <> 0 then
    Delta := -FAxis120
  else if FAxisDiscrete <> 0 then
    Delta := -FAxisDiscrete * 120
  else
  begin
    // Smooth scrolling (touchpads): 10 surface pixels are one notch of 120; the remainder is kept.
    T := FAxisValue * 12 + FAxisRemainder;
    I := Trunc(T);
    FAxisRemainder := T - I;
    Delta := -I;
  end;
  FAxisValue := 0;
  FAxisDiscrete := 0;
  FAxis120 := 0;
  FHasAxis := False;
  if (Delta <> 0) and (FPointerWindow <> nil) then
    FPointerWindow.DoPointer(TWlPointerEvent.Wheel, FPointerPos.X, FPointerPos.Y, FModState or FButtons, Delta);
end;

{$REGION 'Cursors'}

function CursorShape(const ACursor: Integer): UInt32;
begin
  case ACursor of
    crCross:
      Result := WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_CROSSHAIR;
    crIBeam:
      Result := WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_TEXT;
    crSizeNESW:
      Result := WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_NESW_RESIZE;
    crSizeNS:
      Result := WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_NS_RESIZE;
    crSizeNWSE:
      Result := WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_NWSE_RESIZE;
    crSizeWE:
      Result := WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_EW_RESIZE;
    crHourGlass, crSQLWait:
      Result := WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_WAIT;
    crDrag:
      Result := WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_GRABBING;
    crNoDrop:
      Result := WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_NO_DROP;
    crHSplit:
      Result := WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_COL_RESIZE;
    crVSplit:
      Result := WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_ROW_RESIZE;
    crMultiDrag:
      Result := WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_COPY;
    crNo:
      Result := WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_NOT_ALLOWED;
    crAppStart:
      Result := WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_PROGRESS;
    crHelp:
      Result := WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_HELP;
    crHandPoint:
      Result := WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_POINTER;
    crSizeAll:
      Result := WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_MOVE;
  else
    Result := WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_DEFAULT;
  end;
end;

/// Xcursor names of a cursor, the classic X11 name first, then the CSS/freedesktop ones.
function CursorNames(const ACursor: Integer): TArray<string>;
begin
  case ACursor of
    crCross:
      Result := ['crosshair', 'cross', 'tcross'];
    crIBeam:
      Result := ['xterm', 'text', 'ibeam'];
    crSizeNESW:
      Result := ['fd_double_arrow', 'nesw-resize', 'size_bdiag'];
    crSizeNS:
      Result := ['sb_v_double_arrow', 'ns-resize', 'size_ver'];
    crSizeNWSE:
      Result := ['bd_double_arrow', 'nwse-resize', 'size_fdiag'];
    crSizeWE:
      Result := ['sb_h_double_arrow', 'ew-resize', 'size_hor'];
    crUpArrow:
      Result := ['sb_up_arrow', 'up-arrow', 'left_ptr'];
    crHourGlass, crSQLWait:
      Result := ['watch', 'wait'];
    crDrag:
      Result := ['grabbing', 'closedhand', 'dnd-move', 'fleur'];
    crNoDrop:
      Result := ['dnd-none', 'no-drop', 'circle'];
    crHSplit:
      Result := ['sb_h_double_arrow', 'col-resize', 'split_h'];
    crVSplit:
      Result := ['sb_v_double_arrow', 'row-resize', 'split_v'];
    crMultiDrag:
      Result := ['dnd-copy', 'copy'];
    crNo:
      Result := ['crossed_circle', 'not-allowed', 'circle'];
    crAppStart:
      Result := ['left_ptr_watch', 'progress', 'watch'];
    crHelp:
      Result := ['question_arrow', 'help', 'whats_this'];
    crHandPoint:
      Result := ['hand2', 'pointer', 'pointing_hand', 'hand1'];
    crSizeAll:
      Result := ['fleur', 'move', 'all-scroll'];
  else
    Result := ['left_ptr', 'default', 'arrow'];
  end;
end;

function TWlDisplay.LoadCursorTheme: Boolean;
var
  Size, Scale: Integer;
  Theme: string;
  O: TWlOutput;
begin
  if FCursorTheme <> nil then
    Exit(True);
  if not LoadWaylandCursor then
    Exit(False);
  Scale := 1;
  for O in FOutputs do
    Scale := Max(Scale, O.FScale);
  Size := StrToIntDef(GetEnvironmentVariable('XCURSOR_SIZE'), 24);
  Theme := GetEnvironmentVariable('XCURSOR_THEME');
  if Theme = '' then
    FCursorTheme := wl_cursor_theme_load(nil, Size * Scale, FShm)
  else
    FCursorTheme := wl_cursor_theme_load(PAnsiChar(UTF8String(Theme)), Size * Scale, FShm);
  if FCursorTheme = nil then
    Exit(False);
  FCursorThemeScale := Scale;
  FCursorSurface := wl_compositor_create_surface(FCompositor);
  Result := True;
end;

procedure TWlDisplay.ApplyCursor;
var
  C: Pwl_cursor;
  Img: Pwl_cursor_image;
  N: string;
begin
  if (FPointer = nil) or (FPointerWindow = nil) then
    Exit;
  if FCursor = crNone then
  begin
    wl_pointer_set_cursor(FPointer, FPointerSerial, nil, 0, 0);
    Exit;
  end;
  if FCursorShapeDevice <> nil then
  begin
    wp_cursor_shape_device_v1_set_shape(FCursorShapeDevice, FPointerSerial, CursorShape(FCursor));
    Exit;
  end;
  if not LoadCursorTheme then
    Exit;
  C := nil;
  for N in CursorNames(FCursor) do
  begin
    C := wl_cursor_theme_get_cursor(FCursorTheme, PAnsiChar(UTF8String(N)));
    if C <> nil then
      Break;
  end;
  if (C = nil) and (FCursor <> crDefault) then
    C := wl_cursor_theme_get_cursor(FCursorTheme, 'left_ptr');
  if (C = nil) or (C.image_count = 0) then
    Exit;
  Img := C.images[0];
  wl_surface_attach(FCursorSurface, wl_cursor_image_get_buffer(Img), 0, 0);
  if FCompositorVersion >= 3 then
    wl_surface_set_buffer_scale(FCursorSurface, FCursorThemeScale);
  wl_surface_damage(FCursorSurface, 0, 0, Integer(Img.width), Integer(Img.height));
  wl_surface_commit(FCursorSurface);
  wl_pointer_set_cursor(FPointer, FPointerSerial, FCursorSurface, Integer(Img.hotspot_x) div FCursorThemeScale,
    Integer(Img.hotspot_y) div FCursorThemeScale);
end;

procedure TWlDisplay.SetCursor(const ACursor: Integer);
begin
  if ACursor = FCursor then
    Exit;
  FCursor := ACursor;
  ApplyCursor;
end;

{$ENDREGION}

{$REGION 'Keyboard'}

procedure TWlDisplay.ReleaseXkb;
begin
  if FComposeState <> nil then
    xkb_compose_state_unref(FComposeState);
  FComposeState := nil;
  if FComposeTable <> nil then
    xkb_compose_table_unref(FComposeTable);
  FComposeTable := nil;
  if FXkbState <> nil then
    xkb_state_unref(FXkbState);
  FXkbState := nil;
  if FXkbKeymap <> nil then
    xkb_keymap_unref(FXkbKeymap);
  FXkbKeymap := nil;
end;

procedure TWlDisplay.HandleKeymap(const AFormat: UInt32; const AFd: Integer; const ASize: UInt32);
var
  Fd: Integer;
  Map: Pointer;
  Keymap: PXkbKeymap;
  Locale: string;
begin
  Fd := AFd;
  try
    if (AFormat <> WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1) or not GXkbAvailable then
      Exit;
    Map := mmap(nil, ASize, PROT_READ, MAP_PRIVATE, Fd, 0);
    if Map = Pointer(-1) then
    begin
      WlLog(TWlLogLevel.Error, 'cannot map the keymap (errno %d)', [errno]);
      Exit;
    end;
    try
      if FXkbContext = nil then
        FXkbContext := xkb_context_new(XKB_CONTEXT_NO_FLAGS);
      Keymap := xkb_keymap_new_from_string(FXkbContext, Map, XKB_KEYMAP_FORMAT_TEXT_V1, XKB_KEYMAP_COMPILE_NO_FLAGS);
    finally
      munmap(Map, ASize);
    end;
    if Keymap = nil then
    begin
      WlLog(TWlLogLevel.Error, 'cannot compile the keymap of the compositor', []);
      Exit;
    end;
    StopKeyRepeat;
    ReleaseXkb;
    FXkbKeymap := Keymap;
    FXkbState := xkb_state_new(Keymap);
    if XkbComposeAvailable then
    begin
      Locale := GetEnvironmentVariable('LC_ALL');
      if Locale = '' then
        Locale := GetEnvironmentVariable('LC_CTYPE');
      if Locale = '' then
        Locale := GetEnvironmentVariable('LANG');
      if Locale = '' then
        Locale := 'C';
      FComposeTable := xkb_compose_table_new_from_locale(FXkbContext, PAnsiChar(UTF8String(Locale)), 0);
      if FComposeTable <> nil then
        FComposeState := xkb_compose_state_new(FComposeTable, 0);
    end;
  finally
    CloseFd(Fd);
  end;
end;

procedure TWlDisplay.HandleModifiers(const ADepressed, ALatched, ALocked, AGroup: UInt32);

  function Active(const AName: PAnsiChar): Boolean;
  begin
    Result := xkb_state_mod_name_is_active(FXkbState, AName, XKB_STATE_MODS_EFFECTIVE) > 0;
  end;

begin
  if FXkbState = nil then
    Exit;
  xkb_state_update_mask(FXkbState, ADepressed, ALatched, ALocked, 0, 0, AGroup);
  FModState := 0;
  if Active(XKB_MOD_NAME_SHIFT) then
    FModState := FModState or WL_STATE_SHIFT;
  if Active(XKB_MOD_NAME_CTRL) then
    FModState := FModState or WL_STATE_CTRL;
  if Active(XKB_MOD_NAME_ALT) then
    FModState := FModState or WL_STATE_ALT;
  if Active(XKB_MOD_NAME_LOGO) then
    FModState := FModState or WL_STATE_SUPER;
end;

function Utf32ToStr(const AValue: UInt32): string;
begin
  if AValue < $10000 then
    Result := Char(AValue)
  else
    Result := Char($D800 + ((AValue - $10000) shr 10)) + Char($DC00 + ((AValue - $10000) and $3FF));
end;

procedure TWlDisplay.DeliverKeyDown(const AKey: UInt32);
var
  W: TWlWindow;
  Code, Sym, U: UInt32;
  Vk: Word;
  Text: string;
  Composed: Boolean;
  Buf: array[0..63] of AnsiChar;
  I: Integer;
begin
  W := FKeyboardWindow;
  if (W = nil) or (FXkbState = nil) then
    Exit;
  Code := AKey + 8;
  Sym := xkb_state_key_get_one_sym(FXkbState, Code);
  Vk := KeyToVirtualKey(Sym, AKey);
  Text := '';
  Composed := False;
  if FComposeState <> nil then
  begin
    if xkb_compose_state_feed(FComposeState, Sym) = XKB_COMPOSE_FEED_ACCEPTED then
      case xkb_compose_state_get_status(FComposeState) of
        XKB_COMPOSE_COMPOSING:
          Exit; // a dead key: the character comes with the next key
        XKB_COMPOSE_COMPOSED:
          begin
            FillChar(Buf, SizeOf(Buf), 0);
            xkb_compose_state_get_utf8(FComposeState, @Buf[0], SizeOf(Buf));
            Text := UTF8ToString(PAnsiChar(@Buf[0]));
            xkb_compose_state_reset(FComposeState);
            Composed := True;
          end;
        XKB_COMPOSE_CANCELLED:
          begin
            xkb_compose_state_reset(FComposeState);
            Exit;
          end;
      end;
  end;
  if not Composed then
  begin
    U := xkb_state_key_get_utf32(FXkbState, Code);
    // Control characters (Return, Tab, Escape, Ctrl+letter) travel as virtual keys only.
    if (U >= 32) and (U <> 127) then
      Text := Utf32ToStr(U);
  end;
  if WlLogEnabled(TWlLogLevel.Trace) then
    WlLog(TWlLogLevel.Trace, 'key %d sym $%x vk $%x text "%s" mods %d', [AKey, Sym, Vk, Text, FModState]);
  if Text = '' then
  begin
    if Vk <> 0 then
      W.DoKey(TWlKeyEvent.Down, Vk, #0, FModState);
  end
  else
  begin
    W.DoKey(TWlKeyEvent.Down, Vk, Text[1], FModState);
    for I := 2 to Length(Text) do
      if FKeyboardWindow = W then
        W.DoKey(TWlKeyEvent.Down, 0, Text[I], FModState);
  end;
end;

procedure TWlDisplay.HandleKey(const AKey: UInt32; const APressed: Boolean);
var
  W: TWlWindow;
  Sym: UInt32;
begin
  if FXkbState = nil then
    Exit;
  W := FKeyboardWindow;
  if APressed then
  begin
    FLastInputWindow := W;
    DeliverKeyDown(AKey);
    if (FRepeatRate > 0) and (FKeyboardWindow <> nil) and (xkb_keymap_key_repeats(FXkbKeymap, AKey + 8) <> 0) then
    begin
      StopKeyRepeat;
      FRepeatKey := AKey;
      FRepeatTimer := CreateTimer(Max(1, FRepeatDelay),
        procedure
        begin
          // After the delay: repeat at the rate.
          DestroyTimer(FRepeatTimer);
          FRepeatTimer := CreateTimer(Max(1, 1000 div FRepeatRate),
            procedure
            begin
              DeliverKeyDown(FRepeatKey);
            end);
          DeliverKeyDown(FRepeatKey);
        end);
    end;
  end
  else
  begin
    if AKey = FRepeatKey then
      StopKeyRepeat;
    if W <> nil then
    begin
      Sym := xkb_state_key_get_one_sym(FXkbState, AKey + 8);
      W.DoKey(TWlKeyEvent.Up, KeyToVirtualKey(Sym, AKey), #0, FModState);
    end;
  end;
end;

procedure TWlDisplay.StopKeyRepeat;
begin
  if FRepeatTimer <> 0 then
    DestroyTimer(FRepeatTimer);
  FRepeatTimer := 0;
  FRepeatKey := High(UInt32);
end;

{$ENDREGION}

{$REGION 'Clipboard'}

const
  CTextMimeTypes: array[0..4] of string = ('text/plain;charset=utf-8', 'UTF8_STRING', 'text/plain', 'TEXT',
    'STRING');

function TWlDisplay.ClipboardHasText: Boolean;
var
  M: string;
begin
  if FOwnSource <> nil then
    Exit(True);
  if FSelection = nil then
    Exit(False);
  for M in CTextMimeTypes do
    if FSelection.HasMimeType(M) then
      Exit(True);
  Result := False;
end;

function TWlDisplay.ReadOffer(const AOffer: TWlDataOffer; const AMimeType: string; out AData: TBytes): Boolean;
var
  Fds: array[0..1] of Integer;
  P: TPollFd;
  Deadline, Left: Int64;
  Chunk: array[0..16383] of Byte;
  N: NativeInt;
  Len: Integer;
begin
  Result := False;
  AData := nil;
  if pipe2(@Fds[0], O_CLOEXEC) <> 0 then
    Exit;
  wl_data_offer_receive(AOffer.FOffer, PAnsiChar(UTF8String(AMimeType)), Fds[1]);
  CloseFd(Fds[1]);
  Flush;
  Len := 0;
  Deadline := MonotonicMs + 2000;
  try
    while True do
    begin
      Left := Deadline - MonotonicMs;
      if Left <= 0 then
      begin
        WlLog(TWlLogLevel.Warning, 'the clipboard owner did not send %s in time', [AMimeType]);
        Exit;
      end;
      P.fd := Fds[0];
      P.events := POLLIN;
      P.revents := 0;
      if poll(@P, 1, Integer(Left)) < 0 then
      begin
        if errno = EINTR then
          Continue;
        Exit;
      end;
      if P.revents = 0 then
        Continue;
      N := __read(Fds[0], @Chunk[0], SizeOf(Chunk));
      if N = 0 then
        Break;
      if N < 0 then
      begin
        if (errno = EINTR) or (errno = EAGAIN) then
          Continue;
        Exit;
      end;
      SetLength(AData, Len + N);
      Move(Chunk[0], AData[Len], N);
      Inc(Len, N);
    end;
    Result := True;
  finally
    CloseFd(Fds[0]);
  end;
end;

function TWlDisplay.ClipboardGetText: string;
var
  M: string;
  Data: TBytes;
begin
  if FOwnSource <> nil then
    Exit(UTF8ToString(FOwnText));
  Result := '';
  if FSelection = nil then
    Exit;
  for M in CTextMimeTypes do
    if FSelection.HasMimeType(M) then
    begin
      if ReadOffer(FSelection, M, Data) then
      begin
        if (M = 'STRING') or (M = 'TEXT') then
          Result := TEncoding.ANSI.GetString(Data)
        else
          Result := TEncoding.UTF8.GetString(Data);
      end;
      Exit;
    end;
end;

procedure TWlDisplay.ClipboardSetText(const AText: string);
var
  Src, Old: Pwl_data_source;
  M: string;
begin
  if (FDataDeviceManager = nil) or (FDataDevice = nil) then
  begin
    WlLogOnce('clipboard', 'the compositor offers no wl_data_device_manager: no clipboard');
    Exit;
  end;
  Src := wl_data_device_manager_create_data_source(FDataDeviceManager);
  wl_data_source_add_listener(Src, @CDataSourceListener, Self);
  for M in CTextMimeTypes do
    wl_data_source_offer(Src, PAnsiChar(UTF8String(M)));
  Old := FOwnSource;
  FOwnSource := Src;
  FOwnText := UTF8String(AText);
  wl_data_device_set_selection(FDataDevice, Src, FLastInputSerial);
  if Old <> nil then
    wl_data_source_destroy(Old);
  Flush;
end;

{$ENDREGION}

end.
