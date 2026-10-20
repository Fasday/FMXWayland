#!/usr/bin/env python3
"""Move over a blank part of Hello and check that the visible cursor is not recreated per motion."""
import ctypes as c
import sys
import time

x = c.CDLL('libX11.so.6')
fixes = c.CDLL('libXfixes.so.3')
x.XOpenDisplay.argtypes = [c.c_char_p]
x.XOpenDisplay.restype = c.c_void_p
x.XCloseDisplay.argtypes = [c.c_void_p]
x.XWarpPointer.argtypes = [c.c_void_p, c.c_ulong, c.c_ulong, c.c_int, c.c_int,
                          c.c_uint, c.c_uint, c.c_int, c.c_int]
x.XSync.argtypes = [c.c_void_p, c.c_int]
x.XFree.argtypes = [c.c_void_p]


class CursorImage(c.Structure):
    _fields_ = [('x', c.c_short), ('y', c.c_short), ('width', c.c_ushort),
                ('height', c.c_ushort), ('xhot', c.c_ushort), ('yhot', c.c_ushort),
                ('serial', c.c_ulong), ('pixels', c.POINTER(c.c_ulong))]


fixes.XFixesGetCursorImage.argtypes = [c.c_void_p]
fixes.XFixesGetCursorImage.restype = c.POINTER(CursorImage)
d = x.XOpenDisplay(None)
assert d, 'Cannot open DISPLAY'
try:
    window = int(sys.argv[1], 0)
    serials = set()
    for i in range(25):
        x.XWarpPointer(d, 0, window, 0, 0, 0, 0, 480 + i * 6, 180)
        x.XSync(d, 0)
        time.sleep(.05)
        image = fixes.XFixesGetCursorImage(d)
        assert image, 'Cannot read cursor image'
        try:
            cursor = image.contents
            assert any(cursor.pixels[j] >> 24 for j in range(cursor.width * cursor.height)), 'Invisible cursor'
            if i > 0:
                serials.add(cursor.serial)
        finally:
            x.XFree(image)
    assert len(serials) == 1, f'Cursor recreated during motion: {len(serials)} different cursor serials'
    print('Cursor visibility and stable identity during motion: PASS')
finally:
    x.XCloseDisplay(d)
