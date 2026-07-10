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
#  МОДУЛЬ 3: LAN bridge для OPNsense
#  Існуючий інтерфейс (з uplink) = WAN, новий bridge = LAN.
#  LAN-bridge БЕЗ IP на хості — OPNsense роутить і роздає DHCP.
# ============================================================
network_bridge(){
  echo
  echo "${BLD}=== LAN bridge для OPNsense ===${RST}"
  info "Логіка: наявний інтерфейс = ${BLD}WAN${RST}, новий bridge = ${BLD}LAN${RST}."
  info "LAN-bridge лишається без IP на хості — адресацію тримає OPNsense."

  # --- визначити WAN (звідки йде uplink хоста) ---
  local wan_dev wan_br
  wan_dev="$(ip -o -4 route show default 2>/dev/null | awk '{print $5; exit}')"
  if [[ -n "$wan_dev" ]]; then
    if [[ "$wan_dev" == vmbr* ]]; then
      wan_br="$wan_dev"
      # фізичний порт цього bridge
      local wp; wp="$(ls /sys/class/net/"$wan_br"/brif 2>/dev/null | head -n1)"
      info "WAN uplink: ${BLD}${wan_br}${RST} (порт: ${wp:-?}) — це буде net0/WAN у OPNsense."
    else
      wan_br="$wan_dev"
      info "WAN uplink: ${BLD}${wan_dev}${RST} (не bridge)."
    fi
  else
    warn "Не визначив default route — WAN вкажеш вручну в OPNsense."
  fi

  echo
  echo "Наявні bridge:"
  ip -br link show type bridge 2>/dev/null || true
  echo

  # --- знайти вільні фізичні NIC (кандидати на LAN): без IP, не в bridge ---
  local -a free=()
  local ifc
  while read -r ifc; do
    [[ "$ifc" =~ ^(lo|vmbr|veth|tap|fwbr|fwln|fwpr|bond|dummy) ]] && continue
    [[ -e "/sys/class/net/$ifc/device" ]] || continue                 # реальний ethernet
    [[ "$ifc" == "$wan_dev" ]] && continue                            # не чіпати WAN-порт
    if ip -4 addr show "$ifc" 2>/dev/null | grep -q 'inet '; then continue; fi
    if [[ -n "$(ls /sys/class/net/*/brif/"$ifc" 2>/dev/null)" ]]; then continue; fi
    if grep -qE "bridge-ports.*\b${ifc}\b" /etc/network/interfaces 2>/dev/null; then continue; fi
    free+=("$ifc")
  done < <(ls /sys/class/net)

  if [[ ${#free[@]} -eq 0 ]]; then
    warn "Вільних фізичних інтерфейсів під LAN немає."
    warn "Варіант: LAN як internal-only bridge (без фізичного порту) для VM-only мережі."
    confirm "Створити LAN-bridge БЕЗ фізичного порту (internal)?" || { warn "Пропущено."; return 0; }
    _make_lan_bridge "" "$wan_br"
    return 0
  fi

  echo "Вільні інтерфейси (кандидати на LAN-порт):"
  local n=0
  for ifc in "${free[@]}"; do
    local st; st="$(cat /sys/class/net/"$ifc"/operstate 2>/dev/null || echo '?')"
    printf "  ${BLD}%d${RST}) %s  (state=%s)\n" "$n" "$ifc" "$st"
    ((n++))
  done
  echo
  confirm "Створити LAN-bridge для OPNsense?" || { warn "Пропущено."; return 0; }

  local sel
  read -rp "Який інтерфейс як LAN-порт? [0] " sel || true; sel="${sel:-0}"
  [[ "$sel" =~ ^[0-9]+$ && $sel -lt $n ]] || die "Невірний вибір."
  _make_lan_bridge "${free[$sel]}" "$wan_br"
}

# створити LAN-bridge; $1=фізичний порт (порожньо=internal), $2=wan_br для підсумку
_make_lan_bridge(){
  local port="$1" wan_br="$2"

  # наступний вільний vmbrN
  local idx=0
  while ip link show "vmbr${idx}" >/dev/null 2>&1; do ((idx++)); done
  local br="vmbr${idx}"
  info "Створюю LAN-bridge ${BLD}${br}${RST}${port:+ з портом ${BLD}${port}${RST}}"

  cp -a /etc/network/interfaces "/etc/network/interfaces.bak.$(date +%s)"
  {
    echo ""
    echo "# --- OPNsense LAN (створено pve-setup.sh) ---"
    if [[ -n "$port" ]]; then
      echo "auto ${port}"
      echo "iface ${port} inet manual"
      echo ""
    fi
    echo "auto ${br}"
    echo "iface ${br} inet manual"          # без IP на хості — тримає OPNsense
    echo "        bridge-ports ${port:-none}"
    echo "        bridge-stp off"
    echo "        bridge-fd 0"
    echo "#         LAN bridge для OPNsense — приєднай як net1/LAN у VM"
  } >> /etc/network/interfaces

  ok "Додано LAN-bridge ${br} у /etc/network/interfaces (бекап збережено, без IP на хості)."
  echo
  info "Застосувати зараз через 'ifreload -a'?"
  warn "WAN-зв'язок хоста не чіпається (LAN-порт окремий)."
  if confirm "Виконати ifreload -a?"; then
    if command -v ifreload >/dev/null 2>&1; then
      ifreload -a && ok "Мережу перезавантажено."
    else
      warn "ifreload немає (ifupdown2 не стоїть). Застосуй вручну: systemctl restart networking"
    fi
  else
    warn "Не застосовано. Застосуй пізніше: ifreload -a"
  fi

  echo
  echo "${BLD}Мапа для OPNsense VM:${RST}"
  echo "   net0 (WAN) → ${wan_br:-<твій WAN bridge>}"
  echo "   net1 (LAN) → ${br}"
  echo "   У VM conf: net0=virtio,bridge=${wan_br:-vmbr0}  net1=virtio,bridge=${br}"
  echo "   Після інсталяції OPNsense признач: WAN=vtnet0, LAN=vtnet1."
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
#  МОДУЛЬ 5: Post-install (repo + nag + upgrade)
# ============================================================
post_install(){
  echo
  echo "${BLD}=== Post-install ===${RST}"

  # codename Debian під версію PVE (bookworm=PVE8, trixie=PVE9)
  local codename
  codename="$(. /etc/os-release; echo "${VERSION_CODENAME:-bookworm}")"
  info "Debian codename: ${codename}"

  # --- 1. вимкнути enterprise repo (формати .list і deb822 .sources) ---
  local changed=0
  for f in /etc/apt/sources.list.d/pve-enterprise.list /etc/apt/sources.list.d/ceph.list; do
    if [[ -f "$f" ]] && grep -qE '^\s*deb ' "$f"; then
      cp -a "$f" "${f}.bak.$(date +%s)"
      sed -i 's|^\s*deb |# deb |' "$f"
      ok "Вимкнено enterprise repo: $f"; changed=1
    fi
  done
  for f in /etc/apt/sources.list.d/pve-enterprise.sources /etc/apt/sources.list.d/ceph.sources; do
    if [[ -f "$f" ]] && ! grep -qiE '^\s*Enabled:\s*false' "$f"; then
      cp -a "$f" "${f}.bak.$(date +%s)"
      if grep -qiE '^\s*Enabled:' "$f"; then
        sed -i 's|^\s*Enabled:.*|Enabled: false|I' "$f"
      else
        echo "Enabled: false" >> "$f"
      fi
      ok "Вимкнено enterprise repo (deb822): $f"; changed=1
    fi
  done

  # --- 2. додати no-subscription repo ---
  local nosub=/etc/apt/sources.list.d/pve-no-subscription.list
  if [[ ! -f "$nosub" ]] || ! grep -q 'pve-no-subscription' "$nosub"; then
    echo "deb http://download.proxmox.com/debian/pve ${codename} pve-no-subscription" > "$nosub"
    ok "Додано no-subscription repo → $nosub"; changed=1
  else
    ok "no-subscription repo вже є."
  fi

  # --- 3. прибрати 'No valid subscription' nag ---
  local nagjs=/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
  if [[ -f "$nagjs" ]] && grep -q 'data.status.toLowerCase() !== .active' "$nagjs"; then
    cp -a "$nagjs" "${nagjs}.bak.$(date +%s)"
    # відомий робочий патч: підмінити перевірку 'active' на 'nokey'
    sed -i "s/.data.status.toLowerCase() !== 'active'/.data.status.toLowerCase() == 'nokey'/g" "$nagjs"
    systemctl restart pveproxy 2>/dev/null || true
    ok "Nag прибрано (реверт при оновленні пакету proxmox-widget-toolkit)."
  else
    info "Nag-патерн не знайдено (вже прибрано або інша версія) — пропуск."
  fi

  # --- 4. update + dist-upgrade ---
  info "apt update…"
  apt-get update
  echo
  if confirm "Виконати dist-upgrade зараз? (може тягнути новий kernel)"; then
    DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y
    ok "dist-upgrade завершено."
    warn "Якщо оновився kernel — потрібен reboot."
  else
    warn "dist-upgrade пропущено. Пізніше: apt update && apt dist-upgrade"
  fi
  ok "Post-install готовий."
}

# ============================================================
#  МОДУЛЬ 6: Debian VM (актуальний ISO + створення VM)
# ============================================================
debian_vm(){
  echo
  echo "${BLD}=== Debian VM (q35, host, 4c/8G/10G, без autostart) ===${RST}"
  command -v qm >/dev/null 2>&1 || die "qm не знайдено — не хост Proxmox."

  # --- знайти актуальний netinst ISO ---
  local base="https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/"
  info "Шукаю актуальний Debian netinst ISO…"
  local iso
  iso="$(curl -fsSL "$base" | grep -oE 'debian-[0-9.]+-amd64-netinst\.iso' | sort -Vu | tail -n1 || true)"
  [[ -n "$iso" ]] || die "Не знайшов ISO на ${base} — перевір інтернет."
  info "Актуальний ISO: ${BLD}${iso}${RST}"

  # --- ISO storage (dir з content=iso) ---
  local isodir=/var/lib/vz/template/iso
  mkdir -p "$isodir"
  local isopath="${isodir}/${iso}"
  if [[ -f "$isopath" ]]; then
    ok "ISO вже завантажено: $isopath"
  else
    confirm "Завантажити ${iso} у ${isodir}?" || { warn "Скасовано."; return 0; }
    info "Завантаження…"
    curl -fL --progress-bar -o "${isopath}.part" "${base}${iso}"
    mv "${isopath}.part" "$isopath"
    ok "Завантажено: $isopath"
  fi
  local iso_ref="local:iso/${iso}"

  # --- storage для диска (content=images) ---
  local diskstore
  diskstore="$(pvesm status -content images 2>/dev/null | awk 'NR>1{print $1}' | grep -x local-lvm || \
               pvesm status -content images 2>/dev/null | awk 'NR>1{print $1; exit}')"
  [[ -n "$diskstore" ]] || die "Немає storage з content=images."
  read -rp "Storage для диска [${diskstore}]: " s || true; diskstore="${s:-$diskstore}"

  # --- bridge ---
  local br=vmbr0
  ip link show vmbr0 >/dev/null 2>&1 || br="$(ip -br link show type bridge | awk 'NR==1{print $1}')"
  read -rp "Bridge для мережі [${br}]: " b || true; br="${b:-$br}"

  # --- VMID (дефолт 500) ---
  local vmid=500
  if qm status "$vmid" >/dev/null 2>&1; then
    local nextid; nextid="$(pvesh get /cluster/nextid 2>/dev/null || echo 501)"
    warn "VMID 500 вже зайнятий. Пропоную ${nextid}."
    vmid="$nextid"
  fi
  read -rp "VMID [${vmid}]: " v || true; vmid="${v:-$vmid}"
  qm status "$vmid" >/dev/null 2>&1 && die "VM ${vmid} вже існує."

  local name=debian
  read -rp "Ім'я VM [${name}]: " n || true; name="${n:-$name}"

  echo
  info "Параметри VM:"
  echo "    VMID=${vmid} name=${name}"
  echo "    machine=q35 cpu=host cores=4 sockets=1 memory=8192MB"
  echo "    disk=10G на ${diskstore}  net=virtio@${br}"
  echo "    ISO=${iso_ref}  onboot=НІ  ostype=l26"
  confirm "Створити VM?" || { warn "Скасовано."; return 0; }

  qm create "$vmid" \
    --name "$name" \
    --machine q35 \
    --cpu host \
    --cores 4 --sockets 1 \
    --memory 8192 \
    --ostype l26 \
    --scsihw virtio-scsi-single \
    --scsi0 "${diskstore}:10" \
    --net0 "virtio,bridge=${br}" \
    --ide2 "${iso_ref},media=cdrom" \
    --boot "order=scsi0;ide2" \
    --onboot 0 \
    --agent enabled=1
  ok "VM ${vmid} (${name}) створено. Autostart вимкнено."
  info "Старт вручну: qm start ${vmid}  (консоль у web UI → VM ${vmid} → Console)"
}

# ============================================================
#  МОДУЛЬ 7: перевірка IOMMU-груп (чи GPU ізольована чисто)
# ============================================================
iommu_check(){
  echo
  echo "${BLD}=== Перевірка IOMMU-груп ===${RST}"
  if [[ ! -d /sys/kernel/iommu_groups ]] || [[ -z "$(ls -A /sys/kernel/iommu_groups 2>/dev/null)" ]]; then
    err "IOMMU не активний (немає /sys/kernel/iommu_groups)."
    warn "Спочатку модуль 1 (GPU passthrough) + REBOOT, тоді перевіряй."
    return 0
  fi
  ok "IOMMU активний."

  # знайти GPU
  echo
  echo "GPU у системі:"
  local -a gaddr=()
  while read -r line; do
    local a; a="$(awk '{print $1}' <<<"$line")"
    gaddr+=("$a")
    printf "  %s  %s\n" "$a" "$(sed -E 's/^[^ ]+ //' <<<"$line")"
  done < <(lspci -Dnn | grep -iE 'VGA compatible controller|3D controller|Display controller')
  [[ ${#gaddr[@]} -gt 0 ]] || { warn "GPU не знайдено."; return 0; }

  # для кожної GPU показати групу і чистоту
  local addr
  for addr in "${gaddr[@]}"; do
    # знайти номер групи
    local grp="" gp
    for gp in /sys/kernel/iommu_groups/*/devices/"$addr"; do
      [[ -e "$gp" ]] || continue
      grp="$(basename "$(dirname "$(dirname "$gp")")")"
      break
    done
    [[ -z "$grp" ]] && { warn "${addr}: групу не знайдено"; continue; }

    echo
    echo "${BLD}GPU ${addr} → IOMMU group ${grp}${RST}"
    local -a members=()
    local d name drv extra=0
    for d in /sys/kernel/iommu_groups/"$grp"/devices/*; do
      local pci; pci="$(basename "$d")"
      name="$(lspci -Dnns "$pci" | sed -E 's/^[^ ]+ //')"
      drv="$(lspci -Dks "$pci" | awk -F': ' '/Kernel driver in use/{print $2}')"
      members+=("$pci")
      # "свій" = той самий слот що GPU (GPU + її audio) або bridge
      local slot="${addr%.*}"
      local is_own="no"
      [[ "$pci" == "$slot".* ]] && is_own="yes"
      if grep -qiE 'PCI bridge|Host bridge' <<<"$name"; then is_own="bridge"; fi
      local mark="${GRN}✓${RST}"
      [[ "$is_own" == "no" ]] && { mark="${RED}✗ ЧУЖИЙ${RST}"; extra=1; }
      printf "    %s %s  [drv: %s]  %s\n" "$mark" "$pci" "${drv:-—}" "$name"
    done

    if [[ "$extra" == "0" ]]; then
      ok "Група ${grp} ЧИСТА — тільки GPU + її функції/bridge. Passthrough безпечний."
    else
      err "Група ${grp} МІШАНА — містить чужі пристрої (позначені ✗)."
      warn "Passthrough віддасть ЇХ РАЗОМ з GPU. Варіанти:"
      echo "      • інший PCIe слот для карти"
      echo "      • ACS override (ризиковано): pcie_acs_override=downstream,multifunction у cmdline"
    fi
  done
}

# ============================================================
#  МОДУЛЬ 8: OPNsense VM (WAN+LAN, dvd ISO)
# ============================================================
opnsense_vm(){
  echo
  echo "${BLD}=== OPNsense VM (WAN + LAN) ===${RST}"
  command -v qm >/dev/null 2>&1 || die "qm не знайдено — не хост Proxmox."

  # --- знайти актуальний dvd ISO на дзеркалі ---
  local mirror="${OPN_MIRROR:-https://mirror.dns-root.de/opnsense/releases/mirror/}"
  info "Дзеркало OPNsense: ${mirror}"
  local bz
  bz="$(curl -fsSL "$mirror" 2>/dev/null | grep -oE 'OPNsense-[0-9.]+-dvd-amd64\.iso\.bz2' | sort -Vu | tail -n1 || true)"
  local url
  if [[ -n "$bz" ]]; then
    url="${mirror}${bz}"
    info "Знайдено: ${BLD}${bz}${RST}"
  else
    warn "Автопошук ISO не вдався."
    read -rp "Встав пряме посилання на OPNsense dvd .iso.bz2: " url || true
    [[ -n "$url" ]] || die "Немає URL ISO."
    bz="$(basename "$url")"
  fi

  # --- завантажити + розпакувати в ISO storage ---
  local isodir=/var/lib/vz/template/iso
  mkdir -p "$isodir"
  local iso="${bz%.bz2}"
  local isopath="${isodir}/${iso}"
  if [[ -f "$isopath" ]]; then
    ok "ISO вже готовий: $isopath"
  else
    confirm "Завантажити й розпакувати ${bz}?" || { warn "Скасовано."; return 0; }
    command -v bunzip2 >/dev/null 2>&1 || { apt-get update -qq; apt-get install -y bzip2; }
    info "Завантаження…"
    curl -fL --progress-bar -o "${isodir}/${bz}" "$url"
    info "Розпаковка bz2…"
    bunzip2 -f "${isodir}/${bz}"
    [[ -f "$isopath" ]] || die "Після розпаковки нема ${isopath}."
    ok "ISO готовий: $isopath"
  fi
  local iso_ref="local:iso/${iso}"

  # --- storage диска ---
  local diskstore
  diskstore="$(pvesm status -content images 2>/dev/null | awk 'NR>1{print $1}' | grep -x local-lvm || \
               pvesm status -content images 2>/dev/null | awk 'NR>1{print $1; exit}')"
  [[ -n "$diskstore" ]] || die "Немає storage з content=images."
  read -rp "Storage для диска [${diskstore}]: " s || true; diskstore="${s:-$diskstore}"

  # --- WAN bridge (default route) ---
  local wan_br
  wan_br="$(ip -o -4 route show default 2>/dev/null | awk '{print $5; exit}')"
  [[ "$wan_br" == vmbr* ]] || wan_br=vmbr0
  read -rp "WAN bridge (net0) [${wan_br}]: " w || true; wan_br="${w:-$wan_br}"

  # --- LAN bridge: показати bridge крім WAN ---
  echo "Наявні bridge:"
  ip -br link show type bridge 2>/dev/null | awk '{print "   "$1}'
  local lan_br
  lan_br="$(ip -br link show type bridge 2>/dev/null | awk '{print $1}' | grep -v "^${wan_br}$" | head -n1)"
  [[ -n "$lan_br" ]] || lan_br=vmbr1
  read -rp "LAN bridge (net1) [${lan_br}]: " l || true; lan_br="${l:-$lan_br}"
  [[ "$lan_br" == "$wan_br" ]] && die "LAN і WAN не можуть бути одним bridge."

  # --- VMID (дефолт 400) ---
  local vmid=400
  if qm status "$vmid" >/dev/null 2>&1; then
    vmid="$(pvesh get /cluster/nextid 2>/dev/null || echo 401)"
    warn "VMID 400 зайнятий → ${vmid}."
  fi
  read -rp "VMID [${vmid}]: " v || true; vmid="${v:-$vmid}"
  qm status "$vmid" >/dev/null 2>&1 && die "VM ${vmid} вже існує."

  # ресурси (рекомендовані для OPNsense)
  local cores=2 mem=2048 disk=20
  echo
  info "Параметри OPNsense VM:"
  echo "    VMID=${vmid} name=opnsense"
  echo "    machine=q35 cpu=host cores=${cores} memory=${mem}MB disk=${disk}G@${diskstore}"
  echo "    net0(WAN)=virtio@${wan_br}  net1(LAN)=virtio@${lan_br}"
  echo "    ISO=${iso_ref}  ostype=other(FreeBSD)  onboot=ТАК (роутер)"
  confirm "Створити VM?" || { warn "Скасовано."; return 0; }

  qm create "$vmid" \
    --name opnsense \
    --machine q35 \
    --cpu host \
    --cores "$cores" --sockets 1 \
    --memory "$mem" \
    --ostype other \
    --scsihw virtio-scsi-single \
    --scsi0 "${diskstore}:${disk}" \
    --net0 "virtio,bridge=${wan_br}" \
    --net1 "virtio,bridge=${lan_br}" \
    --ide2 "${iso_ref},media=cdrom" \
    --boot "order=scsi0;ide2" \
    --onboot 1
  ok "OPNsense VM ${vmid} створено. Autostart УВІМКНЕНО (роутер)."
  echo
  info "Далі:"
  echo "    qm start ${vmid}   → консоль у web UI → інсталяція"
  echo "    Признач інтерфейси: WAN=vtnet0 (${wan_br}), LAN=vtnet1 (${lan_br})"
  echo "    LAN за замовчуванням 192.168.1.1, DHCP роздає OPNsense."
  warn "⚠ vmbr з фізичним WAN-портом = OPNsense отримає реальний інтернет-канал."
}

# ============================================================
#  MAIN
# ============================================================
GPU_NEEDS_REBOOT=0

show_menu(){
  echo
  echo "${BLD}=== Інтерактивне налаштування сервера Sekta ===${RST}"
  echo "  1) Post-install (repo + nag + upgrade)"
  echo "  2) GPU passthrough (Intel iGPU пріоритет)"
  echo "  3) USB storage (exFAT)"
  echo "  4) LAN bridge для OPNsense"
  echo "  5) Кнопка живлення → reboot VM"
  echo "  6) Debian VM (актуальний ISO + створення)"
  echo "  7) Перевірка IOMMU-груп (чистота GPU)"
  echo "  8) OPNsense VM (WAN + LAN)"
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
      1) post_install ;;
      2) gpu_passthrough ;;
      3) usb_storage ;;
      4) network_bridge ;;
      5) power_button_vm ;;
      6) debian_vm ;;
      7) iommu_check ;;
      8) opnsense_vm ;;
      q|Q) finish ;;
      *) warn "Невірний вибір: '$ch'"; continue ;;
    esac
    echo
    ok "Модуль завершено. Повертаюсь у меню…"
    read -rp "Натисни Enter…" _ || true
  done
}

main "$@"
