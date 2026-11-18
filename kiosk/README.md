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

The installer asks how many screens the display has (1–3). One screen: the
address (default `https://combat.omega`) plus up to 2 more sites as tabs.
Several screens: a site for each screen and where screens 2–3 stand (see
[Several screens](#several-screens)). Without a terminal (e.g. `ssh host '…'` without `-t`)
it takes the default address.

### Options (environment variables)

| Variable | Effect |
|---|---|
| `KIOSK_URL="https://a.omega"` | Skip the prompt. 1 URL → locked full screen (`--kiosk`, no tab bar). |
| `KIOSK_URL="https://a.omega https://b.omega"` | Up to 3 space-separated URLs → tabs in a maximised window (tab strip visible, Ctrl+Tab). |
| `KIOSK_SCREENS=2` | 2 or 3 screens, one full-screen site on each; `KIOSK_URL` then lists a site per screen (missing ones repeat screen 1). |
| `KIOSK_LAYOUT="9 3"` | Where screens 2..N stand, as a clock hour around screen 1 (default `3`). |
| `KIOSK_OUTPUTS="HDMI-1 HDMI-2"` | Optional: outputs for screens 1..N (default: primary first, then as `xrandr` / `wlr-randr` lists them). |
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

## Several screens

With 2–3 screens every screen gets its own Chromium in `--kiosk` with its own
site. Where a screen stands is a **clock hour around screen 1**:

| Hour | Screen is |
|---|---|
| `3` | right |
| `9` | left |
| `12` | above |
| `6` | below |
| `1`–`2`, `4`–`5`, `7`–`8`, `10`–`11` | diagonal (e.g. `2` — right, half a screen higher) |

Several screens at the same hour line up: `3 3` — two screens in a row to the
right of screen 1; `9 3` — screen 1 in the middle.

```bash
curl -fsSL https://raw.githubusercontent.com/EugeneSok/sekta-server-setup/main/kiosk/install.sh \
  | KIOSK_SCREENS=3 KIOSK_LAYOUT="9 3" KIOSK_URL="https://a.omega https://b.omega https://c.omega" bash
```

The unit then runs `~/.local/bin/sekta-kiosk-screens` (`kiosk-screens.sh`) with
settings in `~/.config/sekta-kiosk/screens.conf` (editable; restart the unit
after a change). On every start it waits up to a minute for the screens,
arranges them — `xrandr` on X11, `wlr-randr` on labwc / wayfire — and opens a
full-screen window per screen:

- **X11 (GNOME included)** — one Chromium, one profile: **log in once**, it
  counts on every screen. Windows are put on their screens with `wmctrl`.
  GNOME on Wayland allows neither, so for several screens the installer sets
  `WaylandEnable=false` in `/etc/gdm3/daemon.conf` (backup `*.bak.<epoch>`;
  after a reboot GNOME runs on Xorg). Reinstalling with one screen (or the
  Sekta APP) gives Wayland back — only if the installer was the one to turn it
  off. Restored windows beyond the screen count are closed.
- **Wayland without X11** (labwc / wayfire) — one Chromium per screen through
  XWayland (`--ozone-platform=x11`); screens 2–3 have their own profiles
  (`~/.config/sekta-kiosk/chromium-N`), log in on each separately.

If a window closes, all restart. Screen 1 is the **primary** output; if the
order is wrong, swap the cables or set `KIOSK_OUTPUTS` (names from `xrandr` /
`wlr-randr`). Fewer screens connected than configured — the kiosk starts on
those (waiting up to a minute on the first start after boot, 5 s on restarts).
Connected outputs beyond the kiosk screens (e.g. a laptop panel) are moved to
the right of the layout.

```bash
journalctl --user -u chromium-kiosk.service   # which output got which site
```

**Pages are remembered** (`RESTORE=auto` — with several screens; one screen
always opens its sites, so an unattended dashboard comes back to it on every
boot; `RESTORE=1` / `0` in `screens.conf` — always / never). Each screen reopens what was on it before the
reboot / restart (`--restore-last-session`: pages, history, scroll position —
as far as the site allows), not the configured site. With one profile the
restored windows go to the nearest screen; a screen left without one opens its
configured site. First start, or after a
reset, opens the configured sites. Reinstalling resets too, so new sites apply.

```bash
~/.local/bin/sekta-kiosk-screens --reset && systemctl --user restart chromium-kiosk.service   # back to the configured sites
```


## Sekta kiosk app (screens and sites later)

The browser kiosk installs a small app, **«Sekta kiosk — екрани»**
(`~/.local/bin/sekta-kiosk`, zenity windows): open it from the app menu or with
**Ctrl+Alt+K** — also over the full-screen kiosk (GNOME shortcut; the dialogs
stay on top on X11). On labwc / wayfire (Raspberry Pi OS) there is no hotkey —
run `sekta-kiosk` from a terminal or `DISPLAY=:0 ~/.local/bin/sekta-kiosk` over ssh.

The kiosk owns the display user's Chromium: screen 1 uses the default profile,
«Повернути задані сайти» / a reinstall forget its saved pages, and with several
screens on X11 a Chromium opened by hand is closed when the kiosk starts — use
a dedicated user for the display.

- **Екрани й сайти** — add / remove a screen (up to 3), pick its output
  (`авто` or a name like `HDMI-2`), where it stands (clock hour around screen 1)
  and its site; one screen may hold several sites as tabs. «Застосувати» writes
  `screens.conf` and restarts the kiosk; new sites reset the remembered pages.
  Going from one screen to several switches GNOME to Xorg (`pkexec`, admin
  password) and offers a reboot; back to one screen gives Wayland back.
- **Визначити екрани** — every monitor shows its output name and kiosk screen
  number, to see which cable is which.
- **Повернути задані сайти** — forget the remembered pages.
- **Перезапустити / Зупинити / Запустити kiosk.**

The kiosk unit always runs `sekta-kiosk-screens` (one screen included), so the
app only edits `screens.conf` (`sekta-kiosk-screens --write-conf`). From a USB
stick the same app is the offline installer — see [Offline install](#offline-install).

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

## Offline package (Debian, no network)

One `.deb` per release and arch with everything inside — the sekta-kiosk app,
the installer and all packages it needs (Chromium, Plymouth, zenity, wmctrl…
with dependencies). The package has no dependencies of its own:

```bash
sudo apt install ./sekta-kiosk_1.0.0+bookworm_amd64.deb   # no network needed
```

Then **«Sekta kiosk»** in the app menu (or `sekta-kiosk` in a terminal):

- first start: installs the bundled packages (no zenity yet → a terminal opens,
  sudo password there), then asks screens and sites in windows and installs
  the kiosk (everything of pve-setup item 7); reboot;
- later starts (menu, Ctrl+Alt+K): the screen manager above;
- a newer package installed over it: the app offers to update the kiosk —
  screens, sites and the open pages stay; «Перевстановити kiosk» in the menu
  repairs a broken install with the same version.

The user needs sudo. Debian installed **with a root password** has no sudo at
all — the app shows the one command (as root, sudo comes from the package):
`su - -c "apt install /usr/share/sekta-kiosk/debs/<release>-<arch>/sudo_*.deb && usermod -aG sudo $USER"`,
then log out and in.

Build (Docker; amd64 on an arm64 Mac works through emulation, ~2 min):

```bash
kiosk/build-deb.sh                  # bookworm amd64 (Debian 12)
kiosk/build-deb.sh trixie amd64     # Debian 13
FRESH=1 kiosk/build-deb.sh          # fetch the bundle again (else debs/<release>-<arch> is reused)
kiosk/build-deb.sh --local          # on this machine: online Debian / RPi OS of the target's release and arch
```

→ `kiosk/dist/sekta-kiosk_<VERSION>+<release>_<arch>.deb` (~260–320 MB,
gitignored). Raspberry Pi OS: build with `--local` on an online RPi — its
Chromium comes from the Raspberry Pi repo, not Debian's. Version — `kiosk/VERSION`;
raise it for a release, so displays with the old one get the update offer.
Removing the package keeps the installed kiosk (`~/.local/bin`) and its menu entry.

## Offline install

Same browser kiosk as `install.sh` — up to 3 sites as tabs or 2–3 screens,
UA keyboard, no screen sleep, autologin — without network.

Gather packages once on an **online** Debian / Raspberry Pi OS machine of the
**same release and arch** as the target (e.g. bookworm or trixie; amd64 or arm64).
apt resolves one consistent, complete set as if the target had nothing
installed, so the online machine does not need to be clean. Expect ~250 `.deb`,
~240 MB per bundle, in `debs/<release>-<arch>/` (e.g. `debs/bookworm-amd64`;
not committed — gitignored):

```bash
./fetch-debs.sh
```

Run it on one machine per release/arch you need — **one stick can carry several
bundles**; the installer picks the one for its machine (`VERSION_CODENAME` +
`dpkg --print-architecture`). A flat `debs/` from an older `fetch-debs.sh`
still works.

Copy the whole `kiosk/` folder (scripts incl. `kiosk-screens.sh` and
`sekta-kiosk.sh`, logo/bar PNGs, `debs/`) to the offline machine, e.g. on a USB
stick. **In windows** (GNOME): open a terminal and run the app from the stick —
it asks the screens and sites, then the sudo password, and installs everything:

```bash
bash /media/$USER/<stick>/kiosk/sekta-kiosk.sh
```

Or in the terminal only — run it with `bash` (a stick mounted `noexec` gives
`Permission denied` for `./install-offline.sh`):

```bash
bash ./install-offline.sh
# or non-interactive, 1–3 sites:
KIOSK_URL="https://a.omega https://b.omega" bash ./install-offline.sh
# two screens, the second one to the right:
KIOSK_SCREENS=2 KIOSK_LAYOUT=3 KIOSK_URL="https://a.omega https://b.omega" bash ./install-offline.sh
```

Only packages missing on the target (or older than in `debs/`) are installed —
newer system packages are never downgraded. `fetch-debs.sh` writes
`debs/BUNDLE` (distro, release, arch); `install-offline.sh` refuses a bundle
made for another release or architecture, and one without `BUNDLE` (made by an
older `fetch-debs.sh` — re-run it), before changing anything. Without a bundle
for its machine it lists the ones on the stick.

## Reboot

```bash
sudo reboot
```

`1.md` / `2.md` — manual step-by-step notes (splash, kiosk unit) the installer
was built from; the installer is the source of truth.
