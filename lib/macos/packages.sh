#!/bin/bash

step_macos_developer_tools() {
    stage "Apple 命令行开发工具"
    if xcode-select -p >/dev/null 2>&1 && xcrun --find clang >/dev/null 2>&1; then
        progress "已安装，使用系统的 Clang / Git / make 开发工具"
        state_record tools/developer-tools reused
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        run_cmd "通过 macOS 安装命令行开发工具" xcode-select --install
        progress "实际运行需完成系统安装窗口，再重新执行 FluxEnv"
        return 0
    fi
    [ "$INTERACTIVE" -eq 1 ] || die "请先运行 xcode-select --install，完成安装后重试"
    prompt_yes_no "未找到开发工具，是否打开 Apple 安装窗口？" y || die "需先安装 Apple 命令行开发工具"
    xcode-select --install || die "无法打开安装窗口，请在系统设置中检查命令行开发工具"
    die "请完成系统安装窗口后，重新运行 FluxEnv"
}

macos_find_homebrew() {
    if [ -n "${MACOS_BREW_BIN:-}" ]; then
        [ -x "$MACOS_BREW_BIN" ] || die "指定的 Homebrew 不可执行: $MACOS_BREW_BIN"
        BREW_BIN="$MACOS_BREW_BIN"
    elif [ -x "$BREW_DEFAULT_PREFIX/bin/brew" ]; then
        BREW_BIN="$BREW_DEFAULT_PREFIX/bin/brew"
    elif command_exists brew; then
        BREW_BIN="$(command -v brew)"
    else
        return 1
    fi
    BREW_PREFIX="$("$BREW_BIN" --prefix)" || die "无法读取 Homebrew 安装目录"
    [[ "$BREW_PREFIX" = /* ]] || die "Homebrew 返回了无效路径: $BREW_PREFIX"
    if [ "$ARCH" = "arm64" ] && [ "$BREW_PREFIX" = "/usr/local" ]; then
        die "检测到 Intel Homebrew，请先在 Apple Silicon 上安装原生 /opt/homebrew 版本"
    fi
    if [ "$ARCH" = "x86_64" ] && [ "$BREW_PREFIX" = "/opt/homebrew" ]; then
        die "Intel Mac 不能使用 Apple Silicon Homebrew"
    fi
    return 0
}

step_macos_homebrew() {
    STATE_CURRENT_RESOURCE=tools/homebrew
    stage "Homebrew 安装检查"
    local action=reused
    if ! macos_find_homebrew; then
        [ "$INSTALL_HOMEBREW" -eq 1 ] || die "未安装 Homebrew，且 INSTALL_HOMEBREW=0"
        if [ "$DRY_RUN" -eq 1 ]; then
            BREW_PREFIX="$BREW_DEFAULT_PREFIX"
            BREW_BIN="$BREW_PREFIX/bin/brew"
            progress "将从 https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh 安装 Homebrew"
        else
            local installer=""
            installer="$(mktemp "${TMPDIR:-/tmp}/fluxenv-homebrew.XXXXXX")"
            if ! curl -fsSL --retry 3 https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh -o "$installer"; then
                rm -f "$installer"
                die "Homebrew 安装器下载失败"
            fi
            if [ "$INTERACTIVE" -eq 1 ]; then
                if ! /bin/bash "$installer"; then
                    rm -f "$installer"
                    die "Homebrew 安装失败"
                fi
            elif ! env NONINTERACTIVE=1 /bin/bash "$installer"; then
                rm -f "$installer"
                die "Homebrew 非交互安装失败；请先以普通用户安装 Homebrew"
            fi
            rm -f "$installer"
            macos_find_homebrew || die "安装后仍未找到 Homebrew"
            action=applied
        fi
    fi
    progress "Homebrew: $BREW_PREFIX"
    if [ "$DRY_RUN" -eq 0 ]; then
        eval "$("$BREW_BIN" shellenv)"
        state_record tools/homebrew "$action"
    fi
}

step_macos_packages() {
    stage "常用工具安装"
    if [ "$ENABLE_VIM" = "ask" ]; then
        local previous_vim=""
        previous_vim="$(state_get choices vim)"
        if [ -n "$previous_vim" ]; then
            ENABLE_VIM="$previous_vim"
            progress "复用上次 Vim 选择: $ENABLE_VIM"
        elif prompt_yes_no "是否安装并配置 Vim 编辑器？" n; then
            ENABLE_VIM=1
        else
            ENABLE_VIM=0
        fi
    fi
    VIM_ENABLED="$ENABLE_VIM"
    state_put choices vim "$VIM_ENABLED"
    if [ "$VIM_ENABLED" -eq 1 ]; then
        macos_validate_block "$MACOS_VIMRC" '" >>> fluxenv macos >>>' '" <<< fluxenv macos <<<'
        macos_require_regular_file "$MACOS_CONFIG_DIR/vimrc-macos"
    fi

    local formula=""
    local formula_bin=""
    local installed=""
    local formulae=()
    local missing=()
    local repair=()
    read -r -a formulae <<< "$MACOS_FORMULAE $MACOS_EXTRA_FORMULAE"
    # Core tools remain required even when the base formula list is customized.
    for formula in uv gh; do
        [[ " $MACOS_FORMULAE $MACOS_EXTRA_FORMULAE " = *" $formula "* ]] || formulae+=("$formula")
    done
    if [ "$VIM_ENABLED" -eq 1 ]; then
        formulae+=(vim astyle)
    fi
    [ "${#formulae[@]}" -gt 0 ] || die "工具清单不能为空"
    for formula in "${formulae[@]}"; do
        [[ "$formula" =~ ^[a-zA-Z0-9][a-zA-Z0-9@._/+\-]*$ ]] || die "无效的 Homebrew formula: $formula"
    done
    if [ -x "$BREW_BIN" ]; then
        installed="$("$BREW_BIN" list --formula)" || die "无法读取已安装工具清单"
    fi
    for formula in "${formulae[@]}"; do
        if [ "$formula" = uv ] || [ "$formula" = gh ]; then
            formula_bin="$(command -v "$formula" || true)"
            if [ -z "$formula_bin" ] || ! "$formula_bin" --version >/dev/null 2>&1; then
                formula_bin="$BREW_PREFIX/bin/$formula"
            fi
            if [ -x "$formula_bin" ] && "$formula_bin" --version >/dev/null 2>&1; then
                progress "复用已有工具: $formula"
                state_record "tools/$formula" reused
                continue
            fi
        fi
        if grep -Fxq "$formula" <<< "$installed"; then
            if [ "$formula" = uv ] || [ "$formula" = gh ]; then
                repair+=("$formula")
                continue
            fi
            progress "已安装: $formula"
            state_record "formula/$formula" reused
        else
            missing+=("$formula")
        fi
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        STATE_CURRENT_RESOURCE=tools/homebrew-formulae
        run_cmd "通过 Homebrew 安装所需工具" env HOMEBREW_NO_INSTALL_UPGRADE=1 "$BREW_BIN" install "${missing[@]}"
        if [ "$DRY_RUN" -eq 0 ]; then
            for formula in "${missing[@]}"; do
                state_record "formula/$formula" applied
            done
        fi
    else
        progress "所需工具均已安装"
    fi
    if [ "${#repair[@]}" -gt 0 ]; then
        STATE_CURRENT_RESOURCE=tools/homebrew-formulae
        run_cmd "修复已安装但无法运行的工具" env HOMEBREW_NO_INSTALL_UPGRADE=1 "$BREW_BIN" reinstall "${repair[@]}"
        if [ "$DRY_RUN" -eq 0 ]; then
            for formula in "${repair[@]}"; do
                state_record "formula/$formula" applied
            done
        fi
    fi
    if [ "$DRY_RUN" -eq 0 ]; then
        UV_BIN="$(command -v uv || true)"
        [ -n "$UV_BIN" ] && "$UV_BIN" --version >/dev/null || die "uv 安装后无法运行"
        command_exists gh && gh --version >/dev/null || die "GitHub CLI 安装后无法运行"
        "$BREW_PREFIX/bin/starship" --version >/dev/null || die "Starship 安装后无法运行"
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        UV_BIN="$(command -v uv || true)"
        [ -n "$UV_BIN" ] || UV_BIN="$BREW_PREFIX/bin/uv"
    fi
}
