#!/usr/bin/env bash

set -euo pipefail

# Simple veth lab for AF_PACKET/inline testing.
#
# Topology:
#   ns-client(eth0) -> ns-dut(lan0, wan0) -> root namespace(wanlab0)
#   -> real WAN interface (NAT)
#
# This script does not bridge lan0 and wan0. Use br.sh or your own
# forwarder/IPS inside ns-dut.
#
# Usage:
#   ./ips-afp-lab.sh up
#   ./ips-afp-lab.sh down
#   ./ips-afp-lab.sh status
#   ./ips-afp-lab.sh shell
#
# Optional environment overrides:
#   WAN_IF=<iface>                # default: auto-detect from default route
#   LAB_SUBNET_CIDR=10.200.0.0/24
#   LAB_HOST_IP_CIDR=10.200.0.1/24
#   LAB_CLIENT_IP_CIDR=10.200.0.2/24
#   LAB_MTU=1500
#   NS_CLIENT=client
#   NS_DUT=dut
#   ROOT_IF=wanlab0
#   VETH_C=eth0
#   VETH_D_IN=lan0
#   VETH_D_OUT=wan0

STATE_FILE=${STATE_FILE:-/tmp/ips_lab.state}

NS_CLIENT=${NS_CLIENT:-client}
NS_DUT=${NS_DUT:-dut}

LAB_SUBNET_CIDR=${LAB_SUBNET_CIDR:-10.200.0.0/24}
LAB_HOST_IP_CIDR=${LAB_HOST_IP_CIDR:-10.200.0.1/24}
LAB_CLIENT_IP_CIDR=${LAB_CLIENT_IP_CIDR:-10.200.0.2/24}
LAB_MTU=${LAB_MTU:-1500}

ROOT_IF=${ROOT_IF:-wanlab0}

# veth naming
VETH_C=${VETH_C:-eth0}
VETH_D_IN=${VETH_D_IN:-lan0}
VETH_D_OUT=${VETH_D_OUT:-wan0}

IPT_FWD_CHAIN=IPS_LAB_FWD
IPT_NAT_CHAIN=IPS_LAB_NAT

usage() {
    echo "Usage: $0 {up|down|status|shell}"
}

need_root() {
    if [[ ${EUID} -ne 0 ]]; then
        exec sudo --preserve-env=STATE_FILE,WAN_IF,LAB_SUBNET_CIDR,LAB_HOST_IP_CIDR,LAB_CLIENT_IP_CIDR,LAB_MTU,NS_CLIENT,NS_DUT,ROOT_IF,VETH_C,VETH_D_IN,VETH_D_OUT "$0" "$@"
    fi
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "ERROR: missing command: $1" >&2
        exit 1
    }
}

try() {
    "$@" >/dev/null 2>&1 || true
}

disable_offloads() {
    local ns="$1"
    local iface="$2"
    local feature

    for feature in tso gro lro gso rx tx sg rxvlan txvlan; do
        try ip netns exec "$ns" ethtool -K "$iface" "$feature" off
    done
}

kill_ns_processes() {
    local ns="$1"
    if ip netns list | awk '{print $1}' | grep -qx "$ns"; then
        ip netns pids "$ns" 2>/dev/null | xargs -r kill >/dev/null 2>&1 || true
        sleep 0.1
        ip netns pids "$ns" 2>/dev/null | xargs -r kill -9 >/dev/null 2>&1 || true
    fi
}

detect_wan_if() {
    if [[ -n "${WAN_IF:-}" ]]; then
        echo "$WAN_IF"
        return
    fi

    ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "dev") { print $(i+1); exit }}'
}

client_gateway_ip() {
    echo "${LAB_HOST_IP_CIDR%%/*}"
}

save_state() {
    local wan_if="$1"
    local old_ipfwd="$2"

    cat >"$STATE_FILE" <<EOF
WAN_IF=$wan_if
OLD_IP_FORWARD=$old_ipfwd
EOF
}

load_state() {
    if [[ -f "$STATE_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$STATE_FILE"
    fi
}

iptables_setup() {
    local wan_if="$1"

    try iptables -N "$IPT_FWD_CHAIN"
    iptables -F "$IPT_FWD_CHAIN"
    iptables -A "$IPT_FWD_CHAIN" -i "$ROOT_IF" -o "$wan_if" -j ACCEPT
    iptables -A "$IPT_FWD_CHAIN" -i "$wan_if" -o "$ROOT_IF" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    iptables -C FORWARD -j "$IPT_FWD_CHAIN" >/dev/null 2>&1 || iptables -I FORWARD 1 -j "$IPT_FWD_CHAIN"

    try iptables -t nat -N "$IPT_NAT_CHAIN"
    iptables -t nat -F "$IPT_NAT_CHAIN"
    iptables -t nat -A "$IPT_NAT_CHAIN" -s "$LAB_SUBNET_CIDR" -o "$wan_if" -j MASQUERADE
    iptables -t nat -C POSTROUTING -j "$IPT_NAT_CHAIN" >/dev/null 2>&1 || iptables -t nat -I POSTROUTING 1 -j "$IPT_NAT_CHAIN"
}

iptables_teardown() {
    while iptables -C FORWARD -j "$IPT_FWD_CHAIN" >/dev/null 2>&1; do
        iptables -D FORWARD -j "$IPT_FWD_CHAIN" || true
    done

    while iptables -t nat -C POSTROUTING -j "$IPT_NAT_CHAIN" >/dev/null 2>&1; do
        iptables -t nat -D POSTROUTING -j "$IPT_NAT_CHAIN" || true
    done

    try iptables -F "$IPT_FWD_CHAIN"
    try iptables -X "$IPT_FWD_CHAIN"

    try iptables -t nat -F "$IPT_NAT_CHAIN"
    try iptables -t nat -X "$IPT_NAT_CHAIN"
}

setup_links() {
    ip netns add "$NS_CLIENT"
    ip netns add "$NS_DUT"

    ip -n "$NS_CLIENT" link set lo up
    ip -n "$NS_DUT" link set lo up

    ip link add "$VETH_C" type veth peer name "$VETH_D_IN"
    ip link add "$VETH_D_OUT" type veth peer name "$ROOT_IF"

    ip link set "$VETH_C" netns "$NS_CLIENT"
    ip link set "$VETH_D_IN" netns "$NS_DUT"
    ip link set "$VETH_D_OUT" netns "$NS_DUT"

    ip -n "$NS_CLIENT" link set "$VETH_C" mtu "$LAB_MTU"
    ip -n "$NS_DUT" link set "$VETH_D_IN" mtu "$LAB_MTU"
    ip -n "$NS_DUT" link set "$VETH_D_OUT" mtu "$LAB_MTU"
    ip link set "$ROOT_IF" mtu "$LAB_MTU"

    ip -n "$NS_CLIENT" link set "$VETH_C" up
    disable_offloads "$NS_CLIENT" "$VETH_C"
    ip -n "$NS_CLIENT" addr replace "$LAB_CLIENT_IP_CIDR" dev "$VETH_C"
    ip -n "$NS_CLIENT" route replace default via "$(client_gateway_ip)"
    ip netns exec "$NS_CLIENT" sysctl -w net.ipv4.ping_group_range="0 2147483647" >/dev/null

    ip -n "$NS_DUT" link set "$VETH_D_IN" up
    disable_offloads "$NS_DUT" "$VETH_D_IN"
    ip -n "$NS_DUT" link set "$VETH_D_OUT" up
    disable_offloads "$NS_DUT" "$VETH_D_OUT"
    ip netns exec "$NS_DUT" sysctl -w net.ipv4.ping_group_range="0 2147483647" >/dev/null

    ip link set "$ROOT_IF" up
    ip addr replace "$LAB_HOST_IP_CIDR" dev "$ROOT_IF"
}

do_down() {
    load_state || true

    iptables_teardown

    if [[ -n "${OLD_IP_FORWARD:-}" ]]; then
        sysctl -w net.ipv4.ip_forward="$OLD_IP_FORWARD" >/dev/null
    fi

    kill_ns_processes "$NS_CLIENT"
    kill_ns_processes "$NS_DUT"

    try ip link del "$ROOT_IF"
    try ip link del "$VETH_C"
    try ip link del "$VETH_D_IN"
    try ip link del "$VETH_D_OUT"

    try ip link del cpa
    try ip link del cpb
    try ip link del dia
    try ip link del dib
    try ip link del doa
    try ip link del dob
    try ip link del hoa
    try ip link del hob

    try ip netns del "$NS_CLIENT"
    try ip netns del "$NS_DUT"

    rm -f "$STATE_FILE"

    echo "Lab torn down."
}

do_up() {
    local wan_if
    local old_ipfwd

    wan_if=$(detect_wan_if)
    if [[ -z "$wan_if" ]]; then
        echo "ERROR: could not detect WAN_IF. Set WAN_IF=<iface> and retry." >&2
        exit 1
    fi

    if [[ "$wan_if" == "$ROOT_IF" ]]; then
        echo "ERROR: WAN_IF cannot be $ROOT_IF" >&2
        exit 1
    fi

    do_down >/dev/null 2>&1 || true

    old_ipfwd=$(sysctl -n net.ipv4.ip_forward)
    setup_links
    iptables_setup "$wan_if"
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    save_state "$wan_if" "$old_ipfwd"

    echo "Lab is up."
    echo "  WAN_IF: $wan_if"
    echo "  Client namespace: $NS_CLIENT ($VETH_C: $LAB_CLIENT_IP_CIDR)"
    echo "  DUT namespace:    $NS_DUT ($VETH_D_IN and $VETH_D_OUT are separate)"
    echo "  Root interface:   $ROOT_IF ($LAB_HOST_IP_CIDR)"
    echo
    echo "Use br.sh or your own forwarder/IPS between $VETH_D_IN and $VETH_D_OUT."
    echo "Quick test after enabling forwarding in ns-dut:"
    echo "  ip netns exec $NS_CLIENT ping -c3 $(client_gateway_ip)"
    echo "  ip netns exec $NS_CLIENT curl -I https://example.com"
    echo "  ip netns exec $NS_CLIENT bash"
}

do_status() {
    echo "Namespaces:"
    ip netns list || true

    echo
    echo "Root interfaces:"
    ip -br link show "$ROOT_IF" 2>/dev/null || true
    ip -br addr show "$ROOT_IF" 2>/dev/null || true

    echo
    echo "Client namespace ($NS_CLIENT):"
    ip netns exec "$NS_CLIENT" ip -br link 2>/dev/null || true
    ip netns exec "$NS_CLIENT" ip -br addr 2>/dev/null || true
    ip netns exec "$NS_CLIENT" ip route 2>/dev/null || true

    echo
    echo "DUT namespace ($NS_DUT):"
    ip netns exec "$NS_DUT" ip -br link 2>/dev/null || true
}

do_shell() {
    exec ip netns exec "$NS_CLIENT" bash
}

main() {
    need_root "$@"
    need_cmd ip
    need_cmd awk
    need_cmd grep
    need_cmd xargs
    need_cmd sysctl
    need_cmd iptables
    need_cmd ethtool

    local action="${1:-}"
    case "$action" in
        up)
            do_up
            ;;
        down)
            do_down
            ;;
        status)
            do_status
            ;;
        shell)
            do_shell
            ;;
        *)
            usage
            exit 1
            ;;
    esac
}

main "$@"
