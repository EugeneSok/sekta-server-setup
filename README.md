# sekta-server-setup

Інтерактивний скрипт налаштування сервера **Sekta** (Proxmox VE, останні версії).

Меню (порядок = рекомендована послідовність для нового сервера):
1. **Post-install** — вимкнути enterprise repo, ввімкнути `no-subscription`, прибрати "No valid subscription" nag, `apt dist-upgrade`.
2. **GPU passthrough** — детект GPU на хості, пріоритет Intel iGPU, IOMMU + vfio-pci + blacklist драйвера, звільнення framebuffer хоста для Intel. Автовизначення bootloader (GRUB / systemd-boot).
3. **Перевірка IOMMU-груп** — чи GPU у чистій групі (без чужих пристроїв) для безпечного passthrough.
4. **USB storage (exFAT)** — детект флешки, відмова від системного диску (розпізнає корінь на partition / LVM / ZFS), форматування в exFAT якщо інший FS, монтування по UUID з `nofail`, додавання Proxmox directory storage (`content=backup`).
5. **Debian VM** — знайти й завантажити актуальний netinst ISO, створити VM (q35/UEFI, cpu host, 4 ядра, 8 GB ОЗУ, 10 GB диск, virtio, без autostart).
6. **Кнопка живлення → reboot VM** — хост ігнорує power-key, acpid ловить подію → `qm reboot <VMID>`.
7. **Kiosk-дисплей** — Plymouth boot-splash з логотипом SEKTA + Chromium у режимі kiosk (systemd `--user` unit) на **окремій машині-дисплеї** (Debian / Raspberry Pi OS). Можна задати **до 3 сайтів**: один сайт — заблокований повноекранний `--kiosk`; кілька — вкладки у розгорнутому вікні з видимою панеллю вкладок і перемиканням (Ctrl+Tab). Додатково: українська розкладка клавіатури (`us,ua`, Alt+Shift), вимкнення засинання екрану/машини, автовхід у систему. Інсталятор — у теці [`kiosk/`](kiosk/) цього ж репо; запускається від звичайного користувача.
8. **Sekta APP (Debian)** — те саме, що Kiosk-дисплей (boot-splash, автовхід, UA-клавіатура, без засинання), але на екрані замість браузера — **застосунок Sekta APP** (збірка для Debian, лише «Інструменти») на весь екран (`sekta --fullscreen`, systemd `--user` unit `sekta-kiosk.service`). Ставить **актуальну версію** з GitHub Releases (`sekta-app`, перевірка SHA-256, залежності — через `apt`); повторний запуск пункту оновлює застосунок. **amd64 або arm64** (Raspberry Pi 4/5 тощо; пакет під архітектуру машини обирається сам, arm64 — з Sekta APP 1.7.2), Debian 12+ з графічним робочим столом. Вхід у застосунок — контрольною фразою «Інструментів». Замінює Chromium-kiosk (пункт 7), якщо він уже стоїть.

## Мінімальні вимоги заліза

Розраховано на host + Debian VM (модуль 5).

| Компонент | Мінімум | Рекомендовано |
|---|---|---|
| **CPU** | x86-64, 4 потоки, VT-x / AMD-V. Intel — **не нижче 8-го покоління** | Intel 10-е+ / 6+ потоків |
| **IOMMU** | VT-d / AMD-Vi у BIOS (для GPU passthrough) | — |
| **RAM** | 12 GB (host + Debian VM 8 GB); без VM — 4 GB | 16 GB+ |
| **Диск** | 64 GB SSD | 128 GB+ NVMe |
| **NIC** | 1 | — |
| **USB** | флешка під бекапи (модуль 4) | — |
| **GPU** | лише якщо треба passthrough (модуль 2) | iGPU/dGPU з підтримкою VFIO |

Орієнтовний розподіл RAM/диску: host ~2 GB / 16 GB, Debian VM 8 GB / 10 GB.

Примітки:
- **Intel: не нижче 8-го покоління (Coffee Lake, UHD 630).** Старіші iGPU нестабільні у VFIO-passthrough; 8-е покоління або новіше дає надійний проброс і сучасні драйвери.
- Для **GPU passthrough** обовʼязково увімкнути VT-d/IOMMU у BIOS/UEFI, інакше модулі 2/3 не спрацюють.
- Без Debian VM (модуль 5) вимоги падають до самого хоста.

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

Меню вже впорядковане під це — кроки 1→8. Модулі незалежні, можна робити вибірково.

1. **Post-install** — база: репозиторії + `dist-upgrade`. Якщо оновився kernel → **reboot**.
2. **GPU passthrough** — IOMMU + vfio. Наприкінці **reboot** (обовʼязково).
3. **Перевірка IOMMU-груп** — *після* ребуту: підтвердити що GPU у чистій групі і на `vfio-pci`.
4. **USB storage** — флешка під бекапи (`content=backup`).
5. **Debian VM** — робочі VM за потребою.
6. **Кнопка живлення → reboot VM** — опційно, коли цільова VM вже існує.
7. **Kiosk-дисплей** — окремо, **на самій машині-дисплеї** (не на PVE-хості): boot-splash + Chromium kiosk на дашборд + UA-клавіатура, без засинання, автовхід.
8. **Sekta APP (Debian)** — замість пункту 7, якщо на дисплеї потрібен застосунок («Інструменти»), а не сайт. Теж на самій машині-дисплеї.

Мережева залежність: Post-install, Debian VM (ISO) і kiosk-інсталятори тягнуть дані з інтернету — потрібен вихід у мережу на цих кроках.

## Безпека

- Запускати тільки на хості Proxmox під root.
- Кожна руйнівна дія (форматування диска, ізоляція GPU) — з окремим підтвердженням.
- Конфіги (`/etc/fstab`, `/etc/default/grub`, `/etc/kernel/cmdline`, `logind.conf`) бекапляться перед зміною.
- GPU passthrough вимагає reboot; Intel iGPU як єдина графіка → консоль хоста згасне, керування по SSH / web (8006).

---
by Sokol
