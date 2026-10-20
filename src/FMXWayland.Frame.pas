{ FMXWayland: native Wayland platform for Delphi FireMonkey on Linux.
  Copyright (c) 2026 Fasday. MIT license, see LICENSE. }

/// <summary>Window frame services for programs that draw their own title bar (FMR Ribbon, for example): turn the
/// platform's decorations off for a window, start interactive moves and resizes, show the compositor's window menu,
/// minimize and maximize, learn the window's states (activated, maximized, tiled, ...) and the window manager's
/// capabilities.</summary>
/// <remarks>The contract (see README.md, "IFMXWaylandWindowFrame"): FMXWayland registers an object implementing
/// IFMXWaylandWindowFrame as an FMX platform service when it connects (FmuxInit, next to IFMXWaylandNativeWindow).
/// A library that must not depend on FMXWayland declares the same interfaces (same GUIDs, the same methods in the
/// same order, the same signatures, Delphi's default calling convention) and asks for the service with
/// TPlatformServices.Current.SupportsPlatformService(IID, Intf). The declaration comes from FMR Ribbon
/// (Source\Frame\FMR.Frame.Wayland.pas, Docs\LINUX.md). Do not change it: add a new interface with a new GUID
/// instead.</remarks>
/// <remarks>The X11 backend implements the same contract: Motif decoration hints, EWMH operations where
/// advertised and pointer-grab/client-geometry fallbacks for legacy window managers. The interface name and GUID
/// stay unchanged so existing Linux frame integrations (FMR Ribbon) work with either backend.</remarks>
unit FMXWayland.Frame;

interface

uses
  System.Types, FMX.Types;

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
  /// <summary>Told by the platform about the states of a toplevel (IFMXWaylandWindowFrame.SetFrameListener).
  /// </summary>
  IFMXWaylandWindowFrameListener = interface
    ['{785C5760-E413-4153-82DF-E857D1AA70AC}']
    /// <summary>Called on the main thread once from SetFrameListener and then after every xdg_toplevel configure
    /// that changed the states or brought new capabilities. AStates: FmxwState* bits; ACapabilities: FmxwCap* bits
    /// or FmxwCapsUnknown.</summary>
    procedure WindowFrameChanged(const AHandle: TWindowHandle; const AStates, ACapabilities: Cardinal);
  end;

  /// <summary>Window frame services of FMXWayland for programs that draw their own title bar (FMX platform
  /// service). AHandle is the form's Handle; for handles that are not toplevels of FMXWayland (popups, foreign
  /// handles) the methods do nothing and return False/0. Main thread only.</summary>
  IFMXWaylandWindowFrame = interface
    ['{547B5786-5639-43A4-A598-1A03B465783A}']
    /// <summary>False: no decorations for the window, neither FMXWayland's client-side title bar and borders nor
    /// the compositor's (xdg-decoration mode client_side); the surface is all client area and the window geometry,
    /// FMX's window rectangle equals the client rectangle. Kept for the window (configures and hide/show do not
    /// change it). True (default): the platform's decorations again. Before the window's first show only the choice
    /// is recorded: the form's Width and Height (what the program set) stay and become the client area at the show.
    /// A window shown once keeps its outer size; FMX gets its new bounds.</summary>
    procedure SetDecorated(const AHandle: TWindowHandle; const AValue: Boolean);
    /// <summary>True when the window has decorations now (FMXWayland's or the compositor's).</summary>
    function GetDecorated(const AHandle: TWindowHandle): Boolean;
    /// <summary>xdg_toplevel.move with the seat and the serial of the latest pointer button press on any surface
    /// of the window, while it is held: call it while handling that press (MouseDown). The move starts when the
    /// pointer is dragged 4 pixels with the button held (as GTK does), so a click or a double click stays one.
    /// False without such a press.</summary>
    function BeginMove(const AHandle: TWindowHandle): Boolean;
    /// <summary>xdg_toplevel.resize with the seat, the serial of the latest press held on the window and AEdges
    /// (FmxwEdge*, not FmxwEdgeNone). False without a press or with invalid edges.</summary>
    function BeginResize(const AHandle: TWindowHandle; const AEdges: Cardinal): Boolean;
    /// <summary>xdg_toplevel.show_window_menu at a point of the client area (dp = surface coordinates) with the
    /// seat and the serial of the latest press held on the window. False without a press or without the
    /// window_menu capability.</summary>
    function ShowWindowMenu(const AHandle: TWindowHandle; const AClientPoint: TPointF): Boolean;
    /// <summary>xdg_toplevel.set_minimized (where the window manager can minimize); FMX's WindowState becomes
    /// wsMinimized.</summary>
    procedure Minimize(const AHandle: TWindowHandle);
    /// <summary>xdg_toplevel.set_maximized / unset_maximized (the state follows with the next configure).</summary>
    procedure SetMaximized(const AHandle: TWindowHandle; const AValue: Boolean);
    /// <summary>FmxwState* bits of the last configure.</summary>
    function GetStates(const AHandle: TWindowHandle): Cardinal;
    /// <summary>FmxwCap* bits (xdg_toplevel.wm_capabilities) or FmxwCapsUnknown.</summary>
    function GetCapabilities(const AHandle: TWindowHandle): Cardinal;
    /// <summary>Sets (nil: removes) the listener of the window; FMXWayland keeps a reference until it is replaced
    /// or the window is destroyed, and calls it once right away.</summary>
    procedure SetFrameListener(const AHandle: TWindowHandle; const AListener: IFMXWaylandWindowFrameListener);
  end;

implementation

end.
