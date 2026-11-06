#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISTRO="trixie"
PVE_VERSION="9.2"
PVE_REPO="deb http://download.proxmox.com/debian/pve ${DISTRO} pve-no-subscription"
DRY_RUN=0
TARGET_ROOT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --target-root)
            TARGET_ROOT="$2"
            shift 2
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

deploy_overlay() {
    local root_dir="$1"
    local gpg_dest="${root_dir}/etc/apt/trusted.gpg.d/proxmox-release-${DISTRO}.gpg"
    mkdir -p "${root_dir}/etc/apt/sources.list.d" "${root_dir}/etc/apt/trusted.gpg.d"
    printf '%s\n' "$PVE_REPO" > "${root_dir}/etc/apt/sources.list.d/pve-no-subscription.list"

    if [[ -f "${SCRIPT_DIR}/proxmox-release-${DISTRO}.gpg" ]]; then
        install -m 0644 "${SCRIPT_DIR}/proxmox-release-${DISTRO}.gpg" "$gpg_dest"
    elif [[ "$DRY_RUN" == "0" ]] && command -v wget >/dev/null 2>&1; then
        wget -qO "$gpg_dest" "https://enterprise.proxmox.com/debian/proxmox-release-${DISTRO}.gpg" || true
    fi

    for entry in "${OVERLAY_MANIFEST[@]}"; do
        local mode="${entry%%:*}"
        local rel="${entry#*:}"
        install -m "$mode" -D "${SCRIPT_DIR}/overlay/${rel}" "${root_dir}/${rel}"
    done
}

if [[ "$DRY_RUN" == "1" ]]; then
    STAGE_ROOT="${TARGET_ROOT:-$(mktemp -d)}"
    if [[ -z "$TARGET_ROOT" ]]; then
        trap 'rm -rf "$STAGE_ROOT"' EXIT
    fi
    deploy_overlay "$STAGE_ROOT"
    "${STAGE_ROOT}/usr/local/bin/pve-wifi-nat.sh" --dry-run
    echo "[dry-run] Staged and verified Proxmox VE ${PVE_VERSION} (${DISTRO}) laptop overlay in ${STAGE_ROOT}."
    exit 0
fi

if [[ "$EUID" -ne 0 ]]; then
    echo "Error: setup-laptop.sh must be run as root (or pass --dry-run)." >&2
    exit 1
fi

deploy_overlay "$TARGET_ROOT"

if [[ -n "$TARGET_ROOT" ]]; then
    echo "Staged Proxmox VE ${PVE_VERSION} overlay into target root: ${TARGET_ROOT}"
    exit 0
fi

apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    proxmox-default-kernel \
    proxmox-ve \
    ifupdown2 \
    gnome-core \
    gdm3 \
    network-manager \
    network-manager-gnome \
    iptables \
    nftables \
    dnsmasq-base \
    xdg-utils

systemctl daemon-reload
systemctl enable --now pve-wifi-nat.service || systemctl enable pve-wifi-nat.service || true
systemctl restart systemd-logind || true
systemctl restart NetworkManager || true

echo "Proxmox VE ${PVE_VERSION} laptop profile is active."
