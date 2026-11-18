#!/usr/bin/env bash
#
# sekta-kiosk — the SEKTA kiosk display app (zenity windows, Ukrainian UI).
#
# On a display with the kiosk installed (~/.local/bin/sekta-kiosk; menu entry
# «Sekta kiosk — екрани»; Ctrl+Alt+K, also over the full-screen kiosk):
#   - screens: add / remove a screen, its output, where it stands (clock hour
#     around screen 1) and its site; switches GNOME Wayland ⇄ Xorg as needed;
#   - identify screens (output name and kiosk number on every monitor);
#   - forget the remembered pages; restart / stop / start the kiosk.
#
# From a USB stick, next to install-offline.sh and debs/ — run in a terminal:
#   bash /media/$USER/<stick>/kiosk/sekta-kiosk.sh
# installs the whole kiosk (pve-setup menu item 7) offline, asking the settings
# and the sudo password in windows.
#
#   sekta-kiosk --integrate     menu entry + Ctrl+Alt+K (run by the installers)
#   sekta-kiosk --unintegrate   remove them
#
set -u

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
HERE="$(dirname "$SELF")"
APP_BIN="$HOME/.local/bin/sekta-kiosk"
SCREENS_BIN="$HOME/.local/bin/sekta-kiosk-screens"
START_BIN="$HOME/.local/bin/sekta-kiosk-start"
CONF="$HOME/.config/sekta-kiosk/screens.conf"
SERVICE="chromium-kiosk.service"
MAP_FILE="${XDG_RUNTIME_DIR:-/tmp}/sekta-kiosk-screens.map"
DESKTOP_FILE="$HOME/.local/share/applications/sekta-kiosk.desktop"
KB_LIST_SCHEMA="org.gnome.settings-daemon.plugins.media-keys"
KB_PATH="/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/sekta-kiosk/"
KB_SCHEMA="org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:$KB_PATH"
KB_BINDING="<Control><Alt>k"
DEFAULT_URL="https://combat.omega"
TITLE="Sekta kiosk"
LOG_FILE="$HOME/sekta-kiosk-install.log"

# --- menu entry + hotkey -----------------------------------------------------
have_gnome_keys() {
  command -v gsettings >/dev/null 2>&1 \
    && gsettings list-schemas 2>/dev/null | grep -x "$KB_LIST_SCHEMA" >/dev/null
}

integrate() {
  mkdir -p "$(dirname "$DESKTOP_FILE")"
  cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Type=Application
Name=Sekta kiosk — екрани
Comment=Екрани й сайти kiosk-дисплея (Ctrl+Alt+K)
Exec=$APP_BIN
Icon=video-display
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
  rm -f "$DESKTOP_FILE"
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
  "") ;;
  *) echo "usage: sekta-kiosk [--integrate|--unintegrate]" >&2; exit 2 ;;
esac

# --- GUI helpers -------------------------------------------------------------
if ! command -v zenity >/dev/null 2>&1; then
  echo "sekta-kiosk: потрібен zenity (sudo apt install zenity)." >&2
  [ -f "$HERE/install-offline.sh" ] && \
    echo "Без нього можна встановити з флешки в терміналі: bash $HERE/install-offline.sh" >&2
  exit 1
fi
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || { echo "sekta-kiosk: потрібен графічний сеанс." >&2; exit 1; }

# one window at a time — a second Ctrl+Alt+K does nothing
exec 9>"${XDG_RUNTIME_DIR:-/tmp}/sekta-kiosk.lock"
flock -n 9 || exit 0

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
    done ) &
  ONTOP_PID=$!
fi
trap '[ -n "$ONTOP_PID" ] && kill "$ONTOP_PID" 2>/dev/null' EXIT

# launcher: installed one, or the copy on the stick (installer mode)
KS="$SCREENS_BIN"
[ -x "$KS" ] || KS="$HERE/kiosk-screens.sh"

# --- settings: N screens, S_URL / S_HOUR / S_OUT per screen (0-based) ---------
load_conf() {
  SCREENS=1; URLS=("$DEFAULT_URL"); LAYOUT=(); OUTPUTS=()
  # shellcheck source=/dev/null
  [ -f "$CONF" ] && . "$CONF"
  [ "${#URLS[@]}" -gt 0 ] || URLS=("$DEFAULT_URL")
  N="$SCREENS"
  S_URL=(); S_HOUR=(-); S_OUT=()
  local i
  if [ "$N" -eq 1 ]; then S_URL=("${URLS[*]}"); else
    for ((i = 0; i < N; i++)); do S_URL+=("${URLS[$i]:-${URLS[0]}}"); done
  fi
  for ((i = 1; i < N; i++)); do S_HOUR+=("${LAYOUT[$((i - 1))]:-3}"); done
  for ((i = 0; i < N; i++)); do S_OUT+=("${OUTPUTS[$i]:--}"); done
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
  S_URL+=("$first"); S_HOUR+=(3); S_OUT+=(-)
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
      rows+=("$((i + 1))" "$(out_label "$i")" "$(where_label "$i")" "${S_URL[$i]}")
    done
    choice="$(z --list --width=860 --height=340 \
      --text="Екрани kiosk-дисплея. Виберіть екран і натисніть «Змінити» — вихід, розташування, сайт." \
      --column="№" --column="Вихід" --column="Де стоїть" --column="Сайт" \
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
  export KIOSK_SCREENS="$N" KIOSK_URL="${urls[*]}" KIOSK_LAYOUT="${S_HOUR[*]:1}" KIOSK_OUTPUTS="${S_OUT[*]}"
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
  before="$SCREENS|${URLS[*]}|${LAYOUT[*]}|${OUTPUTS[*]}"
  export_settings
  ks_stop
  if ! err="$("$SCREENS_BIN" --write-conf 2>&1)"; then
    err_box "Не збережено: $(esc "$err")"
    ks_start
    return
  fi
  load_conf
  after="$SCREENS|${URLS[*]}|${LAYOUT[*]}|${OUTPUTS[*]}"
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
      "Екрани й сайти" "Визначити екрани" "Повернути задані сайти" "Перезапустити kiosk" "$toggle")" || exit 0
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
      "Зупинити kiosk") ks_stop ;;
      "Запустити kiosk") ks_start ;;
    esac
  done
}

# --- installer (from the stick) ----------------------------------------------
installer() {
  local bn
  bn="$( . /etc/os-release; echo "${VERSION_CODENAME:-unknown}")-$(dpkg --print-architecture)"
  if [ ! -d "$HERE/debs/$bn" ] && [ ! -f "$HERE/debs/BUNDLE" ]; then
    err_box "На флешці немає пакетів для цієї машини ($bn).
Є: $(cd "$HERE/debs" 2>/dev/null && ls -d */ 2>/dev/null | tr -d / | tr '\n' ' ')
Зберіть їх на машині з тим самим релізом і архітектурою: ./fetch-debs.sh"
    exit 1
  fi

  load_conf   # a reinstall starts from this machine's current settings
  detect_outputs
  info_box "Встановлення kiosk-дисплея SEKTA з флешки, без інтернету ($bn).

Далі — екрани й сайти. Буде встановлено: екран завантаження з логотипом, Chromium на весь екран, автовхід, українська розкладка, без засинання; утиліта «Sekta kiosk — екрани» (Ctrl+Alt+K)." || exit 0
  edit_screens "Встановити" || exit 0
  export_settings

  # sudo inside install-offline.sh asks for the password in a window
  local t rc
  t="$(mktemp -d)"
  printf '#!/bin/sh\nexec /usr/bin/sudo -A "$@"\n' > "$t/sudo"
  printf '#!/bin/sh\nexec zenity --password --title="%s — пароль адміністратора" 2>/dev/null\n' "$TITLE" > "$t/askpass"
  chmod 755 "$t/sudo" "$t/askpass"
  ( cd "$HERE" && PATH="$t:$PATH" SUDO_ASKPASS="$t/askpass" bash ./install-offline.sh </dev/null ) 2>&1 \
    | tee "$LOG_FILE" \
    | sed -u 's/\x1b\[[0-9;]*m//g; s/^/# /' \
    | z --progress --pulsate --auto-close --no-cancel --width=640 --text="Встановлення…"
  rc="${PIPESTATUS[0]}"
  rm -rf "$t"

  if [ "$rc" -ne 0 ]; then
    z --text-info --width=860 --height=520 --filename="$LOG_FILE" \
      --title="$TITLE — помилка встановлення (журнал: $LOG_FILE)"
    exit 1
  fi
  if ask "Kiosk встановлено. Він запуститься після перезавантаження.

Перезавантажити зараз?" --ok-label="Перезавантажити" --cancel-label="Пізніше"; then
    systemctl reboot
  fi
  exit 0
}

if [ -f "$HERE/install-offline.sh" ] && [ "$SELF" != "$(readlink -f "$APP_BIN" 2>/dev/null)" ]; then
  if [ -x "$SCREENS_BIN" ] && [ -f "$CONF" ]; then
    c="$(z --list --width=520 --height=260 --hide-header --text="Kiosk уже встановлено на цій машині." \
      --column="Дія" "Керувати kiosk (екрани й сайти)" "Перевстановити з флешки")" || exit 0
    case "$c" in
      "Перевстановити з флешки") installer ;;
      "") exit 0 ;;
    esac
  else
    installer
  fi
fi

if [ ! -x "$SCREENS_BIN" ] || [ ! -f "$CONF" ]; then
  err_box "Kiosk на цій машині не встановлено (або встановлено старою версією без екранів).
Встановіть його: пункт 7 pve-setup, kiosk/install.sh або з флешки — bash sekta-kiosk.sh."
  exit 1
fi
main_menu
