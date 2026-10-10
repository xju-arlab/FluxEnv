#!/bin/bash

macos_choose_optional() {
    local variable="$1"
    local key="$2"
    local question="$3"
    local value="${!variable}"
    if [ "$value" = ask ]; then
        value="$(state_get choices "$key")"
        if [ -z "$value" ]; then
            if prompt_yes_no "$question" n; then value=1; else value=0; fi
        fi
    fi
    printf -v "$variable" '%s' "$value"
    state_put choices "$key" "$value"
    [ "$value" -eq 1 ]
}

# Check executables as well as Homebrew receipts, and repair only broken tools.
macos_ensure_formulae() {
    local description="$1"
    local ready="$2"
    shift 2
    local formula=""
    local installed=""
    local missing=()
    local repair=()
    if [ -x "$BREW_BIN" ]; then
        installed="$("$BREW_BIN" list --formula)" || die "无法读取 Homebrew 安装状态"
    fi
    for formula in "$@"; do
        if "$ready" "$formula"; then
            state_record "formula/$formula" reused
        elif grep -Fxq "$formula" <<< "$installed"; then
            repair+=("$formula")
        else
            missing+=("$formula")
        fi
    done
    STATE_CURRENT_RESOURCE="tools/$description"
    if [ "${#missing[@]}" -gt 0 ]; then
        run_cmd "安装 $description" env HOMEBREW_NO_INSTALL_UPGRADE=1 "$BREW_BIN" install "${missing[@]}"
    fi
    if [ "${#repair[@]}" -gt 0 ]; then
        run_cmd "修复 $description" env HOMEBREW_NO_INSTALL_UPGRADE=1 "$BREW_BIN" reinstall "${repair[@]}"
    fi
    [ "$DRY_RUN" -eq 0 ] || return 0
    # Bash 3.2 treats an empty array as unset under set -u.
    for formula in ${missing[@]+"${missing[@]}"} ${repair[@]+"${repair[@]}"}; do
        "$ready" "$formula" || die "安装后工具无法运行: $formula"
        state_record "formula/$formula" applied
    done
}
