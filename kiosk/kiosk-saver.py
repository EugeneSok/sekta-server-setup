#!/usr/bin/env python3
#
# sekta-kiosk-saver — screensaver of the kiosk screens (GTK 4).
#
# Installed as ~/.local/bin/sekta-kiosk-saver and started by
# sekta-kiosk-screens with the kiosk (SAVERS / SAVER_HOURS / SAVER_SIZES of
# screens.conf):
#
#   sekta-kiosk-saver OUTPUT HOURS SIZE PICTURE [OUTPUT HOURS SIZE PICTURE …]
#   sekta-kiosk-saver --now OUTPUT HOURS SIZE PICTURE   «Показати» of the app:
#                    shown at once, the program ends on the first input
#
# After HOURS without mouse / keyboard a screen goes black with PICTURE in the
# middle, SIZE % of the screen (10–100; 100 = as big as fits, proportions
# kept), on top of the kiosk; any input takes every screensaver away. OUTPUT
# "-" = every monitor no other screen names (one-screen kiosk). The idle time comes from GNOME (Mutter, X11 and
# Wayland), else from X11 (XScreenSaver extension); with neither (labwc,
# wayfire) it says so in the journal and exits.
#
# SEKTA_KIOSK_SAVER_HOUR=10 — an "hour" of 10 s, for trying it out.
#
# Works with GTK 4.8 (Debian 12) and newer.
import ctypes
import ctypes.util
import os
import shutil
import signal
import subprocess
import sys

import gi
gi.require_version("Gtk", "4.0")
gi.require_version("Gdk", "4.0")
gi.require_version("GdkPixbuf", "2.0")
from gi.repository import Gdk, GdkPixbuf, Gio, GLib, Gtk  # noqa: E402

PREVIEW_S = 300   # --now: gone by itself after 5 min at the latest
HOUR_MS = int(float(os.environ.get("SEKTA_KIOSK_SAVER_HOUR", "3600")) * 1000)
CSS = "window.sk-saver { background: #000000; }"


def log(msg):
    print("sekta-kiosk-saver: " + msg, file=sys.stderr, flush=True)   # → journal of the unit


# --- idle time ---------------------------------------------------------------
class MutterIdle:
    """GNOME: idle time of the whole session, X11 and Wayland."""

    def __init__(self):
        self.bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        self.ms()   # raises when there is no Mutter

    def ms(self):
        r = self.bus.call_sync("org.gnome.Mutter.IdleMonitor", "/org/gnome/Mutter/IdleMonitor/Core",
                               "org.gnome.Mutter.IdleMonitor", "GetIdletime", None,
                               GLib.VariantType.new("(t)"), Gio.DBusCallFlags.NONE, 2000, None)
        return r.unpack()[0]


class XssInfo(ctypes.Structure):
    _fields_ = [("window", ctypes.c_ulong), ("state", ctypes.c_int), ("kind", ctypes.c_int),
                ("til_or_since", ctypes.c_ulong), ("idle", ctypes.c_ulong), ("eventMask", ctypes.c_ulong)]


class XssIdle:
    """X11 without GNOME: the XScreenSaver extension (libXss)."""

    def __init__(self):
        if os.environ.get("WAYLAND_DISPLAY") or not os.environ.get("DISPLAY"):
            raise OSError("not an X11 session")   # XWayland sees X clients' input only
        x11 = ctypes.CDLL(ctypes.util.find_library("X11") or "libX11.so.6")
        self.xss = ctypes.CDLL(ctypes.util.find_library("Xss") or "libXss.so.1")
        x11.XOpenDisplay.restype = ctypes.c_void_p
        x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
        x11.XDefaultRootWindow.restype = ctypes.c_ulong
        x11.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
        self.xss.XScreenSaverAllocInfo.restype = ctypes.POINTER(XssInfo)
        self.xss.XScreenSaverQueryInfo.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.POINTER(XssInfo)]
        self.dpy = x11.XOpenDisplay(None)
        if not self.dpy:
            raise OSError("cannot open X display")
        self.root = x11.XDefaultRootWindow(self.dpy)
        self.info = self.xss.XScreenSaverAllocInfo()
        self.ms()

    def ms(self):
        if not self.xss.XScreenSaverQueryInfo(self.dpy, self.root, self.info):
            raise OSError("no XScreenSaver extension")
        return self.info.contents.idle


def idle_source():
    for cls in (MutterIdle, XssIdle):
        try:
            return cls()
        except (GLib.Error, OSError, AttributeError) as e:
            last = "%s: %s" % (cls.__name__, e)
    log("no idle time here (%s) — screensaver off" % last)
    return None


# --- screens -----------------------------------------------------------------
def picture(path, size, geo):
    """PICTURE fitted into the monitor (logical px), SIZE % of it, rendered
    at that size (sharp, an SVG too) — None if it can't be read."""
    try:
        _fmt, w, h = GdkPixbuf.Pixbuf.get_file_info(path)
        k = min(geo.width / max(1, w), geo.height / max(1, h)) * size / 100
        pb = GdkPixbuf.Pixbuf.new_from_file_at_scale(path, max(1, round(w * k)), max(1, round(h * k)), True)
    except (GLib.Error, TypeError) as e:
        log("picture %s: %s" % (path, e))
        return None
    p = Gtk.Picture.new_for_paintable(Gdk.Texture.new_for_pixbuf(pb))
    p.set_can_shrink(False)
    p.set_halign(Gtk.Align.CENTER)
    p.set_valign(Gtk.Align.CENTER)
    return p


class Saver:
    def __init__(self, screens, idle, now=None):
        self.screens = screens   # [(output, hours, size, picture)]
        self.idle = idle
        self.now = now           # --now: the main loop to end on input
        self.wins = []           # shown windows
        self.shown = set()       # indexes of screens shown
        self.last = 0
        if now:
            for i, (out, _h, size, pic) in enumerate(screens):
                self.show(i, out, size, pic)
            GLib.timeout_add_seconds(PREVIEW_S, self.hide)
        if idle:
            GLib.timeout_add(1000 if not now else 300, self.tick)

    def monitors(self, output):
        mons = Gdk.Display.get_default().get_monitors()
        named = {o for o, _, _, _ in self.screens if o != "-"}
        got = []
        for k in range(mons.get_n_items()):
            m = mons.get_item(k)
            c = m.get_connector() or ""
            if (output == "-" and c not in named) or c == output:
                got.append(m)
        return got

    def tick(self):
        try:
            idle = self.idle.ms()
        except (GLib.Error, OSError) as e:
            log("idle time: %s" % e)
            return True
        if idle < self.last and self.shown:
            self.hide()   # mouse / keyboard: every screen back
        self.last = idle
        if self.now:
            return True
        for i, (out, hours, size, pic) in enumerate(self.screens):
            if i not in self.shown and idle >= hours * HOUR_MS:
                self.show(i, out, size, pic)
        return True

    def show(self, i, out, size, pic):
        self.shown.add(i)
        mons = self.monitors(out)
        if not mons:
            log("screen %d: monitor %s not found" % (i + 1, out))
        for m in mons:
            name = m.get_connector() or "?"
            w = Gtk.Window(title="sekta-kiosk-saver " + name, decorated=False)
            w.add_css_class("sk-saver")
            p = picture(pic, size, m.get_geometry())
            if p:
                w.set_child(p)
            w.set_cursor(Gdk.Cursor.new_from_name("none"))
            # a click / key on the black screen must not reach the page below
            # (and ends a preview even without an idle time)
            click, key = Gtk.GestureClick(), Gtk.EventControllerKey()
            click.connect("pressed", lambda *_: self.input())
            key.connect("key-pressed", lambda *_: self.input() or True)
            w.add_controller(click)
            w.add_controller(key)
            w.fullscreen_on_monitor(m)
            w.present()
            self.wins.append(w)
            # X11 window managers: keep it over the full-screen kiosk window
            if shutil.which("wmctrl"):
                GLib.timeout_add(700, self.above, w.get_title())
            log("screen %d: on (%s)" % (i + 1, name))

    def above(self, title):
        # GNOME gives a window that appears without a click no focus and may
        # stack it under the focused full-screen Chromium: above + activate
        for how in (["-r", title, "-b", "add,above"], ["-a", title]):
            subprocess.run(["wmctrl", "-F"] + how, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return False

    def input(self):
        if self.now:
            self.hide()

    def hide(self):
        for w in self.wins:
            w.destroy()
        self.wins = []
        self.shown = set()
        if self.now:
            self.now.quit()
        else:
            log("input — off")
        return False


def main(argv):
    now = argv[:1] == ["--now"]
    if now:
        argv = argv[1:]
    if len(argv) % 4 or not argv:
        log("usage: sekta-kiosk-saver [--now] OUTPUT HOURS SIZE PICTURE …")
        return 2
    screens = []
    for k in range(0, len(argv), 4):
        out, hours, size, pic = argv[k:k + 4]
        try:
            h, z = int(hours), int(size)
        except ValueError:
            h = z = 0
        if not 1 <= h <= 12 or not 10 <= z <= 100 or not os.path.isfile(pic):
            log("skipped: %s %s %s %s (hours 1-12, size 10-100, a picture file)" % (out, hours, size, pic))
            continue
        screens.append((out, h, z, pic))
    if not screens:
        return 2
    GLib.set_prgname("sekta-kiosk-saver")   # window class: wmctrl keeps it above
    Gtk.init()
    idle = idle_source()
    if not idle and not now:
        return 1
    prov = Gtk.CssProvider()
    if hasattr(prov, "load_from_string"):
        prov.load_from_string(CSS)
    else:
        prov.load_from_data(CSS.encode())
    Gtk.StyleContext.add_provider_for_display(Gdk.Display.get_default(), prov,
                                              Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
    loop = GLib.MainLoop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, sig, loop.quit)
    Saver(screens, idle, loop if now else None)
    if not now:
        log("watching: %s (%s)" % (", ".join("%s %d h" % (o, h) for o, h, _, _ in screens),
                                    type(idle).__name__))
    loop.run()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
