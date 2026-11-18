#!/usr/bin/env bash
#
# sekta-kiosk-screens — Chromium kiosk on 1–3 screens (one window per screen).
#
# Installed by install.sh / install-offline.sh as ~/.local/bin/sekta-kiosk-screens
# and run by chromium-kiosk.service instead of chromium itself. Settings come
# from ~/.config/sekta-kiosk/screens.conf (written by --write-conf — from the
# installers and the sekta-kiosk app):
#
#   SCREENS=3                     how many screens
#   URLS=(url1 url2 url3)         one site per screen; with SCREENS=1 up to 3
#                                 sites as tabs (1 site → locked --kiosk)
#   LAYOUT=(9 3)                  where screens 2..N are, as a clock hour around
#                                 screen 1: 3 = right, 9 = left, 12 = above,
#                                 6 = below; 1-2, 4-5, 7-8, 10-11 = diagonal
#   OUTPUTS=(HDMI-1 HDMI-2)       optional: output names for screens 1..N,
#                                 "-" = any (primary first, then as listed)
#   SCALES=(100 150)              zoom of each screen in % (several screens):
#                                 set by the system (xrandr --scale /
#                                 wlr-randr --scale), not by Chromium — its
#                                 zoom is per site and the screens share one
#                                 profile, so Ctrl+/- would change all of them
#   CHROMIUM=/usr/bin/chromium
#   CHROMIUM_FLAGS=(...)
#   RESTORE=auto                  reopen each screen's pages from last time:
#                                 auto = with several screens only (one
#                                 screen always opens its sites, as before);
#                                 1 = always, 0 = never
#
# Several screens in the same direction line up: 3 3 = two screens in a row to
# the right of screen 1.
#
# Each start: wait for the outputs, arrange them (xrandr on X11, wlr-randr on
# labwc/wayfire; GNOME Wayland keeps its own arrangement), then open a
# full-screen Chromium window per screen:
#   X11 + wmctrl — one Chromium, one shared profile (log in once), windows put
#                  on their screens with wmctrl;
#   otherwise    — one Chromium per screen, screens 2–3 with their own profile.
# A closed window or Chromium exiting stops the rest and exits non-zero, so
# systemd restarts the whole set.
#
# When restoring, a profile with a saved session starts with
# --restore-last-session (pages, history, scroll) and no URL — a URL would add
# a second tab. Without a session (first start, after --reset) it opens URLS.
#   sekta-kiosk-screens --reset   forget saved pages, next start opens URLS
#                                 (stop the kiosk first — Chromium saves its
#                                 session again when it exits)
#   sekta-kiosk-screens --write-conf
#       write screens.conf from KIOSK_SCREENS, KIOSK_URL, KIOSK_LAYOUT,
#       KIOSK_OUTPUTS, KIOSK_SCALE, KIOSK_CHROMIUM, KIOSK_RESTORE
#       (space-separated lists);
#       what is not given stays as in the current file. Exit 2 = bad value.
#   sekta-kiosk-screens --outputs   connected outputs, "name WxH" per line
#   sekta-kiosk-screens --gdm-status   no-gdm | wayland | x11 | x11-ours
#   sekta-kiosk-screens --diag   a report for troubleshooting (stdout): system,
#                                session, config, what the last start did
#                                with the screens, xrandr now, journal
#   sekta-kiosk-screens --gdm x11|wayland      (as root)
#       GNOME on Wayland lets no program arrange screens or move windows, so
#       several screens need GDM's Xorg session; "wayland" undoes only a change
#       made here (marked line in /etc/gdm3/daemon.conf).
#
set -u
# numbers with a dot whatever the language: awk prints "1,500000" under
# uk_UA and xrandr / wlr-randr refuse it — the zoom was never applied
if [ -n "${LC_ALL:-}" ]; then export LANG="$LC_ALL"; unset LC_ALL; fi
export LC_NUMERIC=C

CONF="${SEKTA_KIOSK_CONF:-$HOME/.config/sekta-kiosk/screens.conf}"
PROFILE_DIR="$HOME/.config/sekta-kiosk"

log() { echo "sekta-kiosk-screens: $*" >&2; }   # → journal of the unit
# which output each kiosk screen got ("N output" lines) — for the sekta-kiosk app
MAP_FILE="${XDG_RUNTIME_DIR:-/tmp}/sekta-kiosk-screens.map"
# what the last start did with the screens (layout, zoom, xrandr and what the
# desktop made of it a few seconds later) — for --diag
DIAG_FILE="${XDG_RUNTIME_DIR:-/tmp}/sekta-kiosk-screens.diag"
diag() { echo "$(date +%T) $*" >> "$DIAG_FILE" 2>/dev/null || true; }
# monitors and per-output transform (= the zoom xrandr set), as X11 sees them
xshot() {
  xrandr --listmonitors 2>&1 | sed 's/^/  /'
  xrandr --verbose 2>/dev/null | awk '
    / connected/ { name = $1; geo = $3; if (geo ~ /^primary$/) geo = $4; print "  " name " " geo; t = 0; next }
    / disconnected/ { name = ""; next }
    name != "" && /Transform:/ { t = 1; printf "    transform %s %s %s", $2, $3, $4; next }
    name != "" && t == 1 { printf " | %s %s %s", $1, $2, $3; t = 2; next }
    name != "" && t == 2 { printf " | %s %s %s\n", $1, $2, $3; t = 0; next }'
}
# outputs whose scale the kiosk changed, "output original-scale" per line —
# put back when a screen stops being zoomed (also by the one-screen kiosk);
# the runtime dir is cleared on reboot, as is a scale set with xrandr
SCALE_MARK="${XDG_RUNTIME_DIR:-/tmp}/sekta-kiosk-screens.scale"
DEFAULT_FLAGS=(--noerrdialogs --disable-infobars --disable-session-crashed-bubble
  --disable-features=Translate --no-first-run --check-for-update-interval=31536000
  --password-store=basic)
GDM_CONF=/etc/gdm3/daemon.conf
GDM_MARK="# sekta-kiosk: X11 for several screens"
GDM_SAVED="#sekta-kiosk-was: "

# Chromium profile of screen N (1-based). Screen 1 keeps the default profile.
profile_of() {
  if [ "$1" -eq 1 ]; then echo "$HOME/.config/chromium"; else echo "$PROFILE_DIR/chromium-$1"; fi
}
# Session files: Sessions/ since Chromium ~100, "Current/Last Session" before.
has_session() {
  compgen -G "$1/Default/Sessions/Session_*" >/dev/null \
    || [ -f "$1/Default/Current Session" ] || [ -f "$1/Default/Last Session" ]
}
forget_sessions() {
  local n
  for n in 1 2 3; do
    rm -rf "$(profile_of "$n")/Default/Sessions"
    rm -f "$(profile_of "$n")/Default/"{Current,Last}\ {Session,Tabs}
  done
}

# a screen zoom in percent: 50–300
zoom_ok() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; (( $1 >= 50 && $1 <= 300 )); }

# shell-quoted words, nothing for an empty list
q_words() { local a; for a in "$@"; do printf '%q ' "$a"; done; }

write_conf() {
  SCREENS=1; URLS=(); LAYOUT=(); OUTPUTS=(); SCALES=(); CHROMIUM=""; CHROMIUM_FLAGS=(); RESTORE=auto
  # shellcheck source=/dev/null
  [ -f "$CONF" ] && . "$CONF"
  [ -n "${KIOSK_SCREENS:-}" ] && SCREENS="$KIOSK_SCREENS"
  [ -n "${KIOSK_URL+x}" ] && read -r -a URLS <<< "$KIOSK_URL"
  [ -n "${KIOSK_LAYOUT+x}" ] && read -r -a LAYOUT <<< "$KIOSK_LAYOUT"
  [ -n "${KIOSK_OUTPUTS+x}" ] && read -r -a OUTPUTS <<< "$KIOSK_OUTPUTS"
  [ -n "${KIOSK_SCALE+x}" ] && read -r -a SCALES <<< "$KIOSK_SCALE"
  [ -n "${KIOSK_CHROMIUM:-}" ] && CHROMIUM="$KIOSK_CHROMIUM"
  [ -n "${KIOSK_RESTORE:-}" ] && RESTORE="$KIOSK_RESTORE"

  case "$SCREENS" in 1|2|3) ;; *) log "screens must be 1, 2 or 3 (got '$SCREENS')"; return 2 ;; esac
  [ "${#URLS[@]}" -gt 0 ] || { log "no site given"; return 2; }
  if [ "$SCREENS" -gt 1 ]; then
    # a site per screen: missing ones repeat screen 1, extra ones are dropped
    while [ "${#URLS[@]}" -lt "$SCREENS" ]; do URLS+=("${URLS[0]}"); done
    URLS=("${URLS[@]:0:$SCREENS}")
    while [ "${#LAYOUT[@]}" -lt $(( SCREENS - 1 )) ]; do LAYOUT+=(3); done
    LAYOUT=("${LAYOUT[@]:0:$(( SCREENS - 1 ))}")
    local hr
    for hr in "${LAYOUT[@]}"; do
      case "$hr" in [1-9]|1[0-2]) ;; *) log "screen position must be a clock hour 1-12 (got '$hr')"; return 2 ;; esac
    done
  else
    URLS=("${URLS[@]:0:3}")   # tabs
    LAYOUT=()
  fi
  OUTPUTS=("${OUTPUTS[@]:0:$SCREENS}")
  while [ "${#SCALES[@]}" -lt "$SCREENS" ]; do SCALES+=(100); done
  SCALES=("${SCALES[@]:0:$SCREENS}")
  local sc
  for sc in "${SCALES[@]}"; do
    zoom_ok "$sc" || { log "screen zoom must be a percent 50-300 (got '$sc')"; return 2; }
  done
  local seen=" " o
  for o in "${OUTPUTS[@]}"; do
    [ "$o" = - ] && continue
    case "$seen" in *" $o "*) log "output $o is given to two screens"; return 2 ;; esac
    seen+="$o "
  done
  [ -n "$CHROMIUM" ] || CHROMIUM="$(command -v chromium || command -v chromium-browser || echo chromium)"
  [ "${#CHROMIUM_FLAGS[@]}" -gt 0 ] || CHROMIUM_FLAGS=("${DEFAULT_FLAGS[@]}")
  case "$RESTORE" in 0|1|auto) ;; *) RESTORE=auto ;; esac

  mkdir -p "$(dirname "$CONF")"
  {
    echo "# sekta-kiosk screens — written by sekta-kiosk-screens --write-conf"
    printf 'SCREENS=%s\n' "$SCREENS"
    printf 'URLS=(%s)\n' "$(q_words "${URLS[@]}")"
    printf 'LAYOUT=(%s)\n' "${LAYOUT[*]}"
    printf 'OUTPUTS=(%s)\n' "$(q_words "${OUTPUTS[@]}")"
    printf 'SCALES=(%s)   # zoom of each screen, %%\n' "${SCALES[*]}"
    printf 'CHROMIUM=%q\n' "$CHROMIUM"
    printf 'CHROMIUM_FLAGS=(%s)\n' "$(q_words "${CHROMIUM_FLAGS[@]}")"
    echo "RESTORE=$RESTORE   # reopen pages after a reboot: auto = on several screens, 1 = always, 0 = never"
  } > "$CONF.tmp" && mv "$CONF.tmp" "$CONF"
}

gdm_x11() {
  local f="$GDM_CONF"
  [ -d /etc/gdm3 ] || return 0
  grep -E '^WaylandEnable=false' "$f" >/dev/null 2>&1 && return 0
  [ -f "$f" ] && cp -a "$f" "$f.bak.$(date +%s)"
  [ -f "$f" ] || echo "[daemon]" > "$f"
  grep '^\[daemon\]' "$f" >/dev/null || echo "[daemon]" >> "$f"
  # an active WaylandEnable=… of the admin is parked as a comment, put back by
  # gdm_wayland; commented lines stay as they are
  sed -i "s/^WaylandEnable[[:space:]]*=/$GDM_SAVED&/" "$f"
  sed -i "/^\[daemon\]/a $GDM_MARK\nWaylandEnable=false" "$f"
  echo "GDM: X11 session instead of Wayland (needed for several screens; takes effect after reboot)."
}
gdm_wayland() {
  local f="$GDM_CONF"
  grep -Fx "$GDM_MARK" "$f" >/dev/null 2>&1 || return 0
  cp -a "$f" "$f.bak.$(date +%s)"
  # drop our two lines, give back the admin's parked one
  sed -i "\|^$GDM_MARK\$|{N;d}" "$f"
  sed -i "s/^$GDM_SAVED//" "$f"
  echo "GDM: Wayland session back (one screen; takes effect after reboot)."
}

case "${1:-}" in
  --reset)
    forget_sessions
    log "saved pages forgotten — next start opens the configured sites"
    exit 0 ;;
  --write-conf)
    write_conf; exit $? ;;
  --gdm)
    [ "$(id -u)" -eq 0 ] || { log "--gdm needs root"; exit 1; }
    case "${2:-}" in
      x11) gdm_x11 ;;
      wayland) gdm_wayland ;;
      *) log "--gdm x11|wayland"; exit 2 ;;
    esac
    exit $? ;;
  --diag)
    {
      echo "== sekta-kiosk diagnostics $(date '+%F %T')"
      echo "version: $(cat "$HOME/.config/sekta-kiosk/VERSION" 2>/dev/null || echo ?)" \
        "package: $(dpkg-query -W -f='${Version}' sekta-kiosk 2>/dev/null || echo -)"
      . /etc/os-release 2>/dev/null; echo "system: ${PRETTY_NAME:-?} $(uname -m) kernel $(uname -r)"
      echo "user: $(id -un) session: ${XDG_SESSION_TYPE:-?} desktop: ${XDG_CURRENT_DESKTOP:-?}" \
        "DISPLAY=${DISPLAY:-} WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-}"
      v1="$(gnome-shell --version 2>/dev/null)"; v2="$("${CHROMIUM:-chromium}" --version 2>/dev/null)"
      v3="$(wmctrl -m 2>/dev/null | head -1)"
      echo "gnome-shell: ${v1:--}  chromium: ${v2:--}  window manager: ${v3:--}"
      echo "gdm: $(bash "$0" --gdm-status 2>/dev/null)"
      grep -nE 'WaylandEnable|sekta-kiosk' "$GDM_CONF" 2>/dev/null | sed 's/^/  /'
      echo "kiosk: $(systemctl --user is-active chromium-kiosk.service 2>/dev/null)"
      echo; echo "== $CONF"; grep -vE '^[[:space:]]*(#|$)' "$CONF" 2>/dev/null | grep -v '^CHROMIUM_FLAGS' | sed 's/^/  /'
      echo; echo "== last start (zoom: computed -> xrandr -> what stayed)"
      cat "$DIAG_FILE" 2>/dev/null || echo "  (no start since boot)"
      echo; echo "== X11 now"; xshot
      echo "outputs (name size mode basescale):"; bash "$0" --outputs 2>&1 | sed 's/^/  /'
      echo "screen map: $(tr '\n' ';' 2>/dev/null < "$MAP_FILE")  scale mark: $(tr '\n' ';' 2>/dev/null < "$SCALE_MARK")"
      echo; echo "== windows"; wmctrl -lGx 2>/dev/null | sed 's/^/  /'
      echo; echo "== ~/.config/monitors.xml (GNOME display settings)"
      if [ -f "$HOME/.config/monitors.xml" ]; then
        grep -E '<(connector|x|y|scale|primary|width|height)>' "$HOME/.config/monitors.xml" | tr -d ' ' | paste -sd' ' | sed 's/^/  /'
      else echo "  -"; fi
      echo; echo "== journal (this boot, last 40)"
      journalctl --user -u chromium-kiosk.service -b --no-pager -o short-monotonic 2>/dev/null \
        | grep -v 'chromium\[.*\(ERROR\|WARNING\):' | tail -40
    } 2>&1
    exit 0 ;;
  --gdm-status)
    if [ ! -d /etc/gdm3 ]; then echo no-gdm
    elif grep -Fx "$GDM_MARK" "$GDM_CONF" >/dev/null 2>&1; then echo x11-ours
    elif grep -E '^WaylandEnable=false' "$GDM_CONF" >/dev/null 2>&1; then echo x11
    else echo wayland; fi
    exit 0 ;;
  ""|--outputs) ;;
  *) log "unknown option $1"; exit 2 ;;
esac

SCREENS=1; URLS=(); LAYOUT=(); OUTPUTS=(); SCALES=(); CHROMIUM=chromium; CHROMIUM_FLAGS=(); RESTORE=auto
if [ "${1:-}" != --outputs ]; then
  [ -f "$CONF" ] || { log "no config $CONF"; exit 1; }
  # shellcheck source=/dev/null
  . "$CONF"
fi
[ "${#CHROMIUM_FLAGS[@]}" -gt 0 ] || CHROMIUM_FLAGS=("${DEFAULT_FLAGS[@]}")
# auto: an unattended single dashboard comes back to its site on every boot
if [ "$RESTORE" = auto ]; then
  if [ "$SCREENS" -gt 1 ]; then RESTORE=1; else RESTORE=0; fi
fi

# --- one screen: the plain kiosk ---------------------------------------------
# No layout to arrange. One site → locked --kiosk; several → tabs in a
# maximised window (tab strip visible, Ctrl+Tab).
# Give outputs back the scale they had before the kiosk zoomed them.
restore_scales() {
  [ -f "$SCALE_MARK" ] || return 0
  local o sc
  while read -r o sc; do
    [ -n "$o" ] || continue
    if [ -n "${WAYLAND_DISPLAY:-}" ]; then
      wlr-randr --output "$o" --scale "$sc" 2>/dev/null || true
    else
      xrandr --output "$o" --scale 1x1 2>/dev/null || true
    fi
  done < "$SCALE_MARK"
  rm -f "$SCALE_MARK"
}

if [ "$SCREENS" -le 1 ] && [ "${1:-}" != --outputs ]; then
  rm -f "$MAP_FILE"
  restore_scales   # was several screens with a zoom
  if [ "${#URLS[@]}" -gt 1 ]; then win=(--start-maximized); else win=(--kiosk); fi
  if [ "$RESTORE" = 1 ] && has_session "$(profile_of 1)"; then
    open=(--restore-last-session); log "restoring the pages from last time"
  else
    open=("${URLS[@]}")
  fi
  exec "$CHROMIUM" "${win[@]}" "${CHROMIUM_FLAGS[@]}" "${open[@]}"
fi

# --- connected outputs: "name WxH mode scale" per line, screen order --------
# WxH is the monitor's size in its pixels (a portrait / rotated monitor:
# swapped), mode the one to pass to xrandr --mode, scale the compositor's
# current one (wlroots; X11: 1).
# X11 (also XWayland): mode = current, else preferred, else the first one.
outputs_x11() {
  xrandr --query 2>/dev/null | awk '
    function flush() {
      if (name == "") return
      m = (cur != "" ? cur : (pref != "" ? pref : first)); if (m == "") return
      split(m, wh, "x")
      print prim, name, (rot ? wh[2] "x" wh[1] : m), m
    }
    $2 == "connected" {
      flush(); name = $1; prim = ($3 == "primary") ? 0 : 1; cur = pref = first = ""; rot = 0
      # "1080x1920+0+0 left (normal left …)" — rotation follows the geometry
      for (f = 3; f <= NF; f++) if ($f ~ /^[0-9]+x[0-9]+\+/) { rot = ($(f + 1) == "left" || $(f + 1) == "right"); break }
      next
    }
    $2 == "disconnected" { flush(); name = ""; next }
    name != "" && $1 ~ /^[0-9]+x[0-9]+/ {
      m = $1; sub(/[^0-9x].*/, "", m)
      if (first == "") first = m
      if ($0 ~ /\*/) cur = m
      if ($0 ~ /\+/) pref = m
    }
    END { flush() }' | sort -s -k1,1n | awk '{ print $2, $3, $4, 1 }'
}

# wlroots compositors (labwc, wayfire): the mode (rotated) and its scale — a
# HiDPI scale set in display settings stays the base of the kiosk's zoom.
outputs_wlr() {
  wlr-randr 2>/dev/null | awk '
    function flush() {
      if (name == "") return
      m = (cur != "" ? cur : (pref != "" ? pref : first)); if (m == "") return
      split(m, wh, "x")
      if (rot) printf "%s %dx%d %s %s\n", name, wh[2], wh[1], m, scale
      else     printf "%s %dx%d %s %s\n", name, wh[1], wh[2], m, scale
    }
    /^[^ \t]/ { flush(); name = $1; cur = pref = first = ""; rot = 0; scale = 1; next }
    $1 == "Scale:" && $2 > 0 { scale = $2 }
    $1 == "Transform:" { rot = ($2 ~ /90|270/) }
    $1 ~ /^[0-9]+x[0-9]+$/ && $2 == "px," {
      if (first == "") first = $1
      if ($0 ~ /current/) cur = $1
      if ($0 ~ /preferred/) pref = $1
    }
    END { flush() }'
}

BACKEND=x11
if [ -n "${WAYLAND_DISPLAY:-}" ]; then
  if command -v wlr-randr >/dev/null 2>&1 && wlr-randr >/dev/null 2>&1; then
    BACKEND=wlr
  else
    BACKEND=none   # e.g. GNOME Wayland: layout is set in its display settings
  fi
fi

list_outputs() {
  case "$BACKEND" in
    wlr) outputs_wlr ;;
    *)   outputs_x11 ;;
  esac
}
if [ "${1:-}" = --outputs ]; then list_outputs; exit 0; fi

# Screens may come up a bit after the session; wait up to a minute for all —
# on the first start of this boot only. A restart (closed window, crash) with
# a screen missing for good must not keep the others black for a minute.
FIRST_MARK="${XDG_RUNTIME_DIR:-/tmp}/sekta-kiosk-screens.started"
wait_s=60
[ -e "$FIRST_MARK" ] && wait_s=5
touch "$FIRST_MARK" 2>/dev/null
NAMES=(); SIZES=()
for _ in $(seq 1 "$wait_s"); do
  mapfile -t lines < <(list_outputs)
  [ "${#lines[@]}" -ge "$SCREENS" ] && break
  sleep 1
done
[ "${#lines[@]}" -gt 0 ] || { log "no connected outputs found"; exit 1; }
: > "$DIAG_FILE" 2>/dev/null
diag "start: SCREENS=$SCREENS URLS=(${URLS[*]}) LAYOUT=(${LAYOUT[*]}) OUTPUTS=(${OUTPUTS[*]}) SCALES=(${SCALES[*]}) backend=$BACKEND"
diag "session ${XDG_SESSION_TYPE:-?} DISPLAY=${DISPLAY:-} WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-}"
for l in "${lines[@]}"; do diag "output: $l"; done
[ -f "$SCALE_MARK" ] && diag "scale mark from earlier start: $(tr '\n' ';' < "$SCALE_MARK")"
{ echo "before:"; xshot; } >> "$DIAG_FILE" 2>/dev/null

# Screens with a named output get it; "-" (or a name not connected) gets the
# next free output as detected (primary first). Outputs left over follow.
# An output named twice goes to the first of those screens only.
declare -A SIZE_OF=() MODE_OF=() BASE_OF=() ORIG_OF=()
# scales changed by an earlier start: their originals are the base, not the
# current (zoomed) value
if [ -f "$SCALE_MARK" ]; then
  while read -r o sc; do [ -n "$o" ] && ORIG_OF[$o]="$sc"; done < "$SCALE_MARK"
fi
detected=()
for l in "${lines[@]}"; do
  read -r o sz md sc <<< "$l"
  SIZE_OF[$o]="$sz"; MODE_OF[$o]="${md:-$sz}"; BASE_OF[$o]="${ORIG_OF[$o]:-${sc:-1}}"; detected+=("$o")
done
taken=" "
for o in "${OUTPUTS[@]}"; do
  [ "$o" = - ] && continue
  if [ -n "${SIZE_OF[$o]:-}" ]; then taken+="$o "; else log "output $o not connected — another one is used"; fi
done
free=()
for o in "${detected[@]}"; do case "$taken" in *" $o "*) ;; *) free+=("$o") ;; esac; done
# pinned outputs first (named twice → only the first screen), then "-" screens
# take the free ones in order
SCREEN_OUT=()
used=" "
for ((i = 0; i < SCREENS; i++)); do
  o="${OUTPUTS[$i]:--}"
  if [ "$o" != - ] && [ -n "${SIZE_OF[$o]:-}" ]; then
    case "$used" in
      *" $o "*) log "output $o named twice — screen $((i + 1)) gets another one" ;;
      *) SCREEN_OUT[$i]="$o"; used+="$o " ;;
    esac
  fi
done
for ((i = 0; i < SCREENS; i++)); do
  [ -n "${SCREEN_OUT[$i]:-}" ] && continue
  [ "${#free[@]}" -gt 0 ] || continue
  SCREEN_OUT[$i]="${free[0]}"; free=("${free[@]:1}")
done
# A screen left without a monitor is skipped; the others keep their sites and
# hours (a skipped screen 1 → the next one becomes the centre).
urls=(); layout=(); scales=()
for ((i = 0; i < SCREENS; i++)); do
  if [ -z "${SCREEN_OUT[$i]:-}" ]; then log "screen $((i + 1)): no monitor for it — skipped"; continue; fi
  NAMES+=("${SCREEN_OUT[$i]}")
  urls+=("${URLS[$i]:-${URLS[0]:-}}")
  scales+=("${SCALES[$i]:-100}")
  [ "${#NAMES[@]}" -gt 1 ] && layout+=("${LAYOUT[$((i - 1))]:-3}")
done
URLS=("${urls[@]}"); LAYOUT=("${layout[@]}"); SCALES=("${scales[@]}")
SCREENS="${#NAMES[@]}"
NAMES+=("${free[@]}")   # outputs left over: moved aside below
[ "$SCREENS" -gt 0 ] || { log "no monitor for any screen"; exit 1; }
for ((i = 0; i < SCREENS; i++)); do SIZES+=("${SIZE_OF[${NAMES[$i]}]}"); done

# --- positions from clock hours ----------------------------------------------
# Screen 1 at 0,0. A new screen goes past the screens already on its side of
# screen 1 (right: 2-4, below: 5-7, left: 8-10, above: 11-1), centred on
# screen 1 for 3/6/9/12 and shifted by half its size for the diagonal hours.
X=(); Y=(); W=(); H=()
# Zoom Z % on top of the output's base scale b (wlroots HiDPI; X11: 1): the
# screen shows its pixels / (b·Z/100) of the desktop. W/H are whole desktop
# pixels; the scale handed to xrandr / wlr-randr is derived from them, so the
# compositor gets the same size the layout was made with.
SCALE_F=()   # final scale per screen (screen pixels per desktop pixel)
for ((i = 0; i < SCREENS; i++)); do
  z="${SCALES[$i]:-100}"; zoom_ok "$z" || z=100
  b="${BASE_OF[${NAMES[$i]}]:-1}"
  read -r w h f <<< "$(awk -v w="${SIZES[$i]%x*}" -v h="${SIZES[$i]#*x}" -v b="$b" -v z="$z" '
    BEGIN { sc = b * z / 100; W = int(w / sc + 0.5); H = int(h / sc + 0.5)
            printf "%d %d %.6f\n", W, H, w / W }')"
  W+=("$w"); H+=("$h"); SCALE_F+=("$f")
  diag "screen $((i + 1)): ${NAMES[$i]} ${SIZES[$i]} zoom ${z}% base $b -> desktop ${w}x${h}, scale $f"
done
# xrandr --scale = desktop pixels per screen pixel, cut (not rounded) so the
# output never comes out a pixel wider than W (overlapping its neighbour)
xscale() { awk -v w="$1" -v W="$2" 'BEGIN { printf "%.6f", int(W / w * 1000000) / 1000000 }'; }
X[0]=0; Y[0]=0
w1=${W[0]}; h1=${H[0]}
right=$w1; left=0; top=0; bottom=$h1   # outer edges of each side so far
for ((i = 1; i < SCREENS; i++)); do
  hr="${LAYOUT[$((i - 1))]:-3}"
  w=${W[$i]}; h=${H[$i]}
  case "$hr" in
    2|3|4|5|6|7|8|9|10|11|12|1) ;;
    *) log "screen $((i + 1)): bad hour '$hr' — using 3"; hr=3 ;;
  esac
  case "$hr" in
    2)  x=$right; y=$(( -h / 2 )) ;;
    3)  x=$right; y=$(( (h1 - h) / 2 )) ;;
    4)  x=$right; y=$(( h1 - h / 2 )) ;;
    5)  x=$(( w1 - w / 2 )); y=$bottom ;;
    6)  x=$(( (w1 - w) / 2 )); y=$bottom ;;
    7)  x=$(( -w / 2 )); y=$bottom ;;
    8)  x=$(( left - w )); y=$(( h1 - h / 2 )) ;;
    9)  x=$(( left - w )); y=$(( (h1 - h) / 2 )) ;;
    10) x=$(( left - w )); y=$(( -h / 2 )) ;;
    11) x=$(( -w / 2 )); y=$(( top - h )) ;;
    12) x=$(( (w1 - w) / 2 )); y=$(( top - h )) ;;
    1)  x=$(( w1 - w / 2 )); y=$(( top - h )) ;;
  esac
  # Neighbouring diagonals (4 and 5, …) would overlap at the corner: push the
  # new screen further out on its side until it is clear of the others.
  moved=1
  while (( moved )); do
    moved=0
    for ((j = 0; j < i; j++)); do
      (( x < X[j] + W[j] && X[j] < x + w && y < Y[j] + H[j] && Y[j] < y + h )) || continue
      case "$hr" in
        2|3|4)   x=$(( X[j] + W[j] )) ;;
        5|6|7)   y=$(( Y[j] + H[j] )) ;;
        8|9|10)  x=$(( X[j] - w )) ;;
        11|12|1) y=$(( Y[j] - h )) ;;
      esac
      moved=1
    done
  done
  case "$hr" in
    2|3|4)   right=$(( x + w )) ;;
    5|6|7)   bottom=$(( y + h )) ;;
    8|9|10)  left=$x ;;
    11|12|1) top=$y ;;
  esac
  X[$i]=$x; Y[$i]=$y
done
minx=0; miny=0
for ((i = 0; i < SCREENS; i++)); do
  (( X[i] < minx )) && minx=${X[i]}
  (( Y[i] < miny )) && miny=${Y[i]}
done
# xrandr wants non-negative positions — shift everything to start at 0,0
for ((i = 0; i < SCREENS; i++)); do X[$i]=$(( X[i] - minx )); Y[$i]=$(( Y[i] - miny )); done
# "N output x y" — the sekta-kiosk app shows these numbers ("Визначити екрани")
for ((i = 0; i < SCREENS; i++)); do echo "$((i + 1)) ${NAMES[$i]} ${X[$i]} ${Y[$i]}"; done > "$MAP_FILE" 2>/dev/null

# --- arrange the outputs -----------------------------------------------------
# Connected outputs that are not kiosk screens (e.g. a laptop panel) go to the
# right of the layout, so they never overlap a kiosk screen.
EXTRA=("${NAMES[@]:$SCREENS}")
ex=0
for ((i = 0; i < SCREENS; i++)); do (( X[i] + W[i] > ex )) && ex=$(( X[i] + W[i] )); done
EX=()
for o in "${EXTRA[@]}"; do
  EX+=("$ex")
  if [ "$BACKEND" = wlr ]; then
    ex=$(( ex + $(awk -v w="${SIZE_OF[$o]%x*}" -v b="${BASE_OF[$o]:-1}" 'BEGIN { printf "%d", w / b + 0.5 }') ))
  else
    ex=$(( ex + ${SIZE_OF[$o]%x*} ))
  fi
done
[ "${#EXTRA[@]}" -gt 0 ] && log "not kiosk screens, moved aside: ${EXTRA[*]}"
case "$BACKEND" in
  x11)
    args=()
    for ((i = 0; i < SCREENS; i++)); do
      f="$(xscale "${SIZES[$i]%x*}" "${W[$i]}")"
      args+=(--output "${NAMES[$i]}" --mode "${MODE_OF[${NAMES[$i]}]}" --scale "${f}x${f}" --pos "${X[$i]}x${Y[$i]}")
    done
    for ((i = 0; i < ${#EXTRA[@]}; i++)); do
      args+=(--output "${EXTRA[$i]}" --mode "${MODE_OF[${EXTRA[$i]}]}" --scale 1x1 --pos "${EX[$i]}x0")
    done
    diag "xrandr ${args[*]}"
    if xo="$(xrandr "${args[@]}" 2>&1)"; then diag "xrandr ok${xo:+: $xo}"
    else log "xrandr could not arrange the screens: $xo"; diag "xrandr FAILED: $xo"; fi
    { echo "right after xrandr:"; xshot; } >> "$DIAG_FILE" 2>/dev/null
    # does the desktop (GNOME/mutter) keep it? looked at again a bit later
    ( for t in 3 10 30; do sleep $(( t == 3 ? 3 : t == 10 ? 7 : 20 ))
        { echo "$(date +%T) ${t}s after xrandr:"; xshot; } >> "$DIAG_FILE" 2>/dev/null; done ) </dev/null >/dev/null 2>&1 &
    # not a kiosk window: out of the job table, `wait` / `wait -n` below skip it
    disown "$!" 2>/dev/null || true
    for ((i = 0; i < SCREENS; i++)); do echo "${NAMES[$i]} 1"; done > "$SCALE_MARK" 2>/dev/null
    ;;
  wlr)
    for ((i = 0; i < SCREENS; i++)); do
      diag "wlr-randr --output ${NAMES[$i]} --on --scale ${SCALE_F[$i]} --pos ${X[$i]},${Y[$i]}"
      wlr-randr --output "${NAMES[$i]}" --on --scale "${SCALE_F[$i]}" --pos "${X[$i]},${Y[$i]}" \
        || { log "wlr-randr could not place ${NAMES[$i]}"; diag "wlr-randr FAILED for ${NAMES[$i]}"; }
    done
    for ((i = 0; i < ${#EXTRA[@]}; i++)); do
      wlr-randr --output "${EXTRA[$i]}" --scale "${BASE_OF[${EXTRA[$i]}]:-1}" --pos "${EX[$i]},0" || true
    done
    # originals of everything touched — for restore_scales and the next start
    for o in "${NAMES[@]}"; do echo "$o ${BASE_OF[$o]:-1}"; done > "$SCALE_MARK" 2>/dev/null
    ;;
  none)
    diag "Wayland without wlr-randr: layout and zoom NOT applied"
    log "Wayland without wlr-randr — screen layout is left as set in display settings"
    ;;
esac
sleep 1

# Where the screens really are now (X11 / XWayland view, which is what
# Chromium uses below). If arranging failed or was not possible, every screen
# goes to the nearest real monitor instead of an empty spot.
mapfile -t mons < <(xrandr --listmonitors 2>/dev/null | awk 'NR > 1 {
  g = $3; gsub(/\/[0-9]+/, "", g); split(g, a, /[x+]/); print a[1], a[2], a[3], a[4] }')
if [ "${#mons[@]}" -gt 0 ]; then
  # normalise both sets to start at 0,0, then match centre to centre
  mx=999999; my=999999
  for m in "${mons[@]}"; do read -r _ _ ax ay <<< "$m"; (( ax < mx )) && mx=$ax; (( ay < my )) && my=$ay; done
  used=()
  for ((i = 0; i < SCREENS; i++)); do
    cx=$(( X[i] + W[i] / 2 )); cy=$(( Y[i] + H[i] / 2 ))
    best=-1; bestd=0
    for ((j = 0; j < ${#mons[@]}; j++)); do
      case " ${used[*]} " in *" $j "*) continue ;; esac
      read -r aw ah ax ay <<< "${mons[$j]}"
      dx=$(( ax - mx + aw / 2 - cx )); dy=$(( ay - my + ah / 2 - cy ))
      d=$(( dx * dx + dy * dy ))
      if (( best < 0 || d < bestd )); then best=$j; bestd=$d; fi
    done
    (( best < 0 )) && continue
    used+=("$best")
    read -r W[$i] H[$i] X[$i] Y[$i] <<< "${mons[$best]}"
    diag "screen $((i + 1)) window target: ${W[$i]}x${H[$i]}+${X[$i]}+${Y[$i]}"
  done
fi

# --- Chromium windows --------------------------------------------------------
# Under Wayland run Chromium through XWayland — native Wayland windows can't
# choose their screen.
extra=()
[ -n "${WAYLAND_DISPLAY:-}" ] && extra+=(--ozone-platform=x11)

PIDS=()
stop_all() { kill "${PIDS[@]}" 2>/dev/null; wait 2>/dev/null; }
trap 'stop_all; exit 0' TERM INT

url_of() { echo "${URLS[$1]:-${URLS[0]:-}}"; }
where() { echo "${NAMES[$1]:-?} ${W[$1]}x${H[$1]}+${X[$1]}+${Y[$1]}"; }

# Shared profile on X11 (e.g. GNOME on Xorg — the installer turns GDM's Wayland
# off for several screens): ONE Chromium with a window per screen, so a login
# counts on every screen. A second `chromium` on the same profile only hands
# its URL to the running one and ignores position flags — windows are put on
# their screens with wmctrl instead.
SHARED=""
if [ -z "${WAYLAND_DISPLAY:-}" ] && command -v wmctrl >/dev/null 2>&1 && wmctrl -m >/dev/null 2>&1; then
  SHARED=1
fi

if [ -n "$SHARED" ]; then
  # Chromium windows: "id x y w h" per line, oldest first
  windows() { wmctrl -lGx 2>/dev/null | awk 'tolower($7) ~ /chromium/ { print $1, $3, $4, $5, $6 }'; }
  # wait (up to $2 s) until there are at least $1 windows
  wait_windows() {
    local t
    for ((t = 0; t < $2 * 2; t++)); do
      [ "$(windows | wc -l)" -ge "$1" ] && return 0
      sleep 0.5
    done
    return 1
  }
  # full screen on screen $2 (0-based): drop full screen, move, full screen
  # again — the window manager makes a window full screen on its own monitor
  place() {
    wmctrl -i -r "$1" -b remove,fullscreen,maximized_vert,maximized_horz
    wmctrl -i -r "$1" -e "0,${X[$2]},${Y[$2]},${W[$2]},${H[$2]}"
    sleep 0.5
    wmctrl -i -r "$1" -b add,fullscreen
  }

  if [ "$RESTORE" = 1 ] && has_session "$(profile_of 1)"; then
    open=(--restore-last-session); log "restoring the pages from last time"
  else
    open=("$(url_of 0)")
  fi
  # The kiosk owns this profile: a Chromium already running on it (a browser
  # opened by hand, a kiosk not stopped yet) would take our start over its
  # singleton and exit at once — the watch below would then restart forever.
  # (comm is cut to 15 chars: chromium-browser → chromium-browse on RPi OS)
  if pgrep -u "$(id -u)" -x 'chromium|chromium-browse' >/dev/null 2>&1; then
    log "Chromium already running for $(id -un) — closing it first"
    pkill -u "$(id -u)" -x 'chromium|chromium-browse'
    for _ in $(seq 1 20); do pgrep -u "$(id -u)" -x 'chromium|chromium-browse' >/dev/null 2>&1 || break; sleep 0.5; done
  fi
  "$CHROMIUM" "${extra[@]}" --kiosk \
    --window-position="${X[0]},${Y[0]}" --window-size="${W[0]},${H[0]}" \
    "${CHROMIUM_FLAGS[@]}" "${open[@]}" &
  PIDS+=("$!")
  wait_windows 1 60 || { log "Chromium opened no window"; stop_all; exit 1; }
  # a restored session brings its windows one by one — give them time
  [ "${open[0]}" = --restore-last-session ] && wait_windows "$SCREENS" 15

  # Windows already open (restored) go to the nearest screen; screens left
  # without one get a new window with their site.
  mapfile -t wins < <(windows)
  ASSIGNED=()
  used=()
  for ((i = 0; i < SCREENS; i++)); do
    cx=$(( X[i] + W[i] / 2 )); cy=$(( Y[i] + H[i] / 2 ))
    best=-1; bestd=0
    for ((j = 0; j < ${#wins[@]}; j++)); do
      case " ${used[*]} " in *" $j "*) continue ;; esac
      read -r _ wx wy ww wh <<< "${wins[$j]}"
      dx=$(( wx + ww / 2 - cx )); dy=$(( wy + wh / 2 - cy ))
      d=$(( dx * dx + dy * dy ))
      if (( best < 0 || d < bestd )); then best=$j; bestd=$d; fi
    done
    if (( best >= 0 )); then
      used+=("$best"); ASSIGNED[$i]="${wins[$best]%% *}"
      log "screen $((i + 1)): $(where "$i") → window ${ASSIGNED[$i]}"
      continue
    fi
    before=" $(windows | awk '{ print $1 }' | tr '\n' ' ') "
    timeout 20 "$CHROMIUM" "${extra[@]}" "${CHROMIUM_FLAGS[@]}" --new-window "$(url_of "$i")" >/dev/null 2>&1
    if wait_windows $(( $(wc -w <<< "$before") + 1 )) 30; then
      # the new window = the id that was not there before
      for id in $(windows | awk '{ print $1 }'); do
        case "$before" in *" $id "*) ;; *) ASSIGNED[$i]="$id" ;; esac
      done
      log "screen $((i + 1)): $(where "$i") → $(url_of "$i")"
    else
      log "screen $((i + 1)): no new window appeared"
    fi
  done
  for ((i = 0; i < SCREENS; i++)); do
    [ -n "${ASSIGNED[$i]:-}" ] && place "${ASSIGNED[$i]}" "$i"
  done
  # Restored windows left over (fewer screens than last time, a saved pop-up)
  # would stay full screen on top of a kiosk screen — close them.
  for ((j = 0; j < ${#wins[@]}; j++)); do
    case " ${used[*]} " in *" $j "*) continue ;; esac
    log "closing extra restored window ${wins[$j]%% *}"
    wmctrl -i -c "${wins[$j]%% *}"
  done

  # A screen whose window got closed (or Chromium gone) → restart the set;
  # the restored session keeps the other screens' pages.
  while sleep 5; do
    kill -0 "${PIDS[0]}" 2>/dev/null || { log "Chromium exited — restarting"; break; }
    ids=" $(windows | awk '{ print $1 }' | tr '\n' ' ') "
    for id in "${ASSIGNED[@]}"; do
      case "$ids" in *" $id "*) ;; *) log "window $id closed — restarting all screens"; break 2 ;; esac
    done
  done
  stop_all
  exit 1
fi

# --- Fallback: one Chromium (own profile) per screen -------------------------
# Wayland without X11 window control: a second Chromium on the same profile
# would only open a window in the first process, ignoring position and --kiosk,
# so screens 2–3 get their own profiles (log in on each). Screen 1 keeps the
# default profile (logins from a single-screen kiosk stay).
for ((i = 0; i < SCREENS; i++)); do
  dir="$(profile_of $((i + 1)))"
  prof=()
  if (( i > 0 )); then
    mkdir -p "$dir"
    prof=(--user-data-dir="$dir")
  fi
  if [ "$RESTORE" = 1 ] && has_session "$dir"; then
    open=(--restore-last-session); what="pages from last time"
  else
    open=("$(url_of "$i")"); what="${open[0]}"
  fi
  log "screen $((i + 1)): $(where "$i") → $what"
  "$CHROMIUM" "${prof[@]}" "${extra[@]}" --kiosk \
    --window-position="${X[$i]},${Y[$i]}" --window-size="${W[$i]},${H[$i]}" \
    "${CHROMIUM_FLAGS[@]}" "${open[@]}" &
  PIDS+=("$!")
done

# First window to exit takes the others down; systemd restarts the set.
wait -n
log "a kiosk window exited — restarting all screens"
stop_all
exit 1
