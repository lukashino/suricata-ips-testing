#!/usr/bin/env bash

set -euo pipefail

BR_NAME=idsbr0
LAN_IF=lan0
WAN_IF=wan0

usage() {
    echo "Usage: $0 {up|down}"
}

need_root() {
    if [[ ${EUID} -ne 0 ]]; then
        exec sudo "$0" "$@"
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

link_exists() {
    ip link show dev "$1" >/dev/null 2>&1
}

current_master() {
    ip -o link show dev "$1" | awk '
        {
            for (i = 1; i <= NF; i++) {
                if ($i == "master") {
                    print $(i + 1)
                    exit
                }
            }
        }
    '
}

bridge_members() {
    ip -o link show master "$BR_NAME" | awk -F': ' '{print $2}' | awk -F'@' '{print $1}'
}

do_up() {
    local master

    if ! link_exists "$LAN_IF"; then
        echo "ERROR: interface does not exist: $LAN_IF" >&2
        exit 1
    fi

    if ! link_exists "$WAN_IF"; then
        echo "ERROR: interface does not exist: $WAN_IF" >&2
        exit 1
    fi

    if link_exists "$BR_NAME"; then
        echo "ERROR: bridge already exists: $BR_NAME" >&2
        exit 1
    fi

    master=$(current_master "$LAN_IF")
    if [[ -n "$master" ]]; then
        echo "ERROR: $LAN_IF is already attached to master $master" >&2
        exit 1
    fi

    master=$(current_master "$WAN_IF")
    if [[ -n "$master" ]]; then
        echo "ERROR: $WAN_IF is already attached to master $master" >&2
        exit 1
    fi

    ip link add name "$BR_NAME" type bridge
    ip link set dev "$BR_NAME" type bridge stp_state 0 forward_delay 0

    ip link set dev "$LAN_IF" down
    ip link set dev "$WAN_IF" down

    ip link set dev "$LAN_IF" master "$BR_NAME"
    ip link set dev "$WAN_IF" master "$BR_NAME"

    ip link set dev "$LAN_IF" up
    ip link set dev "$WAN_IF" up
    ip link set dev "$BR_NAME" up

    echo "Bridge created: $BR_NAME"
    echo "  lan: $LAN_IF"
    echo "  wan: $WAN_IF"
}

do_down() {
    local members=()
    local member

    if ! link_exists "$BR_NAME"; then
        echo "Bridge does not exist: $BR_NAME"
        return 0
    fi

    while IFS= read -r member; do
        [[ -n "$member" ]] && members+=("$member")
    done < <(bridge_members)

    try ip link set dev "$BR_NAME" down
    try ip link delete "$BR_NAME" type bridge

    for member in "${members[@]}"; do
        if link_exists "$member"; then
            try ip link set dev "$member" up
        fi
    done

    echo "Bridge removed: $BR_NAME"
}

main() {
    need_root "$@"
    need_cmd ip
    need_cmd awk

    local action="${1:-}"
    case "$action" in
        up)
            do_up
            ;;
        down)
            do_down
            ;;
        *)
            usage
            exit 1
            ;;
    esac
}

main "$@"
