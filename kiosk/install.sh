#!/usr/bin/env bash
#
# SEKTA kiosk — one-command installer (Plymouth splash + Chromium kiosk)
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
#
set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/EugeneSok/sekta-server-setup/main/kiosk"
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
# Detect leftovers from an earlier run (Plymouth theme, kiosk unit) and wipe
# them before reinstalling. Set REINSTALL=keep to skip and overwrite in place.
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

    # Stop + disable the kiosk service, then drop its unit file.
    if systemctl --user list-unit-files 2>/dev/null | grep -q "^$SERVICE"; then
      systemctl --user disable --now "$SERVICE" 2>/dev/null || true
    fi
    rm -f "$UNIT_FILE"
    systemctl --user daemon-reload 2>/dev/null || true

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

info "Fetching logo..."
tmplogo="$(mktemp --suffix=.png)"
if [ -f "$(dirname "$0")/logo.png" ]; then
  cp "$(dirname "$0")/logo.png" "$tmplogo"
else
  curl -fsSL "$REPO_RAW/logo.png" -o "$tmplogo"
fi
sudo cp "$tmplogo" "$THEME_DIR/logo.png"
rm -f "$tmplogo"

info "Fetching progress-bar assets..."
for asset in bar_track.png bar_fill.png; do
  tmpasset="$(mktemp --suffix=.png)"
  if [ -f "$(dirname "$0")/$asset" ]; then
    cp "$(dirname "$0")/$asset" "$tmpasset"
  else
    curl -fsSL "$REPO_RAW/$asset" -o "$tmpasset"
  fi
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
# Check that a graphical desktop is present; without one the kiosk can't start.
if [ -z "${XDG_CURRENT_DESKTOP:-}${WAYLAND_DISPLAY:-}${DISPLAY:-}" ] \
   && ! systemctl list-unit-files 2>/dev/null | grep -qE 'gdm|sddm|lightdm|graphical.target'; then
  warn "No graphical session/desktop detected. Install a desktop (e.g. a display manager)"
  warn "and a graphical autologin, otherwise the kiosk service will not start."
fi

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
