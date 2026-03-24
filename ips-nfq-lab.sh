#!/usr/bin/env bash

set -euo pipefail

# Routed veth lab for NFQUEUE testing.
#
# Topology:
#   client(eth0: 10.200.0.2/24)
#      -> dut(lan0: 10.200.0.1/24, wan0: 10.201.0.2/24)
#      -> root namespace(wanlab0: 10.201.0.1/24)
#      -> real WAN interface
#
# Behavior:
#   - dut routes client traffic toward root
#   - dut applies NFQUEUE on forwarded traffic
#   - dut NATs client traffic out wan0
#   - root namespace NATs uplink traffic out the real WAN interface
#
# Usage:
#   ./ips-nfq-lab.sh up [--queue-bypass]
#   ./ips-nfq-lab.sh down
#   ./ips-nfq-lab.sh status
#
# Optional environment overrides:
#   WAN_IF=<iface>                     # default: auto-detect from default route
#   CLIENT_SUBNET_CIDR=10.200.0.0/24
#   CLIENT_IP_CIDR=10.200.0.2/24
#   DUT_LAN_IP_CIDR=10.200.0.1/24
#   UPLINK_SUBNET_CIDR=10.201.0.0/24
#   DUT_WAN_IP_CIDR=10.201.0.2/24
#   ROOT_IP_CIDR=10.201.0.1/24
#   LAB_MTU=1500
#   NS_CLIENT=client
#   NS_DUT=dut
#   ROOT_IF=wanlab0
#   VETH_C=eth0
#   VETH_D_IN=lan0
#   VETH_D_OUT=wan0
#   NFQ_QUEUE_NUM=0

STATE_FILE=${STATE_FILE:-/tmp/ips_nfq_lab.state}

NS_CLIENT=${NS_CLIENT:-client}
NS_DUT=${NS_DUT:-dut}

CLIENT_SUBNET_CIDR=${CLIENT_SUBNET_CIDR:-10.200.0.0/24}
CLIENT_IP_CIDR=${CLIENT_IP_CIDR:-10.200.0.2/24}
DUT_LAN_IP_CIDR=${DUT_LAN_IP_CIDR:-10.200.0.1/24}
UPLINK_SUBNET_CIDR=${UPLINK_SUBNET_CIDR:-10.201.0.0/24}
DUT_WAN_IP_CIDR=${DUT_WAN_IP_CIDR:-10.201.0.2/24}
ROOT_IP_CIDR=${ROOT_IP_CIDR:-10.201.0.1/24}
LAB_MTU=${LAB_MTU:-1500}

ROOT_IF=${ROOT_IF:-wanlab0}
VETH_C=${VETH_C:-eth0}
VETH_D_IN=${VETH_D_IN:-lan0}
VETH_D_OUT=${VETH_D_OUT:-wan0}
NFQ_QUEUE_NUM=${NFQ_QUEUE_NUM:-0}

IPT_ROOT_FWD_CHAIN=IPS_NFQ_LAB_FWD
IPT_ROOT_NAT_CHAIN=IPS_NFQ_LAB_NAT
IPT_DUT_FWD_CHAIN=IPS_NFQ_DUT_FWD
IPT_DUT_NAT_CHAIN=IPS_NFQ_DUT_NAT

usage() {
    echo "Usage: $0 up [--queue-bypass]"
    echo "       $0 down"
    echo "       $0 status"
}

need_root() {
    if [[ ${EUID} -ne 0 ]]; then
        exec sudo --preserve-env=STATE_FILE,WAN_IF,CLIENT_SUBNET_CIDR,CLIENT_IP_CIDR,DUT_LAN_IP_CIDR,UPLINK_SUBNET_CIDR,DUT_WAN_IP_CIDR,ROOT_IP_CIDR,LAB_MTU,NS_CLIENT,NS_DUT,ROOT_IF,VETH_C,VETH_D_IN,VETH_D_OUT,NFQ_QUEUE_NUM "$0" "$@"
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

namespace_exists() {
    ip netns list | awk '{print $1}' | grep -qx "$1"
}

detect_wan_if() {
    if [[ -n "${WAN_IF:-}" ]]; then
        echo "$WAN_IF"
        return
    fi

    ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "dev") { print $(i+1); exit }}'
}

ip_no_cidr() {
    echo "${1%%/*}"
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

iptables_setup_root() {
    local wan_if="$1"

    try iptables -N "$IPT_ROOT_FWD_CHAIN"
    iptables -F "$IPT_ROOT_FWD_CHAIN"
    iptables -A "$IPT_ROOT_FWD_CHAIN" -i "$ROOT_IF" -o "$wan_if" -j ACCEPT
    iptables -A "$IPT_ROOT_FWD_CHAIN" -i "$wan_if" -o "$ROOT_IF" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    iptables -C FORWARD -j "$IPT_ROOT_FWD_CHAIN" >/dev/null 2>&1 || iptables -I FORWARD 1 -j "$IPT_ROOT_FWD_CHAIN"

    try iptables -t nat -N "$IPT_ROOT_NAT_CHAIN"
    iptables -t nat -F "$IPT_ROOT_NAT_CHAIN"
    iptables -t nat -A "$IPT_ROOT_NAT_CHAIN" -s "$UPLINK_SUBNET_CIDR" -o "$wan_if" -j MASQUERADE
    iptables -t nat -C POSTROUTING -j "$IPT_ROOT_NAT_CHAIN" >/dev/null 2>&1 || iptables -t nat -I POSTROUTING 1 -j "$IPT_ROOT_NAT_CHAIN"
}

iptables_teardown_root() {
    while iptables -C FORWARD -j "$IPT_ROOT_FWD_CHAIN" >/dev/null 2>&1; do
        iptables -D FORWARD -j "$IPT_ROOT_FWD_CHAIN" || true
    done

    while iptables -t nat -C POSTROUTING -j "$IPT_ROOT_NAT_CHAIN" >/dev/null 2>&1; do
        iptables -t nat -D POSTROUTING -j "$IPT_ROOT_NAT_CHAIN" || true
    done

    try iptables -F "$IPT_ROOT_FWD_CHAIN"
    try iptables -X "$IPT_ROOT_FWD_CHAIN"
    try iptables -t nat -F "$IPT_ROOT_NAT_CHAIN"
    try iptables -t nat -X "$IPT_ROOT_NAT_CHAIN"
}

iptables_setup_dut_nat() {
    try ip netns exec "$NS_DUT" iptables -t nat -N "$IPT_DUT_NAT_CHAIN"
    ip netns exec "$NS_DUT" iptables -t nat -F "$IPT_DUT_NAT_CHAIN"
    ip netns exec "$NS_DUT" iptables -t nat -A "$IPT_DUT_NAT_CHAIN" -s "$CLIENT_SUBNET_CIDR" -o "$VETH_D_OUT" -j MASQUERADE
    ip netns exec "$NS_DUT" iptables -t nat -C POSTROUTING -j "$IPT_DUT_NAT_CHAIN" >/dev/null 2>&1 || \
        ip netns exec "$NS_DUT" iptables -t nat -I POSTROUTING 1 -j "$IPT_DUT_NAT_CHAIN"
}

iptables_setup_dut_forward_nfq() {
    local queue_bypass="$1"
    local -a nfq_args=(-j NFQUEUE --queue-num "$NFQ_QUEUE_NUM")

    if [[ "$queue_bypass" == "1" ]]; then
        nfq_args+=(--queue-bypass)
    fi

    try ip netns exec "$NS_DUT" iptables -N "$IPT_DUT_FWD_CHAIN"
    ip netns exec "$NS_DUT" iptables -F "$IPT_DUT_FWD_CHAIN"
    ip netns exec "$NS_DUT" iptables -A "$IPT_DUT_FWD_CHAIN" -i "$VETH_D_IN" -o "$VETH_D_OUT" "${nfq_args[@]}"
    ip netns exec "$NS_DUT" iptables -A "$IPT_DUT_FWD_CHAIN" -i "$VETH_D_OUT" -o "$VETH_D_IN" "${nfq_args[@]}"
    ip netns exec "$NS_DUT" iptables -C FORWARD -j "$IPT_DUT_FWD_CHAIN" >/dev/null 2>&1 || \
        ip netns exec "$NS_DUT" iptables -I FORWARD 1 -j "$IPT_DUT_FWD_CHAIN"
}

iptables_teardown_dut() {
    if ! namespace_exists "$NS_DUT"; then
        return 0
    fi

    while ip netns exec "$NS_DUT" iptables -C FORWARD -j "$IPT_DUT_FWD_CHAIN" >/dev/null 2>&1; do
        ip netns exec "$NS_DUT" iptables -D FORWARD -j "$IPT_DUT_FWD_CHAIN" || true
    done

    while ip netns exec "$NS_DUT" iptables -t nat -C POSTROUTING -j "$IPT_DUT_NAT_CHAIN" >/dev/null 2>&1; do
        ip netns exec "$NS_DUT" iptables -t nat -D POSTROUTING -j "$IPT_DUT_NAT_CHAIN" || true
    done

    try ip netns exec "$NS_DUT" iptables -F "$IPT_DUT_FWD_CHAIN"
    try ip netns exec "$NS_DUT" iptables -X "$IPT_DUT_FWD_CHAIN"
    try ip netns exec "$NS_DUT" iptables -t nat -F "$IPT_DUT_NAT_CHAIN"
    try ip netns exec "$NS_DUT" iptables -t nat -X "$IPT_DUT_NAT_CHAIN"
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
    ip -n "$NS_CLIENT" addr replace "$CLIENT_IP_CIDR" dev "$VETH_C"
    ip -n "$NS_CLIENT" route replace default via "$(ip_no_cidr "$DUT_LAN_IP_CIDR")"
    ip netns exec "$NS_CLIENT" sysctl -w net.ipv4.ping_group_range="0 2147483647" >/dev/null

    ip -n "$NS_DUT" link set "$VETH_D_IN" up
    disable_offloads "$NS_DUT" "$VETH_D_IN"
    ip -n "$NS_DUT" addr replace "$DUT_LAN_IP_CIDR" dev "$VETH_D_IN"
    ip -n "$NS_DUT" link set "$VETH_D_OUT" up
    disable_offloads "$NS_DUT" "$VETH_D_OUT"
    ip -n "$NS_DUT" addr replace "$DUT_WAN_IP_CIDR" dev "$VETH_D_OUT"
    ip -n "$NS_DUT" route replace default via "$(ip_no_cidr "$ROOT_IP_CIDR")"
    ip netns exec "$NS_DUT" sysctl -w net.ipv4.ip_forward=1 >/dev/null
    ip netns exec "$NS_DUT" sysctl -w net.ipv4.ping_group_range="0 2147483647" >/dev/null

    ip link set "$ROOT_IF" up
    ip addr replace "$ROOT_IP_CIDR" dev "$ROOT_IF"
}

do_down() {
    load_state || true

    iptables_teardown_dut
    iptables_teardown_root

    if [[ -n "${OLD_IP_FORWARD:-}" ]]; then
        sysctl -w net.ipv4.ip_forward="$OLD_IP_FORWARD" >/dev/null
    fi

    kill_ns_processes "$NS_CLIENT"
    kill_ns_processes "$NS_DUT"

    try ip link del "$ROOT_IF"
    try ip link del "$VETH_C"
    try ip link del "$VETH_D_IN"
    try ip link del "$VETH_D_OUT"

    try ip netns del "$NS_CLIENT"
    try ip netns del "$NS_DUT"

    rm -f "$STATE_FILE"

    echo "NFQ lab torn down."
}

do_up() {
    local queue_bypass="$1"
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
    iptables_setup_dut_nat
    iptables_setup_dut_forward_nfq "$queue_bypass"
    iptables_setup_root "$wan_if"
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    save_state "$wan_if" "$old_ipfwd"

    echo "NFQ lab is up."
    echo "  WAN_IF: $wan_if"
    echo "  Client namespace: $NS_CLIENT ($VETH_C: $CLIENT_IP_CIDR)"
    echo "  DUT namespace:    $NS_DUT ($VETH_D_IN: $DUT_LAN_IP_CIDR, $VETH_D_OUT: $DUT_WAN_IP_CIDR)"
    echo "  Root interface:   $ROOT_IF ($ROOT_IP_CIDR)"
    echo "  NFQUEUE:          queue $NFQ_QUEUE_NUM (queue-bypass $( [[ "$queue_bypass" == "1" ]] && echo on || echo off ))"
    echo "  DUT NAT:          $CLIENT_SUBNET_CIDR -> $VETH_D_OUT"
    echo
    echo "Quick test:"
    echo "  ./enter-client.sh"
    echo "  ping -c3 $(ip_no_cidr "$DUT_LAN_IP_CIDR")"
    echo "  curl -I https://example.com"
}

do_status() {
    echo "Namespaces:"
    ip netns list || true

    echo
    echo "Root interfaces:"
    ip -br link show "$ROOT_IF" 2>/dev/null || true
    ip -br addr show "$ROOT_IF" 2>/dev/null || true
    iptables -S "$IPT_ROOT_FWD_CHAIN" 2>/dev/null || true
    iptables -t nat -S "$IPT_ROOT_NAT_CHAIN" 2>/dev/null || true

    echo
    echo "Client namespace ($NS_CLIENT):"
    ip netns exec "$NS_CLIENT" ip -br link 2>/dev/null || true
    ip netns exec "$NS_CLIENT" ip -br addr 2>/dev/null || true
    ip netns exec "$NS_CLIENT" ip route 2>/dev/null || true

    echo
    echo "DUT namespace ($NS_DUT):"
    ip netns exec "$NS_DUT" ip -br link 2>/dev/null || true
    ip netns exec "$NS_DUT" ip -br addr 2>/dev/null || true
    ip netns exec "$NS_DUT" ip route 2>/dev/null || true
    ip netns exec "$NS_DUT" sysctl net.ipv4.ip_forward 2>/dev/null || true
    ip netns exec "$NS_DUT" iptables -S FORWARD 2>/dev/null || true
    ip netns exec "$NS_DUT" iptables -S "$IPT_DUT_FWD_CHAIN" 2>/dev/null || true
    ip netns exec "$NS_DUT" iptables -t nat -S "$IPT_DUT_NAT_CHAIN" 2>/dev/null || true
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

    local action=""
    local queue_bypass=0
    local arg

    for arg in "$@"; do
        case "$arg" in
            up|down|status)
                if [[ -n "$action" ]]; then
                    usage >&2
                    exit 1
                fi
                action="$arg"
                ;;
            --queue-bypass)
                queue_bypass=1
                ;;
            *)
                usage >&2
                exit 1
                ;;
        esac
    done

    case "$action" in
        up)
            do_up "$queue_bypass"
            ;;
        down)
            if [[ $queue_bypass -eq 1 ]]; then
                usage >&2
                exit 1
            fi
            do_down
            ;;
        status)
            if [[ $queue_bypass -eq 1 ]]; then
                usage >&2
                exit 1
            fi
            do_status
            ;;
        *)
            usage >&2
            exit 1
            ;;
    esac
}

main "$@"
