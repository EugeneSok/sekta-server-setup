#!/usr/bin/env bash
#
# sekta-kiosk — the SEKTA kiosk display app (Ukrainian UI).
#
# The window is sekta-kiosk-gui.py (Python + GTK 4: screens as they stand,
# zoom, update, installer); without python3-gi / GTK 4 (or with
# SEKTA_KIOSK_ZENITY=1) this script shows the same in zenity windows.
#
# On a display with the kiosk installed (~/.local/bin/sekta-kiosk; menu entry
# «Sekta kiosk — екрани»; Ctrl+Alt+K, also over the full-screen kiosk):
#   - screens: add / remove a screen, its output, where it stands (clock hour
#     around screen 1) and its site; switches GNOME Wayland ⇄ Xorg as needed;
#   - identify screens (output name and kiosk number on every monitor);
#   - forget the remembered pages; restart / stop / start the kiosk.
#
# Installer — next to install-offline.sh and debs/, it installs the whole kiosk
# (pve-setup menu item 7) offline, asking the settings and the sudo password in
# windows:
#   - the Debian package sekta-kiosk (build-deb.sh; /usr/share/sekta-kiosk,
#     menu «Sekta kiosk»): first start installs, later ones manage; a newer
#     package offers to update the kiosk;
#   - a USB stick: bash /media/$USER/<stick>/kiosk/sekta-kiosk.sh
# Without zenity it opens a terminal, installs the bundled packages there
# (install-offline.sh --packages-only, sudo password) and goes on in windows.
#
#   sekta-kiosk --integrate     menu entry + Ctrl+Alt+K (run by the installers)
#   sekta-kiosk --unintegrate   remove them
#
set -u

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
ARGS=("$@")
HERE="$(dirname "$SELF")"
APP_BIN="$HOME/.local/bin/sekta-kiosk"
SCREENS_BIN="$HOME/.local/bin/sekta-kiosk-screens"
START_BIN="$HOME/.local/bin/sekta-kiosk-start"
CONF="$HOME/.config/sekta-kiosk/screens.conf"
SERVICE="chromium-kiosk.service"
MAP_FILE="${XDG_RUNTIME_DIR:-/tmp}/sekta-kiosk-screens.map"
DESKTOP_FILE="$HOME/.local/share/applications/sekta-kiosk.desktop"
ICON_FILE="$HOME/.local/share/icons/hicolor/512x512/apps/sekta-kiosk.png"
KB_LIST_SCHEMA="org.gnome.settings-daemon.plugins.media-keys"
KB_PATH="/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/sekta-kiosk/"
KB_SCHEMA="org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:$KB_PATH"
KB_BINDING="<Control><Alt>k"
DEFAULT_URL="https://combat.omega"
TITLE="Sekta kiosk"
LOG_FILE="$HOME/sekta-kiosk-install.log"
# the Debian package (build-deb.sh)
PKG_DIR=/usr/share/sekta-kiosk
INSTALLED_VERSION_FILE="$HOME/.config/sekta-kiosk/VERSION"
# where an offline install can come from: next to this script (stick or
# package), else the installed package (the hotkey runs ~/.local/bin's copy)
INSTALL_SRC=""
if [ -f "$HERE/install-offline.sh" ]; then INSTALL_SRC="$HERE"
elif [ -f "$PKG_DIR/install-offline.sh" ]; then INSTALL_SRC="$PKG_DIR"; fi

# --- menu entry + hotkey -----------------------------------------------------
have_gnome_keys() {
  command -v gsettings >/dev/null 2>&1 \
    && gsettings list-schemas 2>/dev/null | grep -x "$KB_LIST_SCHEMA" >/dev/null
}

integrate() {
  # the SEKTA icon: from the installer (SEKTA_KIOSK_ICON), next to this
  # script (stick / package) or the package's copy
  local src icon=video-display
  for src in "${SEKTA_KIOSK_ICON:-}" "$HERE/sekta-kiosk.png" /usr/share/sekta-kiosk/sekta-kiosk.png; do
    [ -n "$src" ] && [ -f "$src" ] || continue
    mkdir -p "$(dirname "$ICON_FILE")"
    cp "$src" "$ICON_FILE"
    break
  done
  [ -f "$ICON_FILE" ] && icon=sekta-kiosk
  # same desktop id as the package's entry: ours overrides it (one item in the
  # menu) and stays when the package is removed
  mkdir -p "$(dirname "$DESKTOP_FILE")"
  cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Type=Application
Name=Sekta kiosk — екрани
Comment=Екрани й сайти kiosk-дисплея (Ctrl+Alt+K)
Exec=$APP_BIN
Icon=$icon
Terminal=false
Categories=Settings;
EOF
  have_gnome_keys || return 0
  # custom shortcuts are a list of paths — append ours, keep the others
  local list
  list="$(gsettings get "$KB_LIST_SCHEMA" custom-keybindings)"
  case "$list" in
    *"'$KB_PATH'"*) ;;
    "@as []"|"[]") gsettings set "$KB_LIST_SCHEMA" custom-keybindings "['$KB_PATH']" ;;
    *) gsettings set "$KB_LIST_SCHEMA" custom-keybindings "${list%]}, '$KB_PATH']" ;;
  esac
  gsettings set "$KB_SCHEMA" name "Sekta kiosk"
  gsettings set "$KB_SCHEMA" command "$APP_BIN"
  gsettings set "$KB_SCHEMA" binding "$KB_BINDING"
}

unintegrate() {
  rm -f "$DESKTOP_FILE" "$ICON_FILE"
  have_gnome_keys || return 0
  local list
  list="$(gsettings get "$KB_LIST_SCHEMA" custom-keybindings)"
  case "$list" in *"'$KB_PATH'"*) ;; *) return 0 ;; esac
  list="$(printf '%s' "$list" | sed -e "s|, '$KB_PATH'||; s|'$KB_PATH', ||; s|'$KB_PATH'||")"
  [ "$list" = "[]" ] && list="@as []"
  gsettings set "$KB_LIST_SCHEMA" custom-keybindings "$list"
  gsettings reset-recursively "$KB_SCHEMA" 2>/dev/null || true
}

case "${1:-}" in
  --integrate)   integrate; exit $? ;;
  --unintegrate) unintegrate; exit $? ;;
  --install) ;;   # (re)install from INSTALL_SRC, then the menu
  "") ;;
  *) echo "usage: sekta-kiosk [--integrate|--unintegrate|--install]" >&2; exit 2 ;;
esac

# --- GUI helpers -------------------------------------------------------------
BUNDLE_NAME="$( . /etc/os-release; echo "${VERSION_CODENAME:-unknown}")-$(dpkg --print-architecture 2>/dev/null)"
# Debian installed with a root password has no sudo at all, and the first user
# is not in the sudo group — the installer needs sudo (packages, Plymouth,
# GRUB, autologin). The bundle carries sudo; one command as root fixes both.
has_sudo() {
  command -v sudo >/dev/null 2>&1 \
    && { sudo -n true 2>/dev/null || id -nG | tr ' ' '\n' | grep -x sudo >/dev/null; }
}
sudo_hint() {
  local deb=""
  command -v sudo >/dev/null 2>&1 || deb="apt install $INSTALL_SRC/debs/$BUNDLE_NAME/sudo_*.deb && "
  printf '%s\n' "Користувач $USER не має прав адміністратора (sudo)." \
    "Один раз у терміналі, з паролем root:" \
    "  su - -c \"${deb}usermod -aG sudo $USER\"" \
    "потім вийти з сеансу й увійти знову (або перезавантажити) і запустити Sekta kiosk ще раз."
}

# The GTK window: next to this script (stick / package: .py, ~/.local/bin:
# sekta-kiosk-gui), with python3-gi and GTK 4 there.
GUI=""
for g in "$HERE/sekta-kiosk-gui.py" "$HERE/sekta-kiosk-gui"; do
  if [ -f "$g" ]; then GUI="$g"; break; fi
done
gui_check() {
  [ -n "$GUI" ] && [ -z "${SEKTA_KIOSK_ZENITY:-}" ] && command -v python3 >/dev/null 2>&1 \
    && python3 -c 'import gi; gi.require_version("Gtk", "4.0"); gi.require_version("PangoCairo", "1.0"); gi.require_foreign("cairo"); from gi.repository import Gtk, PangoCairo' >/dev/null 2>&1
}
GUI_OK=""; if gui_check; then GUI_OK=1; fi   # once: a python + GTK load costs
gui_ok() { [ -n "$GUI_OK" ]; }

# one window at a time — a second Ctrl+Alt+K does nothing (also not a second
# package install in a terminal; the GTK window keeps the lock: fd 9 goes
# with exec)
exec 9>"${XDG_RUNTIME_DIR:-/tmp}/sekta-kiosk.lock"
flock -n 9 || exit 0

# No window toolkit yet (a bare Debian): install the bundled packages in a
# terminal — sudo asks the password there — then go on in windows. (zenity
# there but not GTK 4: offer_gtk asks in a zenity window, above the kiosk.)
if [ -n "$INSTALL_SRC" ] && ! gui_ok && ! command -v zenity >/dev/null 2>&1; then
  boot_dir="$(mktemp -d)"
  {
    echo "echo \$\$ > '$boot_dir/pid'"
    if has_sudo; then
      echo "echo 'Sekta kiosk: встановлення пакетів (без інтернету)…'"
      echo "bash '$INSTALL_SRC/install-offline.sh' --packages-only || { echo; echo 'Не вдалося. Натисніть Enter.'; read -r _; }"
    else
      sudo_hint > "$boot_dir/hint"
      echo "cat '$boot_dir/hint'"
      echo "echo; echo 'Натисніть Enter.'; read -r _"
    fi
    echo "touch '$boot_dir/done'"
  } > "$boot_dir/boot.sh"
  if [ -t 0 ]; then
    bash "$boot_dir/boot.sh"
  else
    started=""
    for term in gnome-terminal kgx ptyxis x-terminal-emulator xterm; do
      command -v "$term" >/dev/null 2>&1 || continue
      case "$term" in
        x-terminal-emulator|xterm) "$term" -e "bash $boot_dir/boot.sh" >/dev/null 2>&1 & ;;
        *) "$term" -- bash "$boot_dir/boot.sh" >/dev/null 2>&1 & ;;
      esac
      # terminals often return at once (a server opens the window): watch the
      # script itself — started within 20 s, then until it ends or the window
      # is closed
      for _ in $(seq 1 20); do [ -s "$boot_dir/pid" ] && break; sleep 1; done
      if [ -s "$boot_dir/pid" ]; then
        started=1
        while kill -0 "$(cat "$boot_dir/pid")" 2>/dev/null && [ ! -e "$boot_dir/done" ]; do sleep 1; done
        break
      fi
    done
    if [ -z "$started" ] && command -v notify-send >/dev/null 2>&1; then
      notify-send "Sekta kiosk" "Не вдалося відкрити термінал. Запустіть у терміналі: sekta-kiosk"
    fi
  fi
  rm -rf "$boot_dir"
  if gui_check; then GUI_OK=1; fi
fi
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || { echo "sekta-kiosk: потрібен графічний сеанс." >&2; exit 1; }

if gui_ok; then
  SEKTA_KIOSK_SRC="$INSTALL_SRC" SEKTA_KIOSK_SELF="$SELF" exec python3 "$GUI" "$@"
fi

if ! command -v zenity >/dev/null 2>&1; then
  echo "sekta-kiosk: потрібен python3-gi з GTK 4 або zenity (sudo apt install python3-gi python3-gi-cairo gir1.2-gtk-4.0)." >&2
  [ -n "$INSTALL_SRC" ] && \
    echo "Без нього можна встановити в терміналі: bash $INSTALL_SRC/install-offline.sh" >&2
  exit 1
fi

z() { zenity --title="$TITLE" "$@" 2>/dev/null; }
info_box() { z --info --width=460 --text="$1"; }
err_box()  { z --error --width=460 --text="$1"; }
ask()      { z --question --width=460 --text="$1" "${@:2}"; }
# Pango markup: a site with & or < would break the text
esc() { local t="${1//&/&amp;}"; t="${t//</&lt;}"; printf '%s' "${t//>/&gt;}"; }

# The kiosk windows are full screen; keep our dialogs above them (X11).
ONTOP_PID=""
if command -v wmctrl >/dev/null 2>&1 && [ -z "${WAYLAND_DISPLAY:-}" ]; then
  ( while kill -0 $$ 2>/dev/null; do
      wmctrl -lx 2>/dev/null | awk 'tolower($3) ~ /zenity/ { print $1 }' \
        | while read -r id; do wmctrl -i -r "$id" -b add,above 2>/dev/null; done
      sleep 1
    done ) 9>&- &   # not the lock: its sleep outlives a kill by up to 1 s
  ONTOP_PID=$!
fi
trap '[ -n "$ONTOP_PID" ] && kill "$ONTOP_PID" 2>/dev/null' EXIT

# launcher: installed one, or the copy on the stick (installer mode)
KS="$SCREENS_BIN"
[ -x "$KS" ] || KS="$HERE/kiosk-screens.sh"

# --- settings: N screens, S_URL / S_HOUR / S_OUT per screen (0-based) ---------
load_conf() {
  SCREENS=1; URLS=("$DEFAULT_URL"); LAYOUT=(); OUTPUTS=(); SCALES=()
  # shellcheck source=/dev/null
  [ -f "$CONF" ] && . "$CONF"
  [ "${#URLS[@]}" -gt 0 ] || URLS=("$DEFAULT_URL")
  N="$SCREENS"
  S_URL=(); S_HOUR=(-); S_OUT=(); S_SCALE=()
  local i
  if [ "$N" -eq 1 ]; then S_URL=("${URLS[*]}"); else
    for ((i = 0; i < N; i++)); do S_URL+=("${URLS[$i]:-${URLS[0]}}"); done
  fi
  for ((i = 1; i < N; i++)); do S_HOUR+=("${LAYOUT[$((i - 1))]:-3}"); done
  for ((i = 0; i < N; i++)); do S_OUT+=("${OUTPUTS[$i]:--}"); S_SCALE+=("${SCALES[$i]:-100}"); done
  LOADED_KEY="$(state_key)"
}

# screens, sites, layout, outputs of the editor state — what makes the
# remembered pages wrong (zoom does not); normalised like --write-conf writes
# them, so a conf with OUTPUTS=() equals its "- -" rewrite
state_key() {
  export_settings   # the very values --write-conf gets
  printf '%s' "$KIOSK_SCREENS|$KIOSK_URL|$KIOSK_LAYOUT|$KIOSK_OUTPUTS" | tr -s ' '
}

# Connected outputs (X11 names). On Wayland only XWAYLANDn is visible — then
# outputs can't be picked by name until GNOME runs on Xorg.
OUT_NAMES=(); OUT_SIZES=(); OUT_NOTE=""
detect_outputs() {
  local name size
  OUT_NAMES=(); OUT_SIZES=(); OUT_NOTE=""
  while read -r name size _; do
    [ -n "$name" ] || continue
    case "$name" in XWAYLAND*)
      OUT_NAMES=(); OUT_SIZES=()
      case "${XDG_CURRENT_DESKTOP:-}" in
        *GNOME*) OUT_NOTE="Зараз GNOME працює на Wayland — назви виходів недоступні. Лишіть «авто»; після переходу на X11 (перезавантаження) виходи можна вибрати тут." ;;
        *) OUT_NOTE="Назви виходів недоступні (Wayland без wlr-randr). Лишіть «авто» або встановіть wlr-randr." ;;
      esac
      return ;;
    esac
    OUT_NAMES+=("$name"); OUT_SIZES+=("$size")
  done < <(bash "$KS" --outputs 2>/dev/null)
}

hour_desc() {
  case "$1" in
    3)  echo "праворуч" ;;
    9)  echo "ліворуч" ;;
    12) echo "вище" ;;
    6)  echo "нижче" ;;
    2)  echo "праворуч, зсунутий вгору" ;;
    4)  echo "праворуч, зсунутий вниз" ;;
    8)  echo "ліворуч, зсунутий вниз" ;;
    10) echo "ліворуч, зсунутий вгору" ;;
    1)  echo "вище, зсунутий праворуч" ;;
    11) echo "вище, зсунутий ліворуч" ;;
    5)  echo "нижче, зсунутий праворуч" ;;
    7)  echo "нижче, зсунутий ліворуч" ;;
  esac
}
where_label() {
  if [ "$1" -eq 0 ]; then echo "головний"; else echo "${S_HOUR[$1]} год — $(hour_desc "${S_HOUR[$1]}")"; fi
}
scale_label() { if [ "$N" -eq 1 ]; then echo "—"; else echo "${S_SCALE[$1]} %"; fi; }
out_label() { if [ "${S_OUT[$1]}" = - ]; then echo "авто"; else echo "${S_OUT[$1]}"; fi; }

# --- screen editor -----------------------------------------------------------
edit_screen() {
  local i="$1" o sel h k rows=() words=()
  # output
  if [ "${S_OUT[$i]}" = - ]; then sel=TRUE; else sel=FALSE; fi
  rows+=("$sel" "авто" "основний вихід або наступний вільний")
  for ((k = 0; k < ${#OUT_NAMES[@]}; k++)); do
    if [ "${S_OUT[$i]}" = "${OUT_NAMES[$k]}" ]; then sel=TRUE; else sel=FALSE; fi
    rows+=("$sel" "${OUT_NAMES[$k]}" "${OUT_SIZES[$k]}")
  done
  o="$(z --list --radiolist --width=560 --height=340 \
    --text="Екран $((i + 1)): до якого виходу підключений монітор?
«Визначити екрани» в головному меню показує назву виходу на кожному моніторі.${OUT_NOTE:+

$OUT_NOTE}" \
    --column="" --column="Вихід" --column="Розмір" "${rows[@]}")" || return 0
  if [ "$o" = "авто" ]; then S_OUT[$i]=-; elif [ -n "$o" ]; then
    # one monitor, one screen: the screen that had this output goes to «авто»
    for ((k = 0; k < N; k++)); do
      if [ "$k" -ne "$i" ] && [ "${S_OUT[$k]}" = "$o" ]; then
        S_OUT[$k]=-
        info_box "Вихід $o був у екрана $((k + 1)) — йому тепер «авто»."
      fi
    done
    S_OUT[$i]="$o"
  fi

  # where it stands (not for screen 1 — the others are placed around it)
  if [ "$i" -gt 0 ]; then
    rows=()
    for h in 3 9 12 6 2 4 8 10 1 11 5 7; do
      if [ "${S_HOUR[$i]}" = "$h" ]; then sel=TRUE; else sel=FALSE; fi
      rows+=("$sel" "$h" "$(hour_desc "$h")")
    done
    o="$(z --list --radiolist --width=560 --height=500 \
      --text="Де стоїть екран $((i + 1)) відносно головного (екран 1)?
Година на циферблаті: 3 — праворуч, 9 — ліворуч, 12 — вище, 6 — нижче.
Кілька екранів з однією годиною стають в ряд (3 і 3 — два праворуч)." \
      --column="" --column="Година" --column="Де" "${rows[@]}")" || return 0
    [ -n "$o" ] && S_HOUR[$i]="$o"
  fi

  # zoom (several screens: one Chromium profile, its Ctrl+/- zoom is per site
  # and would change every screen — the system scales each screen instead)
  if [ "$N" -gt 1 ]; then
    rows=()
    for h in 100 110 125 150 175 200 75 90; do
      if [ "${S_SCALE[$i]}" = "$h" ]; then sel=TRUE; else sel=FALSE; fi
      case "$h" in
        100) k="звичайний" ;;
        75|90) k="дрібніше — більше вміщується" ;;
        *) k="більше — для великого чи далекого екрана" ;;
      esac
      rows+=("$sel" "$h" "$k")
    done
    o="$(z --list --radiolist --width=560 --height=420 \
      --text="Масштаб екрана $((i + 1)), %.
Задається для кожного екрана окремо. Ctrl+/− у браузері змінює всі екрани разом — для різних екранів масштаб ставте тут." \
      --column="" --column="%" --column="" "${rows[@]}")" || return 0
    [ -n "$o" ] && S_SCALE[$i]="$o"
  fi

  # site
  local t="Сайт для екрана $((i + 1)):"
  [ "$N" -eq 1 ] && t="Сайт. Кілька сайтів — через пробіл, відкриються вкладками:"
  o="$(z --entry --width=560 --text="$t" --entry-text="${S_URL[$i]}")" || return 0
  read -r -a words <<< "$o"
  [ "${#words[@]}" -gt 0 ] && S_URL[$i]="${words[*]}"
  return 0
}

add_screen() {
  if [ "$N" -ge 3 ]; then info_box "Щонайбільше 3 екрани."; return; fi
  local first rest
  read -r first rest <<< "${S_URL[0]}"
  # tabs are for one screen only — with several, each screen has one site
  S_URL[0]="$first"
  S_URL+=("$first"); S_HOUR+=(3); S_OUT+=(-); S_SCALE+=(100)
  N=$((N + 1))
  edit_screen $((N - 1))
}

remove_screen() {
  if [ "$N" -le 1 ]; then info_box "Лишився один екран — прибирати нічого."; return; fi
  local rows=() i o k
  for ((i = 0; i < N; i++)); do rows+=(FALSE "$((i + 1))" "$(out_label "$i")" "${S_URL[$i]}"); done
  o="$(z --list --radiolist --width=700 --height=300 --text="Який екран прибрати?" \
    --column="" --column="№" --column="Вихід" --column="Сайт" "${rows[@]}")" || return
  [ -n "$o" ] || return
  k=$((o - 1))
  S_URL=("${S_URL[@]:0:k}" "${S_URL[@]:k+1}")
  S_OUT=("${S_OUT[@]:0:k}" "${S_OUT[@]:k+1}")
  S_HOUR=("${S_HOUR[@]:0:k}" "${S_HOUR[@]:k+1}")
  S_SCALE=("${S_SCALE[@]:0:k}" "${S_SCALE[@]:k+1}")
  S_HOUR[0]=-   # the (new) screen 1 is the centre, it has no hour
  N=$((N - 1))
  [ "$k" -eq 0 ] && info_box "Головним став колишній екран 2. Перевірте, де стоять інші екрани відносно нього."
}

# Screens list until «$1» (Застосувати / Встановити) — 0; Скасувати — 1.
edit_screens() {
  local done_label="$1" rows i choice rc
  while :; do
    rows=()
    for ((i = 0; i < N; i++)); do
      rows+=("$((i + 1))" "$(out_label "$i")" "$(where_label "$i")" "$(scale_label "$i")" "${S_URL[$i]}")
    done
    choice="$(z --list --width=940 --height=340 \
      --text="Екрани kiosk-дисплея. Виберіть екран і натисніть «Змінити» — вихід, розташування, масштаб, сайт." \
      --column="№" --column="Вихід" --column="Де стоїть" --column="Масштаб" --column="Сайт" \
      --ok-label="Змінити" --cancel-label="Скасувати" \
      --extra-button="Додати екран" --extra-button="Прибрати екран" --extra-button="$done_label" \
      "${rows[@]}")"
    rc=$?
    case "$choice" in
      "Додати екран")   add_screen ;;
      "Прибрати екран") remove_screen ;;
      "$done_label")    return 0 ;;
      "")
        if [ "$rc" -eq 0 ]; then info_box "Спершу виберіть екран у списку."; else return 1; fi ;;
      *) edit_screen $(( ${choice%%|*} - 1 )) ;;
    esac
  done
}

# KIOSK_* for --write-conf / install-offline.sh from the editor state
export_settings() {
  local i w urls=()
  if [ "$N" -eq 1 ]; then urls=("${S_URL[0]}"); else
    for ((i = 0; i < N; i++)); do read -r w _ <<< "${S_URL[$i]}"; urls+=("$w"); done
  fi
  export KIOSK_SCREENS="$N" KIOSK_URL="${urls[*]}" KIOSK_LAYOUT="${S_HOUR[*]:1}" KIOSK_OUTPUTS="${S_OUT[*]}" \
    KIOSK_SCALE="${S_SCALE[*]}"
}

# --- kiosk control -----------------------------------------------------------
ks_stop()  { systemctl --user stop "$SERVICE" 2>/dev/null; }
ks_start() { "$START_BIN" 2>/dev/null || systemctl --user start "$SERVICE"; }

run_root() {
  if command -v pkexec >/dev/null 2>&1; then
    pkexec /bin/bash "$SCREENS_BIN" "$@"
  else
    err_box "Немає pkexec. Виконайте в терміналі:
sudo bash $SCREENS_BIN $*"
    return 1
  fi
}

apply_screens() {
  local before after err reboot="" gdm
  before="$LOADED_KEY"
  export_settings
  ks_stop
  if ! err="$("$SCREENS_BIN" --write-conf 2>&1)"; then
    err_box "Не збережено: $(esc "$err")"
    ks_start
    return
  fi
  load_conf
  after="$LOADED_KEY"
  # Any change of screens or sites: forget the remembered pages — restored
  # windows go to the nearest screen, after a new layout that is the wrong one.
  # (The kiosk is stopped: Chromium would save its session again on exit.)
  [ "$before" != "$after" ] && "$SCREENS_BIN" --reset 2>/dev/null

  # several screens need GNOME on Xorg; one screen gives Wayland back
  gdm="$("$SCREENS_BIN" --gdm-status)"
  if [ "$N" -gt 1 ] && [ "$gdm" != no-gdm ]; then
    if [ "$gdm" = wayland ]; then
      run_root --gdm x11 && reboot=1
    elif [ "${XDG_SESSION_TYPE:-}" = wayland ]; then
      reboot=1   # already switched, not rebooted yet
    fi
  elif [ "$N" -eq 1 ] && [ "$gdm" = x11-ours ]; then
    run_root --gdm wayland && \
      info_box "Один екран: GNOME повернеться на Wayland після наступного перезавантаження."
  fi

  if [ -n "$reboot" ]; then
    if ask "Для кількох екранів GNOME має працювати на X11 — це почне діяти після перезавантаження.

Перезавантажити зараз?" --ok-label="Перезавантажити" --cancel-label="Пізніше"; then
      systemctl reboot
      exit 0
    fi
  fi
  ks_start
  info_box "Збережено, kiosk перезапущено."
}

identify() {
  local mons=() m name w h x y label pids=()
  mapfile -t mons < <(xrandr --listmonitors 2>/dev/null | awk 'NR > 1 {
    g = $3; gsub(/\/[0-9]+/, "", g); split(g, a, /[x+]/); print $NF, a[1], a[2], a[3], a[4] }')
  if [ "${#mons[@]}" -eq 0 ]; then err_box "Не вдалося отримати список моніторів (xrandr)."; return; fi
  declare -A num=()
  local n o mx my
  # by output name, or by position — on labwc the X11 view names the monitors
  # XWAYLANDn, not like the map (HDMI-A-1)
  if [ -f "$MAP_FILE" ]; then
    while read -r n o mx my; do num[$o]="$n"; [ -n "$my" ] && num[@$mx,$my]="$n"; done < "$MAP_FILE"
  fi
  for m in "${mons[@]}"; do
    read -r name w h x y <<< "$m"
    n="${num[$name]:-${num[@$x,$y]:-}}"
    label="${n:+Екран $n}"
    zenity --info --title="sekta-id $name" --no-wrap \
      --text="<span size='xx-large' weight='bold'>${label:-$name}</span>

<span size='x-large'>$name</span>   ${w}×${h}" >/dev/null 2>&1 &
    pids+=("$!")
  done
  # put each label in the middle of its monitor (X11)
  if command -v wmctrl >/dev/null 2>&1; then
    sleep 1.5
    for m in "${mons[@]}"; do
      read -r name w h x y <<< "$m"
      wmctrl -r "sekta-id $name" -e "0,$((x + w / 2 - 200)),$((y + h / 2 - 100)),-1,-1" 2>/dev/null
      wmctrl -r "sekta-id $name" -b add,above 2>/dev/null
    done
  fi
  info_box "На кожному моніторі — назва його виходу (і номер kiosk-екрана, якщо kiosk працює на кількох екранах).

Закрийте це вікно, щоб прибрати підказки."
  kill "${pids[@]}" 2>/dev/null
}

main_menu() {
  local st toggle c
  while :; do
    load_conf
    if [ "$(systemctl --user is-active "$SERVICE" 2>/dev/null)" = active ]; then
      st="працює"; toggle="Зупинити kiosk"
    else
      st="зупинений"; toggle="Запустити kiosk"
    fi
    c="$(z --list --width=520 --height=380 --hide-header \
      --text="Екранів: $N. Kiosk $st.
Що зробити?" --column="Дія" \
      "Екрани й сайти" "Визначити екрани" "Повернути задані сайти" "Перезапустити kiosk" "$toggle" \
      "Оновити з файлу (.deb)" "Зібрати діагностику" ${INSTALL_SRC:+"Перевстановити kiosk ($(src_version))"})" || exit 0
    case "$c" in
      "Екрани й сайти")
        detect_outputs
        edit_screens "Застосувати" && apply_screens ;;
      "Визначити екрани") identify ;;
      "Повернути задані сайти")
        if ask "Забути відкриті сторінки на всіх екранах і відкрити задані сайти?"; then
          ks_stop; "$SCREENS_BIN" --reset 2>/dev/null; ks_start
        fi ;;
      "Перезапустити kiosk") ks_stop; ks_start ;;
      "Перевстановити kiosk"*) install_from_src ;;
      "Оновити з файлу (.deb)") update_from_deb ;;
      "Зібрати діагностику") collect_diag ;;
      "Зупинити kiosk") ks_stop ;;
      "Запустити kiosk") ks_start ;;
    esac
  done
}

# A dir with `sudo` (= sudo -A) and its askpass — a zenity password window;
# put first in PATH, sudo of the scripts run there asks in a window.
sudo_window_dir() {
  local t
  t="$(mktemp -d)"
  printf '#!/bin/sh\nexec /usr/bin/sudo -A "$@"\n' > "$t/sudo"
  printf '#!/bin/sh\nexec zenity --password --title="%s — пароль адміністратора" 2>/dev/null\n' "$TITLE" > "$t/askpass"
  chmod 755 "$t/sudo" "$t/askpass"
  echo "$t"
}

# --- update from a .deb (e.g. on a stick) ------------------------------------
# Pick sekta-kiosk_<ver>+<release>_<arch>.deb, install the package, then update
# the kiosk with the app and installer that came in it (screens, sites and
# pages stay).
# kiosk-screens --diag into ~/ and onto every writable stick under /media/$USER
collect_diag() {
  local name f saved="" d
  name="sekta-kiosk-diag-$(date +%Y%m%d-%H%M%S).txt"
  f="$HOME/$name"
  { "$SCREENS_BIN" --diag; echo; echo "== utility log $LOG_FILE"; cat "$LOG_FILE" 2>/dev/null; } > "$f" 2>&1 \
    && saved="$f"
  for d in /media/"$USER"/*/; do
    [ -d "$d" ] && cp "$f" "$d" 2>/dev/null && saved="$saved
${d%/}/$name"
  done
  sync
  # on screen, full-size — to photograph and send
  [ -n "$saved" ] || { err_box "Не вдалося записати файл діагностики."; return 0; }
  z --text-info --filename="$f" --width=1600 --height=1000 \
    --title="$TITLE — діагностика (сфотографуйте й надішліть; файл: $(echo $saved | tr '\n' ' '))" || true
}

update_from_deb() {
  local start f pkg arch ver rel cur myarch myrel extra=() t rc tmp
  start="$HOME"
  [ -d "/media/$USER" ] && start="/media/$USER"
  f="$(z --file-selection --title="$TITLE — пакет sekta-kiosk (.deb)" --filename="$start/" \
    --file-filter="Пакет sekta-kiosk | sekta-kiosk*.deb" --file-filter="Усі .deb | *.deb")" || return 0
  [ -f "$f" ] || return 0
  pkg="$(dpkg-deb -f "$f" Package 2>/dev/null)"
  if [ "$pkg" != sekta-kiosk ]; then
    err_box "$(esc "$(basename "$f")") — не пакет sekta-kiosk${pkg:+ (це $pkg)}."
    return 0
  fi
  arch="$(dpkg-deb -f "$f" Architecture)"; ver="$(dpkg-deb -f "$f" Version)"
  myarch="$(dpkg --print-architecture)"
  myrel="$( . /etc/os-release; echo "${VERSION_CODENAME:-}")"
  rel="${ver##*+}"
  if [ "$arch" != "$myarch" ] && [ "$arch" != all ]; then
    err_box "Пакет для $arch, а ця машина — $myarch. Потрібен sekta-kiosk_…+${myrel}_$myarch.deb."
    return 0
  fi
  if [ "$rel" != "$ver" ] && [ -n "$myrel" ] && [ "$rel" != "$myrel" ]; then
    err_box "Пакет для Debian «$rel», а ця машина — «$myrel». Потрібен sekta-kiosk_…+${myrel}_$myarch.deb."
    return 0
  fi
  if ! has_sudo; then err_box "$(esc "$(sudo_hint)")"; return 0; fi

  cur="$(dpkg-query -W -f='${Version}' sekta-kiosk 2>/dev/null || true)"
  if [ -n "$cur" ] && dpkg --compare-versions "$ver" eq "$cur"; then
    ask "Версія ${ver%%+*} вже встановлена. Встановити її ще раз і перевстановити kiosk?" \
      --ok-label="Перевстановити" --cancel-label="Скасувати" || return 0
    extra=(--reinstall)
  elif [ -n "$cur" ] && dpkg --compare-versions "$ver" lt "$cur"; then
    ask "Це старіша версія (${ver%%+*}), ніж встановлена (${cur%%+*}). Встановити все одно?" \
      --ok-label="Встановити" --cancel-label="Скасувати" || return 0
    extra=(--allow-downgrades)
  else
    ask "Оновити до версії ${ver%%+*}${cur:+ (встановлено ${cur%%+*})}?
Екрани, сайти й відкриті сторінки лишаться як є." --ok-label="Оновити" --cancel-label="Скасувати" || return 0
  fi

  # a copy apt's sandbox user can read (a stick is mounted for $USER only)
  tmp="$(mktemp -d)"; chmod 755 "$tmp"
  t="$(sudo_window_dir)"
  rc=0
  {
    echo "Копіювання $(basename "$f")…"
    cp "$f" "$tmp/sekta-kiosk.deb" && chmod 644 "$tmp/sekta-kiosk.deb" || exit 1
    echo "Встановлення пакета…"
    PATH="$t:$PATH" SUDO_ASKPASS="$t/askpass" sudo env DEBIAN_FRONTEND=noninteractive \
      apt-get install -y "${extra[@]}" "$tmp/sekta-kiosk.deb" </dev/null
  } > "$LOG_FILE" 2>&1 &
  local pid=$!
  ( while kill -0 "$pid" 2>/dev/null; do tail -n 1 "$LOG_FILE" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g; s/^/# /'; sleep 1; done ) \
    | z --progress --pulsate --auto-close --no-cancel --width=640 --text="Встановлення пакета…"
  wait "$pid" || rc=$?
  rm -rf "$t" "$tmp"
  if [ "$rc" -ne 0 ]; then
    z --text-info --width=860 --height=520 --filename="$LOG_FILE" \
      --title="$TITLE — пакет не встановлено (журнал: $LOG_FILE)"
    return 0
  fi
  # the kiosk itself: with the package's own (new) app and installer — exec,
  # also when this is the package's app: its file on disk is the new one now
  if [ -n "$ONTOP_PID" ]; then kill "$ONTOP_PID" 2>/dev/null; fi
  exec bash "$PKG_DIR/sekta-kiosk.sh" --install
}

# --- installer (from the stick) ----------------------------------------------
installer() {
  local bn="$BUNDLE_NAME" before after
  if [ ! -d "$INSTALL_SRC/debs/$bn" ] && [ ! -f "$INSTALL_SRC/debs/BUNDLE" ]; then
    err_box "Немає пакетів для цієї машини ($bn) у $INSTALL_SRC/debs.
Є: $(cd "$INSTALL_SRC/debs" 2>/dev/null && ls -d */ 2>/dev/null | tr -d / | tr '\n' ' ')
Потрібен пакет sekta-kiosk для $bn (build-deb.sh) або набір fetch-debs.sh з такої машини."
    return 1
  fi

  if ! has_sudo; then err_box "$(esc "$(sudo_hint)")"; return 1; fi
  load_conf   # a reinstall starts from this machine's current settings
  before="$LOADED_KEY"
  detect_outputs
  info_box "Встановлення kiosk-дисплея SEKTA без інтернету ($bn, версія $(src_version)).

Далі — екрани й сайти. Буде встановлено: екран завантаження з логотипом, Chromium на весь екран, автовхід, українська розкладка, без засинання; утиліта «Sekta kiosk — екрани» (Ctrl+Alt+K)." || return 1
  edit_screens "Встановити" || return 1
  export_settings
  # same screens and sites: keep the remembered pages; an installed kiosk is
  # overwritten in place, not torn down under the running session
  after="$(state_key)"
  if installed && [ "$before" = "$after" ]; then
    export KIOSK_KEEP_PAGES=1
  else
    unset KIOSK_KEEP_PAGES
  fi
  if installed; then export REINSTALL=keep; else unset REINSTALL; fi

  # sudo inside install-offline.sh asks for the password in a window
  local t rc
  t="$(sudo_window_dir)"
  ( cd "$INSTALL_SRC" && PATH="$t:$PATH" SUDO_ASKPASS="$t/askpass" bash ./install-offline.sh </dev/null ) 2>&1 \
    | tee "$LOG_FILE" \
    | sed -u 's/\x1b\[[0-9;]*m//g; s/^/# /' \
    | z --progress --pulsate --auto-close --no-cancel --width=640 --text="Встановлення…"
  rc="${PIPESTATUS[0]}"
  rm -rf "$t"

  if [ "$rc" -ne 0 ]; then
    z --text-info --width=860 --height=520 --filename="$LOG_FILE" \
      --title="$TITLE — помилка встановлення (журнал: $LOG_FILE)"
    return 1
  fi
  if ask "Kiosk встановлено. Він запуститься після перезавантаження.

Перезавантажити зараз?" --ok-label="Перезавантажити" --cancel-label="Пізніше"; then
    systemctl reboot
  fi
  return 0
}

src_version() { cat "$INSTALL_SRC/VERSION" 2>/dev/null || echo "?"; }
installed_version() { cat "$INSTALLED_VERSION_FILE" 2>/dev/null || echo "0"; }
installed() { [ -x "$SCREENS_BIN" ] && [ -f "$CONF" ]; }

# (Re)install with the app that came with the installer: the copy in
# ~/.local/bin (the hotkey) may be older than the package's install-offline.sh.
install_from_src() {
  if [ "$(readlink -f "$INSTALL_SRC/sekta-kiosk.sh")" != "$SELF" ]; then
    if [ -n "$ONTOP_PID" ]; then kill "$ONTOP_PID" 2>/dev/null; fi   # exec skips the EXIT trap
    exec bash "$INSTALL_SRC/sekta-kiosk.sh" --install
  fi
  installer
}

# zenity, no GTK 4 yet (e.g. a 1.2.0 kiosk got this package): offer the
# bundle's packages for the new window — in a zenity window (above the
# kiosk, password in a window). Declined or failed: asked again only with
# another package version.
GTK_TRIED="$HOME/.config/sekta-kiosk/gtk-offered"
offer_gtk() {
  local t rc
  [ -n "$INSTALL_SRC" ] && [ -n "$GUI" ] && [ -z "${SEKTA_KIOSK_ZENITY:-}" ] || return 0
  ls "$INSTALL_SRC/debs/$BUNDLE_NAME"/python3-gi-cairo_*.deb >/dev/null 2>&1 || return 0
  [ "$(cat "$GTK_TRIED" 2>/dev/null)" != "$(src_version)" ] || return 0
  has_sudo || return 0
  mkdir -p "$(dirname "$GTK_TRIED")"
  if ! ask "Для нового вікна Sekta kiosk потрібні пакети з набору (GTK 4, без інтернету).
Встановити зараз? Kiosk працюватиме далі." --ok-label="Встановити" --cancel-label="Пізніше"; then
    src_version > "$GTK_TRIED"; return 0
  fi
  t="$(sudo_window_dir)"
  ( PATH="$t:$PATH" SUDO_ASKPASS="$t/askpass" bash "$INSTALL_SRC/install-offline.sh" --packages-only </dev/null ) 2>&1 \
    | tee "$LOG_FILE" | sed -u 's/\x1b\[[0-9;]*m//g; s/^/# /' \
    | z --progress --pulsate --auto-close --no-cancel --width=640 --text="Встановлення пакетів…"
  rc="${PIPESTATUS[0]}"
  rm -rf "$t"
  if [ "$rc" -eq 0 ] && gui_check; then
    # the new window: start over (its exec reopens the lock)
    if [ -n "$ONTOP_PID" ]; then kill "$ONTOP_PID" 2>/dev/null; fi
    exec bash "$SELF" "${ARGS[@]}"
  fi
  src_version > "$GTK_TRIED"
  err_box "Пакети для нового вікна не встановлено (журнал: $LOG_FILE). Лишаються ці вікна."
}
offer_gtk

if [ "${1:-}" = "--install" ] && [ -n "$INSTALL_SRC" ]; then
  installer
elif ! installed; then
  if [ -z "$INSTALL_SRC" ]; then
    err_box "Kiosk на цій машині не встановлено (або встановлено старою версією без екранів).
Встановіть його: пакет sekta-kiosk, пункт 7 pve-setup, kiosk/install.sh або з флешки — bash sekta-kiosk.sh."
    exit 1
  fi
  installer || exit 1
elif [ -n "$INSTALL_SRC" ] && [ "$(src_version)" != "?" ] \
   && [ "$(printf '%s\n%s\n' "$(installed_version)" "$(src_version)" | sort -V | tail -1)" != "$(installed_version)" ]; then
  # a newer package / stick than what was installed
  if ask "Є новіша версія kiosk: $(src_version) (встановлено $(installed_version)).
Оновити зараз? Екрани, сайти й відкриті сторінки лишаться як є." --ok-label="Оновити" --cancel-label="Пізніше"; then
    install_from_src
  fi
fi
installed || exit 1
main_menu
