#!/usr/bin/env bash
#
# fetch-debs.sh — gather all .deb packages for an OFFLINE kiosk-splash install.
#
# Run this ONCE on an ONLINE Debian / Raspberry Pi OS machine that matches the
# TARGET in both:
#   - architecture  (arm64 for Raspberry Pi, amd64 for a Debian PC)
#   - release        (bookworm, bullseye, ...)
#
# It downloads plymouth, chromium, x11-xserver-utils, keyboard-configuration,
# console-setup, wmctrl, zenity (the sekta-kiosk app) and every dependency into
# ./debs/<release>-<arch>/ (e.g. debs/bookworm-amd64), so install-offline.sh can
# later install them with no network. Run it on one machine per release/arch
# to carry several bundles on one stick — the installer picks its own.
#
# apt resolves ONE consistent package set as if the target had nothing
# installed (empty dpkg status), so the bundle is complete even when this
# machine already has some of the packages, and never carries both branches
# of an `A | B` dependency (systemd vs elogind, dbus-daemon vs dbus-broker) —
# installing both of those breaks the target (libsystemd0 gets replaced).
#
#   ./fetch-debs.sh
#   # then copy the whole project folder (incl. debs/) to the offline machine.
#
set -euo pipefail

# one bundle per release + arch: debs/bookworm-amd64, debs/trixie-arm64, …
OUT="$(cd "$(dirname "$0")" && pwd)/debs/$( . /etc/os-release; echo "${VERSION_CODENAME:-unknown}")-$(dpkg --print-architecture)"

info() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

command -v apt-get >/dev/null 2>&1 || die "apt-get not found — run this on Debian/Raspberry Pi OS."

# root (e.g. a fresh container) has no sudo — run apt directly
SUDO=""; [ "$(id -u)" -eq 0 ] || SUDO="sudo"

# before `apt-cache show`: on a fresh machine the index is empty
info "Refreshing apt index..."
# --error-on=any: without network `apt-get update` only warns and exits 0 — the
# script then died with a misleading "No chromium package" (empty index) or
# carried on with a stale one.
$SUDO apt-get update -y --error-on=any \
  || die "apt index update failed — no network or a repo is unreachable."

# Pick the chromium package name available in this repo.
if apt-cache show chromium >/dev/null 2>&1; then
  CHROMIUM_PKG="chromium"
elif apt-cache show chromium-browser >/dev/null 2>&1; then
  CHROMIUM_PKG="chromium-browser"
else
  die "No chromium package in apt. Add the right repo first."
fi
info "Chromium package: $CHROMIUM_PKG"

# keyboard-configuration / console-setup: UA layout (PART 3a of install-offline.sh)
PKGS=(plymouth plymouth-themes "$CHROMIUM_PKG" x11-xserver-utils keyboard-configuration console-setup)
# sudo: Debian installed with a root password has none — the sekta-kiosk app
# tells to install it from the bundle (su -c "apt install …/sudo_*.deb")
PKGS+=(sudo)
# multi-screen kiosk (kiosk-screens.sh): wmctrl — windows of one Chromium on
# their screens (X11); wlr-randr — screen layout on labwc/wayfire
PKGS+=(wmctrl)
# sekta-kiosk app: its window (python3-gi + GTK 4), zenity (the fallback
# windows), pkexec to switch GDM Wayland/Xorg; libxss1 — idle time of the
# screensaver on X11 without GNOME
for p in python3-gi python3-gi-cairo gir1.2-gtk-4.0 zenity pkexec libxss1; do
  if apt-cache show "$p" >/dev/null 2>&1; then PKGS+=("$p"); fi
done
if apt-cache show wlr-randr >/dev/null 2>&1; then PKGS+=(wlr-randr); fi

# Old bundle out: a stale mix of versions/alternatives must not reach the target.
mkdir -p "$OUT/partial"
rm -f "$OUT"/*.deb "$OUT/BUNDLE"

# NB: not `apt-cache depends --recurse` — it lists every alternative of
# `A | B` (both systemd and elogind…); dpkg -i of such a set broke the target.
info "Resolving and downloading the full dependency set into $OUT ..."
STATUS="$(mktemp)"   # empty dpkg status = "nothing installed" → full closure
$SUDO apt-get -q \
  -o Dir::State::status="$STATUS" \
  -o Dir::Cache::archives="$OUT" \
  install -y --download-only --no-install-recommends "${PKGS[@]}" \
  || { rm -f "$STATUS"; die "apt could not resolve/download the package set."; }
rm -f "$STATUS"
rm -rf "$OUT/partial" "$OUT/lock"
[ -z "$SUDO" ] || $SUDO chown -R "$(id -u):$(id -g)" "$OUT"

# Manifest: install-offline.sh refuses a bundle made for another distro /
# release / arch — mixing releases would partially upgrade or break the target.
bundle_id() { ( . /etc/os-release; printf 'ID=%s\nVERSION_CODENAME=%s\nARCH=%s\n' \
  "${ID:-}" "${VERSION_CODENAME:-}" "$(dpkg --print-architecture)" ); }
bundle_id > "$OUT/BUNDLE"
info "Bundle for: $(tr '\n' ' ' < "$OUT/BUNDLE")"

COUNT="$(find "$OUT" -name '*.deb' | wc -l | tr -d ' ')"
info "Done. $COUNT .deb files in $OUT"
info "Now copy the whole project folder (with debs/) to the offline machine and run ./install-offline.sh"
