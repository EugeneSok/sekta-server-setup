# SEKTA kiosk-дисплей

Boot logo (Plymouth) + Chromium kiosk. One command on Debian / Raspberry Pi OS.

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
