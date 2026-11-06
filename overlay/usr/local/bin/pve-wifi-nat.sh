#!/usr/bin/env bash
set -euo pipefail

VMBR="vmbr1"
SUBNET="10.99.0.0/24"
BRIDGE_IP="10.99.0.1/24"
DRY_RUN="${DRY_RUN:-0}"

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
    OUT_IFACE=$(ip route show default 2>/dev/null | awk '{print $5}' | head -n1 || true)
    OUT_IFACE="${OUT_IFACE:-wlan0}"
    run_cmd sysctl -w net.ipv4.ip_forward=1
    run_cmd ip link add name "$VMBR" type bridge
    run_cmd ip addr add "$BRIDGE_IP" dev "$VMBR"
    run_cmd ip link set dev "$VMBR" up
    run_cmd iptables -t nat -A POSTROUTING -s "$SUBNET" -o "$OUT_IFACE" -j MASQUERADE
    run_cmd nft add table ip pve_wifi_nat
    exit 0
fi

sysctl -w net.ipv4.ip_forward=1 >/dev/null

if ! ip link show "$VMBR" >/dev/null 2>&1; then
    ip link add name "$VMBR" type bridge
fi

if ! ip -4 addr show dev "$VMBR" | grep -q "$BRIDGE_IP"; then
    ip addr add "$BRIDGE_IP" dev "$VMBR"
fi

ip link set dev "$VMBR" up

OUT_IFACE=$(ip route show default | awk '{print $5}' | head -n1 || true)

if [[ -n "$OUT_IFACE" ]] && [[ "$OUT_IFACE" != "$VMBR" ]]; then
    if command -v iptables >/dev/null 2>&1; then
        iptables -t nat -C POSTROUTING -s "$SUBNET" -o "$OUT_IFACE" -j MASQUERADE 2>/dev/null || \
            iptables -t nat -A POSTROUTING -s "$SUBNET" -o "$OUT_IFACE" -j MASQUERADE
        iptables -C FORWARD -i "$VMBR" -o "$OUT_IFACE" -j ACCEPT 2>/dev/null || \
            iptables -A FORWARD -i "$VMBR" -o "$OUT_IFACE" -j ACCEPT
        iptables -C FORWARD -i "$OUT_IFACE" -o "$VMBR" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
            iptables -A FORWARD -i "$OUT_IFACE" -o "$VMBR" -m state --state RELATED,ESTABLISHED -j ACCEPT
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
