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
# console-setup and every dependency into
# ./debs, so install-offline.sh can later install them with no network.
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

OUT="$(cd "$(dirname "$0")" && pwd)/debs"

info() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

command -v apt-get >/dev/null 2>&1 || die "apt-get not found — run this on Debian/Raspberry Pi OS."

# root (e.g. a fresh container) has no sudo — run apt directly
SUDO=""; [ "$(id -u)" -eq 0 ] || SUDO="sudo"

# before `apt-cache show`: on a fresh machine the index is empty
info "Refreshing apt index..."
$SUDO apt-get update -y

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

# Old bundle out: a stale mix of versions/alternatives must not reach the target.
mkdir -p "$OUT/partial"
rm -f "$OUT"/*.deb

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

COUNT="$(find "$OUT" -name '*.deb' | wc -l | tr -d ' ')"
info "Done. $COUNT .deb files in $OUT"
info "Now copy the whole project folder (with debs/) to the offline machine and run ./install-offline.sh"
