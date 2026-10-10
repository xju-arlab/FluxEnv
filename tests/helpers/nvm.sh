#!/bin/bash

# State-bearing nvm fixture shared by Mac and Linux entry-point tests.
nvm() {
    local action="$1"
    shift
    local version=""
    local node_bin="$NVM_DIR/versions/node/v24.0.0/bin"
    case "$action" in
        --version) printf '0.39.7\n' ;;
        version)
            version="$1"
            if [ "$version" = default ]; then
                [ -f "$NVM_DIR/alias/default" ] || { printf 'N/A\n'; return 3; }
                version="$(cat "$NVM_DIR/alias/default")"
            fi
            [ "$version" = 24 ] && [ -x "$node_bin/node" ] || { printf 'N/A\n'; return 3; }
            printf 'v24.0.0\n' ;;
        install)
            [ "${1:-}" != -b ] || shift
            [ "${FLUXENV_TEST_FAIL_NODE:-0}" = 0 ] || return 8
            printf 'nvm install %s\n' "$1" >> "$FLUXENV_TEST_ROOT/mutations"
            mkdir -p "$node_bin"
            local tool=""
            local driver="${FLUXENV_TEST_MOCK_DRIVER:-${FLUXENV_TEST_DRIVER:-}}"
            for tool in node npm corepack; do ln -sf "$driver" "$node_bin/$tool"; done ;;
        alias)
            [ "$1" = default ] && [ "$2" = 24 ] || return 1
            printf 'nvm alias default %s\n' "$2" >> "$FLUXENV_TEST_ROOT/mutations"
            mkdir -p "$NVM_DIR/alias"
            printf '%s\n' "$2" > "$NVM_DIR/alias/default" ;;
        use)
            [ "${1:-}" != --silent ] || shift
            version="$(nvm version "$1")" || return 1
            export PATH="$node_bin:$PATH" ;;
        *) return 1 ;;
    esac
}
