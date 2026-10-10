#!/bin/bash

# Exercise the complete installer with fake system tools and explicit temporary
# config paths. HOME is never changed, and no real brew/sudo/scutil is invoked.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/fluxenv-macos-tests.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT
mkdir -p "$test_root/mocks"

cat > "$test_root/mocks/driver" <<'MOCK'
#!/bin/bash
set -euo pipefail
case "${0##*/}" in
    uname)
        case "$1" in
            -s) printf '%s\n' "${FLUXENV_TEST_OS:-Darwin}" ;;
            -m) printf '%s\n' "${FLUXENV_TEST_ARCH:-arm64}" ;;
            *) printf 'test\n' ;;
        esac ;;
    id)
        case "$1" in
            -u) printf '%s\n' "${FLUXENV_TEST_UID:-501}" ;;
            -un) printf 'fluxenv-test\n' ;;
            *) exit 1 ;;
        esac ;;
    sysctl) printf '0\n' ;;
    sw_vers) printf '15.6.1\n' ;;
    xcode-select|xcrun) [ "${FLUXENV_TEST_NO_CLT:-0}" -eq 0 ] ;;
    dscl) printf 'UserShell: /bin/zsh\n' ;;
    curl)
        printf 'curl %s\n' "$*" >> "$FLUXENV_TEST_ROOT/mutations"
        request="$*"
        output=""
        while [ "$#" -gt 0 ]; do
            if [ "$1" = -o ]; then output="$2"; shift 2; else shift; fi
        done
        if [[ "$request" == *nvm-sh/nvm* ]]; then
            cat > "$output" <<'INSTALLER'
#!/bin/bash
set -eu
mkdir -p "$NVM_DIR"
cp "$FLUXENV_TEST_REPO/tests/helpers/nvm.sh" "$NVM_DIR/nvm.sh"
INSTALLER
        else
            [ "${FLUXENV_TEST_BOOTSTRAP:-0}" -eq 1 ] || exit 1
            cat > "$output" <<'INSTALLER'
#!/bin/bash
set -eu
[ "${NONINTERACTIVE:-}" = 1 ]
ln -s "$FLUXENV_TEST_MOCK_DRIVER" "$FLUXENV_TEST_ROOT/brew prefix/bin/brew"
INSTALLER
        fi
        ;;
    chsh) printf 'unexpected %s\n' "$*" >> "$FLUXENV_TEST_ROOT/mutations"; exit 1 ;;
    sudo)
        printf 'sudo %s\n' "$*" >> "$FLUXENV_TEST_ROOT/mutations"
        [ "$1" != -v ] || exit 0
        exec "$@" ;;
    scutil)
        key="$2"
        case "$1" in
            --get)
                [ -s "$FLUXENV_TEST_ROOT/names/$key" ] || exit 1
                cat "$FLUXENV_TEST_ROOT/names/$key" ;;
            --set)
                printf 'scutil %s\n' "$*" >> "$FLUXENV_TEST_ROOT/mutations"
                if [ "${FLUXENV_TEST_FAIL_NAME_KEY:-}" = "$key" ] && [ ! -f "$FLUXENV_TEST_ROOT/name-failed" ]; then
                    touch "$FLUXENV_TEST_ROOT/name-failed"
                    exit 1
                fi
                printf '%s' "$3" > "$FLUXENV_TEST_ROOT/names/$key" ;;
            *) exit 1 ;;
        esac ;;
    brew)
        case "$1" in
            --prefix) printf '%s\n' "$FLUXENV_TEST_ROOT/brew prefix" ;;
            shellenv)
                printf 'export HOMEBREW_PREFIX=%q\n' "$FLUXENV_TEST_ROOT/brew prefix"
                printf 'export PATH=%q:"$PATH"\n' "$FLUXENV_TEST_ROOT/brew prefix/bin" ;;
            list) cat "$FLUXENV_TEST_ROOT/installed" ;;
            install|reinstall)
                printf 'brew %s\n' "$*" >> "$FLUXENV_TEST_ROOT/mutations"
                [ "${FLUXENV_TEST_FAIL_BREW:-0}" -eq 0 ] || exit 1
                shift
                printf '%s\n' "$@" >> "$FLUXENV_TEST_ROOT/installed"
                for formula in "$@"; do
                    case "$formula" in
                        uv|gh) ln -sf "$FLUXENV_TEST_MOCK_DRIVER" "$FLUXENV_TEST_ROOT/brew prefix/bin/$formula" ;;
                    esac
                done ;;
            *) exit 1 ;;
        esac ;;
    uv)
        case "$1" in
            --version) printf 'uv test\n' ;;
            tool)
                case "$2" in
                    dir) printf '%s\n' "${UV_TOOL_BIN_DIR:-$FLUXENV_TEST_ROOT/tools/bin}" ;;
                    list) cat "$FLUXENV_TEST_ROOT/uv-installed" 2>/dev/null || true ;;
                    install|upgrade)
                        printf 'uv %s\n' "$*" >> "$FLUXENV_TEST_ROOT/mutations"
                        [ "${FLUXENV_TEST_FAIL_HF:-0}" -eq 0 ] || exit 1
                        mkdir -p "${UV_TOOL_BIN_DIR:-$FLUXENV_TEST_ROOT/tools/bin}"
                        ln -sf "$FLUXENV_TEST_MOCK_DRIVER" "${UV_TOOL_BIN_DIR:-$FLUXENV_TEST_ROOT/tools/bin}/hf"
                        printf 'huggingface-hub v2.2.0\n' > "$FLUXENV_TEST_ROOT/uv-installed"
                        printf '2.2.0\n' > "$FLUXENV_TEST_ROOT/hf-version" ;;
                    *) exit 1 ;;
                esac ;;
            *) exit 1 ;;
        esac ;;
    node)
        case "$1" in
            -p) printf '24\n' ;;
            --version) printf 'v24.20.0\n' ;;
            *) exit 1 ;;
        esac ;;
    corepack)
        if [ "$1" = --version ]; then printf '0.36.0\n'; exit 0; fi
        printf 'corepack %s\n' "$*" >> "$FLUXENV_TEST_ROOT/mutations"
        case "$1" in
            enable) ln -sf "$FLUXENV_TEST_MOCK_DRIVER" "${0%/*}/pnpm" ;;
            install|prepare) touch "$NVM_DIR/pnpm-installed" ;;
            *) exit 1 ;;
        esac ;;
    npm) [ "$1" = --version ] && printf '10.0.0\n' ;;
    pnpm)
        case "$1" in
            --version) [ -f "$NVM_DIR/pnpm-installed" ] && printf '10.0.0\n' ;;
            add)
                printf 'pnpm %s\n' "$*" >> "$FLUXENV_TEST_ROOT/mutations"
                [ "${FLUXENV_TEST_FAIL_GC:-0}" = 0 ] || exit 9
                mkdir -p "$PNPM_HOME"; ln -sf "$FLUXENV_TEST_MOCK_DRIVER" "$PNPM_HOME/gc" ;;
            *) exit 1 ;;
        esac ;;
    gc)
        case "$*" in
            version|--version|'auth login --help') printf 'gc test\n' ;;
            *) printf 'unexpected gc %s\n' "$*" >> "$FLUXENV_TEST_ROOT/mutations"; exit 1 ;;
        esac ;;
    hf)
        case "$1" in
            version) cat "$FLUXENV_TEST_ROOT/hf-version" ;;
            auth)
                case "$2" in
                    whoami) [ -f "$FLUXENV_TEST_ROOT/hf-authenticated" ] ;;
                    login)
                        printf 'hf auth login\n' >> "$FLUXENV_TEST_ROOT/mutations"
                        printf 'Device code: TEST-CODE\nAuthorize in browser [Enter]: '
                        read -r answer
                        touch "$FLUXENV_TEST_ROOT/hf-authenticated" ;;
                    *) exit 1 ;;
                esac ;;
            *) exit 1 ;;
        esac ;;
    gh) printf 'gh version test\n' ;;
    starship)
        case "$1" in
            --version) printf 'starship test\n' ;;
            init) printf 'PROMPT="fluxenv-test> "\n' ;;
            module) [ -s "$STARSHIP_CONFIG" ] ;;
            *) exit 1 ;;
        esac ;;
    *) exit 1 ;;
esac
MOCK
chmod +x "$test_root/mocks/driver"
for tool in uname id sysctl sw_vers xcode-select xcrun dscl curl chsh sudo scutil brew; do
    ln -s driver "$test_root/mocks/$tool"
done
export PATH="$test_root/mocks:/usr/bin:/bin:/usr/sbin:/sbin"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_contains() { grep -Fq -- "$2" "$1" || fail "$1 does not contain: $2"; }
assert_no_mutations() { [ ! -s "$FLUXENV_TEST_ROOT/mutations" ] || fail "unexpected system mutation"; }
run_fluxenv() { /bin/bash "$ROOT_DIR/scripts/fluxenv" --config "$FLUXENV_TEST_ROOT/config.env" "$@" > "$FLUXENV_TEST_ROOT/output" 2>&1; }

new_case() {
    export FLUXENV_TEST_ROOT="$test_root/$1"
    unset FLUXENV_TEST_OS FLUXENV_TEST_ARCH FLUXENV_TEST_UID FLUXENV_TEST_NO_CLT FLUXENV_TEST_FAIL_NAME_KEY FLUXENV_TEST_FAIL_BREW FLUXENV_TEST_FAIL_HF FLUXENV_TEST_BOOTSTRAP FLUXENV_TEST_INSTALL_HOMEBREW FLUXENV_TEST_DRY_RUN
    unset FLUXENV_TEST_FAIL_NODE FLUXENV_TEST_FAIL_GC
    mkdir -p "$FLUXENV_TEST_ROOT/names" "$FLUXENV_TEST_ROOT/brew prefix/bin" "$FLUXENV_TEST_ROOT/user"
    printf 'Old Mac' > "$FLUXENV_TEST_ROOT/names/ComputerName"
    printf 'old-mac' > "$FLUXENV_TEST_ROOT/names/LocalHostName"
    : > "$FLUXENV_TEST_ROOT/names/HostName"
    : > "$FLUXENV_TEST_ROOT/installed"
    for tool in uv starship gh; do
        ln -s "$test_root/mocks/driver" "$FLUXENV_TEST_ROOT/brew prefix/bin/$tool"
    done
    {
        printf 'MACOS_BREW_BIN=%q\n' "$test_root/mocks/brew"
        printf 'MACOS_CONFIG_DIR=%q\n' "$FLUXENV_TEST_ROOT/config dir"
        printf 'MACOS_STATE_DIR=%q\n' "$FLUXENV_TEST_ROOT/state"
        printf 'MACOS_ZDOTDIR=%q\n' "$FLUXENV_TEST_ROOT/user"
        printf 'MACOS_VIMRC=%q\n' "$FLUXENV_TEST_ROOT/user/.vimrc"
        printf 'NVM_DIR=%q\n' "$FLUXENV_TEST_ROOT/nvm"
        printf 'PNPM_HOME=%q\n' "$FLUXENV_TEST_ROOT/pnpm"
        printf 'ENABLE_VIM=0\nCHANGE_DEFAULT_SHELL=0\n'
    } > "$FLUXENV_TEST_ROOT/config.env"
}

export FLUXENV_TEST_REPO="$ROOT_DIR"
export FLUXENV_TEST_MOCK_DRIVER="$test_root/mocks/driver"
run_homebrew_stage() {
    /bin/bash > "$FLUXENV_TEST_ROOT/output" 2>&1 <<'STAGE'
set -euo pipefail
source "$FLUXENV_TEST_REPO/lib/core.sh"
source "$FLUXENV_TEST_REPO/lib/state.sh"
source "$FLUXENV_TEST_REPO/lib/macos/packages.sh"
state_open "$FLUXENV_TEST_ROOT/state" macos
init_colors
CURRENT_STAGE=0
TOTAL_STAGES=1
ARCH=arm64
INTERACTIVE=0
DRY_RUN="${FLUXENV_TEST_DRY_RUN:-0}"
INSTALL_HOMEBREW="${FLUXENV_TEST_INSTALL_HOMEBREW:-1}"
BREW_DEFAULT_PREFIX="$FLUXENV_TEST_ROOT/brew prefix"
BREW_BIN=""
BREW_PREFIX=""
command_exists() { [ "$1" != brew ] && command -v "$1" >/dev/null 2>&1; }
step_macos_homebrew
STAGE
}

new_case install
printf '# existing profile\nexport EXISTING_PROFILE=ok\n' > "$FLUXENV_TEST_ROOT/user/.zprofile"
printf '# existing rc\nexport EXISTING_RC=ok\n' > "$FLUXENV_TEST_ROOT/user/.zshrc"
printf 'set ignorecase\n' > "$FLUXENV_TEST_ROOT/user/.vimrc"
run_fluxenv --with-vim --non-interactive || { cat "$FLUXENV_TEST_ROOT/output"; fail install; }
assert_contains "$FLUXENV_TEST_ROOT/mutations" 'brew install wget jq git autojump universal-ctags starship zsh-autosuggestions zsh-syntax-highlighting vim astyle'
assert_contains "$FLUXENV_TEST_ROOT/mutations" 'uv tool install huggingface_hub>=1.20'
assert_contains "$FLUXENV_TEST_ROOT/mutations" 'nvm install 24'
assert_contains "$FLUXENV_TEST_ROOT/mutations" 'nvm alias default 24'
assert_contains "$FLUXENV_TEST_ROOT/mutations" 'corepack enable pnpm'
assert_contains "$FLUXENV_TEST_ROOT/mutations" 'corepack install --global pnpm@latest'
assert_contains "$FLUXENV_TEST_ROOT/mutations" 'pnpm add --global atomgit-cli@latest'
ln -s "$FLUXENV_TEST_MOCK_DRIVER" "$FLUXENV_TEST_ROOT/brew prefix/bin/node"
ln -s "$FLUXENV_TEST_MOCK_DRIVER" "$FLUXENV_TEST_ROOT/pnpm/node"
! grep -q sudo "$FLUXENV_TEST_ROOT/mutations" || fail 'non-interactive run renamed device'
assert_contains "$FLUXENV_TEST_ROOT/user/.zshrc" EXISTING_RC
assert_contains "$FLUXENV_TEST_ROOT/user/.zprofile" EXISTING_PROFILE
assert_contains "$FLUXENV_TEST_ROOT/user/.vimrc" 'set ignorecase'
! grep -q 'palette = ' "$FLUXENV_TEST_ROOT/config dir/starship-macos.toml" || fail 'Mac prompt overrides Terminal palette'
assert_contains "$FLUXENV_TEST_ROOT/config dir/starship-macos.toml" 'style_user = "bright-blue bold"'
assert_contains "$FLUXENV_TEST_ROOT/config dir/macos.zsh" 'TERM_PROGRAM'
assert_contains "$FLUXENV_TEST_ROOT/config dir/macos.zsh" '\033]4;3;rgb:f4/c9/5d'
assert_contains "$FLUXENV_TEST_ROOT/config dir/macos.zsh" 'ZSH_HIGHLIGHT_STYLES[default]'
/bin/zsh -n "$FLUXENV_TEST_ROOT/config dir/macos.zsh" "$FLUXENV_TEST_ROOT/user/.zshrc"
env ZDOTDIR="$FLUXENV_TEST_ROOT/user" HISTFILE="$FLUXENV_TEST_ROOT/history" \
    /bin/zsh -fic 'source "$FLUXENV_TEST_ROOT/user/.zshrc"; [[ $FLUXENV_MACOS_LOADED == 1 && $PROMPT == "fluxenv-test> " && $(command -v node) == "$FLUXENV_TEST_ROOT/nvm/versions/node/v24.0.0/bin/node" ]] && command -v gc >/dev/null' \
    > "$FLUXENV_TEST_ROOT/zsh-output" 2>&1 || { cat "$FLUXENV_TEST_ROOT/zsh-output"; fail 'zsh startup'; }
! grep -q 'no such file' "$FLUXENV_TEST_ROOT/zsh-output" || fail 'Homebrew shellenv command failed'
/usr/bin/vim -Nu "$FLUXENV_TEST_ROOT/user/.vimrc" -n -i NONE -es \
    '+if &tabstop != 4 || &clipboard !=# "unnamed" | cquit | endif' +qall || fail 'vim config'
! grep -Ei '(http_proxy|all_proxy|netui|/run/user|apt |useradd|LS_COLORS=)' "$FLUXENV_TEST_ROOT/config dir/macos.zsh" || fail 'Linux/proxy config leaked'
cp "$FLUXENV_TEST_ROOT/user/.zprofile" "$FLUXENV_TEST_ROOT/profile-first"
cp "$FLUXENV_TEST_ROOT/user/.zshrc" "$FLUXENV_TEST_ROOT/rc-first"
cp "$FLUXENV_TEST_ROOT/user/.vimrc" "$FLUXENV_TEST_ROOT/vim-first"
cp "$FLUXENV_TEST_ROOT/mutations" "$FLUXENV_TEST_ROOT/mutations-first"
snapshot_metadata() {
    python3 - "$FLUXENV_TEST_ROOT" <<'PY'
import os, sys
root = sys.argv[1]
for folder in ('user', 'config dir'):
    for base, _, files in os.walk(os.path.join(root, folder)):
        for name in sorted(files):
            if name == '.zcompdump':
                continue
            path = os.path.join(base, name)
            stat = os.stat(path)
            print(os.path.relpath(path, root), stat.st_ino, stat.st_mtime_ns)
PY
}
snapshot_metadata > "$FLUXENV_TEST_ROOT/metadata-first"
run_fluxenv --with-vim --non-interactive || fail 'repeat install'
cmp "$FLUXENV_TEST_ROOT/profile-first" "$FLUXENV_TEST_ROOT/user/.zprofile" || fail 'profile not idempotent'
cmp "$FLUXENV_TEST_ROOT/rc-first" "$FLUXENV_TEST_ROOT/user/.zshrc" || fail 'rc not idempotent'
cmp "$FLUXENV_TEST_ROOT/vim-first" "$FLUXENV_TEST_ROOT/user/.vimrc" || fail 'vimrc not idempotent'
cmp "$FLUXENV_TEST_ROOT/mutations-first" "$FLUXENV_TEST_ROOT/mutations" || fail 'repeat install modified packages'
snapshot_metadata > "$FLUXENV_TEST_ROOT/metadata-second"
cmp "$FLUXENV_TEST_ROOT/metadata-first" "$FLUXENV_TEST_ROOT/metadata-second" || fail 'repeat rewrote identical config'
[ "$(awk -F '\t' '$4 == "completed" {n++} END {print n+0}' "$FLUXENV_TEST_ROOT/state/history.tsv")" = 2 ] || fail 'missing completion history'
[ -f "$FLUXENV_TEST_ROOT/state/initialized" ] && [ ! -d "$FLUXENV_TEST_ROOT/state/lock" ] || fail 'completion marker/lock'
assert_contains "$FLUXENV_TEST_ROOT/output" '当前设备已完成过初始化'
printf 'PASS: complete install, shell/Vim startup, preservation and repeat run\n'

printf '\n# local customization\n' >> "$FLUXENV_TEST_ROOT/config dir/macos.zsh"
cp "$FLUXENV_TEST_ROOT/config dir/macos.zsh" "$FLUXENV_TEST_ROOT/custom-first"
rm "$FLUXENV_TEST_ROOT/tools/bin/hf" "$FLUXENV_TEST_ROOT/config dir/starship-macos.toml"
: > "$FLUXENV_TEST_ROOT/mutations"
run_fluxenv --with-vim --non-interactive || fail 'incremental repair'
cmp "$FLUXENV_TEST_ROOT/custom-first" "$FLUXENV_TEST_ROOT/config dir/macos.zsh" || fail 'local generated-file edit overwritten'
[ -f "$FLUXENV_TEST_ROOT/config dir/starship-macos.toml" ] && [ -x "$FLUXENV_TEST_ROOT/tools/bin/hf" ] || fail 'missing resource not repaired'
assert_contains "$FLUXENV_TEST_ROOT/mutations" 'uv tool install --reinstall --upgrade huggingface_hub>=1.20'
! grep -Eq '^(brew|sudo)' "$FLUXENV_TEST_ROOT/mutations" || fail 'incremental repair reinstalled/renamed'
run_fluxenv --history || fail 'history command'
assert_contains "$FLUXENV_TEST_ROOT/output" preserved
run_fluxenv --status || fail 'status command'
assert_contains "$FLUXENV_TEST_ROOT/output" 'schema=1'
printf 'PASS: missing hf/config repaired, local changes preserved and history/status readable\n'

printf 'uv\ngh\n' >> "$FLUXENV_TEST_ROOT/installed"
rm "$FLUXENV_TEST_ROOT/brew prefix/bin/uv" "$FLUXENV_TEST_ROOT/brew prefix/bin/gh"
: > "$FLUXENV_TEST_ROOT/mutations"
run_fluxenv --non-interactive || fail 'missing core executable repair'
assert_contains "$FLUXENV_TEST_ROOT/mutations" 'brew reinstall uv gh'
[ -x "$FLUXENV_TEST_ROOT/brew prefix/bin/uv" ] && [ -x "$FLUXENV_TEST_ROOT/brew prefix/bin/gh" ] || fail 'core executable not restored'
printf 'PASS: Homebrew receipts with missing uv/gh executables trigger targeted repair\n'

rm "$FLUXENV_TEST_ROOT/pnpm/gc"
: > "$FLUXENV_TEST_ROOT/mutations"
run_fluxenv --non-interactive || fail 'gc repair'
assert_contains "$FLUXENV_TEST_ROOT/mutations" 'pnpm add --global atomgit-cli@latest'
! grep -Eq '^(nvm|corepack|curl)' "$FLUXENV_TEST_ROOT/mutations" || fail 'gc repair reinstalled toolchain'
printf 'PASS: Node 24/default and Corepack pnpm install once; missing gc repaired alone\n'

new_case gc_failure
export FLUXENV_TEST_FAIL_GC=1
if run_fluxenv --non-interactive; then fail 'gc failure accepted'; fi
[ ! -f "$FLUXENV_TEST_ROOT/state/initialized" ] || fail 'gc failure marked complete'
unset FLUXENV_TEST_FAIL_GC
: > "$FLUXENV_TEST_ROOT/mutations"
run_fluxenv --non-interactive || fail 'gc retry'
assert_contains "$FLUXENV_TEST_ROOT/mutations" 'pnpm add --global atomgit-cli@latest'
! grep -Eq '^(nvm|corepack|curl)' "$FLUXENV_TEST_ROOT/mutations" || fail 'gc retry reinstalled successful toolchain'
printf 'PASS: failed gc install resumes using the completed Node/pnpm environment\n'

new_case node_failure
export FLUXENV_TEST_FAIL_NODE=1
if run_fluxenv --non-interactive; then fail 'Node install failure accepted'; fi
[ ! -f "$FLUXENV_TEST_ROOT/state/initialized" ] || fail 'Node failure marked complete'
[ -s "$FLUXENV_TEST_ROOT/nvm/nvm.sh" ] || fail 'completed nvm installation lost'
unset FLUXENV_TEST_FAIL_NODE
: > "$FLUXENV_TEST_ROOT/mutations"
run_fluxenv --non-interactive || fail 'Node retry'
! grep -q '^curl' "$FLUXENV_TEST_ROOT/mutations" || fail 'Node retry downloaded nvm again'
printf '22\n' > "$FLUXENV_TEST_ROOT/nvm/alias/default"
: > "$FLUXENV_TEST_ROOT/mutations"
run_fluxenv --non-interactive || fail 'default Node repair'
assert_contains "$FLUXENV_TEST_ROOT/mutations" 'nvm alias default 24'
! grep -Eq '^(nvm install|curl|pnpm add)' "$FLUXENV_TEST_ROOT/mutations" || fail 'default repair reinstalled tools'
printf 'PASS: Node failure resumes existing nvm; changed default repaired without reinstall\n'

new_case old_hf
mkdir -p "$FLUXENV_TEST_ROOT/tools/bin"
ln -s "$FLUXENV_TEST_MOCK_DRIVER" "$FLUXENV_TEST_ROOT/tools/bin/hf"
printf '1.19.0\n' > "$FLUXENV_TEST_ROOT/hf-version"
printf 'hf v1.19.0\n' > "$FLUXENV_TEST_ROOT/uv-installed"
run_fluxenv --non-interactive || fail 'old hf upgrade'
assert_contains "$FLUXENV_TEST_ROOT/mutations" 'uv tool upgrade --reinstall hf'
printf 'PASS: older hf upgraded only when device-code support is missing\n'

new_case hf_failure
export FLUXENV_TEST_FAIL_HF=1
if run_fluxenv --non-interactive; then fail 'hf install failure accepted'; fi
[ ! -f "$FLUXENV_TEST_ROOT/state/initialized" ] && [ ! -d "$FLUXENV_TEST_ROOT/state/lock" ] || fail 'failed run marked complete or kept lock'
assert_contains "$FLUXENV_TEST_ROOT/state/history.tsv" failed
cp "$FLUXENV_TEST_ROOT/mutations" "$FLUXENV_TEST_ROOT/failed-mutations"
unset FLUXENV_TEST_FAIL_HF
run_fluxenv --non-interactive || fail 'resume after hf failure'
[ "$(grep -c '^brew install' "$FLUXENV_TEST_ROOT/mutations")" = 1 ] || fail 'resume reinstalled successful packages'
[ -f "$FLUXENV_TEST_ROOT/state/initialized" ] || fail 'resumed run not complete'
printf 'PASS: failure records history and retry reuses completed package installation\n'

new_case hf_auth
python3 "$ROOT_DIR/tests/macos/interactive.py" "$ROOT_DIR/scripts/fluxenv" auth || fail 'hf device authorization'
[ -f "$FLUXENV_TEST_ROOT/hf-authenticated" ] || fail 'authentication not completed'
! grep -q TEST-CODE "$FLUXENV_TEST_ROOT/state/history.tsv" || fail 'device code leaked to history'
python3 "$ROOT_DIR/tests/macos/interactive.py" "$ROOT_DIR/scripts/fluxenv" auth_reuse || fail 'hf auth reuse'
[ "$(grep -c '^hf auth login' "$FLUXENV_TEST_ROOT/mutations")" = 1 ] || fail 'authenticated run prompted login again'
printf 'PASS: browser/device authorization and existing login reuse, with no code in history\n'

new_case dry_run
run_fluxenv --dry-run --with-vim --device-name '我的 MacBook' --local-hostname my-macbook || fail 'dry run'
assert_no_mutations
[ ! -e "$FLUXENV_TEST_ROOT/config dir" ] && [ ! -e "$FLUXENV_TEST_ROOT/state" ] || fail 'dry run wrote config/state'
assert_contains "$FLUXENV_TEST_ROOT/output" 'sudo scutil --set HostName my-macbook'
printf 'PASS: dry run does not write, download or elevate privileges\n'

new_case rename
run_fluxenv --non-interactive --device-name '我的 MacBook' --local-hostname my-macbook || fail rename
[ "$(cat "$FLUXENV_TEST_ROOT/names/ComputerName")" = '我的 MacBook' ] || fail 'display name'
[ "$(cat "$FLUXENV_TEST_ROOT/names/HostName")" = my-macbook ] || fail hostname
name_backup=("$FLUXENV_TEST_ROOT"/state/device-name.*)
assert_contains "${name_backup[0]}" 'ComputerName=Old Mac'
assert_contains "${name_backup[0]}" 'HostName='
printf 'PASS: Unicode display name, hostname and original-name snapshot\n'

new_case rollback
export FLUXENV_TEST_FAIL_NAME_KEY=LocalHostName
if run_fluxenv --non-interactive --device-name 'New Mac'; then fail 'rename failure accepted'; fi
[ "$(cat "$FLUXENV_TEST_ROOT/names/ComputerName")" = 'Old Mac' ] || fail 'ComputerName rollback'
[ "$(cat "$FLUXENV_TEST_ROOT/names/LocalHostName")" = old-mac ] || fail 'LocalHostName rollback'
[ ! -s "$FLUXENV_TEST_ROOT/names/HostName" ] || fail 'unset HostName rollback'
printf 'PASS: failed rename restores all original names, including unset HostName\n'

new_case skip
run_fluxenv --non-interactive --device-name ignored --skip-device-name || fail 'skip rename'
! grep -q sudo "$FLUXENV_TEST_ROOT/mutations" || fail 'skip flag renamed device'
printf 'PASS: skip-device-name overrides explicit rename\n'

new_case interactive
python3 "$ROOT_DIR/tests/macos/interactive.py" "$ROOT_DIR/scripts/fluxenv" rename || fail 'interactive rename'
[ "$(cat "$FLUXENV_TEST_ROOT/names/ComputerName")" = '交互测试 Mac' ] || fail 'interactive display name'
[ "$(cat "$FLUXENV_TEST_ROOT/names/HostName")" = interactive-mac ] || fail 'interactive hostname'
printf 'PASS: interactive rename, invalid-input retries and final confirmation\n'

new_case interactive_cancel
python3 "$ROOT_DIR/tests/macos/interactive.py" "$ROOT_DIR/scripts/fluxenv" cancel || fail 'interactive cancel'
[ "$(cat "$FLUXENV_TEST_ROOT/names/ComputerName")" = 'Old Mac' ] || fail 'cancel changed name'
! grep -q sudo "$FLUXENV_TEST_ROOT/mutations" || fail 'cancel invoked sudo'
printf 'PASS: declining confirmation leaves the device name unchanged\n'

new_case intel
export FLUXENV_TEST_ARCH=x86_64
run_fluxenv --dry-run || fail 'Intel path'
assert_contains "$FLUXENV_TEST_ROOT/output" x86_64
printf 'PASS: Intel Mac dispatch\n'

new_case errors
for arguments in '--device-name' '--config' '--profile normal' '--profile' '--unknown'; do
    # These intentionally contain only fixed options, with no user input.
    if run_fluxenv $arguments; then fail "accepted invalid options: $arguments"; fi
done
if run_fluxenv --dry-run --device-name '   '; then fail 'blank name accepted'; fi
if run_fluxenv --dry-run --device-name $'name\nother'; then fail 'multiline name accepted'; fi
if run_fluxenv --dry-run --device-name Mac --local-hostname=-invalid; then fail 'bad hostname accepted'; fi
if run_fluxenv --dry-run --device-name Mac --local-hostname 'bad name'; then fail 'hostname with spaces accepted'; fi
if run_fluxenv --dry-run --local-hostname lonely; then fail 'hostname without display name accepted'; fi
export FLUXENV_TEST_UID=0
if run_fluxenv --dry-run; then fail 'root accepted'; fi
unset FLUXENV_TEST_UID
export FLUXENV_TEST_NO_CLT=1
if run_fluxenv --non-interactive; then fail 'missing CLT accepted'; fi
unset FLUXENV_TEST_NO_CLT
export FLUXENV_TEST_OS=Linux
if /bin/bash "$ROOT_DIR/scripts/fluxenv-macos" --dry-run > "$FLUXENV_TEST_ROOT/output" 2>&1; then fail 'Linux accepted'; fi
if /bin/bash "$ROOT_DIR/scripts/fluxenv" --profile macos > "$FLUXENV_TEST_ROOT/output" 2>&1; then fail 'Linux macos profile accepted'; fi
assert_contains "$FLUXENV_TEST_ROOT/output" 'macos profile'
assert_no_mutations
printf 'PASS: invalid options/names, root, missing CLT and Linux rejection\n'

new_case symlink
printf 'untouched\n' > "$FLUXENV_TEST_ROOT/target"
ln -s "$FLUXENV_TEST_ROOT/target" "$FLUXENV_TEST_ROOT/user/.zshrc"
if run_fluxenv --non-interactive; then fail 'symlink accepted'; fi
assert_contains "$FLUXENV_TEST_ROOT/target" untouched
assert_no_mutations
printf 'PASS: symlink protection\n'

new_case broken_block
printf '# >>> fluxenv macos >>>\n' > "$FLUXENV_TEST_ROOT/user/.zshrc"
if run_fluxenv --non-interactive; then fail 'broken block accepted'; fi
assert_no_mutations
printf 'PASS: malformed managed block rejected before installation\n'

new_case package_failure
export FLUXENV_TEST_FAIL_BREW=1
if run_fluxenv --non-interactive; then fail 'package failure accepted'; fi
[ ! -e "$FLUXENV_TEST_ROOT/config dir" ] || fail 'package failure still configured shell'
printf 'PASS: failed package installation stops the workflow\n'

new_case homebrew_bootstrap
export FLUXENV_TEST_BOOTSTRAP=1
run_homebrew_stage || { cat "$FLUXENV_TEST_ROOT/output"; fail 'Homebrew bootstrap'; }
[ -x "$FLUXENV_TEST_ROOT/brew prefix/bin/brew" ] || fail 'bootstrap did not discover installed brew'
assert_contains "$FLUXENV_TEST_ROOT/mutations" https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh
printf 'PASS: official Homebrew installer flow and post-install discovery\n'

new_case no_homebrew
export FLUXENV_TEST_INSTALL_HOMEBREW=0
if run_homebrew_stage; then fail 'missing Homebrew accepted'; fi
assert_no_mutations
unset FLUXENV_TEST_INSTALL_HOMEBREW
export FLUXENV_TEST_DRY_RUN=1
run_homebrew_stage || fail 'fresh Homebrew preview'
assert_no_mutations
unset FLUXENV_TEST_DRY_RUN
if run_homebrew_stage; then fail 'failed installer download accepted'; fi
[ ! -x "$FLUXENV_TEST_ROOT/brew prefix/bin/brew" ] || fail 'failed download installed brew'
printf 'PASS: missing Homebrew, fresh-install preview and failed-download handling\n'

printf 'All macOS installer checks passed.\n'
