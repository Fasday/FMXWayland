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
  /// <summary>Parts of client-side decorations.</summary>
  TWlDecoPart = (None, Title, Minimize, Maximize, Close, Left, Right, Top, Bottom, TopLeft, TopRight, BottomLeft,
    BottomRight);

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
  /// window, premultiplied BGRA, Width x Height buffer pixels = logical size x Scale. The buffer may hold an older
  /// frame (buffers rotate): whoever draws must draw all of it (the Skia raster canvas copies its whole back buffer;
  /// FMX's cairo canvas paints into a retained frame and copies what changed since the frame the buffer holds).
  /// Bits is nil under external presentation.</summary>
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
    // Client-side decorations: a subsurface below the window's surface, around it (title bar and borders).
    FCsd: Boolean;
    FDecoSurface: Pwl_surface;
    FDecoSubsurface: Pwl_subsurface;
    FDecoBuffers: TObjectList<TWlBuffer>;
    FDecoDirty: Boolean;
    FDecoHover: TWlDecoPart;
    FDecoPressed: TWlDecoPart;
    FDecoLastClick: Int64;
    FGeometryX: Integer;
    FGeometryY: Integer;
    FGeometryW: Integer;
    FGeometryH: Integer;
    FActivationToken: Pxdg_activation_token_v1;
    // Where a popup asked to be (relative to the parent's window geometry), for diagnostics.
    FPopupAskX: Integer;
    FPopupAskY: Integer;
    // What the window manager does with toplevels (xdg_toplevel.wm_capabilities, xdg_wm_base 5): all of it until it
    // says otherwise.
    FCanMaximize: Boolean;
    FCanMinimize: Boolean;
    FCanWindowMenu: Boolean;
    // The compositor switched the decorations (xdg-decoration) since the last configure: FMX's window rectangle
    // (with the decorations) changes even when the size stays.
    FDecoSwitched: Boolean;
    // Decorations the program wants (SetDecorated): False = none at all, neither the client-side ones nor the
    // compositor's; kept across configures, decoration mode changes and hide/show.
    FDecorated: Boolean;
    // The mode the compositor gave with xdg-decoration (0 until it answers).
    FDecoMode: UInt32;
    // The states of the last configure as bits (1 shl xdg_toplevel.state), those of the configure being received,
    // and the window manager's capabilities as bits (1 shl xdg_toplevel.wm_capabilities; $FFFFFFFF until it sends
    // them); FCapabilitiesChanged: new capabilities, reported with the configure that follows them.
    FStateBits: Cardinal;
    FPendingStateBits: Cardinal;
    FCapabilityBits: Cardinal;
    FCapabilitiesChanged: Boolean;
    // A popup shown while its parent was not mapped yet: its xdg_popup is made when the parent is (xdg-shell: "the
    // parent of an xdg_popup must be mapped before the xdg_popup itself").
    FPopupPending: Boolean;
    FPendingOffset: TPointF;
    procedure CreateToplevelRole;
    function DecoButtonAt(const AIndex: Integer): TWlDecoPart;
    function DecoButtonCount: Integer;
    procedure EnableCsd;
    procedure DisableCsd;
    function DecoPartAt(const AX, AY: Single): TWlDecoPart;
    procedure DecoPointer(const AEvent: TWlPointerEvent; const AX, AY: Single; const AState: Integer;
      const ASerial: UInt32);
    procedure DecoAction(const APart: TWlDecoPart);
    procedure PaintDecorations;
    procedure UpdateGeometry;
    function InsetsFor(const AState: TWlWindowState; const AFullScreen: Boolean): TRect;
    procedure CreatePopupRole;
    procedure DestroyRole;
    procedure HideChildPopups;
    function CanParentPopups: Boolean;
    procedure ParentMapped;
    function HeldPress(out ASerial: UInt32): Boolean;
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
    /// <summary>A configure changed the xdg_toplevel states (StateBits) or brought new capabilities of the window
    /// manager (CapabilityBits).</summary>
    procedure DoFrameChanged; virtual;
    /// <summary>Draws the title of client-side decorations into ARect (buffer pixels) of AFrame (premultiplied BGRA);
    /// the core has no text renderer, the FMX layer draws it with an FMX bitmap (of the canvas FMX uses).</summary>
    procedure DoDrawTitle(const AFrame: PWlFrame; const ARect: TRect; const ATitle: string; const AActive: Boolean);
      virtual;
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
    /// <summary>Asks the compositor to activate (raise and focus) the window, with an xdg-activation token tied to the
    /// last input event; nothing happens without xdg_activation_v1 (the compositor may refuse anyway).</summary>
    procedure Activate;
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
    /// <summary>Widths of the client-side decorations on each side (logical pixels; all 0 without them).</summary>
    function DecorationInsets: TRect;
    /// <summary>Decides whether a toplevel draws its own decorations (call after setting Borderless, before the
    /// first SetBounds): when the compositor has no xdg-decoration and FMXWAYLAND_CSD is not 0.</summary>
    procedure PrepareDecorations;
    /// <summary>False: no decorations for the toplevel, neither its own client-side ones nor the compositor's
    /// (xdg-decoration mode client_side); the surface is all client area and the window geometry. True (default):
    /// the platform's choice again. Kept until changed. A window on the screen keeps its outer size (the client area
    /// takes or gives back the room of the decorations), one not configured yet keeps its client size; DoResized
    /// reports the change.</summary>
    procedure SetDecorated(const AValue: Boolean);
    /// <summary>True when the toplevel has decorations now: its own (Csd) or the compositor's (xdg-decoration
    /// server_side, asked or given).</summary>
    function HasDecorations: Boolean;
    /// <summary>An interactive move with the latest pointer button press on the window (its content or its
    /// decorations), while that press is held: xdg_toplevel.move with its serial once the pointer is dragged 4 pixels
    /// (a click stays a click). False without such a press or for popups.</summary>
    function BeginMove: Boolean;
    /// <summary>xdg_toplevel.resize (AEdges: an xdg_toplevel.resize_edge value other than none) with the serial of
    /// the latest press held on the window; False without one, for popups or invalid edges.</summary>
    function BeginResize(const AEdges: Cardinal): Boolean;
    /// <summary>xdg_toplevel.show_window_menu at (AX, AY) in surface coordinates with the serial of the latest press
    /// held on the window; False without one, for popups or without the window_menu capability.</summary>
    function ShowWindowMenu(const AX, AY: Integer): Boolean;
    /// <summary>xdg_toplevel.set_minimized (where the window manager can minimize); the state becomes Minimized
    /// (DoStateChanged), as Wayland does not tell.</summary>
    procedure Minimize;
    /// <summary>xdg_toplevel.set_maximized or unset_maximized; the state follows with the configure.</summary>
    procedure SetMaximized(const AValue: Boolean);
    property Display: TWlDisplay read FDisplay;
    /// <summary>The window draws its own decorations (the compositor offers no server-side ones).</summary>
    property Csd: Boolean read FCsd;
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
    /// <summary>What SetDecorated set (True by default).</summary>
    property Decorated: Boolean read FDecorated;
    /// <summary>The xdg_toplevel states of the last configure, as bits 1 shl state (maximized 1, fullscreen 2,
    /// resizing 3, activated 4, tiled_left..tiled_bottom 5..8, suspended 9).</summary>
    property StateBits: Cardinal read FStateBits;
    /// <summary>The window manager's capabilities (xdg_toplevel.wm_capabilities) as bits 1 shl capability
    /// (window_menu 1, maximize 2, fullscreen 3, minimize 4); $FFFFFFFF when it never sent them.</summary>
    property CapabilityBits: Cardinal read FCapabilityBits;
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
    FSubcompositor: Pwl_subcompositor;
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
    FPointerOnDeco: Boolean;
    FDecoCursor: Integer;
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
    // The latest button press on any surface of a window (content or decorations) while buttons are held: what
    // xdg_toplevel.move/resize/show_window_menu need.
    FPressSerial: UInt32;
    FPressWindow: TWlWindow;
    FPressButtons: Integer;
    // A move asked for (TWlWindow.BeginMove) that starts once the pointer is dragged from where it was then.
    FMoveWindow: TWlWindow;
    FMoveFrom: TPointF;
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
    FOwnLocal: Boolean;
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
    procedure StartMove;
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
    /// <summary>The globals the compositor announced ('wl_compositor:4,wl_shm:1,...'), for diagnostics.</summary>
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
  // Set when the connection goes away: objects destroyed later must not touch their (freed) proxies.
  GDisconnected: Boolean = False;

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
  W.FPendingStateBits := 0;
  if (AStates <> nil) and (AStates.data <> nil) then
  begin
    P := AStates.data;
    for I := 0 to Integer(AStates.size div SizeOf(Cardinal)) - 1 do
    begin
      if P^ < 32 then
        W.FPendingStateBits := W.FPendingStateBits or (Cardinal(1) shl P^);
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
var
  W: TWlWindow;
  P: PCardinal;
  I: Integer;
  S: string;
begin
  W := TWlWindow(AData);
  W.FCanMaximize := False;
  W.FCanMinimize := False;
  W.FCanWindowMenu := False;
  W.FCapabilityBits := 0;
  S := '';
  if (ACapabilities <> nil) and (ACapabilities.data <> nil) then
  begin
    P := ACapabilities.data;
    for I := 0 to Integer(ACapabilities.size div SizeOf(Cardinal)) - 1 do
    begin
      if P^ < 32 then
        W.FCapabilityBits := W.FCapabilityBits or (Cardinal(1) shl P^);
      case P^ of
        XDG_TOPLEVEL_WM_CAPABILITIES_WINDOW_MENU:
          begin
            W.FCanWindowMenu := True;
            S := S + ' window_menu';
          end;
        XDG_TOPLEVEL_WM_CAPABILITIES_MAXIMIZE:
          begin
            W.FCanMaximize := True;
            S := S + ' maximize';
          end;
        XDG_TOPLEVEL_WM_CAPABILITIES_FULLSCREEN:
          S := S + ' fullscreen';
        XDG_TOPLEVEL_WM_CAPABILITIES_MINIMIZE:
          begin
            W.FCanMinimize := True;
            S := S + ' minimize';
          end;
      end;
      Inc(P);
    end;
  end;
  WlLog(TWlLogLevel.Debug, 'wm capabilities of "%s":%s', [W.FTitle, S]);
  // The title bar buttons follow (it takes effect with the configure that comes next).
  W.FDecoDirty := True;
  W.FCapabilitiesChanged := True;
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
  WlLog(TWlLogLevel.Debug, 'popup configure %d,%d %dx%d (asked %d,%d %dx%d)', [AX, AY, AWidth, AHeight, W.FPopupAskX,
    W.FPopupAskY, W.FWidth, W.FHeight]);
  if W.FParent <> nil then
  begin
    // AX, AY: relative to the parent's window geometry (its decorations included).
    NewOrigin := PointF(W.FParent.FOrigin.X + AX - W.FParent.DecorationInsets.Left,
      W.FParent.FOrigin.Y + AY - W.FParent.DecorationInsets.Top);
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
  WlLog(TWlLogLevel.Debug, 'popup dismissed by the compositor', []);
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
var
  W: TWlWindow;
  WasCsd: Boolean;
begin
  WlLog(TWlLogLevel.Debug, 'decoration mode %d of "%s"', [AMode, TWlWindow(AData).FTitle]);
  W := TWlWindow(AData);
  W.FDecoMode := AMode;
  WasCsd := W.FCsd;
  // The compositor wants the client to decorate (it may say so even though it offers the protocol); not a window
  // the program decorates itself (SetDecorated(False): EnableCsd refuses).
  if (AMode = ZXDG_TOPLEVEL_DECORATION_V1_MODE_CLIENT_SIDE) and not W.FBorderless then
    W.EnableCsd
  else if AMode = ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE then
    W.DisableCsd;
  if W.FCsd <> WasCsd then
    W.FDecoSwitched := True;
end;

procedure DecoSurfaceEnter(AData: Pointer; AWlSurface: Pwl_surface; AOutput: Pwl_output); cdecl;
begin
end;

procedure DecoSurfaceLeave(AData: Pointer; AWlSurface: Pwl_surface; AOutput: Pwl_output); cdecl;
begin
end;

procedure DecoSurfacePreferredBufferScale(AData: Pointer; AWlSurface: Pwl_surface; AFactor: Int32); cdecl;
begin
end;

const
  // The decoration surface's user data is its window (pointer events find it); its scale follows the window's.
  CDecoSurfaceListener: Twl_surface_listener = (enter: DecoSurfaceEnter; leave: DecoSurfaceLeave;
    preferred_buffer_scale: DecoSurfacePreferredBufferScale;
    preferred_buffer_transform: SurfacePreferredBufferTransform);

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

procedure ActivationTokenDone(AData: Pointer; AXdgActivationTokenV1: Pxdg_activation_token_v1;
  AToken: PAnsiChar); cdecl;
var
  W: TWlWindow;
begin
  W := TWlWindow(AData);
  if W.FActivationToken = AXdgActivationTokenV1 then
  begin
    WlLog(TWlLogLevel.Debug, 'activate "%s" with token %s', [W.FTitle, Utf8ToStr(AToken)]);
    xdg_activation_v1_activate(W.FDisplay.FActivation, AToken, W.FSurface);
    W.FActivationToken := nil;
  end;
  xdg_activation_token_v1_destroy(AXdgActivationTokenV1);
end;

const
  CActivationTokenListener: Txdg_activation_token_v1_listener = (done: ActivationTokenDone);

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
  // A move asked for at a press starts when the pointer has gone this far (logical pixels) with the button held.
  CDragThreshold = 4;

procedure PointerEnter(AData: Pointer; AWlPointer: Pwl_pointer; ASerial: UInt32; ASurface: Pwl_surface;
  ASurfaceX, ASurfaceY: Twl_fixed); cdecl;
var
  D: TWlDisplay;
begin
  D := TWlDisplay(AData);
  D.FPointerWindow := D.WindowFromSurface(ASurface);
  D.FPointerOnDeco := (D.FPointerWindow <> nil) and (ASurface = D.FPointerWindow.FDecoSurface);
  D.FPointerSerial := ASerial;
  D.FPointerPos := PointF(wl_fixed_to_double(ASurfaceX), wl_fixed_to_double(ASurfaceY));
  D.FDecoCursor := crDefault;
  if D.FPointerWindow = nil then
    Exit;
  if D.FPointerOnDeco then
    D.FPointerWindow.DecoPointer(TWlPointerEvent.Move, D.FPointerPos.X, D.FPointerPos.Y, 0, ASerial)
  else
  begin
    D.ApplyCursor;
    D.FPointerWindow.DoPointer(TWlPointerEvent.Move, D.FPointerPos.X, D.FPointerPos.Y, D.FModState or D.FButtons, 0);
  end;
end;

procedure PointerLeave(AData: Pointer; AWlPointer: Pwl_pointer; ASerial: UInt32; ASurface: Pwl_surface); cdecl;
const
  CButtonBits: array[0..2] of Integer = (WL_STATE_LEFT, WL_STATE_RIGHT, WL_STATE_MIDDLE);
var
  D: TWlDisplay;
  W: TWlWindow;
  Held, Bit: Integer;
begin
  D := TWlDisplay(AData);
  W := D.FPointerWindow;
  Held := D.FButtons;
  D.FPointerWindow := nil;
  D.FButtons := 0;
  // A press the compositor took over (an interactive move or resize, its window menu) ends here for the window.
  D.FPressButtons := 0;
  D.FPressWindow := nil;
  D.FMoveWindow := nil;
  if W = nil then
    Exit;
  if D.FPointerOnDeco then
    W.DecoPointer(TWlPointerEvent.Leave, -1, -1, 0, ASerial)
  else
  begin
    // Buttons still held: the release will not come to this surface. FMX gets it now, so the control that took the
    // press (and the mouse capture) lets it go.
    for Bit in CButtonBits do
      if (Held and Bit <> 0) and D.FWindows.Contains(W) then
        W.DoPointer(TWlPointerEvent.Up, D.FPointerPos.X, D.FPointerPos.Y, D.FModState or Bit, 0);
    if D.FWindows.Contains(W) then
      W.DoPointer(TWlPointerEvent.Leave, D.FPointerPos.X, D.FPointerPos.Y, D.FModState, 0);
  end;
  D.FPointerOnDeco := False;
end;

procedure PointerMotion(AData: Pointer; AWlPointer: Pwl_pointer; ATime: UInt32; ASurfaceX,
  ASurfaceY: Twl_fixed); cdecl;
var
  D: TWlDisplay;
begin
  D := TWlDisplay(AData);
  D.FPointerPos := PointF(wl_fixed_to_double(ASurfaceX), wl_fixed_to_double(ASurfaceY));
  if D.FPointerWindow = nil then
    Exit;
  if (D.FMoveWindow <> nil) and (D.FMoveWindow = D.FPointerWindow) and
    ((Abs(D.FPointerPos.X - D.FMoveFrom.X) >= CDragThreshold) or
    (Abs(D.FPointerPos.Y - D.FMoveFrom.Y) >= CDragThreshold)) then
    D.StartMove;
  if D.FPointerWindow = nil then
    Exit;
  if D.FPointerOnDeco then
    D.FPointerWindow.DecoPointer(TWlPointerEvent.Move, D.FPointerPos.X, D.FPointerPos.Y, 0, D.FPointerSerial)
  else
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
  // Before the window hears of it: a press handler may start a move (IFMXWaylandWindowFrame.BeginMove) with it.
  if AState = WL_POINTER_BUTTON_STATE_PRESSED then
  begin
    D.FPressButtons := D.FPressButtons or Bit;
    D.FPressSerial := ASerial;
    D.FPressWindow := W;
    D.FMoveWindow := nil;
  end
  else
  begin
    D.FPressButtons := D.FPressButtons and not Bit;
    if D.FPressButtons = 0 then
      D.FPressWindow := nil;
    // Released without a drag: a click, no move.
    D.FMoveWindow := nil;
  end;
  if WlLogEnabled(TWlLogLevel.Trace) then
    WlLog(TWlLogLevel.Trace, 'button %x state %d time %u at %.1f,%.1f (last press %u)', [AButton, AState, ATime,
      D.FPointerPos.X, D.FPointerPos.Y, D.FLastClickTime]);
  if (W <> nil) and D.FPointerOnDeco then
  begin
    if AState = WL_POINTER_BUTTON_STATE_PRESSED then
      W.DecoPointer(TWlPointerEvent.Down, D.FPointerPos.X, D.FPointerPos.Y, Bit, ASerial)
    else
      W.DecoPointer(TWlPointerEvent.Up, D.FPointerPos.X, D.FPointerPos.Y, Bit, ASerial);
    Exit;
  end;
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
  // A selection of the seat replaces the process-local clipboard used while there was no seat.
  if O <> nil then
    D.FOwnLocal := False;
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
  if (FBuffer <> nil) and not GDisconnected then
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
  FDecoBuffers := TObjectList<TWlBuffer>.Create(True);
  FEnteredOutputs := TList<Pwl_output>.Create;
  FWidth := 1;
  FHeight := 1;
  FScale := 1;
  FIntScale := 1;
  FLastBufferScale := 1;
  FDirty := TRectF.Empty;
  FCanMaximize := True;
  FCanMinimize := True;
  FCanWindowMenu := True;
  FCapabilityBits := $FFFFFFFF;
  FDecorated := True;
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
  if (FDisplay <> nil) and not GDisconnected then
  begin
    if FVisible then
      Hide;
    for W in FDisplay.FWindows.ToArray do
      if W.FParent = Self then
        W.FParent := nil;
    FDisplay.RemoveWindow(Self);
    if FFrameCallback <> nil then
      wl_callback_destroy(FFrameCallback);
    if FActivationToken <> nil then
      xdg_activation_token_v1_destroy(FActivationToken);
    DisableCsd;
    DestroyRole;
    if FViewport <> nil then
      wp_viewport_destroy(FViewport);
    if FFractional <> nil then
      wp_fractional_scale_v1_destroy(FFractional);
  end;
  FDecoBuffers.Free;
  FBuffers.Free;
  if (FSurface <> nil) and (FDisplay <> nil) and not GDisconnected then
  begin
    wl_surface_destroy(FSurface);
    FDisplay.Flush;
  end;
  FEnteredOutputs.Free;
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

procedure TWlWindow.DoFrameChanged;
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
    if FBorderless or not FDecorated then
      FDecoMode := ZXDG_TOPLEVEL_DECORATION_V1_MODE_CLIENT_SIDE
    else
      FDecoMode := ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE;
    zxdg_toplevel_decoration_v1_set_mode(FDecoration, FDecoMode);
  end;
end;

{$REGION 'Client-side decorations'}

const
  // Logical pixels.
  CDecoTitleHeight = 30;
  CDecoBorder = 4;
  CDecoButtonWidth = 40;
  CDecoCorner = 14;
  // Colors (premultiplied ARGB, opaque).
  CDecoTitleActive = $FFE6E6E4;
  CDecoTitleInactive = $FFF4F4F2;
  CDecoOutline = $FF9C9C98;
  CDecoSeparator = $FFC8C8C5;
  CDecoIcon = $FF3A3A3A;
  CDecoIconInactive = $FF9A9A9A;
  CDecoHoverButton = $FFD2D2CF;
  CDecoPressedButton = $FFBDBDBA;
  CDecoHoverClose = $FFE81123;
  CDecoPressedClose = $FFB80F1D;

function DecoEnvAllowed: Boolean;
begin
  Result := GetEnvironmentVariable('FMXWAYLAND_CSD') <> '0';
end;

procedure TWlWindow.PrepareDecorations;
begin
  if (FKind = TWlWindowKind.Toplevel) and not FBorderless and FDecorated and (FDisplay.FDecorationManager = nil) and
    DecoEnvAllowed then
    EnableCsd;
end;

procedure TWlWindow.EnableCsd;
begin
  if FCsd or not FDecorated or (FDisplay.FSubcompositor = nil) or not DecoEnvAllowed then
    Exit;
  FDecoSurface := wl_compositor_create_surface(FDisplay.FCompositor);
  wl_surface_add_listener(FDecoSurface, @CDecoSurfaceListener, Self);
  FDecoSubsurface := wl_subcompositor_get_subsurface(FDisplay.FSubcompositor, FDecoSurface, FSurface);
  wl_subsurface_place_below(FDecoSubsurface, FSurface);
  FCsd := True;
  FDecoDirty := True;
  FGeometryW := -1;
  InvalidateAll;
end;

procedure TWlWindow.DisableCsd;
begin
  if not FCsd then
    Exit;
  FCsd := False;
  if FDisplay.FPointerWindow = Self then
    FDisplay.FPointerOnDeco := False;
  wl_subsurface_destroy(FDecoSubsurface);
  FDecoSubsurface := nil;
  wl_surface_destroy(FDecoSurface);
  FDecoSurface := nil;
  FDecoBuffers.Clear;
  FGeometryW := -1;
  InvalidateAll;
end;

function TWlWindow.InsetsFor(const AState: TWlWindowState; const AFullScreen: Boolean): TRect;
begin
  if not FCsd or AFullScreen then
    Result := Rect(0, 0, 0, 0)
  else if AState = TWlWindowState.Maximized then
    Result := Rect(0, CDecoTitleHeight, 0, 0)
  else
    Result := Rect(CDecoBorder, CDecoTitleHeight, CDecoBorder, CDecoBorder);
end;

function TWlWindow.DecorationInsets: TRect;
begin
  Result := InsetsFor(FState, FFullScreen);
end;

procedure TWlWindow.SetDecorated(const AValue: Boolean);
var
  Old, New, OldNormal, NewNormal: TRect;
  KeepOuter: Boolean;
begin
  if (FKind <> TWlWindowKind.Toplevel) or (AValue = FDecorated) then
    Exit;
  Old := DecorationInsets;
  OldNormal := InsetsFor(TWlWindowState.Normal, False);
  FDecorated := AValue;
  if AValue then
  begin
    // The platform's choice again: the compositor's decorations where it offers them (it may answer client-side:
    // DecorationConfigure enables the window's own then), else the window's own.
    if FDecoration <> nil then
    begin
      // The mode asked for counts until the compositor answers (DecorationConfigure).
      if FBorderless then
        FDecoMode := ZXDG_TOPLEVEL_DECORATION_V1_MODE_CLIENT_SIDE
      else
        FDecoMode := ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE;
      zxdg_toplevel_decoration_v1_set_mode(FDecoration, FDecoMode);
    end
    else if not FBorderless and DecoEnvAllowed and ((FDisplay.FDecorationManager = nil) or
      (FDecoMode = ZXDG_TOPLEVEL_DECORATION_V1_MODE_CLIENT_SIDE)) then
      EnableCsd;
  end
  else
  begin
    DisableCsd;
    if FDecoration <> nil then
    begin
      FDecoMode := ZXDG_TOPLEVEL_DECORATION_V1_MODE_CLIENT_SIDE;
      zxdg_toplevel_decoration_v1_set_mode(FDecoration, FDecoMode);
    end;
    // The window geometry is the surface from now on (also where it was never set: server-side decorations).
    FGeometryW := -1;
  end;
  WlLog(TWlLogLevel.Debug, 'decorations of "%s": %s (own title bar %s)', [FTitle, BoolToStr(AValue, True),
    BoolToStr(FCsd, True)]);
  New := DecorationInsets;
  NewNormal := InsetsFor(TWlWindowState.Normal, False);
  if Old <> New then
  begin
    // On the screen the window keeps its outer size and place (as when the compositor switches the decoration
    // mode; a maximized window must keep the configured size): the client area takes or gives back the room of
    // the decorations. Before that the client area keeps the size the program gave it.
    KeepOuter := FConfigured;
    if KeepOuter then
    begin
      FOrigin := PointF(FOrigin.X + New.Left - Old.Left, FOrigin.Y + New.Top - Old.Top);
      FWidth := Max(1, FWidth + Old.Left + Old.Right - New.Left - New.Right);
      FHeight := Max(1, FHeight + Old.Top + Old.Bottom - New.Top - New.Bottom);
    end;
    if (FNormalWidth > 0) and KeepOuter then
    begin
      FNormalWidth := Max(1, FNormalWidth + OldNormal.Left + OldNormal.Right - NewNormal.Left - NewNormal.Right);
      FNormalHeight := Max(1, FNormalHeight + OldNormal.Top + OldNormal.Bottom - NewNormal.Top - NewNormal.Bottom);
    end;
    FFullDamage := True;
    InvalidateAll;
  end;
  if (FToplevel <> nil) and ((FMinWidth > 0) or (FMinHeight > 0)) then
    SetMinSize(FMinWidth, FMinHeight);
  FDisplay.Flush;
  // FMX's window rectangle (with the decorations) and maybe its client size changed.
  DoResized;
end;

function TWlWindow.HasDecorations: Boolean;
begin
  if FKind <> TWlWindowKind.Toplevel then
    Exit(False);
  if FCsd then
    Exit(True);
  // The compositor's: asked for (server_side) and not refused.
  Result := FDecorated and not FBorderless and (FDisplay.FDecorationManager <> nil) and
    (FDecoMode <> ZXDG_TOPLEVEL_DECORATION_V1_MODE_CLIENT_SIDE);
end;

function TWlWindow.HeldPress(out ASerial: UInt32): Boolean;
begin
  ASerial := FDisplay.FPressSerial;
  Result := (FDisplay.FSeat <> nil) and (FDisplay.FPressWindow = Self) and (FDisplay.FPressButtons <> 0);
end;

function TWlWindow.BeginMove: Boolean;
var
  Serial: UInt32;
begin
  // As GTK does: the move starts when the pointer is dragged while the button is held (TWlDisplay.DragMove), so a
  // click - also each click of a double click - stays the window's. (A compositor taking the pointer at the press
  // lets the release go, and GNOME Shell moves a maximized window it got that way to the top left on restore.)
  Result := (FToplevel <> nil) and FVisible and HeldPress(Serial);
  if Result then
  begin
    FDisplay.FMoveWindow := Self;
    FDisplay.FMoveFrom := FDisplay.FPointerPos;
  end;
  WlLog(TWlLogLevel.Debug, 'move of "%s" asked: %s', [FTitle, BoolToStr(Result, True)]);
end;

function TWlWindow.BeginResize(const AEdges: Cardinal): Boolean;
var
  Serial: UInt32;
begin
  // Other values are a protocol error (invalid_resize_edge).
  Result := (AEdges in [XDG_TOPLEVEL_RESIZE_EDGE_TOP, XDG_TOPLEVEL_RESIZE_EDGE_BOTTOM, XDG_TOPLEVEL_RESIZE_EDGE_LEFT,
    XDG_TOPLEVEL_RESIZE_EDGE_TOP_LEFT, XDG_TOPLEVEL_RESIZE_EDGE_BOTTOM_LEFT, XDG_TOPLEVEL_RESIZE_EDGE_RIGHT,
    XDG_TOPLEVEL_RESIZE_EDGE_TOP_RIGHT, XDG_TOPLEVEL_RESIZE_EDGE_BOTTOM_RIGHT]) and (FToplevel <> nil) and
    FVisible and HeldPress(Serial);
  if Result then
  begin
    xdg_toplevel_resize(FToplevel, FDisplay.FSeat, Serial, AEdges);
    FDisplay.Flush;
  end;
  WlLog(TWlLogLevel.Debug, 'resize (edges %d) of "%s" asked: %s', [AEdges, FTitle, BoolToStr(Result, True)]);
end;

function TWlWindow.ShowWindowMenu(const AX, AY: Integer): Boolean;
var
  Serial: UInt32;
begin
  Result := (FToplevel <> nil) and FVisible and FCanWindowMenu and HeldPress(Serial);
  if Result then
  begin
    xdg_toplevel_show_window_menu(FToplevel, FDisplay.FSeat, Serial, AX, AY);
    FDisplay.Flush;
  end;
  WlLog(TWlLogLevel.Debug, 'window menu of "%s" at %d,%d asked: %s', [FTitle, AX, AY, BoolToStr(Result, True)]);
end;

procedure TWlWindow.Minimize;
begin
  if (FToplevel = nil) or not FVisible or not FCanMinimize then
    Exit;
  xdg_toplevel_set_minimized(FToplevel);
  FDisplay.Flush;
  // Wayland does not tell about minimized windows: the state is the request's.
  FState := TWlWindowState.Minimized;
  DoStateChanged(FState);
end;

procedure TWlWindow.SetMaximized(const AValue: Boolean);
begin
  if (FToplevel = nil) or not FVisible then
  begin
    if AValue then
      SetState(TWlWindowState.Maximized)
    else
      SetState(TWlWindowState.Normal);
    Exit;
  end;
  if AValue then
    xdg_toplevel_set_maximized(FToplevel)
  else
    xdg_toplevel_unset_maximized(FToplevel);
  FDisplay.Flush;
end;

procedure TWlWindow.UpdateGeometry;
var
  Ins: TRect;
  X, Y, W, H: Integer;
begin
  if (FXdgSurface = nil) or not (FCsd or (FGeometryW <> 0)) then
    Exit;
  Ins := DecorationInsets;
  X := -Ins.Left;
  Y := -Ins.Top;
  W := FWidth + Ins.Left + Ins.Right;
  H := FHeight + Ins.Top + Ins.Bottom;
  if (X = FGeometryX) and (Y = FGeometryY) and (W = FGeometryW) and (H = FGeometryH) then
    Exit;
  // The window geometry includes the decorations, which lie at negative coordinates of the window's surface.
  xdg_surface_set_window_geometry(FXdgSurface, X, Y, W, H);
  if FDecoSubsurface <> nil then
    wl_subsurface_set_position(FDecoSubsurface, X, Y);
  FGeometryX := X;
  FGeometryY := Y;
  FGeometryW := W;
  FGeometryH := H;
  FDecoDirty := True;
end;

procedure FillFrame(const AFrame: TWlFrame; const AX, AY, AWidth, AHeight: Integer; const AColor: Cardinal);
var
  X0, Y0, X1, Y1, X, Y: Integer;
  P: PCardinal;
begin
  X0 := Max(AX, 0);
  Y0 := Max(AY, 0);
  X1 := Min(AX + AWidth, AFrame.Width);
  Y1 := Min(AY + AHeight, AFrame.Height);
  for Y := Y0 to Y1 - 1 do
  begin
    P := PCardinal(PByte(AFrame.Bits) + NativeInt(Y) * AFrame.Stride + X0 * 4);
    for X := X0 to X1 - 1 do
    begin
      P^ := AColor;
      Inc(P);
    end;
  end;
end;

/// A line of thickness AThick (buffer pixels) from (X0,Y0) to (X1,Y1), drawn as squares along it.
procedure LineFrame(const AFrame: TWlFrame; const X0, Y0, X1, Y1, AThick: Integer; const AColor: Cardinal);
var
  N, I: Integer;
begin
  N := Max(1, Max(Abs(X1 - X0), Abs(Y1 - Y0)));
  for I := 0 to N do
    FillFrame(AFrame, X0 + ((X1 - X0) * I) div N - AThick div 2, Y0 + ((Y1 - Y0) * I) div N - AThick div 2, AThick,
      AThick, AColor);
end;

procedure TWlWindow.PaintDecorations;
var
  Ins: TRect;
  S, TW, TH, BW, BH, I, Right, BtnTop, BtnX, CX, CY, R, Thick: Integer;
  Buf: TWlBuffer;
  Frame: TWlFrame;
  Part: TWlDecoPart;
  Bg, Fg: Cardinal;
  Maximized: Boolean;
begin
  if not FCsd or not FDecoDirty then
    Exit;
  if FFullScreen then
  begin
    wl_surface_attach(FDecoSurface, nil, 0, 0);
    wl_surface_commit(FDecoSurface);
    FDecoDirty := False;
    Exit;
  end;
  Ins := DecorationInsets;
  Maximized := FState = TWlWindowState.Maximized;
  // An integer buffer scale for the decorations (also under a fractional scale: they are small).
  S := Max(1, Ceil(FScale - 0.01));
  TW := FWidth + Ins.Left + Ins.Right;
  TH := FHeight + Ins.Top + Ins.Bottom;
  BW := TW * S;
  BH := TH * S;
  Buf := nil;
  for I := FDecoBuffers.Count - 1 downto 0 do
    if not FDecoBuffers[I].Busy then
    begin
      if (FDecoBuffers[I].Width = BW) and (FDecoBuffers[I].Height = BH) then
        Buf := FDecoBuffers[I]
      else
        FDecoBuffers.Delete(I);
    end;
  if Buf = nil then
  begin
    if FDecoBuffers.Count >= 2 then
      Exit; // both with the compositor: try again later
    Buf := TWlBuffer.Create(FDisplay, BW, BH, WL_SHM_FORMAT_ARGB8888);
    FDecoBuffers.Add(Buf);
  end;
  Frame.Bits := Buf.Data;
  Frame.Stride := Buf.Stride;
  Frame.Width := BW;
  Frame.Height := BH;
  Frame.Scale := S;
  Frame.Drawn := False;
  if FActivated then
    Bg := CDecoTitleActive
  else
    Bg := CDecoTitleInactive;
  FillFrame(Frame, 0, 0, BW, BH, Bg);
  // A transparent hole where the window's own surface is (it lies above; some compositors - WSLg - also show the
  // stacking of subsurfaces differently).
  FillFrame(Frame, Ins.Left * S, Ins.Top * S, FWidth * S, FHeight * S, 0);
  if not Maximized then
  begin
    FillFrame(Frame, 0, 0, BW, S, CDecoOutline);
    FillFrame(Frame, 0, BH - S, BW, S, CDecoOutline);
    FillFrame(Frame, 0, 0, S, BH, CDecoOutline);
    FillFrame(Frame, BW - S, 0, S, BH, CDecoOutline);
  end;
  FillFrame(Frame, Ins.Left * S, (Ins.Top - 1) * S, FWidth * S, S, CDecoSeparator);
  // Buttons: minimize, maximize, close from the right.
  Right := TW - Ins.Right;
  if Maximized then
    BtnTop := 0
  else
    BtnTop := CDecoBorder;
  Thick := Max(1, Round(1.2 * S));
  for I := 0 to DecoButtonCount - 1 do
  begin
    Part := DecoButtonAt(I);
    BtnX := Right - (I + 1) * CDecoButtonWidth;
    if FActivated then
      Fg := CDecoIcon
    else
      Fg := CDecoIconInactive;
    if (FDecoPressed = Part) and (FDecoHover = Part) then
    begin
      if Part = TWlDecoPart.Close then
        FillFrame(Frame, BtnX * S, BtnTop * S, CDecoButtonWidth * S, (Ins.Top - 1 - BtnTop) * S, CDecoPressedClose)
      else
        FillFrame(Frame, BtnX * S, BtnTop * S, CDecoButtonWidth * S, (Ins.Top - 1 - BtnTop) * S, CDecoPressedButton);
      if Part = TWlDecoPart.Close then
        Fg := $FFFFFFFF;
    end
    else if FDecoHover = Part then
    begin
      if Part = TWlDecoPart.Close then
      begin
        FillFrame(Frame, BtnX * S, BtnTop * S, CDecoButtonWidth * S, (Ins.Top - 1 - BtnTop) * S, CDecoHoverClose);
        Fg := $FFFFFFFF;
      end
      else
        FillFrame(Frame, BtnX * S, BtnTop * S, CDecoButtonWidth * S, (Ins.Top - 1 - BtnTop) * S, CDecoHoverButton);
    end;
    CX := (BtnX + CDecoButtonWidth div 2) * S;
    CY := ((BtnTop + Ins.Top - 1) * S) div 2;
    R := 5 * S;
    case Part of
      TWlDecoPart.Close:
        begin
          LineFrame(Frame, CX - R, CY - R, CX + R, CY + R, Thick, Fg);
          LineFrame(Frame, CX - R, CY + R, CX + R, CY - R, Thick, Fg);
        end;
      TWlDecoPart.Maximize:
        if Maximized then
        begin
          // Two overlapping squares: restore.
          FillFrame(Frame, CX - R + 2 * S, CY - R, 2 * R - 2 * S, Thick, Fg);
          FillFrame(Frame, CX + R - Thick, CY - R, Thick, 2 * R - 2 * S, Fg);
          FillFrame(Frame, CX - R, CY - R + 2 * S, 2 * R - 2 * S, Thick, Fg);
          FillFrame(Frame, CX - R, CY + R - Thick, 2 * R - 2 * S, Thick, Fg);
          FillFrame(Frame, CX - R, CY - R + 2 * S, Thick, 2 * R - 2 * S, Fg);
          FillFrame(Frame, CX + R - 2 * S - Thick, CY - R + 2 * S, Thick, 2 * R - 2 * S, Fg);
        end
        else
        begin
          FillFrame(Frame, CX - R, CY - R, 2 * R, Thick, Fg);
          FillFrame(Frame, CX - R, CY + R - Thick, 2 * R, Thick, Fg);
          FillFrame(Frame, CX - R, CY - R, Thick, 2 * R, Fg);
          FillFrame(Frame, CX + R - Thick, CY - R, Thick, 2 * R, Fg);
        end;
      TWlDecoPart.Minimize:
        FillFrame(Frame, CX - R, CY + R - Thick, 2 * R, Thick, Fg);
    end;
  end;
  DoDrawTitle(@Frame, Rect((Ins.Left + 10) * S, BtnTop * S, (Right - DecoButtonCount * CDecoButtonWidth - 8) * S,
    (Ins.Top - 1) * S), FTitle, FActivated);
  wl_surface_attach(FDecoSurface, Buf.Buffer, 0, 0);
  if FDisplay.FCompositorVersion >= 3 then
    wl_surface_set_buffer_scale(FDecoSurface, S);
  wl_surface_damage(FDecoSurface, 0, 0, TW, TH);
  // A synchronized subsurface: this takes effect with the next commit of the window's surface.
  wl_surface_commit(FDecoSurface);
  Buf.Busy := True;
  FDecoDirty := False;
end;

function TWlWindow.DecoPartAt(const AX, AY: Single): TWlDecoPart;
var
  Ins: TRect;
  TW, TH, Right: Integer;
  L, R, T, B: Boolean;
begin
  Result := TWlDecoPart.None;
  if not FCsd then
    Exit;
  Ins := DecorationInsets;
  TW := FWidth + Ins.Left + Ins.Right;
  TH := FHeight + Ins.Top + Ins.Bottom;
  if FState <> TWlWindowState.Maximized then
  begin
    L := AX < CDecoBorder;
    R := AX >= TW - CDecoBorder;
    T := AY < CDecoBorder;
    B := AY >= TH - CDecoBorder;
    // Corners are larger than the borders: easier to grab.
    if L or R then
    begin
      T := T or (AY < CDecoCorner);
      B := B or (AY >= TH - CDecoCorner);
    end;
    if T or B then
    begin
      L := L or (AX < CDecoCorner);
      R := R or (AX >= TW - CDecoCorner);
    end;
    if T and L then
      Exit(TWlDecoPart.TopLeft);
    if T and R then
      Exit(TWlDecoPart.TopRight);
    if B and L then
      Exit(TWlDecoPart.BottomLeft);
    if B and R then
      Exit(TWlDecoPart.BottomRight);
    if L then
      Exit(TWlDecoPart.Left);
    if R then
      Exit(TWlDecoPart.Right);
    if T then
      Exit(TWlDecoPart.Top);
    if B then
      Exit(TWlDecoPart.Bottom);
  end;
  if AY < Ins.Top then
  begin
    Right := TW - Ins.Right;
    if AX >= Right - DecoButtonCount * CDecoButtonWidth then
      Result := DecoButtonAt(Max(0, Ceil((Right - AX) / CDecoButtonWidth) - 1))
    else
      Result := TWlDecoPart.Title;
  end;
end;

function TWlWindow.DecoButtonCount: Integer;
begin
  Result := 1 + Ord(FCanMaximize) + Ord(FCanMinimize);
end;

function TWlWindow.DecoButtonAt(const AIndex: Integer): TWlDecoPart;
const
  COrder: array[0..2] of TWlDecoPart = (TWlDecoPart.Close, TWlDecoPart.Maximize, TWlDecoPart.Minimize);
var
  N: Integer;
  P: TWlDecoPart;
begin
  // From the right: close, maximize, minimize, of those the window manager offers.
  N := 0;
  for P in COrder do
    if (P = TWlDecoPart.Close) or ((P = TWlDecoPart.Maximize) and FCanMaximize) or
      ((P = TWlDecoPart.Minimize) and FCanMinimize) then
    begin
      if N = AIndex then
        Exit(P);
      Inc(N);
    end;
  Result := TWlDecoPart.Title;
end;

procedure TWlWindow.DecoPointer(const AEvent: TWlPointerEvent; const AX, AY: Single; const AState: Integer;
  const ASerial: UInt32);
const
  CEdges: array[TWlDecoPart] of UInt32 = (0, 0, 0, 0, 0, XDG_TOPLEVEL_RESIZE_EDGE_LEFT,
    XDG_TOPLEVEL_RESIZE_EDGE_RIGHT, XDG_TOPLEVEL_RESIZE_EDGE_TOP, XDG_TOPLEVEL_RESIZE_EDGE_BOTTOM,
    XDG_TOPLEVEL_RESIZE_EDGE_TOP_LEFT, XDG_TOPLEVEL_RESIZE_EDGE_TOP_RIGHT, XDG_TOPLEVEL_RESIZE_EDGE_BOTTOM_LEFT,
    XDG_TOPLEVEL_RESIZE_EDGE_BOTTOM_RIGHT);
  CCursors: array[TWlDecoPart] of Integer = (crDefault, crDefault, crDefault, crDefault, crDefault, crSizeWE,
    crSizeWE, crSizeNS, crSizeNS, crSizeNWSE, crSizeNESW, crSizeNESW, crSizeNWSE);
  CButtons = [TWlDecoPart.Minimize, TWlDecoPart.Maximize, TWlDecoPart.Close];
var
  Part: TWlDecoPart;
  Now: Int64;
begin
  if FToplevel = nil then
    Exit;
  if AEvent = TWlPointerEvent.Leave then
    Part := TWlDecoPart.None
  else
    Part := DecoPartAt(AX, AY);
  if Part <> FDecoHover then
  begin
    if (Part in CButtons) or (FDecoHover in CButtons) then
      FDecoDirty := True;
    FDecoHover := Part;
  end;
  if AEvent <> TWlPointerEvent.Leave then
    if CCursors[Part] <> FDisplay.FDecoCursor then
    begin
      FDisplay.FDecoCursor := CCursors[Part];
      FDisplay.ApplyCursor;
    end;
  case AEvent of
    TWlPointerEvent.Leave:
      if FDecoPressed <> TWlDecoPart.None then
      begin
        FDecoPressed := TWlDecoPart.None;
        FDecoDirty := True;
      end;
    TWlPointerEvent.Down:
      if AState = WL_STATE_LEFT then
      begin
        if Part = TWlDecoPart.Title then
        begin
          Now := MonotonicMs;
          if (Now - FDecoLastClick <= CDoubleClickMs) and FCanMaximize then
          begin
            FDecoLastClick := 0;
            DecoAction(TWlDecoPart.Maximize);
          end
          else
          begin
            FDecoLastClick := Now;
            // The move starts when the pointer is dragged (TWlDisplay.StartMove): a click stays a click.
            FDisplay.FMoveWindow := Self;
            FDisplay.FMoveFrom := PointF(AX, AY);
          end;
        end
        else if Part in CButtons then
        begin
          FDecoPressed := Part;
          FDecoDirty := True;
        end
        else if CEdges[Part] <> 0 then
          xdg_toplevel_resize(FToplevel, FDisplay.FSeat, ASerial, CEdges[Part]);
      end
      else if (AState = WL_STATE_RIGHT) and (Part = TWlDecoPart.Title) and FCanWindowMenu then
        // In the coordinates of the window's surface (the decorations' starts at the window geometry's origin).
        xdg_toplevel_show_window_menu(FToplevel, FDisplay.FSeat, ASerial, Round(AX) + FGeometryX,
          Round(AY) + FGeometryY);
    TWlPointerEvent.Up:
      if (AState = WL_STATE_LEFT) and (FDecoPressed <> TWlDecoPart.None) then
      begin
        Part := FDecoPressed;
        FDecoPressed := TWlDecoPart.None;
        FDecoDirty := True;
        if Part = FDecoHover then
          DecoAction(Part);
      end;
  end;
  FDisplay.Flush;
end;

procedure TWlWindow.DecoAction(const APart: TWlDecoPart);
begin
  case APart of
    TWlDecoPart.Close:
      DoCloseRequest;
    TWlDecoPart.Maximize:
      if FState = TWlWindowState.Maximized then
        xdg_toplevel_unset_maximized(FToplevel)
      else
        xdg_toplevel_set_maximized(FToplevel);
    TWlDecoPart.Minimize:
      Minimize;
  end;
end;

procedure TWlWindow.DoDrawTitle(const AFrame: PWlFrame; const ARect: TRect; const ATitle: string;
  const AActive: Boolean);
begin
end;

{$ENDREGION}

procedure TWlWindow.CreatePopupRole;
var
  Positioner: Pxdg_positioner;
  RelX, RelY, AX, AY: Integer;
  PIns: TRect;
begin
  Positioner := xdg_wm_base_create_positioner(FDisplay.FWmBase);
  xdg_positioner_set_size(Positioner, Max(1, FWidth), Max(1, FHeight));
  // Relative to the parent's window geometry, which starts at its decorations.
  PIns := FParent.DecorationInsets;
  RelX := Round(FOrigin.X - FParent.FOrigin.X) + PIns.Left;
  RelY := Round(FOrigin.Y - FParent.FOrigin.Y) + PIns.Top;
  FPopupAskX := RelX;
  FPopupAskY := RelY;
  // The anchor point stays inside the parent; the rest of the distance is an offset.
  AX := EnsureRange(RelX, 0, Max(0, FParent.FWidth + PIns.Left + PIns.Right - 1));
  AY := EnsureRange(RelY, 0, Max(0, FParent.FHeight + PIns.Top + PIns.Bottom - 1));
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

procedure TWlWindow.Activate;
begin
  // Not when the compositor says the window is active already: FMX asks again for the window it is told about.
  if (FDisplay.FActivation = nil) or (FToplevel = nil) or not FVisible or (FActivationToken <> nil) or
    FActivated then
    Exit;
  WlLog(TWlLogLevel.Debug, 'activation token for "%s" (serial %d)', [FTitle, FDisplay.FLastInputSerial]);
  FActivationToken := xdg_activation_v1_get_activation_token(FDisplay.FActivation);
  xdg_activation_token_v1_add_listener(FActivationToken, @CActivationTokenListener, Self);
  if (FDisplay.FSeat <> nil) and (FDisplay.FLastInputSerial <> 0) then
    xdg_activation_token_v1_set_serial(FActivationToken, FDisplay.FLastInputSerial, FDisplay.FSeat);
  if FDisplay.FKeyboardWindow <> nil then
    xdg_activation_token_v1_set_surface(FActivationToken, FDisplay.FKeyboardWindow.FSurface);
  xdg_activation_token_v1_commit(FActivationToken);
  FDisplay.Flush;
end;

procedure TWlWindow.Show;
var
  UsePopup: Boolean;
begin
  if FVisible then
    Exit;
  UsePopup := (FKind = TWlWindowKind.Popup) and (FParent <> nil);
  if (FKind = TWlWindowKind.Popup) and not UsePopup then
    WlLog(TWlLogLevel.Debug, 'popup without a parent: shown as a toplevel', []);
  if UsePopup and not FParent.CanParentPopups then
  begin
    // xdg-shell: the parent of an xdg_popup must be mapped before the popup (configured and its first frame
    // committed). The popup waits for it (ParentMapped), at the same place relative to it.
    WlLog(TWlLogLevel.Debug, 'popup waits until its parent "%s" is mapped', [FParent.FTitle]);
    FPopupPending := True;
    FPendingOffset := FOrigin - FParent.FOrigin;
    FVisible := True;
    FConfigured := False;
    FMapped := False;
    Exit;
  end;
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
      SetMinSize(FMinWidth, FMinHeight);
    FGeometryW := -1;
    FDecoDirty := True;
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
    if (Ws[I].FParent = Self) and Ws[I].FVisible and ((Ws[I].FPopup <> nil) or Ws[I].FPopupPending) then
      Ws[I].Hide;
end;

function TWlWindow.CanParentPopups: Boolean;
begin
  // Mapped: configured and a frame committed (an external presenter commits its own frames once configured).
  Result := FVisible and (FXdgSurface <> nil) and (FMapped or (FExternalPresentation and FConfigured));
end;

procedure TWlWindow.ParentMapped;
var
  W: TWlWindow;
begin
  for W in FDisplay.FWindows.ToArray do
    if (W.FParent = Self) and W.FVisible and FDisplay.FWindows.Contains(W) then
    begin
      if W.FPopupPending then
      begin
        W.FPopupPending := False;
        W.FVisible := False;
        W.FOrigin := FOrigin + W.FPendingOffset;
        WlLog(TWlLogLevel.Debug, 'parent "%s" mapped: the popup is made now', [FTitle]);
        W.Show;
      end
      else if W.FToplevel <> nil then
        // A parent that was not mapped counts as none (xdg_toplevel.set_parent): again now.
        W.SetTransientParent;
    end;
end;

procedure TWlWindow.Hide;
begin
  if not FVisible then
    Exit;
  HideChildPopups;
  if FPopupPending then
  begin
    // Never made: nothing to unmap.
    FPopupPending := False;
    FVisible := False;
    Exit;
  end;
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
  WasConfigured, SizeChanged, StateChanged, DecoSwitched, FrameChanged: Boolean;
  W, H: Integer;
  NewState: TWlWindowState;
  Ins: TRect;
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
    if (W > 0) and (H > 0) then
    begin
      // The size is the window geometry's: without the decorations of the new state. (When the compositor switches
      // the decoration mode, as sway's "border csd" does, the window keeps its outer size: the client area changes.)
      Ins := InsetsFor(NewState, FPendingFullScreen);
      W := Max(1, W - Ins.Left - Ins.Right);
      H := Max(1, H - Ins.Top - Ins.Bottom);
    end;
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
    if (FFullScreen <> FPendingFullScreen) or (NewState <> FState) or (FPendingActivated <> FActivated) or
      SizeChanged or FDecoSwitched then
      FDecoDirty := True;
    DecoSwitched := FDecoSwitched;
    FDecoSwitched := False;
    FFullScreen := FPendingFullScreen;
    if FState = TWlWindowState.Minimized then
    begin
      // Wayland does not tell when a minimized window comes back: being activated again means it has.
      StateChanged := FPendingActivated;
      if not StateChanged then
        NewState := TWlWindowState.Minimized;
    end
    else
      StateChanged := NewState <> FState;
    FState := NewState;
    FrameChanged := (FPendingStateBits <> FStateBits) or FCapabilitiesChanged;
    FStateBits := FPendingStateBits;
    FCapabilitiesChanged := False;
    // The state first: FMX's OnResize of a maximized form sees wsMaximized.
    if StateChanged then
      DoStateChanged(FState);
    if SizeChanged or (FCsd and StateChanged) or DecoSwitched then
      DoResized;
    if FPendingActivated <> FActivated then
    begin
      FActivated := FPendingActivated;
      DoActivate(FActivated);
    end;
    if FrameChanged then
      DoFrameChanged;
  end;
  if not WasConfigured or SizeChanged then
    InvalidateAll;
  if not WasConfigured and FExternalPresentation then
    ParentMapped;
end;

function TWlWindow.NeedsPaint(const ANow: Int64): Boolean;
begin
  // A frame callback that does not come (the compositor does not show the window) must not stop painting forever.
  Result := FVisible and FConfigured and (not FDirty.IsEmpty or (FCsd and FDecoDirty and FMapped)) and
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
  if not (FVisible and FConfigured) then
    Exit;
  if FDirty.IsEmpty then
  begin
    // Only the decorations changed (hover, activation): they apply with a commit of the window's surface.
    if FCsd and FDecoDirty and FMapped then
    begin
      UpdateGeometry;
      PaintDecorations;
      wl_surface_commit(FSurface);
    end;
    Exit;
  end;
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
  UpdateGeometry;
  PaintDecorations;
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
  FFullDamage := False;
  if not FMapped then
  begin
    FMapped := True;
    ParentMapped;
  end;
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
  FDecoDirty := True;
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
      begin
        xdg_toplevel_set_minimized(FToplevel);
        FState := TWlWindowState.Minimized;
      end;
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
var
  Ins: TRect;
begin
  FMinWidth := Max(0, AWidth);
  FMinHeight := Max(0, AHeight);
  if FToplevel <> nil then
  begin
    Ins := InsetsFor(TWlWindowState.Normal, False);
    xdg_toplevel_set_min_size(FToplevel, FMinWidth + Ins.Left + Ins.Right, FMinHeight + Ins.Top + Ins.Bottom);
  end;
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
  GDisconnected := True;
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
  else if AInterface = 'wl_subcompositor' then
    FSubcompositor := wl_registry_bind(FRegistry, AName, @wl_subcompositor_interface, 1)
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
  if FPressWindow = AWindow then
    FPressWindow := nil;
  if FMoveWindow = AWindow then
    FMoveWindow := nil;
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

procedure TWlDisplay.StartMove;
var
  W: TWlWindow;
begin
  W := FMoveWindow;
  FMoveWindow := nil;
  if (W = nil) or (W.FToplevel = nil) or (FPressWindow <> W) or (FPressButtons = 0) or (FSeat = nil) then
    Exit;
  WlLog(TWlLogLevel.Debug, 'move of "%s" starts (dragged)', [W.FTitle]);
  xdg_toplevel_move(W.FToplevel, FSeat, FPressSerial);
  Flush;
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
  if (Delta <> 0) and (FPointerWindow <> nil) and not FPointerOnDeco then
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
  Cursor: Integer;
begin
  if (FPointer = nil) or (FPointerWindow = nil) then
    Exit;
  // Over client-side decorations the decoration's cursor (resize arrows), over the client FMX's.
  if FPointerOnDeco then
    Cursor := FDecoCursor
  else
    Cursor := FCursor;
  if Cursor = crNone then
  begin
    wl_pointer_set_cursor(FPointer, FPointerSerial, nil, 0, 0);
    Exit;
  end;
  if FCursorShapeDevice <> nil then
  begin
    wp_cursor_shape_device_v1_set_shape(FCursorShapeDevice, FPointerSerial, CursorShape(Cursor));
    Exit;
  end;
  if not LoadCursorTheme then
    Exit;
  C := nil;
  for N in CursorNames(Cursor) do
  begin
    C := wl_cursor_theme_get_cursor(FCursorTheme, PAnsiChar(UTF8String(N)));
    if C <> nil then
      Break;
  end;
  if (C = nil) and (Cursor <> crDefault) then
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
  if not FPointerOnDeco then
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

/// The WL_STATE_* bit of a modifier key (0 for other keys). The compositor reports a modifier's own change after
/// the key event; FMX (like Windows) expects Ctrl in the shift state of the Ctrl key's press and not in its release.
function ModifierBit(const AKeysym: UInt32): Integer;
begin
  case AKeysym of
    $FFE1, $FFE2:
      Result := WL_STATE_SHIFT;
    $FFE3, $FFE4:
      Result := WL_STATE_CTRL;
    $FFE7..$FFEA:
      Result := WL_STATE_ALT;
    $FFEB..$FFEE:
      Result := WL_STATE_SUPER;
  else
    Result := 0;
  end;
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
      W.DoKey(TWlKeyEvent.Down, Vk, #0, FModState or ModifierBit(Sym));
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
      W.DoKey(TWlKeyEvent.Up, KeyToVirtualKey(Sym, AKey), #0, FModState and not ModifierBit(Sym));
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
  if (FOwnSource <> nil) or FOwnLocal then
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
  if (FOwnSource <> nil) or FOwnLocal then
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
    // No seat or no data device manager: a clipboard inside the process only.
    WlLogOnce('clipboard', 'no wl_data_device (no seat?): the clipboard works inside this program only');
    FOwnLocal := True;
    FOwnText := UTF8String(AText);
    Exit;
  end;
  FOwnLocal := False;
  WlLog(TWlLogLevel.Debug, 'clipboard: set %d characters (serial %d)', [Length(AText), FLastInputSerial]);
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
