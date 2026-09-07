#!/bin/bash

tui_gum_path() {
    local candidate=''

    if [[ -n "${NETUI_GUM:-}" ]]; then
        candidate=$NETUI_GUM
    elif [[ -n "${NETUI_PACKAGE_ROOT:-}" && -x "$NETUI_PACKAGE_ROOT/bin/gum" ]]; then
        candidate="$NETUI_PACKAGE_ROOT/bin/gum"
    else
        candidate=$(command -v gum 2>/dev/null) || return 1
    fi
    [[ -x "$candidate" && ! -d "$candidate" ]] || return 1
    printf '%s' "$candidate"
}

tui_use_gum() {
    [[ "${TERM:-}" != dumb ]] || return 1
    tui_gum_path >/dev/null 2>&1
}

tui_choose_action() {
    local gum_path=''
    local choice=''

    if tui_use_gum && gum_path=$(tui_gum_path 2>/dev/null); then
        choice=$("$gum_path" choose \
            'd  default' 'v  validate' 'u  start default' 'x  stop' 'r  restart' \
            'p  environment mode' 'l  logs' 'i  import' 'n  rename' 'a  archive' 'w  restore' \
            'e  detail' 'h  shell hook' 'q  quit') || return 1
        printf '%s' "${choice%% *}"
        return 0
    fi

    printf 'Action: ' >&2
    IFS= read -r choice || return 1
    printf '%s' "$choice"
}

tui_refresh_configs() {
    local path=''

    tui_config_paths=()
    while IFS= read -r -d '' path; do
        tui_config_paths+=("$path")
    done < <(config_store_discover)
}

tui_running_state() {
    tui_running_basename=''
    tui_running_status=stopped

    if [[ ! -f "$NETUI_RUNTIME_STATE" || -L "$NETUI_RUNTIME_STATE" ]]; then
        return 0
    fi
    if ! runtime_state_load; then
        tui_running_status=stale
        return 0
    fi
    tui_running_basename=$runtime_config_basename
    if runtime_session_is_healthy; then
        tui_running_status=running
    else
        tui_running_status=stale
    fi
}

tui_protocol_for_config() {
    local path=$1

    jq -r '
        [.outbounds[]? | .type? // empty] as $types |
        ([$types[] | select(. != "direct" and . != "block" and . != "dns" and . != "selector" and . != "urltest")] | .[0]) as $type |
        if $type == null then "unknown"
        elif $type == "vless" and ([.outbounds[]? | select(.type == "vless") | (.tls?.reality?.enabled // false)] | any) then "vless/reality"
        else $type
        end
    ' "$path" 2>/dev/null || printf 'unknown'
}

tui_local_for_config() {
    local path=$1

    jq -r '[.inbounds[]? | select(.listen? and .listen_port?) | "\(.listen):\(.listen_port)"] | .[0] // "—"' "$path" 2>/dev/null || printf '—'
}

tui_check_for_config() {
    local path=$1
    local status=0

    config_store_validate_config "$path" >/dev/null 2>&1
    status=$?
    case "$status" in
        0) printf 'ok' ;;
        3) printf 'dep' ;;
        *) printf 'bad' ;;
    esac
}

tui_default_basename() {
    config_store_default_basename 2>/dev/null || true
}

tui_terminal_width() {
    local width=${COLUMNS:-}

    if [[ ! "$width" =~ ^[0-9]+$ ]]; then
        width=$(tput cols 2>/dev/null || printf '80')
    fi
    [[ "$width" =~ ^[0-9]+$ ]] || width=80
    printf '%s' "$width"
}

tui_box_text() {
    local title=$1
    shift
    local line=''
    local display_line=''
    local width=80
    local inner_width=74
    local border=''
    local padding=0

    width=$(tui_terminal_width)
    ((width >= 28)) || width=28
    inner_width=$((width - 4))
    border=$(printf '%*s' "$((inner_width + 2))" '')
    border=${border// /─}
    printf '╭%s╮\n' "$border"
    display_line=${title:0:inner_width}
    padding=$((inner_width - ${#display_line}))
    ((padding >= 0)) || padding=0
    printf '│ %s%*s │\n' "$display_line" "$padding" ''
    printf '├%s┤\n' "$border"
    for line in "$@"; do
        display_line=${line:0:inner_width}
        padding=$((inner_width - ${#display_line}))
        ((padding >= 0)) || padding=0
        printf '│ %s%*s │\n' "$display_line" "$padding" ''
    done
    printf '╰%s╯\n' "$border"
}

tui_environment_summary() {
    local mode='off'
    local effective='off'
    local bytes=0

    mode=$(env_profiles_get_mode 2>/dev/null) || mode=off
    if env_profiles_compute_environment; then
        effective=on
        bytes=$(env_profiles_no_proxy_bytes "$env_no_proxy")
    fi
    printf '%s|%s|%s' "$mode" "$effective" "$bytes"
}

tui_render_compact_dashboard() {
    local default_basename=''
    local env_summary=''
    local env_mode=''
    local env_effective=''
    local env_bytes=''
    local path=''
    local basename=''
    local marker=' '
    local protocol=''
    local check_status=''
    local index=0
    local -a config_lines=()

    tui_refresh_configs
    tui_running_state
    default_basename=$(tui_default_basename)
    env_summary=$(tui_environment_summary)
    IFS='|' read -r env_mode env_effective env_bytes <<< "$env_summary"
    tui_box_text 'NetUI (compact)' \
        "run: $tui_running_status ${tui_running_basename:-—}" \
        "default: ${default_basename:-—}" \
        "env: $env_mode effective:$env_effective no_proxy:${env_bytes}B"
    if ((${#tui_config_paths[@]} == 0)); then
        config_lines=('no configuration; use i/import')
    else
        for path in "${tui_config_paths[@]}"; do
            basename=${path##*/}
            marker=' '
            [[ "$basename" == "$default_basename" ]] && marker='★'
            [[ "$basename" == "$tui_running_basename" ]] && marker="${marker}●"
            protocol=$(tui_protocol_for_config "$path")
            check_status=$(tui_check_for_config "$path")
            index=$((index + 1))
            config_lines+=("$index$marker ${basename:0:28} ${protocol:0:12} $check_status")
        done
    fi
    tui_box_text 'Configs' "${config_lines[@]}"
    printf '%s\n' 'Actions: d/v/u/x/r/p/l/i/n/a/e/h/q'
}

tui_render_dashboard() {
    if declare -F tui_v2_render_dashboard >/dev/null 2>&1 &&
        [[ "${NETUI_TUI_FALLBACK:-0}" != 1 ]]; then
        tui_v2_render_dashboard
        return $?
    fi

    local default_basename=''
    local env_summary=''
    local env_mode=''
    local env_effective=''
    local env_bytes=''
    local path=''
    local basename=''
    local marker=' '
    local protocol=''
    local local_endpoint=''
    local check_status=''
    local index=0
    local gum_path=''
    local header_text=''

    if (( $(tui_terminal_width) < 80 )); then
        tui_render_compact_dashboard
        return 0
    fi

    tui_refresh_configs
    tui_running_state
    default_basename=$(tui_default_basename)
    env_summary=$(tui_environment_summary)
    IFS='|' read -r env_mode env_effective env_bytes <<< "$env_summary"

    header_text="NetUI | running: $tui_running_status ${tui_running_basename:-—}"
    if [[ "$default_basename" != "" && "$default_basename" != "$tui_running_basename" && "$tui_running_status" == running ]]; then
        header_text="$header_text | restart required"
    fi

    if gum_path=$(tui_gum_path 2>/dev/null) && [[ "${TERM:-}" != dumb ]]; then
        if ! "$gum_path" style --border rounded --padding '0 1' "$header_text" "default: ${default_basename:-—}" "env: $env_mode effective:$env_effective no_proxy:${env_bytes}B"; then
            tui_box_text 'NetUI' "$header_text" "default: ${default_basename:-—}" "env: $env_mode effective:$env_effective no_proxy:${env_bytes}B"
        fi
    else
        tui_box_text 'NetUI' "$header_text" "default: ${default_basename:-—}" "env: $env_mode effective:$env_effective no_proxy:${env_bytes}B"
    fi

    printf '╭─ Configurations ────────────────────────────────────────────────────────────╮\n'
    printf '│ MARK  CONFIG                              PROTOCOL        LOCAL       CHECK │\n'
    if ((${#tui_config_paths[@]} == 0)); then
        printf '│       no JSON configurations found; use import                         │\n'
    else
        for path in "${tui_config_paths[@]}"; do
            basename=${path##*/}
            marker=' '
            [[ "$basename" == "$default_basename" ]] && marker='★'
            [[ "$basename" == "$tui_running_basename" ]] && marker="${marker}●"
            protocol=$(tui_protocol_for_config "$path")
            local_endpoint=$(tui_local_for_config "$path")
            check_status=$(tui_check_for_config "$path")
            index=$((index + 1))
            printf '│ %-4s %-36s %-15s %-11s %-5s │\n' "$index$marker" "${basename:0:36}" "${protocol:0:15}" "${local_endpoint:0:11}" "$check_status"
        done
    fi
    printf '╰────────────────────────────────────────────────────────────────────────────╯\n'
    printf '%s\n' 'Actions: d default  v validate  u start  x stop  r restart  p env  l logs'
    printf '%s\n' '         i import   n rename   a archive w restore e detail h shell-hook q quit'
}

tui_select_config() {
    local selection=''
    local index=0
    local gum_path=''
    local choice=''
    local path=''
    local -a choices=()

    ((${#tui_config_paths[@]} > 0)) || return 1
    if tui_use_gum && gum_path=$(tui_gum_path 2>/dev/null); then
        index=0
        for path in "${tui_config_paths[@]}"; do
            index=$((index + 1))
            choices+=("$index) ${path##*/}")
        done
        choice=$("$gum_path" choose "${choices[@]}") || return 1
        selection=${choice%%)*}
    else
        printf 'Configuration number [1]: '
        IFS= read -r selection || return 1
        [[ -n "$selection" ]] || selection=1
    fi
    [[ "$selection" =~ ^[0-9]+$ ]] || return 1
    index=$((selection - 1))
    ((index >= 0 && index < ${#tui_config_paths[@]})) || return 1
    tui_selected_path=${tui_config_paths[$index]}
    return 0
}

tui_confirm() {
    local answer=''
    local gum_path=''

    if tui_use_gum && gum_path=$(tui_gum_path 2>/dev/null); then
        "$gum_path" confirm "$1"
        return $?
    fi
    printf '%s [y/N] ' "$1"
    IFS= read -r answer || return 1
    [[ "$answer" == y || "$answer" == Y ]]
}

tui_action_set_default() {
    [[ -n "${tui_selected_path:-}" ]] || return 1
    if [[ "${tui_running_status:-}" == running && "${tui_selected_path##*/}" != "${tui_running_basename:-}" ]]; then
        tui_confirm "Set ${tui_selected_path##*/} as default without restarting the running instance?" || return 0
    fi
    if ! config_store_set_default "$tui_selected_path"; then
        netui_print_error 'cannot set selected configuration as default'
        return 1
    fi
    if [[ "${tui_running_status:-}" == running && "${tui_selected_path##*/}" != "${tui_running_basename:-}" ]]; then
        netui_print_info 'default changed; current instance remains until restart'
    else
        netui_print_info "default set to ${tui_selected_path##*/}"
    fi
}

tui_action_validate() {
    [[ -n "${tui_selected_path:-}" ]] || return 1
    if config_store_validate_config "$tui_selected_path"; then
        netui_print_info "valid: ${tui_selected_path##*/}"
        return 0
    fi
    netui_print_error "invalid: ${tui_selected_path##*/}"
    return 5
}

tui_action_start() {
    runtime_start
}

tui_action_stop() {
    runtime_stop
}

tui_action_restart() {
    runtime_stop || return $?
    runtime_start
}

tui_action_environment() {
    local selection=''
    local mode=''
    local gum_path=''
    local choice=''

    if tui_use_gum && gum_path=$(tui_gum_path 2>/dev/null); then
        choice=$("$gum_path" choose \
            '1  global proxy (loopback-only no_proxy)' \
            '2  cn-direct (controlled mainland suffix allowlist)') || return 1
        selection=${choice%% *}
    else
        printf '%s\n' '1) global proxy (loopback-only no_proxy)'
        printf '%s\n' '2) cn-direct (controlled mainland suffix allowlist)'
        printf 'Environment mode [2]: '
        IFS= read -r selection || return 1
        [[ -n "$selection" ]] || selection=2
    fi
    case "$selection" in
        1) mode=global ;;
        2) mode=cn-direct ;;
        *) return 2 ;;
    esac
    env_profiles_set_mode "$mode"
}

tui_action_logs() {
    if [[ -f "$NETUI_LOG_FILE" && ! -L "$NETUI_LOG_FILE" ]]; then
        tail -n 80 -- "$NETUI_LOG_FILE"
    else
        netui_print_info 'no sing-box log yet'
    fi
}

tui_action_detail() {
    local path=${tui_selected_path:-}
    local reality='off'

    [[ -n "$path" ]] || return 1
    reality=$(jq -r 'if any(.outbounds[]?.tls?.reality?.enabled // false) then "on" else "off" end' "$path" 2>/dev/null || printf 'unknown')
    tui_box_text "Details: ${path##*/}" \
        "path: $path" \
        "mode: $(stat -c '%a' -- "$path" 2>/dev/null || printf '?')" \
        "mtime: $(stat -c '%Y' -- "$path" 2>/dev/null || printf '?')" \
        "protocol: $(tui_protocol_for_config "$path")" \
        "local: $(tui_local_for_config "$path")" \
        "reality: $reality" \
        'credentials: hidden'
}

tui_action_import() {
    local source_path=''
    local target_basename=''

    printf 'Import source path: '
    IFS= read -r source_path || return 1
    printf 'Target basename (*.json): '
    IFS= read -r target_basename || return 1
    config_store_import "$source_path" "$target_basename"
}

tui_action_rename() {
    local new_basename=''

    [[ -n "${tui_selected_path:-}" ]] || return 1
    printf 'New basename (*.json): '
    IFS= read -r new_basename || return 1
    config_store_rename "$tui_selected_path" "$new_basename"
}

tui_action_archive() {
    [[ -n "${tui_selected_path:-}" ]] || return 1
    tui_confirm "Archive ${tui_selected_path##*/} to the recoverable trash area?" || return 0
    config_store_archive "$tui_selected_path"
}

tui_action_restore() {
    local archive_path=''
    local target_basename=''

    printf 'Archive path: '
    IFS= read -r archive_path || return 1
    printf 'Restore basename (*.json): '
    IFS= read -r target_basename || return 1
    config_store_restore "$archive_path" "$target_basename"
}

tui_action_shell_hook() {
    shell_integration_install
}

tui_execute_action() {
    local action=$1

    case "$action" in
        d)
            tui_select_config && tui_action_set_default
            ;;
        v)
            tui_select_config && tui_action_validate
            ;;
        u)
            tui_action_start
            ;;
        x)
            if tui_confirm 'Stop the current NetUI instance?'; then
                tui_action_stop
            fi
            ;;
        r)
            if tui_confirm 'Stop and start the default NetUI instance?'; then
                tui_action_restart
            fi
            ;;
        p)
            tui_action_environment
            ;;
        l)
            tui_action_logs
            ;;
        i)
            tui_action_import
            ;;
        n)
            tui_select_config && tui_action_rename
            ;;
        a)
            tui_select_config && tui_action_archive
            ;;
        w)
            tui_action_restore
            ;;
        e)
            tui_select_config && tui_action_detail
            ;;
        h)
            tui_action_shell_hook
            ;;
        q)
            return 10
            ;;
        *)
            netui_print_error 'unknown TUI action'
            return 2
            ;;
    esac
}

tui_execute_test_actions() {
    local action_string=${NETUI_TUI_ACTIONS:-}
    local action=''
    local argument=''
    local status=0
    local current_path=''

    IFS=';' read -r -a tui_test_action_list <<< "$action_string"
    for action in "${tui_test_action_list[@]}"; do
        case "$action" in
            list)
                tui_render_dashboard
                ;;
            default:*)
                argument=${action#default:}
                current_path="$NETUI_CONFIG_DIR/$argument"
                config_store_set_default "$current_path" || status=$?
                ;;
            validate:*)
                argument=${action#validate:}
                current_path="$NETUI_CONFIG_DIR/$argument"
                config_store_validate_config "$current_path" || status=$?
                ;;
            import:*)
                argument=${action#import:}
                current_path=${argument%%:*}
                argument=${argument#*:}
                config_store_import "$current_path" "$argument" || status=$?
                ;;
            rename:*)
                argument=${action#rename:}
                current_path=${argument%%:*}
                argument=${argument#*:}
                config_store_rename "$current_path" "$argument" || status=$?
                ;;
            archive:*)
                argument=${action#archive:}
                config_store_archive "$NETUI_CONFIG_DIR/$argument" || status=$?
                ;;
            restore:*)
                argument=${action#restore:}
                current_path=${argument%%:*}
                argument=${argument#*:}
                config_store_restore "$current_path" "$argument" || status=$?
                ;;
            env:*)
                env_profiles_set_mode "${action#env:}" || status=$?
                ;;
            start)
                runtime_start || status=$?
                ;;
            stop)
                runtime_stop || status=$?
                ;;
            restart)
                tui_action_restart || status=$?
                ;;
            shell-hook)
                shell_integration_install || status=$?
                ;;
            detail:*)
                tui_selected_path="$NETUI_CONFIG_DIR/${action#detail:}"
                tui_action_detail || status=$?
                ;;
            quit|'')
                ;;
            *)
                netui_print_error "unknown test action: $action"
                status=2
                ;;
        esac
    done
    return "$status"
}

tui_run_loop() {
    local action=''

    while :; do
        tui_render_dashboard
        action=$(tui_choose_action) || return 0
        if tui_execute_action "$action"; then
            :
        else
            local status=$?
            ((status == 10)) && return 0
            ((status != 0)) && netui_print_error "action failed with exit $status"
        fi
        printf '\nPress Enter to continue... '
        IFS= read -r _ || true
    done
}

tui_run() {
    if (($# > 0)); then
        case "$1" in
            --help)
                printf '%s\n' 'Usage: netui'
                return 0
                ;;
            --version)
                netctl_version
                return 0
                ;;
            *)
                netui_print_error 'netui does not accept arguments'
                return 2
                ;;
        esac
    fi

    netui_init_dirs || return 1
    netui_require_command jq || return 3
    if [[ -n "${NETUI_TUI_ACTIONS:-}" ]]; then
        tui_execute_test_actions
        return $?
    fi
    if [[ ! -t 0 || ! -t 1 ]]; then
        netui_print_error 'netui requires an interactive terminal'
        return 2
    fi
    if declare -F tui_v2_run >/dev/null 2>&1 &&
        [[ "${TERM:-}" != dumb && "${NETUI_TUI_FALLBACK:-0}" != 1 ]]; then
        tui_v2_run
        return $?
    fi
    trap 'printf "\\n"; exit 130' INT TERM
    tui_run_loop
    local status=$?
    trap - INT TERM
    return "$status"
}
