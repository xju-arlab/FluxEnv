#!/bin/bash

netui_tmux() {
    if [[ -n "${NETUI_TMUX_SOCKET:-}" ]]; then
        tmux -L "$NETUI_TMUX_SOCKET" "$@"
    else
        tmux "$@"
    fi
}

runtime_require_tmux() {
    netui_require_command tmux
}

runtime_session_exists() {
    netui_tmux has-session -t "$NETUI_TMUX_SESSION_NAME" >/dev/null 2>&1
}

runtime_state_load() {
    local key=''
    local value=''

    runtime_token=''
    runtime_session_name=''
    runtime_pane_id=''
    runtime_pane_pid=''
    runtime_process_starttime=''
    runtime_core_path=''
    runtime_config_path=''
    runtime_config_basename=''
    runtime_config_mtime=''
    runtime_config_sha256=''
    runtime_started_at=''

    [[ -f "$NETUI_RUNTIME_STATE" && ! -L "$NETUI_RUNTIME_STATE" ]] || return 1
    chmod 600 -- "$NETUI_RUNTIME_STATE" 2>/dev/null || return 1

    while IFS='=' read -r key value || [[ -n "$key" ]]; do
        case "$key" in
            runtime_token) runtime_token=$value ;;
            session_name) runtime_session_name=$value ;;
            pane_id) runtime_pane_id=$value ;;
            pane_pid) runtime_pane_pid=$value ;;
            process_starttime) runtime_process_starttime=$value ;;
            core_path) runtime_core_path=$value ;;
            config_path) runtime_config_path=$value ;;
            config_basename) runtime_config_basename=$value ;;
            config_mtime) runtime_config_mtime=$value ;;
            config_sha256) runtime_config_sha256=$value ;;
            started_at) runtime_started_at=$value ;;
            '') ;;
            *) return 1 ;;
        esac
    done < "$NETUI_RUNTIME_STATE"

    [[ "$runtime_token" =~ ^[0-9a-f]{32,}$ ]] || return 1
    [[ "$runtime_session_name" == "$NETUI_TMUX_SESSION_NAME" ]] || return 1
    [[ "$runtime_pane_id" =~ ^%[0-9]+$ ]] || return 1
    [[ "$runtime_pane_pid" =~ ^[0-9]+$ ]] || return 1
    [[ "$runtime_process_starttime" =~ ^[0-9]+$ ]] || return 1
    [[ "$runtime_core_path" == /* && "$runtime_core_path" != *$'\n'* ]] || return 1
    [[ "$runtime_config_path" == /* && "$runtime_config_path" != *$'\n'* ]] || return 1
    [[ "$runtime_config_basename" == *.json ]] || return 1

    return 0
}

runtime_state_write() {
    local temporary_state=''

    temporary_state=$(umask 077; mktemp "$NETUI_RUNTIME_DIR/.instance.state.tmp.XXXXXX") || return 1
    if ! (
        umask 077
        {
            printf 'runtime_token=%s\n' "$runtime_token"
            printf 'session_name=%s\n' "$runtime_session_name"
            printf 'pane_id=%s\n' "$runtime_pane_id"
            printf 'pane_pid=%s\n' "$runtime_pane_pid"
            printf 'process_starttime=%s\n' "$runtime_process_starttime"
            printf 'core_path=%s\n' "$runtime_core_path"
            printf 'config_path=%s\n' "$runtime_config_path"
            printf 'config_basename=%s\n' "$runtime_config_basename"
            printf 'config_mtime=%s\n' "$runtime_config_mtime"
            printf 'config_sha256=%s\n' "$runtime_config_sha256"
            printf 'started_at=%s\n' "$runtime_started_at"
        } > "$temporary_state"
    ); then
        rm -f -- "$temporary_state"
        return 1
    fi

    chmod 600 -- "$temporary_state" || {
        rm -f -- "$temporary_state"
        return 1
    }
    mv -Tf -- "$temporary_state" "$NETUI_RUNTIME_STATE"
}

runtime_write_endpoint() {
    local endpoint=''
    local temporary_endpoint=''

    if declare -F config_meta_local_endpoint_tsv >/dev/null 2>&1; then
        endpoint=$(config_meta_local_endpoint_tsv "$runtime_config_path" 2>/dev/null) || endpoint=''
    else
        endpoint=$(jq -r '
            [.inbounds[]? |
                select((.type? == "mixed" or .type? == "http" or .type? == "socks") and
                    (.listen? == "localhost" or .listen? == "127.0.0.1" or .listen? == "::1") and
                    (.listen_port? != null)) |
                {type: .type, listen: .listen, port: .listen_port}]
            | sort_by(if .type == "mixed" then 0 elif .type == "http" then 1 else 2 end)
            | if length == 0 then empty else .[0] | "\(.type)|\(.listen)|\(.port)" end
        ' "$runtime_config_path" 2>/dev/null) || endpoint=''
    fi
    if [[ -z "$endpoint" ]]; then
        rm -f -- "$NETUI_PROXY_ENDPOINT"
        return 0
    fi

    temporary_endpoint=$(umask 077; mktemp "$NETUI_RUNTIME_DIR/.proxy-endpoint.tmp.XXXXXX") || return 1
    if ! (
        umask 077
        printf '%s\n' "$endpoint" > "$temporary_endpoint"
    ); then
        rm -f -- "$temporary_endpoint"
        return 1
    fi
    chmod 600 -- "$temporary_endpoint" || {
        rm -f -- "$temporary_endpoint"
        return 1
    }
    mv -Tf -- "$temporary_endpoint" "$NETUI_PROXY_ENDPOINT"
}

runtime_clear_state() {
    local path=''
    local status=0

    for path in "$NETUI_RUNTIME_STATE" "$NETUI_PROXY_ENDPOINT"; do
        if [[ -L "$path" ]]; then
            netui_print_error "refusing to remove symlink runtime state: $path"
            status=1
        elif [[ -e "$path" ]]; then
            if [[ -f "$path" ]]; then
                rm -f -- "$path" || status=1
            else
                netui_print_error "refusing to remove non-regular runtime state: $path"
                status=1
            fi
        fi
    done

    return "$status"
}

runtime_notify_environment() {
    if declare -F env_profiles_runtime_changed >/dev/null 2>&1; then
        env_profiles_runtime_changed || true
    fi
}

runtime_session_options_match() {
    local option_token=''
    local option_core=''

    option_token=$(netui_tmux show-option -qv -t "$NETUI_TMUX_SESSION_NAME" @netui_token 2>/dev/null) || return 1
    option_core=$(netui_tmux show-option -qv -t "$NETUI_TMUX_SESSION_NAME" @netui_core 2>/dev/null) || return 1
    [[ "$option_token" == "$runtime_token" && "$option_core" == "$runtime_core_path" ]]
}

runtime_kill_marked_session() {
    runtime_session_exists || return 0
    runtime_session_options_match || return 6
    netui_tmux kill-session -t "$NETUI_TMUX_SESSION_NAME" >/dev/null 2>&1
}

runtime_kill_created_session() {
    local expected_pane=$1
    local expected_token=$2
    local expected_core=$3
    local current_pane=''
    local option_token=''
    local option_core=''

    runtime_session_exists || return 0
    current_pane=$(netui_tmux display-message -p -t "$NETUI_TMUX_SESSION_NAME" '#{pane_id}' 2>/dev/null) || return 6
    [[ "$current_pane" == "$expected_pane" ]] || return 6
    option_token=$(netui_tmux show-option -qv -t "$NETUI_TMUX_SESSION_NAME" @netui_token 2>/dev/null) || option_token=''
    option_core=$(netui_tmux show-option -qv -t "$NETUI_TMUX_SESSION_NAME" @netui_core 2>/dev/null) || option_core=''
    [[ -z "$option_token" || "$option_token" == "$expected_token" ]] || return 6
    [[ -z "$option_core" || "$option_core" == "$expected_core" ]] || return 6
    netui_tmux kill-session -t "$NETUI_TMUX_SESSION_NAME" >/dev/null 2>&1
}

runtime_session_metadata_matches() {
    local current_pane_id=''
    local current_pane_pid=''
    local option_pane=''

    runtime_state_load || return 1
    runtime_session_exists || return 1
    runtime_session_options_match || return 1

    current_pane_id=$(netui_tmux display-message -p -t "$NETUI_TMUX_SESSION_NAME" '#{pane_id}' 2>/dev/null) || return 1
    current_pane_pid=$(netui_tmux display-message -p -t "$NETUI_TMUX_SESSION_NAME" '#{pane_pid}' 2>/dev/null) || return 1
    option_pane=$(netui_tmux show-option -qv -t "$NETUI_TMUX_SESSION_NAME" @netui_pane 2>/dev/null) || option_pane=''

    [[ "$current_pane_id" == "$runtime_pane_id" ]] || return 1
    [[ "$current_pane_pid" == "$runtime_pane_pid" ]] || return 1
    [[ -z "$option_pane" || "$option_pane" == "$runtime_pane_id" ]] || return 1
    return 0
}

runtime_process_matches_state() {
    local current_starttime=''

    [[ "$runtime_pane_pid" =~ ^[0-9]+$ ]] || return 1
    current_starttime=$(netui_process_starttime "$runtime_pane_pid") || return 1
    [[ "$current_starttime" == "$runtime_process_starttime" ]] || return 1
    netui_process_has_core "$runtime_pane_pid" "$runtime_core_path"
}

runtime_session_is_healthy() {
    runtime_session_metadata_matches || return 1
    runtime_process_matches_state || return 1
}

runtime_wait_for_process() {
    local core_path=$1
    local attempt=0
    local pane_id=''
    local pane_pid=''
    local starttime=''

    for ((attempt = 0; attempt < 40; attempt++)); do
        if ! runtime_session_exists; then
            return 1
        fi

        pane_id=$(netui_tmux display-message -p -t "$NETUI_TMUX_SESSION_NAME" '#{pane_id}' 2>/dev/null) || pane_id=''
        pane_pid=$(netui_tmux display-message -p -t "$NETUI_TMUX_SESSION_NAME" '#{pane_pid}' 2>/dev/null) || pane_pid=''
        if [[ "$pane_id" =~ ^%[0-9]+$ && "$pane_pid" =~ ^[0-9]+$ ]]; then
            if [[ -n "${runtime_pane_id:-}" && "$pane_id" != "$runtime_pane_id" ]]; then
                return 1
            fi
            starttime=$(netui_process_starttime "$pane_pid") || starttime=''
            if [[ -n "$starttime" ]] && netui_process_has_core "$pane_pid" "$core_path"; then
                runtime_found_pane_id=$pane_id
                runtime_found_pane_pid=$pane_pid
                runtime_found_starttime=$starttime
                return 0
            fi
        fi
        sleep 0.1
    done

    return 1
}

runtime_create_launcher() {
    local launcher=$1

    if ! (
        umask 077
        cat > "$launcher" <<'EOF'
#!/bin/bash

set -u

core_path=${1-}
config_path=${2-}
log_path=${3-}

if [[ -z "$core_path" || -z "$config_path" || -z "$log_path" ]]; then
    exit 2
fi

exec env \
    -u http_proxy \
    -u HTTP_PROXY \
    -u https_proxy \
    -u HTTPS_PROXY \
    -u all_proxy \
    -u ALL_PROXY \
    -u no_proxy \
    -u NO_PROXY \
    -- "$core_path" run -c "$config_path" >>"$log_path" 2>&1
EOF
    ); then
        rm -f -- "$launcher"
        return 1
    fi

    chmod 700 -- "$launcher"
}

_runtime_start_unlocked() {
    local config_path=''
    local core_path=''
    local status=0
    local token=''
    local launcher=''
    local created_pane=''
    local current_pane=''
    local config_hash=''
    local config_mtime=''

    config_path=$(config_store_resolve_default)
    status=$?
    if ((status != 0)); then
        if ((status == 4)); then
            netui_print_error 'no default configuration; use netui to choose one'
        else
            netui_print_error 'default.json is invalid or escapes the configs directory'
        fi
        return "$status"
    fi

    config_store_validate_config "$config_path"
    status=$?
    if ((status != 0)); then
        if ((status == 3)); then
            netui_print_error 'cannot validate default configuration because a dependency is missing'
        else
            netui_print_error "default configuration is invalid: ${config_path##*/}"
        fi
        return "$status"
    fi

    core_path=$(netui_resolve_core_path)
    status=$?
    ((status == 0)) || {
        netui_print_error 'sing-box executable is unavailable'
        return 3
    }

    runtime_require_tmux || return 3
    if runtime_session_exists; then
        if [[ -f "$NETUI_RUNTIME_STATE" && ! -L "$NETUI_RUNTIME_STATE" ]] && runtime_session_is_healthy; then
            env_profiles_enable_on_start || return 1
            netui_print_info "already running: ${runtime_config_basename}"
            return 0
        fi
        netui_print_error "tmux session '$NETUI_TMUX_SESSION_NAME' exists but is not a NetUI-owned healthy instance"
        return 6
    fi

    if [[ -e "$NETUI_RUNTIME_STATE" || -L "$NETUI_RUNTIME_STATE" || -e "$NETUI_PROXY_ENDPOINT" || -L "$NETUI_PROXY_ENDPOINT" ]]; then
        runtime_clear_state || {
            netui_print_error 'cannot clear stale runtime state safely'
            return 1
        }
    fi

    token=$(netui_random_token) || {
        netui_print_error 'cannot generate runtime token'
        return 1
    }
    config_hash=$(netui_file_sha256 "$config_path") || return 1
    config_mtime=$(netui_file_mtime "$config_path") || return 1
    launcher="$NETUI_RUNTIME_DIR/.launch-$token.sh"
    runtime_create_launcher "$launcher" || return 1

    runtime_token=$token
    runtime_session_name=$NETUI_TMUX_SESSION_NAME
    runtime_core_path=$core_path
    runtime_config_path=$config_path
    runtime_config_basename=${config_path##*/}
    runtime_config_mtime=$config_mtime
    runtime_config_sha256=$config_hash
    runtime_started_at=$(date +%s)

    created_pane=$(netui_tmux new-session -d -P -F '#{pane_id}' -s "$NETUI_TMUX_SESSION_NAME" -- "$launcher" "$core_path" "$config_path" "$NETUI_LOG_FILE")
    status=$?
    if ((status != 0)) || [[ ! "$created_pane" =~ ^%[0-9]+$ ]]; then
        rm -f -- "$launcher"
        netui_print_error 'cannot create or identify the NetUI tmux session'
        return 6
    fi

    current_pane=$(netui_tmux display-message -p -t "$NETUI_TMUX_SESSION_NAME" '#{pane_id}' 2>/dev/null) || current_pane=''
    if [[ "$current_pane" != "$created_pane" ]]; then
        rm -f -- "$launcher"
        netui_print_error 'tmux session changed before NetUI ownership could be recorded'
        return 6
    fi

    runtime_pane_id=$created_pane
    if ! netui_tmux set-option -t "$NETUI_TMUX_SESSION_NAME" @netui_token "$runtime_token" ||
        ! netui_tmux set-option -t "$NETUI_TMUX_SESSION_NAME" @netui_core "$runtime_core_path" ||
        ! netui_tmux set-option -t "$NETUI_TMUX_SESSION_NAME" @netui_pane "$runtime_pane_id"; then
        rm -f -- "$launcher"
        if ! runtime_kill_created_session "$created_pane" "$runtime_token" "$runtime_core_path"; then
            netui_print_error 'cannot mark or safely clean the tmux session as NetUI-owned'
            return 6
        fi
        netui_print_error 'cannot mark the tmux session as NetUI-owned'
        return 1
    fi

    if ! runtime_wait_for_process "$core_path"; then
        rm -f -- "$launcher"
        if ! runtime_kill_created_session "$created_pane" "$runtime_token" "$runtime_core_path"; then
            netui_print_error 'sing-box failed and the tmux ownership marker no longer matched; session left untouched'
            return 6
        fi
        netui_print_error 'sing-box did not stay alive in the NetUI tmux session'
        return 1
    fi

    runtime_pane_pid=$runtime_found_pane_pid
    runtime_process_starttime=$runtime_found_starttime

    if ! runtime_state_write || ! runtime_write_endpoint; then
        rm -f -- "$launcher"
        if ! runtime_kill_created_session "$created_pane" "$runtime_token" "$runtime_core_path"; then
            netui_print_error 'runtime persistence failed and the tmux ownership marker no longer matched; session left untouched'
            return 6
        fi
        runtime_clear_state || true
        netui_print_error 'cannot persist NetUI runtime state'
        return 1
    fi

    rm -f -- "$launcher"
    env_profiles_enable_on_start || {
        netui_print_error 'instance started, but automatic proxy environment setup failed'
        return 1
    }
    netui_print_info "started ${runtime_config_basename} in tmux session '$NETUI_TMUX_SESSION_NAME'"
    return 0
}

runtime_start() {
    netui_with_lock _runtime_start_unlocked
}

_runtime_stop_unlocked() {
    local process_pid=''
    local attempt=0

    runtime_require_tmux || return 3
    if ! runtime_session_exists; then
        if ! runtime_clear_state; then
            netui_print_error 'cannot clear stale runtime state safely'
            return 1
        fi
        runtime_notify_environment
        netui_print_info 'not running (stale runtime state cleaned)'
        return 0
    fi

    if [[ ! -f "$NETUI_RUNTIME_STATE" || -L "$NETUI_RUNTIME_STATE" ]]; then
        netui_print_error "refusing to operate on unowned tmux session '$NETUI_TMUX_SESSION_NAME'"
        return 6
    fi

    if ! runtime_session_metadata_matches; then
        netui_print_error "refusing to stop tmux session '$NETUI_TMUX_SESSION_NAME': ownership metadata mismatch"
        return 6
    fi

    process_pid=$runtime_pane_pid
    if runtime_process_matches_state; then
        kill -TERM "$process_pid" 2>/dev/null || true
        for ((attempt = 0; attempt < 30; attempt++)); do
            if ! [[ -d "/proc/$process_pid" ]]; then
                break
            fi
            if ! runtime_process_matches_state; then
                if netui_process_is_zombie "$process_pid"; then
                    break
                fi
                sleep 0.1
                continue
            fi
            sleep 0.1
        done

        if [[ -d "/proc/$process_pid" ]]; then
            if runtime_process_matches_state; then
                kill -KILL "$process_pid" 2>/dev/null || true
            elif ! netui_process_is_zombie "$process_pid" && [[ -d "/proc/$process_pid" ]]; then
                netui_print_error 'managed process identity changed while stopping; refusing to kill it'
                return 6
            fi
        fi
    elif [[ -d "/proc/$process_pid" ]]; then
        netui_print_error 'refusing to stop process with mismatched starttime or core path'
        return 6
    fi

    if runtime_session_exists; then
        if ! runtime_session_options_match; then
            netui_print_error 'tmux ownership marker changed while stopping; refusing to close the session'
            return 6
        fi
        if ! netui_tmux kill-session -t "$NETUI_TMUX_SESSION_NAME" >/dev/null 2>&1; then
            if runtime_session_exists; then
                netui_print_error 'could not close the verified NetUI tmux session'
                return 1
            fi
        fi
    fi

    if ! runtime_clear_state; then
        netui_print_error 'instance stopped but runtime state cleanup failed'
        return 1
    fi
    runtime_notify_environment
    netui_print_info 'stopped NetUI instance'
    return 0
}

runtime_stop() {
    netui_with_lock _runtime_stop_unlocked
}
