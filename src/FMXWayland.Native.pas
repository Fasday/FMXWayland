{ FMXWayland: native Wayland platform for Delphi FireMonkey on Linux.
  Copyright (c) 2026 Fasday. MIT license, see LICENSE. }

/// <summary>The native Wayland handles of FMX windows, for code that renders to them itself (a GPU canvas creating a
/// VkSurfaceKHR with vkCreateWaylandSurfaceKHR, for example).</summary>
/// <remarks>The contract (see README.md, "IFMXWaylandNativeWindow"): FMXWayland registers an object implementing
/// IFMXWaylandNativeWindow as an FMX platform service when it connects (FmuxInit, during the initialization of
/// FMX.Platform). A library that must not depend on FMXWayland declares an interface with the same GUID, the same
/// methods in the same order and the same signatures, and asks for it with
/// TPlatformServices.Current.SupportsPlatformService(IID, Intf). Do not change this declaration: add a new
/// interface with a new GUID instead.</remarks>
unit FMXWayland.Native;

interface

uses
  System.Types, FMX.Types;

type
  /// <summary>Native Wayland handles of FMX windows (FMX platform service).</summary>
  IFMXWaylandNativeWindow = interface
    ['{B04A2FBC-1322-42BC-98A6-D526A7854F2C}']
    /// <summary>The wl_display* of the process's connection to the compositor.</summary>
    function GetWaylandDisplay: Pointer;
    /// <summary>The wl_surface* of the window of AHandle; nil if AHandle is not a window of FMXWayland.</summary>
    function GetWaylandSurface(const AHandle: TWindowHandle): Pointer;
    /// <summary>Size of the window's surface in buffer pixels (logical client size x scale, rounded): the size of a
    /// swapchain for it.</summary>
    function GetBufferSize(const AHandle: TWindowHandle): TSize;
    /// <summary>Buffer pixels per logical pixel (1, 2, ... or fractional with wp_fractional_scale_v1).</summary>
    function GetScale(const AHandle: TWindowHandle): Single;
    /// <summary>True: the caller presents to the surface itself (Vulkan WSI); FMXWayland keeps calling FMX's paint
    /// but stops attaching its own wl_shm frames to the surface. False: back to FMXWayland's frames.</summary>
    procedure SetExternalPresentation(const AHandle: TWindowHandle; const AValue: Boolean);
  end;

implementation

end.
