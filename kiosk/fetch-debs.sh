#!/usr/bin/env bash
#
# fetch-debs.sh — gather all .deb packages for an OFFLINE kiosk-splash install.
#
# Run this ONCE on an ONLINE Debian / Raspberry Pi OS machine that matches the
# TARGET in both:
#   - architecture  (arm64 for Raspberry Pi, amd64 for a Debian PC)
#   - release        (bookworm, bullseye, ...)
#
# It downloads plymouth, chromium, x11-xserver-utils and every dependency into
# ./debs, so install-offline.sh can later install them with no network.
#
# Best run on a CLEAN image of the target: apt-get download skips packages that
# are already installed, so a machine that already has these will fetch an
# incomplete set. If unsure, run inside a fresh container/VM of the same release.
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

# Pick the chromium package name available in this repo.
if apt-cache show chromium >/dev/null 2>&1; then
  CHROMIUM_PKG="chromium"
elif apt-cache show chromium-browser >/dev/null 2>&1; then
  CHROMIUM_PKG="chromium-browser"
else
  die "No chromium package in apt. Add the right repo first."
fi
info "Chromium package: $CHROMIUM_PKG"

PKGS=(plymouth plymouth-themes "$CHROMIUM_PKG" x11-xserver-utils)

info "Refreshing apt index..."
sudo apt-get update -y

mkdir -p "$OUT"

# Resolve the full dependency closure, then download every package into ./debs.
# apt-cache depends --recurse over-lists (virtual/alternatives); we filter to
# real, downloadable package names.
info "Resolving dependency closure..."
mapfile -t RESOLVED < <(
  apt-cache depends --recurse --no-recommends --no-suggests \
    --no-conflicts --no-breaks --no-replaces --no-enhances \
    "${PKGS[@]}" 2>/dev/null \
  | grep -v '[<>]' \
  | grep -v '^ ' \
  | sort -u
)

[ "${#RESOLVED[@]}" -gt 0 ] || die "Dependency resolution returned nothing."
info "Packages to download: ${#RESOLVED[@]}"

info "Downloading into $OUT ..."
( cd "$OUT" && apt-get download "${RESOLVED[@]}" ) || \
  warn "Some packages failed to download (virtual/already-newest?). Check output above."

COUNT="$(find "$OUT" -name '*.deb' | wc -l | tr -d ' ')"
info "Done. $COUNT .deb files in $OUT"
info "Now copy the whole project folder (with debs/) to the offline machine and run ./install-offline.sh"
