#!/usr/bin/env bash
#
# install-offline.sh — OFFLINE variant of install.sh.
#
# No network. Installs apt packages from ./debs (gathered by fetch-debs.sh) and
# loads splash assets from local files only. Same result as install.sh:
#   1) Plymouth logo splash
#   2) Chromium kiosk via a systemd --user unit (1 URL locked, up to 3 as tabs)
#   3) System tweaks: UA keyboard, no screen sleep, autologin
#
# Prep (online machine, matching arch/release):   ./fetch-debs.sh
# Then on the offline machine:                     ./install-offline.sh
#
# Run as a NORMAL user (it calls sudo itself). Preset KIOSK_URL (up to 3
# space-separated URLs) to skip the prompt.
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DEBS_DIR="$HERE/debs"
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

info()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()   { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] && die "Run as a normal user, not root. The script uses sudo where needed."
command -v sudo >/dev/null 2>&1 || die "sudo not found."

# --- Offline prerequisites ---------------------------------------------------
[ -d "$DEBS_DIR" ] || die "No debs/ dir. Run ./fetch-debs.sh on an online machine first."
ls "$DEBS_DIR"/*.deb >/dev/null 2>&1 || die "debs/ is empty. Run ./fetch-debs.sh first."
for asset in logo.png bar_track.png bar_fill.png; do
  [ -f "$HERE/$asset" ] || die "Missing local asset: $asset (offline install needs it bundled)."
done

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

# --- Ask the user which address(es) the kiosk should open --------------------
# KIOSK_URL may hold up to 3 space-separated URLs. One URL → locked --kiosk;
# more → browser tabs in a maximised window (tab strip visible). As install.sh.
URLS=()
if [ -n "${KIOSK_URL:-}" ]; then
  read -r -a URLS <<< "$KIOSK_URL"
fi
# probe that /dev/tty opens: `[ -r ]` is true even with no terminal → set -e kill
if [ "${#URLS[@]}" -eq 0 ] && { : < /dev/tty; } 2>/dev/null; then
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
[ "${#URLS[@]}" -eq 0 ] && URLS+=("$DEFAULT_URL")
if [ "${#URLS[@]}" -gt 1 ]; then
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
    rm -f "$LAUNCHER" "$XDG_AUTOSTART"
    [ -f "$LABWC_AUTOSTART" ] && sed -i "/$AUTOSTART_MARK\$/d" "$LABWC_AUTOSTART"
    [ -d "$THEME_DIR" ] && sudo rm -rf "$THEME_DIR"
    info "Previous install removed."
  fi
fi

# --- Install the bundled .debs (no network) ----------------------------------
# The bundle is the FULL closure (libc6, systemd, …). Only packages that are
# missing here, or older than the bundled version, are installed — `dpkg -i *`
# would silently DOWNGRADE system libraries on a machine updated after the
# bundle was made. apt (not dpkg) orders and configures the set — `dpkg -i`
# of the bundle leaves systemd-sysv & co. unconfigured. With every needed .deb
# given as a file apt has nothing to download. NB: no --no-download — apt 2.6
# then fails on local debs ("Pathname to install is not absolute").
info "Selecting bundled packages missing or older on this machine..."
SELECTED=()
skipped=0
for deb in "$DEBS_DIR"/*.deb; do
  pkg="$(dpkg-deb -f "$deb" Package)"
  ver="$(dpkg-deb -f "$deb" Version)"
  arch="$(dpkg-deb -f "$deb" Architecture)"
  q="$pkg"; [ "$arch" = all ] || q="$pkg:$arch"
  inst="$(dpkg-query -W -f='${db:Status-Status} ${Version}' "$q" 2>/dev/null || true)"
  if [ "${inst%% *}" = installed ] && dpkg --compare-versions "${inst#* }" ge "$ver"; then
    skipped=$((skipped + 1))
    continue
  fi
  SELECTED+=("$deb")
done
info "To install: ${#SELECTED[@]}, already present (same or newer): $skipped"

if [ "${#SELECTED[@]}" -gt 0 ]; then
  # noninteractive: keyboard-configuration would otherwise open a debconf
  # layout dialog mid-install (the layout itself is set in PART 3a)
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${SELECTED[@]}" || \
    die "Could not install offline. The debs/ set does not match this machine — re-run fetch-debs.sh on a machine with the same arch/release."
fi

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

# Window mode: one URL → locked --kiosk (no tab bar); several → maximised window
# with the tab strip (Ctrl+Tab), each URL a tab.
if [ "${#URLS[@]}" -gt 1 ]; then WINDOW_FLAGS="--start-maximized"; else WINDOW_FLAGS="--kiosk"; fi
# systemd treats '%' in ExecStart as a specifier — escape it (as install.sh does)
URL_ARGS="${URLS[*]}"
URL_ARGS="${URL_ARGS//%/%%}"

info "Writing kiosk unit to $UNIT_FILE"
mkdir -p "$UNIT_DIR"
cat > "$UNIT_FILE" <<EOF
[Unit]
Description=Browser Kiosk (user)
# Started by the session autostart ($LAUNCHER), not by a target.
StartLimitIntervalSec=0

[Service]
Type=simple
# Disable screensaver / screen blanking / DPMS power saving (X11; no-op on Wayland).
# Leading '-' makes systemd ignore failures (e.g. xset missing under Wayland).
ExecStartPre=-/usr/bin/xset s off
ExecStartPre=-/usr/bin/xset s noblank
ExecStartPre=-/usr/bin/xset -dpms
ExecStart=$CHROMIUM_BIN $WINDOW_FLAGS --noerrdialogs --disable-infobars --disable-session-crashed-bubble --disable-features=Translate --no-first-run --check-for-update-interval=31536000 --password-store=basic $URL_ARGS
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
