#!/usr/bin/env bash
set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPECTED_REPO="deb http://download.proxmox.com/debian/pve trixie pve-no-subscription"

OVERLAY_MANIFEST=(
    "644:etc/NetworkManager/conf.d/10-proxmox-unmanaged.conf"
    "755:etc/NetworkManager/dispatcher.d/99-pve-wifi-nat"
    "644:etc/dconf/profile/user"
    "644:etc/dconf/db/local.d/00-proxmox-laptop"
    "644:etc/systemd/logind.conf.d/10-pve-laptop.conf"
    "644:etc/systemd/system/pve-wifi-nat.service"
    "755:usr/local/bin/pve-wifi-nat.sh"
    "755:usr/local/bin/pve-laptop-status"
    "755:usr/local/bin/pve-laptop-tui"
    "644:usr/share/applications/proxmox-desktop.desktop"
    "644:usr/share/applications/proxmox-laptop-tui.desktop"
    "644:usr/share/gnome-shell/extensions/proxmox-laptop@pve.local/metadata.json"
    "644:usr/share/gnome-shell/extensions/proxmox-laptop@pve.local/extension.js"
)

HOST_REQUIRED_PACKAGES=(
    proxmox-ve
    proxmox-default-kernel
    gnome-core
    gdm3
    network-manager
    ifupdown2
)

HOST_REQUIRED_SERVICES=(
    pve-wifi-nat.service
    pve-cluster.service
    pvedaemon.service
    pveproxy.service
    gdm.service
    NetworkManager.service
)

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

verify_host() {
    grep -Fq "VERSION_CODENAME=trixie" /etc/os-release || fail "/etc/os-release missing VERSION_CODENAME=trixie"
    [[ "$(uname -r)" == *-pve ]] || fail "Running kernel $(uname -r) is not a Proxmox VE kernel (*-pve)"

    if [[ -r /var/log/installer/syslog ]]; then
        ! grep -Eq "Failed to run preseed command|Execution of preseed command.*failed" /var/log/installer/syslog || \
            fail "/var/log/installer/syslog contains preseed failure entries"
    fi

    [[ -f /etc/apt/sources.list ]] || fail "/etc/apt/sources.list does not exist"
    ! grep -Eq '^[[:space:]]*deb[[:space:]]+cdrom:' /etc/apt/sources.list || \
        fail "/etc/apt/sources.list still has an active deb cdrom: entry"

    [[ -f /etc/apt/sources.list.d/pve-no-subscription.list ]] || \
        fail "/etc/apt/sources.list.d/pve-no-subscription.list is missing"
    grep -Fq "$EXPECTED_REPO" /etc/apt/sources.list.d/pve-no-subscription.list || \
        fail "/etc/apt/sources.list.d/pve-no-subscription.list does not match $EXPECTED_REPO"
    [[ -s /etc/apt/trusted.gpg.d/proxmox-release-trixie.gpg ]] || \
        fail "/etc/apt/trusted.gpg.d/proxmox-release-trixie.gpg is missing or empty"

    local host_name
    host_name="$(hostname)"
    grep -Eq "^[[:space:]]*10\.99\.0\.1[[:space:]]+.*\b${host_name}\b" /etc/hosts || \
        fail "/etc/hosts does not map ${host_name} to 10.99.0.1"
    ! grep -Eq '^[[:space:]]*127\.0\.1\.1[[:space:]]+' /etc/hosts || \
        fail "/etc/hosts still contains a 127.0.1.1 entry"

    grep -Fq "auto vmbr1" /etc/network/interfaces || fail "/etc/network/interfaces missing 'auto vmbr1'"
    grep -Fq "iface vmbr1 inet static" /etc/network/interfaces || fail "/etc/network/interfaces missing 'iface vmbr1 inet static'"
    grep -Fq "address 10.99.0.1/24" /etc/network/interfaces || fail "/etc/network/interfaces missing 'address 10.99.0.1/24'"

    local entry expected_mode rel deployed_path actual_mode
    for entry in "${OVERLAY_MANIFEST[@]}"; do
        expected_mode="${entry%%:*}"
        rel="${entry#*:}"
        deployed_path="/${rel}"
        [[ -f "$deployed_path" ]] || fail "Overlay file missing on host: $deployed_path"
        actual_mode="$(stat -c "%a" "$deployed_path")"
        [[ "$actual_mode" == "$expected_mode" ]] || \
            fail "Mode mismatch on $deployed_path (expected $expected_mode, got $actual_mode)"
        cmp -s "${SCRIPT_DIR}/overlay/${rel}" "$deployed_path" || \
            fail "Content mismatch between repo overlay/${rel} and deployed $deployed_path"
    done

    desktop-file-validate /usr/share/applications/proxmox-desktop.desktop || \
        fail "desktop-file-validate failed for /usr/share/applications/proxmox-desktop.desktop"
    desktop-file-validate /usr/share/applications/proxmox-laptop-tui.desktop || \
        fail "desktop-file-validate failed for /usr/share/applications/proxmox-laptop-tui.desktop"
    /usr/local/bin/pve-laptop-status --json | python3 -c "import json,sys; d=json.load(sys.stdin); assert 'local_url' in d and 'pveproxy' in d" || \
        fail "/usr/local/bin/pve-laptop-status --json did not return valid status JSON"
    /usr/local/bin/pve-laptop-tui --once >/dev/null || \
        fail "/usr/local/bin/pve-laptop-tui --once failed"

    local pkg pkg_status
    for pkg in "${HOST_REQUIRED_PACKAGES[@]}"; do
        pkg_status="$(dpkg-query -W -f='${db:Status-Status}' "$pkg" 2>/dev/null || true)"
        [[ "$pkg_status" == "installed" ]] || fail "Required package $pkg is not installed (status: ${pkg_status:-missing})"
    done

    local svc
    for svc in "${HOST_REQUIRED_SERVICES[@]}"; do
        systemctl is-active --quiet "$svc" || fail "Required service $svc is not active"
    done

    ss -tln | grep -Eq ':8006[[:space:]]' || fail "Port 8006 is not listening"
    [[ "$(curl -k -s -o /dev/null -w '%{http_code}' https://127.0.0.1:8006)" == "200" ]] || \
        fail "https://127.0.0.1:8006 did not return HTTP 200 OK"

    ip -4 addr show dev vmbr1 | grep -Fq "10.99.0.1/24" || fail "vmbr1 does not have 10.99.0.1/24 assigned"
    [[ "$(sysctl -n net.ipv4.ip_forward)" == "1" ]] || fail "net.ipv4.ip_forward is not 1"

    local run_root=()
    if [[ "$EUID" -ne 0 ]]; then
        if sudo -n true 2>/dev/null; then
            run_root=(sudo)
        else
            fail "Root privileges required for live NAT rule and network namespace routing checks (run: sudo ./verify.sh --host)"
        fi
    fi

    if ! "${run_root[@]}" iptables -w 5 -t nat -S POSTROUTING 2>/dev/null | grep -Fq "10.99.0.0/24" && \
       ! "${run_root[@]}" nft list table ip pve_wifi_nat 2>/dev/null | grep -Fq "masquerade"; then
        fail "Neither iptables POSTROUTING nor nft pve_wifi_nat contains 10.99.0.0/24 masquerade rule"
    fi

    cleanup_verify_netns() {
        "${run_root[@]}" ip link del veth-pve-host 2>/dev/null || true
        "${run_root[@]}" ip netns del pve-verify-vm 2>/dev/null || true
    }
    cleanup_verify_netns
    trap cleanup_verify_netns RETURN EXIT

    "${run_root[@]}" ip netns add pve-verify-vm || fail "Failed to create netns pve-verify-vm"
    "${run_root[@]}" ip link add veth-pve-host type veth peer name veth-pve-guest || fail "Failed to create veth pair"
    "${run_root[@]}" ip link set veth-pve-host master vmbr1 || fail "Failed to attach veth-pve-host to vmbr1"
    "${run_root[@]}" ip link set veth-pve-host up || fail "Failed to bring up veth-pve-host"
    "${run_root[@]}" ip link set veth-pve-guest netns pve-verify-vm || fail "Failed to move veth-pve-guest into pve-verify-vm"
    "${run_root[@]}" ip netns exec pve-verify-vm ip addr add 10.99.0.2/24 dev veth-pve-guest || fail "Failed to assign 10.99.0.2/24 in pve-verify-vm"
    "${run_root[@]}" ip netns exec pve-verify-vm ip link set lo up || fail "Failed to bring up lo in pve-verify-vm"
    "${run_root[@]}" ip netns exec pve-verify-vm ip link set veth-pve-guest up || fail "Failed to bring up veth-pve-guest"
    "${run_root[@]}" ip netns exec pve-verify-vm ip route add default via 10.99.0.1 || fail "Failed to set default route via 10.99.0.1 in pve-verify-vm"
    "${run_root[@]}" ip netns exec pve-verify-vm ping -c 2 -W 3 10.99.0.1 >/dev/null || fail "Guest netns pve-verify-vm failed to ping bridge gateway 10.99.0.1"
    "${run_root[@]}" ip netns exec pve-verify-vm ping -c 2 -W 3 1.1.1.1 >/dev/null || fail "Guest netns pve-verify-vm failed to reach 1.1.1.1 via Wi-Fi NAT"

    cleanup_verify_netns
    trap - RETURN EXIT
    echo "PASS: Live Proxmox VE 9.2 GNOME laptop host verification succeeded."
}

for script in \
    "${SCRIPT_DIR}/build-iso.sh" \
    "${SCRIPT_DIR}/setup-laptop.sh" \
    "${SCRIPT_DIR}/overlay/usr/local/bin/pve-wifi-nat.sh" \
    "${SCRIPT_DIR}/overlay/usr/local/bin/pve-laptop-status" \
    "${SCRIPT_DIR}/overlay/etc/NetworkManager/dispatcher.d/99-pve-wifi-nat" \
    "${SCRIPT_DIR}/test-vm-boot.sh" \
    "${SCRIPT_DIR}/verify.sh"; do
    bash -n "$script" || fail "Syntax error in $script"
done

PYTHONDONTWRITEBYTECODE=1 python3 -B -m py_compile "${SCRIPT_DIR}/overlay/usr/local/bin/pve-laptop-tui" || \
    fail "Python syntax error in pve-laptop-tui"
python3 -c "import json,sys; m=json.load(open(sys.argv[1])); assert m['uuid']=='proxmox-laptop@pve.local' and '48' in m['shell-version']" \
    "${SCRIPT_DIR}/overlay/usr/share/gnome-shell/extensions/proxmox-laptop@pve.local/metadata.json" || \
    fail "Invalid GNOME extension metadata.json"
grep -Fq "ProxmoxLaptopExtension" "${SCRIPT_DIR}/overlay/usr/share/gnome-shell/extensions/proxmox-laptop@pve.local/extension.js" || \
    fail "Missing ProxmoxLaptopExtension class in extension.js"

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

SERVICE_FILE="${SCRIPT_DIR}/overlay/etc/systemd/system/pve-wifi-nat.service"
grep -Fq "Before=pve-cluster.service pvedaemon.service pveproxy.service" "$SERVICE_FILE" || \
    fail "pve-wifi-nat.service missing Before=pve-cluster.service ordering"

NAT_SCRIPT="${SCRIPT_DIR}/overlay/usr/local/bin/pve-wifi-nat.sh"
grep -Fq 'VMBR="vmbr1"' "$NAT_SCRIPT" || fail "vmbr1 missing in pve-wifi-nat.sh"
grep -Fq 'BRIDGE_IP="10.99.0.1/24"' "$NAT_SCRIPT" || fail "10.99.0.1/24 missing in pve-wifi-nat.sh"
grep -Fq 'MASQUERADE' "$NAT_SCRIPT" || fail "iptables MASQUERADE missing in pve-wifi-nat.sh"
grep -Fq 'masquerade' "$NAT_SCRIPT" || fail "nftables masquerade missing in pve-wifi-nat.sh"

DESKTOP_FILE="${SCRIPT_DIR}/overlay/usr/share/applications/proxmox-desktop.desktop"
grep -Fq "https://127.0.0.1:8006" "$DESKTOP_FILE" || fail "Web GUI URL missing in desktop entry"

ISO_DRY_OUT="$("${SCRIPT_DIR}/build-iso.sh" --dry-run)"
echo "$ISO_DRY_OUT" | grep -Fq "$EXPECTED_REPO" || fail "build-iso.sh --dry-run did not output expected Trixie repo"

STAGE_TEST="$(mktemp -d)"
trap 'rm -rf "$STAGE_TEST"' EXIT
mkdir -p "${STAGE_TEST}/etc/apt"
echo "deb cdrom:[Debian GNU/Linux 13.7.0 _Trixie_]/ trixie contrib main non-free-firmware" > "${STAGE_TEST}/etc/apt/sources.list"
echo "debian" > "${STAGE_TEST}/etc/hostname"
printf "127.0.0.1\tlocalhost\n127.0.1.1\tdebian.pve.laptop.local\tdebian\n" > "${STAGE_TEST}/etc/hosts"

SETUP_DRY_OUT="$("${SCRIPT_DIR}/setup-laptop.sh" --dry-run --target-root "$STAGE_TEST")"
echo "$SETUP_DRY_OUT" | grep -Fq "[dry-run] ip addr add 10.99.0.1/24 dev vmbr1" || \
    fail "setup-laptop.sh --dry-run did not verify vmbr1 NAT setup"
grep -Fq "#deb cdrom:" "${STAGE_TEST}/etc/apt/sources.list" || \
    fail "setup-laptop.sh did not comment out deb cdrom: in sources.list"
grep -Fq "10.99.0.1	debian.pve.laptop.local	debian" "${STAGE_TEST}/etc/hosts" || \
    fail "setup-laptop.sh did not rewrite 127.0.1.1 to 10.99.0.1 in /etc/hosts"
grep -Fq "iface vmbr1 inet static" "${STAGE_TEST}/etc/network/interfaces" || \
    fail "setup-laptop.sh did not configure vmbr1 in /etc/network/interfaces"

ISO_FILE="${SCRIPT_DIR}/proxmox-gnome-laptop-9.2-amd64.hybrid.iso"
if [[ -f "$ISO_FILE" ]]; then
    ISO_SIZE=$(stat -c%s "$ISO_FILE")
    [[ "$ISO_SIZE" -gt 700000000 ]] || fail "ISO file is unexpectedly small ($ISO_SIZE bytes)"
fi

if [[ "${1:-}" == "--host" || "${1:-}" == "--live" ]]; then
    verify_host
    exit 0
fi

if [[ "${1:-}" == "--runtime" ]]; then
    if command -v docker >/dev/null 2>&1; then
        docker run --rm --privileged -v "${SCRIPT_DIR}:/repo:ro" debian:trixie-slim bash -c '
            set -euo pipefail
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq
            apt-get install -y -qq --no-install-recommends \
                wget ca-certificates gnupg desktop-file-utils iproute2 iputils-ping procps iptables nftables >/dev/null
            echo "deb cdrom:[Debian GNU/Linux 13.7.0 _Trixie_ - Official amd64 NETINST]/ trixie main" >> /etc/apt/sources.list
            echo "debian" > /etc/hostname
            printf "127.0.0.1\tlocalhost\n127.0.1.1\tdebian.pve.laptop.local\tdebian\n" > /etc/hosts
            /repo/setup-laptop.sh --target-root /
            ! grep -q "^deb cdrom:" /etc/apt/sources.list
            grep -Fq "10.99.0.1" /etc/hosts
            grep -Fq "iface vmbr1 inet static" /etc/network/interfaces
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
    else
        RUN_PRIV=()
        if [[ "$EUID" -ne 0 ]]; then
            if sudo -n true 2>/dev/null; then
                RUN_PRIV=(sudo)
            else
                fail "Root privileges or docker required for --runtime verification"
            fi
        fi
        RUNTIME_STAGE="$(mktemp -d)"
        mkdir -p "${RUNTIME_STAGE}/etc/apt"
        echo "deb cdrom:[Debian GNU/Linux 13.7.0 _Trixie_ - Official amd64 NETINST]/ trixie main" > "${RUNTIME_STAGE}/etc/apt/sources.list"
        echo "debian" > "${RUNTIME_STAGE}/etc/hostname"
        printf "127.0.0.1\tlocalhost\n127.0.1.1\tdebian.pve.laptop.local\tdebian\n" > "${RUNTIME_STAGE}/etc/hosts"
        "${RUN_PRIV[@]}" "${SCRIPT_DIR}/setup-laptop.sh" --target-root "$RUNTIME_STAGE"
        ! grep -q "^deb cdrom:" "${RUNTIME_STAGE}/etc/apt/sources.list" || fail "Runtime stage deb cdrom not commented"
        grep -Fq "10.99.0.1" "${RUNTIME_STAGE}/etc/hosts" || fail "Runtime stage 10.99.0.1 missing in hosts"
        grep -Fq "iface vmbr1 inet static" "${RUNTIME_STAGE}/etc/network/interfaces" || fail "Runtime stage vmbr1 missing in interfaces"
        test -x "${RUNTIME_STAGE}/etc/NetworkManager/dispatcher.d/99-pve-wifi-nat" || fail "Runtime stage 99-pve-wifi-nat not executable"
        desktop-file-validate "${RUNTIME_STAGE}/usr/share/applications/proxmox-desktop.desktop" || fail "Runtime stage desktop-file-validate failed"
        [[ "$(dpkg-query -W -f='${Version}' proxmox-ve 2>/dev/null || apt-cache policy proxmox-ve)" == *9.2* ]] || fail "proxmox-ve 9.2 not available in apt cache"
        "${RUN_PRIV[@]}" unshare --net bash -c "
            set -euo pipefail
            export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
            export INTERFACES_FILE='${RUNTIME_STAGE}/etc/network/interfaces'
            export LOCK_FILE='${RUNTIME_STAGE}/pve-wifi-nat.lock'
            export STATE_FILE='${RUNTIME_STAGE}/pve-wifi-nat.state'
            ip link set lo up
            ip link add wlan0 type dummy
            ip addr add 192.0.2.1/24 dev wlan0
            ip link set wlan0 up
            ip route add default dev wlan0
            '${RUNTIME_STAGE}/usr/local/bin/pve-wifi-nat.sh'
            ip -4 addr show dev vmbr1 | grep -Fq '10.99.0.1/24'
            iptables -w 5 -t nat -S POSTROUTING | grep -Fq '10.99.0.0/24 -o wlan0 -j MASQUERADE'
            ip netns add guestvm-rt
            trap 'ip netns del guestvm-rt 2>/dev/null || true' EXIT
            ip link add veth-host type veth peer name veth-guest
            ip link set veth-host master vmbr1
            ip link set veth-host up
            ip link set veth-guest netns guestvm-rt
            ip netns exec guestvm-rt ip addr add 10.99.0.2/24 dev veth-guest
            ip netns exec guestvm-rt ip link set lo up
            ip netns exec guestvm-rt ip link set veth-guest up
            ip netns exec guestvm-rt ip route add default via 10.99.0.1
            ip netns exec guestvm-rt ping -c 2 -W 3 10.99.0.1 >/dev/null
            ip netns exec guestvm-rt ping -c 2 -W 3 192.0.2.1 >/dev/null
        " || { "${RUN_PRIV[@]}" rm -rf "$RUNTIME_STAGE"; fail "Isolated netns runtime verification failed"; }
        "${RUN_PRIV[@]}" rm -rf "$RUNTIME_STAGE"
    fi
fi

echo "PASS: All syntax, repository, overlay, dry-run, and runtime checks succeeded."
