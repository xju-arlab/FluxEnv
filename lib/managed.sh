#!/bin/bash

# Shared incremental file operations. Back up and replace only when needed.
managed_require_file() {
    [ ! -L "$1" ] || die "配置文件是符号链接，请先手动处理: $1"
    [ ! -e "$1" ] || [ -f "$1" ] || die "配置路径不是普通文件: $1"
}

managed_backup() {
    local path="$1"
    [ -f "$path" ] && [ "${DRY_RUN:-0}" -eq 0 ] || return 0
    if [ -z "${STATE_BACKUP_DIR:-}" ]; then
        STATE_BACKUP_DIR="$STATE_DIR/backups/$STATE_RUN_ID"
        mkdir -p "$STATE_BACKUP_DIR"
        chmod 700 "$STATE_BACKUP_DIR"
    fi
    local label="${path#/}"
    label="${label//\//__}"
    cp -p "$path" "$STATE_BACKUP_DIR/$label"
}

managed_copy_missing() {
    local source_dir="$1"
    local target_dir="$2"
    local source_path=""
    local target_path=""
    [ ! -L "$target_dir" ] || die "插件目录不能是符号链接: $target_dir"
    if [ "${DRY_RUN:-0}" -eq 1 ]; then
        progress "[dry-run] 仅补齐目录中的缺失文件: $target_dir"
        return 0
    fi
    while IFS= read -r source_path; do
        target_path="$target_dir/${source_path#"$source_dir"/}"
        managed_require_file "$target_path"
        if [ ! -e "$target_path" ]; then
            mkdir -p "$(dirname "$target_path")"
            cp -p "$source_path" "$target_path"
        fi
    done < <(find "$source_dir" -name .git -prune -o -type f -print)
}

managed_install_file() {
    local path="$1"
    local candidate="$2"
    local adopt_generated="${3:-0}"
    local resource="file:$path"
    STATE_CURRENT_RESOURCE="$resource"
    local installed=""
    local current=""
    local desired=""
    managed_require_file "$path"
    desired="$(state_file_signature "$candidate")"
    if [ -f "$path" ]; then
        current="$(state_file_signature "$path")"
        installed="$(state_get receipts "$resource")"
        if cmp -s "$path" "$candidate"; then
            progress "复用配置: $path"
            state_record "$resource" reused "$desired"
            return 0
        fi
        if { [ -n "$installed" ] && [ "$installed" != "$current" ]; } ||
            { [ -z "$installed" ] && [ "$adopt_generated" -ne 1 ]; }; then
            progress "保留已有自定义配置: $path"
            state_record "$resource" preserved
            return 0
        fi
    fi
    if [ "${DRY_RUN:-0}" -eq 1 ]; then
        progress "[dry-run] 新增/更新配置: $path"
        return 0
    fi
    managed_backup "$path"
    mkdir -p "$(dirname "$path")"
    local temporary=""
    temporary="$(mktemp "${path}.tmp.XXXXXX")"
    if ! cp "$candidate" "$temporary" || ! chmod 600 "$temporary" || ! mv -f "$temporary" "$path"; then
        rm -f "$temporary"
        die "无法更新配置: $path"
    fi
    state_record "$resource" applied "$desired"
}

managed_validate_block() {
    local path="$1"
    local start="$2"
    local end="$3"
    managed_require_file "$path"
    [ -f "$path" ] || return 0
    awk -v start="$start" -v end="$end" '
        $0 == start { if (inside || seen) bad=1; inside=1; seen=1 }
        $0 == end { if (!inside) bad=1; inside=0 }
        END { exit (bad || inside) ? 1 : 0 }
    ' "$path" || die "托管标记不完整或重复，请先修复: $path"
}

managed_update_block() {
    local path="$1"
    local start="$2"
    local end="$3"
    local body="$4"
    local resource="block:$path:$start"
    STATE_CURRENT_RESOURCE="$resource"
    local current=""
    local desired=""
    local installed=""
    local input="/dev/null"
    managed_validate_block "$path" "$start" "$end"
    desired="$(printf '%s\n' "$body" | state_signature)"
    if [ -f "$path" ]; then
        input="$path"
        if grep -Fxq "$start" "$path"; then
            current="$(awk -v start="$start" -v end="$end" '
                $0 == start { inside=1; next } $0 == end { inside=0; next } inside {print}
            ' "$path" | state_signature)"
            installed="$(state_get receipts "$resource")"
            if [ "$current" = "$desired" ]; then
                progress "复用托管块: $path"
                state_record "$resource" reused "$desired"
                return 0
            fi
            if [ -n "$installed" ] && [ "$installed" != "$current" ]; then
                progress "保留本地修改的托管块: $path"
                state_record "$resource" preserved
                return 0
            fi
        fi
    fi
    if [ "${DRY_RUN:-0}" -eq 1 ]; then
        progress "[dry-run] 补齐/更新托管块: $path"
        return 0
    fi
    mkdir -p "$(dirname "$path")"
    local temporary=""
    temporary="$(mktemp "${path}.tmp.XXXXXX")"
    if ! FLUXENV_BLOCK_BODY="$body" awk -v start="$start" -v end="$end" '
        $0 == start { print start; print ENVIRON["FLUXENV_BLOCK_BODY"]; print end; inside=1; found=1; next }
        $0 == end { inside=0; next }
        !inside { print }
        END { if (!found) { if (NR) print ""; print start; print ENVIRON["FLUXENV_BLOCK_BODY"]; print end } }
    ' "$input" > "$temporary"; then
        rm -f "$temporary"
        die "无法生成托管配置: $path"
    fi
    managed_backup "$path"
    if ! chmod 600 "$temporary" || ! mv -f "$temporary" "$path"; then
        rm -f "$temporary"
        die "无法保存托管配置: $path"
    fi
    state_record "$resource" applied "$desired"
}
