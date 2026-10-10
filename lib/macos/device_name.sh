#!/bin/bash

macos_read_device_name() {
    scutil --get "$1" 2>/dev/null || true
}

macos_validate_device_name() {
    case "$1" in
        *$'\n'*|*$'\r'*) return 1 ;;
    esac
    [ -n "$1" ] && [[ "$1" =~ [^[:space:]] ]] &&
        ! printf '%s' "$1" | LC_ALL=C grep -q '[[:cntrl:]]'
}

macos_validate_local_hostname() {
    [ "${#1}" -le 63 ] && [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]]
}

macos_derive_local_hostname() {
    local derived=""
    derived="$(printf '%s' "$1" | LC_ALL=C tr -c 'A-Za-z0-9-' '-' |
        sed -e 's/--*/-/g' -e 's/^-//' -e 's/-$//' | cut -c 1-63 | sed 's/-$//')"
    if [ -z "$derived" ]; then
        derived="$(macos_read_device_name LocalHostName)"
        macos_validate_local_hostname "$derived" || derived="mac"
    fi
    printf '%s' "$derived"
}

macos_apply_device_name() {
    local computer="$1"
    local local_host="$2"
    local old_computer=""
    local old_local=""
    local old_host=""
    if [ "$DRY_RUN" -eq 1 ]; then
        progress "改名前将记录原有三个名字"
        run_cmd "设置设备显示名" sudo scutil --set ComputerName "$computer"
        run_cmd "设置 Bonjour 名" sudo scutil --set LocalHostName "$local_host"
        run_cmd "设置主机名" sudo scutil --set HostName "$local_host"
        return 0
    fi
    old_computer="$(scutil --get ComputerName)" || die "无法读取当前 ComputerName，已取消改名"
    old_local="$(scutil --get LocalHostName)" || die "无法读取当前 LocalHostName，已取消改名"
    old_host="$(macos_read_device_name HostName)"
    sudo -v || die "需要管理员授权才能修改设备名"
    mkdir -p "$MACOS_STATE_DIR"
    DEVICE_NAME_BACKUP="$(mktemp "$MACOS_STATE_DIR/device-name.$(date +%Y%m%d_%H%M%S).XXXXXX")"
    chmod 600 "$DEVICE_NAME_BACKUP"
    printf 'ComputerName=%s\nLocalHostName=%s\nHostName=%s\n' \
        "$old_computer" "$old_local" "$old_host" > "$DEVICE_NAME_BACKUP"

    if sudo scutil --set ComputerName "$computer" &&
        sudo scutil --set LocalHostName "$local_host" &&
        sudo scutil --set HostName "$local_host"; then
        progress "设备名已修改: ${computer}（${local_host}.local）"
        return 0
    fi
    warn "改名未完成，正在恢复原有名字"
    local restored=1
    sudo scutil --set ComputerName "$old_computer" || restored=0
    sudo scutil --set LocalHostName "$old_local" || restored=0
    sudo scutil --set HostName "$old_host" || restored=0
    [ "$restored" -eq 1 ] || warn "恢复未全部成功，请依据 $DEVICE_NAME_BACKUP 手动恢复"
    die "设备改名失败，原始记录: $DEVICE_NAME_BACKUP"
}

step_macos_device_name() {
    stage "设备名称"
    if [ "$SKIP_DEVICE_NAME" -eq 1 ]; then
        progress "跳过设备改名"
        return 0
    fi
    progress "当前设备名: $(macos_read_device_name ComputerName)"
    progress "Bonjour 名: $(macos_read_device_name LocalHostName)"
    local current_host=""
    current_host="$(macos_read_device_name HostName)"
    progress "主机名: ${current_host:-未设置}"
    if [ -z "$DEVICE_NAME" ]; then
        if [ "$DRY_RUN" -eq 1 ]; then
            progress "实际运行会询问是否修改设备名；可用 --device-name 预览指定名字"
            return 0
        fi
        prompt_yes_no "是否修改这台 Mac 的设备名？" n || return 0
        while true; do
            IFS= read -r -p "请输入新设备显示名（留空取消，可含中文和空格）: " DEVICE_NAME || die "设备名输入已结束"
            [ -n "$DEVICE_NAME" ] || return 0
            macos_validate_device_name "$DEVICE_NAME" && break
            warn "设备名不能为空白或包含控制字符"
        done
        local proposed=""
        proposed="$(macos_derive_local_hostname "$DEVICE_NAME")"
        while true; do
            IFS= read -r -p "Bonjour/主机名 [$proposed]: " LOCAL_HOST_NAME || die "主机名输入已结束"
            LOCAL_HOST_NAME="${LOCAL_HOST_NAME:-$proposed}"
            macos_validate_local_hostname "$LOCAL_HOST_NAME" && break
            warn "请输入最多 63 字符的字母、数字、连字符，首尾必须为字母或数字"
        done
    fi
    LOCAL_HOST_NAME="${LOCAL_HOST_NAME:-$(macos_derive_local_hostname "$DEVICE_NAME")}"
    macos_validate_device_name "$DEVICE_NAME" || die "无效的设备名"
    macos_validate_local_hostname "$LOCAL_HOST_NAME" || die "无效的 Bonjour 名"
    progress "ComputerName → $DEVICE_NAME"
    progress "LocalHostName / HostName → $LOCAL_HOST_NAME"
    if [ "$INTERACTIVE" -eq 1 ]; then
        prompt_yes_no "确认修改以上三个名字？（需要管理员密码）" n || return 0
    fi
    macos_apply_device_name "$DEVICE_NAME" "$LOCAL_HOST_NAME"
}
