#!/usr/bin/env python3
"""Check the actual popup drawable alpha, or its binary Shape fallback without a compositor."""
import ctypes as c
import sys
import time

x = c.CDLL('libX11.so.6')
x.XOpenDisplay.argtypes = [c.c_char_p]
x.XOpenDisplay.restype = c.c_void_p
x.XCloseDisplay.argtypes = [c.c_void_p]
x.XDefaultScreen.argtypes = [c.c_void_p]
x.XInternAtom.argtypes = [c.c_void_p, c.c_char_p, c.c_int]
x.XInternAtom.restype = c.c_ulong
x.XGetSelectionOwner.argtypes = [c.c_void_p, c.c_ulong]
x.XGetSelectionOwner.restype = c.c_ulong
x.XGetGeometry.argtypes = [c.c_void_p, c.c_ulong, c.POINTER(c.c_ulong), c.POINTER(c.c_int),
                          c.POINTER(c.c_int), c.POINTER(c.c_uint), c.POINTER(c.c_uint),
                          c.POINTER(c.c_uint), c.POINTER(c.c_uint)]
x.XGetImage.argtypes = [c.c_void_p, c.c_ulong, c.c_int, c.c_int, c.c_uint, c.c_uint, c.c_ulong, c.c_int]
x.XGetImage.restype = c.c_void_p
x.XGetPixel.argtypes = [c.c_void_p, c.c_int, c.c_int]
x.XGetPixel.restype = c.c_ulong
x.XDestroyImage.argtypes = [c.c_void_p]
x.XFree.argtypes = [c.c_void_p]


class Rectangle(c.Structure):
    _fields_ = [('x', c.c_short), ('y', c.c_short), ('width', c.c_ushort), ('height', c.c_ushort)]


d = x.XOpenDisplay(None)
assert d, 'Cannot open DISPLAY'
try:
    window = int(sys.argv[1], 0)
    root = c.c_ulong()
    left, top = c.c_int(), c.c_int()
    width, height, border, depth = c.c_uint(), c.c_uint(), c.c_uint(), c.c_uint()
    assert x.XGetGeometry(d, window, c.byref(root), c.byref(left), c.byref(top), c.byref(width),
                          c.byref(height), c.byref(border), c.byref(depth)), 'Cannot query popup geometry'
    atom = x.XInternAtom(d, f'_NET_WM_CM_S{x.XDefaultScreen(d)}'.encode(), 1)
    composited = bool(atom and x.XGetSelectionOwner(d, atom))
    if composited:
        assert depth.value == 32, f'Composited popup uses opaque depth {depth.value}'
        deadline = time.monotonic() + 2
        while True:
            image = x.XGetImage(d, window, 0, 0, width.value, height.value, c.c_ulong(-1).value, 2)
            assert image, 'Cannot read popup pixels'
            try:
                corner = x.XGetPixel(image, 0, 0)
                content = x.XGetPixel(image, 12, 12)
            finally:
                x.XDestroyImage(image)
            assert corner >> 24 == 0, f'Popup padding is not transparent: {corner:#x}'
            if content >> 24 == 255:
                break
            assert time.monotonic() < deadline, f'Popup content is not opaque: {content:#x}'
            time.sleep(.05)  # wait for FMX's popup fade-in / first Skia frame
        print('Composited popup: ARGB32, transparent padding, opaque content: PASS')
    else:
        shape = c.CDLL('libXext.so.6')
        shape.XShapeGetRectangles.argtypes = [c.c_void_p, c.c_ulong, c.c_int,
                                             c.POINTER(c.c_int), c.POINTER(c.c_int)]
        shape.XShapeGetRectangles.restype = c.POINTER(Rectangle)
        count, ordering = c.c_int(), c.c_int()
        deadline = time.monotonic() + 2
        while True:
            rects = shape.XShapeGetRectangles(d, window, 0, c.byref(count), c.byref(ordering))
            try:
                def contains(px, py):
                    return bool(rects) and any(r.x <= px < r.x + r.width and r.y <= py < r.y + r.height
                                              for r in rects[:count.value])
                assert not contains(0, 0), 'Non-composited popup still has opaque padding'
                if contains(12, 12):
                    break
            finally:
                if rects:
                    x.XFree(rects)
            assert time.monotonic() < deadline, 'Non-composited popup content is clipped'
            time.sleep(.05)
        print('Non-composited popup: transparent padding removed by Shape: PASS')
finally:
    x.XCloseDisplay(d)
