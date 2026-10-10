#!/bin/bash

macos_mactex_ready() {
    local tool=""
    for tool in pdflatex xelatex latexmk; do
        "$MACOS_TEX_BIN_DIR/$tool" --version >/dev/null 2>&1 || return 1
    done
}

step_macos_mactex() {
    stage "MacTeX"
    if ! macos_choose_optional ENABLE_MACTEX mactex "是否安装 MacTeX 完整发行版（下载较大，需要管理员权限）？"; then
        progress "跳过 MacTeX；可用 --with-mactex 安装"
        return 0
    fi
    [[ "$MACOS_TEX_BIN_DIR" = /* ]] || die "TeX 工具目录必须是绝对路径"
    if macos_mactex_ready; then
        state_record tools/mactex reused
        progress "复用已有 TeX 工具"
        return 0
    fi
    STATE_CURRENT_RESOURCE=cask/mactex
    if [ "$DRY_RUN" -eq 1 ]; then
        run_cmd "安装完整 MacTeX" "$BREW_BIN" install --cask mactex
        return 0
    fi
    # Homebrew verifies the official package checksum and reuses its cache.
    local cache=""
    local download_action=applied
    cache="$("$BREW_BIN" --cache --cask mactex)" || die "无法读取 MacTeX 缓存位置"
    [ ! -s "$cache" ] || download_action=reused
    run_cmd "下载并校验 MacTeX 安装包" "$BREW_BIN" fetch --cask mactex
    state_record cask/mactex-download "$download_action" "$cache"
    if [ "$INTERACTIVE" -ne 1 ] && ! sudo -n true 2>/dev/null; then
        state_record tools/mactex skipped
        MACOS_MACTEX_PENDING=1
        warn "MacTeX 已下载并校验；安装需要管理员密码，请执行 brew install --cask mactex"
        return 0
    fi
    local installed=""
    installed="$("$BREW_BIN" list --cask)" || die "无法读取 MacTeX 安装状态"
    if grep -Fxq mactex <<< "$installed"; then
        run_cmd "修复 MacTeX 工具" "$BREW_BIN" reinstall --cask mactex
    else
        run_cmd "安装完整 MacTeX" "$BREW_BIN" install --cask mactex
    fi
    macos_mactex_ready || die "MacTeX 安装后工具检查未通过"
    state_record tools/mactex applied
}
