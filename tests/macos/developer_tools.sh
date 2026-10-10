#!/bin/bash

# Isolated integration checks for optional tools, recovery and preserved state.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
real_nvim="$(command -v nvim || true)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/fluxenv-developer-tests.XXXXXX")"
checks_finished=0
exec 3>&2
trap 'if [ "$checks_finished" -ne 1 ]; then tail -40 "$test_root/output" >&3 2>/dev/null; rm -rf "$test_root"; exit 1; fi; rm -rf "$test_root"' EXIT
export FLUXENV_DEV_TEST_ROOT="$test_root"
mkdir -p "$test_root/mocks"
cat > "$test_root/mocks/driver" <<'MOCK'
#!/bin/bash
set -euo pipefail
tool="${0##*/}"
case "$tool" in
    brew)
        case "$1" in
            --cache) printf '%s\n' "$FLUXENV_DEV_CASE/mactex.pkg" ;;
            list) cat "$FLUXENV_DEV_CASE/installed" ;;
            fetch)
                printf 'fetch\n' >> "$FLUXENV_DEV_CASE/mutations"
                printf 'package\n' > "$FLUXENV_DEV_CASE/mactex.pkg" ;;
            install|reinstall)
                printf 'brew %s\n' "$*" >> "$FLUXENV_DEV_CASE/mutations"
                shift
                for formula in "$@"; do
                    [ "$formula" != --cask ] || continue
                    printf '%s\n' "$formula" >> "$FLUXENV_DEV_CASE/installed"
                    case "$formula" in
                        neovim) binary="$FLUXENV_DEV_CASE/brew prefix/bin/nvim" ;;
                        ripgrep) binary="$FLUXENV_DEV_CASE/brew prefix/bin/rg" ;;
                        tree-sitter-cli) binary="$FLUXENV_DEV_CASE/brew prefix/bin/tree-sitter" ;;
                        openjdk@21) binary="$FLUXENV_DEV_CASE/brew prefix/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home/bin/java" ;;
                        docker-compose|docker-buildx) binary="$FLUXENV_DEV_CASE/brew prefix/lib/docker/cli-plugins/$formula" ;;
                        mactex)
                            for tex in pdflatex xelatex latexmk; do
                                ln -sf "$FLUXENV_DEV_TEST_ROOT/mocks/driver" "$FLUXENV_DEV_CASE/texbin/$tex"
                            done
                            continue ;;
                        *) binary="$FLUXENV_DEV_CASE/brew prefix/bin/$formula" ;;
                    esac
                    mkdir -p "$(dirname "$binary")"
                    ln -sf "$FLUXENV_DEV_TEST_ROOT/mocks/driver" "$binary"
                done ;;
            *) exit 1 ;;
        esac ;;
    git)
        if [ "$1" = -C ]; then cat "$2/.origin"; exit; fi
        printf 'clone\n' >> "$FLUXENV_DEV_CASE/mutations"
        [ "${FLUXENV_DEV_FAIL_CLONE:-0}" -eq 0 ] || exit 1
        printf '%s\n' "$2" > "$3/.origin"
        printf -- '-- configuration\n' > "$3/init.lua" ;;
    docker)
        case "$1" in
            --version) printf 'Docker test\n' ;;
            info) [ -f "$FLUXENV_DEV_CASE/engine" ] ;;
            context) cat "$FLUXENV_DEV_CASE/context" ;;
            compose|buildx) [ -x "$DOCKER_CONFIG/cli-plugins/docker-$1" ] ;;
            *) exit 1 ;;
        esac ;;
    colima)
        if [ "$1" = start ]; then
            printf 'colima start\n' >> "$FLUXENV_DEV_CASE/mutations"
            touch "$FLUXENV_DEV_CASE/engine"
            printf 'colima\n' > "$FLUXENV_DEV_CASE/context"
        fi ;;
    sudo) [ "${FLUXENV_DEV_SUDO_READY:-0}" -eq 1 ] ;;
    nvim|rg|fd|tree-sitter|java|docker-compose|docker-buildx|pdflatex|xelatex|latexmk) printf 'test 1.0\n' ;;
    *) exit 1 ;;
esac
MOCK
chmod +x "$test_root/mocks/driver"
for tool in git sudo; do ln -s driver "$test_root/mocks/$tool"; done
export PATH="$test_root/mocks:/usr/bin:/bin:/usr/sbin:/sbin"
source "$ROOT_DIR/lib/core.sh"
source "$ROOT_DIR/lib/state.sh"
source "$ROOT_DIR/lib/macos/optional_tools.sh"
source "$ROOT_DIR/lib/macos/neovim.sh"
source "$ROOT_DIR/lib/macos/docker.sh"
source "$ROOT_DIR/lib/macos/mactex.sh"
init_colors
INTERACTIVE=0
DRY_RUN=0
CURRENT_STAGE=0
TOTAL_STAGES=1
ENABLE_NVIM=1
ENABLE_DOCKER=1
ENABLE_MACTEX=1
NVIM_CONFIG_REPO=https://github.com/winbeau/Config-NeoVim.git
NVM_DIR="$test_root/nvm"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
new_case() {
    export FLUXENV_DEV_CASE="$test_root/$1"
    mkdir -p "$FLUXENV_DEV_CASE/brew prefix/bin" "$FLUXENV_DEV_CASE/texbin"
    : > "$FLUXENV_DEV_CASE/installed"
    : > "$FLUXENV_DEV_CASE/mutations"
    printf 'default\n' > "$FLUXENV_DEV_CASE/context"
    BREW_PREFIX="$FLUXENV_DEV_CASE/brew prefix"
    BREW_BIN="$BREW_PREFIX/bin/brew"
    ln -s "$test_root/mocks/driver" "$BREW_BIN"
    MACOS_NVIM_CONFIG_DIR="$FLUXENV_DEV_CASE/config dir/nvim"
    MACOS_DOCKER_CONFIG_DIR="$FLUXENV_DEV_CASE/docker config"
    MACOS_TEX_BIN_DIR="$FLUXENV_DEV_CASE/texbin"
    MACOS_MACTEX_PENDING=0
    state_open "$FLUXENV_DEV_CASE/state" macos
    mkdir -p "$STATE_DIR"
    STATE_ACTIVE=1
}
macos_neovim_run() {
    if [ "$1" = check ]; then [ -f "$FLUXENV_DEV_CASE/plugin" ]; return; fi
    printf 'nvim bootstrap\n' >> "$FLUXENV_DEV_CASE/mutations"
    [ "${FLUXENV_DEV_FAIL_BOOTSTRAP:-0}" -eq 0 ] || return 1
    touch "$FLUXENV_DEV_CASE/plugin"
}

new_case neovim
step_macos_neovim > "$test_root/output" 2>&1 || { cat "$test_root/output"; fail 'NeoVim first install'; }
cp "$FLUXENV_DEV_CASE/mutations" "$test_root/first"
step_macos_neovim > "$test_root/output" 2>&1
cmp "$test_root/first" "$FLUXENV_DEV_CASE/mutations" || fail 'NeoVim repeat mutated installation'
rm "$FLUXENV_DEV_CASE/plugin"
step_macos_neovim > "$test_root/output" 2>&1
[ "$(grep -c 'nvim bootstrap' "$FLUXENV_DEV_CASE/mutations")" -eq 2 ] || fail 'missing plugin not repaired'
[ "$(grep -c '^brew ' "$FLUXENV_DEV_CASE/mutations")" -eq 1 ] || fail 'plugin repair reinstalled packages'
printf -- '-- local edit\n' >> "$MACOS_NVIM_CONFIG_DIR/init.lua"
step_macos_neovim > "$test_root/output" 2>&1
grep -q 'local edit' "$MACOS_NVIM_CONFIG_DIR/init.lua" || fail 'NeoVim local edit lost'
printf 'PASS: NeoVim reuse, missing plugin recovery and local edits\n'

new_case custom_config
mkdir -p "$MACOS_NVIM_CONFIG_DIR"
printf 'custom\n' > "$MACOS_NVIM_CONFIG_DIR/init.lua"
step_macos_neovim > "$test_root/output" 2>&1
[ "$(cat "$MACOS_NVIM_CONFIG_DIR/init.lua")" = custom ] || fail 'custom config replaced'
! grep -q 'clone\|nvim bootstrap' "$FLUXENV_DEV_CASE/mutations" || fail 'custom config bootstrapped'
new_case clone_failure
export FLUXENV_DEV_FAIL_CLONE=1
if (step_macos_neovim) > "$test_root/output" 2>&1; then fail 'clone failure accepted'; fi
[ ! -e "$MACOS_NVIM_CONFIG_DIR" ] || fail 'incomplete clone installed'
unset FLUXENV_DEV_FAIL_CLONE
export FLUXENV_DEV_FAIL_BOOTSTRAP=1
if (step_macos_neovim) > "$test_root/output" 2>&1; then fail 'bootstrap failure accepted'; fi
[ -z "$(state_get receipts "nvim-bootstrap:$MACOS_NVIM_CONFIG_DIR")" ] || fail 'failed bootstrap recorded ready'
unset FLUXENV_DEV_FAIL_BOOTSTRAP
step_macos_neovim > "$test_root/output" 2>&1
[ "$(grep -c '^brew ' "$FLUXENV_DEV_CASE/mutations")" -eq 1 ] || fail 'retry reinstalled dependencies'
printf 'PASS: existing configs preserved; failed NeoVim downloads/bootstrap resume\n'

new_case docker
step_macos_docker > "$test_root/output" 2>&1 || { cat "$test_root/output"; fail 'Docker install'; }
cp "$FLUXENV_DEV_CASE/mutations" "$test_root/first"
step_macos_docker > "$test_root/output" 2>&1
cmp "$test_root/first" "$FLUXENV_DEV_CASE/mutations" || fail 'Docker repeat restarted engine'
rm "$MACOS_DOCKER_CONFIG_DIR/cli-plugins/docker-compose"
step_macos_docker > "$test_root/output" 2>&1
cmp "$test_root/first" "$FLUXENV_DEV_CASE/mutations" || fail 'missing plugin reinstalled formula or engine'
printf 'remote\n' > "$FLUXENV_DEV_CASE/context"
step_macos_docker > "$test_root/output" 2>&1
[ "$(cat "$FLUXENV_DEV_CASE/context")" = remote ] || fail 'existing Docker context replaced'
rm "$FLUXENV_DEV_CASE/engine"
if (step_macos_docker) > "$test_root/output" 2>&1; then fail 'unavailable remote context replaced'; fi
[ "$(grep -c 'colima start' "$FLUXENV_DEV_CASE/mutations")" -eq 1 ] || fail 'Colima started over remote context'
printf 'PASS: Docker plugins repaired, running engines reused, existing contexts preserved\n'

new_case mactex
step_macos_mactex > "$test_root/output" 2>&1
[ "$MACOS_MACTEX_PENDING" -eq 1 ] || fail 'MacTeX needs-password status missing'
! grep -q '^brew ' "$FLUXENV_DEV_CASE/mutations" || fail 'unattended MacTeX prompted for password'
export FLUXENV_DEV_SUDO_READY=1
step_macos_mactex > "$test_root/output" 2>&1
cp "$FLUXENV_DEV_CASE/mutations" "$test_root/first"
step_macos_mactex > "$test_root/output" 2>&1
cmp "$test_root/first" "$FLUXENV_DEV_CASE/mutations" || fail 'MacTeX installed twice'
unset FLUXENV_DEV_SUDO_READY
printf 'PASS: MacTeX download without password, privileged install and reuse\n'

new_case preview
DRY_RUN=1
step_macos_neovim > "$test_root/output" 2>&1
step_macos_docker >> "$test_root/output" 2>&1
step_macos_mactex >> "$test_root/output" 2>&1
[ ! -s "$FLUXENV_DEV_CASE/mutations" ] || fail 'optional tool preview modified system'
[ ! -e "$MACOS_NVIM_CONFIG_DIR" ] && [ ! -e "$MACOS_DOCKER_CONFIG_DIR" ] || fail 'preview wrote configuration'
printf 'PASS: optional tool preview does not download, install or start engines\n'

# Exercise the real, network-free Lua readiness checker when NeoVim is present.
if [ -n "$real_nvim" ]; then
    mkdir -p "$test_root/data/nvim"
    printf '#!/bin/bash\nexit 0\n' > "$test_root/executable"
    chmod +x "$test_root/executable"
    python3 - "$test_root" <<'PY'
import json, sys
from pathlib import Path
root = Path(sys.argv[1])
(root / 'data/nvim/fluxenv-ready.json').write_text(json.dumps({
    'schema': 1, 'paths': [str(root / 'executable')], 'executables': [str(root / 'executable')]
}))
PY
    check_manifest() {
        env XDG_DATA_HOME="$test_root/data" XDG_STATE_HOME="$test_root/state" XDG_CONFIG_HOME="$test_root/config" \
            NVIM_APPNAME=nvim FLUXENV_NVIM_MODE=check FLUXENV_NVIM_BOOTSTRAP="$ROOT_DIR/config/nvim-bootstrap.lua" \
            "$real_nvim" -u NONE -i NONE --headless '+lua dofile(vim.env.FLUXENV_NVIM_BOOTSTRAP)' +qa > "$test_root/output" 2>&1
    }
    check_manifest || fail 'valid manifest rejected'
    chmod -x "$test_root/executable"
    if check_manifest; then fail 'broken executable accepted'; fi
    rm "$test_root/executable"
    if check_manifest; then fail 'missing resource accepted'; fi
    printf 'PASS: real NeoVim readiness check detects missing resources and executables\n'
fi
checks_finished=1
