# sekta-server-setup

Інтерактивний скрипт налаштування сервера **Sekta** (Proxmox VE, останні версії).

Меню:
1. **Post-install** — вимкнути enterprise repo, ввімкнути `no-subscription`, прибрати "No valid subscription" nag, `apt dist-upgrade`.
2. **GPU passthrough** — детект GPU на хості, пріоритет Intel iGPU, IOMMU + vfio-pci + blacklist драйвера, звільнення framebuffer хоста для Intel. Автовизначення bootloader (GRUB / systemd-boot).
3. **USB storage (exFAT)** — детект флешки, форматування в exFAT якщо інший FS, монтування по UUID з `nofail`, додавання Proxmox directory storage (`content=backup`).
4. **Мережевий bridge** — пошук вільного фізичного інтерфейсу, створення `vmbrN` (manual / static / dhcp).
5. **Кнопка живлення → reboot VM** — хост ігнорує power-key, acpid ловить подію → `qm reboot <VMID>`.
6. **Debian VM** — знайти й завантажити актуальний netinst ISO, створити VM (q35, cpu host, 4 ядра, 8 GB ОЗУ, 10 GB диск, virtio, без autostart).
7. **Перевірка IOMMU-груп** — чи GPU у чистій групі (без чужих пристроїв) для безпечного passthrough.

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

## Безпека

- Запускати тільки на хості Proxmox під root.
- Кожна руйнівна дія (форматування диска, ізоляція GPU, зміна мережі) — з окремим підтвердженням.
- Конфіги (`/etc/fstab`, `/etc/network/interfaces`, `/etc/default/grub`, `/etc/kernel/cmdline`, `logind.conf`) бекапляться перед зміною.
- GPU passthrough вимагає reboot; Intel iGPU як єдина графіка → консоль хоста згасне, керування по SSH / web (8006).

---
by Sokol
