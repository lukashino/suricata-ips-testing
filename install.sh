#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SOURCE="$SCRIPT_DIR/ips-lab"

usage() {
    cat <<EOF
Usage: ./install.sh

Installs ips-lab as a symlink so updates are picked up after git pull.
EOF
}

prompt_install_dir() {
    local choice
    local dir

    cat >&2 <<EOF
Where should ips-lab be installed?

  1) ~/.local/bin
  2) /usr/local/bin
  3) Somewhere else

EOF

    while true; do
        read -r -p "Choose [1-3]: " choice
        case "$choice" in
            1)
                echo "$HOME/.local/bin"
                return
                ;;
            2)
                echo "/usr/local/bin"
                return
                ;;
            3)
                while true; do
                    read -r -p "Install directory: " dir
                    dir=${dir/#\~/$HOME}
                    if [[ -n "$dir" ]]; then
                        echo "$dir"
                        return
                    fi
                    echo "Please enter a directory." >&2
                done
                ;;
            *)
                echo "Please choose 1, 2, or 3." >&2
                ;;
        esac
    done
}

confirm_replace() {
    local target="$1"
    local answer

    if [[ -L "$target" && "$(readlink "$target")" == "$SOURCE" ]]; then
        echo "Already installed: $target -> $SOURCE"
        exit 0
    fi

    if [[ -e "$target" || -L "$target" ]]; then
        read -r -p "$target already exists. Replace it? [y/N]: " answer
        case "$answer" in
            y|Y|yes|YES)
                return
                ;;
            *)
                echo "Aborted."
                exit 1
                ;;
        esac
    fi
}

install_symlink() {
    local install_dir="$1"
    local target="$install_dir/ips-lab"

    confirm_replace "$target"

    if [[ ! -d "$install_dir" ]]; then
        mkdir -p "$install_dir" 2>/dev/null || sudo mkdir -p "$install_dir"
    fi

    chmod +x "$SOURCE"

    if [[ -w "$install_dir" ]]; then
        ln -sfn "$SOURCE" "$target"
    else
        sudo ln -sfn "$SOURCE" "$target"
    fi

    echo "Installed: $target -> $SOURCE"

    case ":$PATH:" in
        *":$install_dir:"*)
            ;;
        *)
            echo
            echo "Note: $install_dir is not currently in your PATH."
            echo "Add it to your shell profile or invoke ips-lab with the full path."
            ;;
    esac
}

main() {
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        usage
        exit 0
    fi

    if [[ $# -ne 0 ]]; then
        usage >&2
        exit 1
    fi

    if [[ ! -f "$SOURCE" ]]; then
        echo "ERROR: ips-lab not found next to install.sh: $SOURCE" >&2
        exit 1
    fi

    install_symlink "$(prompt_install_dir)"
}

main "$@"
