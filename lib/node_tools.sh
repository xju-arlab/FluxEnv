#!/bin/bash

# User-scoped JavaScript toolchain. nvm owns Node versions; Corepack owns pnpm.

validate_javascript_tools_config() {
    NVM_VERSION="${NVM_VERSION:-0.39.7}"
    NODE_VERSION="${NODE_VERSION:-24}"
    PNPM_VERSION="${PNPM_VERSION:-latest}"
    [[ "$NVM_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "NVM_VERSION 必须是版本号"
    [[ "$NODE_VERSION" =~ ^[0-9]+$ ]] && [ "$NODE_VERSION" -ge 24 ] || die "NODE_VERSION 必须是 24 或更高的主版本"
    [[ "$PNPM_VERSION" =~ ^(latest|[0-9]+(\.[0-9]+){0,2})$ ]] || die "PNPM_VERSION 必须是 latest 或版本号"
}

node_tool_paths() {
    validate_javascript_tools_config
    NVM_DIR="${NVM_DIR:-$TARGET_HOME/.nvm}"
    PNPM_HOME="${PNPM_HOME:-$TARGET_HOME/.local/share/pnpm}"
    [[ "$NVM_DIR" = /* ]] || die "NVM_DIR 必须是绝对路径: $NVM_DIR"
    [[ "$PNPM_HOME" = /* ]] || die "PNPM_HOME 必须是绝对路径: $PNPM_HOME"
    [ ! -L "$NVM_DIR" ] || die "NVM_DIR 不能是符号链接: $NVM_DIR"
    [ ! -L "$PNPM_HOME" ] || die "PNPM_HOME 不能是符号链接: $PNPM_HOME"
}

node_user_script() {
    user_cmd env NVM_DIR="$NVM_DIR" PNPM_HOME="$PNPM_HOME" PATH="$PNPM_HOME/bin:$PNPM_HOME:$PATH" \
        NODE_VERSION="${NODE_VERSION:-24}" NVM_VERSION="${NVM_VERSION:-0.39.7}" \
        PNPM_VERSION="${PNPM_VERSION:-latest}" GITCODE_CLI_SPEC="${GITCODE_CLI_SPEC:-atomgit-cli@latest}" \
        COREPACK_ENABLE_PROJECT_SPEC=0 COREPACK_ENABLE_DOWNLOAD_PROMPT=0 GC_NO_UPDATE_CHECK=1 \
        ALLOW_ONLINE_FETCH="${ALLOW_ONLINE_FETCH:-1}" "$@" /bin/bash --noprofile --norc -s
}

node_toolchain_ready() {
    node_tool_paths
    node_user_script COREPACK_ENABLE_NETWORK=0 <<'NODE_STATUS'
set -e
[ -s "$NVM_DIR/nvm.sh" ] || exit 1
. "$NVM_DIR/nvm.sh"
nvm use --silent default >/dev/null 2>&1 || exit 1
node_major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null)"
[ "$node_major" = "$NODE_VERSION" ] || exit 1
command -v corepack >/dev/null 2>&1 || exit 1
corepack --version >/dev/null 2>&1 || exit 1
command -v pnpm >/dev/null 2>&1 || exit 1
pnpm_version="$(pnpm --version 2>/dev/null)" || exit 1
case "$PNPM_VERSION" in
    latest) ;;
    *) case "$pnpm_version" in "$PNPM_VERSION"|"$PNPM_VERSION".*) ;; *) exit 1 ;; esac ;;
esac
NODE_STATUS
}

install_node_toolchain() {
    STATE_CURRENT_RESOURCE=tools/nvm
    node_tool_paths
    if node_toolchain_ready; then
        progress "复用 Node.js ${NODE_VERSION}、nvm、Corepack 和 pnpm"
        state_record tools/nvm reused
        state_record tools/node reused
        state_record tools/corepack reused
        state_record tools/pnpm reused
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        progress "[dry-run] 在 $TARGET_HOME 安装 nvm ${NVM_VERSION}，安装并设为默认 Node.js ${NODE_VERSION}"
        progress "[dry-run] corepack enable && corepack prepare pnpm@${PNPM_VERSION} --activate"
        return 0
    fi
    progress "为 $TARGET_USER 安装 nvm ${NVM_VERSION}、Node.js ${NODE_VERSION} 和 pnpm"
    node_user_script <<'NODE_INSTALL'
set -e
mkdir -p "$PNPM_HOME"
if [ ! -s "$NVM_DIR/nvm.sh" ]; then
    [ "$ALLOW_ONLINE_FETCH" = 1 ] || { echo "缺少 nvm 且禁用在线下载" >&2; exit 1; }
    mkdir -p "$NVM_DIR"
    installer="$(mktemp "${TMPDIR:-/tmp}/fluxenv-nvm.XXXXXX")"
    trap 'rm -f "$installer"' EXIT
    curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/v${NVM_VERSION}/install.sh" -o "$installer"
    NODE_VERSION= PROFILE=/dev/null NVM_DIR="$NVM_DIR" bash "$installer"
    rm -f "$installer"
fi
[ -s "$NVM_DIR/nvm.sh" ] || { echo "nvm 安装后缺少 nvm.sh" >&2; exit 1; }
. "$NVM_DIR/nvm.sh"
if ! nvm version "$NODE_VERSION" >/dev/null 2>&1 || [ "$(nvm version "$NODE_VERSION")" = "N/A" ]; then
    [ "$ALLOW_ONLINE_FETCH" = 1 ] || { echo "缺少 Node.js $NODE_VERSION 且禁用在线下载" >&2; exit 1; }
    nvm install -b "$NODE_VERSION"
fi
if [ "$(nvm version default 2>/dev/null || true)" != "$(nvm version "$NODE_VERSION")" ]; then
    nvm alias default "$NODE_VERSION"
fi
nvm use --silent "$NODE_VERSION" >/dev/null
command -v node >/dev/null 2>&1
[ "$(node -p 'process.versions.node.split(".")[0]')" = "$NODE_VERSION" ]
if ! command -v corepack >/dev/null 2>&1 || ! corepack --version >/dev/null 2>&1; then
    [ "$ALLOW_ONLINE_FETCH" = 1 ] || { echo "缺少 Corepack 且禁用在线下载" >&2; exit 1; }
    npm install --global corepack@latest
fi
corepack enable pnpm
pnpm_ready=0
pnpm_version="$(COREPACK_ENABLE_NETWORK=0 pnpm --version 2>/dev/null || true)"
if [ -n "$pnpm_version" ]; then
    case "$PNPM_VERSION" in
        latest) pnpm_ready=1 ;;
        *) case "$pnpm_version" in "$PNPM_VERSION"|"$PNPM_VERSION".*) pnpm_ready=1 ;; esac ;;
    esac
fi
if [ "$pnpm_ready" = 0 ]; then
    [ "$ALLOW_ONLINE_FETCH" = 1 ] || { echo "缺少 pnpm 且禁用在线下载" >&2; exit 1; }
    if corepack install --global "pnpm@${PNPM_VERSION}" >/dev/null 2>&1; then
        :
    else
        if ! corepack prepare "pnpm@${PNPM_VERSION}" --activate; then
            npm install --global corepack@latest
            corepack enable pnpm
            corepack prepare "pnpm@${PNPM_VERSION}" --activate
        fi
    fi
fi
command -v pnpm >/dev/null 2>&1
pnpm --version >/dev/null 2>&1
NODE_INSTALL
    state_record tools/nvm applied
    state_record tools/node applied
    state_record tools/corepack applied
    state_record tools/pnpm applied
}

gitcode_ready() {
    node_tool_paths
    node_user_script <<'GITCODE_STATUS'
set -e
[ -s "$NVM_DIR/nvm.sh" ] || exit 1
. "$NVM_DIR/nvm.sh"
nvm use --silent default >/dev/null 2>&1
command -v pnpm >/dev/null 2>&1
command -v gc >/dev/null 2>&1
gc version >/dev/null 2>&1 || gc --version >/dev/null 2>&1
gc auth login --help >/dev/null 2>&1
GITCODE_STATUS
}

install_gitcode_cli() {
    STATE_CURRENT_RESOURCE=tools/gitcode
    node_tool_paths
    if gitcode_ready; then
        progress "复用 GitCode CLI（gc）"
        state_record tools/gitcode reused
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        progress "[dry-run] pnpm add -g ${GITCODE_CLI_SPEC:-atomgit-cli@latest}"
        return 0
    fi
    [ "${ALLOW_ONLINE_FETCH:-1}" -eq 1 ] || die "缺少 GitCode CLI（gc），且 ALLOW_ONLINE_FETCH=0"
    progress "通过 pnpm 安装 GitCode CLI（gc auth login）"
    node_user_script <<'GITCODE_INSTALL'
set -e
. "$NVM_DIR/nvm.sh"
nvm use --silent default >/dev/null
mkdir -p "$PNPM_HOME"
pnpm add --global "${GITCODE_CLI_SPEC:-atomgit-cli@latest}"
command -v gc >/dev/null 2>&1
gc version >/dev/null 2>&1 || gc --version >/dev/null 2>&1
gc auth login --help >/dev/null 2>&1
GITCODE_INSTALL
    state_record tools/gitcode applied
}

install_javascript_tools() {
    install_node_toolchain
    install_gitcode_cli
}
