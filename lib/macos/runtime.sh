#!/bin/bash

macos_require_regular_file() {
    local path="$1"
    [ ! -L "$path" ] || die "配置文件是符号链接，请先手动处理: $path"
    if [ -e "$path" ] && [ ! -f "$path" ]; then
        die "配置路径不是普通文件: $path"
    fi
}

macos_validate_block() {
    local path="$1"
    local start="$2"
    local end="$3"
    macos_require_regular_file "$path"
    [ -f "$path" ] || return 0
    awk -v start="$start" -v end="$end" '
        $0 == start { if (inside || seen) bad=1; inside=1; seen=1 }
        $0 == end { if (!inside) bad=1; inside=0 }
        END { exit (bad || inside) ? 1 : 0 }
    ' "$path" || die "托管标记不完整或重复，请先修复: $path"
}

macos_prepare_backups() {
    [ -z "$BACKUP_DIR" ] || return 0
    if [ "$DRY_RUN" -eq 1 ]; then
        BACKUP_DIR="$MACOS_STATE_DIR/backups/<本次安装>"
        progress "备份目录: $BACKUP_DIR"
        return 0
    fi
    mkdir -p "$MACOS_STATE_DIR/backups"
    BACKUP_DIR="$(mktemp -d "$MACOS_STATE_DIR/backups/$(date +%Y%m%d_%H%M%S).XXXXXX")"
    chmod 700 "$BACKUP_DIR"
}

macos_backup_file() {
    local path="$1"
    local label="$2"
    macos_require_regular_file "$path"
    [ -f "$path" ] || return 0
    run_cmd "备份 $path" cp -p "$path" "$BACKUP_DIR/$label"
}

macos_write_file() {
    local path="$1"
    local label="$2"
    local temporary=""
    macos_require_regular_file "$path"
    if [ "$DRY_RUN" -eq 1 ]; then
        progress "写入 $path"
        cat >/dev/null
        return 0
    fi
    macos_backup_file "$path" "$label"
    temporary="$(mktemp "${path}.tmp.XXXXXX")"
    if ! cat > "$temporary" || ! chmod 600 "$temporary" || ! mv -f "$temporary" "$path"; then
        rm -f "$temporary"
        die "无法写入 $path"
    fi
}

macos_update_block() {
    local path="$1"
    local start="$2"
    local end="$3"
    local body="$4"
    local label="$5"
    local temporary=""
    local input="/dev/null"
    macos_validate_block "$path" "$start" "$end"
    if [ "$DRY_RUN" -eq 1 ]; then
        progress "更新托管配置块: $path"
        return 0
    fi
    macos_backup_file "$path" "$label"
    temporary="$(mktemp "${path}.tmp.XXXXXX")"
    [ ! -f "$path" ] || input="$path"
    # Pass the body through ENVIRON, so awk does not interpret shell escapes.
    if ! FLUXENV_BLOCK_BODY="$body" awk -v start="$start" -v end="$end" '
        $0 == start { print start; print ENVIRON["FLUXENV_BLOCK_BODY"]; print end; inside=1; found=1; next }
        $0 == end { inside=0; next }
        !inside { print }
        END { if (!found) { if (NR) print ""; print start; print ENVIRON["FLUXENV_BLOCK_BODY"]; print end } }
    ' "$input" > "$temporary"; then
        rm -f "$temporary"
        die "无法更新 $path"
    fi
    if ! chmod 600 "$temporary" || ! mv -f "$temporary" "$path"; then
        rm -f "$temporary"
        die "无法保存托管配置: $path"
    fi
}

step_macos_preflight() {
    stage "macOS 环境检查"
    [ "$(uname -s)" = "Darwin" ] || die "此入口只支持 macOS"
    [ "$(id -u)" -ne 0 ] || die "请以当前普通用户运行，不要使用 sudo bash scripts/fluxenv"
    ARCH="$(uname -m)"
    case "$ARCH" in
        arm64) BREW_DEFAULT_PREFIX="/opt/homebrew" ;;
        x86_64) BREW_DEFAULT_PREFIX="/usr/local" ;;
        *) die "暂不支持的 Mac 架构: $ARCH" ;;
    esac
    if [ "$(sysctl -in sysctl.proc_translated 2>/dev/null || true)" = "1" ]; then
        die "请在原生 Apple Silicon 终端中运行，避免安装 Intel 版工具"
    fi
    progress "macOS $(sw_vers -productVersion) / ${ARCH}，当前用户: $TARGET_USER"
    command_exists zsh || die "未找到 macOS 自带的 zsh"
    command_exists curl || die "未找到 curl"

    local path=""
    for path in "$MACOS_CONFIG_DIR" "$MACOS_STATE_DIR" "$MACOS_ZDOTDIR" "$MACOS_VIMRC"; do
        [[ "$path" = /* ]] || die "配置目录必须是绝对路径: $path"
    done
    macos_validate_block "$MACOS_ZDOTDIR/.zprofile" '# >>> fluxenv macos >>>' '# <<< fluxenv macos <<<'
    macos_validate_block "$MACOS_ZDOTDIR/.zshrc" '# >>> fluxenv macos >>>' '# <<< fluxenv macos <<<'
    macos_require_regular_file "$MACOS_CONFIG_DIR/macos.zsh"
    macos_require_regular_file "$MACOS_CONFIG_DIR/starship-macos.toml"

    is_true "$INSTALL_HOMEBREW" && INSTALL_HOMEBREW=1 || INSTALL_HOMEBREW=0
    is_true "$SKIP_DEVICE_NAME" && SKIP_DEVICE_NAME=1 || SKIP_DEVICE_NAME=0
    if [ "$SKIP_DEVICE_NAME" -eq 0 ]; then
        [ -z "$DEVICE_NAME" ] || macos_validate_device_name "$DEVICE_NAME" || die "设备名不能为空白或包含控制字符"
        [ -z "$LOCAL_HOST_NAME" ] || macos_validate_local_hostname "$LOCAL_HOST_NAME" || die "Bonjour 名格式错误"
        [ -z "$LOCAL_HOST_NAME" ] || [ -n "$DEVICE_NAME" ] || die "--local-hostname 需要同时指定设备名"
    fi
    case "$ENABLE_VIM" in
        ask) ;;
        *) is_true "$ENABLE_VIM" && ENABLE_VIM=1 || ENABLE_VIM=0 ;;
    esac
    case "$CHANGE_DEFAULT_SHELL" in
        ask) ;;
        *) is_true "$CHANGE_DEFAULT_SHELL" && CHANGE_DEFAULT_SHELL=1 || CHANGE_DEFAULT_SHELL=0 ;;
    esac
}

step_macos_finalize() {
    stage "完成"
    if [ "$DRY_RUN" -eq 1 ]; then
        progress "预览完成，未执行安装或改名"
        return 0
    fi
    printf '\nFluxEnv macOS 初始化完成\n'
    printf '  用户: %s\n  Homebrew: %s\n  配置: %s\n  备份: %s\n' \
        "$TARGET_USER" "$BREW_PREFIX" "$MACOS_CONFIG_DIR" "$BACKUP_DIR"
    [ -z "$DEVICE_NAME_BACKUP" ] || printf '  改名前记录: %s\n' "$DEVICE_NAME_BACKUP"
    progress "新开终端，或执行 exec /bin/zsh -l"
}
