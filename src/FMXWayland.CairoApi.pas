{ FMXWayland: system Cairo/Pango/GdkPixbuf bindings.
  Written by Hemul GM. Copyright (c) 2026 Fasday and contributors. MIT license, see LICENSE. }

/// <summary>Bindings of the system libraries cairo, pango, pangocairo, gdk-pixbuf, gobject and glib, loaded with
/// dlopen on first use (LoadGraphicsLibraries): programs that never draw with FMX's cairo canvas do not need
/// them.</summary>
unit FMXWayland.CairoApi;

interface

const
  CAIRO_FORMAT_ARGB32 = 0;

  CAIRO_OPERATOR_SOURCE = 1;

  CAIRO_ANTIALIAS_DEFAULT = 0;
  CAIRO_ANTIALIAS_FAST = 4;
  CAIRO_ANTIALIAS_BEST = 6;

  CAIRO_FILL_RULE_WINDING = 0;
  CAIRO_FILL_RULE_EVEN_ODD = 1;

  CAIRO_EXTEND_REPEAT = 1;
  CAIRO_EXTEND_PAD = 3;

  CAIRO_FILTER_NEAREST = 3;
  CAIRO_FILTER_BILINEAR = 4;

  CAIRO_PATH_MOVE_TO = 0;
  CAIRO_PATH_LINE_TO = 1;
  CAIRO_PATH_CURVE_TO = 2;
  CAIRO_PATH_CLOSE_PATH = 3;

  PANGO_SCALE = 1024;

  PANGO_STYLE_OBLIQUE = 1;
  PANGO_STYLE_ITALIC = 2;

  PANGO_ALIGN_LEFT = 0;
  PANGO_ALIGN_CENTER = 1;
  PANGO_ALIGN_RIGHT = 2;

  PANGO_WRAP_WORD_CHAR = 2;

  PANGO_ELLIPSIZE_END = 3;

  PANGO_UNDERLINE_SINGLE = 1;

  GDK_COLORSPACE_RGB = 0;

type
  /// <summary>cairo_matrix_t.</summary>
  TCairoMatrix = record
    XX, YX, XY, YY, X0, Y0: Double;
  end;
  PCairoMatrix = ^TCairoMatrix;

  /// <summary>cairo_path_data_t: a header (Kind = CAIRO_PATH_*, Length = elements including the header) followed
  /// by its points.</summary>
  TCairoPathData = record
    case Integer of
      0: (Kind, Length: Integer);
      1: (X, Y: Double);
  end;
  PCairoPathData = ^TCairoPathData;

  /// <summary>cairo_path_t.</summary>
  TCairoPath = record
    Status: Integer;
    Data: PCairoPathData;
    Count: Integer;
  end;
  PCairoPath = ^TCairoPath;

  /// <summary>PangoRectangle (Pango units: PANGO_SCALE per pixel).</summary>
  TPangoRectangle = record
    X, Y, Width, Height: Integer;
  end;
  PPangoRectangle = ^TPangoRectangle;

/// <summary>Loads the libraries and their functions (once; thread-safe). Raises an exception that names what is
/// missing.</summary>
procedure LoadGraphicsLibraries;

var
  cairo_image_surface_create: function(Format, Width, Height: Integer): Pointer; cdecl;
  cairo_image_surface_create_for_data: function(Data: Pointer; Format, Width, Height, Stride: Integer): Pointer;
    cdecl;
  cairo_surface_destroy: procedure(Surface: Pointer); cdecl;
  cairo_surface_flush: procedure(Surface: Pointer); cdecl;
  cairo_surface_status: function(Surface: Pointer): Integer; cdecl;
  cairo_create: function(Surface: Pointer): Pointer; cdecl;
  cairo_destroy: procedure(Cr: Pointer); cdecl;
  cairo_status: function(Cr: Pointer): Integer; cdecl;
  cairo_status_to_string: function(Status: Integer): PAnsiChar; cdecl;
  cairo_save: procedure(Cr: Pointer); cdecl;
  cairo_restore: procedure(Cr: Pointer); cdecl;
  cairo_set_matrix: procedure(Cr: Pointer; Matrix: PCairoMatrix); cdecl;
  cairo_get_matrix: procedure(Cr: Pointer; Matrix: PCairoMatrix); cdecl;
  cairo_scale: procedure(Cr: Pointer; X, Y: Double); cdecl;
  cairo_translate: procedure(Cr: Pointer; X, Y: Double); cdecl;
  cairo_set_source_rgba: procedure(Cr: Pointer; R, G, B, A: Double); cdecl;
  cairo_set_source: procedure(Cr, Pattern: Pointer); cdecl;
  cairo_get_source: function(Cr: Pointer): Pointer; cdecl;
  cairo_set_source_surface: procedure(Cr, Surface: Pointer; X, Y: Double); cdecl;
  cairo_set_operator: procedure(Cr: Pointer; Op: Integer); cdecl;
  cairo_set_antialias: procedure(Cr: Pointer; AA: Integer); cdecl;
  cairo_new_path: procedure(Cr: Pointer); cdecl;
  cairo_move_to: procedure(Cr: Pointer; X, Y: Double); cdecl;
  cairo_line_to: procedure(Cr: Pointer; X, Y: Double); cdecl;
  cairo_curve_to: procedure(Cr: Pointer; X1, Y1, X2, Y2, X3, Y3: Double); cdecl;
  cairo_close_path: procedure(Cr: Pointer); cdecl;
  cairo_rectangle: procedure(Cr: Pointer; X, Y, W, H: Double); cdecl;
  cairo_arc: procedure(Cr: Pointer; X, Y, Radius, A1, A2: Double); cdecl;
  cairo_fill: procedure(Cr: Pointer); cdecl;
  cairo_stroke: procedure(Cr: Pointer); cdecl;
  cairo_clip: procedure(Cr: Pointer); cdecl;
  cairo_clip_extents: procedure(Cr: Pointer; X1, Y1, X2, Y2: PDouble); cdecl;
  cairo_set_fill_rule: procedure(Cr: Pointer; Rule: Integer); cdecl;
  cairo_in_fill: function(Cr: Pointer; X, Y: Double): Integer; cdecl;
  cairo_paint: procedure(Cr: Pointer); cdecl;
  cairo_paint_with_alpha: procedure(Cr: Pointer; Alpha: Double); cdecl;
  cairo_push_group: procedure(Cr: Pointer); cdecl;
  cairo_pop_group_to_source: procedure(Cr: Pointer); cdecl;
  cairo_set_line_width: procedure(Cr: Pointer; Width: Double); cdecl;
  cairo_get_line_width: function(Cr: Pointer): Double; cdecl;
  cairo_set_line_cap: procedure(Cr: Pointer; Cap: Integer); cdecl;
  cairo_set_line_join: procedure(Cr: Pointer; Join: Integer); cdecl;
  cairo_set_dash: procedure(Cr: Pointer; Dashes: PDouble; Count: Integer; Offset: Double); cdecl;
  cairo_pattern_create_linear: function(X1, Y1, X2, Y2: Double): Pointer; cdecl;
  cairo_pattern_create_radial: function(X1, Y1, R1, X2, Y2, R2: Double): Pointer; cdecl;
  cairo_pattern_create_for_surface: function(Surface: Pointer): Pointer; cdecl;
  cairo_pattern_add_color_stop_rgba: procedure(Pattern: Pointer; Offset, R, G, B, A: Double); cdecl;
  cairo_pattern_set_extend: procedure(Pattern: Pointer; Extend: Integer); cdecl;
  cairo_pattern_set_filter: procedure(Pattern: Pointer; Filter: Integer); cdecl;
  cairo_pattern_set_matrix: procedure(Pattern: Pointer; Matrix: PCairoMatrix); cdecl;
  cairo_pattern_destroy: procedure(Pattern: Pointer); cdecl;
  cairo_copy_path: function(Cr: Pointer): PCairoPath; cdecl;
  cairo_path_destroy: procedure(Path: PCairoPath); cdecl;
  pango_font_description_new: function(): Pointer; cdecl;
  pango_font_description_free: procedure(Desc: Pointer); cdecl;
  pango_font_description_set_family: procedure(Desc: Pointer; Family: PAnsiChar); cdecl;
  pango_font_description_set_absolute_size: procedure(Desc: Pointer; Size: Double); cdecl;
  pango_font_description_set_weight: procedure(Desc: Pointer; Weight: Integer); cdecl;
  pango_font_description_set_style: procedure(Desc: Pointer; Style: Integer); cdecl;
  pango_layout_set_font_description: procedure(Layout, Desc: Pointer); cdecl;
  pango_layout_set_text: procedure(Layout: Pointer; Text: PAnsiChar; Length: Integer); cdecl;
  pango_layout_set_width: procedure(Layout: Pointer; Width: Integer); cdecl;
  pango_layout_set_height: procedure(Layout: Pointer; Height: Integer); cdecl;
  pango_layout_set_wrap: procedure(Layout: Pointer; Wrap: Integer); cdecl;
  pango_layout_set_alignment: procedure(Layout: Pointer; Align: Integer); cdecl;
  pango_layout_set_ellipsize: procedure(Layout: Pointer; Ellipsize: Integer); cdecl;
  pango_layout_get_extents: procedure(Layout: Pointer; Ink, Logical: PPangoRectangle); cdecl;
  pango_layout_index_to_pos: procedure(Layout: Pointer; Index: Integer; Position: PPangoRectangle); cdecl;
  pango_layout_xy_to_index: function(Layout: Pointer; X, Y: Integer; Index, Trailing: PInteger): Integer; cdecl;
  pango_attr_list_new: function(): Pointer; cdecl;
  pango_attr_list_unref: procedure(Attrs: Pointer); cdecl;
  pango_attr_underline_new: function(Underline: Integer): Pointer; cdecl;
  pango_attr_strikethrough_new: function(Strike: Integer): Pointer; cdecl;
  pango_attr_list_insert: procedure(Attrs, Attr: Pointer); cdecl;
  pango_layout_set_attributes: procedure(Layout, Attrs: Pointer); cdecl;
  pango_font_map_list_families: procedure(FontMap: Pointer; Families: PPointer; Count: PInteger); cdecl;
  pango_font_family_get_name: function(Family: Pointer): PAnsiChar; cdecl;
  pango_cairo_create_layout: function(Cr: Pointer): Pointer; cdecl;
  pango_cairo_show_layout: procedure(Cr, Layout: Pointer); cdecl;
  pango_cairo_layout_path: procedure(Cr, Layout: Pointer); cdecl;
  pango_cairo_font_map_get_default: function(): Pointer; cdecl;
  gdk_pixbuf_loader_new: function(): Pointer; cdecl;
  gdk_pixbuf_loader_write: function(Loader, Buffer: Pointer; Count: NativeUInt; Error: PPointer): Integer; cdecl;
  gdk_pixbuf_loader_close: function(Loader: Pointer; Error: PPointer): Integer; cdecl;
  gdk_pixbuf_loader_get_pixbuf: function(Loader: Pointer): Pointer; cdecl;
  gdk_pixbuf_get_width: function(Pixbuf: Pointer): Integer; cdecl;
  gdk_pixbuf_get_height: function(Pixbuf: Pointer): Integer; cdecl;
  gdk_pixbuf_get_rowstride: function(Pixbuf: Pointer): Integer; cdecl;
  gdk_pixbuf_get_n_channels: function(Pixbuf: Pointer): Integer; cdecl;
  gdk_pixbuf_get_pixels: function(Pixbuf: Pointer): PByte; cdecl;
  gdk_pixbuf_new: function(Colorspace, HasAlpha, BitsPerSample, Width, Height: Integer): Pointer; cdecl;
  gdk_pixbuf_save_to_bufferv: function(Pixbuf: Pointer; Buffer: PPointer; Size: PNativeUInt; Format: PAnsiChar;
    Keys, Values: Pointer; Error: PPointer): Integer; cdecl;
  g_object_unref: procedure(Obj: Pointer); cdecl;
  g_free: procedure(Data: Pointer); cdecl;
  g_error_free: procedure(Error: Pointer); cdecl;

implementation

uses
  System.SysUtils, System.SyncObjs, Posix.Dlfcn;

var
  GLock: TCriticalSection;
  GLoaded: Boolean = False;
  H_cairo: NativeUInt = 0;
  H_pango: NativeUInt = 0;
  H_pangocairo: NativeUInt = 0;
  H_pixbuf: NativeUInt = 0;
  H_gobject: NativeUInt = 0;
  H_glib: NativeUInt = 0;

procedure LoadGraphicsLibraries;

  procedure OpenLibrary(var Handle: NativeUInt; const Name: UTF8String);
  begin
    if Handle = 0 then
      Handle := dlopen(PAnsiChar(Name), RTLD_NOW);
    if Handle = 0 then
      raise Exception.Create('FMXWayland: cannot load ' + string(Name) + ': ' + string(UTF8String(dlerror)));
  end;

  function Sym(Handle: NativeUInt; const Name: UTF8String): Pointer;
  begin
    Result := dlsym(Handle, PAnsiChar(Name));
    if Result = nil then
      raise Exception.Create('FMXWayland: missing graphics function ' + string(Name));
  end;

begin
  GLock.Acquire;
  try
    if GLoaded then
      Exit;
    OpenLibrary(H_cairo, 'libcairo.so.2');
    cairo_image_surface_create := Sym(H_cairo, 'cairo_image_surface_create');
    cairo_image_surface_create_for_data := Sym(H_cairo, 'cairo_image_surface_create_for_data');
    cairo_surface_destroy := Sym(H_cairo, 'cairo_surface_destroy');
    cairo_surface_flush := Sym(H_cairo, 'cairo_surface_flush');
    cairo_surface_status := Sym(H_cairo, 'cairo_surface_status');
    cairo_create := Sym(H_cairo, 'cairo_create');
    cairo_destroy := Sym(H_cairo, 'cairo_destroy');
    cairo_status := Sym(H_cairo, 'cairo_status');
    cairo_status_to_string := Sym(H_cairo, 'cairo_status_to_string');
    cairo_save := Sym(H_cairo, 'cairo_save');
    cairo_restore := Sym(H_cairo, 'cairo_restore');
    cairo_set_matrix := Sym(H_cairo, 'cairo_set_matrix');
    cairo_get_matrix := Sym(H_cairo, 'cairo_get_matrix');
    cairo_scale := Sym(H_cairo, 'cairo_scale');
    cairo_translate := Sym(H_cairo, 'cairo_translate');
    cairo_set_source_rgba := Sym(H_cairo, 'cairo_set_source_rgba');
    cairo_set_source := Sym(H_cairo, 'cairo_set_source');
    cairo_get_source := Sym(H_cairo, 'cairo_get_source');
    cairo_set_source_surface := Sym(H_cairo, 'cairo_set_source_surface');
    cairo_set_operator := Sym(H_cairo, 'cairo_set_operator');
    cairo_set_antialias := Sym(H_cairo, 'cairo_set_antialias');
    cairo_new_path := Sym(H_cairo, 'cairo_new_path');
    cairo_move_to := Sym(H_cairo, 'cairo_move_to');
    cairo_line_to := Sym(H_cairo, 'cairo_line_to');
    cairo_curve_to := Sym(H_cairo, 'cairo_curve_to');
    cairo_close_path := Sym(H_cairo, 'cairo_close_path');
    cairo_rectangle := Sym(H_cairo, 'cairo_rectangle');
    cairo_arc := Sym(H_cairo, 'cairo_arc');
    cairo_fill := Sym(H_cairo, 'cairo_fill');
    cairo_stroke := Sym(H_cairo, 'cairo_stroke');
    cairo_clip := Sym(H_cairo, 'cairo_clip');
    cairo_clip_extents := Sym(H_cairo, 'cairo_clip_extents');
    cairo_set_fill_rule := Sym(H_cairo, 'cairo_set_fill_rule');
    cairo_in_fill := Sym(H_cairo, 'cairo_in_fill');
    cairo_paint := Sym(H_cairo, 'cairo_paint');
    cairo_paint_with_alpha := Sym(H_cairo, 'cairo_paint_with_alpha');
    cairo_push_group := Sym(H_cairo, 'cairo_push_group');
    cairo_pop_group_to_source := Sym(H_cairo, 'cairo_pop_group_to_source');
    cairo_set_line_width := Sym(H_cairo, 'cairo_set_line_width');
    cairo_get_line_width := Sym(H_cairo, 'cairo_get_line_width');
    cairo_set_line_cap := Sym(H_cairo, 'cairo_set_line_cap');
    cairo_set_line_join := Sym(H_cairo, 'cairo_set_line_join');
    cairo_set_dash := Sym(H_cairo, 'cairo_set_dash');
    cairo_pattern_create_linear := Sym(H_cairo, 'cairo_pattern_create_linear');
    cairo_pattern_create_radial := Sym(H_cairo, 'cairo_pattern_create_radial');
    cairo_pattern_create_for_surface := Sym(H_cairo, 'cairo_pattern_create_for_surface');
    cairo_pattern_add_color_stop_rgba := Sym(H_cairo, 'cairo_pattern_add_color_stop_rgba');
    cairo_pattern_set_extend := Sym(H_cairo, 'cairo_pattern_set_extend');
    cairo_pattern_set_filter := Sym(H_cairo, 'cairo_pattern_set_filter');
    cairo_pattern_set_matrix := Sym(H_cairo, 'cairo_pattern_set_matrix');
    cairo_pattern_destroy := Sym(H_cairo, 'cairo_pattern_destroy');
    cairo_copy_path := Sym(H_cairo, 'cairo_copy_path');
    cairo_path_destroy := Sym(H_cairo, 'cairo_path_destroy');
    OpenLibrary(H_pango, 'libpango-1.0.so.0');
    pango_font_description_new := Sym(H_pango, 'pango_font_description_new');
    pango_font_description_free := Sym(H_pango, 'pango_font_description_free');
    pango_font_description_set_family := Sym(H_pango, 'pango_font_description_set_family');
    pango_font_description_set_absolute_size := Sym(H_pango, 'pango_font_description_set_absolute_size');
    pango_font_description_set_weight := Sym(H_pango, 'pango_font_description_set_weight');
    pango_font_description_set_style := Sym(H_pango, 'pango_font_description_set_style');
    pango_layout_set_font_description := Sym(H_pango, 'pango_layout_set_font_description');
    pango_layout_set_text := Sym(H_pango, 'pango_layout_set_text');
    pango_layout_set_width := Sym(H_pango, 'pango_layout_set_width');
    pango_layout_set_height := Sym(H_pango, 'pango_layout_set_height');
    pango_layout_set_wrap := Sym(H_pango, 'pango_layout_set_wrap');
    pango_layout_set_alignment := Sym(H_pango, 'pango_layout_set_alignment');
    pango_layout_set_ellipsize := Sym(H_pango, 'pango_layout_set_ellipsize');
    pango_layout_get_extents := Sym(H_pango, 'pango_layout_get_extents');
    pango_layout_index_to_pos := Sym(H_pango, 'pango_layout_index_to_pos');
    pango_layout_xy_to_index := Sym(H_pango, 'pango_layout_xy_to_index');
    pango_attr_list_new := Sym(H_pango, 'pango_attr_list_new');
    pango_attr_list_unref := Sym(H_pango, 'pango_attr_list_unref');
    pango_attr_underline_new := Sym(H_pango, 'pango_attr_underline_new');
    pango_attr_strikethrough_new := Sym(H_pango, 'pango_attr_strikethrough_new');
    pango_attr_list_insert := Sym(H_pango, 'pango_attr_list_insert');
    pango_layout_set_attributes := Sym(H_pango, 'pango_layout_set_attributes');
    pango_font_map_list_families := Sym(H_pango, 'pango_font_map_list_families');
    pango_font_family_get_name := Sym(H_pango, 'pango_font_family_get_name');
    OpenLibrary(H_pangocairo, 'libpangocairo-1.0.so.0');
    pango_cairo_create_layout := Sym(H_pangocairo, 'pango_cairo_create_layout');
    pango_cairo_show_layout := Sym(H_pangocairo, 'pango_cairo_show_layout');
    pango_cairo_layout_path := Sym(H_pangocairo, 'pango_cairo_layout_path');
    pango_cairo_font_map_get_default := Sym(H_pangocairo, 'pango_cairo_font_map_get_default');
    OpenLibrary(H_pixbuf, 'libgdk_pixbuf-2.0.so.0');
    gdk_pixbuf_loader_new := Sym(H_pixbuf, 'gdk_pixbuf_loader_new');
    gdk_pixbuf_loader_write := Sym(H_pixbuf, 'gdk_pixbuf_loader_write');
    gdk_pixbuf_loader_close := Sym(H_pixbuf, 'gdk_pixbuf_loader_close');
    gdk_pixbuf_loader_get_pixbuf := Sym(H_pixbuf, 'gdk_pixbuf_loader_get_pixbuf');
    gdk_pixbuf_get_width := Sym(H_pixbuf, 'gdk_pixbuf_get_width');
    gdk_pixbuf_get_height := Sym(H_pixbuf, 'gdk_pixbuf_get_height');
    gdk_pixbuf_get_rowstride := Sym(H_pixbuf, 'gdk_pixbuf_get_rowstride');
    gdk_pixbuf_get_n_channels := Sym(H_pixbuf, 'gdk_pixbuf_get_n_channels');
    gdk_pixbuf_get_pixels := Sym(H_pixbuf, 'gdk_pixbuf_get_pixels');
    gdk_pixbuf_new := Sym(H_pixbuf, 'gdk_pixbuf_new');
    gdk_pixbuf_save_to_bufferv := Sym(H_pixbuf, 'gdk_pixbuf_save_to_bufferv');
    OpenLibrary(H_gobject, 'libgobject-2.0.so.0');
    g_object_unref := Sym(H_gobject, 'g_object_unref');
    OpenLibrary(H_glib, 'libglib-2.0.so.0');
    g_free := Sym(H_glib, 'g_free');
    g_error_free := Sym(H_glib, 'g_error_free');
    GLoaded := True;
  finally
    GLock.Release;
  end;
end;

initialization
  GLock := TCriticalSection.Create;

finalization
  GLock.Free;
  // Handles live until process exit: FMX finalization can still destroy canvases and text layouts.
end.
