#!/usr/bin/env bash

set -euo pipefail

NS_CLIENT=${NS_CLIENT:-client}
PROMPT_LABEL=${PROMPT_LABEL:-ns}
PROMPT="[$PROMPT_LABEL:$NS_CLIENT] \u@\h:\w\\$ "

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "ERROR: missing command: $1" >&2
        exit 1
    }
}

namespace_exists() {
    ip netns list | awk '{print $1}' | grep -qx "$1"
}

enter_as_user() {
    local target_user="$1"
    local target_home
    local -a env_args

    target_home=$(getent passwd "$target_user" | awk -F: '{print $6}')
    if [[ -z "$target_home" ]]; then
        echo "ERROR: could not determine home directory for $target_user" >&2
        exit 1
    fi

    env_args=(
        "HOME=$target_home"
        "USER=$target_user"
        "LOGNAME=$target_user"
        "SHELL=/bin/bash"
        "TERM=${TERM:-xterm-256color}"
        "PATH=${PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}"
        "PS1=$PROMPT"
    )

    [[ -n "${DISPLAY:-}" ]] && env_args+=("DISPLAY=$DISPLAY")
    [[ -n "${XAUTHORITY:-}" ]] && env_args+=("XAUTHORITY=$XAUTHORITY")
    [[ -n "${WAYLAND_DISPLAY:-}" ]] && env_args+=("WAYLAND_DISPLAY=$WAYLAND_DISPLAY")
    [[ -n "${XDG_RUNTIME_DIR:-}" ]] && env_args+=("XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR")
    [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]] && env_args+=("DBUS_SESSION_BUS_ADDRESS=$DBUS_SESSION_BUS_ADDRESS")

    exec ip netns exec "$NS_CLIENT" runuser -u "$target_user" -- env "${env_args[@]}" bash --noprofile --norc -i
}

need_cmd ip
need_cmd awk
need_cmd grep
need_cmd getent
need_cmd runuser

if [[ ${EUID} -ne 0 ]]; then
    exec sudo --preserve-env=NS_CLIENT,PROMPT_LABEL,DISPLAY,XAUTHORITY,WAYLAND_DISPLAY,XDG_RUNTIME_DIR,DBUS_SESSION_BUS_ADDRESS,TERM,PATH "$0"
fi

if ! namespace_exists "$NS_CLIENT"; then
    echo "ERROR: namespace does not exist: $NS_CLIENT" >&2
    exit 1
fi

if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    enter_as_user "$SUDO_USER"
fi

exec ip netns exec "$NS_CLIENT" env "PS1=$PROMPT" bash --noprofile --norc -i
