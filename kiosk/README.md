# SEKTA kiosk-дисплей

Boot logo (Plymouth) + Chromium kiosk, or the Sekta APP (`KIOSK_APP=1`). One command on Debian / Raspberry Pi OS.

Run on the **display machine** (not the PVE host) as a **normal user with sudo** —
the installers refuse root and call `sudo` themselves. `pve-setup.sh` menu items
7 (Chromium) and 8 (Sekta APP) run the same `install.sh`.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/EugeneSok/sekta-server-setup/main/kiosk/install.sh | bash
```

Or:

```bash
git clone https://github.com/EugeneSok/sekta-server-setup.git
cd sekta-server-setup/kiosk
./install.sh
```

The installer asks for the address (default `https://combat.omega`) and offers
up to 2 more sites as tabs. Without a terminal (e.g. `ssh host '…'` without `-t`)
it takes the default address.

### Options (environment variables)

| Variable | Effect |
|---|---|
| `KIOSK_URL="https://a.omega"` | Skip the prompt. 1 URL → locked full screen (`--kiosk`, no tab bar). |
| `KIOSK_URL="https://a.omega https://b.omega"` | Up to 3 space-separated URLs → tabs in a maximised window (tab strip visible, Ctrl+Tab). |
| `KIOSK_APP=1` | Sekta APP instead of Chromium (see below). |
| `REINSTALL=keep` | Overwrite in place instead of removing the previous install first. |

```bash
curl -fsSL https://raw.githubusercontent.com/EugeneSok/sekta-server-setup/main/kiosk/install.sh | KIOSK_URL="https://a.omega https://b.omega" bash
```

### What it sets up

- **Boot splash** — Plymouth theme `mylogo` (SEKTA logo + progress bar). On GRUB
  systems `quiet splash` is **added** to `GRUB_CMDLINE_LINUX_DEFAULT` (existing
  params are kept, backup `*.bak.<epoch>`); Raspberry Pi has no GRUB — skipped.
- **Kiosk** — systemd `--user` unit, restarts on crash; screen blanking / DPMS off
  (X11).
- **UA keyboard** — `us,ua`, toggle Alt+Shift.
- **No sleep** — system suspend/hibernate masked; `consoleblank=0` (GRUB).
- **Autologin** — GDM3 or LightDM; without a display manager — TTY1 autologin
  (a graphical session is still needed). SDDM is not covered.

## Sekta APP kiosk (instead of Chromium)

On Debian 12+ (amd64 or arm64) with a desktop, run the **Sekta APP** full screen
instead of a browser. The installer downloads the **latest** `sekta-linux-<arch>.deb`
(`amd64` or `arm64`, picked by `dpkg --print-architecture`; arm64 since 1.7.2)
from GitHub Releases (`EugeneSok/sekta-app`), verifies its SHA-256 and installs
it with `apt` (dependencies included). Re-run to update the app.

```bash
curl -fsSL https://raw.githubusercontent.com/EugeneSok/sekta-server-setup/main/kiosk/install.sh | KIOSK_APP=1 bash
```

The kiosk unit is `sekta-kiosk.service` (`/usr/bin/sekta --fullscreen`); an
existing `chromium-kiosk.service` is removed so only one runs on boot. Plymouth
splash, autologin, UA keyboard and no-sleep are the same as the browser kiosk.
Offline install covers the browser kiosk only.

## Autostart

The kiosk unit is started by the graphical session, not by
`graphical-session.target`: labwc / wayfire (Raspberry Pi OS, plain Debian)
never activate that target, so a unit wanted by it did not start after a
reboot. The installer writes `~/.local/bin/sekta-kiosk-start` (hands
`WAYLAND_DISPLAY`/`DISPLAY` to the user manager, then
`systemctl --user start <unit>`) and calls it from
`~/.config/autostart/sekta-kiosk.desktop` and `~/.config/labwc/autostart`
(seeded from `/etc/xdg/labwc/autostart` so the panel stays). Re-run the
installer on machines set up before this change. Check after a reboot:

```bash
systemctl --user status chromium-kiosk.service   # browser kiosk
systemctl --user status sekta-kiosk.service      # Sekta APP
```

## Offline install

Same browser kiosk as `install.sh` — up to 3 sites as tabs, UA keyboard,
no screen sleep, autologin — without network.

Gather packages once on an **online** Debian / Raspberry Pi OS machine of the
**same release and arch** as the target (e.g. bookworm or trixie; amd64 or arm64).
apt resolves one consistent, complete set as if the target had nothing
installed, so the online machine does not need to be clean. Expect ~250 `.deb`,
~240 MB in `debs/` (not committed — gitignored):

```bash
./fetch-debs.sh
```

Copy the whole `kiosk/` folder (scripts, logo/bar PNGs, `debs/`) to the offline
machine, e.g. on a USB stick, then run it with `bash` — a stick mounted `noexec`
gives `Permission denied` for `./install-offline.sh`:

```bash
bash ./install-offline.sh
# or non-interactive, 1–3 sites:
KIOSK_URL="https://a.omega https://b.omega" bash ./install-offline.sh
```

Only packages missing on the target (or older than in `debs/`) are installed —
newer system packages are never downgraded. `fetch-debs.sh` writes
`debs/BUNDLE` (distro, release, arch); `install-offline.sh` refuses a bundle
made for another release or architecture, and one without `BUNDLE` (made by an
older `fetch-debs.sh` — re-run it), before changing anything.

## Reboot

```bash
sudo reboot
```

`1.md` / `2.md` — manual step-by-step notes (splash, kiosk unit) the installer
was built from; the installer is the source of truth.
