#!/usr/bin/env bash
#
# install-offline.sh — OFFLINE variant of install.sh.
#
# No network. Installs apt packages from ./debs (gathered by fetch-debs.sh) and
# loads splash assets from local files only. Same result as install.sh:
#   1) Plymouth logo splash
#   2) Chromium kiosk via a systemd --user unit
#
# Prep (online machine, matching arch/release):   ./fetch-debs.sh
# Then on the offline machine:                     ./install-offline.sh
#
# Run as a NORMAL user (it calls sudo itself). Preset KIOSK_URL to skip the prompt.
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DEBS_DIR="$HERE/debs"
THEME_DIR="/usr/share/plymouth/themes/mylogo"
DEFAULT_URL="https://combat.omega"
SERVICE="chromium-kiosk.service"
UNIT_DIR="$HOME/.config/systemd/user"
UNIT_FILE="$UNIT_DIR/$SERVICE"

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

# --- Ask the user which address the kiosk should open ------------------------
URL="${KIOSK_URL:-}"
if [ -z "$URL" ]; then
  if [ -r /dev/tty ]; then
    printf 'Address to open in kiosk [%s]: ' "$DEFAULT_URL" > /dev/tty
    read -r URL < /dev/tty || true
  fi
fi
URL="${URL:-$DEFAULT_URL}"
info "Kiosk URL: $URL"

# --- Remove any previous installation so this run is clean -------------------
detect_existing() {
  [ -d "$THEME_DIR" ] && return 0
  [ -f "$UNIT_FILE" ] && return 0
  systemctl --user list-unit-files 2>/dev/null | grep -q "^$SERVICE" && return 0
  return 1
}

if detect_existing; then
  if [ "${REINSTALL:-}" = "keep" ]; then
    warn "Existing install detected — REINSTALL=keep set, overwriting in place."
  else
    warn "Existing kiosk-splash install detected — removing it before reinstall."
    if systemctl --user list-unit-files 2>/dev/null | grep -q "^$SERVICE"; then
      systemctl --user disable --now "$SERVICE" 2>/dev/null || true
    fi
    rm -f "$UNIT_FILE"
    systemctl --user daemon-reload 2>/dev/null || true
    [ -d "$THEME_DIR" ] && sudo rm -rf "$THEME_DIR"
    info "Previous install removed."
  fi
fi

# --- Install every bundled .deb (no network) ---------------------------------
# dpkg -i installs in one shot; a follow-up apt-get -f handles ordering issues
# using only the local debs (no download, since everything is already present).
info "Installing bundled packages from $DEBS_DIR ..."
sudo dpkg -i "$DEBS_DIR"/*.deb || {
  warn "dpkg reported issues — resolving from local debs only..."
  sudo apt-get install -y --no-download --fix-broken || \
    die "Could not satisfy dependencies offline. The debs/ set is incomplete — re-run fetch-debs.sh on a clean machine matching this arch/release."
}

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
  sudo sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"/' /etc/default/grub
  sudo update-grub
else
  warn "/etc/default/grub not found — skipping GRUB step (ok on Raspberry Pi)."
fi

# ============================================================================
# PART 2 — Chromium kiosk systemd --user unit
# ============================================================================
if [ -z "${XDG_CURRENT_DESKTOP:-}${WAYLAND_DISPLAY:-}${DISPLAY:-}" ] \
   && ! systemctl list-unit-files 2>/dev/null | grep -qE 'gdm|sddm|lightdm|graphical.target'; then
  warn "No graphical session/desktop detected. Install a desktop (e.g. a display manager)"
  warn "and a graphical autologin, otherwise the kiosk service will not start."
fi

CHROMIUM_BIN="$(command -v chromium || command -v chromium-browser || true)"
[ -n "$CHROMIUM_BIN" ] || die "chromium binary not found after install — the bundled debs may be incomplete."

info "Writing kiosk unit to $UNIT_FILE"
mkdir -p "$UNIT_DIR"
cat > "$UNIT_FILE" <<EOF
[Unit]
Description=Browser Kiosk (user)
After=graphical-session.target
PartOf=graphical-session.target

[Service]
Type=simple
# Disable screensaver / screen blanking / DPMS power saving (X11; no-op on Wayland).
# Leading '-' makes systemd ignore failures (e.g. xset missing under Wayland).
ExecStartPre=-/usr/bin/xset s off
ExecStartPre=-/usr/bin/xset s noblank
ExecStartPre=-/usr/bin/xset -dpms
ExecStart=$CHROMIUM_BIN --kiosk --noerrdialogs --disable-infobars --disable-session-crashed-bubble --disable-features=Translate --no-first-run --check-for-update-interval=31536000 --password-store=basic $URL
Restart=on-failure
RestartSec=2

[Install]
WantedBy=graphical-session.target
EOF

info "Enabling kiosk service..."
systemctl --user daemon-reload
systemctl --user enable --now "$SERVICE" || \
  warn "Could not start now (no active graphical session?). It will start on next login."

info "Enabling user lingering (start without opening a terminal)..."
sudo loginctl enable-linger "$USER"

info "Done. Reboot to see the splash and kiosk:  sudo reboot"
