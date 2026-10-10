#!/bin/bash

system_uv_runs() {
    local install_dir="${UV_INSTALL_DIR:-/usr/local/bin}"

    [ -x "$install_dir/uv" ] && "$install_dir/uv" --version >/dev/null 2>&1
}

install_uv_system() {
    local install_dir="${UV_INSTALL_DIR:-/usr/local/bin}"
    local offline_installer="$OFFLINE_DIR/uv-install.sh"
    local offline_installer_found=0
    local quoted_install_dir=""

    if command_exists uv && uv --version >/dev/null 2>&1; then
        UV_BIN="$(command -v uv)"
        progress "复用已有 uv"
        state_record tools/uv reused
        return 0
    fi
    if system_uv_runs; then
        UV_BIN="$install_dir/uv"
        progress "uv 已安装: $("$install_dir/uv" --version 2>/dev/null)"
        state_record tools/uv reused
        return 0
    fi

    run_cmd "创建 uv 系统安装目录" mkdir -p "$install_dir"

    if [ -f "$offline_installer" ]; then
        offline_installer_found=1
        if try_cmd "执行离线 uv 安装脚本" env UV_INSTALL_DIR="$install_dir" UV_NO_MODIFY_PATH=1 sh "$offline_installer"; then
            if [ "$DRY_RUN" -eq 1 ] || system_uv_runs; then
                UV_BIN="$install_dir/uv"
                state_record tools/uv applied
                return 0
            fi
        fi
    fi

    if [ "$ALLOW_ONLINE_FETCH" -eq 1 ]; then
        printf -v quoted_install_dir "%q" "$install_dir"
        run_shell "在线安装 uv 到 $install_dir" "set -o pipefail; curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=$quoted_install_dir UV_NO_MODIFY_PATH=1 sh"
        [ "$DRY_RUN" -eq 1 ] || system_uv_runs || die "uv 安装后无法运行"
        UV_BIN="$install_dir/uv"
        state_record tools/uv applied
        return 0
    fi

    if [ "$offline_installer_found" -eq 1 ]; then
        warn "uv 离线安装失败，且 ALLOW_ONLINE_FETCH=0，已跳过 uv 安装"
    else
        warn "缺少离线资源: uv-install.sh，且 ALLOW_ONLINE_FETCH=0，已跳过 uv 安装"
    fi
    die "必须安装 uv 后才能安装 Hugging Face CLI；可设置 ALLOW_ONLINE_FETCH=1"
}

step_uv() {
    stage "uv 系统安装"

    install_uv_system
}
