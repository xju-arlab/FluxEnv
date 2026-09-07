#!/bin/bash

set -u

script_dir=$(cd -P -- "${0%/*}" && pwd -P)
repo_root=$(cd -P -- "$script_dir/../.." && pwd -P)
test_home=$(mktemp -d "${TMPDIR:-/tmp}/netui-test.XXXXXX")
tmux_socket="netui-test-${BASHPID}-${RANDOM}"
fake_sing_box="$test_home/fake-sing-box"
fake_env_file="$test_home/fake-env.txt"
test_bin="$test_home/bin"

failures=0
checks=0

cleanup() {
    tmux -L "$tmux_socket" kill-server >/dev/null 2>&1 || true
    rm -rf -- "$test_home"
}
trap cleanup EXIT

export HOME="$test_home"
export XDG_CONFIG_HOME="$test_home/config-home"
export XDG_DATA_HOME="$test_home/data-home"
export XDG_STATE_HOME="$test_home/state-home"
export NETUI_SING_BOX="$fake_sing_box"
export NETUI_TMUX_SOCKET="$tmux_socket"
export NETUI_PACKAGE_ROOT="$repo_root/packages/netui"
export NETUI_SHELL_INIT_PATH="$repo_root/packages/netui/share/shell/init.sh"
unset TMUX || true

mkdir -p -- "$test_bin"
ln -s -- "$repo_root/packages/netui/bin/netctl" "$test_bin/netup"
ln -s -- "$repo_root/packages/netui/bin/netctl" "$test_bin/netdown"
ln -s -- "$repo_root/packages/netui/bin/netctl" "$test_bin/netui"

cat > "$fake_sing_box" <<'EOF'
#!/bin/bash

set -u

command_name=${1-}
if [[ "$command_name" == check ]]; then
    [[ "${2-}" == -c && -n "${3-}" ]] || exit 2
    config_path=$3
    jq empty "$config_path" >/dev/null 2>&1 || exit 1
    if jq -e '.netui_test_check_fail == true' "$config_path" >/dev/null 2>&1; then
        exit 1
    fi
    exit 0
fi

if [[ "$command_name" == run ]]; then
    [[ "${2-}" == -c && -n "${3-}" ]] || exit 2
    : > "${FAKE_ENV_FILE:?}"
    for variable_name in http_proxy HTTP_PROXY https_proxy HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY; do
        if [[ -n "${!variable_name+x}" ]]; then
            printf '%s=%s\n' "$variable_name" "${!variable_name}" >> "$FAKE_ENV_FILE"
        fi
    done
    trap 'exit 0' TERM INT
    while :; do
        sleep 0.1
    done
fi

exit 2
EOF
chmod 700 -- "$fake_sing_box"
export FAKE_ENV_FILE="$fake_env_file"

# shellcheck source=../../packages/netui/lib/common.sh
source "$repo_root/packages/netui/lib/common.sh"
# shellcheck source=../../packages/netui/lib/paths.sh
source "$repo_root/packages/netui/lib/paths.sh"
# shellcheck source=../../packages/netui/lib/config_store.sh
source "$repo_root/packages/netui/lib/config_store.sh"
# shellcheck source=../../packages/netui/lib/config_meta.sh
source "$repo_root/packages/netui/lib/config_meta.sh"
# shellcheck source=../../packages/netui/lib/share_uri.sh
source "$repo_root/packages/netui/lib/share_uri.sh"
# shellcheck source=../../packages/netui/lib/env_profiles.sh
source "$repo_root/packages/netui/lib/env_profiles.sh"
# shellcheck source=../../packages/netui/lib/runtime_tmux.sh
source "$repo_root/packages/netui/lib/runtime_tmux.sh"
# shellcheck source=../../packages/netui/lib/shell_integration.sh
source "$repo_root/packages/netui/lib/shell_integration.sh"
# shellcheck source=../../packages/netui/lib/tui.sh
source "$repo_root/packages/netui/lib/tui.sh"
# shellcheck source=../../packages/netui/lib/tui_terminal.sh
source "$repo_root/packages/netui/lib/tui_terminal.sh"
# shellcheck source=../../packages/netui/lib/tui_render.sh
source "$repo_root/packages/netui/lib/tui_render.sh"

netui_init_dirs
config_dir=$NETUI_CONFIG_DIR

assert_status() {
    local expected=$1
    local label=$2
    shift 2
    local actual=0

    checks=$((checks + 1))
    "$@"
    actual=$?
    if ((actual != expected)); then
        printf 'FAIL: %s (expected %s, got %s)\n' "$label" "$expected" "$actual" >&2
        failures=$((failures + 1))
    else
        printf 'ok: %s\n' "$label"
    fi
}

assert_true() {
    local label=$1
    shift

    checks=$((checks + 1))
    if "$@"; then
        printf 'ok: %s\n' "$label"
    else
        printf 'FAIL: %s\n' "$label" >&2
        failures=$((failures + 1))
    fi
}

frame_geometry_matches() {
    local path=$1
    local expected_lines=$2
    local expected_width=$3
    local line=''
    local line_count=0
    local line_width=0

    while IFS= read -r line || [[ -n "$line" ]]; do
        line_count=$((line_count + 1))
        line_width=$(tui_terminal_cell_width "$line")
        ((line_width == expected_width)) || return 1
    done < "$path"
    ((line_count == expected_lines))
}

tui_idle_redraw_stable() (
    local read_count=0
    local render_count=0

    tui_v2_model_refresh() { :; }
    tui_terminal_enter() { tui_terminal_active=1; }
    tui_terminal_restore() { tui_terminal_active=0; }
    tui_terminal_get_size() { printf '24|80'; }
    tui_v2_render_frame() {
        render_count=$((render_count + 1))
        tui_v2_last_size='24|80'
    }
    tui_terminal_read_key() {
        read_count=$((read_count + 1))
        if ((read_count < 5)); then
            return 1
        fi
        tui_terminal_key=QUIT
        return 0
    }
    tui_v2_dispatch_key() {
        tui_v2_running=0
    }

    tui_v2_run || return 1
    ((render_count == 1))
)

capture_idle_tui() {
    local output_path=$1
    local command=''

    printf -v command 'env HOME=%q XDG_CONFIG_HOME=%q XDG_DATA_HOME=%q XDG_STATE_HOME=%q NETUI_SING_BOX=%q NETUI_TMUX_SOCKET=%q NETUI_TUI_FIXED_ROWS=24 NETUI_TUI_FIXED_COLS=100 NETUI_TUI_COLOR=never TERM=xterm-256color %q' \
        "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$NETUI_SING_BOX" "$NETUI_TMUX_SOCKET" "$test_bin/netui"
    { sleep 1; printf q; } | script -q -E never -c "$command" "$output_path" >/dev/null 2>&1
}

idle_tui_output_is_stable() {
    local path=$1
    local frame_count=0
    local clear_count=0

    frame_count=$(LC_ALL=C grep -aFo 'CONFIGURATIONS' "$path" 2>/dev/null | wc -l)
    clear_count=$(LC_ALL=C grep -aFo $'\033[2J' "$path" 2>/dev/null | wc -l)
    ((frame_count == 1 && clear_count == 1))
}

assert_file_mode() {
    local expected=$1
    local path=$2
    local label=$3
    local actual=''

    checks=$((checks + 1))
    actual=$(stat -c '%a' -- "$path" 2>/dev/null || printf 'missing')
    if [[ "$actual" == "$expected" ]]; then
        printf 'ok: %s\n' "$label"
    else
        printf 'FAIL: %s (expected mode %s, got %s)\n' "$label" "$expected" "$actual" >&2
        failures=$((failures + 1))
    fi
}

write_valid_fixture() {
    local path=$1
    local check_fail=${2:-false}

    cat > "$path" <<EOF
{
    "log": {"level": "info"},
    "inbounds": [{"type": "mixed", "listen": "127.0.0.1", "listen_port": 10808}],
    "outbounds": [{"type": "direct"}],
    "netui_test_check_fail": $check_fail
}
EOF
    chmod 600 -- "$path"
}

replace_state_value() {
    local key=$1
    local value=$2
    local temporary_state="$NETUI_RUNTIME_DIR/.test-state.tmp"
    local current_key=''
    local current_value=''

    while IFS='=' read -r current_key current_value || [[ -n "$current_key" ]]; do
        if [[ "$current_key" == "$key" ]]; then
            printf '%s=%s\n' "$current_key" "$value"
        else
            printf '%s=%s\n' "$current_key" "$current_value"
        fi
    done < "$NETUI_RUNTIME_STATE" > "$temporary_state"
    chmod 600 -- "$temporary_state"
    mv -Tf -- "$temporary_state" "$NETUI_RUNTIME_STATE"
}

run_clean_bash_hook() {
    env -u http_proxy -u HTTP_PROXY -u https_proxy -u HTTPS_PROXY -u all_proxy -u ALL_PROXY -u no_proxy -u NO_PROXY \
        HOME="$HOME" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" XDG_STATE_HOME="$XDG_STATE_HOME" \
        bash --noprofile --norc -c 'source "$1"; printf "%s|%s|%s|%s|%s|%s|%s|%s\\n" "${http_proxy-}" "${HTTP_PROXY-}" "${https_proxy-}" "${HTTPS_PROXY-}" "${all_proxy-}" "${ALL_PROXY-}" "${no_proxy-}" "${NETUI_ENV_OWNED-}"' -- "$NETUI_SHELL_INIT_PATH"
}

run_clean_zsh_hook() {
    env -u http_proxy -u HTTP_PROXY -u https_proxy -u HTTPS_PROXY -u all_proxy -u ALL_PROXY -u no_proxy -u NO_PROXY \
        HOME="$HOME" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" XDG_STATE_HOME="$XDG_STATE_HOME" NETUI_TMUX_SOCKET="$NETUI_TMUX_SOCKET" \
        zsh -f -c 'source "$1"; print -r -- "${http_proxy-}|${HTTP_PROXY-}|${https_proxy-}|${HTTPS_PROXY-}|${all_proxy-}|${ALL_PROXY-}|${no_proxy-}|${NETUI_ENV_OWNED-}"' -- "$NETUI_SHELL_INIT_PATH"
}

alpha_config="$config_dir/alpha.json"
unicode_config="$config_dir/中文 配置.json"
bad_config="$config_dir/bad.json"
check_fail_config="$config_dir/check-fail.json"
outside_config="$test_home/outside.json"

write_valid_fixture "$alpha_config"
write_valid_fixture "$unicode_config"
printf '{not valid json\n' > "$bad_config"
chmod 644 -- "$bad_config"
write_valid_fixture "$check_fail_config" true
write_valid_fixture "$outside_config"
mkdir -p -- "$config_dir/directory.json"
mkfifo -- "$config_dir/pipe.json"
ln -s -- "$outside_config" "$config_dir/escape-link.json"

found_names=''
found_names=$(config_store_discover_names)
assert_true 'discovery includes ordinary alpha.json' grep -Fqx -- 'alpha.json' <<< "$found_names"
assert_true 'discovery includes Unicode filename' grep -Fqx -- '中文 配置.json' <<< "$found_names"
assert_true 'discovery excludes symlink' bash -c '! grep -Fqx -- "escape-link.json" <<< "$1"' -- "$found_names"
assert_true 'discovery excludes directory and FIFO' bash -c '! grep -Eq "^(directory|pipe)\\.json$" <<< "$1"' -- "$found_names"
assert_file_mode 600 "$alpha_config" 'discovery tightens config mode'
assert_file_mode 600 "$bad_config" 'discovery tightens bad config mode'

assert_status 0 'set default atomically' config_store_set_default "$alpha_config"
assert_true 'default is a symlink' test -L "$NETUI_DEFAULT_LINK"
assert_true 'default symlink is relative' bash -c '[[ "$(readlink -- "$1")" == configs/alpha.json ]]' -- "$NETUI_DEFAULT_LINK"
resolved_default=$(config_store_resolve_default)
assert_true 'default resolves inside configs' test "$resolved_default" = "$alpha_config"
assert_true 'atomic update leaves no temporary link' bash -c '! compgen -G "$1/.default.json.tmp.*" >/dev/null' -- "$NETUI_CONFIG_HOME"

assert_status 5 'reject absolute default selection outside configs' config_store_set_default "$outside_config"
assert_status 5 'reject path traversal selection' config_store_set_default "$config_dir/../outside.json"
assert_status 5 'reject config symlink selection' config_store_set_default "$config_dir/escape-link.json"
rm -f -- "$NETUI_DEFAULT_LINK"
ln -s -- ../outside.json "$NETUI_DEFAULT_LINK"
assert_status 5 'reject escaping default symlink' config_store_resolve_default
assert_status 0 'restore valid default after escape test' config_store_set_default "$unicode_config"
assert_status 5 'reject malformed JSON' config_store_set_default "$bad_config"
assert_status 5 'reject sing-box check failure' config_store_set_default "$check_fail_config"
assert_status 0 'restore alpha as default' config_store_set_default "$alpha_config"

rm -f -- "$NETUI_DEFAULT_LINK"
assert_status 4 'netup without default exits 4' "$test_bin/netup"
assert_status 2 'netup rejects positional configuration' "$test_bin/netup" alpha.json
assert_status 2 'netui rejects non-interactive stdin/stdout' "$test_bin/netui"
assert_true 'netui reports interactive terminal requirement' bash -c '"$1" 2>&1 | grep -Fq "interactive terminal"' -- "$test_bin/netui"
assert_status 0 'restore default before runtime tests' config_store_set_default "$alpha_config"

for variable_name in http_proxy HTTP_PROXY https_proxy HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY; do
    export "$variable_name=sentinel-$variable_name"
done

: > "$fake_env_file"
assert_status 0 'netup starts default config' "$test_bin/netup"
assert_true 'fake sing-box did not inherit proxy variables' test ! -s "$fake_env_file"
assert_true 'runtime state was written' test -f "$NETUI_RUNTIME_STATE"
assert_true 'tmux session exists after netup' tmux -L "$tmux_socket" has-session -t netui
runtime_state_load
managed_token=$runtime_token
managed_pid=$runtime_pane_pid
assert_true 'runtime state records selected config' test "$runtime_config_basename" = alpha.json
assert_true 'runtime state records absolute core path' test "$runtime_core_path" = "$(realpath -e -- "$fake_sing_box")"

assert_status 0 'duplicate netup is idempotent' "$test_bin/netup"
pane_count=$(tmux -L "$tmux_socket" list-panes -t netui 2>/dev/null | wc -l)
assert_true 'duplicate netup keeps one pane' test "$pane_count" -eq 1
runtime_state_load
assert_true 'duplicate netup keeps the same token' test "$runtime_token" = "$managed_token"
assert_true 'duplicate netup keeps the same PID' test "$runtime_pane_pid" = "$managed_pid"
assert_status 0 'netdown stops managed instance' "$test_bin/netdown"
assert_true 'managed session is gone after netdown' bash -c '! tmux -L "$1" has-session -t netui 2>/dev/null' -- "$tmux_socket"

# A same-name session without NetUI markers must never be touched.
tmux -L "$tmux_socket" new-session -d -s netui -- sleep 30
foreign_pid=$(tmux -L "$tmux_socket" display-message -p -t netui '#{pane_pid}')
assert_status 6 'netup rejects same-name foreign session' "$test_bin/netup"
foreign_pid_after=$(tmux -L "$tmux_socket" display-message -p -t netui '#{pane_pid}')
assert_true 'foreign session survives netup refusal' test "$foreign_pid_after" = "$foreign_pid"
assert_status 6 'netdown rejects same-name foreign session' "$test_bin/netdown"
assert_true 'foreign session survives netdown refusal' tmux -L "$tmux_socket" has-session -t netui
tmux -L "$tmux_socket" kill-session -t netui

assert_status 0 'restart managed instance for identity tests' "$test_bin/netup"
cp -- "$NETUI_RUNTIME_STATE" "$test_home/instance.state.backup"

cp -- "$test_home/instance.state.backup" "$NETUI_RUNTIME_STATE"
replace_state_value runtime_token deadbeef
assert_status 6 'token mismatch refuses stop' "$test_bin/netdown"
assert_true 'token mismatch leaves session alive' tmux -L "$tmux_socket" has-session -t netui

cp -- "$test_home/instance.state.backup" "$NETUI_RUNTIME_STATE"
replace_state_value pane_pid 999999
assert_status 6 'PID mismatch refuses stop' "$test_bin/netdown"
assert_true 'PID mismatch leaves session alive' tmux -L "$tmux_socket" has-session -t netui

cp -- "$test_home/instance.state.backup" "$NETUI_RUNTIME_STATE"
replace_state_value process_starttime 0
assert_status 6 'starttime mismatch refuses stop' "$test_bin/netdown"
assert_true 'starttime mismatch leaves session alive' tmux -L "$tmux_socket" has-session -t netui

cp -- "$test_home/instance.state.backup" "$NETUI_RUNTIME_STATE"
replace_state_value core_path /tmp/not-the-netui-core
assert_status 6 'core path mismatch refuses stop' "$test_bin/netdown"
assert_true 'core path mismatch leaves session alive' tmux -L "$tmux_socket" has-session -t netui

cp -- "$test_home/instance.state.backup" "$NETUI_RUNTIME_STATE"
assert_status 0 'verified identity permits stop' "$test_bin/netdown"

assert_status 0 'start instance for stale-state cleanup' "$test_bin/netup"
assert_true 'stale-state fixture has a session' tmux -L "$tmux_socket" has-session -t netui
tmux -L "$tmux_socket" kill-session -t netui
assert_true 'stale-state fixture leaves state behind' test -f "$NETUI_RUNTIME_STATE"
assert_status 0 'netdown cleans stale state without a session' "$test_bin/netdown"
assert_true 'stale runtime state is removed' bash -c '[[ ! -e "$1" && ! -L "$1" ]]' -- "$NETUI_RUNTIME_STATE"
assert_true 'stale endpoint state is removed' bash -c '[[ ! -e "$1" && ! -L "$1" ]]' -- "$NETUI_PROXY_ENDPOINT"
assert_status 0 'netdown remains idempotent after stale cleanup' "$test_bin/netdown"

# Phase-two runtime identity and endpoint selection.
endpoint_config="$config_dir/endpoint-order.json"
cat > "$endpoint_config" <<'EOF'
{
    "inbounds": [
        {"type": "dns", "listen": "0.0.0.0", "listen_port": 53},
        {"type": "mixed", "listen": "127.0.0.1", "listen_port": 10808}
    ],
    "outbounds": [{"type": "direct"}]
}
EOF
chmod 600 -- "$endpoint_config"
assert_status 0 'set endpoint-order fixture as default' config_store_set_default "$endpoint_config"
assert_status 0 'start endpoint-order fixture' "$test_bin/netup"
assert_true 'endpoint selection chooses loopback proxy inbound' grep -Fqx -- 'mixed|127.0.0.1|10808' "$NETUI_PROXY_ENDPOINT"
assert_status 0 'stop endpoint-order fixture' "$test_bin/netdown"
assert_status 0 'restore alpha after endpoint test' config_store_set_default "$alpha_config"
socks_config="$config_dir/socks-only.json"
cat > "$socks_config" <<'EOF'
{
    "inbounds": [{"type": "socks", "listen": "127.0.0.1", "listen_port": 10811}],
    "outbounds": [{"type": "direct"}]
}
EOF
chmod 600 -- "$socks_config"
assert_status 0 'set socks-only fixture as default' config_store_set_default "$socks_config"
assert_status 0 'start socks-only fixture' "$test_bin/netup"
assert_status 0 'enable global profile for socks-only fixture' env_profiles_set_mode global
assert_true 'socks-only hook does not invent HTTP proxies' bash -c '[[ "$1" == "||||socks5h://127.0.0.1:10811|socks5h://127.0.0.1:10811|localhost,127.0.0.1,::1|1" ]]' -- "$(run_clean_bash_hook)"
assert_status 0 'stop socks-only fixture' "$test_bin/netdown"
assert_status 0 'restore alpha after socks test' config_store_set_default "$alpha_config"
env_profiles_set_mode cn-direct >/dev/null

assert_status 0 'start instance for running rename test' "$test_bin/netup"
assert_status 0 'rename running configuration without stopping it' config_store_rename "$alpha_config" alpha-running.json
runtime_state_load
assert_true 'running snapshot display basename follows rename' test "$runtime_config_basename" = alpha-running.json
assert_status 0 'change default away from renamed running configuration' config_store_set_default "$unicode_config"
assert_status 6 'archive refuses renamed running configuration' config_store_archive "$config_dir/alpha-running.json"
assert_status 0 'stop renamed running configuration' "$test_bin/netdown"
assert_status 0 'rename configuration back after runtime test' config_store_rename "$config_dir/alpha-running.json" alpha.json
assert_status 0 'restore alpha default after rename test' config_store_set_default "$alpha_config"

# Phase-two environment profiles and shell synchronization.
assert_status 0 'persist global environment mode' env_profiles_set_mode global
assert_file_mode 600 "$NETUI_ENV_MODE_FILE" 'environment mode is private'
assert_true 'global mode is persisted' test "$(env_profiles_get_mode)" = global
assert_true 'global no_proxy is loopback-only' test "$(env_profiles_global_no_proxy)" = 'localhost,127.0.0.1,::1'

: > "$fake_env_file"
assert_status 0 'netup applies persisted environment profile' "$test_bin/netup"
global_env=$(tmux -L "$tmux_socket" show-environment -g 2>/dev/null || true)
assert_true 'tmux global environment has HTTP proxy' grep -Fqx -- 'http_proxy=http://127.0.0.1:10808' <<< "$global_env"
assert_true 'tmux global environment has ALL proxy' grep -Fqx -- 'ALL_PROXY=socks5h://127.0.0.1:10808' <<< "$global_env"
assert_true 'bash hook applies global profile' bash -c '[[ "$1" == "http://127.0.0.1:10808|http://127.0.0.1:10808|http://127.0.0.1:10808|http://127.0.0.1:10808|socks5h://127.0.0.1:10808|socks5h://127.0.0.1:10808|localhost,127.0.0.1,::1|1" ]]' -- "$(run_clean_bash_hook)"
assert_true 'zsh hook applies global profile' bash -c '[[ "$1" == "http://127.0.0.1:10808|http://127.0.0.1:10808|http://127.0.0.1:10808|http://127.0.0.1:10808|socks5h://127.0.0.1:10808|socks5h://127.0.0.1:10808|localhost,127.0.0.1,::1|1" ]]' -- "$(run_clean_zsh_hook)"

tmux -L "$tmux_socket" kill-session -t netui
stale_hook_output=$(env -u http_proxy -u HTTP_PROXY -u https_proxy -u HTTPS_PROXY -u all_proxy -u ALL_PROXY -u no_proxy -u NO_PROXY \
    HOME="$HOME" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" XDG_STATE_HOME="$XDG_STATE_HOME" NETUI_TMUX_SOCKET="$tmux_socket" \
    NETUI_ENV_OWNED=1 http_proxy=stale HTTP_PROXY=stale bash --noprofile --norc -c 'source "$1"; printf "%s|%s|%s|%s|%s|%s|%s|%s\\n" "${http_proxy-}" "${HTTP_PROXY-}" "${https_proxy-}" "${HTTPS_PROXY-}" "${all_proxy-}" "${ALL_PROXY-}" "${no_proxy-}" "${NETUI_ENV_OWNED-}"' -- "$NETUI_SHELL_INIT_PATH")
assert_true 'shell hook clears variables after unexpected tmux loss' test "$stale_hook_output" = '|||||||'
assert_status 0 'clean unexpected runtime loss' "$test_bin/netdown"
assert_status 0 'restart after unexpected runtime loss' "$test_bin/netup"

assert_status 0 'persist cn-direct environment mode' env_profiles_set_mode cn-direct
cn_no_proxy=$(env_profiles_cn_no_proxy)
cn_no_proxy_bytes=$(env_profiles_no_proxy_bytes "$cn_no_proxy")
assert_true 'cn-direct no_proxy stays within 512 bytes' test "$cn_no_proxy_bytes" -le 512
assert_true 'cn-direct no_proxy has no whitespace' bash -c '[[ "$1" != *[[:space:]]* && "$1" != *$"\\n"* ]]' -- "$cn_no_proxy"
assert_true 'cn-direct includes required suffixes' bash -c '[[ "$1" == *".cn"* && "$1" == *".huaweicloud.com"* && "$1" == *".aliyun.com"* && "$1" == *".cloud.tencent.com"* && "$1" == *".npmmirror.com"* ]]' -- "$cn_no_proxy"
assert_true 'bash hook applies cn-direct profile' bash -c '[[ "$1" == *".cn"* && "$1" == *"|1" ]]' -- "$(run_clean_bash_hook)"

assert_status 2 'off is no longer a selectable environment mode' env_profiles_set_mode off
assert_status 0 'stop profile-backed instance' "$test_bin/netdown"
off_hook_output=$(env -u http_proxy -u HTTP_PROXY -u https_proxy -u HTTPS_PROXY -u all_proxy -u ALL_PROXY -u no_proxy -u NO_PROXY \
    HOME="$HOME" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" XDG_STATE_HOME="$XDG_STATE_HOME" \
    NETUI_ENV_OWNED=1 http_proxy=owned HTTP_PROXY=owned bash --noprofile --norc -c 'source "$1"; printf "%s|%s|%s|%s|%s|%s|%s|%s\\n" "${http_proxy-}" "${HTTP_PROXY-}" "${https_proxy-}" "${HTTPS_PROXY-}" "${all_proxy-}" "${ALL_PROXY-}" "${no_proxy-}" "${NETUI_ENV_OWNED-}"' -- "$NETUI_SHELL_INIT_PATH")
assert_true 'netdown clears owned shell variables' test "$off_hook_output" = '|||||||'
assert_true 'environment preference survives netdown' test "$(env_profiles_get_mode)" = cn-direct
manual_hook_output=$(env -u http_proxy -u HTTP_PROXY -u https_proxy -u HTTPS_PROXY -u all_proxy -u ALL_PROXY -u no_proxy -u NO_PROXY \
    HOME="$HOME" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" XDG_STATE_HOME="$XDG_STATE_HOME" \
    http_proxy=manual HTTP_PROXY=manual bash --noprofile --norc -c 'source "$1"; printf "%s|%s|%s|%s\\n" "${http_proxy-}" "${HTTP_PROXY-}" "${all_proxy-}" "${NETUI_ENV_OWNED-}"' -- "$NETUI_SHELL_INIT_PATH")
assert_true 'stopped runtime preserves unowned shell variables' test "$manual_hook_output" = 'manual|manual||'
user_tmux_socket="netui-user-env-${BASHPID}-${RANDOM}"
tmux -L "$user_tmux_socket" new-session -d -s user-env -- sleep 30
NETUI_TMUX_SOCKET="$user_tmux_socket"
tmux -L "$user_tmux_socket" set-environment -g http_proxy manual-tmux
assert_status 0 'stopped runtime leaves unowned tmux environment alone' env_profiles_set_mode cn-direct
user_tmux_env=$(tmux -L "$user_tmux_socket" show-environment -g 2>/dev/null || true)
assert_true 'unowned tmux proxy survives stopped runtime' grep -Fqx -- 'http_proxy=manual-tmux' <<< "$user_tmux_env"
tmux -L "$user_tmux_socket" kill-server >/dev/null 2>&1 || true
NETUI_TMUX_SOCKET="$tmux_socket"

# Shell rc integration is precise and idempotent; it is exercised in the temp HOME only.
rm -f -- "$HOME/.bashrc" "$HOME/.zshrc"
printf '%s\n' '[[ $- == *i* ]] || return 0' > "$HOME/.bashrc"
assert_status 0 'install shell integration' shell_integration_install
assert_status 0 'reinstall shell integration idempotently' shell_integration_install
assert_true 'bashrc has one integration block' bash -c '[[ "$(grep -Fc "# >>> netui shell integration >>>" "$1")" == 1 ]]' -- "$HOME/.bashrc"
assert_true 'zshrc has one integration block' bash -c '[[ "$(grep -Fc "# >>> netui shell integration >>>" "$1")" == 1 ]]' -- "$HOME/.zshrc"
assert_true 'zshenv has one integration block' bash -c '[[ "$(grep -Fc "# >>> netui shell integration >>>" "$1")" == 1 ]]' -- "$HOME/.zshenv"
assert_true 'hook loads before the noninteractive Bash early return' bash -c 'source "$HOME/.bashrc"; declare -F netup >/dev/null'
assert_true 'noninteractive Zsh loads the command wrappers automatically' zsh -c '(( $+functions[netup] && $+functions[sudo] ))'
prompt_command_result=$(env HOME="$HOME" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" XDG_STATE_HOME="$XDG_STATE_HOME" bash --noprofile --norc -c 'PROMPT_COMMAND=existing_hook; source "$HOME/.bashrc"; printf "%s\\n" "$PROMPT_COMMAND"')
assert_true 'Bash PROMPT_COMMAND preserves existing hook' bash -c '[[ "$1" == *existing_hook* && "$1" == *__netui_apply_env* ]]' -- "$prompt_command_result"
zsh_precmd_result=$(env HOME="$HOME" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" XDG_STATE_HOME="$XDG_STATE_HOME" zsh -f -c 'precmd_functions=(existing_hook); source "$HOME/.zshrc"; print -r -- "$precmd_functions"')
assert_true 'Zsh precmd preserves existing hook' bash -c '[[ "$1" == *existing_hook* && "$1" == *__netui_apply_env* ]]' -- "$zsh_precmd_result"
assert_status 0 'remove shell integration precisely' shell_integration_remove
assert_true 'bashrc integration block removed' bash -c '! grep -Fq "# >>> netui shell integration >>>" "$1"' -- "$HOME/.bashrc"
assert_true 'zshenv integration block removed' bash -c '! grep -Fq "# >>> netui shell integration >>>" "$1"' -- "$HOME/.zshenv"
assert_true 'shell integration preserves the original rc content' grep -Fqx '[[ $- == *i* ]] || return 0' "$HOME/.bashrc"

# Exercise shell wrappers without a prompt, including sudo argv and exit status.
cat > "$test_bin/sudo" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" > "$NETUI_SUDO_CAPTURE"
printf '%s\n' "${http_proxy-}|${https_proxy-}|${all_proxy-}|${no_proxy-}" >> "$NETUI_SUDO_CAPTURE"
exit 17
EOF
chmod 700 "$test_bin/sudo"
cat > "$test_home/shell-chain.sh" <<'EOF'
source "$NETUI_SHELL_INIT_PATH"
netup >/dev/null && [[ "$http_proxy" == http://127.0.0.1:10808 && "$no_proxy" == *'.cn'* ]] || exit 1
netui env-invalid >/dev/null 2>&1
[[ $? == 2 ]] || exit 2
sudo -u root printf '%s' 'argument with spaces'
[[ $? == 17 ]] || exit 3
[[ $(head -n 1 "$NETUI_SUDO_CAPTURE") == --preserve-env=http_proxy,HTTP_PROXY,https_proxy,HTTPS_PROXY,all_proxy,ALL_PROXY,no_proxy,NO_PROXY ]] || exit 4
[[ $(sed -n '6p' "$NETUI_SUDO_CAPTURE") == 'argument with spaces' ]] || exit 5
[[ $(tail -n 1 "$NETUI_SUDO_CAPTURE") == 'http://127.0.0.1:10808|http://127.0.0.1:10808|socks5h://127.0.0.1:10808|'*'.cn'* ]] || exit 6
netdown >/dev/null && [[ -z ${http_proxy-}${https_proxy-}${all_proxy-}${NETUI_ENV_OWNED-} ]] || exit 7
sudo -n true
[[ $? == 17 ]] || exit 8
[[ $(head -n 1 "$NETUI_SUDO_CAPTURE") == -n ]] || exit 9
netup unexpected.json >/dev/null 2>&1
[[ $? == 2 && -z ${http_proxy-} ]] || exit 10
EOF
for test_shell in bash zsh; do
    assert_status 0 "$test_shell synchronizes chained commands and preserves only proxy variables for sudo" \
        env PATH="$test_bin:$PATH" NETUI_SUDO_CAPTURE="$test_home/sudo-args" "$test_shell" "$test_home/shell-chain.sh"
done
env_profiles_write_value "$NETUI_ENV_MODE_FILE" off
assert_status 0 'netup migrates the legacy off preference' "$test_bin/netup"
assert_true 'legacy off is persisted as cn-direct' grep -Fqx cn-direct "$NETUI_ENV_MODE_FILE"
assert_status 0 'stop migrated runtime' "$test_bin/netdown"

tui_v2_model_refresh
for cycle_key in CTRL_UP CTRL_DOWN; do
    assert_status 0 "$cycle_key switches cn-direct to global" tui_v2_dispatch_key "$cycle_key"
    assert_true "$cycle_key persists global" test "$(env_profiles_get_mode)" = global
    assert_status 0 "$cycle_key wraps global back to cn-direct" tui_v2_dispatch_key "$cycle_key"
    assert_true "$cycle_key persists cn-direct" test "$(env_profiles_get_mode)" = cn-direct
done

tui_incremental_render_works() (
    NETUI_TUI_FIXED_ROWS=24
    NETUI_TUI_FIXED_COLS=112
    NETUI_TUI_COLOR=never
    tui_terminal_active=1
    tui_terminal_screen_generation=1
    tui_v2_selected_index=0
    tui_v2_render_frame > "$test_home/frame-first"
    tui_v2_render_frame > "$test_home/frame-idle"
    [[ ! -s "$test_home/frame-idle" ]] || return 1
    tui_v2_dispatch_key DOWN || return 1
    tui_v2_render_frame > "$test_home/frame-move"
    [[ -s "$test_home/frame-move" ]] || return 1
    [[ $(wc -c < "$test_home/frame-move") -lt $(wc -c < "$test_home/frame-first") ]] || return 1
    tui_terminal_screen_generation=2
    tui_v2_render_frame > "$test_home/frame-reenter"
    grep -Fq $'\033[H' "$test_home/frame-reenter"
)
assert_true 'terminal emits only changed rows and repaints after reentering' tui_incremental_render_works

# Deterministic TUI actions exercise business paths and renderer invariants.
tui_list_output="$test_home/tui-list.txt"
assert_status 0 'TUI test action renders the fullscreen dashboard' bash -c 'NETUI_TUI_FIXED_ROWS=24 NETUI_TUI_FIXED_COLS=112 NETUI_TUI_COLOR=never NETUI_TUI_ACTIONS="list;quit" "$1" > "$2" 2>&1' -- "$test_bin/netui" "$tui_list_output"
assert_true 'fullscreen dashboard contains rounded border' grep -Fq '╭' "$tui_list_output"
assert_true 'fullscreen frame keeps every right border in one column' frame_geometry_matches "$tui_list_output" 24 111
assert_true 'idle event loop does not redraw unchanged frames' tui_idle_redraw_stable
assert_true 'terminal width counts CJK cells' test "$(tui_terminal_cell_width '节点')" = 4
assert_true 'terminal width remains UTF-8 safe under C locale' env LC_ALL=C bash -c 'source "$1"; [[ "$(tui_terminal_cell_width "节点")" == 4 ]]' -- "$repo_root/packages/netui/lib/tui_terminal.sh"
assert_true 'terminal width counts combining marks' test "$(tui_terminal_cell_width $'e\u0301')" = 1
assert_true 'emoji modifiers do not add terminal cells' test "$(tui_terminal_cell_width $'\U0001F3FB')" = 0
tui_v2_fit_text '节点-alpha' 12
assert_true 'renderer pads mixed-width names to exact cells' test "$(tui_terminal_cell_width "$tui_v2_fit_result")" = 12
assert_true 'renderer strips C1 controls and degrades emoji safely' test "$(tui_v2_clean_text $'ok\u009b31m\U0001F642')" = 'ok31m?'
tui_idle_output="$test_home/tui-idle.typescript"
assert_status 0 'capture a real idle PTY session' capture_idle_tui "$tui_idle_output"
assert_true 'idle PTY emits one frame and one initial clear' idle_tui_output_is_stable "$tui_idle_output"
tui_color_output="$test_home/tui-color.txt"
assert_status 0 'TUI emits the color theme when requested' env -u NO_COLOR bash -c 'NETUI_TUI_FIXED_ROWS=24 NETUI_TUI_FIXED_COLS=112 NETUI_TUI_COLOR=always NETUI_TUI_ACTIONS="list;quit" "$1" > "$2" 2>&1' -- "$test_bin/netui" "$tui_color_output"
assert_true 'color theme includes layered backgrounds' grep -Fq $'\033[1;38;5;231;48;5;24m' "$tui_color_output"
tui_no_color_output="$test_home/tui-no-color.txt"
assert_status 0 'NO_COLOR disables the requested TUI theme' bash -c 'NO_COLOR=1 NETUI_TUI_FIXED_ROWS=24 NETUI_TUI_FIXED_COLS=112 NETUI_TUI_COLOR=always NETUI_TUI_ACTIONS="list;quit" "$1" > "$2" 2>&1' -- "$test_bin/netui" "$tui_no_color_output"
assert_true 'NO_COLOR output contains no SGR sequences' bash -c '! grep -Fq "$1" "$2"' -- $'\033[' "$tui_no_color_output"
tui_narrow_output="$test_home/tui-narrow.txt"
assert_status 0 'TUI compact layout works below 70 columns' bash -c 'NETUI_TUI_FIXED_ROWS=18 NETUI_TUI_FIXED_COLS=68 NETUI_TUI_COLOR=never NETUI_TUI_ACTIONS="list;quit" "$1" > "$2" 2>&1' -- "$test_bin/netui" "$tui_narrow_output"
assert_true 'compact layout identifies itself' grep -Fq 'NetUI v' "$tui_narrow_output"
assert_true 'compact frame also keeps a continuous right border' frame_geometry_matches "$tui_narrow_output" 18 67
assert_status 0 'TUI test actions import rename and archive safely' bash -c 'NETUI_TUI_ACTIONS="import:$1:imported.json;rename:imported.json:renamed.json;archive:renamed.json;quit" "$2" >/dev/null 2>&1' -- "$outside_config" "$test_bin/netui"
assert_true 'archived configuration is absent from configs' bash -c '[[ ! -e "$1/renamed.json" && ! -L "$1/renamed.json" ]]' -- "$config_dir"
assert_true 'archived configuration is recoverable' bash -c 'find "$1" -type f -name renamed.json -print -quit | grep -q .' -- "$NETUI_CONFIG_TRASH_DIR"
archived_path=$(find "$NETUI_CONFIG_TRASH_DIR" -type f -name renamed.json -print -quit)
assert_status 0 'TUI restore action recovers archived configuration' bash -c 'NETUI_TUI_ACTIONS="restore:$1:restored.json;quit" "$2" >/dev/null 2>&1' -- "$archived_path" "$test_bin/netui"
assert_true 'restored configuration returns to configs' test -f "$config_dir/restored.json"
secret_config="$config_dir/secret.json"
cat > "$secret_config" <<'EOF'
{
    "inbounds": [{"type": "mixed", "listen": "127.0.0.1", "listen_port": 10809}],
    "outbounds": [{"type": "vless", "server": "example.invalid", "uuid": "00000000-0000-0000-0000-000000000000", "password": "supersecret", "tls": {"reality": {"enabled": true, "private_key": "private-secret"}}}]
}
EOF
chmod 600 -- "$secret_config"
tui_detail_output="$test_home/tui-detail.txt"
assert_status 0 'TUI detail action succeeds on redacted fixture' bash -c 'NETUI_TUI_ACTIONS="detail:secret.json;quit" "$1" > "$2" 2>&1' -- "$test_bin/netui" "$tui_detail_output"
assert_true 'TUI detail hides secret values' bash -c '! grep -Eq "supersecret|private-secret|00000000-0000" "$1"' -- "$tui_detail_output"

assert_status 0 'config metadata and redaction tests' bash "$script_dir/config_meta.sh"
assert_status 0 'share URI parser and atomic import tests' bash "$script_dir/uri_import.sh"

if ((failures > 0)); then
    printf '\n%s of %s checks failed\n' "$failures" "$checks" >&2
    exit 1
fi

printf '\nAll %s NetUI checks passed\n' "$checks"
