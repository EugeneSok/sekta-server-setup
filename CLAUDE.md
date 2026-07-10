# CLAUDE.md

Guidance for working in this repo.

## What this is

Interactive Proxmox VE host-setup script for the **Sekta** server. Single bash file `pve-setup.sh`, menu-driven, runs on the PVE host as root. No build step, no deps.

Designed to run via `bash <(curl -fsSL <raw>/pve-setup.sh)` — process substitution, NOT `curl | bash` (the script is interactive with `read`, a pipe steals stdin).

## Files

- `pve-setup.sh` — the whole tool. Header comment block → helpers (`info/ok/warn/err/die/confirm`) → one function per module → `show_menu` + `main` loop.
- `README.md` — user-facing: module list + run command. Keep in sync with the menu.
- `CLAUDE.md` — this file.

## Modules (menu order)

1. `post_install` — disable enterprise repo (`.list` + deb822 `.sources`), enable `no-subscription` for detected codename, strip "No valid subscription" nag from `proxmoxlib.js`, `apt dist-upgrade`.
2. `gpu_passthrough` — detect GPUs, tag/default to Intel iGPU. Auto-detects bootloader (GRUB vs systemd-boot) via `detect_bootloader` and edits the right cmdline. IOMMU param from CPU vendor. For Intel iGPU also adds `initcall_blacklist=sysfb_init` + `video=efifb:off,vesafb:off` to release host framebuffer. Writes vfio modules, `vfio.conf` with the whole PCI slot's IDs, driver blacklist. Sets `GPU_NEEDS_REBOOT=1`.
3. `usb_storage` — detect disk, refuse system disk, force exFAT (format via sgdisk+mkfs.exfat if other FS), fstab by UUID with `nofail`, `pvesm add dir USB --content backup`.
4. `network_bridge` — **OPNsense LAN prep**. Existing default-route interface = WAN (untouched), new bridge on a free NIC = LAN, `inet manual` (no host IP — OPNsense owns addressing). Falls back to internal-only bridge if no free NIC. Prints net0=WAN / net1=LAN map.
5. `power_button_vm` — host ignores power key (`logind.conf HandlePowerKey=ignore`), acpid rule → `qm reboot <VMID>` for a user-picked VM.
6. `debian_vm` — scrape `cdimage.debian.org/.../current/` for latest netinst ISO, create VM. **Default VMID 500.** q35/host/4c/8G/10G, no autostart.
7. `iommu_check` — read-only. Shows each GPU's IOMMU group, marks foreign devices `✗`; clean group = safe passthrough.
8. `opnsense_vm` — scrape `$OPN_MIRROR` (default `mirror.dns-root.de/.../mirror/`) for latest `*-dvd-amd64.iso.bz2`, bunzip2, create VM with net0=WAN + net1=LAN. **Default VMID 400.** q35/host/2c/2G/20G, `ostype other`, onboot 1.
9. `pihole_lxc` — `pveam` Debian 12 template, unprivileged LXC (1c/512M/8G) on LAN bridge, static or dhcp, unattended Pi-hole install via `pct exec`. **Default CTID 501.**

## Conventions / gotchas

- **VMID scheme:** OPNsense 400, Debian 500, Pi-hole LXC 501. Each falls back to `pvesh get /cluster/nextid` if taken.
- Every destructive action gets its own `confirm`. Config files (`fstab`, `interfaces`, `grub`, `/etc/kernel/cmdline`, `logind.conf`, repo files, `proxmoxlib.js`) are backed up `*.bak.<epoch>` before edit.
- Bootloader detection matters: PVE on ZFS/UEFI = systemd-boot (`/etc/kernel/cmdline` + `proxmox-boot-tool refresh`), on ext4/LVM = GRUB. `add_kernel_param` handles both, idempotently.
- Storage auto-detect prefers `local-lvm` (images/rootdir), `local` (iso/vztmpl), but always lets the user override.
- ISO/template downloads need host internet. Pi-hole/OPNsense/Debian modules all fetch from external mirrors.
- Nag removal reverts when `proxmox-widget-toolkit` updates — expected.
- The menu loop returns after each module; a hard `die` inside a module exits the whole script (intentional — don't continue past a broken step).

## Validate before pushing

```bash
bash -n pve-setup.sh   # syntax only; cannot run PVE-specific commands on macOS
```

No test suite — every module mutates a live Proxmox host.

## Commit style

Short imperative subject, `Co-Authored-By: Claude` trailer. Push to `main` (public repo `EugeneSok/sekta-server-setup`). The `curl` run pulls from `main`, so commit + push together. Keep `README.md` menu list and this file's module list in sync when adding/reordering modules.
