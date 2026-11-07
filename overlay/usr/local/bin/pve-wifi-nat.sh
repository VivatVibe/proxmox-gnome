#!/usr/bin/env bash
set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

VMBR="vmbr1"
SUBNET="10.99.0.0/24"
BRIDGE_IP="10.99.0.1/24"
DRY_RUN="${DRY_RUN:-0}"
LOCK_FILE="${LOCK_FILE:-/run/pve-wifi-nat.lock}"
STATE_FILE="${STATE_FILE:-/run/pve-wifi-nat.state}"
INTERFACES_FILE="${INTERFACES_FILE:-/etc/network/interfaces}"

if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=1
fi

run_cmd() {
    if [[ "$DRY_RUN" == "1" ]]; then
        echo "[dry-run] $*"
    else
        "$@"
    fi
}

if [[ "$DRY_RUN" == "1" ]]; then
    OUT_IFACE=$(ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' || true)
    OUT_IFACE="${OUT_IFACE:-wlan0}"
    run_cmd sysctl -w net.ipv4.ip_forward=1
    run_cmd ip link add name "$VMBR" type bridge
    run_cmd ip addr add "$BRIDGE_IP" dev "$VMBR"
    run_cmd ip link set dev "$VMBR" up
    run_cmd iptables -w 5 -t nat -A POSTROUTING -s "$SUBNET" -o "$OUT_IFACE" -j MASQUERADE
    run_cmd nft add table ip pve_wifi_nat
    exit 0
fi

if command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCK_FILE"
    flock -w 15 9
fi

if [[ -f "$INTERFACES_FILE" && -w "$INTERFACES_FILE" ]] && ! grep -Eq "^[[:space:]]*iface[[:space:]]+${VMBR}([[:space:]]|\$)" "$INTERFACES_FILE" 2>/dev/null; then
    cat <<EOF >> "$INTERFACES_FILE"

auto ${VMBR}
iface ${VMBR} inet static
	address ${BRIDGE_IP}
	bridge-ports none
	bridge-stp off
	bridge-fd 0
EOF
fi

sysctl -w net.ipv4.ip_forward=1 >/dev/null

if ! ip link show "$VMBR" >/dev/null 2>&1; then
    ip link add name "$VMBR" type bridge 2>/dev/null || true
fi
ip link show "$VMBR" >/dev/null

if ! ip -4 addr show dev "$VMBR" | grep -Fq "$BRIDGE_IP"; then
    ip addr add "$BRIDGE_IP" dev "$VMBR" 2>/dev/null || true
fi
ip -4 addr show dev "$VMBR" | grep -Fq "$BRIDGE_IP"

ip link set dev "$VMBR" up

OUT_IFACE=$(ip route show default | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' || true)

if [[ -n "$OUT_IFACE" ]] && [[ "$OUT_IFACE" != "$VMBR" ]]; then
    if command -v iptables >/dev/null 2>&1; then
        iptables -w 5 -t nat -C POSTROUTING -s "$SUBNET" -o "$OUT_IFACE" -j MASQUERADE 2>/dev/null || \
            iptables -w 5 -t nat -A POSTROUTING -s "$SUBNET" -o "$OUT_IFACE" -j MASQUERADE
        iptables -w 5 -C FORWARD -i "$VMBR" -o "$OUT_IFACE" -j ACCEPT 2>/dev/null || \
            iptables -w 5 -A FORWARD -i "$VMBR" -o "$OUT_IFACE" -j ACCEPT
        iptables -w 5 -C FORWARD -i "$OUT_IFACE" -o "$VMBR" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
            iptables -w 5 -A FORWARD -i "$OUT_IFACE" -o "$VMBR" -m state --state RELATED,ESTABLISHED -j ACCEPT
    elif command -v nft >/dev/null 2>&1; then
        nft add table ip pve_wifi_nat
        nft flush table ip pve_wifi_nat
        nft add chain ip pve_wifi_nat postrouting '{ type nat hook postrouting priority 100; policy accept; }'
        nft add rule ip pve_wifi_nat postrouting oifname "$OUT_IFACE" ip saddr "$SUBNET" masquerade
        nft add chain ip pve_wifi_nat forward '{ type filter hook forward priority 0; policy accept; }'
        nft add rule ip pve_wifi_nat forward iifname "$VMBR" oifname "$OUT_IFACE" accept
        nft add rule ip pve_wifi_nat forward iifname "$OUT_IFACE" oifname "$VMBR" ct state related,established accept
    fi
fi

OUT_IP=""
NAT_RULE="missing"
if [[ -n "$OUT_IFACE" ]]; then
    OUT_IP=$(ip -4 -o addr show dev "$OUT_IFACE" 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}' || true)
    if [[ "$OUT_IFACE" != "$VMBR" ]]; then
        NAT_RULE="active"
    fi
fi
PREV_IP=""
if [[ -f "$STATE_FILE" ]]; then
    PREV_IP=$(awk -F= '/^OUT_IP=/{print $2; exit}' "$STATE_FILE" 2>/dev/null || true)
fi
if [[ -w "$(dirname "$STATE_FILE")" ]]; then
    cat <<EOF > "${STATE_FILE}.tmp"
OUT_IFACE=${OUT_IFACE:-}
OUT_IP=${OUT_IP:-}
LAN_URL=${OUT_IP:+https://${OUT_IP}:8006}
LOCAL_URL=https://127.0.0.1:8006
VMBR_IP=${BRIDGE_IP%/*}
NAT_RULE=${NAT_RULE}
UPDATED_AT=$(date +%s)
EOF
    mv -f "${STATE_FILE}.tmp" "$STATE_FILE"
fi

if [[ -n "$OUT_IP" && "$OUT_IP" != "$PREV_IP" ]] && command -v gdbus >/dev/null 2>&1; then
    for bus_sock in /run/user/*/bus; do
        [[ -S "$bus_sock" ]] || continue
        uid_dir="$(dirname "$bus_sock")"
        uid_num="$(basename "$uid_dir")"
        user_name="$(id -nu "$uid_num" 2>/dev/null || true)"
        [[ -n "$user_name" ]] || continue
        sudo -u "$user_name" DBUS_SESSION_BUS_ADDRESS="unix:path=${bus_sock}" \
            gdbus call --session \
            --dest org.freedesktop.Notifications \
            --object-path /org/freedesktop/Notifications \
            --method org.freedesktop.Notifications.Notify \
            "Proxmox Laptop Assistant" 0 "network-server-symbolic" \
            "Proxmox VE LAN Address (${OUT_IFACE})" \
            "Access from other devices via https://${OUT_IP}:8006" \
            "[]" "{}" 5000 >/dev/null 2>&1 || true
    done
fi
