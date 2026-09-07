#!/bin/bash

# NetUI shell integration. This file is static code; it reads only validated,
# small state files and never executes or sources runtime state.

__netui_config_home=${NETUI_CONFIG_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/netui}
__netui_state_home=${NETUI_STATE_HOME:-${XDG_STATE_HOME:-$HOME/.local/state}/netui}
__netui_runtime_dir=$__netui_state_home/runtime
__netui_mode_file=$__netui_config_home/env-mode
__netui_generation_file=$__netui_runtime_dir/env-generation
__netui_endpoint_file=$__netui_runtime_dir/proxy-endpoint
__netui_instance_file=$__netui_runtime_dir/instance.state
__netui_last_generation=''
__netui_last_mode=''

case ":$PATH:" in
    *":${NETUI_BIN_DIR:-${XDG_BIN_HOME:-$HOME/.local/bin}}:"*) ;;
    *) export PATH="${NETUI_BIN_DIR:-${XDG_BIN_HOME:-$HOME/.local/bin}}:$PATH" ;;
esac

__netui_read_mode() {
    local mode=''

    if [[ ! -e "$__netui_mode_file" && ! -L "$__netui_mode_file" ]]; then
        __netui_mode=cn-direct
        return 0
    fi
    if [[ ! -f "$__netui_mode_file" || -L "$__netui_mode_file" ]]; then
        __netui_mode=off
        return 0
    fi
    IFS= read -r mode < "$__netui_mode_file" || mode=''
    case "$mode" in
        global|cn-direct)
            __netui_mode=$mode
            ;;
        off)
            __netui_mode=cn-direct
            ;;
        *)
            __netui_mode=off
            ;;
    esac
}

__netui_read_generation() {
    local generation='0'

    if [[ -f "$__netui_generation_file" && ! -L "$__netui_generation_file" ]]; then
        IFS= read -r generation < "$__netui_generation_file" || generation=0
    fi
    [[ "$generation" =~ ^[0-9]+$ ]] || generation=0
    __netui_generation=$generation
}

__netui_clear_owned_environment() {
    [[ "${NETUI_ENV_OWNED-}" == 1 ]] || return 0
    unset http_proxy HTTP_PROXY https_proxy HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY
    unset NETUI_ENV_OWNED
}

__netui_read_endpoint() {
    local endpoint_type=''
    local endpoint_host=''
    local endpoint_port=''
    local endpoint_extra=''

    [[ -f "$__netui_endpoint_file" && ! -L "$__netui_endpoint_file" ]] || return 1
    [[ -f "$__netui_instance_file" && ! -L "$__netui_instance_file" ]] || return 1
    IFS='|' read -r endpoint_type endpoint_host endpoint_port endpoint_extra < "$__netui_endpoint_file" || return 1
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

    __netui_endpoint_type=$endpoint_type
    __netui_endpoint_host=$endpoint_host
    __netui_endpoint_port=$endpoint_port
    return 0
}

__netui_tmux() {
    if [[ -n "${NETUI_TMUX_SOCKET-}" ]]; then
        tmux -L "$NETUI_TMUX_SOCKET" "$@"
    else
        tmux "$@"
    fi
}

__netui_runtime_is_healthy() {
    local key=''
    local value=''
    local token=''
    local session_name=''
    local pane_id=''
    local pane_pid=''
    local process_starttime=''
    local core_path=''
    local session_metadata=''
    local field=0
    local stat_line=''
    local stat_tail=''
    local current_starttime=''
    local process_exe=''
    local command_line=''
    local first_arg=''
    local remaining_args=''
    local second_arg=''
    local third_arg=''

    [[ -f "$__netui_instance_file" && ! -L "$__netui_instance_file" ]] || return 1
    [[ -f "$__netui_endpoint_file" && ! -L "$__netui_endpoint_file" ]] || return 1
    while IFS='=' read -r key value || [[ -n "$key" ]]; do
        case "$key" in
            runtime_token) token=$value ;;
            session_name) session_name=$value ;;
            pane_id) pane_id=$value ;;
            pane_pid) pane_pid=$value ;;
            process_starttime) process_starttime=$value ;;
            core_path) core_path=$value ;;
            config_path|config_basename|config_mtime|config_sha256|started_at) ;;
            '') ;;
            *) return 1 ;;
        esac
    done < "$__netui_instance_file"
    [[ "$token" =~ ^[0-9a-f]{32,}$ ]] || return 1
    [[ "$session_name" == "${NETUI_TMUX_SESSION_NAME:-netui}" ]] || return 1
    [[ "$pane_id" =~ ^%[0-9]+$ && "$pane_pid" =~ ^[0-9]+$ ]] || return 1
    [[ "$process_starttime" =~ ^[0-9]+$ && "$core_path" == /* ]] || return 1
    command -v tmux >/dev/null 2>&1 || return 1
    session_metadata=$(__netui_tmux display-message -p -t "$pane_id" \
        '#{session_name}|#{@netui_token}|#{@netui_core}|#{@netui_pane}|#{pane_id}|#{pane_pid}' 2>/dev/null) || return 1
    [[ "$session_metadata" == "$session_name|$token|$core_path|$pane_id|$pane_id|$pane_pid" ]] || return 1
    [[ -r "/proc/$pane_pid/stat" && -r "/proc/$pane_pid/cmdline" ]] || return 1
    IFS= read -r stat_line 2>/dev/null < "/proc/$pane_pid/stat" || return 1
    stat_tail=${stat_line##*) }
    for ((field = 0; field < 19; field++)); do
        stat_tail=${stat_tail#* }
    done
    current_starttime=${stat_tail%% *}
    [[ "$current_starttime" == "$process_starttime" ]] || return 1
    process_exe=$(readlink -e -- "/proc/$pane_pid/exe" 2>/dev/null) || process_exe=''
    [[ "$process_exe" == "$core_path" ]] && return 0
    [[ -f "$core_path" && -x "$core_path" ]] || return 1
    command_line=$(tr '\0' '\n' 2>/dev/null < "/proc/$pane_pid/cmdline") || return 1
    first_arg=${command_line%%$'\n'*}
    remaining_args=${command_line#*$'\n'}
    second_arg=${remaining_args%%$'\n'*}
    third_arg=${remaining_args#*$'\n'}
    third_arg=${third_arg%%$'\n'*}
    case "${first_arg##*/}" in
        bash|dash|sh|zsh) [[ "$second_arg" == "$core_path" ]] ;;
        env)
            case "$second_arg" in
                bash|dash|sh|zsh) [[ "$third_arg" == "$core_path" ]] ;;
                *) return 1 ;;
            esac
            ;;
        *) return 1 ;;
    esac
}

__netui_apply_env() {
    local generation=''
    local mode=''
    local no_proxy_value=''
    local http_value=''
    local https_value=''
    local all_value=''

    __netui_read_generation
    __netui_read_mode
    generation=$__netui_generation
    mode=$__netui_mode
    if [[ "$mode" != off ]] && ! __netui_runtime_is_healthy; then
        __netui_last_generation=''
        __netui_clear_owned_environment
        return 0
    fi
    if [[ "$generation" == "$__netui_last_generation" && "$mode" == "$__netui_last_mode" ]]; then
        return 0
    fi
    __netui_last_generation=$generation
    __netui_last_mode=$mode

    if [[ "$mode" == off ]] || ! __netui_read_endpoint; then
        __netui_clear_owned_environment
        return 0
    fi

    case "$mode" in
        global)
            no_proxy_value='localhost,127.0.0.1,::1'
            ;;
        cn-direct)
            no_proxy_value='localhost,127.0.0.1,::1,.cn,.huaweicloud.com,.aliyun.com,.aliyuncs.com,.cloud.tencent.com,.myqcloud.com,.npmmirror.com,.qq.com,.tencent.com,.baidu.com,.bcebos.com,.alicdn.com,.taobao.com,.jd.com,.bilibili.com,.byteimg.com,.douyin.com,.163.com,.weibo.com,.zhihu.com,.gitee.com,.gitcode.com'
            ;;
        *)
            __netui_clear_owned_environment
            return 0
            ;;
    esac

    http_value=''
    https_value=''
    all_value=''
    case "$__netui_endpoint_type" in
        mixed)
            http_value="http://$__netui_endpoint_host:$__netui_endpoint_port"
            https_value=$http_value
            all_value="socks5h://$__netui_endpoint_host:$__netui_endpoint_port"
            ;;
        http)
            http_value="http://$__netui_endpoint_host:$__netui_endpoint_port"
            https_value=$http_value
            ;;
        socks)
            all_value="socks5h://$__netui_endpoint_host:$__netui_endpoint_port"
            ;;
    esac

    __netui_clear_owned_environment
    [[ -n "$http_value" ]] && export http_proxy=$http_value HTTP_PROXY=$http_value
    [[ -n "$https_value" ]] && export https_proxy=$https_value HTTPS_PROXY=$https_value
    [[ -n "$all_value" ]] && export all_proxy=$all_value ALL_PROXY=$all_value
    export no_proxy=$no_proxy_value NO_PROXY=$no_proxy_value
    export NETUI_ENV_OWNED=1
    return 0
}

# Shell functions apply changes before the next command, including && chains.
# The executable commands remain usable in scripts without sourcing this file.
netup() {
    local netui_status=0
    command netup "$@" || netui_status=$?
    __netui_last_generation=''
    __netui_apply_env
    return "$netui_status"
}

netdown() {
    local netui_status=0
    command netdown "$@" || netui_status=$?
    __netui_last_generation=''
    __netui_apply_env
    return "$netui_status"
}

netui() {
    local netui_status=0
    command netui "$@" || netui_status=$?
    __netui_last_generation=''
    __netui_apply_env
    return "$netui_status"
}

sudo() {
    __netui_apply_env
    if [[ "${NETUI_ENV_OWNED-}" == 1 ]]; then
        command sudo --preserve-env=http_proxy,HTTP_PROXY,https_proxy,HTTPS_PROXY,all_proxy,ALL_PROXY,no_proxy,NO_PROXY "$@"
    else
        command sudo "$@"
    fi
}

if [[ -n "${BASH_VERSION-}" ]]; then
    if [[ -z "${__netui_bash_hook_installed-}" ]]; then
        if declare -p PROMPT_COMMAND 2>/dev/null | grep -q 'declare -a'; then
            __netui_prompt_hook_present=0
            for __netui_prompt_hook in "${PROMPT_COMMAND[@]}"; do
                [[ "$__netui_prompt_hook" == __netui_apply_env ]] && __netui_prompt_hook_present=1
            done
            if ((__netui_prompt_hook_present == 0)); then
                PROMPT_COMMAND=(__netui_apply_env "${PROMPT_COMMAND[@]}")
            fi
            unset __netui_prompt_hook_present __netui_prompt_hook
        elif [[ ";${PROMPT_COMMAND-};" != *';__netui_apply_env;'* ]]; then
            PROMPT_COMMAND="__netui_apply_env${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
        fi
        __netui_bash_hook_installed=1
    fi
elif [[ -n "${ZSH_VERSION-}" ]]; then
    if [[ -z "${__netui_zsh_hook_installed-}" ]]; then
        autoload -Uz add-zsh-hook
        add-zsh-hook -d precmd __netui_apply_env 2>/dev/null || true
        add-zsh-hook precmd __netui_apply_env
        __netui_zsh_hook_installed=1
    fi
fi

__netui_apply_env
