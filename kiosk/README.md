# SEKTA kiosk-дисплей

Boot logo (Plymouth) + Chromium kiosk, or the Sekta APP (`KIOSK_APP=1`). One command on Debian / Raspberry Pi OS.

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

**Autostart.** The kiosk unit is started by the graphical session, not by
`graphical-session.target`: labwc / wayfire (Raspberry Pi OS, plain Debian)
never activate that target, so a unit wanted by it did not start after a
reboot. The installer writes `~/.local/bin/sekta-kiosk-start` (hands
`WAYLAND_DISPLAY`/`DISPLAY` to the user manager, then
`systemctl --user start <unit>`) and calls it from
`~/.config/autostart/sekta-kiosk.desktop` and `~/.config/labwc/autostart`
(seeded from `/etc/xdg/labwc/autostart` so the panel stays). Re-run the
installer on machines set up before this change. Check after a reboot:
`systemctl --user status sekta-kiosk.service`.

## Offline install

Gather packages once on an online Debian machine of the **same arch + release**
(amd64 / bookworm — ideally a clean image, since `apt-get download` skips
already-installed packages):

```bash
./fetch-debs.sh
```

Copy the whole folder (including `debs/`) to the offline machine, then:

```bash
./install-offline.sh
```

## Reboot

```bash
sudo reboot
```
