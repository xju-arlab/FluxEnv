#!/bin/bash

# Shared-state and Linux integration checks using temporary homes/system mocks.
# No real apt, users, services, hostname changes or authentication are invoked.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/fluxenv-incremental-tests.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT
export FLUXENV_TEST_REPO="$ROOT_DIR"
export FLUXENV_TEST_USER="$(/usr/bin/id -un)"
mkdir -p "$test_root/bin"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_contains() { grep -Fq -- "$2" "$1" || { cat "$1"; fail "missing $2 in $1"; }; }

cat > "$test_root/state-case.sh" <<'STATE_CASE'
#!/bin/bash
set -euo pipefail
source "$FLUXENV_TEST_REPO/lib/core.sh"
source "$FLUXENV_TEST_REPO/lib/state.sh"
source "$FLUXENV_TEST_REPO/lib/managed.sh"
init_colors
DRY_RUN=0
[ "$1" != dry ] || DRY_RUN=1
state_open "$FLUXENV_TEST_ROOT/state" test
state_begin
case "$1" in
    fail) state_record tools/first applied; STATE_CURRENT_RESOURCE=tools/second; exit 7 ;;
    unbound) unset missing_value; broken() { : "$missing_value"; }; broken ;;
    managed|dry)
        managed_install_file "$FLUXENV_TEST_ROOT/user/config" "$FLUXENV_TEST_ROOT/candidate"
        managed_update_block "$FLUXENV_TEST_ROOT/user/rc" '# >>> test >>>' '# <<< test <<<' "$(cat "$FLUXENV_TEST_ROOT/body")"
        ;;
esac
state_finish
STATE_CASE

new_case() {
    export FLUXENV_TEST_ROOT="$test_root/$1"
    mkdir -p "$FLUXENV_TEST_ROOT/user"
}
run_state() { /bin/bash "$test_root/state-case.sh" "$@" > "$FLUXENV_TEST_ROOT/output" 2>&1; }

new_case lifecycle
if run_state fail; then fail 'failure not propagated'; fi
[ ! -e "$FLUXENV_TEST_ROOT/state/initialized" ] && [ ! -d "$FLUXENV_TEST_ROOT/state/lock" ] || fail 'failed lifecycle marker/lock'
assert_contains "$FLUXENV_TEST_ROOT/state/history.tsv" 'exit=7'
assert_contains "$FLUXENV_TEST_ROOT/state/receipts.tsv" tools/first
run_state success || fail 'retry lifecycle'
[ -f "$FLUXENV_TEST_ROOT/state/initialized" ] || fail 'retry missing completion'
if run_state unbound; then fail 'Bash unset-variable failure reported success'; fi
cp "$FLUXENV_TEST_ROOT/state/initialized" "$FLUXENV_TEST_ROOT/last-success"
if run_state fail; then fail 'incremental failure not propagated'; fi
cmp "$FLUXENV_TEST_ROOT/last-success" "$FLUXENV_TEST_ROOT/state/initialized" || fail 'failure erased previous success'
mkdir "$FLUXENV_TEST_ROOT/state/lock"
printf '%s\n' "$$" > "$FLUXENV_TEST_ROOT/state/lock/pid"
if run_state success; then fail 'live lock accepted'; fi
printf '999999999\n' > "$FLUXENV_TEST_ROOT/state/lock/pid"
run_state success || fail 'stale lock not recovered'
printf 'PASS: success/failure history, partial receipts, last success and lock recovery\n'

new_case files
printf 'first\n' > "$FLUXENV_TEST_ROOT/candidate"
printf 'export EXAMPLE=first\n' > "$FLUXENV_TEST_ROOT/body"
printf '# personal config\n' > "$FLUXENV_TEST_ROOT/user/rc"
run_state managed || fail 'initial managed files'
printf 'second\n' > "$FLUXENV_TEST_ROOT/candidate"
printf 'export EXAMPLE=second\n' > "$FLUXENV_TEST_ROOT/body"
printf '# outside change\n' >> "$FLUXENV_TEST_ROOT/user/rc"
run_state managed || fail 'template increment'
assert_contains "$FLUXENV_TEST_ROOT/user/config" second
assert_contains "$FLUXENV_TEST_ROOT/user/rc" EXAMPLE=second
assert_contains "$FLUXENV_TEST_ROOT/user/rc" '# outside change'
printf 'personal\n' >> "$FLUXENV_TEST_ROOT/user/config"
printf 'third\n' > "$FLUXENV_TEST_ROOT/candidate"
printf 'export EXAMPLE=third\n' > "$FLUXENV_TEST_ROOT/body"
python3 - "$FLUXENV_TEST_ROOT/user/rc" <<'PY'
import sys
path = sys.argv[1]
with open(path) as stream:
    content = stream.read().replace('EXAMPLE=second', 'EXAMPLE=personal')
with open(path, 'w') as stream:
    stream.write(content)
PY
run_state managed || fail 'preserving personal edits'
assert_contains "$FLUXENV_TEST_ROOT/user/config" personal
assert_contains "$FLUXENV_TEST_ROOT/user/rc" EXAMPLE=personal
! grep -q third "$FLUXENV_TEST_ROOT/user/rc" || fail 'edited block overwritten'
rm "$FLUXENV_TEST_ROOT/user/config"
run_state managed || fail 'deleted-file repair'
assert_contains "$FLUXENV_TEST_ROOT/user/config" third
printf 'PASS: template updates, block boundaries, local-edit preservation and deleted-file repair\n'

new_case dry
printf 'candidate\n' > "$FLUXENV_TEST_ROOT/candidate"
printf 'body\n' > "$FLUXENV_TEST_ROOT/body"
run_state dry || fail 'dry lifecycle'
[ ! -e "$FLUXENV_TEST_ROOT/state" ] && [ ! -e "$FLUXENV_TEST_ROOT/user/rc" ] || fail 'dry created persistent files'
mkdir "$FLUXENV_TEST_ROOT/real-state"
ln -s "$FLUXENV_TEST_ROOT/real-state" "$FLUXENV_TEST_ROOT/state"
if run_state success; then fail 'state symlink accepted'; fi
printf 'PASS: dry run and unsafe state paths\n'

new_case uv_install
mkdir -p "$FLUXENV_TEST_ROOT/offline"
cat > "$FLUXENV_TEST_ROOT/offline/uv-install.sh" <<'INSTALLER'
#!/bin/sh
[ "$UV_NO_MODIFY_PATH" = 1 ] || exit 1
printf 'installed\n' >> "$FLUXENV_TEST_ROOT/uv-installer-calls"
cat > "$UV_INSTALL_DIR/uv" <<'UV'
#!/bin/sh
[ "$1" = --version ] && echo 'uv offline-test'
UV
chmod +x "$UV_INSTALL_DIR/uv"
INSTALLER
run_uv_stage() {
    env PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/bash > "$FLUXENV_TEST_ROOT/output" 2>&1 <<'UV_STAGE'
set -euo pipefail
source "$FLUXENV_TEST_REPO/lib/core.sh"
source "$FLUXENV_TEST_REPO/lib/state.sh"
source "$FLUXENV_TEST_REPO/lib/steps/uv.sh"
init_colors
state_open "$FLUXENV_TEST_ROOT/state" uv-test
state_begin
DRY_RUN=0
ALLOW_ONLINE_FETCH=0
OFFLINE_DIR="$FLUXENV_TEST_ROOT/offline"
UV_INSTALL_DIR="$FLUXENV_TEST_ROOT/bin"
install_uv_system
state_finish
UV_STAGE
}
run_uv_stage || fail 'offline uv install'
run_uv_stage || fail 'offline uv reuse'
[ "$(wc -l < "$FLUXENV_TEST_ROOT/uv-installer-calls" | tr -d ' ')" = 1 ] || fail 'uv installer repeated'
rm "$FLUXENV_TEST_ROOT/bin/uv"
printf '#!/bin/sh\nexit 0\n' > "$FLUXENV_TEST_ROOT/offline/uv-install.sh"
if run_uv_stage; then fail 'no-op uv installer accepted'; fi
assert_contains "$FLUXENV_TEST_ROOT/state/history.tsv" failed
printf 'PASS: uv offline installation, reuse and post-install verification\n'

cat > "$test_root/bin/driver" <<'MOCK'
#!/bin/bash
set -euo pipefail
case "${0##*/}" in
    uname) case "$1" in -s) echo Linux ;; -m) echo x86_64 ;; *) echo mock-linux ;; esac ;;
    whoami) echo root ;;
    id)
        case "${1:-}" in
            -un) echo root ;;
            -u) echo 0 ;;
            "$FLUXENV_TEST_USER") exit 0 ;;
            *) exit 1 ;;
        esac ;;
    getent)
        [ "$1" = passwd ] && [ "$2" = "$FLUXENV_TEST_USER" ]
        printf '%s:x:501:20::%s:/bin/zsh\n' "$2" "$FLUXENV_TEST_ROOT/user" ;;
    dpkg-query)
        package="${@: -1}"
        grep -Fxq "$package" "$FLUXENV_TEST_ROOT/installed" || exit 1
        printf installed ;;
    dpkg) [ "$1" = --print-architecture ] && echo amd64 ;;
    apt)
        printf 'apt %s\n' "$*" >> "$FLUXENV_TEST_ROOT/mutations"
        action="$1"; shift
        case "$action" in
            update) ;;
            upgrade) [ "${FLUXENV_TEST_FAIL_UPGRADE:-0}" = 0 ] ;;
            install)
                for package in "$@"; do
                    [[ "$package" != -* ]] || continue
                    if [ "$package" = gh ] && [ -n "${GH_OS_RELEASE_FILE:-}" ] && grep -q '20.04' "$GH_OS_RELEASE_FILE"; then
                        [ -s "$GH_APT_DIR/keyrings/githubcli-archive-keyring.gpg" ] &&
                            grep -q 'https://cli.github.com/packages stable main' "$GH_APT_DIR/sources.list.d/github-cli.list" || exit 4
                    fi
                    grep -Fxq "$package" "$FLUXENV_TEST_ROOT/installed" || printf '%s\n' "$package" >> "$FLUXENV_TEST_ROOT/installed"
                    [ "$package" != gh ] || ln -sf "$FLUXENV_TEST_DRIVER" "$FLUXENV_TEST_ROOT/bin/gh"
                done ;;
            *) exit 1 ;;
        esac ;;
    runuser)
        [ "$1" = -u ] && [ "$2" = "$FLUXENV_TEST_USER" ] && [ "$3" = -- ]
        printf 'runuser %s\n' "$2" >> "$FLUXENV_TEST_ROOT/user-context"
        shift 3; exec "$@" ;;
    uv)
        case "$1" in
            --version) echo 'uv test' ;;
            tool)
                case "$2" in
                    dir) printf '%s\n' "${UV_TOOL_BIN_DIR:-$FLUXENV_TEST_ROOT/tools/bin}" ;;
                    list) cat "$FLUXENV_TEST_ROOT/uv-installed" 2>/dev/null || true ;;
                    install|upgrade)
                        printf 'uv %s\n' "$*" >> "$FLUXENV_TEST_ROOT/mutations"
                        [ "${FLUXENV_TEST_FAIL_HF:-0}" = 0 ] || exit 9
                        mkdir -p "${UV_TOOL_BIN_DIR:-$FLUXENV_TEST_ROOT/tools/bin}"
                        ln -sf "$FLUXENV_TEST_DRIVER" "${UV_TOOL_BIN_DIR:-$FLUXENV_TEST_ROOT/tools/bin}/hf"
                        echo 'huggingface-hub v2.2.0' > "$FLUXENV_TEST_ROOT/uv-installed" ;;
                    *) exit 1 ;;
                esac ;;
            *) exit 1 ;;
        esac ;;
    hf) [ "$1" = version ] && echo '2.2.0' ;;
    gh) echo 'gh version test' ;;
    starship) case "$1" in --version) echo 'starship test' ;; module) [ -s "$STARSHIP_CONFIG" ] ;; *) exit 1 ;; esac ;;
    hostname) [ "$#" = 0 ] && echo existing-host ;;
    locale) echo en_US.utf8 ;;
    curl)
        request="$*"
        if [[ "$request" == *githubcli-archive-keyring.gpg* ]]; then
            printf 'curl gh-keyring\n' >> "$FLUXENV_TEST_ROOT/mutations"
            [ "${FLUXENV_TEST_FAIL_KEYRING:-0}" = 0 ] || exit 5
            output=""
            while [ "$#" -gt 0 ]; do
                if [ "$1" = -o ]; then output="$2"; shift 2; else shift; fi
            done
            printf 'mock gpg keyring\n' > "$output"
        elif [[ "$request" == *nvm-sh/nvm* ]]; then
            output=""
            while [ "$#" -gt 0 ]; do
                if [ "$1" = -o ]; then output="$2"; shift 2; else shift; fi
            done
            cat > "$output" <<'INSTALLER'
#!/bin/bash
set -eu
mkdir -p "$NVM_DIR"
cp "$FLUXENV_TEST_REPO/tests/helpers/nvm.sh" "$NVM_DIR/nvm.sh"
INSTALLER
        else
            printf 'FORBIDDEN curl %s\n' "$*" >> "$FLUXENV_TEST_ROOT/mutations"
            exit 1
        fi ;;
    node)
        case "$1" in
            -p) echo 24 ;;
            --version) echo v24.20.0 ;;
            *) exit 1 ;;
        esac ;;
    corepack)
        if [ "$1" = --version ]; then echo 0.36.0; exit 0; fi
        printf 'corepack %s\n' "$*" >> "$FLUXENV_TEST_ROOT/mutations"
        case "$1" in
            enable) ln -sf "$FLUXENV_TEST_DRIVER" "${0%/*}/pnpm" ;;
            install|prepare) touch "$NVM_DIR/pnpm-installed" ;;
            *) exit 1 ;;
        esac ;;
    npm) [ "$1" = --version ] && echo 10.0.0 ;;
    pnpm)
        case "$1" in
            --version) [ -f "$NVM_DIR/pnpm-installed" ] && echo 12.11.2 ;;
            add)
                printf 'pnpm %s\n' "$*" >> "$FLUXENV_TEST_ROOT/mutations"
                [ "${FLUXENV_TEST_FAIL_GC:-0}" = 0 ] || exit 9
                case ":$PATH:" in *":$PNPM_HOME/bin:"*) ;; *) exit 10 ;; esac
                mkdir -p "$PNPM_HOME/bin"; ln -sf "$FLUXENV_TEST_DRIVER" "$PNPM_HOME/bin/gc" ;;
            *) exit 1 ;;
        esac ;;
    gc)
        case "$*" in
            version|--version|'auth login --help') echo 'gc test' ;;
            *) printf 'FORBIDDEN gc %s\n' "$*" >> "$FLUXENV_TEST_ROOT/mutations"; exit 1 ;;
        esac ;;
    useradd|userdel|chpasswd|chsh|sudo|git|chown)
        printf 'FORBIDDEN %s %s\n' "${0##*/}" "$*" >> "$FLUXENV_TEST_ROOT/mutations"; exit 1 ;;
    *) exit 1 ;;
esac
MOCK
chmod +x "$test_root/bin/driver"
export FLUXENV_TEST_DRIVER="$test_root/bin/driver"
for tool in uname whoami id getent dpkg-query dpkg apt runuser hostname locale useradd userdel chpasswd chsh sudo curl git chown; do
    ln -s driver "$test_root/bin/$tool"
done

new_linux_case() {
    new_case "$1"
    mkdir -p "$FLUXENV_TEST_ROOT/bin" "$FLUXENV_TEST_ROOT/offline"
    for tool in uv starship; do ln -s "$FLUXENV_TEST_DRIVER" "$FLUXENV_TEST_ROOT/bin/$tool"; done
    for plugin in zsh-autosuggestions zsh-syntax-highlighting; do
        mkdir -p "$FLUXENV_TEST_ROOT/offline/$plugin"
        printf '# test plugin\n' > "$FLUXENV_TEST_ROOT/offline/$plugin/$plugin.zsh"
    done
    printf 'curl\n' > "$FLUXENV_TEST_ROOT/installed"
    unset FLUXENV_TEST_FAIL_HF FLUXENV_TEST_FAIL_UPGRADE
    unset FLUXENV_TEST_FAIL_NODE FLUXENV_TEST_FAIL_GC
    unset FLUXENV_TEST_FAIL_KEYRING
    {
        printf 'PROFILE_STEPS="preflight packages uv hostname user user_tools shell_env vim hf_auth finalize"\n'
        printf 'FLUXENV_STATE_DIR=%q\n' "$FLUXENV_TEST_ROOT/state"
        printf 'OFFLINE_DIR=%q\n' "$FLUXENV_TEST_ROOT/offline"
        printf 'BASE_PACKAGES="curl jq"\nENABLE_APT_MIRROR=0\n'
        printf 'VISUAL_HOSTNAME_ONLY=1\nHOST_NAME=incremental-host\n'
        printf 'ENABLE_VIM=0\nCHANGE_DEFAULT_SHELL=0\nHF_LOGIN=0\n'
    } > "$FLUXENV_TEST_ROOT/config.env"
}
run_linux() {
    env PATH="$FLUXENV_TEST_ROOT/bin:$test_root/bin:/usr/bin:/bin:/usr/sbin:/sbin" SUDO_USER="$FLUXENV_TEST_USER" \
        /bin/bash "$ROOT_DIR/scripts/fluxenv" --config "$FLUXENV_TEST_ROOT/config.env" "$@" > "$FLUXENV_TEST_ROOT/output" 2>&1
}

new_linux_case linux
run_linux --non-interactive || { cat "$FLUXENV_TEST_ROOT/output"; fail 'Linux first bootstrap'; }
assert_contains "$FLUXENV_TEST_ROOT/mutations" 'apt install -y --no-install-recommends jq gh'
assert_contains "$FLUXENV_TEST_ROOT/mutations" 'uv tool install huggingface_hub>=1.20'
assert_contains "$FLUXENV_TEST_ROOT/mutations" 'nvm install 24'
assert_contains "$FLUXENV_TEST_ROOT/mutations" 'nvm alias default 24'
assert_contains "$FLUXENV_TEST_ROOT/mutations" 'corepack install --global pnpm@latest'
assert_contains "$FLUXENV_TEST_ROOT/mutations" 'pnpm add --global atomgit-cli@latest'
assert_contains "$FLUXENV_TEST_ROOT/user-context" "runuser $FLUXENV_TEST_USER"
! grep -q FORBIDDEN "$FLUXENV_TEST_ROOT/mutations" || fail 'unexpected privileged mutation'
/bin/zsh -n "$FLUXENV_TEST_ROOT/user/.zshrc" || fail 'Linux zsh syntax'
cp "$FLUXENV_TEST_ROOT/mutations" "$FLUXENV_TEST_ROOT/first-mutations"
cp "$FLUXENV_TEST_ROOT/user/.zshrc" "$FLUXENV_TEST_ROOT/first-rc"
run_linux --non-interactive || { cat "$FLUXENV_TEST_ROOT/output"; fail 'Linux repeat'; }
cmp "$FLUXENV_TEST_ROOT/first-mutations" "$FLUXENV_TEST_ROOT/mutations" || fail 'Linux repeat changed packages/users'
cmp "$FLUXENV_TEST_ROOT/first-rc" "$FLUXENV_TEST_ROOT/user/.zshrc" || fail 'Linux repeated shell rewrite'
printf '\n# local alias\nalias mycmd=true\n' >> "$FLUXENV_TEST_ROOT/user/.zshrc"
printf 'EXTRA_PACKAGES="new-package"\nHOST_NAME=""\n' >> "$FLUXENV_TEST_ROOT/config.env"
rm "$FLUXENV_TEST_ROOT/tools/bin/hf" "$FLUXENV_TEST_ROOT/user/.config/starship.toml"
printf 'personal plugin data\n' > "$FLUXENV_TEST_ROOT/user/.zsh/plugins/zsh-autosuggestions/personal.txt"
rm "$FLUXENV_TEST_ROOT/user/.zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh"
: > "$FLUXENV_TEST_ROOT/mutations"
run_linux --non-interactive || { cat "$FLUXENV_TEST_ROOT/output"; fail 'Linux increment'; }
assert_contains "$FLUXENV_TEST_ROOT/mutations" 'apt install -y --no-install-recommends new-package'
! grep -Eq 'apt upgrade|apt install -f|FORBIDDEN' "$FLUXENV_TEST_ROOT/mutations" || fail 'increment repeated first-time mutations'
assert_contains "$FLUXENV_TEST_ROOT/user/.zshrc" 'alias mycmd=true'
[ -s "$FLUXENV_TEST_ROOT/user/.config/starship.toml" ] && [ -x "$FLUXENV_TEST_ROOT/tools/bin/hf" ] || fail 'Linux missing-resource repair'
assert_contains "$FLUXENV_TEST_ROOT/user/.zsh/plugins/zsh-autosuggestions/personal.txt" 'personal plugin data'
[ -f "$FLUXENV_TEST_ROOT/user/.zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh" ] || fail 'plugin entry not repaired'
run_linux --profile autodl --status || fail 'cross-profile status'
assert_contains "$FLUXENV_TEST_ROOT/output" schema=1
rm "$FLUXENV_TEST_ROOT/bin/gh"
: > "$FLUXENV_TEST_ROOT/mutations"
run_linux --non-interactive || fail 'Linux gh executable repair'
assert_contains "$FLUXENV_TEST_ROOT/mutations" 'apt install --reinstall -y --no-install-recommends gh'
printf 'PASS: Linux entry, current user context, incremental packages/tools, config preservation and shared profile history\n'

new_linux_case ubuntu20
printf 'ID=ubuntu\nVERSION_ID="20.04"\n' > "$FLUXENV_TEST_ROOT/os-release"
{
    printf 'GH_OS_RELEASE_FILE=%q\n' "$FLUXENV_TEST_ROOT/os-release"
    printf 'GH_APT_DIR=%q\n' "$FLUXENV_TEST_ROOT/apt"
} >> "$FLUXENV_TEST_ROOT/config.env"
run_linux --non-interactive || { cat "$FLUXENV_TEST_ROOT/output"; fail 'Ubuntu 20.04 keyring/source'; }
assert_contains "$FLUXENV_TEST_ROOT/apt/sources.list.d/github-cli.list" "deb [arch=amd64 signed-by=$FLUXENV_TEST_ROOT/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main"
assert_contains "$FLUXENV_TEST_ROOT/mutations" 'curl gh-keyring'
chmod 600 "$FLUXENV_TEST_ROOT/apt/keyrings/githubcli-archive-keyring.gpg"
cp "$FLUXENV_TEST_ROOT/mutations" "$FLUXENV_TEST_ROOT/first-mutations"
run_linux --non-interactive || fail 'Ubuntu 20.04 repeat'
cmp "$FLUXENV_TEST_ROOT/first-mutations" "$FLUXENV_TEST_ROOT/mutations" || fail 'Ubuntu repository repeated download or install'
python3 - "$FLUXENV_TEST_ROOT/apt" <<'PY'
import os, stat, sys
for file in ('keyrings/githubcli-archive-keyring.gpg', 'sources.list.d/github-cli.list'):
    assert stat.S_IMODE(os.stat(os.path.join(sys.argv[1], file)).st_mode) == 0o644
PY
rm "$FLUXENV_TEST_ROOT/apt/keyrings/githubcli-archive-keyring.gpg"
export FLUXENV_TEST_FAIL_KEYRING=1
if run_linux --non-interactive; then fail 'keyring download failure accepted'; fi
assert_contains "$FLUXENV_TEST_ROOT/state/history.tsv" failed
unset FLUXENV_TEST_FAIL_KEYRING
run_linux --non-interactive || fail 'keyring download retry'
printf 'PASS: Ubuntu 20.04 official gh repository, readable keyring, reuse and download recovery\n'

new_linux_case linux_failure
export FLUXENV_TEST_FAIL_UPGRADE=1
if run_linux --non-interactive; then fail 'upgrade failure ignored'; fi
[ ! -f "$FLUXENV_TEST_ROOT/state/initialized" ] || fail 'upgrade failure marked complete'
! grep -q system/initial-update "$FLUXENV_TEST_ROOT/state/receipts.tsv" || fail 'failed upgrade checkpointed'
unset FLUXENV_TEST_FAIL_UPGRADE
export FLUXENV_TEST_FAIL_HF=1
if run_linux --non-interactive; then fail 'HF failure ignored'; fi
assert_contains "$FLUXENV_TEST_ROOT/state/receipts.tsv" system/initial-update
unset FLUXENV_TEST_FAIL_HF
cp "$FLUXENV_TEST_ROOT/mutations" "$FLUXENV_TEST_ROOT/before-retry"
run_linux --non-interactive || fail 'Linux resume'
[ "$(grep -c '^apt upgrade' "$FLUXENV_TEST_ROOT/mutations")" = 2 ] || fail 'successful upgrade repeated after HF failure'
[ -f "$FLUXENV_TEST_ROOT/state/initialized" ] && [ ! -d "$FLUXENV_TEST_ROOT/state/lock" ] || fail 'Linux resume marker/lock'
printf 'PASS: Linux failed upgrade retries; later failure resumes without repeating completed upgrades\n'

new_linux_case linux_dry
run_linux --dry-run || { cat "$FLUXENV_TEST_ROOT/output"; fail 'Linux preview'; }
[ ! -e "$FLUXENV_TEST_ROOT/mutations" ] && [ ! -e "$FLUXENV_TEST_ROOT/state" ] && [ ! -e "$FLUXENV_TEST_ROOT/user/.zshrc" ] || fail 'Linux preview modified environment'
if run_linux --non-interactive --hf-login; then fail 'non-interactive explicit auth accepted'; fi
assert_contains "$FLUXENV_TEST_ROOT/output" '非交互安装请使用 --skip-hf-login'
printf 'PASS: Linux preview and non-interactive login validation\n'
printf 'All shared-state and Linux checks passed.\n'
