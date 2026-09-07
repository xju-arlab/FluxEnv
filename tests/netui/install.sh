#!/bin/bash

set -euo pipefail

script_dir=$(cd -P -- "${0%/*}" && pwd -P)
repo_root=$(cd -P -- "$script_dir/../.." && pwd -P)
fixture=$(mktemp -d "${TMPDIR:-/tmp}/netui-install-test.XXXXXX")
cleanup() {
    tmux -L "${tmux_socket:-netui-install-test}" kill-server >/dev/null 2>&1 || true
    rm -rf -- "$fixture"
}
trap cleanup EXIT HUP INT TERM

tmux_socket="netui-install-${BASHPID}-${RANDOM}"
version=$(<"$repo_root/packages/netui/VERSION")
release="$fixture/netui-v${version}-linux-amd64"
mkdir -p "$release/bin" "$release/lib" "$release/share/shell" "$release/examples" "$release/licenses"

for source_file in \
    packages/netui/install.sh packages/netui/lib/install_core.sh packages/netui/VERSION \
    packages/netui/README.md packages/netui/THIRD_PARTY_NOTICES.md packages/netui/SOURCE-CODE-OFFER.md packages/netui/examples/config.example.json \
    packages/netui/bin/netctl packages/netui/lib/common.sh packages/netui/lib/paths.sh \
    packages/netui/lib/config_store.sh packages/netui/lib/config_meta.sh packages/netui/lib/share_uri.sh \
    packages/netui/lib/env_profiles.sh packages/netui/lib/runtime_tmux.sh \
    packages/netui/lib/shell_integration.sh packages/netui/lib/tui.sh \
    packages/netui/lib/tui_terminal.sh packages/netui/lib/tui_render.sh \
    packages/netui/share/shell/init.sh; do
    target="$release/${source_file#packages/netui/}"
    mkdir -p "${target%/*}"
    cp -- "$repo_root/$source_file" "$target"
done

cp -- "$repo_root/LICENSE" "$release/licenses/NETUI-LICENSE"
cp -- "$repo_root/LICENSE" "$release/licenses/sing-box-LICENSE"
cp -- "$repo_root/LICENSE" "$release/licenses/gum-LICENSE"

cat > "$release/bin/sing-box" <<'EOF'
#!/bin/bash

case "${1-}" in
    version)
        printf 'sing-box 1.13.18\n'
        ;;
    check)
        [[ "${2-}" == -c && -n "${3-}" ]] || exit 2
        jq empty "$3" >/dev/null
        ;;
    run)
        trap 'exit 0' TERM INT
        while :; do sleep 0.1; done
        ;;
    *)
        exit 2
        ;;
esac
EOF
cat > "$release/bin/gum" <<'EOF'
#!/bin/bash
printf 'gum 2.0.0\n'
EOF
chmod 755 "$release/bin/sing-box" "$release/bin/gum" "$release/install.sh" \
    "$release/bin/netctl" "$release/lib"/*.sh "$release/share/shell/init.sh"

cat > "$release/manifest.json" <<EOF
{"schema":1,"project":"netui","version":"$version","os":"linux","arch":"amd64","assets":[{"name":"sing-box","version":"1.13.18","sha256":"0000000000000000000000000000000000000000000000000000000000000000"},{"name":"gum","version":"2.0.0","sha256":"1111111111111111111111111111111111111111111111111111111111111111"}]}
EOF

home="$fixture/home"
mkdir -p "$home"
HOME="$home" XDG_CONFIG_HOME="$home/.config" XDG_DATA_HOME="$home/.local/share" \
    XDG_STATE_HOME="$home/.local/state" bash "$release/install.sh" --from-release

current="$home/.local/share/netui/current"
[[ -L "$current" ]]
[[ "$(readlink -- "$current")" == "releases/$version" ]]
for command_name in netup netdown netui; do
    [[ -L "$home/.local/bin/$command_name" ]]
    [[ "$(readlink -- "$home/.local/bin/$command_name")" == "$current/bin/netctl" ]]
done
[[ "$(stat -c '%a' -- "$home/.config/netui")" == 700 ]]
[[ "$(stat -c '%a' -- "$home/.local/state/netui")" == 700 ]]
[[ "$(cat "$home/.config/netui/env-mode")" == cn-direct ]]
for rc_file in "$home/.bashrc" "$home/.zshenv" "$home/.zshrc"; do
    [[ "$(head -n 1 "$rc_file")" == '# >>> netui shell integration >>>' ]]
done

config="$home/.config/netui/configs/example.json"
mkdir -p "${config%/*}"
cat > "$config" <<'EOF'
{"inbounds":[{"type":"mixed","listen":"127.0.0.1","listen_port":10808}],"outbounds":[{"type":"direct"}]}
EOF
chmod 600 "$config"
HOME="$home" XDG_CONFIG_HOME="$home/.config" XDG_DATA_HOME="$home/.local/share" \
    XDG_STATE_HOME="$home/.local/state" NETUI_PACKAGE_ROOT="$current" \
    bash -c 'source "$NETUI_PACKAGE_ROOT/lib/common.sh"; source "$NETUI_PACKAGE_ROOT/lib/paths.sh"; source "$NETUI_PACKAGE_ROOT/lib/config_store.sh"; netui_init_dirs; config_store_set_default "$NETUI_CONFIG_DIR/example.json"'
HOME="$home" XDG_CONFIG_HOME="$home/.config" XDG_DATA_HOME="$home/.local/share" \
    XDG_STATE_HOME="$home/.local/state" NETUI_TMUX_SOCKET="$tmux_socket" \
    "$home/.local/bin/netup"
HOME="$home" XDG_CONFIG_HOME="$home/.config" XDG_DATA_HOME="$home/.local/share" \
    XDG_STATE_HOME="$home/.local/state" NETUI_TMUX_SOCKET="$tmux_socket" \
    "$home/.local/bin/netdown"

HOME="$home" XDG_CONFIG_HOME="$home/.config" XDG_DATA_HOME="$home/.local/share" \
    XDG_STATE_HOME="$home/.local/state" bash "$home/.local/share/netui/current/install.sh" --from-release
[[ -L "$current" ]]
[[ "$(grep -Fc '# >>> netui shell integration >>>' "$home/.bashrc")" == 1 ]]

HOME="$home" XDG_CONFIG_HOME="$home/.config" XDG_DATA_HOME="$home/.local/share" \
    XDG_STATE_HOME="$home/.local/state" bash "$home/.local/share/netui/current/install.sh" --uninstall --yes
[[ ! -e "$home/.local/share/netui/current" ]]
[[ -f "$config" ]]

printf 'NetUI install checks passed\n'
