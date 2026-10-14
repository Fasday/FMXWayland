#!/usr/bin/env python3
"""Test helper of tests/compositors.sh: drives a compositor from outside as a user and another application would.

  input       KWin: org_kde_kwin_fake_input; wlroots (sway): zwlr_virtual_pointer_v1 + zwp_virtual_keyboard_v1;
              GNOME Shell: Clutter virtual input devices through org.gnome.Shell.Eval
  clipboard   another client's: ext_data_control_v1 or zwlr_data_control_v1; GNOME Shell: St.Clipboard (Eval)
  windows     where they are, which has the focus, closing, maximizing: swaymsg; KWin scripts (D-Bus);
              GNOME Shell: Eval
  screenshots grim (sway, and the sway that hosts a nested KWin); GNOME Shell: org.gnome.Shell.Screenshot

The Wayland client speaks the wire protocol over the socket (no libraries). It runs as a server, so its input devices
and its clipboard source stay; commands come one per line through a FIFO, each answered through another FIFO with
"ok [result]" or "error <message>":

  wltool.py serve <sway|kwin|gnome> <command-fifo> <answer-fifo>

Environment: WAYLAND_DISPLAY (the compositor under test), HOST_WAYLAND_DISPLAY (the sway whose output grim captures:
the compositor itself, or the one hosting a nested KWin), SWAYSOCK, KWIN_LOG (KWin's stderr: script output), LAYOUT
("<w> <h>": the logical size of the output, for absolute pointer motion on wlroots).

Commands (coordinates in logical pixels of the layout):
  move X Y | down [left|right|middle] | up [..] | click [..] | wheel N (notches, + = towards the user)
  key NAME[+NAME...] (ctrl+a, backspace, home, alt+f4, ...) | type TEXT (US layout: a-z A-Z 0-9 space .,-/=)
  copy TEXT | paste                     the clipboard as another application
  geometry TITLE                        "x y w h" of the window's geometry (with client-side decorations if any)
  focus                                 title of the focused window
  parent TITLE                          title of the window TITLE is transient for ('' if none)
  windows                               the titles of all windows, separated by '|'
  close TITLE | maximize TITLE | restore TITLE
  shot FILE                             a PNG of the output
  settle                                waits until the shell takes no input itself (GNOME: overview, modal grabs)
  caps | quit
"""
import array
import ctypes
import json
import os
import select
import socket
import struct
import subprocess
import sys
import time

BUTTONS = {'left': 0x110, 'right': 0x111, 'middle': 0x112}
KEYS = {
    'esc': 1, 'escape': 1, 'minus': 12, 'equal': 13, 'backspace': 14, 'tab': 15, 'return': 28, 'enter': 28,
    'ctrl': 29, 'shift': 42, 'alt': 56, 'space': 57, 'f4': 62, 'home': 102, 'up': 103, 'pageup': 104, 'left': 105,
    'right': 106, 'end': 107, 'down': 108, 'pagedown': 109, 'insert': 110, 'delete': 111, 'super': 125,
    'comma': 51, 'period': 52, 'slash': 53,
}
for _i, _c in enumerate('1234567890'):
    KEYS[_c] = 2 + _i
for _row, _start in (('qwertyuiop', 16), ('asdfghjkl', 30), ('zxcvbnm', 44)):
    for _i, _c in enumerate(_row):
        KEYS[_c] = _start + _i
CHARS = {' ': 'space', '.': 'period', ',': 'comma', '-': 'minus', '/': 'slash', '=': 'equal'}
# Modifier masks of the standard keymap (Shift, Control, Mod1) for the virtual keyboard's modifiers request.
MOD_MASKS = {42: 1, 29: 4, 56: 8}
TEXT_MIMES = ('text/plain;charset=utf-8', 'UTF8_STRING', 'text/plain', 'TEXT', 'STRING')
DEBUG = os.environ.get('WLTOOL_DEBUG') == '1'


def fixed(v):
    return int(round(v * 256)) & 0xffffffff


def key_codes(names):
    return [KEYS[n.lower()] for n in names]


def text_keys(text):
    """Each character as a list of key codes pressed together (US layout)."""
    for ch in text:
        if ch.isupper():
            yield key_codes(['shift', ch.lower()])
        else:
            yield key_codes([CHARS.get(ch, ch)])


class Wayland:
    """The connection: requests out, events in, objects by id with their interface names."""

    def __init__(self, display=None):
        path = display or os.environ['WAYLAND_DISPLAY']
        if not path.startswith('/'):
            path = os.path.join(os.environ['XDG_RUNTIME_DIR'], path)
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(path)
        self.buf = b''
        self.fds = []
        self.next_id = 2
        self.objects = {1: 'wl_display'}
        self.handlers = {}
        self.globals = {}
        self.registry = self.new('wl_registry')
        self.request(1, 1, 'n', self.registry)
        self.roundtrip()

    def new(self, interface):
        oid = self.next_id
        self.next_id += 1
        self.objects[oid] = interface
        return oid

    def request(self, oid, opcode, sig, *args, fds=()):
        body = b''
        for t, a in zip(sig, args):
            if t in 'uon':
                body += struct.pack('<I', a or 0)
            elif t == 'i':
                body += struct.pack('<i', a)
            elif t == 'f':
                body += struct.pack('<I', fixed(a))
            elif t == 's':
                if a is None:
                    body += struct.pack('<I', 0)
                else:
                    s = a.encode() + b'\0'
                    body += struct.pack('<I', len(s)) + s + b'\0' * (-len(s) % 4)
            # 'h': file descriptors travel beside the message
        msg = struct.pack('<II', oid, ((8 + len(body)) << 16) | opcode) + body
        if DEBUG:
            print('request %s@%d.%d %s' % (self.objects.get(oid), oid, opcode, body.hex()), file=sys.stderr)
        if fds:
            self.sock.sendmsg([msg], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array('i', fds))])
        else:
            self.sock.sendall(msg)

    def bind(self, interface, version):
        name, ver = self.globals[interface]
        oid = self.new(interface)
        s = interface.encode() + b'\0'
        body = struct.pack('<I', name) + struct.pack('<I', len(s)) + s + b'\0' * (-len(s) % 4)
        body += struct.pack('<II', min(ver, version), oid)
        self.sock.sendall(struct.pack('<II', self.registry, ((8 + len(body)) << 16) | 0) + body)
        return oid

    def read_events(self, timeout):
        r, _, _ = select.select([self.sock], [], [], timeout)
        if not r:
            return False
        data, anc, _, _ = self.sock.recvmsg(65536, socket.CMSG_SPACE(16 * 4))
        if not data:
            raise SystemExit('the compositor closed the connection')
        for level, kind, payload in anc:
            if level == socket.SOL_SOCKET and kind == socket.SCM_RIGHTS:
                a = array.array('i')
                a.frombytes(payload[:len(payload) - len(payload) % 4])
                self.fds.extend(a)
        self.buf += data
        while len(self.buf) >= 8:
            oid, so = struct.unpack('<II', self.buf[:8])
            size, opcode = so >> 16, so & 0xffff
            if len(self.buf) < size:
                break
            body, self.buf = self.buf[8:size], self.buf[size:]
            self.dispatch(oid, opcode, body)
        return True

    def take_fd(self):
        return self.fds.pop(0)

    @staticmethod
    def string(body, pos):
        n = struct.unpack('<I', body[pos:pos + 4])[0]
        s = body[pos + 4:pos + 4 + n - 1].decode(errors='replace') if n else None
        return s, pos + 4 + n + (-n % 4)

    def dispatch(self, oid, opcode, body):
        iface = self.objects.get(oid)
        if DEBUG:
            print('event %s@%d.%d %s' % (iface, oid, opcode, body.hex()), file=sys.stderr)
        if iface == 'wl_display' and opcode == 0:
            obj, code = struct.unpack('<II', body[:8])
            msg, _ = self.string(body, 8)
            raise SystemExit('protocol error on %s@%d code %d: %s' % (self.objects.get(obj), obj, code, msg))
        if iface == 'wl_registry' and opcode == 0:
            name = struct.unpack('<I', body[:4])[0]
            interface, pos = self.string(body, 4)
            version = struct.unpack('<I', body[pos:pos + 4])[0]
            self.globals[interface] = (name, version)
            return
        h = self.handlers.get(iface)
        if h:
            h(oid, opcode, body)

    def roundtrip(self, timeout=5.0):
        cb = self.new('wl_callback')
        done = []
        self.handlers['wl_callback'] = lambda oid, op, body: done.append(oid)
        self.request(1, 0, 'n', cb)
        end = time.time() + timeout
        while cb not in done:
            if time.time() > end:
                raise SystemExit('the compositor does not answer')
            self.read_events(max(0.0, end - time.time()))


def write_png(path, width, height, rows):
    def chunk(kind, data):
        c = struct.pack('>I', len(data)) + kind + data
        return c + struct.pack('>I', __import__('zlib').crc32(kind + data) & 0xffffffff)
    raw = b''.join(b'\x00' + r for r in rows)
    with open(path, 'wb') as f:
        f.write(b'\x89PNG\r\n\x1a\n')
        f.write(chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0)))
        f.write(chunk(b'IDAT', __import__('zlib').compress(raw, 6)))
        f.write(chunk(b'IEND', b''))


class WaylandInput:
    """Input and clipboard through Wayland protocols (KWin, wlroots)."""

    def __init__(self, width, height):
        self.wl = Wayland()
        g = self.wl.globals
        self.width, self.height = width, height
        self.t0 = time.time()
        self.seat = self.wl.bind('wl_seat', 1)
        self.fake = self.vptr = self.vkbd = None
        self.mods = 0
        if 'org_kde_kwin_fake_input' in g:
            self.fake = self.wl.bind('org_kde_kwin_fake_input', 4)
            self.wl.request(self.fake, 0, 'ss', 'FMXWayland tests', 'input for the tests')
        else:
            if 'zwlr_virtual_pointer_manager_v1' in g:
                m = self.wl.bind('zwlr_virtual_pointer_manager_v1', 1)
                self.vptr = self.wl.new('zwlr_virtual_pointer_v1')
                self.wl.request(m, 0, 'on', self.seat, self.vptr)
            if 'zwp_virtual_keyboard_manager_v1' in g:
                m = self.wl.bind('zwp_virtual_keyboard_manager_v1', 1)
                self.vkbd = self.wl.new('zwp_virtual_keyboard_v1')
                self.wl.request(m, 0, 'on', self.seat, self.vkbd)
                keymap = self.keymap()
                fd = os.memfd_create('keymap')
                os.write(fd, keymap)
                self.wl.request(self.vkbd, 0, 'uhu', 1, None, len(keymap), fds=[fd])
                os.close(fd)
        self.dc = None
        for prefix, mgr in (('ext', 'ext_data_control_manager_v1'), ('zwlr', 'zwlr_data_control_manager_v1')):
            if mgr in g:
                self.dc = prefix
                self.dc_mgr = self.wl.bind(mgr, 1)
                self.dc_dev = self.wl.new(self.dc_name('device'))
                self.wl.request(self.dc_mgr, 1, 'no', self.dc_dev, self.seat)
                break
        self.offers = {}
        self.selection = None
        self.own_source = None
        self.own_text = b''
        if self.dc:
            self.wl.handlers[self.dc_name('device')] = self.on_device
            self.wl.handlers[self.dc_name('offer')] = self.on_offer
            self.wl.handlers[self.dc_name('source')] = self.on_source
        self.wl.roundtrip()

    def caps(self):
        return 'pointer=%s keyboard=%s clipboard=%s' % (
            'fake_input' if self.fake else ('virtual_pointer' if self.vptr else 'none'),
            'fake_input' if self.fake else ('virtual_keyboard' if self.vkbd else 'none'),
            (self.dc + '_data_control') if self.dc else 'none')

    def poll_fd(self):
        return self.wl.sock

    def service(self):
        self.wl.read_events(0)

    def sync(self):
        self.wl.roundtrip()

    def dc_name(self, kind):
        return '%s_data_control_%s_v1' % (self.dc, kind)

    @staticmethod
    def keymap():
        xkb = ctypes.CDLL('libxkbcommon.so.0')
        xkb.xkb_context_new.restype = ctypes.c_void_p
        xkb.xkb_keymap_new_from_names.restype = ctypes.c_void_p
        xkb.xkb_keymap_new_from_names.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_int]
        xkb.xkb_keymap_get_as_string.restype = ctypes.c_char_p
        xkb.xkb_keymap_get_as_string.argtypes = [ctypes.c_void_p, ctypes.c_int]

        class Names(ctypes.Structure):
            _fields_ = [(n, ctypes.c_char_p) for n in ('rules', 'model', 'layout', 'variant', 'options')]
        ctx = xkb.xkb_context_new(0)
        names = Names(b'evdev', b'pc105', b'us', b'', b'')
        km = xkb.xkb_keymap_new_from_names(ctx, ctypes.byref(names), 0)
        return xkb.xkb_keymap_get_as_string(km, 1) + b'\0'

    def ms(self):
        return int((time.time() - self.t0) * 1000) & 0xffffffff

    def on_device(self, oid, opcode, body):
        if opcode == 0:
            offer = struct.unpack('<I', body[:4])[0]
            self.wl.objects[offer] = self.dc_name('offer')
            self.offers[offer] = []
        elif opcode == 1:
            offer = struct.unpack('<I', body[:4])[0]
            self.selection = offer or None

    def on_offer(self, oid, opcode, body):
        if opcode == 0:
            mime, _ = self.wl.string(body, 0)
            self.offers.setdefault(oid, []).append(mime)

    def on_source(self, oid, opcode, body):
        if opcode == 0:
            fd = self.wl.take_fd()
            try:
                if oid == self.own_source:
                    os.write(fd, self.own_text)
            finally:
                os.close(fd)
        elif opcode == 1 and oid == self.own_source:
            self.own_source = None

    def move(self, x, y):
        if self.fake:
            self.wl.request(self.fake, 9, 'ff', x, y)
        elif self.vptr:
            self.wl.request(self.vptr, 1, 'uuuuu', self.ms(), int(round(x * 100)), int(round(y * 100)),
                            int(self.width * 100), int(self.height * 100))
            self.wl.request(self.vptr, 4, '')
        else:
            raise RuntimeError('no pointer injection')

    def button(self, name, pressed):
        code = BUTTONS[name]
        if self.fake:
            self.wl.request(self.fake, 2, 'uu', code, 1 if pressed else 0)
        elif self.vptr:
            self.wl.request(self.vptr, 2, 'uuu', self.ms(), code, 1 if pressed else 0)
            self.wl.request(self.vptr, 4, '')
        else:
            raise RuntimeError('no pointer injection')

    def wheel(self, notches):
        if self.fake:
            self.wl.request(self.fake, 3, 'uf', 0, 15.0 * notches)
        elif self.vptr:
            self.wl.request(self.vptr, 5, 'u', 0)
            self.wl.request(self.vptr, 7, 'uufi', self.ms(), 0, 15.0 * notches, notches)
            self.wl.request(self.vptr, 4, '')
        else:
            raise RuntimeError('no pointer injection')

    def key(self, code, pressed):
        if self.fake:
            self.wl.request(self.fake, 10, 'uu', code, 1 if pressed else 0)
        elif self.vkbd:
            self.wl.request(self.vkbd, 1, 'uuu', self.ms(), code, 1 if pressed else 0)
            if code in MOD_MASKS:
                self.mods = (self.mods | MOD_MASKS[code]) if pressed else (self.mods & ~MOD_MASKS[code])
                self.wl.request(self.vkbd, 2, 'uuuu', self.mods, 0, 0, 0)
        else:
            raise RuntimeError('no keyboard injection')

    def copy(self, text):
        if not self.dc:
            raise RuntimeError('no data control protocol')
        src = self.wl.new(self.dc_name('source'))
        self.wl.request(self.dc_mgr, 0, 'n', src)
        for m in TEXT_MIMES:
            self.wl.request(src, 0, 's', m)
        self.own_source, self.own_text = src, text.encode()
        self.wl.request(self.dc_dev, 0, 'o', src)

    def paste(self):
        if not self.dc:
            raise RuntimeError('no data control protocol')
        self.wl.roundtrip()
        if self.selection is None:
            return ''
        mimes = self.offers.get(self.selection, [])
        mime = next((m for m in TEXT_MIMES if m in mimes), None)
        if mime is None:
            return '(no text: %s)' % ','.join(mimes)
        r, w = os.pipe()
        self.wl.request(self.selection, 0, 'sh', mime, None, fds=[w])
        os.close(w)
        data = b''
        end = time.time() + 3
        while time.time() < end:
            # Our own source may be the one asked meanwhile.
            self.wl.read_events(0)
            rr, _, _ = select.select([r], [], [], 0.05)
            if rr:
                b = os.read(r, 65536)
                if not b:
                    break
                data += b
        os.close(r)
        return data.decode(errors='replace')


class Gnome:
    """GNOME Shell: org.gnome.Shell.Eval (unsafe mode: the test extension of compositors.sh turns it on)."""

    def __init__(self):
        import dbus
        self.dbus = dbus
        bus = dbus.SessionBus()
        self.shell = dbus.Interface(bus.get_object('org.gnome.Shell', '/org/gnome/Shell'), 'org.gnome.Shell')
        self.shooter = dbus.Interface(bus.get_object('org.gnome.Shell', '/org/gnome/Shell/Screenshot'),
                                      'org.gnome.Shell.Screenshot')
        self.eval('const C = imports.gi.Clutter;'
                  'const seat = global.stage.context.get_backend().get_default_seat();'
                  'global._fmxwPtr = seat.create_virtual_device(C.InputDeviceType.POINTER_DEVICE);'
                  'global._fmxwKbd = seat.create_virtual_device(C.InputDeviceType.KEYBOARD_DEVICE); "ok"')

    def eval(self, code):
        ok, res = self.shell.Eval(code)
        if not ok:
            raise RuntimeError('Eval failed: %s' % res)
        return json.loads(res) if res else None

    def caps(self):
        return 'pointer=clutter_virtual keyboard=clutter_virtual clipboard=st_clipboard'

    def poll_fd(self):
        return None

    def service(self):
        pass

    def sync(self):
        pass

    T = 'imports.gi.GLib.get_monotonic_time()'

    def move(self, x, y):
        self.eval('global._fmxwPtr.notify_absolute_motion(%s, %f, %f); "ok"' % (self.T, x, y))

    def button(self, name, pressed):
        b = {'left': 1, 'middle': 2, 'right': 3}[name]
        self.eval('global._fmxwPtr.notify_button(%s, %d, imports.gi.Clutter.ButtonState.%s); "ok"'
                  % (self.T, b, 'PRESSED' if pressed else 'RELEASED'))

    def wheel(self, notches):
        d = 'DOWN' if notches > 0 else 'UP'
        for _ in range(abs(notches)):
            self.eval('global._fmxwPtr.notify_discrete_scroll(%s, imports.gi.Clutter.ScrollDirection.%s, '
                      'imports.gi.Clutter.ScrollSource.WHEEL); "ok"' % (self.T, d))

    def key(self, code, pressed):
        self.eval('global._fmxwKbd.notify_key(%s, %d, imports.gi.Clutter.KeyState.%s); "ok"'
                  % (self.T, code, 'PRESSED' if pressed else 'RELEASED'))

    def copy(self, text):
        self.eval('const St = imports.gi.St; St.Clipboard.get_default().set_text(St.ClipboardType.CLIPBOARD, %s); "ok"'
                  % json.dumps(text))

    def paste(self):
        self.eval('const St = imports.gi.St; global._fmxwClip = null; St.Clipboard.get_default().get_text('
                  'St.ClipboardType.CLIPBOARD, (c, t) => { global._fmxwClip = t === null ? "" : t; }); "ok"')
        end = time.time() + 3
        while time.time() < end:
            v = self.eval('global._fmxwClip')
            if v is not None:
                return v
            time.sleep(0.1)
        return '(no answer)'

    WIN = ('global.get_window_actors().map(a => a.meta_window).find(w => w.get_title() == %s)')

    def geometry(self, title):
        r = self.eval('const w = %s; if (!w) "none"; else { const r = w.get_frame_rect(); [r.x, r.y, r.width, '
                      'r.height].join(" "); }' % (self.WIN % json.dumps(title)))
        if r == 'none':
            raise RuntimeError('no window "%s"' % title)
        return r

    def focus(self):
        return self.eval('const w = global.display.focus_window; w ? w.get_title() : ""')

    def parent(self, title):
        return self.eval('const w = %s; const p = w ? w.get_transient_for() : null; p ? p.get_title() : ""'
                         % (self.WIN % json.dumps(title)))

    def windows(self):
        return '|'.join(self.eval('global.get_window_actors().map(a => a.meta_window.get_title() || "")'))

    def close(self, title):
        self.eval('%s.delete(global.get_current_time()); "ok"' % (self.WIN % json.dumps(title)))

    def maximize(self, title, on):
        # (Mutter before 49 takes MetaMaximizeFlags.)
        f = 'maximize' if on else 'unmaximize'
        self.eval('const w = %s; const M = imports.gi.Meta; if (M.MaximizeFlags) w.%s(M.MaximizeFlags.BOTH); '
                  'else w.%s(); "ok"' % (self.WIN % json.dumps(title), f, f))

    def shot(self, path):
        ok, name = self.shooter.Screenshot(False, False, path)
        if not ok:
            raise RuntimeError('Screenshot failed')
        self.settle()
        return name

    def settle(self):
        """Waits until the shell takes no input itself (no overview, no modal grab)."""
        end = time.time() + 5
        while time.time() < end:
            if self.eval('if (Main.overview.visible && !Main.overview.animationInProgress) Main.overview.hide(); '
                         '!Main.layoutManager._startingUp && !Main.overview.visible && Main.modalCount == 0'):
                return 'settled'
            time.sleep(0.1)
        return 'still busy (modal %s)' % self.eval('Main.modalCount')


class Sway:
    def __init__(self):
        pass

    @staticmethod
    def msg(*args):
        return subprocess.run(['swaymsg'] + list(args), check=True, capture_output=True, text=True).stdout

    def views(self):
        def walk(n):
            if n.get('type') in ('con', 'floating_con') and n.get('pid'):
                yield n
            for c in n.get('nodes', []) + n.get('floating_nodes', []):
                yield from walk(c)
        return list(walk(json.loads(self.msg('-t', 'get_tree'))))

    def view(self, title):
        for v in self.views():
            if v.get('name') == title:
                return v
        raise RuntimeError('no window "%s"' % title)

    def geometry(self, title):
        v = self.view(title)
        r, w = v['rect'], v['window_rect']
        return '%d %d %d %d' % (r['x'] + w['x'], r['y'] + w['y'], w['width'], w['height'])

    def focus(self):
        for v in self.views():
            if v.get('focused'):
                return v.get('name') or ''
        return ''

    def parent(self, title):
        self.view(title)
        return '(not reported by sway)'

    def windows(self):
        return '|'.join(v.get('name') or '' for v in self.views())

    def close(self, title):
        self.msg('[con_id=%d]' % self.view(title)['id'], 'kill')

    def maximize(self, title, on):
        self.msg('[con_id=%d]' % self.view(title)['id'], 'fullscreen', 'enable' if on else 'disable')

    def shot(self, path):
        env = dict(os.environ, WAYLAND_DISPLAY=os.environ.get('HOST_WAYLAND_DISPLAY', os.environ['WAYLAND_DISPLAY']))
        subprocess.run(['grim', path], check=True, env=env)
        return path


class KWin:
    """KWin scripts loaded through D-Bus; what they print appears in KWin's log (KWIN_LOG)."""

    def __init__(self):
        import dbus
        self.dbus = dbus
        self.bus = dbus.SessionBus()
        self.scripting = dbus.Interface(self.bus.get_object('org.kde.KWin', '/Scripting'), 'org.kde.kwin.Scripting')
        self.log = os.environ['KWIN_LOG']
        self.n = 0

    def script(self, body):
        self.n += 1
        marker = 'FMXW%d' % self.n
        path = os.path.join(os.environ['XDG_RUNTIME_DIR'], 'fmxw-%d.js' % self.n)
        with open(path, 'w') as f:
            f.write('function out(s) { print("%s " + s); }\n%s\n' % (marker, body))
        sid = self.scripting.loadScript(path, marker, signature='ss')
        script = self.dbus.Interface(self.bus.get_object('org.kde.KWin', '/Scripting/Script%d' % sid),
                                     'org.kde.kwin.Script')
        script.run()
        end = time.time() + 3
        try:
            while time.time() < end:
                with open(self.log, errors='replace') as f:
                    for line in f:
                        p = line.find(marker + ' ')
                        if p >= 0:
                            return line[p + len(marker) + 1:].rstrip('\n').rstrip('"')
                time.sleep(0.05)
            raise RuntimeError('no answer of the KWin script')
        finally:
            self.scripting.unloadScript(marker)

    WIN = 'const w = workspace.windowList().find(w => w.caption == %s);'

    def geometry(self, title):
        r = self.script(self.WIN % json.dumps(title) + 'if (!w) out("none"); else { const g = w.clientGeometry; '
                        'out([g.x, g.y, g.width, g.height].join(" ")); }')
        if r == 'none':
            raise RuntimeError('no window "%s"' % title)
        return r

    def focus(self):
        return self.script('const w = workspace.activeWindow; out(w ? w.caption : "");')

    def parent(self, title):
        r = self.script(self.WIN % json.dumps(title) + 'if (!w) out("none"); '
                        'else out(w.transientFor ? w.transientFor.caption : "");')
        if r == 'none':
            raise RuntimeError('no window "%s"' % title)
        return r

    def windows(self):
        return self.script('out(workspace.windowList().map(w => w.caption).join("|"));')

    def close(self, title):
        self.script(self.WIN % json.dumps(title) + 'w.closeWindow(); out("ok");')

    def maximize(self, title, on):
        self.script(self.WIN % json.dumps(title) + 'w.setMaximize(%s, %s); out("ok");'
                    % (('true', 'true') if on else ('false', 'false')))

    def shot(self, path):
        return Sway.shot(self, path)


def make(kind):
    width, height = (float(v) for v in os.environ.get('LAYOUT', '1280 800').split())
    if kind == 'gnome':
        g = Gnome()
        return g, g
    wm = Sway() if kind == 'sway' else KWin()
    return WaylandInput(width, height), wm


def run(inp, wm, line):
    p = line.split(' ', 1)
    cmd, arg = p[0], (p[1] if len(p) > 1 else '')
    a = arg.split()
    result = ''
    if cmd == 'move':
        inp.move(float(a[0]), float(a[1]))
    elif cmd in ('down', 'up'):
        inp.button(a[0] if a else 'left', cmd == 'down')
    elif cmd == 'click':
        inp.button(a[0] if a else 'left', True)
        inp.sync()
        time.sleep(0.05)
        inp.button(a[0] if a else 'left', False)
    elif cmd == 'wheel':
        inp.wheel(int(a[0]))
    elif cmd == 'key':
        codes = key_codes(arg.split('+'))
        for c in codes:
            inp.key(c, True)
            inp.sync()
        for c in reversed(codes):
            inp.key(c, False)
            inp.sync()
    elif cmd == 'type':
        for codes in text_keys(arg):
            for c in codes:
                inp.key(c, True)
                inp.sync()
            for c in reversed(codes):
                inp.key(c, False)
                inp.sync()
            time.sleep(0.02)
    elif cmd == 'copy':
        inp.copy(arg)
    elif cmd == 'paste':
        result = inp.paste()
    elif cmd == 'geometry':
        result = wm.geometry(arg)
    elif cmd == 'focus':
        result = wm.focus()
    elif cmd == 'parent':
        result = wm.parent(arg)
    elif cmd == 'windows':
        result = wm.windows()
    elif cmd == 'close':
        wm.close(arg)
    elif cmd in ('maximize', 'restore'):
        wm.maximize(arg, cmd == 'maximize')
    elif cmd == 'shot':
        result = wm.shot(arg)
    elif cmd == 'caps':
        result = inp.caps()
    elif cmd == 'settle':
        result = wm.settle() if hasattr(wm, 'settle') else 'settled'
    else:
        raise RuntimeError('unknown command ' + cmd)
    inp.sync()
    return result


def serve(kind, fifo, answers):
    inp, wm = make(kind)
    # Read and write end: the FIFO never reports end of file between the commands of the shell.
    fd = os.open(fifo, os.O_RDWR | os.O_NONBLOCK)
    pending = b''
    while True:
        # The Wayland connection is served meanwhile (the clipboard source answers other clients).
        waits = [fd] + ([inp.poll_fd()] if inp.poll_fd() is not None else [])
        r, _, _ = select.select(waits, [], [], 1.0)
        if inp.poll_fd() is not None and inp.poll_fd() in r:
            inp.service()
        if fd not in r:
            continue
        pending += os.read(fd, 65536)
        while b'\n' in pending:
            raw, pending = pending.split(b'\n', 1)
            line = raw.decode(errors='replace').strip()
            if not line:
                continue
            if line == 'quit':
                with open(answers, 'w') as f:
                    f.write('ok\n')
                return
            try:
                res = ('ok ' + str(run(inp, wm, line))).rstrip()
            except Exception as e:  # answered; the server goes on
                res = 'error %s' % e
            with open(answers, 'w') as f:
                f.write(res.replace('\n', '\\n') + '\n')


if __name__ == '__main__':
    if len(sys.argv) == 5 and sys.argv[1] == 'serve':
        serve(sys.argv[2], sys.argv[3], sys.argv[4])
    else:
        sys.exit(__doc__)
