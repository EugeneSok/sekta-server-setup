#!/usr/bin/env bash
#
# build-deb.sh — build the OFFLINE Debian package sekta-kiosk: the sekta-kiosk
# app (GTK 4 window, zenity fallback) + the kiosk installer + every package it needs
# (fetch-debs.sh bundle: chromium, plymouth, GTK 4, zenity, wmctrl, … with all
# dependencies). The package has no dependencies of its own, so it installs on
# a machine with no network:
#
#   sudo apt install ./sekta-kiosk_1.0.0+bookworm_amd64.deb
#
# Then «Sekta kiosk» in the app menu: the first start installs the kiosk
# (pve-setup menu item 7) asking the screens and sites, later starts manage it;
# a newer package offers to update the kiosk.
#
#   ./build-deb.sh [release] [arch]   in a Docker container debian:<release>
#                                     (default: bookworm amd64; trixie, arm64)
#   FRESH=1 ./build-deb.sh …          fetch the bundle again (else the one
#                                     in debs/<release>-<arch> is reused)
#   ./build-deb.sh --local            on this machine (online Debian /
#                                     Raspberry Pi OS — the target's release
#                                     and arch; RPi OS has its own chromium)
#
# Result: dist/sekta-kiosk_<VERSION>+<release>_<arch>.deb (VERSION file).
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DIST="${DIST:-$HERE/dist}"
VERSION="$(cat "$HERE/VERSION")"

info() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

FILES=(install-offline.sh kiosk-screens.sh sekta-kiosk.sh sekta-kiosk-gui.py fetch-debs.sh
       logo.png bar_track.png bar_fill.png sekta-kiosk.png VERSION)

if [ "${1:-}" != "--local" ]; then
  release="${1:-bookworm}"; arch="${2:-amd64}"
  case "$arch" in amd64|arm64) ;; *) die "arch: amd64 or arm64" ;; esac
  command -v docker >/dev/null 2>&1 || die "docker not found (or run with --local on the target's release)."
  mkdir -p "$DIST"
  info "Building in debian:$release ($arch)…"
  # The container runs this script with --local over a copy of kiosk/ (without
  # debs/ and dist/); the bundle debs/<release>-<arch> is kept on the host as
  # a cache — FRESH=1 fetches it again (newer packages).
  bundle="$HERE/debs/$release-$arch"
  [ "${FRESH:-}" = 1 ] && rm -rf "$bundle"
  mkdir -p "$bundle"
  docker run --rm --platform "linux/$arch" \
    -v "$HERE:/src:ro" -v "$DIST:/dist" -v "$bundle:/work/debs/$release-$arch" \
    -e DIST=/dist -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
    "debian:$release" bash -c '
      set -e
      tar -C /src --exclude=./debs --exclude=./dist -cf - . | tar -C /work -xf -
      bash /work/build-deb.sh --local
      chown -R "$HOST_UID:$HOST_GID" /dist /work/debs'
  exit 0
fi

# --- local build -------------------------------------------------------------
command -v dpkg-deb >/dev/null 2>&1 || die "dpkg-deb not found — run on Debian."
for f in "${FILES[@]}"; do [ -f "$HERE/$f" ] || die "missing $f"; done
release="$( . /etc/os-release; echo "${VERSION_CODENAME:-unknown}")"
arch="$(dpkg --print-architecture)"
bn="$release-$arch"

# no bundle yet, or one made before sudo / GTK 4 joined fetch-debs.sh PKGS
if [ ! -f "$HERE/debs/$bn/BUNDLE" ] || ! ls "$HERE/debs/$bn"/sudo_*.deb >/dev/null 2>&1 \
   || ! ls "$HERE/debs/$bn"/python3-gi-cairo_*.deb >/dev/null 2>&1; then
  info "Fetching the package bundle debs/$bn…"
  bash "$HERE/fetch-debs.sh"
fi
[ -f "$HERE/debs/$bn/BUNDLE" ] || die "fetch-debs.sh did not make debs/$bn."

root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
share="$root/usr/share/sekta-kiosk"
mkdir -p "$share/debs" "$root/usr/bin" "$root/usr/share/applications" "$root/DEBIAN" \
  "$root/usr/share/icons/hicolor/512x512/apps" "$root/usr/share/metainfo"
for f in "${FILES[@]}"; do cp "$HERE/$f" "$share/"; done
chmod 755 "$share"/*.sh
cp -r "$HERE/debs/$bn" "$share/debs/"
ln -s ../share/sekta-kiosk/sekta-kiosk.sh "$root/usr/bin/sekta-kiosk"

cat > "$root/usr/share/applications/sekta-kiosk.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Sekta kiosk
Comment=Встановлення kiosk-дисплея та екрани й сайти (Ctrl+Alt+K)
Exec=/usr/bin/sekta-kiosk
Icon=sekta-kiosk
Terminal=false
Categories=Settings;
EOF
cp "$HERE/sekta-kiosk.png" "$root/usr/share/icons/hicolor/512x512/apps/sekta-kiosk.png"

# AppStream: «Програми» (GNOME Software) shows a proper page — name, icon,
# description, «Встановити» — when the .deb is opened with a double click
cat > "$root/usr/share/metainfo/ua.sekta.kiosk.metainfo.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<component type="desktop-application">
  <id>ua.sekta.kiosk</id>
  <name>Sekta kiosk</name>
  <summary>Kiosk-дисплей SEKTA без інтернету</summary>
  <metadata_license>CC0-1.0</metadata_license>
  <project_license>LicenseRef-proprietary</project_license>
  <developer id="ua.sekta"><name>SEKTA</name></developer>
  <description>
    <p>Встановлює kiosk-дисплей SEKTA без інтернету: екран завантаження з логотипом,
    Chromium на весь екран на 1–3 екранах, автовхід, українська розкладка, без засинання.
    Усі потрібні пакети — всередині ($bn).</p>
    <p>Після встановлення — «Sekta kiosk» у меню програм (Ctrl+Alt+K): екрани, їхнє
    розташування, масштаб і сайти.</p>
  </description>
  <launchable type="desktop-id">sekta-kiosk.desktop</launchable>
  <icon type="stock">sekta-kiosk</icon>
  <categories><category>Settings</category></categories>
  <url type="homepage">https://github.com/EugeneSok/sekta-server-setup</url>
  <releases><release version="$VERSION" date="$(date +%F)"/></releases>
  <content_rating type="oars-1.1"/>
</component>
EOF

size="$(du -sk "$root/usr" | cut -f1)"
cat > "$root/DEBIAN/control" <<EOF
Package: sekta-kiosk
Version: $VERSION+$release
Architecture: $arch
Maintainer: SEKTA <noreply@sekta.local>
Installed-Size: $size
Section: misc
Priority: optional
Description: SEKTA kiosk display — offline installer and screen manager
 Installs the SEKTA kiosk display (boot splash, Chromium on 1-3 screens,
 autologin, Ukrainian keyboard, no sleep) with no network: every package it
 needs is inside ($bn). Start «Sekta kiosk» from the app menu.
EOF

mkdir -p "$DIST"
out="$DIST/sekta-kiosk_${VERSION}+${release}_${arch}.deb"
dpkg-deb --root-owner-group -Zxz --build "$root" "$out" >/dev/null
info "Built $out ($(du -h "$out" | cut -f1))"
