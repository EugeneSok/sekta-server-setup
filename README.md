# sekta-server-setup

Інтерактивний скрипт налаштування сервера **Sekta** (Proxmox VE, останні версії).

Меню:
1. **Post-install** — вимкнути enterprise repo, ввімкнути `no-subscription`, прибрати "No valid subscription" nag, `apt dist-upgrade`.
2. **GPU passthrough** — детект GPU на хості, пріоритет Intel iGPU, IOMMU + vfio-pci + blacklist драйвера, звільнення framebuffer хоста для Intel. Автовизначення bootloader (GRUB / systemd-boot).
3. **USB storage (exFAT)** — детект флешки, форматування в exFAT якщо інший FS, монтування по UUID з `nofail`, додавання Proxmox directory storage (`content=backup`).
4. **LAN bridge для OPNsense** — наявний uplink-інтерфейс = WAN, новий bridge на вільному NIC = LAN (без IP на хості — адресацію тримає OPNsense). Виводить мапу net0=WAN / net1=LAN для VM. Якщо вільного NIC нема — internal-only bridge для VM-мережі.
5. **Кнопка живлення → reboot VM** — хост ігнорує power-key, acpid ловить подію → `qm reboot <VMID>`.
6. **Debian VM** — знайти й завантажити актуальний netinst ISO, створити VM (q35, cpu host, 4 ядра, 8 GB ОЗУ, 10 GB диск, virtio, без autostart).
7. **Перевірка IOMMU-груп** — чи GPU у чистій групі (без чужих пристроїв) для безпечного passthrough.
8. **OPNsense VM** — завантажити актуальний dvd ISO з дзеркала, розпакувати, створити VM з двома NIC (net0=WAN, net1=LAN), q35/host/2c/2G/20G, autostart увімкнено.
9. **LXC Pi-hole** — шаблон Debian 12, unprivileged контейнер (1c/512M/8G) на LAN-bridge, static або DHCP, unattended-інсталяція Pi-hole, опційний пароль web-адмінки.

## Запуск

На хості Proxmox під **root**:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/EugeneSok/sekta-server-setup/main/pve-setup.sh)
```

Або завантажити й запустити:

```bash
curl -fsSLO https://raw.githubusercontent.com/EugeneSok/sekta-server-setup/main/pve-setup.sh
chmod +x pve-setup.sh
./pve-setup.sh
```

## Порядок запуску для нового сервера

Рекомендована послідовність (пункти меню). Модулі незалежні — можна робити вибірково.

1. **Post-install** (1) — база: репозиторії + `dist-upgrade`. Якщо оновився kernel → **reboot**.
2. **GPU passthrough** (2) — IOMMU + vfio. Наприкінці **reboot** (обовʼязково).
3. **Перевірка IOMMU-груп** (7) — *після* ребуту: підтвердити що GPU у чистій групі і на `vfio-pci`.
4. **USB storage** (3) — флешка під бекапи (`content=backup`).
5. **LAN bridge** (4) — підготувати WAN/LAN інтерфейси під роутер.
6. **OPNsense VM** (8) — роутер: net0=WAN, net1=LAN. Встановити, призначити інтерфейси (WAN=vtnet0, LAN=vtnet1).
7. **Pi-hole LXC** (9) — DNS-фільтр на LAN. Потім прописати його IP як DNS у OPNsense DHCP.
8. **Debian VM** (6) — робочі VM за потребою.
9. **Кнопка живлення → reboot VM** (5) — опційно, коли цільова VM вже існує.

Мережева залежність: Pi-hole/OPNsense/Debian/шаблони LXC тягнуть дані з інтернету — хосту потрібен вихід у мережу на цих кроках.

## Безпека

- Запускати тільки на хості Proxmox під root.
- Кожна руйнівна дія (форматування диска, ізоляція GPU, зміна мережі) — з окремим підтвердженням.
- Конфіги (`/etc/fstab`, `/etc/network/interfaces`, `/etc/default/grub`, `/etc/kernel/cmdline`, `logind.conf`) бекапляться перед зміною.
- GPU passthrough вимагає reboot; Intel iGPU як єдина графіка → консоль хоста згасне, керування по SSH / web (8006).

---
by Sokol
