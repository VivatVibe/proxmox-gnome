#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

for script in \
    "${SCRIPT_DIR}/build-iso.sh" \
    "${SCRIPT_DIR}/setup-laptop.sh" \
    "${SCRIPT_DIR}/overlay/usr/local/bin/pve-wifi-nat.sh" \
    "${SCRIPT_DIR}/overlay/etc/NetworkManager/dispatcher.d/99-pve-wifi-nat" \
    "${SCRIPT_DIR}/test-vm-boot.sh" \
    "${SCRIPT_DIR}/verify.sh"; do
    bash -n "$script" || fail "Syntax error in $script"
done

EXPECTED_REPO="deb http://download.proxmox.com/debian/pve trixie pve-no-subscription"
grep -Fq 'DISTRO="trixie"' "${SCRIPT_DIR}/build-iso.sh" || fail "build-iso.sh missing DISTRO=trixie"
grep -Fq 'PVE_VERSION="9.2"' "${SCRIPT_DIR}/build-iso.sh" || fail "build-iso.sh missing PVE_VERSION=9.2"
grep -Fq 'proxmox-default-kernel' "${SCRIPT_DIR}/build-iso.sh" || fail "build-iso.sh missing proxmox-default-kernel"
grep -Fq 'proxmox-ve' "${SCRIPT_DIR}/build-iso.sh" || fail "build-iso.sh missing proxmox-ve"

grep -Fq 'proxmox-default-kernel' "${SCRIPT_DIR}/setup-laptop.sh" || fail "setup-laptop.sh missing proxmox-default-kernel"
grep -Fq 'proxmox-ve' "${SCRIPT_DIR}/setup-laptop.sh" || fail "setup-laptop.sh missing proxmox-ve"

NM_CONF="${SCRIPT_DIR}/overlay/etc/NetworkManager/conf.d/10-proxmox-unmanaged.conf"
grep -Fq "unmanaged-devices=interface-name:vmbr*;interface-name:eth*;interface-name:en*" "$NM_CONF" || \
    fail "NetworkManager unmanaged-devices mismatch"

DISPATCHER_HOOK="${SCRIPT_DIR}/overlay/etc/NetworkManager/dispatcher.d/99-pve-wifi-nat"
grep -Fq "/usr/local/bin/pve-wifi-nat.sh" "$DISPATCHER_HOOK" || \
    fail "Dispatcher hook missing pve-wifi-nat.sh invocation"

LOGIND_CONF="${SCRIPT_DIR}/overlay/etc/systemd/logind.conf.d/10-pve-laptop.conf"
grep -Fq "HandleLidSwitch=ignore" "$LOGIND_CONF" || fail "HandleLidSwitch=ignore missing"

NAT_SCRIPT="${SCRIPT_DIR}/overlay/usr/local/bin/pve-wifi-nat.sh"
grep -Fq 'VMBR="vmbr1"' "$NAT_SCRIPT" || fail "vmbr1 missing in pve-wifi-nat.sh"
grep -Fq 'BRIDGE_IP="10.99.0.1/24"' "$NAT_SCRIPT" || fail "10.99.0.1/24 missing in pve-wifi-nat.sh"
grep -Fq 'MASQUERADE' "$NAT_SCRIPT" || fail "iptables MASQUERADE missing in pve-wifi-nat.sh"
grep -Fq 'masquerade' "$NAT_SCRIPT" || fail "nftables masquerade missing in pve-wifi-nat.sh"

DESKTOP_FILE="${SCRIPT_DIR}/overlay/usr/share/applications/proxmox-desktop.desktop"
grep -Fq "https://127.0.0.1:8006" "$DESKTOP_FILE" || fail "Web GUI URL missing in desktop entry"

ISO_DRY_OUT="$("${SCRIPT_DIR}/build-iso.sh" --dry-run)"
echo "$ISO_DRY_OUT" | grep -Fq "$EXPECTED_REPO" || fail "build-iso.sh --dry-run did not output expected Trixie repo"

SETUP_DRY_OUT="$("${SCRIPT_DIR}/setup-laptop.sh" --dry-run)"
echo "$SETUP_DRY_OUT" | grep -Fq "[dry-run] ip addr add 10.99.0.1/24 dev vmbr1" || \
    fail "setup-laptop.sh --dry-run did not verify vmbr1 NAT setup"

ISO_FILE="${SCRIPT_DIR}/proxmox-gnome-laptop-9.2-amd64.hybrid.iso"
if [[ -f "$ISO_FILE" ]]; then
    ISO_SIZE=$(stat -c%s "$ISO_FILE")
    [[ "$ISO_SIZE" -gt 700000000 ]] || fail "ISO file is unexpectedly small ($ISO_SIZE bytes)"
fi

if [[ "${1:-}" == "--runtime" ]]; then
    docker run --rm --privileged -v "${SCRIPT_DIR}:/repo:ro" debian:trixie-slim bash -c '
        set -euo pipefail
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq --no-install-recommends \
            wget ca-certificates gnupg desktop-file-utils iproute2 iputils-ping procps iptables nftables >/dev/null
        /repo/setup-laptop.sh --target-root /
        test -x /etc/NetworkManager/dispatcher.d/99-pve-wifi-nat
        desktop-file-validate /usr/share/applications/proxmox-desktop.desktop
        apt-get update -qq
        apt-get install -s --no-install-recommends \
            proxmox-default-kernel proxmox-ve ifupdown2 gnome-core gdm3 \
            network-manager network-manager-gnome iptables nftables dnsmasq-base xdg-utils \
            | grep -Fq "Inst proxmox-ve (9.2"
        /etc/NetworkManager/dispatcher.d/99-pve-wifi-nat vmbr1 up
        /etc/NetworkManager/dispatcher.d/99-pve-wifi-nat wlan0 up
        /etc/NetworkManager/dispatcher.d/99-pve-wifi-nat wlan0 dhcp4-change
        ip -4 addr show dev vmbr1 | grep -Fq "10.99.0.1/24"
        iptables -t nat -S POSTROUTING | grep -Fq "10.99.0.0/24"
        ip netns add guestvm
        ip link add veth-host type veth peer name veth-guest
        ip link set veth-host master vmbr1
        ip link set veth-host up
        ip link set veth-guest netns guestvm
        ip netns exec guestvm ip addr add 10.99.0.2/24 dev veth-guest
        ip netns exec guestvm ip link set lo up
        ip netns exec guestvm ip link set veth-guest up
        ip netns exec guestvm ip route add default via 10.99.0.1
        ip netns exec guestvm ping -c 2 -W 3 10.99.0.1 >/dev/null
        HOST_IP=$(ip -4 addr show dev eth0 | awk "/inet / {split(\$2, a, \"/\"); print a[1]; exit}")
        if [[ -n "$HOST_IP" ]]; then
            ip netns exec guestvm ping -c 2 -W 3 "$HOST_IP" >/dev/null
        fi
    ' || fail "Debian 13 runtime container verification failed"
fi

echo "PASS: All syntax, repository, overlay, dry-run, and runtime checks succeeded."
