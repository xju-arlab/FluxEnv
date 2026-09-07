#!/bin/bash

netui_print_error() {
    printf 'netui: %s\n' "$*" >&2
}

netui_print_info() {
    printf 'netui: %s\n' "$*"
}

netui_require_command() {
    local command_name=$1

    if ! command -v "$command_name" >/dev/null 2>&1; then
        netui_print_error "missing dependency: $command_name"
        return 3
    fi

    return 0
}

netui_path_is_within() {
    local root=$1
    local path=$2

    [[ "$path" == "$root" || "$path" == "$root/"* ]]
}

netui_random_token() {
    local token=''

    token=$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d '[:space:]') || token=''
    if [[ ! "$token" =~ ^[0-9a-f]{32}$ ]]; then
        token="$(printf '%s-%s-%s' "${BASHPID:-$$}" "$RANDOM" "$(date +%s%N 2>/dev/null || date +%s)")"
        token=$(printf '%s' "$token" | sha256sum 2>/dev/null | cut -d' ' -f1)
    fi

    [[ "$token" =~ ^[0-9a-f]{32,}$ ]] || return 1
    printf '%s' "$token"
}

netui_resolve_core_path() {
    local candidate=''
    local resolved=''

    if [[ -n "${NETUI_SING_BOX:-}" ]]; then
        candidate=$NETUI_SING_BOX
        if [[ "$candidate" != */* ]]; then
            candidate=$(command -v "$candidate" 2>/dev/null) || return 3
        fi
    elif [[ -n "${NETUI_PACKAGE_ROOT:-}" && -x "$NETUI_PACKAGE_ROOT/bin/sing-box" ]]; then
        candidate="$NETUI_PACKAGE_ROOT/bin/sing-box"
    else
        candidate=$(command -v sing-box 2>/dev/null) || return 3
    fi

    resolved=$(realpath -e -- "$candidate" 2>/dev/null) || return 3
    [[ "$resolved" == /* && -f "$resolved" && -x "$resolved" ]] || return 3

    NETUI_CORE_PATH=$resolved
    printf '%s' "$resolved"
}

netui_process_starttime() {
    local pid=$1
    local stat_line=''
    local -a stat_fields=()

    [[ "$pid" =~ ^[0-9]+$ && -r "/proc/$pid/stat" ]] || return 1
    IFS= read -r stat_line 2>/dev/null < "/proc/$pid/stat" || return 1
    stat_line=${stat_line##*) }
    read -r -a stat_fields <<< "$stat_line"
    [[ "${#stat_fields[@]}" -ge 20 ]] || return 1

    printf '%s' "${stat_fields[19]}"
}

netui_process_is_zombie() {
    local pid=$1
    local stat_line=''
    local -a stat_fields=()

    [[ "$pid" =~ ^[0-9]+$ && -r "/proc/$pid/stat" ]] || return 1
    IFS= read -r stat_line 2>/dev/null < "/proc/$pid/stat" || return 1
    stat_line=${stat_line##*) }
    read -r -a stat_fields <<< "$stat_line"
    [[ "${#stat_fields[@]}" -ge 1 && "${stat_fields[0]}" == Z ]]
}

netui_process_has_core() {
    local pid=$1
    local expected_core=$2
    local process_exe=''
    local interpreter=''
    local command_line=''
    local remaining_args=''
    local first_arg=''
    local second_arg=''
    local third_arg=''

    [[ "$pid" =~ ^[0-9]+$ && -r "/proc/$pid/cmdline" ]] || return 1
    [[ "$expected_core" == /* && -f "$expected_core" && -x "$expected_core" ]] || return 1

    process_exe=$(readlink -e -- "/proc/$pid/exe" 2>/dev/null) || process_exe=''
    if [[ "$process_exe" == "$expected_core" ]]; then
        return 0
    fi

    # Test fixtures may use an executable shell script instead of an ELF core.
    # Accept only the kernel's strict shebang layouts, never an arbitrary argv.
    command_line=$(tr '\0' '\n' 2>/dev/null < "/proc/$pid/cmdline") || return 1
    first_arg=${command_line%%$'\n'*}
    if [[ "$command_line" == *$'\n'* ]]; then
        remaining_args=${command_line#*$'\n'}
    else
        remaining_args=''
    fi
    second_arg=${remaining_args%%$'\n'*}
    if [[ "$remaining_args" == *$'\n'* ]]; then
        third_arg=${remaining_args#*$'\n'}
        third_arg=${third_arg%%$'\n'*}
    else
        third_arg=''
    fi
    interpreter=$first_arg
    case "${interpreter##*/}" in
        bash|dash|sh|zsh)
            [[ "$second_arg" == "$expected_core" ]] && return 0
            ;;
        env)
            case "$second_arg" in
                bash|dash|sh|zsh)
                    [[ "$third_arg" == "$expected_core" ]] && return 0
                    ;;
            esac
            ;;
    esac

    return 1
}

netui_file_sha256() {
    local path=$1
    local checksum_line=''

    checksum_line=$(sha256sum -- "$path" 2>/dev/null) || return 1
    printf '%s' "${checksum_line%% *}"
}

netui_file_mtime() {
    local path=$1

    stat -c '%Y' -- "$path" 2>/dev/null
}

netui_with_lock() {
    local callback=$1
    shift
    local lock_fd=''
    local lock_timeout=${NETUI_LOCK_TIMEOUT:-10}
    local status=0

    [[ "$lock_timeout" =~ ^[0-9]+$ ]] || lock_timeout=10
    netui_init_dirs || return 1
    netui_require_command flock || return 3

    exec {lock_fd}>"$NETUI_LOCK_FILE" || {
        netui_print_error "cannot open lifecycle lock"
        return 1
    }
    chmod 600 -- "$NETUI_LOCK_FILE" 2>/dev/null || true

    if ! flock -w "$lock_timeout" "$lock_fd"; then
        exec {lock_fd}>&-
        netui_print_error "lifecycle lock timed out"
        return 8
    fi

    "$callback" "$@"
    status=$?

    flock -u "$lock_fd" 2>/dev/null || true
    exec {lock_fd}>&-
    return "$status"
}
