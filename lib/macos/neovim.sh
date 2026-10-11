#!/bin/bash

macos_validate_neovim_config() {
    [[ "$NVIM_CONFIG_REPO" =~ ^https://github\.com/[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+(\.git)?$ ]] ||
        die "NVIM_CONFIG_REPO 必须是 GitHub HTTPS 仓库地址"
    [[ "$MACOS_NVIM_CONFIG_DIR" = /* ]] || die "NeoVim 配置目录必须是绝对路径"
    [ "$(basename "$MACOS_NVIM_CONFIG_DIR")" = nvim ] || die "NeoVim 配置目录末级名称必须是 nvim"
    [ ! -e "$MACOS_NVIM_CONFIG_DIR" ] || [ -d "$MACOS_NVIM_CONFIG_DIR" ] ||
        die "NeoVim 配置路径不是目录"
}

macos_neovim_formula_ready() {
    case "$1" in
        neovim)
            "$BREW_PREFIX/bin/nvim" -u NONE -i NONE --headless \
                '+lua if vim.fn.has("nvim-0.11.2") ~= 1 then vim.cmd("cquit 1") end' +qa >/dev/null 2>&1 ;;
        ripgrep) "$BREW_PREFIX/bin/rg" --version >/dev/null 2>&1 ;;
        fd) "$BREW_PREFIX/bin/fd" --version >/dev/null 2>&1 ;;
        tree-sitter-cli) "$BREW_PREFIX/bin/tree-sitter" --version >/dev/null 2>&1 ;;
        openjdk@21) "$BREW_PREFIX/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home/bin/java" -version >/dev/null 2>&1 ;;
    esac
}

macos_neovim_packages() {
    macos_ensure_formulae "NeoVim、搜索工具、Tree-sitter 和 Java 21" macos_neovim_formula_ready \
        neovim ripgrep fd tree-sitter-cli openjdk@21
}

macos_neovim_checkout() {
    local origin=""
    local temporary=""
    local resource="nvim-config:$MACOS_NVIM_CONFIG_DIR"
    STATE_CURRENT_RESOURCE="$resource"
    if [ -L "$MACOS_NVIM_CONFIG_DIR" ]; then
        progress "保留符号链接形式的 NeoVim 配置: $MACOS_NVIM_CONFIG_DIR"
        state_record "$resource" preserved
        return 1
    fi
    if [ -d "$MACOS_NVIM_CONFIG_DIR" ]; then
        origin="$(git -C "$MACOS_NVIM_CONFIG_DIR" remote get-url origin 2>/dev/null || true)"
        if [ "${origin%.git}" = "${NVIM_CONFIG_REPO%.git}" ] && [ -s "$MACOS_NVIM_CONFIG_DIR/init.lua" ]; then
            progress "复用 NeoVim 配置仓库和本地改动: $MACOS_NVIM_CONFIG_DIR"
            state_record "$resource" reused
            return 0
        fi
        progress "保留已有 NeoVim 配置: $MACOS_NVIM_CONFIG_DIR"
        state_record "$resource" preserved
        return 1
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        progress "[dry-run] 克隆 $NVIM_CONFIG_REPO 到 $MACOS_NVIM_CONFIG_DIR"
        return 0
    fi
    mkdir -p "$(dirname "$MACOS_NVIM_CONFIG_DIR")"
    temporary="$(mktemp -d "${MACOS_NVIM_CONFIG_DIR}.clone.XXXXXX")"
    if ! git clone "$NVIM_CONFIG_REPO" "$temporary" || [ ! -s "$temporary/init.lua" ]; then
        rm -rf "$temporary"
        die "NeoVim 配置下载失败或缺少 init.lua；重跑会继续安装"
    fi
    mv "$temporary" "$MACOS_NVIM_CONFIG_DIR"
    state_record "$resource" applied
}

macos_neovim_appearance() {
    local path="$MACOS_NVIM_CONFIG_DIR/lua/plugins/zz_fluxenv_ui.lua"
    if [ "$DRY_RUN" -eq 1 ]; then
        progress "[dry-run] 添加 NeoVim 外观和 Apple Terminal 256 色适配"
        return 0
    fi
    managed_install_file "$path" "$ROOT_DIR/config/nvim-fluxenv-ui.lua"
}

macos_neovim_run() {
    local mode="$1"
    env XDG_CONFIG_HOME="$(dirname "$MACOS_NVIM_CONFIG_DIR")" NVIM_APPNAME=nvim \
        NVM_DIR="$NVM_DIR" JAVA21_HOME="${JAVA21_HOME:-$BREW_PREFIX/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home}" \
        FLUXENV_NVIM_MODE="$mode" FLUXENV_NVIM_BOOTSTRAP="$ROOT_DIR/config/nvim-bootstrap.lua" \
        FLUXENV_NVIM_BIN="$BREW_PREFIX/bin/nvim" \
        /bin/bash --noprofile --norc -s <<'NVIM_RUN'
set -e
. "$NVM_DIR/nvm.sh"
nvm use --silent default >/dev/null
export PATH="$JAVA21_HOME/bin:$PATH"
export JAVA_HOME="$JAVA21_HOME"
if [ "$FLUXENV_NVIM_MODE" = check ]; then
    exec "$FLUXENV_NVIM_BIN" -u NONE -i NONE --headless \
        '+lua dofile(vim.env.FLUXENV_NVIM_BOOTSTRAP)' +qa
fi
exec "$FLUXENV_NVIM_BIN" -i NONE --headless \
    --cmd 'lua local p=vim.fn.stdpath("config").."/lazy-lock.json"; if vim.fn.filereadable(p)==1 then vim.g.fluxenv_install_lock=vim.fn.readfile(p) end' \
    '+lua dofile(vim.env.FLUXENV_NVIM_BOOTSTRAP)' +qa
NVIM_RUN
}

macos_neovim_signature() {
    {
        "$BREW_PREFIX/bin/nvim" --version | head -n 1
        state_file_signature "$ROOT_DIR/config/nvim-bootstrap.lua"
        local path=""
        while IFS= read -r path; do
            printf '%s\n' "$path"
            state_file_signature "$path"
        done < <(find "$MACOS_NVIM_CONFIG_DIR" -name .git -prune -o \
            -type f \( -name '*.lua' -o -name lazy-lock.json -o -name lazyvim.json \) -print | sort)
    } | state_signature
}

step_macos_neovim() {
    stage "NeoVim / Config-NeoVim"
    local resource="nvim-bootstrap:$MACOS_NVIM_CONFIG_DIR"
    local signature=""
    if ! macos_choose_optional ENABLE_NVIM nvim "是否安装 NeoVim 和 Config-NeoVim（LazyVim）配置？"; then
        progress "跳过 NeoVim；可用 --with-nvim 安装"
        return 0
    fi
    macos_validate_neovim_config
    macos_neovim_packages
    macos_neovim_checkout || return 0
    macos_neovim_appearance
    if [ "$DRY_RUN" -eq 1 ]; then
        progress "[dry-run] 按 lazy-lock.json 安装插件、语言服务和语法解析器；已安装项复用"
        return 0
    fi
    signature="$(macos_neovim_signature)"
    if [ "$(state_get receipts "$resource")" = "$signature" ] && macos_neovim_run check >/dev/null 2>&1; then
        progress "复用 NeoVim 插件、语言服务和语法解析器"
        state_record "$resource" reused "$signature"
    else
        STATE_CURRENT_RESOURCE="$resource"
        progress "初始化 NeoVim；补齐缺失插件、语言服务和语法解析器"
        macos_neovim_run install || die "NeoVim 初始化失败；已有配置保留，重跑会补齐缺失项"
        macos_neovim_run check || die "NeoVim 初始化后检查未通过"
        signature="$(macos_neovim_signature)"
        state_record "$resource" applied "$signature"
    fi
    progress "NeoVim 已就绪，执行 nvim 启动"
}
