#!/usr/bin/env bash
#
# install-offline.sh — OFFLINE variant of install.sh.
#
# No network. Installs apt packages from ./debs (gathered by fetch-debs.sh) and
# loads splash assets from local files only. Same result as install.sh:
#   1) Plymouth logo splash
#   2) Chromium kiosk via a systemd --user unit (1 URL locked, up to 3 as tabs,
#      or 2–3 screens with a site on each — KIOSK_SCREENS / KIOSK_LAYOUT)
#   3) System tweaks: UA keyboard, no screen sleep, autologin
#
# Prep (online machine, matching arch/release):   ./fetch-debs.sh
# Then on the offline machine:                     ./install-offline.sh
#
# Run as a NORMAL user (it calls sudo itself). Preset KIOSK_URL (up to 3
# space-separated URLs) to skip the prompt; KIOSK_SCREENS, KIOSK_LAYOUT and
# KIOSK_OUTPUTS, KIOSK_SCALE work as in install.sh.
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# --packages-only: install the bundled packages and stop — the sekta-kiosk app
# runs it in a terminal when zenity itself is missing, then goes on in windows
PACKAGES_ONLY=""
[ "${1:-}" = "--packages-only" ] && PACKAGES_ONLY=1
# debs/<release>-<arch>/ — one stick can carry bundles for several machines
# (fetch-debs.sh); a flat debs/ from an older fetch-debs.sh still works.
BUNDLE_NAME="$( . /etc/os-release; echo "${VERSION_CODENAME:-unknown}")-$(dpkg --print-architecture)"
if [ -d "$HERE/debs/$BUNDLE_NAME" ]; then DEBS_DIR="$HERE/debs/$BUNDLE_NAME"; else DEBS_DIR="$HERE/debs"; fi
THEME_DIR="/usr/share/plymouth/themes/mylogo"
DEFAULT_URL="https://combat.omega"
SERVICE="chromium-kiosk.service"
APP_SERVICE="sekta-kiosk.service"   # Sekta APP kiosk from install.sh (KIOSK_APP=1)
UNIT_DIR="$HOME/.config/systemd/user"
USER="${USER:-$(id -un)}"   # set -u: not set in every context
UNIT_FILE="$UNIT_DIR/$SERVICE"
# Started by the graphical session (autostart), not by graphical-session.target
# — labwc / wayfire never activate that target. Same scheme as install.sh.
LAUNCHER="$HOME/.local/bin/sekta-kiosk-start"
XDG_AUTOSTART="$HOME/.config/autostart/sekta-kiosk.desktop"
LABWC_AUTOSTART="$HOME/.config/labwc/autostart"
AUTOSTART_MARK="# sekta-kiosk"
# Multi-screen browser kiosk (kiosk-screens.sh), as in install.sh
SCREENS_BIN="$HOME/.local/bin/sekta-kiosk-screens"
SCREENS_CONF="$HOME/.config/sekta-kiosk/screens.conf"
APP_BIN="$HOME/.local/bin/sekta-kiosk"   # sekta-kiosk app, as in install.sh
GUI_BIN="$HOME/.local/bin/sekta-kiosk-gui"   # its GTK window

info()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()   { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] && die "Run as a normal user, not root. The script uses sudo where needed."
command -v sudo >/dev/null 2>&1 || die "sudo not found."

# --- Offline prerequisites ---------------------------------------------------
[ -d "$DEBS_DIR" ] || die "No debs/ dir. Run ./fetch-debs.sh on an online machine first."
ls "$DEBS_DIR"/*.deb >/dev/null 2>&1 || \
  die "No bundle for this machine ($BUNDLE_NAME) in debs/ (there: $(cd "$HERE/debs" && ls -d */ 2>/dev/null | tr -d / | tr '\n' ' ')). Run ./fetch-debs.sh on a $BUNDLE_NAME machine."
for asset in logo.png bar_track.png bar_fill.png kiosk-screens.sh sekta-kiosk.sh; do
  [ -f "$HERE/$asset" ] || die "Missing local asset: $asset (offline install needs it bundled)."
done
# the app's GTK window — without it the app shows zenity windows
[ -f "$HERE/sekta-kiosk-gui.py" ] || warn "No sekta-kiosk-gui.py — the sekta-kiosk app falls back to zenity windows."
# only the menu icon — without it the app gets a generic one
[ -f "$HERE/sekta-kiosk.png" ] || warn "No sekta-kiosk.png — the menu entry gets a generic icon."

# The bundle must match this system (written by fetch-debs.sh): debs from
# another release would partially upgrade/mix the system, another arch can't
# install at all. No manifest = bundle from an older fetch-debs.sh that also
# carried conflicting alternatives (systemd + elogind) — never install that.
[ -f "$DEBS_DIR/BUNDLE" ] || \
  die "debs/ has no BUNDLE manifest — it was made by an older fetch-debs.sh and may break this system. Re-run ./fetch-debs.sh."
bundle_want="$(cat "$DEBS_DIR/BUNDLE")"
bundle_have="$( . /etc/os-release; printf 'ID=%s\nVERSION_CODENAME=%s\nARCH=%s\n' \
  "${ID:-}" "${VERSION_CODENAME:-}" "$(dpkg --print-architecture)" )"
[ "$bundle_want" = "$bundle_have" ] || \
  die "debs/ is for [$(echo $bundle_want)], this machine is [$(echo $bundle_have)]. Run ./fetch-debs.sh on a machine of the same release/arch."

# Append params to GRUB_CMDLINE_LINUX_DEFAULT idempotently (existing params are
# kept); one backup + update-grub, and only if something changed. Same as install.sh.
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

if [ -z "$PACKAGES_ONLY" ]; then
# --- Ask the user which address(es) the kiosk should open --------------------
# KIOSK_URL may hold up to 3 space-separated URLs. One URL → locked --kiosk;
# more → browser tabs in a maximised window (tab strip visible). With
# KIOSK_SCREENS=2|3 — one URL per screen, KIOSK_LAYOUT = clock hour of screens
# 2..N around screen 1. As install.sh.
URLS=()
SCREENS="${KIOSK_SCREENS:-}"
LAYOUT=()
OUTPUTS=()
read -r -a LAYOUT <<< "${KIOSK_LAYOUT:-}"
read -r -a OUTPUTS <<< "${KIOSK_OUTPUTS:-}"
if [ -n "${KIOSK_URL:-}" ]; then
  read -r -a URLS <<< "$KIOSK_URL"
fi
# probe that /dev/tty opens: `[ -r ]` is true even with no terminal → set -e kill
if [ "${#URLS[@]}" -eq 0 ] && { : < /dev/tty; } 2>/dev/null; then
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
[ "${#URLS[@]}" -eq 0 ] && URLS+=("$DEFAULT_URL")

SCREENS="${SCREENS:-1}"
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

if [ "$SCREENS" -gt 1 ]; then
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
detect_existing() {
  [ -d "$THEME_DIR" ] && return 0
  for svc in "$SERVICE" "$APP_SERVICE"; do
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
    # both flavours: a Sekta APP kiosk from install.sh must not stay behind
    for svc in "$SERVICE" "$APP_SERVICE"; do
      if systemctl --user list-unit-files 2>/dev/null | grep "^$svc" >/dev/null; then
        systemctl --user disable --now "$svc" 2>/dev/null || true
      fi
      rm -f "$UNIT_DIR/$svc" "$UNIT_DIR/graphical-session.target.wants/$svc"
    done
    systemctl --user daemon-reload 2>/dev/null || true
    if [ -x "$APP_BIN" ]; then "$APP_BIN" --unintegrate 2>/dev/null || true; fi
    rm -f "$LAUNCHER" "$XDG_AUTOSTART" "$SCREENS_BIN" "$SCREENS_CONF" "$APP_BIN" "$GUI_BIN"
    [ -f "$LABWC_AUTOSTART" ] && sed -i "/$AUTOSTART_MARK\$/d" "$LABWC_AUTOSTART"
    [ -d "$THEME_DIR" ] && sudo rm -rf "$THEME_DIR"
    info "Previous install removed."
  fi
fi

fi   # PACKAGES_ONLY

# --- Install the bundled .debs (no network) ----------------------------------
# The bundle is the FULL closure (libc6, systemd, …) of a machine with nothing
# installed, from the release as it was when the bundle was made. apt does the
# choosing: the bundle becomes a local repository (the only source) and apt
# installs just the kiosk packages, upgrading a library only when they need
# it — and then together with what depends on it exactly, or not at all.
# Picking "every bundled .deb newer than here" by hand broke on an older
# point release: libblkid1 2.41.5 selected, util-linux (Pre-Depends
# libblkid1 = 2.41-5, essential, not in the bundle) left behind → apt refused.
# apt never downgrades, so a machine updated after the bundle keeps its newer
# packages.
info "Preparing the bundled packages as a local apt repository..."
REPO="$(mktemp -d)"
mkdir -p "$REPO/lists/partial" "$REPO/cache/partial" "$REPO/parts"
for deb in "$DEBS_DIR"/*.deb; do
  b="$(basename "$deb")"
  ln -s "$deb" "$REPO/$b"
  { dpkg-deb -f "$deb"
    echo "Filename: ./$b"
    echo "Size: $(stat -c %s "$deb")"
    echo "SHA256: $(sha256sum "$deb" | cut -d' ' -f1)"
    echo; } >> "$REPO/Packages"
done
echo "deb [trusted=yes] file:$REPO ./" > "$REPO/sources.list"
APT_LOCAL=(-o Dir::Etc::SourceList="$REPO/sources.list" -o Dir::Etc::SourceParts="$REPO/parts"
           -o Dir::State::Lists="$REPO/lists" -o Dir::Cache::Archives="$REPO/cache"
           -o Dir::Cache::pkgcache= -o Dir::Cache::srcpkgcache= -o Acquire::Languages=none)
WANT=()
for p in plymouth plymouth-themes chromium chromium-browser x11-xserver-utils \
         keyboard-configuration console-setup wmctrl wlr-randr python3-gi python3-gi-cairo gir1.2-gtk-4.0 zenity pkexec; do
  if grep -x "Package: $p" "$REPO/Packages" >/dev/null; then WANT+=("$p"); fi
done
sudo apt-get "${APT_LOCAL[@]}" update -qq || { sudo rm -rf "$REPO"; die "Could not read the bundled packages ($DEBS_DIR)."; }
# noninteractive: keyboard-configuration would otherwise open a debconf
# layout dialog mid-install (the layout itself is set in PART 3a)
# --no-remove: never trade an installed package (a desktop's) for the kiosk —
# apt stops with an error instead
if ! sudo DEBIAN_FRONTEND=noninteractive apt-get "${APT_LOCAL[@]}" install -y --no-remove --no-install-recommends "${WANT[@]}"; then
  sudo rm -rf "$REPO"
  die "Could not install offline: the bundle ($DEBS_DIR) does not fit this machine's packages — rebuild it (fetch-debs.sh / build-deb.sh) for the same release, or update this machine first."
fi
sudo rm -rf "$REPO"
if [ -n "$PACKAGES_ONLY" ]; then info "Bundled packages installed."; exit 0; fi

# ============================================================================
# PART 1 — Plymouth logo splash
# ============================================================================
info "Creating theme dir $THEME_DIR"
sudo mkdir -p "$THEME_DIR"

info "Copying logo + progress-bar assets..."
sudo cp "$HERE/logo.png"       "$THEME_DIR/logo.png"
sudo cp "$HERE/bar_track.png"  "$THEME_DIR/bar_track.png"
sudo cp "$HERE/bar_fill.png"   "$THEME_DIR/bar_fill.png"

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
bar_height = 6;
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

if [ -f /etc/default/grub ]; then
  info "Configuring GRUB quiet splash..."
  # add quiet + splash, keep existing params (replacing the line wiped them)
  grub_add_params quiet splash
else
  warn "/etc/default/grub not found — skipping GRUB step (ok on Raspberry Pi)."
fi

# ============================================================================
# PART 2 — Chromium kiosk systemd --user unit
# ============================================================================
if [ -z "${XDG_CURRENT_DESKTOP:-}${WAYLAND_DISPLAY:-}${DISPLAY:-}" ] \
   && ! systemctl list-unit-files 2>/dev/null | grep -E 'gdm|sddm|lightdm|graphical.target' >/dev/null; then
  warn "No graphical session/desktop detected. Install a desktop (e.g. a display manager)"
  warn "and a graphical autologin, otherwise the kiosk service will not start."
fi

CHROMIUM_BIN="$(command -v chromium || command -v chromium-browser || true)"
[ -n "$CHROMIUM_BIN" ] || die "chromium binary not found after install — the bundled debs may be incomplete."

command -v wmctrl >/dev/null 2>&1 || \
  warn "wmctrl missing (not in debs/?) — several screens would each need their own login."

# The unit runs sekta-kiosk-screens (screens + Chromium), the sekta-kiosk app
# edits screens.conf later — as in install.sh.
info "Installing kiosk launcher $SCREENS_BIN and the sekta-kiosk app"
# a running kiosk (REINSTALL=keep) is the launcher itself: stop it, replace
# the files (new inode) rather than rewrite them under bash's feet
systemctl --user stop "$SERVICE" 2>/dev/null || true
mkdir -p "$(dirname "$SCREENS_BIN")"
install -m 755 "$HERE/kiosk-screens.sh" "$SCREENS_BIN.new" && mv -f "$SCREENS_BIN.new" "$SCREENS_BIN"
install -m 755 "$HERE/sekta-kiosk.sh" "$APP_BIN.new" && mv -f "$APP_BIN.new" "$APP_BIN"
if [ -f "$HERE/sekta-kiosk-gui.py" ]; then
  install -m 755 "$HERE/sekta-kiosk-gui.py" "$GUI_BIN.new" && mv -f "$GUI_BIN.new" "$GUI_BIN"
else
  rm -f "$GUI_BIN"   # an older window must not drive the new launcher: zenity
fi
KIOSK_SCREENS="$SCREENS" KIOSK_URL="${URLS[*]}" KIOSK_LAYOUT="${LAYOUT[*]}" \
  KIOSK_OUTPUTS="${OUTPUTS[*]}" KIOSK_CHROMIUM="$CHROMIUM_BIN" \
  "$SCREENS_BIN" --write-conf || die "Could not write $SCREENS_CONF."
# the app offers an update when the package / stick carries a newer one
[ -f "$HERE/VERSION" ] && cp "$HERE/VERSION" "$(dirname "$SCREENS_CONF")/VERSION"
# new sites must win over pages saved by the previous install (the app sets
# KIOSK_KEEP_PAGES on an update with the same screens and sites)
[ -n "${KIOSK_KEEP_PAGES:-}" ] || "$SCREENS_BIN" --reset
# GNOME on Wayland can't arrange screens or move windows: Xorg for several
if [ "$SCREENS" -gt 1 ]; then sudo bash "$SCREENS_BIN" --gdm x11; else sudo bash "$SCREENS_BIN" --gdm wayland; fi
KIOSK_EXEC="$SCREENS_BIN"
KIOSK_DESC="Browser Kiosk (user)"

info "Writing kiosk unit to $UNIT_FILE"
mkdir -p "$UNIT_DIR"
cat > "$UNIT_FILE" <<EOF
[Unit]
Description=$KIOSK_DESC
# Started by the session autostart ($LAUNCHER), not by a target.
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
EOF

# Launcher: pass the session's display to the user manager, start the unit.
mkdir -p "$(dirname "$LAUNCHER")"
cat > "$LAUNCHER" <<EOF
#!/bin/sh
# Generated by sekta-server-setup kiosk/install-offline.sh
systemctl --user import-environment WAYLAND_DISPLAY DISPLAY XAUTHORITY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE 2>/dev/null
exec systemctl --user start $SERVICE
EOF
chmod 755 "$LAUNCHER"

# XDG autostart (GNOME, LXDE/LXQt, XFCE, Raspberry Pi OS)
mkdir -p "$(dirname "$XDG_AUTOSTART")"
cat > "$XDG_AUTOSTART" <<EOF
[Desktop Entry]
Type=Application
Name=Sekta kiosk
Exec=$LAUNCHER
X-GNOME-Autostart-enabled=true
NoDisplay=true
EOF

# labwc autostart (plain Debian labwc has no XDG autostart). A user file
# replaces /etc/xdg/labwc/autostart, so seed it from the system one first.
if command -v labwc >/dev/null 2>&1 || [ -d "$(dirname "$LABWC_AUTOSTART")" ]; then
  mkdir -p "$(dirname "$LABWC_AUTOSTART")"
  if [ ! -f "$LABWC_AUTOSTART" ] && [ -f /etc/xdg/labwc/autostart ]; then
    cp /etc/xdg/labwc/autostart "$LABWC_AUTOSTART"
  fi
  touch "$LABWC_AUTOSTART"
  sed -i "/$AUTOSTART_MARK\$/d" "$LABWC_AUTOSTART"
  echo "$LAUNCHER & $AUTOSTART_MARK" >> "$LABWC_AUTOSTART"
fi

info "Enabling user lingering (start without opening a terminal)..."
sudo loginctl enable-linger "$USER"

systemctl --user daemon-reload 2>/dev/null || true
# sekta-kiosk app: menu entry + Ctrl+Alt+K (gsettings needs the user bus,
# hence after lingering). Not for the Sekta APP kiosk.
if [ -x "$APP_BIN" ] && [ "$KIOSK_EXEC" = "$SCREENS_BIN" ]; then
  SEKTA_KIOSK_ICON="$HERE/sekta-kiosk.png" "$APP_BIN" --integrate || warn "Could not add the sekta-kiosk menu entry / Ctrl+Alt+K."
fi
# Earlier versions enabled the unit into graphical-session.target — drop that.
systemctl --user disable "$SERVICE" 2>/dev/null || true
rm -f "$UNIT_DIR/graphical-session.target.wants/$SERVICE"
if [ -n "${WAYLAND_DISPLAY:-}${DISPLAY:-}" ] && "$LAUNCHER" 2>/dev/null; then
  info "Kiosk started."
else
  info "Kiosk will start with the graphical session (next login / reboot)."
fi

# ============================================================================
# PART 3 — system tweaks: UA keyboard, no screen sleep, autologin
# ============================================================================

# --- 3a. Ukrainian keyboard layout (us default + ua, Alt+Shift toggle) -------
info "Keyboard: ensuring Ukrainian layout (us,ua — switch Alt+Shift)..."
if [ -f /etc/default/keyboard ] && grep -qE 'XKBLAYOUT="[^"]*\bua\b' /etc/default/keyboard; then
  info "Ukrainian layout already configured."
else
  # offline: keyboard-configuration / console-setup come from the debs/ bundle
  dpkg-query -W -f='${db:Status-Status}' keyboard-configuration 2>/dev/null | grep '^installed' >/dev/null || \
    warn "keyboard-configuration is not installed (missing from debs/?) — layout may not apply."
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

info "Done. Reboot to see the splash and kiosk:  sudo reboot"
