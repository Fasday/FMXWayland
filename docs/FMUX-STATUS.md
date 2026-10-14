# FMUX functions: status in FMXWayland

All 186 function pointers of `FMUX.Api` (RAD Studio 37.0). *implemented*: does what libfmux did;
*partial*: assigned, but only part of it is done (the note says what); *stub*: the generated stub (logs once,
returns zero/nil/False).

Generated with `.\tools\gen-fmux-api.ps1 -StatusFile docs\FMUX-STATUS.md` (the notes come from the
`// partial:` comments in `src\FMXWayland.Fmux.pas`); a stub that FMX calls logs `<name> is not implemented`
once at run time.

| Function | FMXWayland |
|---|---|
| FmuxInit | implemented |
| FmuxRun | implemented |
| FmuxTerminate | implemented |
| FmuxHandleMessage | implemented |
| FmuxWakeMainThread | implemented |
| FmuxCreateWindow | implemented |
| FmuxDestroyWindow | implemented |
| FmuxSetMainWindow | implemented |
| FmuxSetWindowState | implemented |
| FmuxSetWindowTitle | implemented |
| FmuxSetWindowIcon | partial: ignored (no xdg-toplevel-icon yet) |
| FmuxShowWindow | implemented |
| FmuxActivateWindow | partial: no-op (needs an xdg-activation token) |
| FmuxWindowBringToFront | partial: no-op on Wayland |
| FmuxWindowSendToBack | partial: no-op on Wayland |
| FmuxGetClientSize | implemented |
| FmuxSetClientSize | implemented |
| FmuxGetWindowRect | implemented |
| FmuxSetWindowRect | partial: the position of toplevels is virtual |
| FmuxInvalidateRect | implemented |
| FmuxProcessUpdates | implemented |
| FmuxClientToScreen | implemented |
| FmuxScreenToClient | implemented |
| FmuxGetScreenSize | implemented |
| FmuxGetScreenScale | implemented |
| FmuxGetWindowScale | implemented |
| FmuxGetWindowFullScreen | implemented |
| FmuxSetWindowFullScreen | implemented |
| FmuxSetCapture | partial: Wayland's implicit grab |
| FmuxReleaseCapture | partial: Wayland's implicit grab |
| FmuxGetWindowNativeHandle | partial: returns the wl_surface |
| FmuxGetWindowNativeDrawingHandle | partial: returns the wl_surface |
| FmuxAddTooltip | partial: no-op (no native tooltips) |
| FmuxRemoveTooltip | partial: no-op |
| FmuxAddGestureRecognizer | partial: no-op (no touch gestures yet) |
| FmuxRemoveGestureRecognizer | partial: no-op |
| FmuxShowModal | implemented |
| FmuxGetKeyState | implemented |
| FmuxCreateTimer | implemented |
| FmuxDestroyTimer | implemented |
| FmuxSetClipRects | stub |
| FmuxIntersectClipRect | stub |
| FmuxExcludeClipRect | stub |
| FmuxSave | stub |
| FmuxRestore | stub |
| FmuxCanvasSetQuality | stub |
| FmuxCanvasClear | stub |
| FmuxCanvasClearRect | stub |
| FmuxCanvasSetMatrix | stub |
| FmuxCanvasSetFillColor | stub |
| FmuxCanvasSetFillGradient | stub |
| FmuxCanvasSetFillRadialGradient | stub |
| FmuxCanvasSetFillBitmap | stub |
| FmuxCanvasEllipse | stub |
| FmuxCanvasRect | stub |
| FmuxCanvasLine | stub |
| FmuxCanvasPath | stub |
| FmuxCanvasFill | stub |
| FmuxCanvasPtInPath | stub |
| FmuxCanvasStroke | stub |
| FmuxCanvasSetStrokeWidth | stub |
| FmuxCanvasSetStrokeCap | stub |
| FmuxCanvasSetStrokeJoin | stub |
| FmuxCanvasSetStrokeDash | stub |
| FmuxBitmapCreate | implemented |
| FmuxBitmapDestroy | implemented |
| FmuxGetBitmapInfo | implemented |
| FmuxCanvasDrawBitmap | implemented |
| FmuxCreateContext | stub |
| FmuxDestroyContext | stub |
| FmuxBitmapLoad | stub |
| FmuxBitmapSave | stub |
| FmuxCreateTextLayout | stub |
| FmuxDestroyTextLayout | stub |
| FmuxDrawTextLayout | stub |
| FmuxGetTextLayoutRect | stub |
| FmuxLayoutPositionAtPoint | stub |
| FmuxLayoutMeasureRange | stub |
| FmuxLayoutToPath | stub |
| FmuxAddCustomFont | stub |
| FmuxAddCustomFontFromData | stub |
| FmuxGetFontCount | stub |
| FmuxGetFontName | stub |
| FmuxSetLog | partial: FMXWayland logs to stderr itself (FMXWAYLAND_LOG) |
| FmuxCreateSharedContext | stub |
| FmuxCreateThreadContext | stub |
| FmuxMakeCurrentContext | stub |
| FmuxFlushBuffer | stub |
| FmuxCreateMainMenu | stub |
| FmuxCreateMenu | stub |
| FmuxCreateMenuItem | stub |
| FmuxMenuAddItem | stub |
| FmuxSetSubmenu | stub |
| FmuxUpdateMenuItem | stub |
| FmuxMessageDialog | partial: FMX's own dialog form, not a native one |
| FmuxInputQuery | stub |
| FmuxFilesDialog | stub |
| FmuxClipboardHasText | implemented |
| FmuxClipboardGetText | implemented |
| FmuxClipboardSetText | implemented |
| FmuxClipboardHasImage | partial: no images yet (always False) |
| FmuxClipboardGetImage | partial: no images yet |
| FmuxClipboardSetImage | stub |
| FmuxClipboardHasCustom | partial: no custom formats yet (always False) |
| FmuxClipboardGetCustom | partial: no custom formats yet |
| FmuxClipboardSetCustom | stub |
| FmuxClipboardSetArray | stub |
| FmuxEnumPrinters | stub |
| FmuxIsDefaultPrinter | stub |
| FmuxGetPageSettings | stub |
| FmuxPrintDialog | stub |
| FmuxPageSetupDefault | stub |
| FmuxPageSetupDialog | stub |
| FmuxPrinterRun | stub |
| FmuxGetOrientation | stub |
| FmuxSetOrientation | stub |
| FmuxCreatePDFContext | stub |
| FmuxDestroyPDFContext | stub |
| FmuxPDFContextNewPage | stub |
| FmuxBeginDoc | stub |
| FmuxAbortDoc | stub |
| FmuxEndDoc | stub |
| FmuxBeginPage | stub |
| FmuxEnumPaperSizes | stub |
| FmuxAddCustomPaperSize | stub |
| FmuxSelectFormatByPaperSize | stub |
| FmuxSetAlwaysAskOutputFile | stub |
| FmuxSetCursor | implemented |
| FmuxImeEnterControl | partial: no-op (text-input-v3 not used yet) |
| FmuxImeExitControl | partial: no-op |
| FmuxImeSetCaretPos | partial: no-op |
| FmuxGetDisplayInfo | partial: work area = whole output |
| FmuxGetDisplayFromWindow | implemented |
| FmuxGetDisplayFromPoint | implemented |
| FmuxTakeScreenshot | stub |
| FmuxIsWebViewInstalled | stub |
| FmuxCreateWebView | stub |
| FmuxWebViewShow | stub |
| FmuxWebViewSetBounds | stub |
| FmuxWebViewNavigate | stub |
| FmuxWebViewLoadText | stub |
| FmuxWebViewCanGoBack | stub |
| FmuxWebViewGoBack | stub |
| FmuxWebViewCanGoForward | stub |
| FmuxWebViewGoForward | stub |
| FmuxWebViewReload | stub |
| FmuxEvaluateJavaScript | stub |
| FmuxWebViewGetUrl | stub |
| FmuxWebViewStop | stub |
| FmuxDestroyWebView | stub |
| FmuxOpenFile | stub |
| FmuxOpenUrl | stub |
| FmuxGetFileIcon | stub |
| FmuxGetFileType | stub |
| FmuxMediaInstalled | stub |
| FmuxCreateMedia | stub |
| FmuxDestroyMedia | stub |
| FmuxMediaPlay | stub |
| FmuxMediaStop | stub |
| FmuxMediaGetDuration | stub |
| FmuxMediaGetCurrent | stub |
| FmuxMediaSetCurrent | stub |
| FmuxMediaSetVisible | stub |
| FmuxMediaSetBounds | stub |
| FmuxMediaGetVideoSize | stub |
| FmuxMediaGetVolume | stub |
| FmuxMediaSetVolume | stub |
| FmuxMediaGetState | stub |
| FmuxBeginDragDrop | stub |
| FmuxCaptureDeviceEnum | stub |
| FmuxStartVideoCapture | stub |
| FmuxStopVideoCapture | stub |
| FmuxGetMousePos | partial: last position over an own window |
| FmuxGetDefaultCursor | stub |
| FmuxGetCursor | stub |
| FmuxGetCursorBitmap | stub |
| FmuxGenMouseMove | stub |
| FmuxGenMouseDown | stub |
| FmuxGenMouseUp | stub |
| FmuxGenMouseWheel | stub |
| FmuxGenKeyDown | stub |
| FmuxGenKeyUp | stub |
| FmuxGetVersionInfo | implemented |
| FmuxSetVersionInfo | implemented |
| IsWayland | implemented |
| IsBroadway | implemented |
