#!/usr/bin/env bash
#
# SEKTA kiosk — one-command installer (Plymouth splash + Chromium or Sekta APP kiosk)
#
#   1) Plymouth boot splash with a centered logo (from 1.md)
#   2) Chromium kiosk autostart via a systemd --user unit (from 2.md)
#
# Run on Debian/Raspberry Pi OS as a NORMAL user (it calls sudo itself):
#
#   curl -fsSL https://raw.githubusercontent.com/EugeneSok/sekta-server-setup/main/kiosk/install.sh | bash
#
# Or clone and run locally:
#   git clone https://github.com/EugeneSok/sekta-server-setup.git
#   cd sekta-server-setup/kiosk && ./install.sh
#
# Non-interactive: preset the URL with the KIOSK_URL env var, e.g.
#   curl -fsSL .../install.sh | KIOSK_URL=https://combat.omega bash
# For a tabbed kiosk pass up to 3 space-separated URLs (opened as tabs, tab
# strip stays visible so the operator can switch):
#   curl -fsSL .../install.sh | KIOSK_URL="https://a.omega https://b.omega" bash
#
# Several screens (2–3), one site on each: KIOSK_SCREENS = how many, KIOSK_URL =
# a site per screen, KIOSK_LAYOUT = where screens 2..N are, as a clock hour
# around screen 1 (3 right, 9 left, 12 above, 6 below; others — diagonal):
#   curl -fsSL .../install.sh | KIOSK_SCREENS=2 KIOSK_LAYOUT=3 \
#     KIOSK_URL="https://a.omega https://b.omega" bash
# KIOSK_OUTPUTS="HDMI-1 HDMI-2" pins screens to outputs (default: primary first).
# KIOSK_SCALE="100 150" zoom of each screen in % (50–300, default 100; set by
# the system, not Chromium). Not given → kept from the current screens.conf.
#
# Sekta APP kiosk (Debian 12+, amd64 or arm64): instead of Chromium, install the LATEST
# Sekta APP .deb from GitHub Releases (SHA-256 verified) and run it full-screen
# (`sekta --fullscreen`). Re-running the same command updates the app.
#   curl -fsSL .../install.sh | KIOSK_APP=1 bash
#
set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/EugeneSok/sekta-server-setup/main/kiosk"
THEME_DIR="/usr/share/plymouth/themes/mylogo"
DEFAULT_URL="https://combat.omega"
# Two kiosk flavours share everything except what runs on screen:
#   browser (default) — Chromium with up to 3 sites
#   app (KIOSK_APP=1)  — Sekta APP (Debian build, «Інструменти» only)
APP_MODE=""
case "${KIOSK_APP:-}" in 1|yes|true) APP_MODE=1 ;; esac
APP_RELEASES_API="https://api.github.com/repos/EugeneSok/sekta-app/releases/latest"
# Release asset per CPU architecture (set in install_sekta_app):
#   sekta-linux-amd64.deb / sekta-linux-arm64.deb (since Sekta APP 1.7.2).
APP_ASSET=""
BROWSER_SERVICE="chromium-kiosk.service"
APP_SERVICE="sekta-kiosk.service"
if [ -n "$APP_MODE" ]; then SERVICE="$APP_SERVICE"; else SERVICE="$BROWSER_SERVICE"; fi
UNIT_DIR="$HOME/.config/systemd/user"
UNIT_FILE="$UNIT_DIR/$SERVICE"
# The kiosk unit is started by the graphical session itself (autostart), not
# by graphical-session.target: labwc / wayfire on Raspberry Pi OS and plain
# Debian never activate that target, so a unit WantedBy it never starts after
# a reboot. The launcher first hands the session's display variables to the
# user manager (started at boot by lingering, i.e. before any display exists).
LAUNCHER="$HOME/.local/bin/sekta-kiosk-start"
XDG_AUTOSTART="$HOME/.config/autostart/sekta-kiosk.desktop"
LABWC_AUTOSTART="$HOME/.config/labwc/autostart"
AUTOSTART_MARK="# sekta-kiosk"
# Multi-screen browser kiosk: the unit runs this script, which arranges the
# screens and opens one Chromium per screen (kiosk-screens.sh in the repo).
SCREENS_BIN="$HOME/.local/bin/sekta-kiosk-screens"
SCREENS_CONF="$HOME/.config/sekta-kiosk/screens.conf"
# sekta-kiosk app (kiosk/sekta-kiosk.sh): screens & sites later, menu + Ctrl+Alt+K
APP_BIN="$HOME/.local/bin/sekta-kiosk"
GUI_BIN="$HOME/.local/bin/sekta-kiosk-gui"   # its GTK window (kiosk/sekta-kiosk-gui.py)
SAVER_BIN="$HOME/.local/bin/sekta-kiosk-saver"   # screensaver of the screens (kiosk/kiosk-saver.py)

info()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()   { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] && die "Run as a normal user, not root. The script uses sudo where needed."
command -v sudo >/dev/null 2>&1 || die "sudo not found."
# set -u: $USER is not set in every context (cron, some su/containers)
USER="${USER:-$(id -un)}"

# Local assets only when run as a real ./install.sh from the repo checkout.
# `curl | bash` has no script file ($0 = "bash" → dirname "."), and pve-setup
# runs a temp copy — both must fetch from REPO_RAW, not pick up a stray
# logo.png from the current / temp directory.
SRC_DIR=""
case "${BASH_SOURCE[0]:-}" in
  install.sh|*/install.sh) SRC_DIR="$(dirname "${BASH_SOURCE[0]}")" ;;
esac

# kiosk/<file> from the repo checkout, else from REPO_RAW
get_asset() {
  if [ -n "$SRC_DIR" ] && [ -f "$SRC_DIR/$1" ]; then cp "$SRC_DIR/$1" "$2"
  else curl -fsSL "$REPO_RAW/$1" -o "$2"; fi
}

# Append params to GRUB_CMDLINE_LINUX_DEFAULT idempotently (existing params are
# kept); one backup + update-grub, and only if something changed.
grub_add_params() {
  local f=/etc/default/grub p changed=""
  [ -f "$f" ] || return 0
  for p in "$@"; do
    grep -E '^GRUB_CMDLINE_LINUX_DEFAULT=' "$f" | grep -w -- "$p" >/dev/null && continue
    [ -n "$changed" ] || sudo cp -a "$f" "$f.bak.$(date +%s)"
    if grep -E '^GRUB_CMDLINE_LINUX_DEFAULT=' "$f" >/dev/null; then
      sudo sed -i "s/^\(GRUB_CMDLINE_LINUX_DEFAULT=\"[^\"]*\)\"/\1 $p\"/; s/^\(GRUB_CMDLINE_LINUX_DEFAULT=\"\) /\1/" "$f"
    else
      echo "GRUB_CMDLINE_LINUX_DEFAULT=\"$p\"" | sudo tee -a "$f" >/dev/null
    fi
    changed=1
  done
  if [ -n "$changed" ]; then sudo update-grub; fi
}

# Every `systemctl --user` below needs a session bus. Under `sudo -u` or a
# non-login shell (e.g. from pve-setup) it is undefined → "Failed to connect
# to user scope bus". Point env at this user's runtime bus up front.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"

# --- Ask the user which address(es) the kiosk should open --------------------
# KIOSK_URL may hold one or more space-separated URLs. With a single URL the
# kiosk runs locked in --kiosk mode. With >1 URL it opens them as browser tabs
# in a maximised window so the operator can see and switch between them.
# With KIOSK_SCREENS=2|3 the URLs go one per screen instead (no tabs), and
# KIOSK_LAYOUT gives the clock hour of screens 2..N around screen 1.
URLS=()
SCREENS="${KIOSK_SCREENS:-}"
LAYOUT=()
OUTPUTS=()
read -r -a LAYOUT <<< "${KIOSK_LAYOUT:-}"
read -r -a OUTPUTS <<< "${KIOSK_OUTPUTS:-}"
if [ -n "$APP_MODE" ]; then
  : # app mode — no URLs, the app is the kiosk
elif [ -n "${KIOSK_URL:-}" ]; then
  # split the env value on whitespace into the URL array
  read -r -a URLS <<< "$KIOSK_URL"
fi
# Probe that /dev/tty really opens: `[ -r /dev/tty ]` is true even with no
# controlling terminal (ssh without -t, cron), and the `> /dev/tty` below would
# then kill the script under set -e. No terminal → default URL.
if [ -z "$APP_MODE" ] && [ "${#URLS[@]}" -eq 0 ] && { : < /dev/tty; } 2>/dev/null; then
  # ask again until valid — a typo must not run the wrong set of questions
  while :; do
    case "$SCREENS" in 1|2|3) break ;; esac
    [ -n "$SCREENS" ] && printf 'Must be 1, 2 or 3.\n' > /dev/tty
    printf 'How many screens (1-3)? [1] ' > /dev/tty
    read -r SCREENS < /dev/tty || SCREENS=1
    SCREENS="${SCREENS:-1}"
  done
  if [ "$SCREENS" -gt 1 ]; then
    preset=("${LAYOUT[@]}")   # KIOSK_LAYOUT wins over the question
    LAYOUT=()
    for i in $(seq 1 "$SCREENS"); do
      def="${URLS[0]:-$DEFAULT_URL}"
      printf 'Address for screen #%s [%s]: ' "$i" "$def" > /dev/tty
      read -r u < /dev/tty || true
      URLS+=("${u:-$def}")
      [ "$i" -eq 1 ] && continue
      hr="${preset[$((i - 2))]:-}"
      while :; do
        case "$hr" in [1-9]|1[0-2]) break ;; esac
        [ -n "$hr" ] && printf 'An hour 1-12, please.\n' > /dev/tty
        printf 'Where is screen #%s, as a clock hour around screen #1 (3 right, 9 left, 12 above, 6 below)? [3] ' "$i" > /dev/tty
        read -r hr < /dev/tty || hr=3
        hr="${hr:-3}"
      done
      LAYOUT+=("$hr")
    done
  else
    printf 'Address to open in kiosk [%s]: ' "$DEFAULT_URL" > /dev/tty
    read -r first < /dev/tty || true
    URLS+=("${first:-$DEFAULT_URL}")
    # offer up to two more tabs
    while [ "${#URLS[@]}" -lt 3 ]; do
      printf 'Open another site in a tab? [y/N] ' > /dev/tty
      read -r ans < /dev/tty || true
      case "${ans,,}" in y|yes) ;; *) break ;; esac
      printf 'URL for tab #%s: ' "$(( ${#URLS[@]} + 1 ))" > /dev/tty
      read -r more < /dev/tty || true
      [ -n "$more" ] && URLS+=("$more")
    done
  fi
fi
[ -z "$APP_MODE" ] && [ "${#URLS[@]}" -eq 0 ] && URLS+=("$DEFAULT_URL")

SCREENS="${SCREENS:-1}"
[ -n "$APP_MODE" ] && SCREENS=1
case "$SCREENS" in 1|2|3) ;; *) die "KIOSK_SCREENS must be 1, 2 or 3 (got '$SCREENS')." ;; esac
if [ "$SCREENS" -gt 1 ]; then
  # a site per screen: missing ones repeat screen 1, extra ones are dropped
  while [ "${#URLS[@]}" -lt "$SCREENS" ]; do URLS+=("${URLS[0]}"); done
  URLS=("${URLS[@]:0:$SCREENS}")
  while [ "${#LAYOUT[@]}" -lt $(( SCREENS - 1 )) ]; do LAYOUT+=(3); done
  LAYOUT=("${LAYOUT[@]:0:$(( SCREENS - 1 ))}")
  for hr in "${LAYOUT[@]}"; do
    case "$hr" in [1-9]|1[0-2]) ;; *) die "Screen position must be a clock hour 1-12 (got '$hr')." ;; esac
  done
fi

if [ -n "$APP_MODE" ]; then
  info "Kiosk: Sekta APP (latest release, full screen)"
elif [ "$SCREENS" -gt 1 ]; then
  info "Kiosk on $SCREENS screens:"
  for i in $(seq 1 "$SCREENS"); do
    if [ "$i" -eq 1 ]; then where="main"; else where="at ${LAYOUT[$((i - 2))]} o'clock"; fi
    info "  screen $i ($where): ${URLS[$((i - 1))]}"
  done
elif [ "${#URLS[@]}" -gt 1 ]; then
  info "Kiosk URLs (${#URLS[@]} tabs): ${URLS[*]}"
else
  info "Kiosk URL: ${URLS[0]}"
fi

# --- Remove any previous installation so this run is clean -------------------
# Detect leftovers from an earlier run (Plymouth theme, kiosk unit) and wipe
# them before reinstalling. Set REINSTALL=keep to skip and overwrite in place.
detect_existing() {
  [ -d "$THEME_DIR" ] && return 0
  for svc in "$BROWSER_SERVICE" "$APP_SERVICE"; do
    [ -f "$UNIT_DIR/$svc" ] && return 0
    systemctl --user list-unit-files 2>/dev/null | grep "^$svc" >/dev/null && return 0
  done
  return 1
}

if detect_existing; then
  if [ "${REINSTALL:-}" = "keep" ]; then
    warn "Existing install detected — REINSTALL=keep set, overwriting in place."
  else
    warn "Existing kiosk-splash install detected — removing it before reinstall."

    # Stop + disable BOTH kiosk flavours (switching browser ⇄ app must not
    # leave the other one starting on boot), then drop their unit files.
    for svc in "$BROWSER_SERVICE" "$APP_SERVICE"; do
      if systemctl --user list-unit-files 2>/dev/null | grep "^$svc" >/dev/null; then
        systemctl --user disable --now "$svc" 2>/dev/null || true
      fi
      rm -f "$UNIT_DIR/$svc" "$UNIT_DIR/graphical-session.target.wants/$svc"
    done
    systemctl --user daemon-reload 2>/dev/null || true
    # Session autostart hooks (rewritten below for the chosen flavour).
    if [ -x "$APP_BIN" ]; then "$APP_BIN" --unintegrate 2>/dev/null || true; fi
    rm -f "$LAUNCHER" "$XDG_AUTOSTART" "$SCREENS_BIN" "$SCREENS_CONF" "$APP_BIN" "$GUI_BIN" "$SAVER_BIN"
    [ -f "$LABWC_AUTOSTART" ] && sed -i "/$AUTOSTART_MARK\$/d" "$LABWC_AUTOSTART"

    # Drop the old Plymouth theme dir.
    [ -d "$THEME_DIR" ] && sudo rm -rf "$THEME_DIR"

    info "Previous install removed."
  fi
fi

# ============================================================================
# PART 1 — Plymouth logo splash
# ============================================================================
info "Installing plymouth..."
sudo apt-get update -y
sudo apt-get install -y plymouth plymouth-themes

info "Creating theme dir $THEME_DIR"
sudo mkdir -p "$THEME_DIR"

info "Fetching logo + progress-bar assets..."
for asset in logo.png bar_track.png bar_fill.png; do
  tmpasset="$(mktemp --suffix=.png)"
  get_asset "$asset" "$tmpasset" || die "Could not fetch $asset."
  sudo cp "$tmpasset" "$THEME_DIR/$asset"
  rm -f "$tmpasset"
done

info "Writing theme files..."
sudo tee "$THEME_DIR/mylogo.plymouth" >/dev/null <<EOF
[Plymouth Theme]
Name=MyLogo
Description=My custom logo
ModuleName=script

[script]
ImageDir=$THEME_DIR
ScriptFile=$THEME_DIR/mylogo.script
EOF

sudo tee "$THEME_DIR/mylogo.script" >/dev/null <<'EOF'
logo = Image("logo.png");
screen_width = Window.GetWidth();
screen_height = Window.GetHeight();

scale = Math.Min(
    screen_width  / logo.GetWidth(),
    screen_height / logo.GetHeight()
) * 0.4;

scaled = logo.Scale(
    logo.GetWidth()  * scale,
    logo.GetHeight() * scale
);

sprite = Sprite(scaled);
sprite.SetX(screen_width  / 2 - scaled.GetWidth()  / 2);
sprite.SetY(screen_height / 2 - scaled.GetHeight() / 2);

# --- Progress bar --------------------------------------------------------
bar_width  = screen_width * 0.3;
bar_height = Math.Max(screen_height * 0.006, 4);
bar_x = screen_width / 2 - bar_width / 2;
bar_y = sprite.GetY() + scaled.GetHeight() + screen_height * 0.06;

track_img = Image("bar_track.png").Scale(bar_width, bar_height);
track = Sprite(track_img);
track.SetX(bar_x);
track.SetY(bar_y);

fill_base = Image("bar_fill.png");
fill = Sprite();
fill.SetX(bar_x);
fill.SetY(bar_y);

fun on_progress(duration, progress) {
    w = bar_width * progress;
    if (w < 1) w = 1;
    fill.SetImage(fill_base.Scale(w, bar_height));
}
Plymouth.SetBootProgressFunction(on_progress);

# --- Logo fade in --------------------------------------------------------
tick = 0;
fun refresh() {
    if (tick < 30) {
        tick++;
        sprite.SetOpacity(tick / 30);
    }
}
Plymouth.SetRefreshFunction(refresh);
EOF

info "Activating theme..."
sudo plymouth-set-default-theme -R mylogo

# Quiet boot via GRUB (skipped on systems without GRUB, e.g. Raspberry Pi)
# Adds quiet + splash, keeping the params already there (the old version
# replaced the whole line and wiped them).
if [ -f /etc/default/grub ]; then
  info "Configuring GRUB quiet splash..."
  grub_add_params quiet splash
else
  warn "/etc/default/grub not found — skipping GRUB step (ok on Raspberry Pi)."
fi

# ============================================================================
# PART 2 — kiosk systemd --user unit (Chromium, or Sekta APP with KIOSK_APP=1)
# ============================================================================
# Check that a graphical desktop is present; without one the kiosk can't start.
# NB: no `grep -q` after systemctl here — with `set -o pipefail` it exits on the
# first match, systemctl dies of SIGPIPE (rc 141) and the check reads as
# "no desktop" (false warning on Raspberry Pi OS with LightDM + labwc).
if [ -z "${XDG_CURRENT_DESKTOP:-}${WAYLAND_DISPLAY:-}${DISPLAY:-}" ] \
   && ! systemctl list-unit-files 2>/dev/null | grep -E 'gdm|sddm|lightdm|graphical.target' >/dev/null; then
  warn "No graphical session/desktop detected. Install a desktop (e.g. a display manager)"
  warn "and a graphical autologin, otherwise the kiosk service will not start."
fi

# Install / update Sekta APP: latest GitHub release, SHA-256 verified, apt
# resolves dependencies. Built for amd64 and arm64 (Raspberry Pi 4/5 etc.).
install_sekta_app() {
  local arch; arch="$(dpkg --print-architecture)"
  case "$arch" in
    amd64|arm64) APP_ASSET="sekta-linux-$arch.deb" ;;
    *) die "Sekta APP is built for amd64 and arm64 only (this machine: $arch)." ;;
  esac
  sudo apt-get install -y ca-certificates curl >/dev/null
  info "Looking up the latest Sekta APP release..."
  local json url tag tmp
  json="$(curl -fsSL -H 'Accept: application/vnd.github+json' "$APP_RELEASES_API")" \
    || die "Cannot reach GitHub Releases ($APP_RELEASES_API)."
  tag="$(printf '%s' "$json" | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')"
  url="$(printf '%s' "$json" | grep -o "\"browser_download_url\": *\"[^\"]*/$APP_ASSET\"" \
    | sed -E 's/.*"(https[^"]+)"$/\1/' | head -1)"
  [ -n "$url" ] || die "Release ${tag:-latest} has no $APP_ASSET (Linux build missing?)."
  tmp="$(mktemp -d)"
  info "Downloading $APP_ASSET ($tag)..."
  curl -fsSL "$url" -o "$tmp/$APP_ASSET" || die "Download failed: $url"
  curl -fsSL "$url.sha256" -o "$tmp/$APP_ASSET.sha256" || die "Checksum download failed."
  # The .sha256 file is "<hash>  <name>"; verify against our local file name.
  (cd "$tmp" && awk -v f="$APP_ASSET" '{print $1"  "f}' "$APP_ASSET.sha256" | sha256sum -c --status) \
    || { rm -rf "$tmp"; die "SHA-256 mismatch for $APP_ASSET — not installing."; }
  # apt (not dpkg) so missing libraries are pulled in; _apt must read the file.
  chmod 755 "$tmp"; chmod 644 "$tmp/$APP_ASSET"
  sudo apt-get install -y "$tmp/$APP_ASSET"
  rm -rf "$tmp"
  command -v sekta >/dev/null 2>&1 || die "sekta binary not found after install."
  info "Sekta APP installed: $(dpkg-query -W -f='${Version}' sekta 2>/dev/null)"
}

if [ -n "$APP_MODE" ]; then
  install_sekta_app
  sudo apt-get install -y x11-xserver-utils >/dev/null 2>&1 || \
    warn "Could not install x11-xserver-utils (screen-blanking disable may not work)."
  KIOSK_EXEC="/usr/bin/sekta --fullscreen"
  KIOSK_DESC="Sekta APP kiosk (user)"
  # Auto-update: the app exits and a detached script installs the .deb and
  # relaunches it. The default KillMode=control-group would kill that script
  # together with the app the moment the unit stops; SEKTA_KIOSK_UNIT tells it
  # to relaunch through this unit (Sekta APP 1.7.5+), not as a stray window.
  KIOSK_EXTRA="KillMode=process
Environment=SEKTA_KIOSK_UNIT=$APP_SERVICE"
  # a browser kiosk on several screens may have switched GNOME to Xorg — undo
  tmpks="$(mktemp)"
  if get_asset kiosk-screens.sh "$tmpks"; then sudo bash "$tmpks" --gdm wayland; fi
  rm -f "$tmpks"
else
  info "Installing chromium..."
  if apt-cache show chromium >/dev/null 2>&1; then
    sudo apt-get install -y chromium
  elif apt-cache show chromium-browser >/dev/null 2>&1; then
    sudo apt-get install -y chromium-browser
  else
    warn "No chromium package found in apt; assuming it is already installed."
  fi

  # x11 utilities for disabling screen blanking / DPMS (no-op under Wayland)
  sudo apt-get install -y x11-xserver-utils >/dev/null 2>&1 || \
    warn "Could not install x11-xserver-utils (screen-blanking disable may not work)."

  # Resolve the chromium binary
  CHROMIUM_BIN="$(command -v chromium || command -v chromium-browser || true)"
  [ -n "$CHROMIUM_BIN" ] || die "chromium binary not found after install."

  # wmctrl: windows of one shared Chromium on their screens (X11); wlr-randr:
  # screen layout on labwc/wayfire. Also for one screen — the sekta-kiosk app
  # can add screens later.
  # python3-gi + GTK 4: the sekta-kiosk app's window; zenity: its fallback
  # windows; pkexec: GDM Wayland/Xorg switch. One apt run for what this
  # release has.
  extra_pkgs=()
  for pkg in wmctrl wlr-randr python3-gi python3-gi-cairo gir1.2-gtk-4.0 zenity pkexec libxss1; do
    if apt-cache show "$pkg" >/dev/null 2>&1; then extra_pkgs+=("$pkg"); fi
  done
  if [ "${#extra_pkgs[@]}" -gt 0 ]; then
    sudo apt-get install -y "${extra_pkgs[@]}" || \
      warn "Could not install ${extra_pkgs[*]} — several screens / the sekta-kiosk app may not work."
  fi

  # The unit runs sekta-kiosk-screens: it arranges the screens and starts
  # Chromium (one screen: locked --kiosk, or tabs for several sites). The
  # sekta-kiosk app edits screens.conf and restarts the unit.
  info "Installing kiosk launcher $SCREENS_BIN and the sekta-kiosk app"
  # A running kiosk (REINSTALL=keep) is the launcher itself: stop it, and
  # replace the files (new inode) rather than rewrite them under bash's feet.
  systemctl --user stop "$BROWSER_SERVICE" 2>/dev/null || true
  mkdir -p "$(dirname "$SCREENS_BIN")"
  get_asset kiosk-screens.sh "$SCREENS_BIN.new" || die "Could not fetch kiosk-screens.sh."
  get_asset sekta-kiosk.sh "$APP_BIN.new" || die "Could not fetch sekta-kiosk.sh."
  chmod 755 "$SCREENS_BIN.new" "$APP_BIN.new"
  mv -f "$SCREENS_BIN.new" "$SCREENS_BIN"
  mv -f "$APP_BIN.new" "$APP_BIN"
  # the GTK window: without it the app shows zenity windows
  if get_asset sekta-kiosk-gui.py "$GUI_BIN.new"; then
    chmod 755 "$GUI_BIN.new"; mv -f "$GUI_BIN.new" "$GUI_BIN"
  else
    rm -f "$GUI_BIN.new" "$GUI_BIN"; warn "Could not fetch sekta-kiosk-gui.py — the sekta-kiosk app uses zenity windows."
  fi
  # screensaver (SAVERS in screens.conf): without it the screens never get one
  if get_asset kiosk-saver.py "$SAVER_BIN.new"; then
    chmod 755 "$SAVER_BIN.new"; mv -f "$SAVER_BIN.new" "$SAVER_BIN"
  else
    rm -f "$SAVER_BIN.new"; warn "Could not fetch kiosk-saver.py — no screensaver."
  fi
  # the SEKTA logo of the splash: a screensaver picture always at hand
  "$SCREENS_BIN" --saver-sekta "$THEME_DIR/logo.png" >/dev/null || warn "No SEKTA logo for the screensaver."
  KIOSK_SCREENS="$SCREENS" KIOSK_URL="${URLS[*]}" KIOSK_LAYOUT="${LAYOUT[*]}" \
    KIOSK_OUTPUTS="${OUTPUTS[*]}" KIOSK_CHROMIUM="$CHROMIUM_BIN" \
    "$SCREENS_BIN" --write-conf || die "Could not write $SCREENS_CONF."
  # new sites must win over pages saved by the previous install
  [ -n "${KIOSK_KEEP_PAGES:-}" ] || "$SCREENS_BIN" --reset
  # the app compares it with a package / stick to offer an update
  get_asset VERSION "$(dirname "$SCREENS_CONF")/VERSION" 2>/dev/null || true
  # GNOME on Wayland can't arrange screens or move windows: Xorg for several
  if [ "$SCREENS" -gt 1 ]; then sudo bash "$SCREENS_BIN" --gdm x11; else sudo bash "$SCREENS_BIN" --gdm wayland; fi

  KIOSK_EXEC="$SCREENS_BIN"
  KIOSK_DESC="Browser Kiosk (user)"
  KIOSK_EXTRA="# Stop: SIGTERM to the launcher only, it closes Chromium, which then saves
# its session and marks a clean exit (control-group would TERM every Chromium
# process at once — an "unclean" exit, and the pages were never restored).
KillMode=mixed
TimeoutStopSec=20"
fi

info "Writing kiosk unit to $UNIT_FILE"
mkdir -p "$UNIT_DIR"
cat > "$UNIT_FILE" <<EOF
[Unit]
Description=$KIOSK_DESC
# Started by the session autostart ($LAUNCHER), not by a target — see above.
# Keep retrying a crashing kiosk instead of giving up after 5 attempts.
StartLimitIntervalSec=0

[Service]
Type=simple
# Disable screensaver / screen blanking / DPMS power saving (X11; no-op on Wayland).
# Leading '-' makes systemd ignore failures (e.g. xset missing under Wayland).
ExecStartPre=-/usr/bin/xset s off
ExecStartPre=-/usr/bin/xset s noblank
ExecStartPre=-/usr/bin/xset -dpms
ExecStart=$KIOSK_EXEC
Restart=on-failure
RestartSec=3
$KIOSK_EXTRA
EOF

# Launcher run by the session: pass the display to the user manager, then
# start the unit. `start` is a no-op when it already runs, so being called by
# both autostart mechanisms below is harmless.
mkdir -p "$(dirname "$LAUNCHER")"
cat > "$LAUNCHER" <<EOF
#!/bin/sh
# Generated by sekta-server-setup kiosk/install.sh
systemctl --user import-environment WAYLAND_DISPLAY DISPLAY XAUTHORITY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE 2>/dev/null
exec systemctl --user start $SERVICE
EOF
chmod 755 "$LAUNCHER"

# (1) XDG autostart — GNOME, LXDE/LXQt, XFCE, and Raspberry Pi OS (its labwc
#     and wayfire sessions run lxsession-xdg-autostart).
mkdir -p "$(dirname "$XDG_AUTOSTART")"
cat > "$XDG_AUTOSTART" <<EOF
[Desktop Entry]
Type=Application
Name=Sekta kiosk
Exec=$LAUNCHER
X-GNOME-Autostart-enabled=true
NoDisplay=true
EOF

# (2) labwc's own autostart — plain Debian labwc has no XDG autostart. A user
#     file REPLACES /etc/xdg/labwc/autostart (panel, desktop, XDG autostart on
#     Raspberry Pi OS), so seed it from the system one before appending.
if command -v labwc >/dev/null 2>&1 || [ -d "$(dirname "$LABWC_AUTOSTART")" ]; then
  mkdir -p "$(dirname "$LABWC_AUTOSTART")"
  if [ ! -f "$LABWC_AUTOSTART" ] && [ -f /etc/xdg/labwc/autostart ]; then
    cp /etc/xdg/labwc/autostart "$LABWC_AUTOSTART"
  fi
  touch "$LABWC_AUTOSTART"
  sed -i "/$AUTOSTART_MARK\$/d" "$LABWC_AUTOSTART"
  echo "$LAUNCHER & $AUTOSTART_MARK" >> "$LABWC_AUTOSTART"
  info "labwc autostart: $LABWC_AUTOSTART"
fi

# `systemctl --user` needs a running user manager + session bus. When this
# runs via `sudo -u` or a non-login shell (e.g. from pve-setup) there is none,
# giving "Failed to connect to user scope bus". Enable lingering FIRST so the
# user manager starts, point env at its bus, then wait for the socket.
info "Enabling user lingering (starts the user manager without a login)..."
sudo loginctl enable-linger "$USER"

# wait for the user manager to bring up its bus socket
for _ in $(seq 1 20); do
  [ -S "$XDG_RUNTIME_DIR/bus" ] && break
  sleep 0.5
done

systemctl --user daemon-reload 2>/dev/null || true
# sekta-kiosk app: menu entry + Ctrl+Alt+K (gsettings needs the user bus,
# hence after lingering). Not for the Sekta APP kiosk.
if [ -x "$APP_BIN" ] && [ "$KIOSK_EXEC" = "$SCREENS_BIN" ]; then
  icon_tmp="$(mktemp --suffix=.png)"
  get_asset sekta-kiosk.png "$icon_tmp" 2>/dev/null || rm -f "$icon_tmp"
  SEKTA_KIOSK_ICON="$icon_tmp" "$APP_BIN" --integrate || warn "Could not add the sekta-kiosk menu entry / Ctrl+Alt+K."
  rm -f "$icon_tmp"
fi
# Earlier versions enabled the unit into graphical-session.target — drop that.
systemctl --user disable "$SERVICE" 2>/dev/null || true
rm -f "$UNIT_DIR/graphical-session.target.wants/$SERVICE"

# Run it right away when installing from inside the graphical session;
# otherwise the session autostart starts it at the next login / boot.
if [ -n "${WAYLAND_DISPLAY:-}${DISPLAY:-}" ] && "$LAUNCHER" 2>/dev/null; then
  info "Kiosk started."
else
  info "Kiosk will start with the graphical session (next login / reboot)."
fi

# ============================================================================
# PART 3 — system tweaks: UA keyboard, no screen sleep, autologin, session
# ============================================================================

# --- 3a. Ukrainian keyboard layout (us default + ua, Alt+Shift toggle) -------
info "Keyboard: ensuring Ukrainian layout (us,ua — switch Alt+Shift)..."
if [ -f /etc/default/keyboard ] && grep -qE 'XKBLAYOUT="[^"]*\bua\b' /etc/default/keyboard; then
  info "Ukrainian layout already configured."
else
  # noninteractive: output goes to /dev/null, a debconf layout dialog would hang unseen
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y keyboard-configuration console-setup >/dev/null 2>&1 || \
    warn "Could not install keyboard-configuration/console-setup."
  [ -f /etc/default/keyboard ] && \
    sudo cp -a /etc/default/keyboard "/etc/default/keyboard.bak.$(date +%s)"
  # localectl writes /etc/default/keyboard for X and console in one shot; it can
  # exist yet fail (no running systemd-localed / dbus) — then write the file.
  if ! { command -v localectl >/dev/null 2>&1 && \
         sudo localectl set-x11-keymap us,ua pc105 "" grp:alt_shift_toggle 2>/dev/null; }; then
    command -v localectl >/dev/null 2>&1 && \
      warn "localectl keymap set failed — writing /etc/default/keyboard directly."
    sudo tee /etc/default/keyboard >/dev/null <<'EOF'
XKBMODEL="pc105"
XKBLAYOUT="us,ua"
XKBVARIANT=","
XKBOPTIONS="grp:alt_shift_toggle"
BACKSPACE="guess"
EOF
  fi
  sudo dpkg-reconfigure -f noninteractive keyboard-configuration >/dev/null 2>&1 || true
  sudo setupcon --save 2>/dev/null || true
  # report what is really on disk, not what was attempted
  if grep -qE 'XKBLAYOUT="[^"]*\bua\b' /etc/default/keyboard 2>/dev/null; then
    info "Ukrainian layout added (toggle: Alt+Shift)."
  else
    warn "Ukrainian layout NOT applied — check /etc/default/keyboard."
  fi
fi

# --- 3b. Disable screen sleep / suspend --------------------------------------
# Display DPMS is already handled per-session by xset in the kiosk unit. Here we
# stop the *machine* from suspending and stop the VT console from blanking.
info "Screen sleep: checking system suspend/sleep state..."
if systemctl is-enabled sleep.target suspend.target 2>/dev/null | grep masked >/dev/null; then
  info "Sleep/suspend already masked."
else
  sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target \
    >/dev/null 2>&1 || warn "Could not mask sleep targets."
  info "System suspend/sleep disabled (masked)."
fi
# Kernel console blanking off (VT) via cmdline — GRUB only (no-op on RPi).
if [ -f /etc/default/grub ]; then
  grub_add_params consoleblank=0
  info "Console blanking disabled (consoleblank=0)."
fi

# --- 3c. Automatic login on Debian -------------------------------------------
# Kiosk must land in a graphical session without a password. Config depends on
# the display manager; we detect GDM3 / LightDM, else fall back to TTY autologin.
info "Autologin: detecting display manager for user '$USER'..."
autologin_done=""

# GDM3 (GNOME)
if [ -d /etc/gdm3 ] || systemctl list-unit-files 2>/dev/null | grep '^gdm' >/dev/null; then
  GDM_CONF=/etc/gdm3/daemon.conf
  sudo mkdir -p /etc/gdm3
  [ -f "$GDM_CONF" ] && sudo cp -a "$GDM_CONF" "$GDM_CONF.bak.$(date +%s)"
  [ -f "$GDM_CONF" ] || echo "[daemon]" | sudo tee "$GDM_CONF" >/dev/null
  grep -q '^\[daemon\]' "$GDM_CONF" || echo "[daemon]" | sudo tee -a "$GDM_CONF" >/dev/null
  # uncomment/replace existing keys if present
  sudo sed -i \
    -e "s/^[#[:space:]]*AutomaticLoginEnable[[:space:]]*=.*/AutomaticLoginEnable=true/" \
    -e "s/^[#[:space:]]*AutomaticLogin[[:space:]]*=.*/AutomaticLogin=$USER/" \
    "$GDM_CONF"
  # insert under [daemon] if still missing
  grep -q '^AutomaticLoginEnable=true' "$GDM_CONF" || \
    sudo sed -i "/^\[daemon\]/a AutomaticLoginEnable=true" "$GDM_CONF"
  grep -q "^AutomaticLogin=$USER" "$GDM_CONF" || \
    sudo sed -i "/^AutomaticLoginEnable=true/a AutomaticLogin=$USER" "$GDM_CONF"
  info "GDM3 autologin enabled for '$USER'."
  autologin_done=1
fi

# LightDM
if [ -z "$autologin_done" ] && { [ -d /etc/lightdm ] || systemctl list-unit-files 2>/dev/null | grep '^lightdm' >/dev/null; }; then
  sudo mkdir -p /etc/lightdm/lightdm.conf.d
  sudo tee /etc/lightdm/lightdm.conf.d/50-kiosk-autologin.conf >/dev/null <<EOF
[Seat:*]
autologin-user=$USER
autologin-user-timeout=0
EOF
  # lightdm needs the user in the 'autologin' group on Debian
  getent group autologin >/dev/null 2>&1 || sudo groupadd -r autologin 2>/dev/null || true
  sudo gpasswd -a "$USER" autologin >/dev/null 2>&1 || true
  info "LightDM autologin enabled for '$USER'."
  autologin_done=1
fi

# No display manager → TTY1 autologin (graphical session still required, see PART 2)
if [ -z "$autologin_done" ]; then
  sudo mkdir -p /etc/systemd/system/getty@tty1.service.d
  sudo tee /etc/systemd/system/getty@tty1.service.d/autologin.conf >/dev/null <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $USER --noclear %I \$TERM
EOF
  sudo systemctl daemon-reload 2>/dev/null || true
  warn "No display manager found — set TTY1 autologin for '$USER'."
  warn "A graphical session (startx / a display manager) is still needed for the kiosk."
fi

# --- 3d. Session: no lock screen, no keyring password, no second kiosk ------
# Autologin alone still left password windows: GNOME's lock screen, and the
# "login" keyring — locked after an autologin, unlocked by its password only.
# A kiosk unit / autostart entry made by hand earlier started a second browser
# on the same profile at login. All in the user's session (needs its bus).
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"
if command -v gsettings >/dev/null 2>&1 \
  && gsettings list-keys org.gnome.desktop.screensaver >/dev/null 2>&1; then
  if gsettings set org.gnome.desktop.screensaver lock-enabled false 2>/dev/null \
    && gsettings set org.gnome.desktop.session idle-delay 0 2>/dev/null; then
    info "GNOME: lock screen and screen blanking off."
  else
    warn "GNOME: could not turn the lock screen off (no session yet?)."
  fi
fi

# Keyring password → empty (the secrets stay; on disk unencrypted then).
# $1 = current password; rc 0 = changed, 1 = wrong password, 2 = no keyring service
keyring_nopass() {
  KEYRING_PW="$1" python3 -I - <<'PY' 2>/dev/null
import os, sys
try:
    from gi.repository import Gio, GLib
    bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    def call(path, iface, method, args, sig):
        return bus.call_sync("org.freedesktop.secrets", path, iface, method, args,
                             GLib.VariantType.new(sig), Gio.DBusCallFlags.NO_AUTO_START, 10000, None).unpack()
    _, sess = call("/org/freedesktop/secrets", "org.freedesktop.Secret.Service", "OpenSession",
                   GLib.Variant("(sv)", ("plain", GLib.Variant("s", ""))), "(vo)")
except Exception:
    sys.exit(2)
sec = lambda s: (sess, b"", s.encode(), "text/plain")
try:
    call("/org/freedesktop/secrets", "org.gnome.keyring.InternalUnsupportedGuiltRiddenInterface",
         "ChangeWithMasterPassword",
         GLib.Variant("(o(oayays)(oayays))", ("/org/freedesktop/secrets/collection/login",
                                              sec(os.environ["KEYRING_PW"]), sec(""))), "()")
except Exception:
    sys.exit(1)
PY
}
KEYRING_FILE="$HOME/.local/share/keyrings/login.keyring"
if [ -f "$KEYRING_FILE" ] && python3 -c 'import gi' 2>/dev/null; then
  krc=0; keyring_nopass "" || krc=$?
  if [ "$krc" = 0 ]; then
    info "Keyring: without a password."
  elif [ "$krc" = 2 ]; then
    warn "Keyring: the keyring service is not running — password left (reinstall from the desktop)."
  else
    kpw=""
    if [ -n "${SUDO_ASKPASS:-}" ] && [ -x "$SUDO_ASKPASS" ]; then
      kpw="$("$SUDO_ASKPASS" "Пароль користувача $USER (сховище ключів)" 2>/dev/null || true)"
    elif { : < /dev/tty; } 2>/dev/null; then
      printf 'Password of %s to take it off the login keyring (Enter = skip): ' "$USER" > /dev/tty
      IFS= read -rs kpw < /dev/tty || kpw=""
      echo > /dev/tty
    fi
    if [ -z "$kpw" ]; then
      warn "Keyring: password left — GNOME may ask for it after login."
    else
      cp -a "$KEYRING_FILE" "$KEYRING_FILE.bak.$(date +%s)"
      if keyring_nopass "$kpw"; then
        info "Keyring: password removed (no password window after login)."
      else
        warn "Keyring: wrong password — left as it was."
      fi
    fi
    unset kpw
  fi
fi

# Other kiosk launchers of this user (a browser started by an own unit or an
# autostart entry): disabled — two browsers on one profile fight over it.
for u in "$HOME"/.config/systemd/user/*.service; do
  [ -f "$u" ] || continue
  case "$(basename "$u")" in chromium-kiosk.service|sekta-kiosk.service) continue ;; esac
  grep -E '^ExecStart=.*(chromium|chrome|firefox)' "$u" >/dev/null 2>&1 || continue
  if systemctl --user is-enabled "$(basename "$u")" >/dev/null 2>&1; then
    if systemctl --user disable "$(basename "$u")" >/dev/null 2>&1; then
      warn "Disabled another kiosk unit: $(basename "$u") (file kept)."
    fi
  fi
done
for a in "$HOME"/.config/autostart/*.desktop; do
  [ -f "$a" ] || continue
  case "$(basename "$a")" in sekta-kiosk*.desktop) continue ;; esac
  grep -E '^Exec=.*(chromium|chrome|firefox)' "$a" >/dev/null 2>&1 || continue
  grep -E '^Hidden=true' "$a" >/dev/null 2>&1 && continue
  cp -a "$a" "$a.bak.$(date +%s)"
  echo "Hidden=true" >> "$a"
  warn "Disabled another browser autostart: $(basename "$a") (backup kept)."
done

info "Done. Reboot to see the splash and kiosk:  sudo reboot"
