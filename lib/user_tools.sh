#!/bin/bash

validate_user_tools_config() {
    case "${HF_LOGIN:-ask}" in
        ask|0|1) ;;
        *) die "HF_LOGIN 必须是 ask、0 或 1" ;;
    esac
    [[ "${HF_TOOL_SPEC:-huggingface_hub>=1.20}" =~ ^huggingface_hub([\<\>\=\!\~].*|$) ]] ||
        die "HF_TOOL_SPEC 必须使用官方 huggingface_hub 包"
    if [ "${HF_LOGIN:-ask}" = 1 ] && [ "${DRY_RUN:-0}" -eq 0 ] && [ "${INTERACTIVE:-1}" -eq 0 ]; then
        die "设备码登录需要你完成浏览器授权，请在终端运行 hf auth login；非交互安装请使用 --skip-hf-login"
    fi
}

user_cmd() {
    if [ "$(id -un)" = "$TARGET_USER" ]; then
        "$@"
    else
        runuser -u "$TARGET_USER" -- "$@"
    fi
}

uv_tool_cmd() {
    local offline="${UV_OFFLINE:-false}"
    [ "${ALLOW_ONLINE_FETCH:-1}" -ne 0 ] || offline=true
    if [ -n "${FLUXENV_TOOL_BIN_DIR:-}" ]; then
        user_cmd env UV_OFFLINE="$offline" UV_TOOL_BIN_DIR="$FLUXENV_TOOL_BIN_DIR" "$UV_BIN" "$@"
    else
        user_cmd env UV_OFFLINE="$offline" "$UV_BIN" "$@"
    fi
}

hf_cmd() {
    user_cmd env HF_HUB_DISABLE_UPDATE_CHECK=1 "$HF_BIN" "$@"
}

hf_supports_device_login() {
    [ -n "${HF_BIN:-}" ] && [ -x "$HF_BIN" ] || return 1
    local version=""
    version="$(hf_cmd version 2>/dev/null)" || return 1
    if [[ "$version" =~ ([0-9]+)\.([0-9]+)\. ]]; then
        [ "${BASH_REMATCH[1]}" -gt 1 ] ||
            { [ "${BASH_REMATCH[1]}" -eq 1 ] && [ "${BASH_REMATCH[2]}" -ge 20 ]; }
    else
        return 1
    fi
}

install_huggingface_tool() {
    STATE_CURRENT_RESOURCE=tools/huggingface
    if [ -z "${UV_BIN:-}" ]; then
        UV_BIN="$(command -v uv || true)"
    fi
    if [ "${DRY_RUN:-0}" -eq 1 ] && [ -z "$UV_BIN" ]; then
        UV_BIN=uv
    fi
    [ -n "$UV_BIN" ] || die "需要先成功安装 uv"
    if [ "${DRY_RUN:-0}" -eq 0 ]; then
        "$UV_BIN" --version >/dev/null || die "uv 无法运行"
    fi
    if [ "${DRY_RUN:-0}" -eq 0 ] || [ -x "$UV_BIN" ]; then
        UV_TOOL_BIN="$(uv_tool_cmd tool dir --bin)" || die "无法读取 uv 工具可执行目录"
    else
        UV_TOOL_BIN="${FLUXENV_TOOL_BIN_DIR:-$TARGET_HOME/.local/bin}"
    fi
    [[ "$UV_TOOL_BIN" = /* ]] || die "uv 工具目录必须是绝对路径: $UV_TOOL_BIN"
    HF_BIN="$UV_TOOL_BIN/hf"
    if [ ! -x "$HF_BIN" ] && [ "$(id -un)" = "$TARGET_USER" ]; then
        HF_BIN="$(command -v hf || true)"
    fi
    if hf_supports_device_login; then
        progress "复用已有 Hugging Face CLI（支持设备码登录）"
        state_record tools/huggingface reused
        return 0
    fi
    if [ "${DRY_RUN:-0}" -eq 1 ]; then
        progress "[dry-run] uv tool install '${HF_TOOL_SPEC:-huggingface_hub>=1.20}'（当前用户: ${TARGET_USER}）"
        return 0
    fi
    local installed=""
    installed="$(uv_tool_cmd tool list)" || die "无法读取 uv 工具清单"
    progress "使用 uv 为 $TARGET_USER 安装支持设备码登录的 hf"
    if grep -Eq '^hf v' <<< "$installed"; then
        uv_tool_cmd tool upgrade --reinstall hf
    elif grep -Eq '^huggingface[-_]hub v' <<< "$installed"; then
        uv_tool_cmd tool install --reinstall --upgrade "${HF_TOOL_SPEC:-huggingface_hub>=1.20}"
    else
        uv_tool_cmd tool install "${HF_TOOL_SPEC:-huggingface_hub>=1.20}"
    fi
    HF_BIN="$UV_TOOL_BIN/hf"
    hf_supports_device_login || die "hf 安装后无法运行或版本尚不支持设备码登录（需 >=1.20）"
    state_record tools/huggingface applied
}

offer_huggingface_login() {
    if [ "${HF_LOGIN:-ask}" = 0 ]; then
        state_record auth/huggingface skipped
        return 0
    fi
    if [ "${DRY_RUN:-0}" -eq 1 ]; then
        progress "[dry-run] 可选 hf auth login：浏览器设备码登录；已有登录会复用"
        return 0
    fi
    if [ "${INTERACTIVE:-1}" -eq 0 ]; then
        progress "Hugging Face 已安装；需要时执行 hf auth login"
        return 0
    fi
    if hf_cmd auth whoami >/dev/null 2>&1; then
        progress "Hugging Face 已登录，复用当前登录"
        state_record auth/huggingface reused
        return 0
    fi
    if [ "${HF_LOGIN:-ask}" = ask ]; then
        prompt_yes_no "是否现在用浏览器设备码登录 Hugging Face？" n || {
            state_record auth/huggingface skipped
            return 0
        }
    fi
    progress "选择 Log in with your browser，按 hf 输出的地址和设备码完成授权"
    # Authentication output goes directly to the terminal, never to history.
    hf_cmd auth login
    state_record auth/huggingface applied
}
