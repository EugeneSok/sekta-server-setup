#!/usr/bin/env python3
#
# sekta-kiosk-gui — the window of the SEKTA kiosk app (GTK 4, Ukrainian UI).
#
# Started by sekta-kiosk.sh when python3-gi + GTK 4 are there (else the app
# keeps its zenity windows). sekta-kiosk.sh holds the single-instance lock,
# makes the menu entry / hotkey and installs the bundled packages on a bare
# Debian; this file is the window:
#   - screens as they stand around screen 1: output, clock hour, zoom, site;
#     «Застосувати» writes screens.conf (kiosk-screens.sh --write-conf),
#     switches GNOME Wayland ⇄ Xorg (pkexec) and restarts the kiosk;
#   - identify screens, restore the sites, restart / stop / start the kiosk;
#   - update from a sekta-kiosk .deb (e.g. on a stick);
#   - the offline installer (install-offline.sh next to the app / package).
#
#   sekta-kiosk-gui.py [--install]   from sekta-kiosk.sh (env SEKTA_KIOSK_*)
#
# Works with GTK 4.8 (Debian 12) and newer: no libadwaita, no 4.10+ API.
import math
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import threading
import time

import gi
gi.require_version("Gtk", "4.0")
gi.require_version("Gdk", "4.0")
gi.require_version("PangoCairo", "1.0")
gi.require_foreign("cairo")   # python3-gi-cairo: drawing the screens
from gi.repository import Gdk, Gio, GLib, Gtk, Pango, PangoCairo  # noqa: E402

TITLE = "Sekta kiosk"
HOME = os.path.expanduser("~")
BIN = os.path.join(HOME, ".local/bin")
SCREENS_BIN = os.path.join(BIN, "sekta-kiosk-screens")
START_BIN = os.path.join(BIN, "sekta-kiosk-start")
CONF = os.path.join(HOME, ".config/sekta-kiosk/screens.conf")
INSTALLED_VERSION_FILE = os.path.join(HOME, ".config/sekta-kiosk/VERSION")
SERVICE = "chromium-kiosk.service"
RUNTIME = os.environ.get("XDG_RUNTIME_DIR") or "/tmp"
MAP_FILE = os.path.join(RUNTIME, "sekta-kiosk-screens.map")
LOG_FILE = os.path.join(HOME, "sekta-kiosk-install.log")
PKG_DIR = "/usr/share/sekta-kiosk"
DEFAULT_URL = "https://combat.omega"
SELF = os.path.realpath(__file__)
# from sekta-kiosk.sh: where an offline install comes from (stick / package)
INSTALL_SRC = os.environ.get("SEKTA_KIOSK_SRC", "")
APP_SH = os.environ.get("SEKTA_KIOSK_SELF", "")
HOURS = {3: "праворуч", 9: "ліворуч", 12: "вище", 6: "нижче",
         2: "праворуч, зсунутий вгору", 4: "праворуч, зсунутий вниз",
         8: "ліворуч, зсунутий вниз", 10: "ліворуч, зсунутий вгору",
         1: "вище, зсунутий праворуч", 11: "вище, зсунутий ліворуч",
         5: "нижче, зсунутий праворуч", 7: "нижче, зсунутий ліворуч"}
ZOOMS = [75, 90, 100, 110, 125, 150, 175, 200]
# −/+ in the main window: these steps (kiosk-screens.sh takes 50–300)
ZOOM_STEPS = [50, 67, 75, 80, 90, 100, 110, 125, 150, 175, 200, 250, 300]
ANSI = re.compile(r"\x1b\[[0-9;]*m")

CSS = """
window.sk, window.sk-dialog { background: #ecede3; color: #23271b; }
headerbar.sk-head { background: #e2e3d7; border-bottom: 1px solid #c9ccba; box-shadow: none; min-height: 52px; }
.sk-title { font-weight: 600; font-size: 12pt; }
.sk-sub { color: #5f6352; font-size: 9pt; }
.sk-muted { color: #5f6352; }
.sk-dim { color: #4a4e3f; }
.sk-pill { background: #d9e1c0; color: #4b5a26; border-radius: 14px; padding: 4px 12px; font-weight: 500; }
.sk-pill.off { background: #eadfc6; color: #8a5a12; }
button.sk-btn { background: #f4f4ec; background-image: none; border: 1px solid #c0c3af; border-radius: 8px;
  min-height: 34px; padding: 0 14px; color: #23271b; box-shadow: none; }
button.sk-btn:hover { background: #fafaf5; }
button.sk-btn:disabled { color: #8a8d7c; }
button.sk-primary { background: #5f6f34; background-image: none; color: #ffffff; border: none; border-radius: 8px;
  min-height: 38px; padding: 0 20px; font-weight: 600; box-shadow: none; }
button.sk-primary:hover { background: #55642e; }
button.sk-primary:disabled { background: #c9ccba; color: #5c604f; }
button.sk-dashed { background: rgba(244,244,236,0.85); background-image: none; border: 1px dashed #8f9b6a;
  border-radius: 8px; color: #4b5a26; min-height: 34px; padding: 0 14px; box-shadow: none; }
button.sk-dashed:disabled { color: #8a8d7c; border-color: #b6baa2; }
.sk-aside { background: #e5e6da; border-left: 1px solid #c9ccba; }
.sk-stage { background: #dfe1d3; border: 1px solid #c7cab7; border-radius: 12px; }
.sk-note { background: #e1e5d2; border: 1px solid #c0c3af; border-radius: 10px; padding: 12px 14px; color: #4a4e3f; }
.sk-warn { color: #8a5a12; }
.sk-err { color: #9b2c1c; font-weight: 600; }
.sk-badge { background: #d6dfba; color: #4b5a26; border-radius: 10px; font-weight: 700; font-size: 16pt;
  min-width: 42px; min-height: 42px; }
.sk-h1 { font-size: 15pt; font-weight: 600; }
.sk-big { font-size: 20pt; font-weight: 700; }
.sk-label { font-weight: 600; color: #4a4e3f; font-size: 10pt; }
.sk-mono { font-family: monospace; }
entry.sk-entry { background: #f4f4ec; background-image: none; border: 1px solid #b6baa2; border-radius: 8px;
  min-height: 40px; color: #23271b; box-shadow: none; }
button.sk-card { background: #f4f4ec; background-image: none; border: 2px solid #c0c3af; border-radius: 10px;
  padding: 8px 14px; color: #23271b; box-shadow: none; }
button.sk-card:checked { background: #d9e1c0; border-color: #5f6f34; }
button.sk-hour { background: #f4f4ec; background-image: none; border: 1px solid #b6baa2; border-radius: 18px;
  min-width: 36px; min-height: 36px; padding: 0; font-weight: 600; color: #353a2a; box-shadow: none; }
button.sk-hour:checked { background: #5f6f34; color: #ffffff; border-color: #5f6f34; }
.sk-seg { background: #dfe1d3; border: 1px solid #c7cab7; border-radius: 10px; padding: 4px; }
button.sk-zoom { background: transparent; background-image: none; border: none; border-radius: 7px; min-height: 36px;
  min-width: 58px; font-weight: 600; color: #353a2a; box-shadow: none; }
button.sk-zoom:checked { background: #5f6f34; color: #ffffff; }
.sk-foot { background: #e5e6da; border-top: 1px solid #c9ccba; }
.sk-left { background: #dfe1d3; border-right: 1px solid #c9ccba; }
.sk-chip { background: #e1e5d2; border: 1px solid #c0c3af; border-radius: 14px; padding: 3px 12px; font-size: 9pt; color: #353a2a; }
.sk-step-done { background: #5f6f34; color: #ffffff; border-radius: 15px; min-width: 30px; min-height: 30px; font-weight: 700; }
.sk-step-now { border: 2px solid #5f6f34; color: #4b5a26; border-radius: 15px; min-width: 26px; min-height: 26px; font-weight: 700; }
.sk-step-todo { border: 2px solid #b6baa2; color: #5c604f; border-radius: 15px; min-width: 26px; min-height: 26px; font-weight: 700; }
.sk-step-fail { background: #9b2c1c; color: #ffffff; border-radius: 15px; min-width: 30px; min-height: 30px; font-weight: 700; }
.sk-row { padding: 0 12px; border: 1px solid transparent; }
.sk-row-now { background: #e1e5d2; border: 1px solid #c0c3af; border-radius: 10px; }
progressbar.sk-bar trough { background: #d3d6c4; min-height: 8px; border-radius: 4px; border: none; }
progressbar.sk-bar progress { background: #5f6f34; min-height: 8px; border-radius: 4px; border: none; }
textview.sk-log, textview.sk-log text { background: #e4e5d9; color: #4a4e3f; font-family: monospace; font-size: 9pt; }
textview.sk-diag, textview.sk-diag text { background: #f7f7f0; color: #23271b; font-family: monospace; font-size: 10.5pt; }
.sk-logbox { border: 1px solid #c7cab7; border-radius: 10px; }
.sk-ident { background: #23271b; color: #ecede3; }
.sk-ident-num { font-size: 96pt; font-weight: 700; color: #c3d38c; }
.sk-ident-out { font-size: 28pt; font-family: monospace; }
"""


# --- small helpers -----------------------------------------------------------
def run(cmd, env=None, **kw):
    """Run a command, return (rc, stdout + stderr)."""
    try:
        p = subprocess.run(cmd, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, text=True, **kw)
        return p.returncode, p.stdout
    except OSError as e:
        return 127, str(e)


def out(cmd):
    rc, o = run(cmd)
    return o.strip() if rc == 0 else ""


def read(path, default=""):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return default


def ver_key(v):
    return [int(x) if x.isdigit() else x for x in re.split(r"[.+~-]", v)]


def newer(a, b):
    """a newer than b (sort -V for plain x.y.z)."""
    try:
        return ver_key(a) > ver_key(b)
    except TypeError:
        return a != b and sorted([a, b])[-1] == a


def bundle_name():
    rel = ""
    for line in read("/etc/os-release").splitlines():
        if line.startswith("VERSION_CODENAME="):
            rel = line.split("=", 1)[1].strip('"')
    return rel or "unknown", out(["dpkg", "--print-architecture"])


def has_sudo():
    if not shutil.which("sudo"):
        return False
    if run(["sudo", "-n", "true"])[0] == 0:
        return True
    return "sudo" in out(["id", "-nG"]).split()


def sudo_hint():
    rel, arch = bundle_name()
    deb = ""
    if not shutil.which("sudo"):
        deb = "apt install %s/debs/%s-%s/sudo_*.deb && " % (INSTALL_SRC, rel, arch)
    user = os.environ.get("USER", "")
    return ("Користувач %s не має прав адміністратора (sudo).\n"
            "Один раз у терміналі, з паролем root:\n"
            "  su - -c \"%susermod -aG sudo %s\"\n"
            "потім вийти з сеансу й увійти знову (або перезавантажити) і запустити Sekta kiosk ще раз."
            % (user, deb, user))


def icon_path():
    for p in (os.path.join(INSTALL_SRC, "sekta-kiosk.png") if INSTALL_SRC else "",
              os.path.join(HOME, ".local/share/icons/hicolor/512x512/apps/sekta-kiosk.png"),
              os.path.join(os.path.dirname(SELF), "sekta-kiosk.png"),
              os.path.join(PKG_DIR, "sekta-kiosk.png")):
        if p and os.path.isfile(p):
            return p
    return ""


def logo(size):
    p = icon_path()
    img = Gtk.Image.new_from_file(p) if p else Gtk.Image.new_from_icon_name("video-display-symbolic")
    img.set_pixel_size(size)
    return img


def label(text="", css=(), xalign=0.0, wrap=False, ellipsize=False, mono=False):
    lab = Gtk.Label(label=text, xalign=xalign)
    for c in css:
        lab.add_css_class(c)
    if mono:
        lab.add_css_class("sk-mono")
    if wrap:
        lab.set_wrap(True)
        lab.set_wrap_mode(Pango.WrapMode.WORD_CHAR)
        lab.set_max_width_chars(40)   # natural width: a column, not the whole text
    if ellipsize:
        lab.set_ellipsize(Pango.EllipsizeMode.END)
    return lab


def button(text, css="sk-btn", icon=None, cb=None):
    b = Gtk.Button()
    b.add_css_class(css)
    if icon:
        box = Gtk.Box(spacing=8)
        img = Gtk.Image.new_from_icon_name(icon)
        # no icon theme with this icon (a bare desktop): text only
        img.set_visible(Gtk.IconTheme.get_for_display(Gdk.Display.get_default()).has_icon(icon))
        box.append(img)
        box.append(Gtk.Label(label=text))
        b.set_child(box)
    else:
        b.set_label(text)
    if cb:
        b.connect("clicked", lambda *_: cb())
    return b


def vbox(spacing=0, css=None, margin=0):
    b = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=spacing)
    if css:
        b.add_css_class(css)
    if margin:
        for side in ("top", "bottom", "start", "end"):
            getattr(b, "set_margin_" + side)(margin)
    return b


def hbox(spacing=0, css=None):
    b = Gtk.Box(spacing=spacing)
    if css:
        b.add_css_class(css)
    return b


def clear(box):
    child = box.get_first_child()
    while child:
        nxt = child.get_next_sibling()
        box.remove(child)
        child = nxt


def sudo_dir(password):
    """A private dir (0700) with sudo (= sudo -A) and its askpass, which hands
    sudo the password already checked in our window — put first in PATH, every
    sudo of the scripts run there gets it. (A password window of its own would
    open unfocused, under ours or the kiosk — GNOME gives a new window of
    another process no focus — and the install would wait for it unseen.)"""
    t = tempfile.mkdtemp()   # 0700, this user only
    pw = os.path.join(t, "pw")
    fd = os.open(pw, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(password + "\n")
    with open(os.path.join(t, "sudo"), "w") as f:
        f.write('#!/bin/sh\nexec /usr/bin/sudo -A "$@"\n')
    with open(os.path.join(t, "askpass"), "w") as f:
        f.write('#!/bin/sh\nexec cat %s\n' % shlex.quote(pw))
    os.chmod(os.path.join(t, "sudo"), 0o755)
    os.chmod(os.path.join(t, "askpass"), 0o700)
    return t


def sudo_env(env, t):
    env["PATH"] = t + ":" + env.get("PATH", "")
    env["SUDO_ASKPASS"] = os.path.join(t, "askpass")
    return env


def sudo_check(password):
    """The password works for sudo (-k: not a cached sign-in)."""
    try:
        p = subprocess.run(["sudo", "-S", "-k", "-p", "", "true"], input=password + "\n", text=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=60)
        return p.returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


# --- settings ----------------------------------------------------------------
class Conf:
    """screens.conf: N screens; url / hour (None for screen 1) / out ('-' =
    auto) / scale per screen."""

    def __init__(self):
        self.screens = [{"url": DEFAULT_URL, "hour": None, "out": "-", "scale": 100}]
        self.raw = (1, [DEFAULT_URL], [], [])

    @classmethod
    def load(cls):
        c = cls()
        script = ('SCREENS=1; URLS=(); LAYOUT=(); OUTPUTS=(); SCALES=(); [ -f "$1" ] && . "$1" >/dev/null 2>&1; '
                  'printf "S%s\\0" "$SCREENS"; printf "U%s\\0" "${URLS[@]}"; printf "L%s\\0" "${LAYOUT[@]}"; '
                  'printf "O%s\\0" "${OUTPUTS[@]}"; printf "Z%s\\0" "${SCALES[@]}"')
        try:
            o = subprocess.run(["bash", "-c", script, "_", CONF], stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL, text=True).stdout
        except OSError:
            o = ""
        vals = {"S": [], "U": [], "L": [], "O": [], "Z": []}
        for item in o.split("\0"):
            if item and item[0] in vals and len(item) > 1:
                vals[item[0]].append(item[1:])
        try:
            n = max(1, min(3, int(vals["S"][0])))
        except (IndexError, ValueError):
            n = 1
        urls = vals["U"] or [DEFAULT_URL]
        c.raw = (n, urls, vals["L"], vals["O"])
        c.screens = []
        for i in range(n):
            url = " ".join(urls) if n == 1 else (urls[i] if i < len(urls) else urls[0])
            hour = None
            if i > 0:
                try:
                    hour = int(vals["L"][i - 1])
                except (IndexError, ValueError):
                    hour = 3
                if hour not in HOURS:
                    hour = 3
            o_ = vals["O"][i] if i < len(vals["O"]) else "-"
            try:
                z = int(vals["Z"][i])
            except (IndexError, ValueError):
                z = 100
            c.screens.append({"url": url, "hour": hour, "out": o_ or "-", "scale": z})
        return c

    def copy(self):
        c = Conf()
        c.screens = [dict(s) for s in self.screens]
        c.raw = self.raw
        return c

    def env(self):
        """KIOSK_* for --write-conf / install-offline.sh."""
        n = len(self.screens)
        if n == 1:
            urls = [" ".join(self.screens[0]["url"].split())]
        else:
            urls = [(s["url"].split() or [DEFAULT_URL])[0] for s in self.screens]
        return {"KIOSK_SCREENS": str(n), "KIOSK_URL": " ".join(urls),
                "KIOSK_LAYOUT": " ".join(str(s["hour"]) for s in self.screens[1:]),
                "KIOSK_OUTPUTS": " ".join(s["out"] for s in self.screens),
                "KIOSK_SCALE": " ".join(str(s["scale"]) for s in self.screens)}

    def key(self):
        """screens, sites, layout, outputs — what makes the remembered pages wrong."""
        e = self.env()
        return " ".join(("%s|%s|%s|%s" % (e["KIOSK_SCREENS"], e["KIOSK_URL"], e["KIOSK_LAYOUT"],
                                          e["KIOSK_OUTPUTS"])).split())

    def same(self, other):
        return [tuple(sorted(s.items())) for s in self.screens] == \
               [tuple(sorted(s.items())) for s in other.screens]


def detect_outputs(ks):
    """Connected outputs [(name, 'WxH')] and a note when names are unknown."""
    names = []
    rc, o = run(["bash", ks, "--outputs"])
    for line in o.splitlines() if rc == 0 else []:
        f = line.split()
        if not f:
            continue
        if f[0].startswith("XWAYLAND"):
            if "GNOME" in os.environ.get("XDG_CURRENT_DESKTOP", ""):
                return [], ("Зараз GNOME працює на Wayland — назви виходів недоступні. Лишіть «авто»; "
                            "після переходу на X11 (перезавантаження) виходи можна вибрати тут.")
            return [], "Назви виходів недоступні (Wayland без wlr-randr). Лишіть «авто» або встановіть wlr-randr."
        names.append((f[0], f[1] if len(f) > 1 else ""))
    return names, ""


def assign_outputs(screens, outputs):
    """Output name per screen as the launcher picks them: pinned ones first,
    then «auto» takes the next free one (None: no monitor)."""
    names = [n for n, _ in outputs]
    got, used = [None] * len(screens), set()
    for i, s in enumerate(screens):
        if s["out"] != "-" and s["out"] in names and s["out"] not in used:
            got[i] = s["out"]
            used.add(s["out"])
    free = [n for n in names if n not in used]
    for i, s in enumerate(screens):
        if got[i] is None and s["out"] == "-" and free:
            got[i] = free.pop(0)
    return got


def layout_rects(screens, sizes):
    """Desktop rectangles like kiosk-screens.sh: screen 1 at 0,0, the others
    past the screens on their side, centred (3/6/9/12) or shifted by half."""
    def half(v):
        return int(v / 2)
    X, Y = [0], [0]
    W = [s[0] for s in sizes]
    H = [s[1] for s in sizes]
    w1, h1 = W[0], H[0]
    right, left, top, bottom = w1, 0, 0, h1
    for i in range(1, len(screens)):
        hr = screens[i]["hour"] or 3
        w, h = W[i], H[i]
        x, y = {2: (right, half(-h)), 3: (right, half(h1 - h)), 4: (right, h1 - half(h)),
                5: (w1 - half(w), bottom), 6: (half(w1 - w), bottom), 7: (half(-w), bottom),
                8: (left - w, h1 - half(h)), 9: (left - w, half(h1 - h)), 10: (left - w, half(-h)),
                11: (half(-w), top - h), 12: (half(w1 - w), top - h), 1: (w1 - half(w), top - h)}[hr]
        moved = True
        while moved:
            moved = False
            for j in range(i):
                if x < X[j] + W[j] and X[j] < x + w and y < Y[j] + H[j] and Y[j] < y + h:
                    if hr in (2, 3, 4):
                        x = X[j] + W[j]
                    elif hr in (5, 6, 7):
                        y = Y[j] + H[j]
                    elif hr in (8, 9, 10):
                        x = X[j] - w
                    else:
                        y = Y[j] - h
                    moved = True
        if hr in (2, 3, 4):
            right = x + w
        elif hr in (5, 6, 7):
            bottom = y + h
        elif hr in (8, 9, 10):
            left = x
        else:
            top = y
        X.append(x)
        Y.append(y)
    return list(zip(X, Y, W, H))


def rounded(cr, x, y, w, h, r):
    cr.new_sub_path()
    cr.arc(x + w - r, y + r, r, -math.pi / 2, 0)
    cr.arc(x + w - r, y + h - r, r, 0, math.pi / 2)
    cr.arc(x + r, y + h - r, r, math.pi / 2, math.pi)
    cr.arc(x + r, y + r, r, math.pi, 3 * math.pi / 2)
    cr.close_path()


def rgb(cr, hexc, a=1.0):
    cr.set_source_rgba(int(hexc[1:3], 16) / 255, int(hexc[3:5], 16) / 255, int(hexc[5:7], 16) / 255, a)


# --- the app -----------------------------------------------------------------
class App(Gtk.Application):
    def __init__(self, args):
        super().__init__(application_id="ua.sekta.kiosk", flags=Gio.ApplicationFlags.NON_UNIQUE)
        self.args = args
        self.win = None
        self.ks = SCREENS_BIN if os.access(SCREENS_BIN, os.X_OK) else os.path.join(INSTALL_SRC, "kiosk-screens.sh")
        self.conf = Conf.load()
        self.edit = self.conf.copy()
        self.outputs, self.out_note = [], ""
        self.sel = 0
        self.mode = "manage"        # or "install"
        self.install_quit = False   # cancel of the first install closes the app
        self.busy = False
        self.kiosk_active = False
        self.chooser = None
        self.boxes = []
        self.before_key = ""

    def do_shutdown(self):
        # a sudo dir handed over by the update and not used (install cancelled)
        d = os.environ.get("SEKTA_KIOSK_SUDO_DIR", "")
        if d and os.path.isdir(d) and os.stat(d).st_uid == os.getuid():
            shutil.rmtree(d, ignore_errors=True)
        Gtk.Application.do_shutdown(self)

    # --- window ---------------------------------------------------------------
    def do_activate(self):
        prov = Gtk.CssProvider()
        if hasattr(prov, "load_from_string"):
            prov.load_from_string(CSS)
        else:
            prov.load_from_data(CSS.encode())
        Gtk.StyleContext.add_provider_for_display(Gdk.Display.get_default(), prov,
                                                  Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        self.win = Gtk.ApplicationWindow(application=self, title=TITLE)
        self.win.add_css_class("sk")
        self.win.set_default_size(1080, 700)
        self.build_header()
        # sized by the page shown, not the biggest one
        self.stack = Gtk.Stack(transition_type=Gtk.StackTransitionType.CROSSFADE,
                               hhomogeneous=False, vhomogeneous=False, interpolate_size=False)
        self.win.set_child(self.stack)
        self.stack.add_named(Gtk.Box(), "blank")   # until start() picks a page
        self.build_main()
        self.build_editor()
        self.build_intro()
        self.build_update()
        self.build_progress()
        self.build_actions()
        self.win.present()
        self.keep_above()
        GLib.timeout_add_seconds(3, self.poll_status)
        try:
            self.start()
        except Exception as e:   # never a half-filled window
            self.error("Sekta kiosk: внутрішня помилка (%s: %s).\nЗапасні вікна: SEKTA_KIOSK_ZENITY=1 sekta-kiosk"
                       % (type(e).__name__, e), self.quit)
            raise

    def start(self):
        installed = self.installed()
        if "--install" in self.args and INSTALL_SRC:
            self.install_quit = not installed   # cancel: nothing to manage yet
            self.installer()
        elif not installed:
            if not INSTALL_SRC:
                self.error("Kiosk на цій машині не встановлено (або встановлено старою версією без екранів).\n"
                           "Встановіть його: пакет sekta-kiosk, пункт 7 pve-setup, kiosk/install.sh "
                           "або з флешки — bash sekta-kiosk.sh.", self.quit)
                return
            self.install_quit = True
            self.installer()
        else:
            self.show_manage()
            src = self.src_version()
            if INSTALL_SRC and src != "?" and newer(src, self.installed_version()):
                self.ask("Є новіша версія kiosk: %s (встановлено %s).\nОновити зараз? Екрани, сайти й "
                         "відкриті сторінки лишаться як є." % (src, self.installed_version()),
                         "Оновити", "Пізніше", lambda ok: ok and self.install_from_src())

    def installed(self):
        return os.access(SCREENS_BIN, os.X_OK) and os.path.isfile(CONF)

    def src_version(self):
        return read(os.path.join(INSTALL_SRC, "VERSION"), "?") if INSTALL_SRC else "?"

    def installed_version(self):
        return read(INSTALLED_VERSION_FILE, "0")

    def keep_above(self):
        """The kiosk windows are full screen: keep ours above them (X11)."""
        if os.environ.get("WAYLAND_DISPLAY") or not shutil.which("wmctrl"):
            return

        busy = []

        def tick():
            if busy:   # the previous round is still running (slow display)
                return True
            busy.append(1)

            def work():
                rc, o = run(["wmctrl", "-lx"])
                for line in o.splitlines() if rc == 0 else []:
                    f = line.split()
                    if len(f) > 2 and "sekta-kiosk" in f[2].lower():
                        run(["wmctrl", "-i", "-r", f[0], "-b", "add,above"])
                busy.clear()
            threading.Thread(target=work, daemon=True).start()
            return True
        tick()
        GLib.timeout_add_seconds(1, tick)

    def build_header(self):
        hb = Gtk.HeaderBar()
        hb.add_css_class("sk-head")
        box = hbox(12)
        box.append(logo(32))
        t = vbox(1)
        t.set_valign(Gtk.Align.CENTER)
        t.append(label(TITLE, ["sk-title"]))
        self.subtitle = label("", ["sk-sub"])
        t.append(self.subtitle)
        box.append(t)
        hb.pack_start(box)
        hb.set_title_widget(Gtk.Box())
        self.menu_btn = Gtk.MenuButton(icon_name="open-menu-symbolic")
        self.menu_btn.add_css_class("sk-btn")
        self.menu_btn.set_tooltip_text("Ще дії")
        hb.pack_end(self.menu_btn)
        self.toggle_btn = button("Зупинити", icon="media-playback-stop-symbolic", cb=self.toggle_kiosk)
        hb.pack_end(self.toggle_btn)
        self.restart_btn = button("Перезапустити", icon="view-refresh-symbolic", cb=self.restart_kiosk)
        hb.pack_end(self.restart_btn)
        self.pill = label("", ["sk-pill"])
        self.pill.set_valign(Gtk.Align.CENTER)
        hb.pack_end(self.pill)
        self.head_items = [self.menu_btn, self.toggle_btn, self.restart_btn, self.pill]
        self.win.set_titlebar(hb)

    def build_actions(self):
        menu = Gio.Menu()
        items = [("identify", "Визначити екрани", self.identify),
                 ("restore", "Повернути задані сайти", self.restore_sites),
                 ("update", "Оновити з файлу (.deb)…", self.update_from_deb),
                 ("diag", "Зібрати діагностику", self.collect_diag)]
        if INSTALL_SRC:
            items.append(("reinstall", "Перевстановити kiosk (%s)" % self.src_version(), self.install_from_src))
        for name, text, cb in items:
            a = Gio.SimpleAction.new(name, None)
            a.connect("activate", lambda *_a, cb=cb: cb())
            self.win.add_action(a)
            menu.append(text, "win." + name)
        self.menu_btn.set_menu_model(menu)

    def collect_diag(self):
        """kiosk-screens.sh --diag (+ this app's log) into ~/ and onto every
        writable stick under /media/$USER."""
        def work():
            name = time.strftime("sekta-kiosk-diag-%Y%m%d-%H%M%S.txt")
            rc, o = run([SCREENS_BIN, "--diag"])
            text = o + "\n== utility log %s\n%s\n" % (LOG_FILE, read(LOG_FILE) or "-")
            saved = []
            dirs = [os.path.expanduser("~")]
            media = os.path.join("/media", os.environ.get("USER", ""))
            if os.path.isdir(media):
                dirs += [os.path.join(media, d) for d in sorted(os.listdir(media))]
            for d in dirs:
                f = os.path.join(d, name)
                try:
                    with open(f, "w") as fh:
                        fh.write(text)
                    saved.append(f)
                except OSError:
                    pass
            if len(saved) > 1:
                run(["sync"])
            return text, saved

        def done(res):
            text, saved = res
            self.show_diag(text, saved)
        self.background(work, done)

    def show_diag(self, text, saved):
        """The report on screen, full-size — to photograph and send."""
        d = Gtk.Window(transient_for=self.win, modal=True, title=TITLE + " — діагностика")
        d.add_css_class("sk-dialog")
        box = vbox(10, margin=16)
        where = ("Файл: " + ", ".join(saved)) if saved else "Файл записати не вдалося."
        box.append(label("Сфотографуйте екран (прокрутіть, якщо не вмістилось) і надішліть розробнику. " + where,
                         ["sk-muted"], wrap=True))
        tv = Gtk.TextView(editable=False, cursor_visible=False, monospace=True)
        tv.add_css_class("sk-diag")
        tv.set_wrap_mode(Gtk.WrapMode.WORD_CHAR)
        tv.get_buffer().set_text(text)
        sc = Gtk.ScrolledWindow(vexpand=True, hexpand=True)
        sc.add_css_class("sk-logbox")
        sc.set_child(tv)
        box.append(sc)
        btns = hbox(10)
        btns.set_halign(Gtk.Align.END)
        btns.append(button("Оновити", "sk-btn", "view-refresh-symbolic", lambda: (d.destroy(), self.collect_diag())))
        btns.append(button("Закрити", "sk-primary", cb=d.destroy))
        box.append(btns)
        d.set_child(box)
        # the size of the monitor (no window manager may honour maximize)
        w, h = 1200, 800
        try:
            mons = Gdk.Display.get_default().get_monitors()
            if mons.get_n_items():
                g = mons.get_item(0).get_geometry()
                w, h = int(g.width * 0.96), int(g.height * 0.92)
        except Exception:
            pass
        d.set_default_size(w, h)
        d.maximize()
        d.present()

    def poll_status(self):
        """Kiosk state in the header — systemctl off the main loop."""
        if self.mode == "manage" and not getattr(self, "polling", False):
            self.polling = True

            def work():
                active = out(["systemctl", "--user", "is-active", SERVICE]) == "active"
                GLib.idle_add(lambda: self.show_status(active) and False)
            threading.Thread(target=work, daemon=True).start()
        return True

    def show_status(self, active):
        self.polling = False
        if self.mode == "manage":
            self.pill.set_label("Kiosk працює" if active else "Kiosk зупинений")
            if active:
                self.pill.remove_css_class("off")
            else:
                self.pill.add_css_class("off")
            box = self.toggle_btn.get_child()
            box.get_first_child().set_from_icon_name("media-playback-stop-symbolic" if active
                                                     else "media-playback-start-symbolic")
            box.get_last_child().set_label("Зупинити" if active else "Запустити")
            self.kiosk_active = active
        return True

    def set_subtitle(self):
        n = len(self.edit.screens)
        word = "екран" if n == 1 else "екрани"
        ver = self.installed_version() if self.mode == "manage" else self.src_version()
        self.subtitle.set_label("Kiosk-дисплей · %d %s · версія %s" % (n, word, ver))

    # --- main page: screens ---------------------------------------------------
    def build_main(self):
        page = hbox()
        left = vbox(14, margin=22)
        left.set_hexpand(True)
        top = hbox(12)
        self.main_title = label("Розташування екранів", ["sk-h1"])
        top.append(self.main_title)
        hint = label("Клацніть екран — його налаштування праворуч, подвійний клік — змінити", ["sk-muted"],
                     wrap=True)
        hint.set_hexpand(True)
        hint.set_valign(Gtk.Align.END)
        top.append(hint)
        left.append(top)

        ov = Gtk.Overlay()
        ov.add_css_class("sk-stage")
        ov.set_vexpand(True)
        self.stage = Gtk.DrawingArea()
        self.stage.set_draw_func(self.draw_stage)
        click = Gtk.GestureClick()
        click.connect("pressed", self.stage_click)
        self.stage.add_controller(click)
        ov.set_child(self.stage)
        tools = hbox(10)
        tools.set_halign(Gtk.Align.START)
        tools.set_valign(Gtk.Align.END)
        tools.set_margin_start(14)
        tools.set_margin_bottom(14)
        self.add_btn = button("Додати екран", "sk-dashed", "list-add-symbolic", self.add_screen)
        tools.append(self.add_btn)
        self.ident_btn = button("Визначити екрани", "sk-btn", "video-display-symbolic", self.identify)
        tools.append(self.ident_btn)
        ov.add_overlay(tools)
        left.append(ov)
        self.main_note = label("", ["sk-note"], wrap=True)
        left.append(self.main_note)
        page.append(left)

        aside = vbox(16, "sk-aside")
        aside.set_size_request(350, -1)
        inner = vbox(16, margin=22)
        inner.set_vexpand(True)
        aside.append(inner)
        head = hbox(12)
        self.badge = label("1", ["sk-badge"], xalign=0.5)
        head.append(self.badge)
        ht = vbox(2)
        ht.set_valign(Gtk.Align.CENTER)
        self.aside_title = label("Екран 1", ["sk-title"])
        self.aside_where = label("", ["sk-muted"])
        ht.append(self.aside_title)
        ht.append(self.aside_where)
        head.append(ht)
        inner.append(head)
        self.grid = Gtk.Grid(row_spacing=12, column_spacing=12)
        self.grid_vals = {}
        for r, key in enumerate(("Сайт", "Вихід", "Де стоїть", "Масштаб")):
            k = label(key, ["sk-muted"])
            k.set_valign(Gtk.Align.START)
            self.grid.attach(k, 0, r, 1, 1)
            v = label("", ellipsize=True)
            v.set_hexpand(True)
            v.set_selectable(False)
            if key == "Масштаб":
                # quick zoom of the selected screen: − value + and back to 100 %
                row = hbox(6)
                self.zoom_minus = button("−", "sk-btn", cb=lambda: self.zoom_step(-1))
                self.zoom_minus.set_tooltip_text("Дрібніше — більше вміщується")
                self.zoom_plus = button("+", "sk-btn", cb=lambda: self.zoom_step(1))
                self.zoom_plus.set_tooltip_text("Більше — для великого чи далекого екрана")
                self.zoom_reset = button("100 %", "sk-btn", cb=lambda: self.zoom_step(0))
                self.zoom_reset.set_tooltip_text("Звичайний масштаб")
                v.set_hexpand(False)
                v.set_xalign(0.5)
                v.set_width_chars(6)
                v.add_css_class("sk-title")
                row.append(self.zoom_minus)
                row.append(v)
                row.append(self.zoom_plus)
                row.append(self.zoom_reset)
                self.zoom_one = label("— (один екран)")
                row.append(self.zoom_one)
                self.grid.attach(row, 1, r, 1, 1)
                k.set_valign(Gtk.Align.CENTER)
            else:
                self.grid.attach(v, 1, r, 1, 1)
            self.grid_vals[key] = v
        inner.append(self.grid)
        self.edit_btn = button("Змінити екран", "sk-btn", "document-edit-symbolic", lambda: self.open_editor(self.sel))
        inner.append(self.edit_btn)
        self.remove_btn = button("Прибрати екран", "sk-btn", "user-trash-symbolic", self.remove_screen)
        inner.append(self.remove_btn)
        spacer = Gtk.Box()
        spacer.set_vexpand(True)
        inner.append(spacer)
        self.zoom_note = label("Масштаб кожного екрана — тут. Ctrl+/− у браузері змінює всі екрани разом.",
                               ["sk-note"], wrap=True)
        self.zoom_note.set_max_width_chars(30)
        inner.append(self.zoom_note)
        self.dirty_lab = label("Є незастосовані зміни", ["sk-warn"], wrap=True)
        inner.append(self.dirty_lab)
        row = hbox(10)
        row.set_halign(Gtk.Align.END)
        self.cancel_btn = button("Скасувати зміни", cb=self.cancel_changes)
        row.append(self.cancel_btn)
        self.apply_btn = button("Застосувати", "sk-primary", cb=self.apply_or_install)
        row.append(self.apply_btn)
        inner.append(row)
        page.append(aside)
        self.stack.add_named(page, "main")

    def show_manage(self):
        self.mode = "manage"
        self.conf = Conf.load()
        self.edit = self.conf.copy()
        self.sel = 0
        self.outputs, self.out_note = detect_outputs(self.ks)
        for w in self.head_items:
            w.set_visible(True)
        self.poll_status()
        self.refresh()
        self.stack.set_visible_child_name("main")

    def refresh(self):
        s = self.edit.screens
        n = len(s)
        self.sel = min(self.sel, n - 1)
        self.set_subtitle()
        cur = s[self.sel]
        got = assign_outputs(s, self.outputs)
        self.badge.set_label(str(self.sel + 1))
        self.aside_title.set_label("Екран %d" % (self.sel + 1))
        self.aside_where.set_label(self.where(self.sel))
        self.grid_vals["Сайт"].set_label(cur["url"])
        sizes = dict(self.outputs)
        o = cur["out"] if cur["out"] != "-" else "авто" + (" (%s)" % got[self.sel] if got[self.sel] else "")
        size = sizes.get(got[self.sel] or "", "")
        self.grid_vals["Вихід"].set_label(o + (" · " + size if size else ""))
        self.grid_vals["Де стоїть"].set_label(self.where(self.sel))
        z = cur["scale"]
        self.grid_vals["Масштаб"].set_label("%d %%" % z)
        for w in (self.zoom_minus, self.zoom_plus, self.zoom_reset, self.grid_vals["Масштаб"]):
            w.set_visible(n > 1)
        self.zoom_one.set_visible(n == 1)
        self.zoom_minus.set_sensitive(z > ZOOM_STEPS[0])
        self.zoom_plus.set_sensitive(z < ZOOM_STEPS[-1])
        self.zoom_reset.set_sensitive(z != 100)
        self.remove_btn.set_visible(n > 1)
        self.zoom_note.set_visible(n > 1)
        self.add_btn.set_sensitive(n < 3)
        self.add_btn.set_tooltip_text(None if n < 3 else "Щонайбільше 3 екрани")
        self.main_note.set_label(self.out_note)
        self.main_note.set_visible(bool(self.out_note))
        install = self.mode == "install"
        dirty = not self.edit.same(self.conf)
        self.dirty_lab.set_visible(dirty and not install)
        self.cancel_btn.set_label("Скасувати встановлення" if install else "Скасувати зміни")
        self.cancel_btn.set_visible(install or dirty)
        self.apply_btn.set_label("Встановити" if install else "Застосувати")
        self.apply_btn.set_sensitive(install or dirty)
        self.main_title.set_label("Екрани й сайти" if install else "Розташування екранів")
        self.stage.queue_draw()

    def zoom_step(self, d):
        """−1 / +1: the next step down / up; 0: back to 100 %."""
        sc = self.edit.screens[self.sel]
        z = sc["scale"]
        if d == 0:
            z = 100
        elif d > 0:
            z = next((v for v in ZOOM_STEPS if v > z), z)
        else:
            z = next((v for v in reversed(ZOOM_STEPS) if v < z), z)
        sc["scale"] = z
        self.refresh()

    def where(self, i):
        if i == 0:
            return "Головний"
        h = self.edit.screens[i]["hour"]
        return "%d год — %s" % (h, HOURS[h])

    def stage_geometry(self, width, height):
        s = self.edit.screens
        got = assign_outputs(s, self.outputs)
        sizes = dict(self.outputs)
        dims = []
        for i, sc in enumerate(s):
            wh = sizes.get(got[i] or "", "1920x1080")
            try:
                w, h = (int(v) for v in wh.split("x"))
            except ValueError:
                w, h = 1920, 1080
            z = sc["scale"] if len(s) > 1 else 100
            dims.append((max(1, round(w * 100 / z)), max(1, round(h * 100 / z))))
        rects = layout_rects(s, dims)
        minx = min(r[0] for r in rects)
        miny = min(r[1] for r in rects)
        maxx = max(r[0] + r[2] for r in rects)
        maxy = max(r[1] + r[3] for r in rects)
        pad, gap = 40, 14
        k = min((width - 2 * pad) / max(1, maxx - minx), (height - 2 * pad - 50) / max(1, maxy - miny), 0.2)
        k = max(k, 0.01)
        ox = (width - (maxx - minx) * k) / 2 - minx * k
        oy = (height - 50 - (maxy - miny) * k) / 2 - miny * k
        boxes = []
        for (x, y, w, h) in rects:
            boxes.append((ox + x * k + gap / 2, oy + y * k + gap / 2, w * k - gap, h * k - gap))
        return boxes, got

    def draw_stage(self, area, cr, width, height):
        rgb(cr, "#c7cab7")
        for x in range(11, width, 22):
            for y in range(11, height, 22):
                cr.rectangle(x, y, 1.2, 1.2)
        cr.fill()
        boxes, got = self.stage_geometry(width, height)
        self.boxes = boxes
        n = len(boxes)
        for i, (x, y, w, h) in enumerate(boxes):
            sc = self.edit.screens[i]
            on = i == self.sel
            if on:
                rounded(cr, x - 4, y - 4, w + 8, h + 8, 13)
                rgb(cr, "#5f6f34", 0.16)
                cr.fill()
            rounded(cr, x, y, w, h, 10)
            rgb(cr, "#d9e1c0" if on else "#f4f4ec")
            cr.fill_preserve()
            rgb(cr, "#5f6f34" if on else "#b6baa2")
            cr.set_line_width(2)
            cr.stroke()
            if h < 90 or w < 150:
                self.draw_small(cr, i, sc, x, y, w, h, n)
                continue
            fs = max(7.0, min(10.0, h / 14))
            o = sc["out"] if sc["out"] != "-" else "авто" + (" · " + got[i] if got[i] else "")
            self.text(cr, o, x + 12, y + 10, w - 24 - (60 if n > 1 else 0), fs, "#5f6352", mono=True)
            if n > 1:
                chip = "%d %%" % sc["scale"]
                lay = self.layout(cr, chip, fs, bold=True)
                tw, th = lay.get_pixel_size()
                cx = x + w - 12 - tw - 14
                rounded(cr, cx, y + 8, tw + 14, th + 6, (th + 6) / 2)
                rgb(cr, "#d6dfba")
                cr.fill()
                rgb(cr, "#4b5a26")
                cr.move_to(cx + 7, y + 11)
                PangoCairo.show_layout(cr, lay)
            big = max(14.0, min(44.0, h / 3.4))
            lay = self.layout(cr, str(i + 1), big, bold=True)
            tw, th = lay.get_pixel_size()
            rgb(cr, "#23271b")
            cr.move_to(x + 12, y + (h - th) / 2)
            PangoCairo.show_layout(cr, lay)
            self.text(cr, sc["url"], x + 12, y + h - fs * 1.6 - 12, w - 24, fs, "#4a4e3f")

    def draw_small(self, cr, i, sc, x, y, w, h, n):
        """A small box: its number (and zoom) only — the rest is on the right."""
        lay = self.layout(cr, str(i + 1), max(11.0, min(28.0, h / 2.6)), bold=True)
        tw, th = lay.get_pixel_size()
        chip = self.layout(cr, "%d %%" % sc["scale"], 7.5, bold=True) if n > 1 and h >= 46 else None
        ch = chip.get_pixel_size()[1] + 4 if chip else 0
        rgb(cr, "#23271b")
        cr.move_to(x + (w - tw) / 2, y + (h - th - ch) / 2)
        PangoCairo.show_layout(cr, lay)
        if chip:
            cw, cth = chip.get_pixel_size()
            cx, cy = x + (w - cw - 10) / 2, y + (h - th - ch) / 2 + th
            rounded(cr, cx, cy, cw + 10, cth + 4, (cth + 4) / 2)
            rgb(cr, "#d6dfba")
            cr.fill()
            rgb(cr, "#4b5a26")
            cr.move_to(cx + 5, cy + 2)
            PangoCairo.show_layout(cr, chip)

    def layout(self, cr, text, size, bold=False, mono=False):
        lay = PangoCairo.create_layout(cr)
        fd = Pango.FontDescription.from_string(("Monospace " if mono else "Sans ") + ("Bold " if bold else "")
                                               + "%.1f" % size)
        lay.set_font_description(fd)
        lay.set_text(text, -1)
        return lay

    def text(self, cr, text, x, y, w, size, color, mono=False):
        if w < 10:
            return
        lay = self.layout(cr, text, size, mono=mono)
        lay.set_width(int(w * Pango.SCALE))
        lay.set_ellipsize(Pango.EllipsizeMode.END)
        rgb(cr, color)
        cr.move_to(x, y)
        PangoCairo.show_layout(cr, lay)

    def stage_click(self, gesture, n_press, x, y):
        for i, (bx, by, bw, bh) in enumerate(getattr(self, "boxes", [])):
            if bx <= x <= bx + bw and by <= y <= by + bh:
                self.sel = i
                self.refresh()
                if n_press >= 2:
                    self.open_editor(i)
                return

    def add_screen(self):
        s = self.edit.screens
        if len(s) >= 3:
            return
        first = (s[0]["url"].split() or [DEFAULT_URL])[0]
        s[0]["url"] = first   # tabs are for one screen only
        s.append({"url": first, "hour": 3, "out": "-", "scale": 100})
        self.sel = len(s) - 1
        self.refresh()
        self.open_editor(self.sel)

    def remove_screen(self):
        s = self.edit.screens
        if len(s) <= 1:
            return
        k = self.sel

        def done(ok):
            if not ok:
                return
            del s[k]
            s[0]["hour"] = None   # the (new) screen 1 is the centre
            self.sel = 0
            self.refresh()
            if k == 0:
                self.info("Головним став колишній екран 2. Перевірте, де стоять інші екрани відносно нього.")
        self.ask("Прибрати екран %d (%s)?" % (k + 1, s[k]["url"]), "Прибрати", "Скасувати", done)

    def cancel_changes(self):
        if self.mode == "install":
            if self.install_quit:
                self.quit()
            else:
                self.show_manage()
            return
        self.edit = self.conf.copy()
        self.refresh()

    def apply_or_install(self):
        if self.mode == "install":
            self.run_install()
        else:
            self.apply_screens()

    # --- screen editor --------------------------------------------------------
    def build_editor(self):
        page = vbox()
        body = vbox(20, margin=24)
        body.set_vexpand(True)
        self.ed_title = label("Екран 2", ["sk-h1"])
        body.append(self.ed_title)

        grp = vbox(8)
        self.ed_site_lab = label("Сайт", ["sk-label"])
        grp.append(self.ed_site_lab)
        self.ed_site = Gtk.Entry()
        self.ed_site.add_css_class("sk-entry")
        grp.append(self.ed_site)
        body.append(grp)

        grp = vbox(8)
        grp.append(label("Вихід (монітор)", ["sk-label"]))
        self.ed_outs = hbox(10)
        grp.append(self.ed_outs)
        self.ed_out_note = label("", ["sk-muted"], wrap=True)
        grp.append(self.ed_out_note)
        body.append(grp)

        self.ed_place = hbox(24)
        clock = Gtk.Overlay()
        face = Gtk.DrawingArea()
        face.set_size_request(250, 250)
        face.set_draw_func(self.draw_clock)
        clock.set_child(face)
        fixed = Gtk.Fixed()
        self.hour_btns = {}
        group = None
        for h in range(1, 13):
            a = h * math.pi / 6
            b = Gtk.ToggleButton(label=str(h))
            b.add_css_class("sk-hour")
            b.set_size_request(36, 36)
            b.set_tooltip_text("%d год — %s" % (h, HOURS[h]))
            if group:
                b.set_group(group)
            group = group or b
            b.connect("toggled", self.hour_toggled, h)
            fixed.put(b, round(125 + 103 * math.sin(a) - 18), round(125 - 103 * math.cos(a) - 18))
            self.hour_btns[h] = b
        clock.add_overlay(fixed)
        clock.set_valign(Gtk.Align.CENTER)
        self.ed_place.append(clock)
        pt = vbox(8)
        pt.set_valign(Gtk.Align.CENTER)
        pt.append(label("Де стоїть відносно екрана 1", ["sk-label"]))
        self.ed_hour_text = label("", ["sk-big"])
        pt.append(self.ed_hour_text)
        pt.append(label("Година на циферблаті: 3 — праворуч, 9 — ліворуч, 12 — вище, 6 — нижче. "
                        "Однакова година у двох екранів — стають в ряд.", ["sk-muted"], wrap=True))
        pt.set_hexpand(True)
        self.ed_place.append(pt)
        body.append(self.ed_place)

        self.ed_zoom_box = vbox(10)
        zt = hbox(10)
        zt.append(label("Масштаб", ["sk-label"]))
        zt.append(label("лише цього екрана; Ctrl+/− у браузері змінює всі разом", ["sk-muted"]))
        self.ed_zoom_box.append(zt)
        self.ed_zooms = hbox(4, "sk-seg")
        self.ed_zooms.set_halign(Gtk.Align.START)
        self.ed_zoom_box.append(self.ed_zooms)
        body.append(self.ed_zoom_box)

        scroll = Gtk.ScrolledWindow(hscrollbar_policy=Gtk.PolicyType.NEVER)
        scroll.set_child(body)
        scroll.set_vexpand(True)
        page.append(scroll)
        foot = hbox(10, "sk-foot")
        foot.set_halign(Gtk.Align.FILL)
        inner = hbox(10)
        inner.set_hexpand(True)
        inner.set_halign(Gtk.Align.END)
        for side in ("top", "bottom"):
            getattr(inner, "set_margin_" + side)(14)
        inner.set_margin_end(24)
        inner.append(button("Скасувати", cb=lambda: self.stack.set_visible_child_name("main")))
        inner.append(button("Готово", "sk-primary", cb=self.editor_done))
        foot.append(inner)
        page.append(foot)
        self.stack.add_named(page, "editor")

    def draw_clock(self, area, cr, w, h):
        cr.set_line_width(1)
        cr.set_dash([4, 4])
        rgb(cr, "#b6baa2")
        cr.arc(125, 125, 103, 0, 2 * math.pi)
        cr.stroke()
        cr.set_dash([])
        rounded(cr, 85, 98, 80, 54, 8)
        rgb(cr, "#d9e1c0")
        cr.fill_preserve()
        rgb(cr, "#8f9b6a")
        cr.set_line_width(2)
        cr.stroke()
        lay = self.layout(cr, "1", 16, bold=True)
        tw, th = lay.get_pixel_size()
        rgb(cr, "#4b5a26")
        cr.move_to(125 - tw / 2, 125 - th / 2)
        PangoCairo.show_layout(cr, lay)

    def hour_toggled(self, b, h):
        if b.get_active():
            self.ed_hour = h
            self.ed_hour_text.set_label("%d год — %s" % (h, HOURS[h]))

    def open_editor(self, i):
        s = self.edit.screens
        if i >= len(s):
            return
        self.ed_i = i
        sc = s[i]
        n = len(s)
        self.ed_title.set_label("Екран %d" % (i + 1))
        self.ed_site_lab.set_label("Сайт" if n > 1 else "Сайт. Кілька сайтів — через пробіл, відкриються вкладками")
        self.ed_site.set_text(sc["url"])
        # outputs
        clear(self.ed_outs)
        got = assign_outputs(s, self.outputs)
        self.ed_out = sc["out"]
        group = None
        opts = [("-", "Авто", "основний або наступний вільний")]
        for name, size in self.outputs:
            owner = [k + 1 for k, o in enumerate(s) if k != i and (o["out"] == name or got[k] == name)]
            opts.append((name, name, size + (" · у екрана %d" % owner[0] if owner else "")))
        if sc["out"] != "-" and sc["out"] not in [n_ for n_, _ in self.outputs]:
            opts.append((sc["out"], sc["out"], "не підключений"))
        for val, title, note in opts:
            b = Gtk.ToggleButton()
            b.add_css_class("sk-card")
            c = vbox(3)
            c.append(label(title, mono=val != "-"))
            c.append(label(note, ["sk-muted"]))
            b.set_child(c)
            if group:
                b.set_group(group)
            group = group or b
            b.set_active(val == sc["out"])
            b.connect("toggled", lambda btn, v=val: btn.get_active() and setattr(self, "ed_out", v))
            self.ed_outs.append(b)
        self.ed_out_note.set_label(self.out_note or "«Визначити екрани» показує назву виходу на кожному моніторі.")
        # place
        self.ed_place.set_visible(i > 0)
        if i > 0:
            self.ed_hour = sc["hour"] or 3
            self.hour_btns[self.ed_hour].set_active(True)
            self.ed_hour_text.set_label("%d год — %s" % (self.ed_hour, HOURS[self.ed_hour]))
        # zoom
        self.ed_zoom_box.set_visible(n > 1)
        clear(self.ed_zooms)
        self.ed_zoom = sc["scale"]
        group = None
        for z in sorted(set(ZOOMS + [sc["scale"]])):
            b = Gtk.ToggleButton(label="%d %%" % z)
            b.add_css_class("sk-zoom")
            if group:
                b.set_group(group)
            group = group or b
            b.set_active(z == sc["scale"])
            b.connect("toggled", lambda btn, v=z: btn.get_active() and setattr(self, "ed_zoom", v))
            self.ed_zooms.append(b)
        self.stack.set_visible_child_name("editor")
        self.ed_site.grab_focus_without_selecting()

    def editor_done(self):
        s = self.edit.screens
        i = self.ed_i
        words = self.ed_site.get_text().split()
        if not words:
            self.error("Вкажіть сайт.")
            return
        if len(s) > 1 and len(words) > 1:
            self.error("Кілька сайтів вкладками — лише коли екран один. Для кожного з кількох екранів — один сайт.")
            return
        sc = s[i]
        sc["url"] = " ".join(words)
        moved = []
        if self.ed_out != "-":
            # one monitor, one screen: the screen that had this output → «авто»
            for k, o in enumerate(s):
                if k != i and o["out"] == self.ed_out:
                    o["out"] = "-"
                    moved.append(k + 1)
        sc["out"] = self.ed_out
        if i > 0:
            sc["hour"] = self.ed_hour
        if len(s) > 1:
            sc["scale"] = self.ed_zoom
        self.sel = i
        self.refresh()
        self.stack.set_visible_child_name("main")
        if moved:
            self.info("Вихід %s був у екрана %d — йому тепер «авто»." % (self.ed_out, moved[0]))

    # --- kiosk control --------------------------------------------------------
    def ks_stop(self):
        run(["systemctl", "--user", "stop", SERVICE])

    def ks_start(self):
        if run([START_BIN])[0] != 0:
            run(["systemctl", "--user", "start", SERVICE])

    def background(self, work, done=None):
        """work() in a thread, done(result) back in the window."""
        self.set_busy(True)

        def wrap():
            try:
                r = work()
            except Exception as e:   # never a window stuck insensitive
                msg = "%s: %s" % (type(e).__name__, e)
                GLib.idle_add(lambda: (self.set_busy(False), self.error("Не вдалося: " + msg)) and False)
                return
            GLib.idle_add(lambda: (self.set_busy(False), done and done(r)) and False)
        threading.Thread(target=wrap, daemon=True).start()

    def set_busy(self, on):
        self.busy = on
        self.stack.set_sensitive(not on)
        for w in self.head_items:
            w.set_sensitive(not on)
        self.win.set_cursor(Gdk.Cursor.new_from_name("wait") if on else None)

    def restart_kiosk(self):
        self.background(lambda: (self.ks_stop(), self.ks_start()), lambda _r: self.poll_status())

    def toggle_kiosk(self):
        if getattr(self, "kiosk_active", False):
            self.background(self.ks_stop, lambda _r: self.poll_status())
        else:
            self.background(self.ks_start, lambda _r: self.poll_status())

    def restore_sites(self):
        def go(ok):
            if ok:
                self.background(lambda: (self.ks_stop(), run([SCREENS_BIN, "--reset"]), self.ks_start()),
                                lambda _r: self.poll_status())
        self.ask("Забути відкриті сторінки на всіх екранах і відкрити задані сайти?", "Повернути", "Скасувати", go)

    def run_root(self, *args):
        if not shutil.which("pkexec"):
            return False, "Немає pkexec. Виконайте в терміналі:\nsudo bash %s %s" % (SCREENS_BIN, " ".join(args))
        rc, o = run(["pkexec", "/bin/bash", SCREENS_BIN] + list(args))
        return rc == 0, o

    def apply_screens(self):
        new = self.edit.copy()
        before = self.conf.key()   # normalised: OUTPUTS=() equals its "- -" rewrite

        def work():
            env = dict(os.environ, **new.env())
            self.ks_stop()
            rc, o = run([SCREENS_BIN, "--write-conf"], env=env)
            if rc != 0:
                self.ks_start()
                return {"fatal": "Не збережено: " + o.strip()}
            conf = Conf.load()
            # any change of screens or sites: forget the remembered pages —
            # restored windows go to the nearest screen, after a new layout that
            # is the wrong one (the kiosk is stopped: Chromium saves on exit)
            if conf.key() != before:
                run([SCREENS_BIN, "--reset"])
            n = len(conf.screens)
            gdm = out([SCREENS_BIN, "--gdm-status"])
            res = {"reboot": False, "msg": "", "err": ""}
            # several screens need GNOME on Xorg; one screen gives Wayland back
            if n > 1 and gdm != "no-gdm":
                if gdm == "wayland":
                    ok, o = self.run_root("--gdm", "x11")
                    if ok:
                        res["reboot"] = True
                    elif not shutil.which("pkexec"):
                        res["err"] = o
                    else:   # password window cancelled / refused
                        res["err"] = ("GNOME не переведено на X11 (пароль адміністратора не введено?) — кілька "
                                      "екранів не розставляться. Натисніть «Застосувати» ще раз.")
                elif os.environ.get("XDG_SESSION_TYPE") == "wayland":
                    res["reboot"] = True   # already switched, not rebooted yet
            elif n == 1 and gdm == "x11-ours":
                if self.run_root("--gdm", "wayland")[0]:
                    res["msg"] = "Один екран: GNOME повернеться на Wayland після наступного перезавантаження."
            if not res["reboot"]:
                self.ks_start()
            return res

        def done(res):
            self.show_manage()
            if res.get("fatal"):
                self.error(res["fatal"])
                return
            if res.get("err"):
                self.error(res["err"])
            if res.get("reboot"):
                self.ask("Для кількох екранів GNOME має працювати на X11 — це почне діяти після "
                         "перезавантаження.\n\nПерезавантажити зараз?", "Перезавантажити", "Пізніше",
                         lambda ok: run(["systemctl", "reboot"]) if ok else self.background(self.ks_start))
            else:
                self.info((res["msg"] + "\n\n" if res.get("msg") else "") + "Збережено, kiosk перезапущено.")
        self.background(work, done)

    # --- identify screens -----------------------------------------------------
    def identify(self):
        num = {}
        for line in read(MAP_FILE).splitlines():
            f = line.split()
            if len(f) >= 2:
                num[f[1]] = f[0]
                if len(f) >= 4:
                    num["@%s,%s" % (f[2], f[3])] = f[0]
        mons = Gdk.Display.get_default().get_monitors()
        wins = []
        for k in range(mons.get_n_items()):
            m = mons.get_item(k)
            g = m.get_geometry()
            name = (m.get_connector() if hasattr(m, "get_connector") else None) or "монітор %d" % (k + 1)
            n = num.get(name) or num.get("@%d,%d" % (g.x, g.y))
            w = Gtk.Window(title="sekta-id " + name, decorated=False)
            w.add_css_class("sk-ident")
            box = vbox(18)
            box.set_valign(Gtk.Align.CENTER)
            box.set_halign(Gtk.Align.CENTER)
            box.append(label("Екран %s" % n if n else name, ["sk-ident-num"], xalign=0.5))
            box.append(label(name, ["sk-ident-out"], xalign=0.5))
            box.append(label("%d×%d · клацніть, щоб закрити" % (g.width, g.height), xalign=0.5))
            w.set_child(box)
            click = Gtk.GestureClick()
            click.connect("pressed", lambda *_: close())
            w.add_controller(click)
            w.fullscreen_on_monitor(m)
            w.present()
            wins.append(w)

        def close():
            for w in wins:
                w.destroy()
            wins.clear()
            return False
        GLib.timeout_add_seconds(8, close)

    # --- dialogs --------------------------------------------------------------
    def dialog(self, text, buttons, cb=None, error=False):
        """buttons: [(label, value, primary)]; cb(value) — None when closed."""
        d = Gtk.Window(transient_for=self.win, modal=True, title=TITLE, resizable=False)
        d.add_css_class("sk-dialog")
        d.set_default_size(480, -1)
        box = vbox(18, margin=24)
        row = hbox(14)
        if error:
            img = Gtk.Image.new_from_icon_name("dialog-warning-symbolic")
            img.set_pixel_size(28)
            img.set_valign(Gtk.Align.START)
            row.append(img)
        lab = label(text, wrap=True)
        lab.set_max_width_chars(60)
        lab.set_selectable(error)   # an error's command can be copied
        row.append(lab)
        box.append(row)
        btns = hbox(10)
        btns.set_halign(Gtk.Align.END)
        fired = []

        def fire(v):
            if fired:
                return
            fired.append(v)
            d.destroy()
            if cb:
                cb(v)
        default = None
        for text_, val, primary in buttons:
            b = button(text_, "sk-primary" if primary else "sk-btn", cb=lambda v=val: fire(v))
            btns.append(b)
            if primary:
                default = b
        box.append(btns)
        d.set_child(box)
        if default:
            d.set_default_widget(default)
            default.grab_focus()
        d.connect("close-request", lambda *_: (fire(None), True)[1])   # fire() destroys it
        d.present()
        return d

    def with_sudo(self, go):
        """go(t): t = the sudo dir — after the admin password, asked and
        checked in our own window (empty when sudo needs none)."""
        # handed over by the update from a .deb (exec of the new installer):
        # the same password, not asked twice
        d = os.environ.pop("SEKTA_KIOSK_SUDO_DIR", "")
        if d and os.path.isfile(os.path.join(d, "askpass")) and os.stat(d).st_uid == os.getuid():
            go(d)
            return
        # no password at all (NOPASSWD): -k so a sign-in sudo still remembers
        # (e.g. an apt install in a terminal a minute ago) does not count —
        # the scripts' own sudo would not have it and got an empty password
        if run(["sudo", "-n", "-k", "true"])[0] == 0:
            go(sudo_dir(""))
            return
        self.ask_password(go)

    def ask_password(self, go, wrong=False):
        d = Gtk.Window(transient_for=self.win, modal=True, title=TITLE + " — пароль адміністратора",
                       resizable=False)
        d.add_css_class("sk-dialog")
        d.set_default_size(440, -1)
        box = vbox(16, margin=24)
        row = hbox(14)
        row.append(logo(40))
        t = vbox(4)
        t.append(label("Пароль адміністратора", ["sk-title"]))
        t.append(label("Ваш пароль входу (sudo, користувач %s)." % os.environ.get("USER", ""),
                       ["sk-muted"], wrap=True))
        row.append(t)
        box.append(row)
        e = Gtk.PasswordEntry(show_peek_icon=True)
        e.add_css_class("sk-entry")
        box.append(e)
        err = label("Пароль не підійшов — спробуйте ще раз." if wrong else "", ["sk-err"])
        err.set_visible(wrong)
        box.append(err)
        btns = hbox(10)
        btns.set_halign(Gtk.Align.END)
        ok_btn = button("Гаразд", "sk-primary")

        def ok(*_):
            pw = e.get_text()
            d.destroy()

            def check():
                return sudo_check(pw)

            def checked(good):
                if good:
                    go(sudo_dir(pw))
                else:
                    self.ask_password(go, wrong=True)
            self.background(check, checked)
        ok_btn.connect("clicked", ok)
        e.connect("activate", ok)
        btns.append(button("Скасувати", cb=d.destroy))
        btns.append(ok_btn)
        box.append(btns)
        d.set_child(box)
        d.set_default_widget(ok_btn)
        d.present()
        e.grab_focus()

    def info(self, text, cb=None):
        self.dialog(text, [("Гаразд", True, True)], cb and (lambda _v: cb()))

    def error(self, text, cb=None):
        self.dialog(text, [("Гаразд", True, True)], cb and (lambda _v: cb()), error=True)

    def ask(self, text, ok, cancel, cb):
        self.dialog(text, [(cancel, False, False), (ok, True, True)], lambda v: cb(bool(v)))

    # --- progress page (install / update) ------------------------------------
    def build_progress(self):
        page = hbox()
        left = vbox(24, "sk-left")
        left.set_size_request(380, -1)
        li = vbox(22, margin=40)
        li.set_vexpand(True)
        li.append(logo(120))
        li.get_first_child().set_halign(Gtk.Align.START)
        self.pr_title = label("", ["sk-h1"], wrap=True)
        li.append(self.pr_title)
        self.pr_text = label("", ["sk-dim"], wrap=True)
        li.append(self.pr_text)
        self.pr_chips = hbox(8)
        li.append(self.pr_chips)
        sp = Gtk.Box()
        sp.set_vexpand(True)
        li.append(sp)
        self.pr_ver = label("", ["sk-muted"])
        li.append(self.pr_ver)
        left.append(li)
        page.append(left)

        right = vbox(22, margin=40)
        right.set_hexpand(True)
        self.pr_steps = vbox(4)
        right.append(self.pr_steps)
        st = hbox()
        self.pr_status = label("", ellipsize=True)
        self.pr_status.set_hexpand(True)
        st.append(self.pr_status)
        right.append(st)
        self.pr_bar = Gtk.ProgressBar()
        self.pr_bar.add_css_class("sk-bar")
        right.append(self.pr_bar)
        self.pr_log = Gtk.TextView(editable=False, cursor_visible=False, monospace=True)
        self.pr_log.add_css_class("sk-log")
        self.pr_log.set_wrap_mode(Gtk.WrapMode.WORD_CHAR)
        for side in ("top", "bottom", "left", "right"):
            getattr(self.pr_log, "set_%s_margin" % side)(12)
        self.pr_scroll = Gtk.ScrolledWindow()
        self.pr_scroll.add_css_class("sk-logbox")
        self.pr_scroll.set_child(self.pr_log)
        self.pr_scroll.set_vexpand(True)
        right.append(self.pr_scroll)
        foot = hbox(10)
        self.pr_logpath = label("Журнал: " + LOG_FILE.replace(HOME, "~"), ["sk-muted"], ellipsize=True)
        self.pr_logpath.set_hexpand(True)
        foot.append(self.pr_logpath)
        self.pr_btns = hbox(10)
        foot.append(self.pr_btns)
        right.append(foot)
        page.append(right)
        self.stack.add_named(page, "progress")

    def progress(self, title, text, chips, steps, ver):
        self.pr_title.set_label(title)
        self.pr_text.set_label(text)
        clear(self.pr_chips)
        for c in chips:
            self.pr_chips.append(label(c, ["sk-chip"]))
        self.pr_ver.set_label(ver)
        self.steps = []
        clear(self.pr_steps)
        for i, s in enumerate(steps):
            row = hbox(14, "sk-row")
            row.set_size_request(-1, 48)
            mark = label(str(i + 1), xalign=0.5)
            mark.set_valign(Gtk.Align.CENTER)
            row.append(mark)
            t = label(s)
            t.set_hexpand(True)
            row.append(t)
            note = label("", ["sk-muted"])
            row.append(note)
            self.pr_steps.append(row)
            self.steps.append((row, mark, t, note))
        self.pr_log.get_buffer().set_text("")
        self.pr_status.set_label("")
        self.pr_status.remove_css_class("sk-err")
        self.pr_bar.set_fraction(0)
        clear(self.pr_btns)
        for w in self.head_items:
            w.set_visible(False)
        self.stack.set_visible_child_name("progress")

    def step(self, i, state, note=""):
        """state: done | now | todo | fail"""
        for k, (row, mark, t, n) in enumerate(self.steps):
            if k != i:
                continue
            for c in ("sk-step-done", "sk-step-now", "sk-step-todo", "sk-step-fail"):
                mark.remove_css_class(c)
            mark.add_css_class("sk-step-" + state)
            mark.set_label({"done": "✓", "fail": "!"}.get(state, str(k + 1)))
            if state == "now":
                row.add_css_class("sk-row-now")
            else:
                row.remove_css_class("sk-row-now")
            t.remove_css_class("sk-muted")
            if state == "todo":
                t.add_css_class("sk-muted")
            n.set_label(note)

    def log_line(self, line):
        buf = self.pr_log.get_buffer()
        buf.insert(buf.get_end_iter(), line + "\n")
        if buf.get_line_count() > 400:
            it = buf.get_iter_at_line(buf.get_line_count() - 400)   # GTK 4: (ok, iter)
            buf.delete(buf.get_start_iter(), it[1] if isinstance(it, tuple) else it)
        adj = self.pr_scroll.get_vadjustment()
        GLib.idle_add(lambda: adj.set_value(adj.get_upper()) and False)
        s = line.strip()
        if s:
            self.pr_status.set_label(re.sub(r"^(==>|\[[!x]\])\s*", "", s))

    def stream(self, cmd, env, cwd, done):
        """Run cmd, its output into the log view + LOG_FILE; done(rc)."""
        pulse = [GLib.timeout_add(120, lambda: (self.pr_bar.pulse(), True)[1])]

        def work():
            rc = 1
            try:
                with open(LOG_FILE, "w") as log:
                    p = subprocess.Popen(cmd, env=env, cwd=cwd, stdin=subprocess.DEVNULL,
                                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                                         errors="replace", bufsize=1)

                    def reader():
                        for line in p.stdout:
                            line = ANSI.sub("", line.rstrip("\n"))
                            log.write(line + "\n")
                            log.flush()
                            GLib.idle_add(lambda ln=line: self.log_line(ln) and False)
                    r = threading.Thread(target=reader, daemon=True)
                    r.start()
                    # done when the command ends — a daemon it started may keep
                    # the output pipe open for good
                    rc = p.wait()
                    r.join(3)
            except OSError as e:
                GLib.idle_add(lambda: self.log_line(str(e)) and False)

            def fin():
                GLib.source_remove(pulse[0])
                self.pr_bar.set_fraction(1.0 if rc == 0 else 0.0)
                done(rc)
                return False
            GLib.idle_add(fin)
        threading.Thread(target=work, daemon=True).start()

    def pr_buttons(self, items):
        clear(self.pr_btns)
        for text, primary, cb in items:
            self.pr_btns.append(button(text, "sk-primary" if primary else "sk-btn", cb=cb))

    # --- installer ------------------------------------------------------------
    def build_intro(self):
        page = hbox()
        left = vbox(0, "sk-left")
        left.set_size_request(380, -1)
        li = vbox(22, margin=40)
        li.set_vexpand(True)
        lg = logo(120)
        lg.set_halign(Gtk.Align.START)
        li.append(lg)
        li.append(label("Встановлення kiosk-дисплея", ["sk-h1"], wrap=True))
        li.append(label("Екран завантаження з логотипом, Chromium на весь екран на кожному моніторі, автовхід, "
                        "українська розкладка, без засинання; утиліта «Sekta kiosk — екрани» (Ctrl+Alt+K).",
                        ["sk-dim"], wrap=True))
        self.in_chips = hbox(8)
        li.append(self.in_chips)
        sp = Gtk.Box()
        sp.set_vexpand(True)
        li.append(sp)
        self.in_ver = label("", ["sk-muted"])
        li.append(self.in_ver)
        left.append(li)
        page.append(left)
        right = vbox(18, margin=40)
        right.set_hexpand(True)
        right.set_valign(Gtk.Align.CENTER)
        self.in_head = label("", ["sk-big"], wrap=True)
        right.append(self.in_head)
        self.in_text = label("", ["sk-dim"], wrap=True)
        right.append(self.in_text)
        row = hbox(10)
        row.set_halign(Gtk.Align.START)
        row.set_margin_top(10)
        self.in_cancel = button("Скасувати", cb=self.cancel_changes)
        row.append(self.in_cancel)
        row.append(button("Далі — екрани й сайти", "sk-primary", cb=self.install_screens))
        right.append(row)
        page.append(right)
        self.stack.add_named(page, "intro")

    def chips(self):
        rel, arch = bundle_name()
        names = {"bookworm": "Debian 12 «bookworm»", "trixie": "Debian 13 «trixie»"}
        return ["Без інтернету", names.get(rel, rel), arch]

    def installer(self):
        rel, arch = bundle_name()
        bn = "%s-%s" % (rel, arch)
        debs = os.path.join(INSTALL_SRC, "debs")
        if not os.path.isdir(os.path.join(debs, bn)) and not os.path.isfile(os.path.join(debs, "BUNDLE")):
            have = " ".join(sorted(d for d in (os.listdir(debs) if os.path.isdir(debs) else [])
                                   if os.path.isdir(os.path.join(debs, d))))
            self.error("Немає пакетів для цієї машини (%s) у %s.\nЄ: %s\nПотрібен пакет sekta-kiosk для %s "
                       "(build-deb.sh) або набір fetch-debs.sh з такої машини." % (bn, debs, have or "—", bn),
                       self.after_install_cancel)
            return
        if not has_sudo():
            self.error(sudo_hint(), self.after_install_cancel)
            return
        self.mode = "install"
        self.conf = Conf.load()   # a reinstall starts from this machine's settings
        self.edit = self.conf.copy()
        self.before_key = self.conf.key()
        self.outputs, self.out_note = detect_outputs(self.ks)
        self.sel = 0
        for w in self.head_items:
            w.set_visible(False)
        self.set_subtitle()
        clear(self.in_chips)
        for c in self.chips():
            self.in_chips.append(label(c, ["sk-chip"]))
        self.in_ver.set_label("Sekta kiosk " + self.src_version())
        if self.installed() and self.installed_version() == self.src_version():
            self.in_head.set_label("Перевстановлення kiosk %s" % self.src_version())
            self.in_text.set_label("Екрани, сайти й відкриті сторінки лишаться як є — далі можна їх перевірити.")
        elif self.installed():
            self.in_head.set_label("Оновлення kiosk до версії %s" % self.src_version())
            self.in_text.set_label("Встановлено %s. Екрани, сайти й відкриті сторінки лишаться як є — далі можна "
                                   "їх перевірити." % self.installed_version())
        else:
            self.in_head.set_label("Без інтернету, з пакетів на цьому носії")
            self.in_text.set_label("Далі — екрани й сайти: скільки моніторів, де вони стоять і що показують. "
                                   "Пароль адміністратора утиліта спитає перед встановленням.")
        self.stack.set_visible_child_name("intro")

    def after_install_cancel(self):
        if self.install_quit:
            self.quit()
        else:
            self.show_manage()

    def install_screens(self):
        self.refresh()
        self.stack.set_visible_child_name("main")

    def run_install(self):
        self.with_sudo(self.run_install_with)

    def run_install_with(self, t):
        env = dict(os.environ, **self.edit.env())
        installed = self.installed()
        # same screens and sites: keep the remembered pages; an installed kiosk
        # is overwritten in place, not torn down under the running session
        env.pop("KIOSK_KEEP_PAGES", None)
        env.pop("REINSTALL", None)
        if installed and self.edit.key() == self.before_key:
            env["KIOSK_KEEP_PAGES"] = "1"
        if installed:
            env["REINSTALL"] = "keep"
        sudo_env(env, t)
        n = len(self.edit.screens)
        self.progress("Встановлення kiosk-дисплея", "Не вимикайте машину, доки не завершиться.", self.chips(),
                      ["Екрани й сайти", "Встановлення", "Перезавантаження"], "Sekta kiosk " + self.src_version())
        self.step(0, "done", "%d %s" % (n, "екран" if n == 1 else "екрани"))
        self.step(1, "now", "триває…")
        self.step(2, "todo")

        def done(rc):
            shutil.rmtree(t, ignore_errors=True)
            if rc != 0:
                self.step(1, "fail", "помилка")
                self.pr_status.set_label("Помилка встановлення — подробиці в журналі нижче.")
                self.pr_status.add_css_class("sk-err")
                self.pr_buttons([("Закрити", False, self.quit), ("Назад до екранів", True, self.install_screens)])
                return
            self.pr_status.remove_css_class("sk-err")
            self.step(1, "done", "готово")
            self.step(2, "now", "потрібне")
            self.pr_status.set_label("Kiosk встановлено. Він запуститься після перезавантаження.")
            self.install_quit = False
            self.pr_buttons([("Пізніше", False, self.show_manage),
                             ("Перезавантажити", True, lambda: run(["systemctl", "reboot"]))])
        self.stream(["bash", "./install-offline.sh"], env, INSTALL_SRC, done)

    def install_from_src(self):
        """(Re)install with the app that came with the installer: the copy in
        ~/.local/bin (the hotkey) may be older than the package's installer."""
        src_app = os.path.realpath(os.path.join(INSTALL_SRC, "sekta-kiosk.sh"))
        if APP_SH and src_app != os.path.realpath(APP_SH):
            os.execvp("bash", ["bash", src_app, "--install"])
        self.installer()

    # --- update from a .deb (e.g. on a stick) --------------------------------
    def build_update(self):
        page = vbox()
        body = vbox(20, margin=28)
        body.set_vexpand(True)
        body.append(label("Оновлення з файлу", ["sk-h1"]))
        card = hbox(14, "sk-note")
        img = Gtk.Image.new_from_icon_name("package-x-generic-symbolic")
        img.set_pixel_size(28)
        card.append(img)
        ct = vbox(3)
        ct.set_hexpand(True)
        self.up_file = label("", mono=True, ellipsize=True)
        self.up_where = label("", ["sk-muted"], ellipsize=True)
        ct.append(self.up_file)
        ct.append(self.up_where)
        card.append(ct)
        other = button("Інший файл…", cb=self.update_from_deb)
        other.set_valign(Gtk.Align.CENTER)
        card.append(other)
        body.append(card)
        vers = hbox(26)
        vers.set_halign(Gtk.Align.CENTER)
        vers.set_margin_top(8)
        a = vbox(4)
        a.append(label("Встановлено", ["sk-muted"], xalign=0.5))
        self.up_cur = label("", ["sk-big", "sk-dim"], xalign=0.5)
        a.append(self.up_cur)
        vers.append(a)
        arrow = Gtk.Image.new_from_icon_name("go-next-symbolic")
        arrow.set_pixel_size(28)
        vers.append(arrow)
        b = vbox(4)
        b.append(label("Новий", ["sk-muted"], xalign=0.5))
        self.up_new = label("", ["sk-big"], xalign=0.5)
        b.append(self.up_new)
        vers.append(b)
        body.append(vers)
        self.up_checks = hbox(10)
        self.up_checks.set_homogeneous(True)
        body.append(self.up_checks)
        self.up_text = label("", ["sk-dim"], wrap=True)
        body.append(self.up_text)
        page.append(body)
        foot = hbox(10, "sk-foot")
        inner = hbox(10)
        inner.set_hexpand(True)
        inner.set_halign(Gtk.Align.END)
        for side in ("top", "bottom"):
            getattr(inner, "set_margin_" + side)(14)
        inner.set_margin_end(24)
        inner.append(button("Скасувати", cb=self.show_manage))
        self.up_go = button("Оновити", "sk-primary", cb=self.update_go)
        inner.append(self.up_go)
        foot.append(inner)
        page.append(foot)
        self.stack.add_named(page, "update")

    def update_from_deb(self):
        start = "/media/" + os.environ.get("USER", "")
        if not os.path.isdir(start):
            start = HOME
        ch = Gtk.FileChooserNative(title=TITLE + " — пакет sekta-kiosk (.deb)", transient_for=self.win,
                                   action=Gtk.FileChooserAction.OPEN, accept_label="Вибрати",
                                   cancel_label="Скасувати")
        f1 = Gtk.FileFilter()
        f1.set_name("Пакет sekta-kiosk")
        f1.add_pattern("sekta-kiosk*.deb")
        f2 = Gtk.FileFilter()
        f2.set_name("Усі .deb")
        f2.add_pattern("*.deb")
        ch.add_filter(f1)
        ch.add_filter(f2)
        try:
            ch.set_current_folder(Gio.File.new_for_path(start))
        except GLib.Error:
            pass

        def resp(dlg, r):
            self.chooser = None
            if r == Gtk.ResponseType.ACCEPT and dlg.get_file():
                self.check_deb(dlg.get_file().get_path())
        ch.connect("response", resp)
        self.chooser = ch   # keep a reference until it answers
        ch.show()

    def check_deb(self, f):
        if not f or not os.path.isfile(f):
            return
        base = os.path.basename(f)
        pkg = out(["dpkg-deb", "-f", f, "Package"])
        if pkg != "sekta-kiosk":
            self.error("%s — не пакет sekta-kiosk%s." % (base, " (це %s)" % pkg if pkg else ""))
            return
        arch = out(["dpkg-deb", "-f", f, "Architecture"])
        ver = out(["dpkg-deb", "-f", f, "Version"])
        myrel, myarch = bundle_name()
        rel = ver.rsplit("+", 1)[1] if "+" in ver else ""
        want = "Потрібен sekta-kiosk_…+%s_%s.deb." % (myrel, myarch)
        if arch not in (myarch, "all"):
            self.error("Пакет для %s, а ця машина — %s. %s" % (arch, myarch, want))
            return
        if rel and myrel != "unknown" and rel != myrel:
            self.error("Пакет для Debian «%s», а ця машина — «%s». %s" % (rel, myrel, want))
            return
        if not has_sudo():
            self.error(sudo_hint())
            return
        cur = out(["dpkg-query", "-W", "-f=${Version}", "sekta-kiosk"])
        self.up_extra = []
        go = "Оновити"
        text = "Екрани, сайти, масштаб і відкриті сторінки лишаться як є. Пароль адміністратора утиліта спитає перед встановленням."
        if cur and run(["dpkg", "--compare-versions", ver, "eq", cur])[0] == 0:
            self.up_extra, go = ["--reinstall"], "Перевстановити"
            text = "Ця версія вже встановлена — пакет і kiosk буде встановлено ще раз. " + text
        elif cur and run(["dpkg", "--compare-versions", ver, "lt", cur])[0] == 0:
            self.up_extra, go = ["--allow-downgrades"], "Встановити старішу"
            text = "Це старіша версія, ніж встановлена. " + text
        self.up_path = f
        self.up_file.set_label(base)
        try:
            size = "%d МБ" % round(os.path.getsize(f) / 1048576)
        except OSError:
            size = ""
        self.up_where.set_label(os.path.dirname(f) + (" · " + size if size else ""))
        self.up_cur.set_label(cur.split("+")[0] if cur else "—")
        self.up_new.set_label(ver.split("+")[0])
        clear(self.up_checks)
        names = {"bookworm": "Debian 12 «bookworm»", "trixie": "Debian 13 «trixie»"}
        for c in ("Пакет sekta-kiosk", "Архітектура " + myarch, names.get(myrel, "Debian " + myrel)):
            row = hbox(10, "sk-note")
            img = Gtk.Image.new_from_icon_name("object-select-symbolic")
            row.append(img)
            row.append(label(c))
            self.up_checks.append(row)
        self.up_text.set_label(text)
        self.up_go.set_label(go)
        for w in self.head_items:
            w.set_visible(False)
        self.stack.set_visible_child_name("update")

    def update_go(self):
        self.with_sudo(self.update_with)

    def update_with(self, t):
        f = self.up_path
        tmp = tempfile.mkdtemp()   # a copy apt's sandbox user can read (a stick is 700)
        os.chmod(tmp, 0o755)
        env = sudo_env(dict(os.environ), t)
        deb = os.path.join(tmp, "sekta-kiosk.deb")
        script = ('echo "Копіювання $(basename "$1")…"; cp "$1" "$2" && chmod 644 "$2" || exit 1; '
                  'echo "Встановлення пакета…"; shift 2; '
                  'sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"')
        self.progress("Оновлення з файлу", os.path.basename(f), self.chips(),
                      ["Пакет sekta-kiosk", "Kiosk (екрани лишаться)"], "Sekta kiosk " + self.up_new.get_label())
        self.step(0, "now", "триває…")
        self.step(1, "todo")

        def done(rc):
            shutil.rmtree(tmp, ignore_errors=True)
            if rc != 0:
                shutil.rmtree(t, ignore_errors=True)
                self.step(0, "fail", "помилка")
                self.pr_status.set_label("Пакет не встановлено — подробиці в журналі нижче.")
                self.pr_status.add_css_class("sk-err")
                self.pr_buttons([("Назад", True, self.show_manage)])
                return
            self.step(0, "done", "готово")
            # the kiosk itself: with the package's own (new) app and installer;
            # it takes over the sudo dir (and removes it when done)
            os.environ["SEKTA_KIOSK_SUDO_DIR"] = t
            os.execvp("bash", ["bash", os.path.join(PKG_DIR, "sekta-kiosk.sh"), "--install"])
        self.stream(["bash", "-c", script, "_", f, deb] + self.up_extra + [deb], env, None, done)


def main():
    GLib.set_prgname("sekta-kiosk")
    GLib.set_application_name(TITLE)
    app = App(sys.argv[1:])
    sys.exit(app.run([sys.argv[0]]))


if __name__ == "__main__":
    main()
