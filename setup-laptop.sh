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

configure_pve_hosts_and_apt() {
    local root_dir="$1"
    local sources_file="${root_dir}/etc/apt/sources.list"
    local hostname_file="${root_dir}/etc/hostname"
    local hosts_file="${root_dir}/etc/hosts"
    local interfaces_file="${root_dir}/etc/network/interfaces"

    if [[ -f "$sources_file" ]]; then
        sed -i 's/^[[:space:]]*deb[[:space:]]\+cdrom:/#deb cdrom:/g' "$sources_file"
    fi

    local host_name="debian"
    if [[ -s "$hostname_file" ]]; then
        host_name="$(tr -d '[:space:]' < "$hostname_file")"
    fi

    mkdir -p "${root_dir}/etc"
    if [[ -f "$hosts_file" ]]; then
        local tmp_hosts
        if grep -qE '^[[:space:]]*127\.0\.1\.1[[:space:]]+' "$hosts_file"; then
            tmp_hosts="$(sed "s/^[[:space:]]*127\.0\.1\.1[[:space:]].*/10.99.0.1\t${host_name}.pve.laptop.local\t${host_name}/" "$hosts_file")"
            printf '%s\n' "$tmp_hosts" > "$hosts_file"
        elif ! grep -qE "^[[:space:]]*10\.99\.0\.1[[:space:]]+.*\b${host_name}\b" "$hosts_file"; then
            printf '10.99.0.1\t%s.pve.laptop.local\t%s\n' "$host_name" "$host_name" >> "$hosts_file"
        fi
    else
        cat <<EOF > "$hosts_file"
127.0.0.1	localhost
10.99.0.1	${host_name}.pve.laptop.local	${host_name}
EOF
    fi

    mkdir -p "${root_dir}/etc/network/interfaces.d"
    if [[ ! -f "$interfaces_file" ]]; then
        cat <<'EOF' > "$interfaces_file"
source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback
EOF
    fi
    if ! grep -q "iface vmbr1" "$interfaces_file" 2>/dev/null; then
        cat <<'EOF' >> "$interfaces_file"

auto vmbr1
iface vmbr1 inet static
	address 10.99.0.1/24
	bridge-ports none
	bridge-stp off
	bridge-fd 0
EOF
    fi
}

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

    configure_pve_hosts_and_apt "$root_dir"
}

if [[ "$DRY_RUN" == "1" ]]; then
    STAGE_ROOT="${TARGET_ROOT:-$(mktemp -d)}"
    if [[ -z "$TARGET_ROOT" ]]; then
        trap 'rm -rf "$STAGE_ROOT"' EXIT
    fi
    echo "deb cdrom:[Debian 13.7.0]/ trixie main" > "${STAGE_ROOT}/exchange_sources" || true
    mkdir -p "${STAGE_ROOT}/etc/apt"
    echo "deb cdrom:[Debian 13.7.0]/ trixie main" > "${STAGE_ROOT}/etc/apt/sources.list"
    echo "debian" > "${STAGE_ROOT}/etc/hostname"
    printf "127.0.0.1\tlocalhost\n127.0.1.1\tdebian.local\tdebian\n" > "${STAGE_ROOT}/etc/hosts"
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

HOST_NAME="$(hostname)"
echo "postfix postfix/main_mailer_type select Local only" | debconf-set-selections || true
echo "postfix postfix/mailname string ${HOST_NAME}.pve.laptop.local" | debconf-set-selections || true

/usr/local/bin/pve-wifi-nat.sh || true

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
systemctl restart pve-cluster pvedaemon pveproxy || true
systemctl restart systemd-logind || true
systemctl restart NetworkManager || true

echo "Proxmox VE ${PVE_VERSION} laptop profile is active."
