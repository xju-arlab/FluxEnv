#!/bin/bash

shell_integration_init_path() {
    if [[ -n "${NETUI_SHELL_INIT_PATH:-}" ]]; then
        printf '%s' "$NETUI_SHELL_INIT_PATH"
    elif [[ -n "${NETUI_PACKAGE_ROOT:-}" ]]; then
        printf '%s/share/shell/init.sh' "$NETUI_PACKAGE_ROOT"
    else
        printf '%s' "${XDG_DATA_HOME:-$HOME/.local/share}/netui/current/share/shell/init.sh"
    fi
}

shell_integration_block() {
    local init_path=$1
    local escaped_path=''

    escaped_path=$(printf '%q' "$init_path")
    printf '%s\n' '# >>> netui shell integration >>>'
    printf '[ -r %s ] && source %s\n' "$escaped_path" "$escaped_path"
    printf '%s\n' '# <<< netui shell integration <<<'
}

shell_integration_marker_count() {
    local rc_file=$1
    local marker=$2

    grep -Fxc -- "$marker" "$rc_file" 2>/dev/null || true
}

shell_integration_backup_file() {
    local rc_file=$1
    local backup_dir=$2

    [[ -f "$rc_file" && ! -L "$rc_file" ]] || return 0
    cp -p -- "$rc_file" "$backup_dir/${rc_file##*/}"
}

shell_integration_prepare_backup_dir() {
    local timestamp=''
    local backup_dir=''

    timestamp=$(date +%Y%m%d%H%M%S)
    backup_dir="$NETUI_BACKUP_DIR/shell/$timestamp"
    local attempt=0
    while [[ -e "$backup_dir" || -L "$backup_dir" ]]; do
        attempt=$((attempt + 1))
        backup_dir="$NETUI_BACKUP_DIR/shell/${timestamp}-$attempt"
    done
    mkdir -p -- "$backup_dir" || return 1
    chmod 700 -- "$backup_dir" || return 1
    printf '%s' "$backup_dir"
}

shell_integration_install_file() {
    local rc_file=$1
    local init_path=$2
    local start_marker='# >>> netui shell integration >>>'
    local end_marker='# <<< netui shell integration <<<'
    local start_count=0
    local end_count=0
    local temporary_file=''
    local inside_block=0
    local line=''

    [[ "$rc_file" == /* && "$init_path" == /* ]] || return 1
    if [[ ! -e "$rc_file" ]]; then
        (umask 077; touch -- "$rc_file") || return 1
    fi
    [[ -f "$rc_file" && ! -L "$rc_file" ]] || return 1

    start_count=$(shell_integration_marker_count "$rc_file" "$start_marker")
    end_count=$(shell_integration_marker_count "$rc_file" "$end_marker")
    if ((start_count > 0 || end_count > 0)); then
        ((start_count == 1 && end_count == 1)) || return 1
    fi

    temporary_file=$(umask 077; mktemp "$rc_file.netui.XXXXXX") || return 1
    # Place the hook before Ubuntu's noninteractive early return so SSH commands
    # inherit the same environment as an interactive terminal.
    {
        shell_integration_block "$init_path"
        while IFS= read -r line || [[ -n "$line" ]]; do
            if [[ "$line" == "$start_marker" ]]; then
                inside_block=1
                continue
            fi
            if [[ "$line" == "$end_marker" ]]; then
                inside_block=0
                continue
            fi
            ((inside_block == 0)) && printf '%s\n' "$line"
        done < "$rc_file"
        true
    } > "$temporary_file" || {
        rm -f -- "$temporary_file"
        return 1
    }
    chmod --reference="$rc_file" "$temporary_file" || {
        rm -f -- "$temporary_file"
        return 1
    }
    mv -Tf -- "$temporary_file" "$rc_file" || return 1
    return 0
}

shell_integration_remove_file() {
    local rc_file=$1
    local start_marker='# >>> netui shell integration >>>'
    local end_marker='# <<< netui shell integration <<<'
    local start_count=0
    local end_count=0
    local temporary_file="$rc_file.netui.tmp.$$.$RANDOM"
    local inside_block=0
    local line=''

    [[ -f "$rc_file" && ! -L "$rc_file" ]] || return 0
    start_count=$(shell_integration_marker_count "$rc_file" "$start_marker")
    end_count=$(shell_integration_marker_count "$rc_file" "$end_marker")
    if ((start_count == 0 && end_count == 0)); then
        return 0
    fi
    ((start_count == 1 && end_count == 1)) || return 1

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "$start_marker" ]]; then
            inside_block=1
            continue
        fi
        if [[ "$line" == "$end_marker" ]]; then
            inside_block=0
            continue
        fi
        ((inside_block == 0)) && printf '%s\n' "$line"
    done < "$rc_file" > "$temporary_file" || {
        rm -f -- "$temporary_file"
        return 1
    }
    chmod --reference="$rc_file" "$temporary_file" 2>/dev/null || chmod 600 -- "$temporary_file"
    mv -Tf -- "$temporary_file" "$rc_file"
}

_shell_integration_install_unlocked() {
    local init_path=''
    local backup_dir=''
    local rc_file=''

    init_path=$(shell_integration_init_path)
    [[ -f "$init_path" && ! -L "$init_path" ]] || {
        netui_print_error "shell init file is missing: $init_path"
        return 1
    }
    backup_dir=$(shell_integration_prepare_backup_dir) || return 1

    for rc_file in "$HOME/.bashrc" "$HOME/.zshenv" "$HOME/.zshrc"; do
        shell_integration_backup_file "$rc_file" "$backup_dir" || return 1
    done
    for rc_file in "$HOME/.bashrc" "$HOME/.zshenv" "$HOME/.zshrc"; do
        shell_integration_install_file "$rc_file" "$init_path" || return 1
    done
    netui_print_info 'Bash and Zsh shell integration installed idempotently'
    return 0
}

shell_integration_install() {
    netui_with_lock _shell_integration_install_unlocked
}

_shell_integration_remove_unlocked() {
    local backup_dir=''
    local rc_file=''

    backup_dir=$(shell_integration_prepare_backup_dir) || return 1
    for rc_file in "$HOME/.bashrc" "$HOME/.zshenv" "$HOME/.zshrc"; do
        shell_integration_backup_file "$rc_file" "$backup_dir" || return 1
    done
    for rc_file in "$HOME/.bashrc" "$HOME/.zshenv" "$HOME/.zshrc"; do
        shell_integration_remove_file "$rc_file" || return 1
    done
    netui_print_info 'Bash and Zsh shell integration removed'
    return 0
}

shell_integration_remove() {
    netui_with_lock _shell_integration_remove_unlocked
}
