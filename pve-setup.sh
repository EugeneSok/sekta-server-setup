#!/usr/bin/env bash
#
# pve-setup.sh — інтерактивне налаштування Proxmox VE (останні версії)
#
# Модулі:
#   1) GPU passthrough (детект на хості, пріоритет iGPU, крок за кроком)
#   2) Додатковий storage з USB-флешки (примусово exFAT, форматує якщо інший FS)
#   3) Перевірка мережевих інтерфейсів + створення bridge на вільному
#
# Запускати ТІЛЬКИ на хості Proxmox під root.
# Кожна руйнівна дія — з окремим підтвердженням.

set -euo pipefail

# ----- кольори / лог -----
RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; BLU=$'\e[34m'; BLD=$'\e[1m'; RST=$'\e[0m'
info(){ echo "${BLU}[i]${RST} $*"; }
ok(){   echo "${GRN}[ok]${RST} $*"; }
warn(){ echo "${YEL}[!]${RST} $*"; }
err(){  echo "${RED}[x]${RST} $*" >&2; }
die(){  err "$*"; exit 1; }

# yes/no, повертає 0 на yes
confirm(){
  local prompt="${1:-Продовжити?}" ans
  read -rp "${BLD}${prompt}${RST} [y/N] " ans || true
  [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
}

need_root(){ [[ $EUID -eq 0 ]] || die "Запусти під root."; }

check_pve(){
  if ! command -v pveversion >/dev/null 2>&1; then
    warn "pveversion не знайдено — це схоже НЕ хост Proxmox."
    confirm "Все одно продовжити?" || die "Скасовано."
  else
    info "Proxmox: $(pveversion | head -n1)"
  fi
}

# ============================================================
#  Визначення bootloader і додавання параметра ядра
# ============================================================
# PVE на ZFS/UEFI використовує systemd-boot (proxmox-boot-tool),
# на ext4/LVM зазвичай GRUB. Визначаємо автоматично.
detect_bootloader(){
  if [[ -f /etc/kernel/proxmox-boot-uuids ]] || \
     { command -v proxmox-boot-tool >/dev/null 2>&1 && proxmox-boot-tool status >/dev/null 2>&1 && [[ -f /etc/kernel/cmdline ]]; }; then
    echo "systemd-boot"
  else
    echo "grub"
  fi
}

# додати параметр у cmdline ядра (ідемпотентно)
add_kernel_param(){
  local param="$1" bl
  bl="$(detect_bootloader)"
  info "Bootloader: ${BLD}${bl}${RST}"

  if [[ "$bl" == "systemd-boot" ]]; then
    local f=/etc/kernel/cmdline
    [[ -f "$f" ]] || die "Немає $f — не можу оновити cmdline."
    if grep -qw -- "$param" "$f"; then
      ok "Параметр '$param' вже присутній у $f"
    else
      cp -a "$f" "${f}.bak.$(date +%s)"
      sed -i "s|$| ${param}|" "$f"
      # прибрати можливі подвійні пробіли
      sed -i 's/  \+/ /g' "$f"
      ok "Додано '$param' у $f"
    fi
    info "Оновлюю boot config (proxmox-boot-tool refresh)…"
    proxmox-boot-tool refresh
  else
    local f=/etc/default/grub
    [[ -f "$f" ]] || die "Немає $f."
    if grep -q "GRUB_CMDLINE_LINUX_DEFAULT" "$f" && \
       grep "GRUB_CMDLINE_LINUX_DEFAULT" "$f" | grep -qw -- "$param"; then
      ok "Параметр '$param' вже присутній у $f"
    else
      cp -a "$f" "${f}.bak.$(date +%s)"
      sed -i "s|\(GRUB_CMDLINE_LINUX_DEFAULT=\"[^\"]*\)\"|\1 ${param}\"|" "$f"
      sed -i 's/  \+/ /g' "$f"
      ok "Додано '$param' у $f"
    fi
    info "Оновлюю GRUB (update-grub)…"
    update-grub
  fi
}

# ============================================================
#  МОДУЛЬ 1: GPU passthrough
# ============================================================
gpu_passthrough(){
  echo
  echo "${BLD}=== GPU passthrough ===${RST}"

  # CPU vendor → правильний IOMMU-параметр
  local cpu_vendor iommu_param
  cpu_vendor="$(grep -m1 -oE 'GenuineIntel|AuthenticAMD' /proc/cpuinfo || echo unknown)"
  case "$cpu_vendor" in
    GenuineIntel) iommu_param="intel_iommu=on" ;;
    AuthenticAMD) iommu_param="amd_iommu=on"   ;;
    *) warn "CPU vendor невідомий, беру intel_iommu=on"; iommu_param="intel_iommu=on" ;;
  esac
  info "CPU: ${cpu_vendor} → ${iommu_param}"

  # Список GPU. Формат: index|pci_addr|vendor:device|driver|is_igpu|desc
  mapfile -t gpu_lines < <(
    lspci -Dnn | grep -iE 'VGA compatible controller|3D controller|Display controller' || true
  )
  [[ ${#gpu_lines[@]} -gt 0 ]] || die "GPU не знайдено (lspci)."

  local -a G_ADDR G_IDS G_DESC G_IGPU G_DRV
  local i=0 default_idx=-1
  echo
  echo "Знайдені GPU:"
  for line in "${gpu_lines[@]}"; do
    local addr ids desc drv igpu="no"
    addr="$(awk '{print $1}' <<<"$line")"                       # напр. 0000:00:02.0
    ids="$(grep -oE '\[[0-9a-f]{4}:[0-9a-f]{4}\]' <<<"$line" | tail -n1 | tr -d '[]')"
    desc="$(sed -E 's/^[^ ]+ //' <<<"$line")"
    drv="$(lspci -Dks "$addr" 2>/dev/null | awk -F': ' '/Kernel driver in use/{print $2}')"
    [[ -z "$drv" ]] && drv="(немає)"
    # iGPU евристика: Intel i915/xe на 00:02.0, або AMD Raphael/iGPU
    if grep -qiE 'intel|i915|xe|amd.*(raphael|renoir|cezanne|vega.*mobile|radeon vega)' <<<"$desc" \
       && grep -qE ':0[0-2]\.' <<<"$addr"; then
      igpu="yes"
    fi
    G_ADDR[i]="$addr"; G_IDS[i]="$ids"; G_DESC[i]="$desc"; G_IGPU[i]="$igpu"; G_DRV[i]="$drv"
    local tag=""; [[ "$igpu" == "yes" ]] && { tag=" ${GRN}[iGPU]${RST}"; [[ $default_idx -lt 0 ]] && default_idx=$i; }
    printf "  ${BLD}%d${RST}) %s  ids=%s  driver=%s%s\n" "$i" "$desc" "$ids" "$drv" "$tag"
    ((i++))
  done
  [[ $default_idx -lt 0 ]] && default_idx=0   # немає iGPU → перший

  echo
  info "Пріоритет за замовчуванням: iGPU (індекс ${default_idx})."
  local sel
  read -rp "Який GPU ізолювати для passthrough? [${default_idx}] " sel || true
  sel="${sel:-$default_idx}"
  [[ "$sel" =~ ^[0-9]+$ && $sel -lt $i ]] || die "Невірний вибір."

  local addr="${G_ADDR[$sel]}" ids="${G_IDS[$sel]}" desc="${G_DESC[$sel]}"
  echo
  warn "Обрано: ${BLD}${desc}${RST}"
  warn "PCI: ${addr}  IDs: ${ids}"
  warn "УВАГА: якщо це GPU, яку хост використовує для консолі/дисплею —"
  warn "після passthrough локальна консоль хоста ПРОПАДЕ. Керуй по SSH/web."
  confirm "Продовжити ізоляцію цього GPU?" || { warn "GPU-модуль скасовано."; return 0; }

  # Зібрати ВСІ id функцій на тому ж слоті (GPU + його HDMI-audio)
  local slot="${addr%.*}"   # 0000:00:02
  local all_ids
  all_ids="$(lspci -Dn | awk -v s="$slot" '$1 ~ "^"s"\\." {print $3}' | sort -u | paste -sd, -)"
  [[ -z "$all_ids" ]] && all_ids="$ids"
  info "IDs для vfio-pci (весь слот): ${all_ids}"

  # 1. IOMMU параметр ядра
  add_kernel_param "$iommu_param"
  # pt для Intel (passthrough mode) — безпечно
  [[ "$iommu_param" == "intel_iommu=on" ]] && add_kernel_param "iommu=pt"

  # Intel iGPU = зазвичай основний дисплей хоста. Треба звільнити
  # framebuffer, інакше host тримає карту і vfio-pci не захопить.
  if [[ "${G_IGPU[$sel]}" == "yes" && "${desc,,}" == *intel* ]]; then
    warn "Intel iGPU: додаю параметри звільнення framebuffer хоста."
    add_kernel_param "initcall_blacklist=sysfb_init"   # kernel 5.18+ (сучасний PVE)
    add_kernel_param "video=efifb:off"
    add_kernel_param "video=vesafb:off"
  fi

  # 2. vfio модулі в /etc/modules (kernel 6.2+: vfio_virqfd не потрібен)
  local modf=/etc/modules
  for m in vfio vfio_iommu_type1 vfio_pci; do
    grep -qxF "$m" "$modf" 2>/dev/null || echo "$m" >> "$modf"
  done
  ok "vfio модулі додані у $modf"

  # 3. vfio-pci ids
  echo "options vfio-pci ids=${all_ids} disable_vga=1" > /etc/modprobe.d/vfio.conf
  ok "Записано /etc/modprobe.d/vfio.conf"

  # 4. blacklist рідного драйвера
  local blk=/etc/modprobe.d/blacklist-gpu.conf
  : > "$blk"
  case "${desc,,}" in
    *nvidia*) printf 'blacklist nouveau\nblacklist nvidia\nblacklist nvidiafb\n' >> "$blk" ;;
    *intel*)  printf 'blacklist i915\nblacklist xe\n' >> "$blk" ;;
    *amd*|*radeon*|*ati*) printf 'blacklist amdgpu\nblacklist radeon\n' >> "$blk" ;;
    *) warn "Драйвер не вгадав — blacklist не додано, перевір вручну." ;;
  esac
  [[ -s "$blk" ]] && ok "Blacklist драйвера → $blk"

  # 5. оновити initramfs
  info "update-initramfs -u -k all…"
  update-initramfs -u -k all

  echo
  ok "GPU passthrough налаштовано."
  warn "Потрібен ${BLD}REBOOT${RST}. Після ребуту перевір:"
  echo "    dmesg | grep -e DMAR -e IOMMU"
  echo "    lspci -Dks ${addr}   # 'Kernel driver in use: vfio-pci'"
  GPU_NEEDS_REBOOT=1
}

# ============================================================
#  МОДУЛЬ 2: USB storage (exFAT)
# ============================================================
usb_storage(){
  echo
  echo "${BLD}=== USB storage (exFAT) ===${RST}"

  # драйвери exfat
  if ! command -v mkfs.exfat >/dev/null 2>&1 || ! command -v mount.exfat-fuse >/dev/null 2>&1; then
    info "Ставлю exfat пакети…"
    apt-get update -qq
    apt-get install -y exfat-fuse exfatprogs
  fi

  # список знімних дисків
  echo
  echo "Знайдені диски:"
  lsblk -dpno NAME,SIZE,TYPE,TRAN,MODEL | grep -E 'disk' || true
  echo
  info "USB-диски зазвичай мають TRAN=usb."
  local dev
  read -rp "Вкажи пристрій флешки (напр. /dev/sda): " dev || true
  [[ -b "$dev" ]] || die "Немає block-device: $dev"

  # захист: не системний диск
  local rootsrc; rootsrc="$(findmnt -no SOURCE / || true)"
  if [[ "$rootsrc" == "$dev"* ]]; then
    die "$dev виглядає як системний диск (корінь на ньому). Відмова."
  fi

  echo
  warn "Обрано пристрій: ${BLD}${dev}${RST}"
  lsblk -pno NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "$dev"
  echo

  # цільовий розділ = перший розділ, або сам диск
  local part
  part="$(lsblk -pnro NAME,TYPE "$dev" | awk '$2=="part"{print $1; exit}')"
  [[ -z "$part" ]] && part="$dev"

  local fstype; fstype="$(blkid -o value -s TYPE "$part" 2>/dev/null || true)"
  info "Розділ: ${part}  FS: ${fstype:-невідомо}"

  if [[ "$fstype" == "exfat" ]]; then
    ok "Вже exFAT — форматувати не треба."
  else
    warn "FS не exFAT (${fstype:-порожньо})."
    warn "${RED}${BLD}ФОРМАТУВАННЯ ЗІТРЕ ВСІ ДАНІ на ${dev}!${RST}"
    confirm "Форматувати ${dev} у exFAT?" || die "Скасовано користувачем."
    read -rp "Введи ${BLD}FORMAT${RST} для підтвердження: " c || true
    [[ "$c" == "FORMAT" ]] || die "Не підтверджено."

    # розмонтувати все з цього диску
    umount "${dev}"* 2>/dev/null || true

    info "Створюю нову таблицю розділів (GPT) + один розділ…"
    command -v sgdisk >/dev/null 2>&1 || apt-get install -y gdisk
    sgdisk --zap-all "$dev"
    sgdisk -n1:0:0 -t1:0700 "$dev"     # 0700 = Microsoft basic data
    partprobe "$dev"; sleep 2
    part="$(lsblk -pnro NAME,TYPE "$dev" | awk '$2=="part"{print $1; exit}')"
    [[ -n "$part" ]] || die "Не знайшов новий розділ."
    info "mkfs.exfat на ${part}…"
    mkfs.exfat -L PVEUSB "$part"
    ok "Відформатовано у exFAT: ${part}"
  fi

  # UUID + fstab + mount
  local uuid; uuid="$(blkid -o value -s UUID "$part")"
  [[ -n "$uuid" ]] || die "Не отримав UUID."
  local mnt=/mnt/usb
  mkdir -p "$mnt"

  local fstab_line="UUID=${uuid} ${mnt} exfat defaults,uid=0,gid=0,umask=000,nofail 0 0"
  if grep -q "UUID=${uuid}" /etc/fstab; then
    ok "Запис у /etc/fstab вже є."
  else
    cp -a /etc/fstab "/etc/fstab.bak.$(date +%s)"
    echo "$fstab_line" >> /etc/fstab
    ok "Додано у /etc/fstab (з nofail): ${fstab_line}"
  fi

  info "Перевірка: mount -a…"
  mount -a
  mountpoint -q "$mnt" && ok "Змонтовано на ${mnt}" || warn "Не змонтувалось — перевір вручну."
  ls -lh "$mnt" || true

  # додати як Proxmox storage
  if command -v pvesm >/dev/null 2>&1; then
    if pvesm status 2>/dev/null | awk '{print $1}' | grep -qx USB; then
      ok "Storage 'USB' вже існує у Proxmox."
    elif confirm "Додати як Proxmox directory storage (id=USB, content=backup)?"; then
      pvesm add dir USB --path "$mnt" --content backup --is_mountpoint 1
      ok "Додано storage 'USB' → ${mnt}"
    fi
  fi
  ok "USB storage готовий."
}

# ============================================================
#  МОДУЛЬ 3: мережеві інтерфейси + bridge
# ============================================================
network_bridge(){
  echo
  echo "${BLD}=== Мережеві інтерфейси / bridge ===${RST}"

  echo
  echo "Фізичні інтерфейси:"
  ip -br link show | awk '$1 !~ /^(lo|vmbr|veth|tap|fwln|fwpr|fwbr|bond)/'
  echo
  echo "Наявні bridge:"
  ip -br link show type bridge 2>/dev/null || true
  echo

  # знайти вільні фізичні NIC: без IP і не в жодному bridge
  local -a free=()
  local ifc
  while read -r ifc; do
    [[ "$ifc" =~ ^(lo|vmbr|veth|tap|fwbr|fwln|fwpr|bond|dummy) ]] && continue
    # тільки реальні ethernet
    [[ -e "/sys/class/net/$ifc/device" ]] || continue
    # має IP?
    if ip -4 addr show "$ifc" 2>/dev/null | grep -q 'inet '; then continue; fi
    # уже член bridge?
    if [[ -n "$(ls /sys/class/net/*/brif/"$ifc" 2>/dev/null)" ]]; then continue; fi
    # згаданий у /etc/network/interfaces як bridge-port?
    if grep -qE "bridge-ports.*\b${ifc}\b" /etc/network/interfaces 2>/dev/null; then continue; fi
    free+=("$ifc")
  done < <(ls /sys/class/net)

  if [[ ${#free[@]} -eq 0 ]]; then
    warn "Вільних фізичних інтерфейсів немає — bridge не створюю."
    return 0
  fi

  echo "Вільні інтерфейси (без IP, не в bridge):"
  local n=0
  for ifc in "${free[@]}"; do
    local st; st="$(cat /sys/class/net/"$ifc"/operstate 2>/dev/null || echo '?')"
    printf "  ${BLD}%d${RST}) %s  (state=%s)\n" "$n" "$ifc" "$st"
    ((n++))
  done
  echo
  confirm "Створити новий bridge на вільному інтерфейсі?" || { warn "Пропущено."; return 0; }

  local sel
  read -rp "Який інтерфейс? [0] " sel || true; sel="${sel:-0}"
  [[ "$sel" =~ ^[0-9]+$ && $sel -lt $n ]] || die "Невірний вибір."
  local port="${free[$sel]}"

  # наступний вільний vmbrN
  local idx=0
  while ip link show "vmbr${idx}" >/dev/null 2>&1; do ((idx++)); done
  local br="vmbr${idx}"
  info "Створюю ${BLD}${br}${RST} з портом ${BLD}${port}${RST}"

  # IP-налаштування bridge
  local mode ipcidr gw
  echo "Режим IP для ${br}: 1) manual (без IP, чистий L2)  2) static  3) dhcp"
  read -rp "Вибір [1]: " mode || true; mode="${mode:-1}"

  cp -a /etc/network/interfaces "/etc/network/interfaces.bak.$(date +%s)"
  {
    echo ""
    echo "auto ${port}"
    echo "iface ${port} inet manual"
    echo ""
    echo "auto ${br}"
    case "$mode" in
      2)
        read -rp "IP/CIDR (напр. 192.168.1.10/24): " ipcidr
        read -rp "Gateway (Enter якщо нема): " gw
        echo "iface ${br} inet static"
        echo "        address ${ipcidr}"
        [[ -n "$gw" ]] && echo "        gateway ${gw}"
        ;;
      3)
        echo "iface ${br} inet dhcp"
        ;;
      *)
        echo "iface ${br} inet manual"
        ;;
    esac
    echo "        bridge-ports ${port}"
    echo "        bridge-stp off"
    echo "        bridge-fd 0"
  } >> /etc/network/interfaces

  ok "Додано ${br} у /etc/network/interfaces (бекап збережено)."
  echo
  info "Застосувати зараз через 'ifreload -a'?"
  warn "Якщо мережа хоста йде через цей інтерфейс — можлива втрата зв'язку."
  if confirm "Виконати ifreload -a?"; then
    if command -v ifreload >/dev/null 2>&1; then
      ifreload -a && ok "Мережу перезавантажено."
    else
      warn "ifreload немає (ifupdown2 не стоїть). Застосуй вручну: systemctl restart networking"
    fi
  else
    warn "Не застосовано. Застосуй пізніше: ifreload -a"
  fi
  ip -br addr show "$br" || true
}

# ============================================================
#  МОДУЛЬ 4: кнопка живлення хоста → reboot VM
# ============================================================
power_button_vm(){
  echo
  echo "${BLD}=== Кнопка живлення → reboot VM ===${RST}"
  command -v qm >/dev/null 2>&1 || die "qm не знайдено — це не хост Proxmox."

  # список VM
  echo
  echo "Наявні VM:"
  qm list 2>/dev/null || die "Не вдалось отримати список VM (qm list)."
  echo
  local vmid
  read -rp "VMID який перезавантажувати кнопкою: " vmid || true
  [[ "$vmid" =~ ^[0-9]+$ ]] || die "VMID має бути числом."
  qm status "$vmid" >/dev/null 2>&1 || die "VM ${vmid} не існує."
  local vmname; vmname="$(qm config "$vmid" 2>/dev/null | awk -F': ' '/^name:/{print $2}')"
  info "Обрано VM ${vmid} (${vmname:-без імені})."

  # КРОК 1: хост ігнорує кнопку
  local lc=/etc/systemd/logind.conf
  cp -a "$lc" "${lc}.bak.$(date +%s)"
  if grep -qE '^\s*#?\s*HandlePowerKey=' "$lc"; then
    sed -i 's|^\s*#\?\s*HandlePowerKey=.*|HandlePowerKey=ignore|' "$lc"
  else
    echo "HandlePowerKey=ignore" >> "$lc"
  fi
  ok "logind.conf: HandlePowerKey=ignore"
  systemctl restart systemd-logind
  info "systemd-logind перезапущено."

  # КРОК 2: acpid
  if ! command -v acpi_listen >/dev/null 2>&1 && ! dpkg -s acpid >/dev/null 2>&1; then
    info "Ставлю acpid…"
    apt-get update -qq
    apt-get install -y acpid
  fi
  systemctl enable --now acpid
  ok "acpid увімкнено."

  # КРОК 4: скрипт reboot (спершу створюємо ціль правила)
  local rvs=/usr/local/bin/reboot-vm.sh
  cat > "$rvs" <<EOF
#!/bin/bash
# Автоген pve-setup.sh — м'який ACPI-reboot VM по кнопці живлення хоста
qm reboot ${vmid}
EOF
  chmod +x "$rvs"
  ok "Створено ${rvs} → qm reboot ${vmid}"

  # КРОК 3: ACPI event rule
  mkdir -p /etc/acpi/events
  local rule=/etc/acpi/events/power-reboot-vm
  cat > "$rule" <<EOF
event=button/power.*
action=${rvs}
EOF
  ok "Створено ACPI-правило ${rule}"

  # КРОК 5: рестарт acpid
  systemctl restart acpid
  ok "acpid перезапущено."

  echo
  ok "Готово. Кнопка живлення хоста тепер робить: qm reboot ${vmid}"
  warn "Перевірка (натисни кнопку АБО симулюй подію):"
  echo "    acpi_listen        # покаже подію button/power при натисканні"
  echo "    journalctl -u acpid -f"
}

# ============================================================
#  MAIN
# ============================================================
GPU_NEEDS_REBOOT=0

show_menu(){
  echo
  echo "${BLD}=== Інтерактивне налаштування сервера Sekta ===${RST}"
  echo "  1) GPU passthrough (Intel iGPU пріоритет)"
  echo "  2) USB storage (exFAT)"
  echo "  3) Мережевий bridge"
  echo "  4) Кнопка живлення → reboot VM"
  echo "  q) Вихід"
  [[ "$GPU_NEEDS_REBOOT" == "1" ]] && echo "  ${YEL}* очікує REBOOT для застосування GPU passthrough${RST}"
  echo
}

main(){
  need_root
  check_pve

  # безпечний вихід: якщо GPU налаштовано — нагадати про reboot
  finish(){
    echo
    if [[ "$GPU_NEEDS_REBOOT" == "1" ]]; then
      warn "GPU passthrough вимагає перезавантаження."
      if confirm "Перезавантажити зараз?"; then reboot; fi
    fi
    ok "Вихід."
    exit 0
  }

  while true; do
    show_menu
    local ch
    read -rp "Вибір: " ch || { finish; }
    case "$ch" in
      1) gpu_passthrough ;;
      2) usb_storage ;;
      3) network_bridge ;;
      4) power_button_vm ;;
      q|Q) finish ;;
      *) warn "Невірний вибір: '$ch'"; continue ;;
    esac
    echo
    ok "Модуль завершено. Повертаюсь у меню…"
    read -rp "Натисни Enter…" _ || true
  done
}

main "$@"
