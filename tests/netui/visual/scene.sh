#!/bin/bash

set -euo pipefail

scene=${1:-}
package_root=${NETUI_VISUAL_PACKAGE_ROOT:-${NETUI_PACKAGE_ROOT:-}}

[[ -n "$package_root" && -d "$package_root" ]] || exit 1

# shellcheck source=../../../packages/netui/lib/common.sh
source "$package_root/lib/common.sh"
# shellcheck source=../../../packages/netui/lib/paths.sh
source "$package_root/lib/paths.sh"
# shellcheck source=../../../packages/netui/lib/config_store.sh
source "$package_root/lib/config_store.sh"

netui_init_dirs

write_fixture() {
    local path=$1
    local port=$2

    cat > "$path" <<EOF
{
    "log": {"level": "info"},
    "inbounds": [{"type": "mixed", "listen": "127.0.0.1", "listen_port": $port}],
    "outbounds": [{"type": "direct"}]
}
EOF
    chmod 600 -- "$path"
}

prepare_fixture() {
    [[ -f "$NETUI_CONFIG_DIR/alpha.json" ]] || write_fixture "$NETUI_CONFIG_DIR/alpha.json" 10808
    [[ -f "$NETUI_CONFIG_DIR/beta.json" ]] || write_fixture "$NETUI_CONFIG_DIR/beta.json" 10809
    config_store_set_default "$NETUI_CONFIG_DIR/alpha.json" >/dev/null
}

if [[ "$scene" == prepare ]]; then
    prepare_fixture
    exit 0
fi

prepare_fixture
case "$scene" in
    dashboard)
        NETUI_TUI_FIXED_ROWS=24 NETUI_TUI_FIXED_COLS=108 NETUI_TUI_COLOR=always NETUI_TUI_DISABLE_ALT_SCREEN=1 \
            "$package_root/bin/netctl" netui
        ;;
    config-switch)
        NETUI_TUI_ACTIONS='default:beta.json;quit' "$package_root/bin/netctl" netui >/dev/null
        NETUI_TUI_FIXED_ROWS=24 NETUI_TUI_FIXED_COLS=108 NETUI_TUI_COLOR=always NETUI_TUI_DISABLE_ALT_SCREEN=1 \
            "$package_root/bin/netctl" netui
        ;;
    env-modes)
        NETUI_TUI_ACTIONS='env:global;quit' "$package_root/bin/netctl" netui >/dev/null
        NETUI_TUI_FIXED_ROWS=24 NETUI_TUI_FIXED_COLS=108 NETUI_TUI_COLOR=always NETUI_TUI_DISABLE_ALT_SCREEN=1 \
            "$package_root/bin/netctl" netui
        ;;
    narrow)
        NETUI_TUI_ACTIONS='env:cn-direct;quit' "$package_root/bin/netctl" netui >/dev/null
        NETUI_TUI_FIXED_ROWS=24 NETUI_TUI_FIXED_COLS=70 NETUI_TUI_COLOR=always NETUI_TUI_DISABLE_ALT_SCREEN=1 \
            "$package_root/bin/netctl" netui
        ;;
    fallback)
        NETUI_GUM="$NETUI_VISUAL_HOME/no-gum" NETUI_TUI_FALLBACK=1 COLUMNS=112 NETUI_TUI_ACTIONS='env:cn-direct;list;quit' \
            "$package_root/bin/netctl" netui
        ;;
    *)
        printf 'unknown visual scene: %s\n' "$scene" >&2
        exit 2
        ;;
esac
