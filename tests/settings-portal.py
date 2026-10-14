#!/usr/bin/env python3
"""A settings portal for tests/dialog-check.sh: org.freedesktop.portal.Desktop on the session bus with
org.freedesktop.portal.Settings and one value, org.gnome.desktop.interface font-name.

    settings-portal.py <font-name> <log> [--old]

--old: only Read, whose value is a variant in a variant (portals before version 2 of the interface). Each call is
written to the log; "ready" once the name is owned.
"""
import sys

import dbus
import dbus.mainloop.glib
import dbus.service
from gi.repository import GLib

FONT, LOG = sys.argv[1], sys.argv[2]
OLD = '--old' in sys.argv[3:]
IFACE = 'org.freedesktop.portal.Settings'


def log(text):
    with open(LOG, 'a') as f:
        f.write(text + '\n')


def lookup(namespace, key):
    if (namespace, key) == ('org.gnome.desktop.interface', 'font-name'):
        return FONT
    raise dbus.exceptions.DBusException('Requested setting not found', name='org.freedesktop.portal.Error.NotFound')


class Settings(dbus.service.Object):
    @dbus.service.method(IFACE, in_signature='ss', out_signature='v')
    def Read(self, namespace, key):
        log('Read %s %s' % (namespace, key))
        return dbus.String(lookup(namespace, key), variant_level=2)


class SettingsV2(Settings):
    @dbus.service.method(IFACE, in_signature='ss', out_signature='v')
    def ReadOne(self, namespace, key):
        log('ReadOne %s %s' % (namespace, key))
        return dbus.String(lookup(namespace, key))


dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
bus = dbus.SessionBus()
name = dbus.service.BusName('org.freedesktop.portal.Desktop', bus)
(Settings if OLD else SettingsV2)(bus, '/org/freedesktop/portal/desktop')
log('ready')
GLib.MainLoop().run()
