# Proxmox VE 9.2 and GNOME laptop installer for Debian 13 Trixie

Build a bootable Debian 13 (Trixie) hybrid ISO and host installer that provisions Proxmox VE 9.2 alongside GNOME Desktop on a laptop without breaking hypervisor networking.

## Components

- **Debian 13 Trixie and Proxmox VE 9.2.** Configures `deb http://download.proxmox.com/debian/pve trixie pve-no-subscription`, `/etc/apt/trusted.gpg.d/proxmox-release-trixie.gpg`, `proxmox-default-kernel`, and `proxmox-ve`.
- **NetworkManager and `ifupdown2` isolation.** Marks `vmbr*`, `eth*`, and `en*` as unmanaged in `/etc/NetworkManager/conf.d/10-proxmox-unmanaged.conf` so GNOME manages Wi-Fi (`wl*`, `wlan*`, `wlo*`) while Proxmox owns bridge interfaces.
- **Automatic Wi-Fi NAT bridge (`vmbr1`).** Creates `vmbr1` on `10.99.0.1/24` via `/usr/local/bin/pve-wifi-nat.sh` with `flock` serialization and idempotent `iptables` and `nftables` masquerade rules. Runs at boot via `pve-wifi-nat.service` before `pve-cluster.service` and whenever Wi-Fi connects or changes IP via `/etc/NetworkManager/dispatcher.d/99-pve-wifi-nat`.
- **Laptop lid policy.** Sets `HandleLidSwitch=ignore` in `/etc/systemd/logind.conf.d/10-pve-laptop.conf` so guest VMs keep running when you close the laptop lid.
- **GNOME desktop launcher.** Installs `/usr/share/applications/proxmox-desktop.desktop` to open `https://127.0.0.1:8006`.

## Build the hybrid ISO

To build `proxmox-gnome-laptop-9.2-amd64.hybrid.iso`, run:

```bash
./build-iso.sh
```

To write the generated hybrid ISO to a USB drive (`/dev/sdX`), run:

```bash
sudo dd if=proxmox-gnome-laptop-9.2-amd64.hybrid.iso of=/dev/sdX bs=4M status=progress oflag=sync
```

## Apply to an existing Debian 13 laptop

To provision an existing Debian 13 (Trixie) installation, run:

```bash
sudo ./setup-laptop.sh
```

To reconcile overlay files, `/etc/network/interfaces`, and `pve-wifi-nat.service` on an already provisioned host without running `apt-get`, run:

```bash
sudo ./setup-laptop.sh --reconcile
```

## Verify the configuration and host

To run syntax, repository, overlay, and non-root `--dry-run` checks, run:

```bash
./verify.sh
```

To verify an installed Proxmox VE 9.2 laptop host (`*-pve` kernel, `/etc/apt/sources.list`, `/etc/hosts`, `/etc/network/interfaces`, deployed overlay files, `systemd` service states, port `8006` HTTPS response, `vmbr1` NAT rules, and live guest network namespace routing to `1.1.1.1` over Wi-Fi), run either command:

```bash
sudo ./verify.sh --host
sudo ./verify.sh --live
```

To run the isolated runtime verification (staging root, OpenPGP key and `proxmox-ve` 9.2 package checks, `vmbr1` creation, and `guestvm` NAT routing inside Docker or an isolated `unshare --net` namespace), run:

```bash
./verify.sh --runtime
```

To boot the built ISO in QEMU/KVM (`/dev/kvm`) and capture installer screenshots, run:

```bash
./test-vm-boot.sh
```
