#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISTRO="trixie"
PVE_VERSION="9.2"
PVE_REPO="deb http://download.proxmox.com/debian/pve ${DISTRO} pve-no-subscription"
NETINST_URL="https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/debian-13.7.0-amd64-netinst.iso"
OUT_ISO="${SCRIPT_DIR}/proxmox-gnome-laptop-${PVE_VERSION}-amd64.hybrid.iso"
DRY_RUN=0
BUILD_MODE="installer"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --live-build)
            BUILD_MODE="live-build"
            shift
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

OVERLAY_MANIFEST=(
    "0644:etc/NetworkManager/conf.d/10-proxmox-unmanaged.conf"
    "0755:etc/NetworkManager/dispatcher.d/99-pve-wifi-nat"
    "0644:etc/systemd/logind.conf.d/10-pve-laptop.conf"
    "0644:etc/systemd/system/pve-wifi-nat.service"
    "0755:usr/local/bin/pve-wifi-nat.sh"
    "0644:usr/share/applications/proxmox-desktop.desktop"
)

stage_live_build_tree() {
    local target_dir="$1"
    mkdir -p "${target_dir}/config/package-lists" \
             "${target_dir}/config/archives" \
             "${target_dir}/config/includes.chroot" \
             "${target_dir}/config/hooks/live"

    cat <<EOF > "${target_dir}/config/package-lists/pve-gnome.list.chroot"
gnome-core
gdm3
network-manager
network-manager-gnome
ifupdown2
firefox-esr
iptables
nftables
dnsmasq-base
xdg-utils
pve-headers
proxmox-default-kernel
proxmox-ve
EOF

    cat <<EOF > "${target_dir}/config/archives/pve.list.chroot"
${PVE_REPO}
EOF

    for entry in "${OVERLAY_MANIFEST[@]}"; do
        local mode="${entry%%:*}"
        local rel="${entry#*:}"
        install -m "$mode" -D "${SCRIPT_DIR}/overlay/${rel}" "${target_dir}/config/includes.chroot/${rel}"
    done

    cat <<'EOF' > "${target_dir}/config/hooks/live/01-pve-prep.chroot"
#!/bin/sh
set -e
systemctl enable pve-wifi-nat.service || true
echo "Proxmox VE 9.2 GNOME laptop environment provisioned."
EOF
    chmod 0755 "${target_dir}/config/hooks/live/01-pve-prep.chroot"
}

stage_installer_payload() {
    local target_dir="$1"
    mkdir -p "${target_dir}/proxmox-laptop" \
             "${target_dir}/isolinux" \
             "${target_dir}/boot/grub"

    install -m 0755 "${SCRIPT_DIR}/setup-laptop.sh" "${target_dir}/proxmox-laptop/setup-laptop.sh"
    if [[ -f "${SCRIPT_DIR}/proxmox-release-${DISTRO}.gpg" ]]; then
        install -m 0644 "${SCRIPT_DIR}/proxmox-release-${DISTRO}.gpg" "${target_dir}/proxmox-laptop/proxmox-release-${DISTRO}.gpg"
    fi
    for entry in "${OVERLAY_MANIFEST[@]}"; do
        local mode="${entry%%:*}"
        local rel="${entry#*:}"
        install -m "$mode" -D "${SCRIPT_DIR}/overlay/${rel}" "${target_dir}/proxmox-laptop/overlay/${rel}"
    done

    cat <<EOF > "${target_dir}/preseed.cfg"
d-i apt-setup/non-free boolean true
d-i apt-setup/contrib boolean true
d-i apt-setup/non-free-firmware boolean true
tasksel tasksel/first multiselect standard, gnome-desktop, laptop
d-i pkgsel/include string network-manager network-manager-gnome ifupdown2 iptables nftables dnsmasq-base xdg-utils wget ca-certificates gnupg
d-i preseed/late_command string \\
    cp -r /cdrom/proxmox-laptop /target/root/proxmox-laptop && \\
    in-target /bin/bash /root/proxmox-laptop/setup-laptop.sh && \\
    if [ -f /usr/lib/finish-install.d/55netcfg-copy-config ]; then \\
        printf '\nin-target /bin/bash /root/proxmox-laptop/setup-laptop.sh --target-root /\n' >> /usr/lib/finish-install.d/55netcfg-copy-config; \\
    fi
EOF

    cat <<'EOF' > "${target_dir}/isolinux/gtk.cfg"
default installgui
label installgui
	menu label ^Graphical install (Proxmox VE 9.2 + GNOME Laptop)
	menu default
	kernel /install.amd/vmlinuz
	append vga=788 initrd=/install.amd/gtk/initrd.gz file=/cdrom/preseed.cfg --- quiet
EOF

    cat <<'EOF' > "${target_dir}/isolinux/txt.cfg"
label install
	menu label ^Install (Proxmox VE 9.2 + GNOME Laptop)
	kernel /install.amd/vmlinuz
	append vga=788 initrd=/install.amd/initrd.gz file=/cdrom/preseed.cfg --- quiet
EOF

    cat <<'EOF' > "${target_dir}/boot/grub/grub.cfg"
if [ x$feature_default_font_path = xy ] ; then
   font=unicode
else
   font=$prefix/font.pf2
fi

if loadfont $font ; then
  set gfxmode=800x600
  set gfxpayload=keep
  insmod efi_gop
  insmod efi_uga
  insmod video_bochs
  insmod video_cirrus
  insmod gfxterm
  insmod png
  terminal_output gfxterm
fi

set theme=/boot/grub/theme/1

menuentry --hotkey=g 'Graphical install (Proxmox VE 9.2 + GNOME Laptop)' {
    set background_color=black
    linux    /install.amd/vmlinuz vga=788 file=/cdrom/preseed.cfg --- quiet
    initrd   /install.amd/gtk/initrd.gz
}
menuentry --hotkey=i 'Install (Proxmox VE 9.2 + GNOME Laptop)' {
    set background_color=black
    linux    /install.amd/vmlinuz vga=788 file=/cdrom/preseed.cfg --- quiet
    initrd   /install.amd/initrd.gz
}
EOF
}

if [[ "$DRY_RUN" == "1" ]]; then
    STAGE_DIR="$(mktemp -d)"
    trap 'rm -rf "$STAGE_DIR"' EXIT
    stage_live_build_tree "$STAGE_DIR"
    stage_installer_payload "$STAGE_DIR"
    bash -n "${STAGE_DIR}/config/hooks/live/01-pve-prep.chroot"
    bash -n "${STAGE_DIR}/proxmox-laptop/setup-laptop.sh"
    echo "[dry-run] Validated live-build and installer ISO config for Debian ${DISTRO} and Proxmox VE ${PVE_VERSION}."
    echo "[dry-run] Repo: $(cat "${STAGE_DIR}/config/archives/pve.list.chroot")"
    exit 0
fi

if [[ "$BUILD_MODE" == "installer" ]]; then
    BASE_ISO="/tmp/debian-13-netinst.iso"
    if [[ ! -s "$BASE_ISO" ]]; then
        wget -c -O "$BASE_ISO" "$NETINST_URL"
    fi

    STAGE_DIR="$(mktemp -d)"
    trap 'rm -rf "$STAGE_DIR"' EXIT
    if [[ ! -f "${SCRIPT_DIR}/proxmox-release-${DISTRO}.gpg" ]]; then
        wget -qO "${SCRIPT_DIR}/proxmox-release-${DISTRO}.gpg" \
            "https://enterprise.proxmox.com/debian/proxmox-release-${DISTRO}.gpg"
    fi
    stage_installer_payload "$STAGE_DIR"

    rm -f "$OUT_ISO"

    if command -v xorriso >/dev/null 2>&1; then
        xorriso \
            -indev "$BASE_ISO" \
            -outdev "$OUT_ISO" \
            -boot_image any replay \
            -volid "PVE_9_2_GNOME_LAPTOP" \
            -map "${STAGE_DIR}/preseed.cfg" /preseed.cfg \
            -map "${STAGE_DIR}/proxmox-laptop" /proxmox-laptop \
            -map "${STAGE_DIR}/isolinux/gtk.cfg" /isolinux/gtk.cfg \
            -map "${STAGE_DIR}/isolinux/txt.cfg" /isolinux/txt.cfg \
            -map "${STAGE_DIR}/boot/grub/grub.cfg" /boot/grub/grub.cfg \
            -commit_eject all
    elif command -v docker >/dev/null 2>&1; then
        docker run --rm \
            -v "${BASE_ISO}:/tmp/base.iso:ro" \
            -v "${STAGE_DIR}:/stage:ro" \
            -v "${SCRIPT_DIR}:/out" \
            debian:trixie-slim bash -c "
                apt-get update -qq && apt-get install -y -qq xorriso >/dev/null &&
                xorriso \
                    -indev /tmp/base.iso \
                    -outdev /out/$(basename "$OUT_ISO") \
                    -boot_image any replay \
                    -volid 'PVE_9_2_GNOME_LAPTOP' \
                    -map /stage/preseed.cfg /preseed.cfg \
                    -map /stage/proxmox-laptop /proxmox-laptop \
                    -map /stage/isolinux/gtk.cfg /isolinux/gtk.cfg \
                    -map /stage/isolinux/txt.cfg /isolinux/txt.cfg \
                    -map /stage/boot/grub/grub.cfg /boot/grub/grub.cfg \
                    -commit_eject all &&
                chown $(id -u):$(id -g) /out/$(basename "$OUT_ISO")
            "
    else
        echo "Error: xorriso or docker is required to build the ISO." >&2
        exit 1
    fi

    echo "Build complete: ${OUT_ISO}"
    exit 0
fi

if [[ "$EUID" -ne 0 ]]; then
    echo "Error: build-iso.sh --live-build requires root privileges." >&2
    exit 1
fi

WORK_DIR="${SCRIPT_DIR}/build"
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    live-build debootstrap squashfs-tools xorriso wget ca-certificates

mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

if [[ -d config ]]; then
    lb clean --purge
fi

lb config \
    --mode debian \
    --distribution "$DISTRO" \
    --architectures amd64 \
    --archive-areas "main contrib non-free non-free-firmware" \
    --bootloader syslinux \
    --binary-images iso-hybrid \
    --image-name "proxmox-gnome-laptop-${PVE_VERSION}" \
    --memtest none

stage_live_build_tree "$WORK_DIR"

wget -qO config/archives/pve.key.chroot "https://enterprise.proxmox.com/debian/proxmox-release-${DISTRO}.gpg"
lb build
cp -f "${WORK_DIR}/proxmox-gnome-laptop-${PVE_VERSION}-amd64.hybrid.iso" "$OUT_ISO"
echo "Build complete: ${OUT_ISO}"
