#!/bin/bash

# Shared lifecycle and receipts. Records are data, never sourced as shell code.
state_signature() {
    cksum | awk '{print $1 ":" $2}'
}

state_file_signature() {
    state_signature < "$1"
}

state_open() {
    STATE_DIR="$1"
    STATE_SCOPE="$2"
    [[ "$STATE_DIR" = /* ]] || die "历史目录必须是绝对路径: $STATE_DIR"
    STATE_RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
    STATE_ACTIVE=0
    STATE_FINISHED=0
    STATE_LOCKED=0
    STATE_INITIALIZED=0
    STATE_APPLIED=0
    STATE_REUSED=0
    STATE_PRESERVED=0
    STATE_CURRENT_RESOURCE="preflight"
    STATE_BACKUP_DIR=""
    local path=""
    [ ! -L "$STATE_DIR" ] || die "历史目录不能是符号链接: $STATE_DIR"
    for path in history.tsv receipts.tsv choices.tsv initialized; do
        [ ! -L "$STATE_DIR/$path" ] || die "历史文件不能是符号链接: $STATE_DIR/$path"
        [ ! -e "$STATE_DIR/$path" ] || [ -f "$STATE_DIR/$path" ] || die "历史路径不是普通文件: $STATE_DIR/$path"
    done
    if [ -f "$STATE_DIR/initialized" ]; then
        STATE_INITIALIZED=1
        progress "当前设备已完成过初始化，开始检测增量并复用已有配置"
    else
        progress "未找到完成记录，将检测并接入现有环境"
    fi
}

state_event() {
    [ "${STATE_ACTIVE:-0}" -eq 1 ] && [ "${DRY_RUN:-0}" -eq 0 ] || return 0
    local event="$1"
    local resource="$2"
    local detail="${3:-}"
    # Only implementation-owned descriptions belong here; no command output,
    # environment dumps, passwords, tokens or device authorization codes.
    detail="${detail//$'\t'/ }"
    detail="${detail//$'\n'/ }"
    resource="${resource//$'\t'/ }"
    resource="${resource//$'\n'/ }"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "$STATE_RUN_ID" "$STATE_SCOPE" "$event" "$resource" "$detail" >> "$STATE_DIR/history.tsv"
}

state_get() {
    local table="$1"
    local key="$2"
    [ -f "$STATE_DIR/$table.tsv" ] || return 0
    awk -F '\t' -v key="$key" '$1 == key { print $2; exit }' "$STATE_DIR/$table.tsv"
}

state_put() {
    local table="$1"
    local key="$2"
    local value="$3"
    [ "${STATE_ACTIVE:-0}" -eq 1 ] && [ "${DRY_RUN:-0}" -eq 0 ] || return 0
    [ "$(state_get "$table" "$key")" != "$value" ] || return 0
    local temporary=""
    local input="/dev/null"
    [ ! -f "$STATE_DIR/$table.tsv" ] || input="$STATE_DIR/$table.tsv"
    temporary="$(mktemp "$STATE_DIR/.$table.XXXXXX")"
    awk -F '\t' -v key="$key" '$1 != key' "$input" > "$temporary"
    printf '%s\t%s\n' "$key" "$value" >> "$temporary"
    chmod 600 "$temporary"
    mv -f "$temporary" "$STATE_DIR/$table.tsv"
}

state_record() {
    local resource="$1"
    local action="$2"
    local signature="${3:-present}"
    STATE_CURRENT_RESOURCE="$resource"
    case "$action" in
        applied) STATE_APPLIED=$((${STATE_APPLIED:-0} + 1)) ;;
        reused) STATE_REUSED=$((${STATE_REUSED:-0} + 1)) ;;
        preserved) STATE_PRESERVED=$((${STATE_PRESERVED:-0} + 1)) ;;
    esac
    state_event "$action" "$resource"
    # Preserve the last installed signature when a user has edited a file.
    [ "$action" = preserved ] || [ "$action" = skipped ] || state_put receipts "$resource" "$signature"
}

state_begin() {
    [ "${DRY_RUN:-0}" -eq 0 ] || return 0
    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR"
    if ! mkdir "$STATE_DIR/lock" 2>/dev/null; then
        local previous_pid=""
        [ ! -L "$STATE_DIR/lock" ] || die "历史锁不能是符号链接"
        previous_pid="$(cat "$STATE_DIR/lock/pid" 2>/dev/null || true)"
        if [[ "$previous_pid" =~ ^[0-9]+$ ]] && ! kill -0 "$previous_pid" 2>/dev/null; then
            rm -f "$STATE_DIR/lock/pid"
            rmdir "$STATE_DIR/lock" || die "历史锁中有未知内容，请手动检查"
            mkdir "$STATE_DIR/lock" || die "无法取得历史锁"
        else
            die "另一个初始化正在运行，请稍后重试（$STATE_DIR/lock）"
        fi
    fi
    STATE_LOCKED=1
    STATE_ACTIVE=1
    trap 'state_exit "$?" 1' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    printf '%s\n' "$$" > "$STATE_DIR/lock/pid"
    touch "$STATE_DIR/history.tsv"
    chmod 600 "$STATE_DIR/history.tsv"
    state_event started run
}

state_finish() {
    [ "${STATE_FINISHED:-0}" -eq 0 ] || return 0
    if [ "${STATE_ACTIVE:-0}" -eq 1 ]; then
        local temporary=""
        temporary="$(mktemp "$STATE_DIR/.initialized.XXXXXX")"
        printf 'schema=1\nprofile=%s\nlast_success=%s\n' "$STATE_SCOPE" "$STATE_RUN_ID" > "$temporary"
        chmod 600 "$temporary"
        mv -f "$temporary" "$STATE_DIR/initialized"
        state_event completed run
    fi
    STATE_FINISHED=1
}

state_exit() {
    local status="$1"
    # Bash 3.2 can report status 0 for an unset-variable error in a function.
    # An unfinished run must never appear successful to its caller.
    if [ "${STATE_FINISHED:-0}" -eq 0 ] && [ "$status" -eq 0 ]; then
        status=1
    fi
    if command -v state_cleanup >/dev/null 2>&1; then
        state_cleanup || status=1
    fi
    if [ "${STATE_ACTIVE:-0}" -eq 1 ] && [ "${STATE_FINISHED:-0}" -eq 0 ]; then
        state_event failed "${STATE_CURRENT_RESOURCE:-run}" "exit=$status" || true
    fi
    if [ "${STATE_LOCKED:-0}" -eq 1 ]; then
        rm -f "$STATE_DIR/lock/pid"
        rmdir "$STATE_DIR/lock" || true
        STATE_LOCKED=0
    fi
    [ "${2:-0}" -ne 1 ] || exit "$status"
}

state_show() {
    local mode="$1"
    if [ "$mode" = history ]; then
        if [ -f "$STATE_DIR/history.tsv" ]; then
            cat "$STATE_DIR/history.tsv"
        else
            progress "暂无初始化历史"
        fi
        return 0
    fi
    printf 'Profile: %s\n历史目录: %s\n' "$STATE_SCOPE" "$STATE_DIR"
    if [ -f "$STATE_DIR/initialized" ]; then
        cat "$STATE_DIR/initialized"
    else
        progress "尚无成功完成记录"
    fi
    [ ! -f "$STATE_DIR/receipts.tsv" ] || cat "$STATE_DIR/receipts.tsv"
}

state_summary() {
    progress "本次新增/修复: ${STATE_APPLIED:-0}，复用: ${STATE_REUSED:-0}，保留本地修改: ${STATE_PRESERVED:-0}"
    progress "历史记录: $STATE_DIR/history.tsv"
}
