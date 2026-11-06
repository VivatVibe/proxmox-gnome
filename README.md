# Proxmox VE 9.2 + GNOME Laptop Installer (Debian 13 Trixie)

Build a bootable Debian 13 (Trixie) hybrid ISO and host installer that provisions Proxmox VE 9.2 alongside GNOME Desktop on a laptop without breaking hypervisor networking.

## Features

- **Debian 13 Trixie + Proxmox VE 9.2:** Configures `deb http://download.proxmox.com/debian/pve trixie pve-no-subscription`, `proxmox-release-trixie.gpg`, `proxmox-default-kernel`, and `proxmox-ve`.
- **NetworkManager and `ifupdown2` Isolation:** Marks `vmbr*`, `eth*`, and `en*` as unmanaged in `/etc/NetworkManager/conf.d/10-proxmox-unmanaged.conf` so GNOME manages Wi-Fi (`wl*`, `wlan*`, `wlo*`) while Proxmox owns bridge interfaces.
- **Automatic Wi-Fi NAT Bridge (`vmbr1`):** Creates `vmbr1` on `10.99.0.1/24` via `/usr/local/bin/pve-wifi-nat.sh` with idempotent `iptables` and `nftables` masquerade rules, triggered at boot (`pve-wifi-nat.service`) and whenever Wi-Fi connects or roams (`/etc/NetworkManager/dispatcher.d/99-pve-wifi-nat`).
- **Laptop Lid Policy:** Ignores lid close events (`HandleLidSwitch=ignore`) in `/etc/systemd/logind.conf.d/10-pve-laptop.conf` so guest VMs keep running when the laptop lid is closed.
- **GNOME Desktop Launcher:** Installs `/usr/share/applications/proxmox-desktop.desktop` to open `https://127.0.0.1:8006`.

## Build the Hybrid ISO

To build `proxmox-gnome-laptop-9.2-amd64.hybrid.iso`, run:

```bash
./build-iso.sh
```

To write the generated hybrid ISO to a USB drive (`/dev/sdX`), run:

```bash
sudo dd if=proxmox-gnome-laptop-9.2-amd64.hybrid.iso of=/dev/sdX bs=4M status=progress oflag=sync
```

## Apply to an Existing Debian 13 Laptop

To provision an existing Debian 13 (Trixie) installation directly, run:

```bash
sudo ./setup-laptop.sh
```

## Verify

To run syntax, repository, overlay, and non-root `--dry-run` checks:

```bash
./verify.sh
```

To run the full Debian 13 runtime verification (OpenPGP key validation, `apt` dependency resolution for `proxmox-ve` 9.2, `vmbr1` creation, NetworkManager dispatcher hook execution, and Guest VM NAT routing to `1.1.1.1`):

```bash
./verify.sh --runtime
```

To test booting the built ISO under QEMU/KVM (`/dev/kvm`) and capture boot screenshots:

```bash
./test-vm-boot.sh
```
