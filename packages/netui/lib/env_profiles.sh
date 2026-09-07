#!/bin/bash

env_profiles_validate_mode() {
    case "$1" in
        global|cn-direct)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

env_profiles_read_mode() {
    local mode=''

    if [[ ! -e "$NETUI_ENV_MODE_FILE" && ! -L "$NETUI_ENV_MODE_FILE" ]]; then
        env_mode=cn-direct
        return 0
    fi
    [[ -f "$NETUI_ENV_MODE_FILE" && ! -L "$NETUI_ENV_MODE_FILE" ]] || return 1
    IFS= read -r mode < "$NETUI_ENV_MODE_FILE" || mode=''
    # Versions through 0.2.2 installed an off preference by default.
    [[ "$mode" != off ]] || mode=cn-direct
    env_profiles_validate_mode "$mode" || return 1
    env_mode=$mode
    return 0
}

env_profiles_get_mode() {
    if ! env_profiles_read_mode; then
        printf 'off'
        return 1
    fi
    printf '%s' "$env_mode"
}

env_profiles_global_no_proxy() {
    printf '%s' 'localhost,127.0.0.1,::1'
}

env_profiles_cn_no_proxy() {
    printf '%s' 'localhost,127.0.0.1,::1,.cn,.huaweicloud.com,.aliyun.com,.aliyuncs.com,.cloud.tencent.com,.myqcloud.com,.npmmirror.com,.qq.com,.tencent.com,.baidu.com,.bcebos.com,.alicdn.com,.taobao.com,.jd.com,.bilibili.com,.byteimg.com,.douyin.com,.163.com,.weibo.com,.zhihu.com,.gitee.com,.gitcode.com'
}

env_profiles_no_proxy_bytes() {
    local value=$1

    LC_ALL=C printf '%s' "$value" | wc -c | tr -d '[:space:]'
}

env_profiles_write_value() {
    local path=$1
    local value=$2
    local temporary_path="$path.tmp.$$.$RANDOM"

    [[ ! -L "$path" ]] || return 1
    if [[ -e "$path" && ! -f "$path" ]]; then
        return 1
    fi
    if ! (
        umask 077
        printf '%s\n' "$value" > "$temporary_path"
    ); then
        rm -f -- "$temporary_path"
        return 1
    fi
    chmod 600 -- "$temporary_path" || {
        rm -f -- "$temporary_path"
        return 1
    }
    mv -Tf -- "$temporary_path" "$path"
}

env_profiles_read_endpoint() {
    local endpoint_type=''
    local endpoint_host=''
    local endpoint_port=''
    local endpoint_extra=''

    env_endpoint_type=''
    env_endpoint_host=''
    env_endpoint_port=''

    [[ -f "$NETUI_PROXY_ENDPOINT" && ! -L "$NETUI_PROXY_ENDPOINT" ]] || return 1
    IFS='|' read -r endpoint_type endpoint_host endpoint_port endpoint_extra < "$NETUI_PROXY_ENDPOINT" || return 1
    [[ -z "$endpoint_extra" ]] || return 1
    case "$endpoint_type" in
        mixed|http|socks)
            ;;
        *)
            return 1
            ;;
    esac
    case "$endpoint_host" in
        localhost|127.0.0.1|::1)
            ;;
        *)
            return 1
            ;;
    esac
    [[ "$endpoint_port" =~ ^[1-9][0-9]{0,4}$ ]] || return 1
    ((endpoint_port <= 65535)) || return 1

    env_endpoint_type=$endpoint_type
    env_endpoint_host=$endpoint_host
    env_endpoint_port=$endpoint_port
    return 0
}

env_profiles_runtime_is_healthy() {
    [[ -f "$NETUI_RUNTIME_STATE" && ! -L "$NETUI_RUNTIME_STATE" ]] || return 1
    [[ -f "$NETUI_PROXY_ENDPOINT" && ! -L "$NETUI_PROXY_ENDPOINT" ]] || return 1
    if declare -F runtime_session_is_healthy >/dev/null 2>&1; then
        runtime_session_is_healthy
        return $?
    fi
    return 0
}

env_profiles_compute_environment() {
    local no_proxy_value=''

    env_http_proxy=''
    env_https_proxy=''
    env_all_proxy=''
    env_no_proxy=''
    env_effective=0

    env_profiles_read_mode || return 1
    env_profiles_runtime_is_healthy || return 1
    env_profiles_read_endpoint || return 1

    case "$env_mode" in
        global)
            no_proxy_value=$(env_profiles_global_no_proxy)
            ;;
        cn-direct)
            no_proxy_value=$(env_profiles_cn_no_proxy)
            ;;
        *)
            return 1
            ;;
    esac

    [[ "$(env_profiles_no_proxy_bytes "$no_proxy_value")" -le 512 ]] || return 1
    [[ "$no_proxy_value" != *$'\n'* && "$no_proxy_value" != *[[:space:]]* ]] || return 1

    case "$env_endpoint_type" in
        mixed)
            env_http_proxy="http://$env_endpoint_host:$env_endpoint_port"
            env_https_proxy="$env_http_proxy"
            env_all_proxy="socks5h://$env_endpoint_host:$env_endpoint_port"
            ;;
        http)
            env_http_proxy="http://$env_endpoint_host:$env_endpoint_port"
            env_https_proxy="$env_http_proxy"
            ;;
        socks)
            env_all_proxy="socks5h://$env_endpoint_host:$env_endpoint_port"
            ;;
    esac

    env_no_proxy=$no_proxy_value
    env_effective=1
    return 0
}

env_profiles_tmux() {
    if [[ -n "${NETUI_TMUX_SOCKET:-}" ]]; then
        tmux -L "$NETUI_TMUX_SOCKET" "$@"
    else
        tmux "$@"
    fi
}

env_profiles_tmux_is_owned() {
    [[ "$(env_profiles_tmux show-environment -g NETUI_TMUX_ENV_OWNED 2>/dev/null)" == 'NETUI_TMUX_ENV_OWNED=1' ]]
}

env_profiles_tmux_clear_owned() {
    local variable_name=''

    env_profiles_tmux_is_owned || return 0
    for variable_name in http_proxy HTTP_PROXY https_proxy HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY; do
        env_profiles_tmux set-environment -g -u "$variable_name" >/dev/null 2>&1 || true
    done
    env_profiles_tmux set-environment -g -u NETUI_TMUX_ENV_OWNED >/dev/null 2>&1 || true
}

env_profiles_sync_tmux() {
    command -v tmux >/dev/null 2>&1 || return 0
    if ! env_profiles_tmux list-sessions >/dev/null 2>&1; then
        return 0
    fi

    if ! env_profiles_compute_environment; then
        env_profiles_tmux_clear_owned
        return 0
    fi

    env_profiles_tmux_clear_owned
    env_profiles_tmux set-environment -g NETUI_TMUX_ENV_OWNED 1 >/dev/null 2>&1 || true
    [[ -n "$env_http_proxy" ]] && {
        env_profiles_tmux set-environment -g http_proxy "$env_http_proxy" >/dev/null 2>&1 || true
        env_profiles_tmux set-environment -g HTTP_PROXY "$env_http_proxy" >/dev/null 2>&1 || true
    }
    [[ -n "$env_https_proxy" ]] && {
        env_profiles_tmux set-environment -g https_proxy "$env_https_proxy" >/dev/null 2>&1 || true
        env_profiles_tmux set-environment -g HTTPS_PROXY "$env_https_proxy" >/dev/null 2>&1 || true
    }
    [[ -n "$env_all_proxy" ]] && {
        env_profiles_tmux set-environment -g all_proxy "$env_all_proxy" >/dev/null 2>&1 || true
        env_profiles_tmux set-environment -g ALL_PROXY "$env_all_proxy" >/dev/null 2>&1 || true
    }
    env_profiles_tmux set-environment -g no_proxy "$env_no_proxy" >/dev/null 2>&1 || true
    env_profiles_tmux set-environment -g NO_PROXY "$env_no_proxy" >/dev/null 2>&1 || true
    return 0
}

env_profiles_increment_generation() {
    local generation=0

    if [[ -f "$NETUI_ENV_GENERATION" && ! -L "$NETUI_ENV_GENERATION" ]]; then
        IFS= read -r generation < "$NETUI_ENV_GENERATION" || generation=0
    fi
    [[ "$generation" =~ ^[0-9]+$ ]] || generation=0
    generation=$((generation + 1))
    env_profiles_write_value "$NETUI_ENV_GENERATION" "$generation"
}

_env_profiles_set_mode_unlocked() {
    local requested_mode=$1

    env_profiles_validate_mode "$requested_mode" || {
        netui_print_error 'environment mode must be global or cn-direct'
        return 2
    }
    env_profiles_write_value "$NETUI_ENV_MODE_FILE" "$requested_mode" || {
        netui_print_error 'cannot persist environment mode'
        return 1
    }
    env_profiles_increment_generation || {
        netui_print_error 'cannot update environment generation'
        return 1
    }
    env_profiles_sync_tmux
    return 0
}

env_profiles_set_mode() {
    if (($# != 1)); then
        netui_print_error 'usage: env_profiles_set_mode <global|cn-direct|off>'
        return 2
    fi

    netui_with_lock _env_profiles_set_mode_unlocked "$1"
}

env_profiles_runtime_changed() {
    netui_init_dirs || return 1
    env_profiles_increment_generation || return 1
    env_profiles_sync_tmux
}

env_profiles_enable_on_start() {
    env_profiles_read_mode || {
        netui_print_error 'cannot read environment mode'
        return 1
    }
    env_profiles_write_value "$NETUI_ENV_MODE_FILE" "$env_mode" || return 1
    env_profiles_runtime_changed
}

env_profiles_status() {
    local mode='off'
    local effective='off'
    local no_proxy_bytes=0

    mode=$(env_profiles_get_mode 2>/dev/null) || mode=off
    if env_profiles_compute_environment; then
        effective=on
        no_proxy_bytes=$(env_profiles_no_proxy_bytes "$env_no_proxy")
    fi
    printf 'mode=%s effective=%s no_proxy_bytes=%s' "$mode" "$effective" "$no_proxy_bytes"
}
