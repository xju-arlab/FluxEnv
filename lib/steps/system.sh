#!/bin/bash

APT_BACKUP_DIR="/var/backups/fluxenv/apt"

update_hosts_file() {
    local resolved_ip=""
    if command_exists ip; then
        resolved_ip="$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '^127\.' | head -1)"
    elif command_exists ifconfig; then
        resolved_ip="$(ifconfig 2>/dev/null | awk '/inet / && $2 != "127.0.0.1" {print $2; exit}')"
    fi

    if [ -z "$resolved_ip" ]; then
        warn "无法解析主机 IPv4，跳过 /etc/hosts 更新"
        return 0
    fi

    progress "更新 /etc/hosts 中的主机名映射"
    if [ "${DRY_RUN:-0}" -eq 1 ]; then
        echo "    [dry-run] ${resolved_ip} ${HOST_NAME}"
        return 0
    fi

    backup_path /etc/hosts

    if grep -q "^${resolved_ip}[[:space:]]" /etc/hosts; then
        sed -i "s|^${resolved_ip}[[:space:]].*|${resolved_ip} ${HOST_NAME} ${HOST_NAME}|" /etc/hosts
    else
        printf '%s %s %s\n' "$resolved_ip" "$HOST_NAME" "$HOST_NAME" >> /etc/hosts
    fi
}

apply_apt_mirror() {
    local mirror_files=()
    local file_path=""

    if [ "$ENABLE_APT_MIRROR" -ne 1 ]; then
        progress "跳过 apt 换源"
        return 0
    fi

    if [ -f /etc/apt/sources.list ]; then
        mirror_files+=("/etc/apt/sources.list")
    fi

    while IFS= read -r file_path; do
        mirror_files+=("$file_path")
    done < <(find /etc/apt/sources.list.d -maxdepth 1 \( -name '*.list' -o -name '*.sources' \) 2>/dev/null | sort)

    if [ "${#mirror_files[@]}" -eq 0 ]; then
        warn "未找到可修改的 apt 源文件，跳过换源"
        return 0
    fi

    progress "应用 apt 镜像源: ${APT_MIRROR_PRESET} (${APT_UBUNTU_MIRROR})"
    if [ "${DRY_RUN:-0}" -eq 1 ]; then
        printf '    [dry-run] %s\n' "${mirror_files[@]}"
        return 0
    fi

    find /etc/apt/sources.list.d -maxdepth 1 -type f \( -name '*.list.backup.*' -o -name '*.sources.backup.*' \) -delete 2>/dev/null || true

    for file_path in "${mirror_files[@]}"; do
        backup_path_to_dir "$file_path" "$APT_BACKUP_DIR"
        sed -i \
            -e "s|https\?://archive\.ubuntu\.com/ubuntu|${APT_UBUNTU_MIRROR}|g" \
            -e "s|https\?://security\.ubuntu\.com/ubuntu|${APT_UBUNTU_MIRROR}|g" \
            -e "s|https\?://ports\.ubuntu\.com/ubuntu-ports|${APT_UBUNTU_PORTS_MIRROR}|g" \
            "$file_path"
    done
}

step_packages() {
    stage "增量软件包检查"
    local mirror_signature=""
    mirror_signature="$(printf '%s\n' "$ENABLE_APT_MIRROR" "$APT_UBUNTU_MIRROR" "$APT_UBUNTU_PORTS_MIRROR" | state_signature)"
    if [ "$ENABLE_APT_MIRROR" -eq 1 ] && [ "$(state_get receipts system/apt-mirror)" != "$mirror_signature" ]; then
        apply_apt_mirror
        state_record system/apt-mirror applied "$mirror_signature"
    else
        progress "复用现有 apt 源配置"
        state_record system/apt-mirror reused "$mirror_signature"
    fi
    # Full upgrades belong to the first bootstrap, never to an incremental run.
    if [ "$STATE_INITIALIZED" -eq 0 ] && [ -z "$(state_get receipts system/initial-update)" ]; then
        if [ "$APT_FIX_BROKEN" -eq 1 ]; then
            run_cmd "修复潜在依赖问题" apt install -f -y
        fi
        if [ "$APT_UPGRADE" -eq 1 ]; then
            run_cmd "更新软件源信息" apt update
            run_cmd "首次升级系统软件包" env DEBIAN_FRONTEND=noninteractive apt upgrade -y
        fi
        state_record system/initial-update applied
    fi
    local packages=()
    read -r -a packages <<< "$BASE_PACKAGES $EXTRA_PACKAGES gh"
    linux_install_packages "${packages[@]}"
    if command_exists locale-gen && ! locale -a | grep -qi '^en_US\.utf8$'; then
        run_cmd "生成 en_US.UTF-8 locale" locale-gen en_US.UTF-8
    fi
}

linux_install_packages() {
    local package=""
    local status=""
    local missing=()
    local repair=()
    local check_gh=0
    for package in "$@"; do
        [[ "$package" =~ ^[a-zA-Z0-9][a-zA-Z0-9+.:_-]*$ ]] || die "无效的软件包名称: $package"
        status="$(dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null || true)"
        [ "$package" != gh ] || check_gh=1
        if [ "$package" = gh ] && [ "$status" = installed ] &&
            ! { command_exists gh && gh --version >/dev/null 2>&1; }; then
            repair+=("$package")
        elif [ "$status" = installed ]; then
            progress "复用已安装软件包: $package"
            state_record "package/$package" reused
        elif [ "$package" = gh ] && command_exists gh && gh --version >/dev/null 2>&1; then
            progress "复用已有 GitHub CLI"
            state_record tools/gh reused
        else
            missing+=("$package")
        fi
    done
    if [ "${#missing[@]}" -gt 0 ] || [ "${#repair[@]}" -gt 0 ]; then
        STATE_CURRENT_RESOURCE=tools/apt-packages
        run_cmd "更新安装索引" apt update
        if [ "${#missing[@]}" -gt 0 ]; then
            run_cmd "仅安装缺失的软件包" env DEBIAN_FRONTEND=noninteractive apt install -y --no-install-recommends "${missing[@]}"
        fi
        if [ "${#repair[@]}" -gt 0 ]; then
            run_cmd "修复已安装但无法运行的 GitHub CLI" env DEBIAN_FRONTEND=noninteractive apt install --reinstall -y --no-install-recommends "${repair[@]}"
        fi
        if [ "$DRY_RUN" -eq 0 ]; then
            [ "${#repair[@]}" -eq 0 ] || missing+=("${repair[@]}")
            for package in "${missing[@]}"; do
                [ "$(dpkg-query -W -f='${db:Status-Status}' "$package")" = installed ] || die "软件包安装后未就绪: $package"
                state_record "package/$package" applied
            done
        fi
    fi
    if [ "$check_gh" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
        command_exists gh && gh --version >/dev/null || die "GitHub CLI 安装后无法运行"
    fi
}

step_ssh() {
    stage "SSH 配置优化"

    if [ ! -f /etc/ssh/sshd_config ]; then
        warn "未找到 /etc/ssh/sshd_config，尝试安装 openssh-server"
        linux_install_packages openssh-server
    fi
    if [ ! -f /etc/ssh/sshd_config ]; then
        warn "未找到 sshd_config，跳过 SSH 配置"
        return 0
    fi

    if grep -Eq '^ClientAliveInterval[[:space:]]+60([[:space:]]|$)' /etc/ssh/sshd_config &&
        grep -Eq '^ClientAliveCountMax[[:space:]]+3([[:space:]]|$)' /etc/ssh/sshd_config; then
        progress "SSH 配置已匹配，复用现有配置和服务"
        state_record system/ssh reused "$(state_file_signature /etc/ssh/sshd_config)"
        return 0
    fi
    local installed_signature=""
    installed_signature="$(state_get receipts system/ssh)"
    if [ -n "$installed_signature" ] && [ "$installed_signature" != "$(state_file_signature /etc/ssh/sshd_config)" ]; then
        progress "保留手动修改过的 SSH 配置"
        state_record system/ssh preserved
        return 0
    fi

    backup_path /etc/ssh/sshd_config
    set_sshd_option "ClientAliveInterval" "60"
    set_sshd_option "ClientAliveCountMax" "3"
    restart_ssh_service
    [ "$DRY_RUN" -eq 1 ] || state_record system/ssh applied "$(state_file_signature /etc/ssh/sshd_config)"
}

step_hostname() {
    stage "主机名配置"

    if [ "$STATE_INITIALIZED" -eq 1 ] && [ -z "$HOST_NAME" ]; then
        if [ "$VISUAL_HOSTNAME_ONLY" -eq 1 ]; then
            HOST_NAME="$(state_get choices host_name)"
        else
            HOST_NAME="$(hostname)"
        fi
        progress "复用已有主机名: $HOST_NAME"
        state_record system/hostname reused
        return 0
    fi

    prompt_value HOST_NAME "请输入主机名（字母开头，可含数字、下划线、连字符）" '^[a-zA-Z][a-zA-Z0-9_-]*$'
    progress "设置主机名为: $HOST_NAME"

    if [ "$VISUAL_HOSTNAME_ONLY" -eq 0 ] && [ "$(hostname)" = "$HOST_NAME" ]; then
        progress "主机名已匹配"
        state_put choices host_name "$HOST_NAME"
        state_record system/hostname reused
        return 0
    fi

    set_hostname_safe "$HOST_NAME"

    if [ "$VISUAL_HOSTNAME_ONLY" -eq 0 ]; then
        update_hosts_file
    fi
    state_put choices host_name "$HOST_NAME"
    state_record system/hostname applied
}
