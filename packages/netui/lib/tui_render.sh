#!/bin/bash

# Model, frame rendering, and actions for the fullscreen NetUI interface.

tui_v2_selected_index=0
tui_v2_selected_basename=''
tui_v2_scroll_offset=0
tui_v2_model_ready=0
tui_v2_running=1
tui_v2_needs_redraw=1
tui_v2_resize_pending=0
tui_v2_last_size=''
tui_v2_status_message=''
tui_v2_status_level='info'
tui_v2_modal_message=''
tui_v2_cols=80
tui_v2_rows=24
tui_v2_frame_width=79
tui_v2_inner_width=77
tui_v2_frame=''
tui_v2_fit_result=''
tui_v2_field_result=''
tui_v2_clean_result=''
tui_v2_environment='cn-direct|off|0'
tui_v2_version='?'
tui_v2_previous_size=''
tui_v2_previous_screen=-1
declare -a tui_v2_previous_lines=()
tui_v2_color_enabled=0
tui_v2_theme_reset=''
tui_v2_theme_canvas=''
tui_v2_theme_border=''
tui_v2_theme_title=''
tui_v2_theme_toolbar=''
tui_v2_theme_section=''
tui_v2_theme_header=''
tui_v2_theme_row=''
tui_v2_theme_selected=''
tui_v2_theme_invalid=''
tui_v2_theme_footer=''
tui_v2_theme_info=''
tui_v2_theme_error=''
tui_v2_theme_modal=''
declare -a tui_v2_names=()
declare -a tui_v2_protocols=()
declare -a tui_v2_servers=()
declare -a tui_v2_ports=()
declare -a tui_v2_transports=()
declare -a tui_v2_security=()
declare -a tui_v2_locals=()
declare -a tui_v2_checks=()
declare -a tui_v2_paths=()
declare -a tui_v2_latencies=()
declare -a tui_v2_speeds=()
declare -a tui_v2_logs=()

tui_v2_sanitize_text() {
    local input=${1:-}
    local output=''
    local char=''
    local state=plain
    local ordinal=0
    local index=0
    local ascii_pattern='^[ -~]*$'

    if [[ "$input" =~ $ascii_pattern ]]; then
        tui_v2_clean_result=$input
        return 0
    fi

    tui_terminal_init_text_locale
    local LC_ALL=$tui_terminal_text_locale
    for ((index = 0; index < ${#input}; index++)); do
        char=${input:index:1}
        printf -v ordinal '%d' "'$char"
        case "$state" in
            plain)
                if ((ordinal == 27)); then
                    state=escape
                elif ((ordinal == 9)); then
                    output+='    '
                elif ((ordinal == 0x200D || (ordinal >= 0xFE00 && ordinal <= 0xFE0F) || (ordinal >= 0x1F3FB && ordinal <= 0x1F3FF))); then
                    :
                elif ((ordinal >= 0x1F000 && ordinal <= 0x1FAFF)); then
                    output+='?'
                elif ((ordinal >= 32 && ordinal != 127 && (ordinal < 128 || ordinal >= 160))); then
                    output+=$char
                fi
                ;;
            escape)
                case "$char" in
                    '[') state=csi ;;
                    ']') state=osc ;;
                    *) state=plain ;;
                esac
                ;;
            csi)
                if ((ordinal >= 64 && ordinal <= 126)); then
                    state=plain
                fi
                ;;
            osc)
                if ((ordinal == 7)); then
                    state=plain
                elif ((ordinal == 27)); then
                    state=osc_escape
                fi
                ;;
            osc_escape)
                if [[ "$char" == '\\' ]]; then
                    state=plain
                elif ((ordinal != 27)); then
                    state=osc
                fi
                ;;
        esac
    done
    tui_v2_clean_result=$output
}

tui_v2_clean_text() {
    tui_v2_sanitize_text "${1:-}"
    printf '%s' "$tui_v2_clean_result"
}

tui_v2_fit_text() {
    local value=''
    local width=$2
    local total_width=0
    local target_width=0
    local used_width=0
    local char=''
    local index=0
    local suffix=''
    local padding=''
    local ascii_pattern='^[ -~]*$'

    tui_terminal_init_text_locale
    local LC_ALL=$tui_terminal_text_locale
    [[ "$width" =~ ^[0-9]+$ ]] || width=1
    ((width >= 0)) || width=0
    tui_v2_sanitize_text "${1:-}"
    value=$tui_v2_clean_result
    tui_terminal_measure_text "$value"
    total_width=$tui_terminal_text_cells
    tui_v2_fit_result=''

    if ((total_width > width)); then
        target_width=$width
        if ((width >= 4)); then
            suffix='...'
            target_width=$((width - 3))
        fi
        if [[ "$value" =~ $ascii_pattern ]]; then
            tui_v2_fit_result=${value:0:target_width}
            used_width=$target_width
        else
            for ((index = 0; index < ${#value}; index++)); do
                char=${value:index:1}
                tui_terminal_char_width "$char"
                if ((tui_terminal_char_cells == 0)); then
                    [[ -n "$tui_v2_fit_result" ]] && tui_v2_fit_result+=$char
                    continue
                fi
                ((used_width + tui_terminal_char_cells <= target_width)) || break
                tui_v2_fit_result+=$char
                used_width=$((used_width + tui_terminal_char_cells))
            done
        fi
        tui_v2_fit_result+=$suffix
        used_width=$((used_width + ${#suffix}))
    else
        tui_v2_fit_result=$value
        used_width=$total_width
    fi

    if ((used_width < width)); then
        printf -v padding '%*s' "$((width - used_width))" ''
        tui_v2_fit_result+=$padding
    fi
}

tui_v2_clip() {
    tui_v2_fit_text "${1:-}" "$2"
    printf '%s' "${tui_v2_fit_result%${tui_v2_fit_result##*[! ]}}"
}

tui_v2_field() {
    tui_v2_fit_text "${1:-}" "$2"
    printf '%s' "$tui_v2_fit_result"
}

tui_v2_make_field() {
    local value=${1:-}
    local width=$2
    local align=${3:-left}
    local text_width=0
    local padding=''

    tui_v2_fit_text "$value" "$width"
    tui_v2_field_result=$tui_v2_fit_result
    if [[ "$align" == right ]]; then
        tui_v2_field_result=${tui_v2_field_result%${tui_v2_field_result##*[! ]}}
        tui_terminal_measure_text "$tui_v2_field_result"
        text_width=$tui_terminal_text_cells
        printf -v padding '%*s' "$((width - text_width))" ''
        tui_v2_field_result="$padding$tui_v2_field_result"
    fi
}

tui_v2_repeat() {
    local count=$1
    local char=${2:-─}
    local output=''

    ((count > 0)) || return 0
    printf -v output '%*s' "$count" ''
    output=${output// /$char}
    printf '%s' "$output"
}

tui_v2_theme_init() {
    local mode=${NETUI_TUI_COLOR:-auto}

    tui_v2_color_enabled=0
    [[ -z "${NO_COLOR+x}" ]] || mode=never
    case "$mode" in
        always) tui_v2_color_enabled=1 ;;
        never) ;;
        auto)
            if [[ -t 1 && "${TERM:-dumb}" != dumb ]]; then
                tui_v2_color_enabled=1
            fi
            ;;
        *)
            if [[ -t 1 && "${TERM:-dumb}" != dumb ]]; then
                tui_v2_color_enabled=1
            fi
            ;;
    esac

    if ((tui_v2_color_enabled)); then
        tui_v2_theme_reset=$'\033[0m'
        tui_v2_theme_canvas=$'\033[38;5;252;48;5;234m'
        tui_v2_theme_border=$'\033[38;5;67;48;5;234m'
        tui_v2_theme_title=$'\033[1;38;5;231;48;5;24m'
        tui_v2_theme_toolbar=$'\033[38;5;153;48;5;236m'
        tui_v2_theme_section=$'\033[1;38;5;81;48;5;234m'
        tui_v2_theme_header=$'\033[1;38;5;110;48;5;237m'
        tui_v2_theme_row=$'\033[38;5;252;48;5;234m'
        tui_v2_theme_selected=$'\033[1;38;5;231;48;5;30m'
        tui_v2_theme_invalid=$'\033[38;5;210;48;5;234m'
        tui_v2_theme_footer=$'\033[38;5;250;48;5;235m'
        tui_v2_theme_info=$'\033[1;38;5;121;48;5;235m'
        tui_v2_theme_error=$'\033[1;38;5;210;48;5;235m'
        tui_v2_theme_modal=$'\033[1;38;5;229;48;5;58m'
    else
        tui_v2_theme_reset=''
        tui_v2_theme_canvas=''
        tui_v2_theme_border=''
        tui_v2_theme_title=''
        tui_v2_theme_toolbar=''
        tui_v2_theme_section=''
        tui_v2_theme_header=''
        tui_v2_theme_row=''
        tui_v2_theme_selected=''
        tui_v2_theme_invalid=''
        tui_v2_theme_footer=''
        tui_v2_theme_info=''
        tui_v2_theme_error=''
        tui_v2_theme_modal=''
    fi
}

tui_v2_frame_append() {
    if [[ -n "$tui_v2_frame" ]]; then
        tui_v2_frame+=$'\n'
    fi
    tui_v2_frame+=$1
}

tui_v2_box_rule() {
    local left=$1
    local middle=${2:-─}
    local right=$3
    local rule=''

    printf -v rule '%*s' "$tui_v2_inner_width" ''
    rule=${rule// /$middle}
    tui_v2_frame_append "${tui_v2_theme_canvas}${tui_v2_theme_border}${left}${rule}${right}${tui_v2_theme_reset}"
}

tui_v2_line() {
    local text=${1:-}
    local style=${2:-$tui_v2_theme_row}

    tui_v2_fit_text "$text" "$tui_v2_inner_width"
    tui_v2_frame_append "${tui_v2_theme_canvas}${tui_v2_theme_border}│${style}${tui_v2_fit_result}${tui_v2_theme_border}│${tui_v2_theme_reset}"
}

tui_v2_set_status() {
    tui_v2_status_level=${1:-info}
    tui_v2_status_message=$(tui_v2_clean_text "${2:-}")
    tui_v2_modal_message=''
}

tui_v2_collect_logs() {
    local line=''

    tui_v2_logs=()
    if [[ -f "$NETUI_LOG_FILE" && ! -L "$NETUI_LOG_FILE" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            tui_v2_logs+=("$(tui_v2_clean_text "$line")")
        done < <(tail -n 8 -- "$NETUI_LOG_FILE")
    fi
    if ((${#tui_v2_logs[@]} == 0)); then
        tui_v2_logs=('No recent NetUI log entries.')
    fi
}

tui_v2_refresh_status() {
    tui_running_state
    tui_v2_default_basename=$(tui_default_basename)
    tui_v2_environment=$(tui_environment_summary)
    if [[ -f "${NETUI_PACKAGE_ROOT:-.}/VERSION" ]]; then
        IFS= read -r tui_v2_version < "${NETUI_PACKAGE_ROOT:-.}/VERSION" || tui_v2_version='?'
    fi
    tui_v2_collect_logs
}

tui_v2_model_refresh() {
    local previous_basename=${tui_v2_selected_basename:-}
    local path=''
    local basename=''
    local metadata=''
    local fields=''
    local name=''
    local protocol=''
    local server=''
    local port=''
    local transport=''
    local security=''
    local local_endpoint=''
    local metadata_status=''
    local index=0

    tui_refresh_configs
    tui_v2_paths=()
    tui_v2_names=()
    tui_v2_protocols=()
    tui_v2_servers=()
    tui_v2_ports=()
    tui_v2_transports=()
    tui_v2_security=()
    tui_v2_locals=()
    tui_v2_checks=()
    tui_v2_latencies=()
    tui_v2_speeds=()

    for path in "${tui_config_paths[@]}"; do
        basename=${path##*/}
        metadata=$(config_meta_extract "$path" 2>/dev/null || printf '{}')
        fields=$(jq -r '[
            (.name // ""),
            (.display_protocol // "unknown"),
            (.server // "—"),
            ((.server_port // "") | tostring),
            (.transport // "—"),
            (.security // "—"),
            (if .local_type == null then "—" else "\(.local_type) \(.local_listen):\(.local_port)" end),
            (.metadata_status // "unknown")
        ] | map(tostring) | join("\u001f")' <<< "$metadata" 2>/dev/null || printf '%s\037%s\037%s\037\037%s\037%s\037%s\037%s\n' "$basename" unknown '—' '—' '—' '—' invalid)
        IFS=$'\x1f' read -r name protocol server port transport security local_endpoint metadata_status <<< "$fields"
        tui_v2_paths[$index]=$path
        tui_v2_names+=("$basename")
        tui_v2_protocols+=("${protocol:-unknown}")
        tui_v2_servers+=("${server:-—}")
        tui_v2_ports+=("${port:-—}")
        tui_v2_transports+=("${transport:-—}")
        tui_v2_security+=("${security:-—}")
        tui_v2_locals+=("${local_endpoint:-—}")
        tui_v2_checks+=("$(tui_check_for_config "$path")")
        tui_v2_latencies+=('—')
        tui_v2_speeds+=('—')
        index=$((index + 1))
    done

    if ((${#tui_v2_paths[@]} == 0)); then
        tui_v2_selected_index=0
        tui_v2_selected_basename=''
    else
        if [[ -n "$previous_basename" ]]; then
            for index in "${!tui_v2_paths[@]}"; do
                if [[ "${tui_v2_names[$index]}" == "$previous_basename" || "${tui_v2_paths[$index]##*/}" == "$previous_basename" ]]; then
                    tui_v2_selected_index=$index
                    break
                fi
            done
        fi
        ((tui_v2_selected_index < ${#tui_v2_paths[@]})) || tui_v2_selected_index=$((${#tui_v2_paths[@]} - 1))
        ((tui_v2_selected_index >= 0)) || tui_v2_selected_index=0
        tui_v2_selected_basename=${tui_v2_paths[$tui_v2_selected_index]##*/}
        tui_selected_path=${tui_v2_paths[$tui_v2_selected_index]}
    fi
    tui_v2_refresh_status
    tui_v2_model_ready=1
}

tui_v2_sync_selection() {
    local count=${#tui_v2_paths[@]}

    if ((count == 0)); then
        tui_v2_selected_index=0
        tui_v2_selected_basename=''
        tui_selected_path=''
        return 0
    fi
    ((tui_v2_selected_index >= 0)) || tui_v2_selected_index=0
    ((tui_v2_selected_index < count)) || tui_v2_selected_index=$((count - 1))
    tui_v2_selected_basename=${tui_v2_paths[$tui_v2_selected_index]##*/}
    tui_selected_path=${tui_v2_paths[$tui_v2_selected_index]}
}

tui_v2_adjust_scroll() {
    local visible_rows=$1
    local count=${#tui_v2_paths[@]}
    local max_offset=0

    ((visible_rows >= 1)) || visible_rows=1
    if ((count <= visible_rows)); then
        tui_v2_scroll_offset=0
        return 0
    fi
    if ((tui_v2_selected_index < tui_v2_scroll_offset)); then
        tui_v2_scroll_offset=$tui_v2_selected_index
    elif ((tui_v2_selected_index >= tui_v2_scroll_offset + visible_rows)); then
        tui_v2_scroll_offset=$((tui_v2_selected_index - visible_rows + 1))
    fi
    max_offset=$((count - visible_rows))
    ((tui_v2_scroll_offset <= max_offset)) || tui_v2_scroll_offset=$max_offset
    ((tui_v2_scroll_offset >= 0)) || tui_v2_scroll_offset=0
}

tui_v2_build_table_line() {
    local kind=$1
    local index=${2:-0}
    local marker=''
    local name=''
    local server=''
    local port=''
    local protocol=''
    local transport=''
    local security=''
    local local_endpoint=''
    local check_status=''
    local dynamic_width=0
    local field=''

    tui_v2_table_line=''
    tui_v2_table_style=$tui_v2_theme_row
    if [[ "$kind" == header ]]; then
        marker='S'
        name='NAME'
        server='ADDRESS'
        port='PORT'
        protocol='PROTOCOL'
        transport='XPORT'
        security='SECURITY'
        local_endpoint='LOCAL'
        check_status='CHECK'
        tui_v2_table_style=$tui_v2_theme_header
    else
        ((index == tui_v2_selected_index)) && marker+='>' || marker+=' '
        [[ "${tui_v2_paths[$index]##*/}" == "${tui_v2_default_basename:-}" ]] && marker+='*' || marker+=' '
        [[ "${tui_v2_paths[$index]##*/}" == "${tui_running_basename:-}" ]] && marker+='+' || marker+=' '
        [[ "${tui_v2_checks[$index]}" == bad ]] && marker+='!' || marker+=' '
        name=${tui_v2_names[$index]%.json}
        server=${tui_v2_servers[$index]}
        port=${tui_v2_ports[$index]}
        protocol=${tui_v2_protocols[$index]}
        transport=${tui_v2_transports[$index]}
        security=${tui_v2_security[$index]}
        local_endpoint=${tui_v2_locals[$index]}
        check_status=${tui_v2_checks[$index]}
        if ((index == tui_v2_selected_index)); then
            tui_v2_table_style=$tui_v2_theme_selected
        elif [[ "$check_status" == bad ]]; then
            tui_v2_table_style=$tui_v2_theme_invalid
        fi
    fi

    if ((tui_v2_inner_width >= 108)); then
        dynamic_width=$((tui_v2_inner_width - 96))
        tui_v2_make_field "$marker" 4; field=$tui_v2_field_result; tui_v2_table_line+=$field
        tui_v2_make_field "$name" 20; field=$tui_v2_field_result; tui_v2_table_line+=" $field"
        tui_v2_make_field "$server" 22; field=$tui_v2_field_result; tui_v2_table_line+=" $field"
        tui_v2_make_field "$port" 5 right; field=$tui_v2_field_result; tui_v2_table_line+=" $field"
        tui_v2_make_field "$protocol" 13; field=$tui_v2_field_result; tui_v2_table_line+=" $field"
        tui_v2_make_field "$transport" 9; field=$tui_v2_field_result; tui_v2_table_line+=" $field"
        tui_v2_make_field "$security" 10; field=$tui_v2_field_result; tui_v2_table_line+=" $field"
        tui_v2_make_field "$local_endpoint" "$dynamic_width"; field=$tui_v2_field_result; tui_v2_table_line+=" $field"
        tui_v2_make_field "$check_status" 5; field=$tui_v2_field_result; tui_v2_table_line+=" $field"
    elif ((tui_v2_inner_width >= 88)); then
        dynamic_width=$((tui_v2_inner_width - 66))
        tui_v2_make_field "$marker" 4; field=$tui_v2_field_result; tui_v2_table_line+=$field
        tui_v2_make_field "$name" 22; field=$tui_v2_field_result; tui_v2_table_line+=" $field"
        tui_v2_make_field "$server" "$dynamic_width"; field=$tui_v2_field_result; tui_v2_table_line+=" $field"
        tui_v2_make_field "$port" 5 right; field=$tui_v2_field_result; tui_v2_table_line+=" $field"
        tui_v2_make_field "$protocol" 14; field=$tui_v2_field_result; tui_v2_table_line+=" $field"
        tui_v2_make_field "$security" 10; field=$tui_v2_field_result; tui_v2_table_line+=" $field"
        tui_v2_make_field "$check_status" 5; field=$tui_v2_field_result; tui_v2_table_line+=" $field"
    elif ((tui_v2_inner_width >= 68)); then
        dynamic_width=$((tui_v2_inner_width - 55))
        tui_v2_make_field "$marker" 4; field=$tui_v2_field_result; tui_v2_table_line+=$field
        tui_v2_make_field "$name" 22; field=$tui_v2_field_result; tui_v2_table_line+=" $field"
        tui_v2_make_field "$protocol" 14; field=$tui_v2_field_result; tui_v2_table_line+=" $field"
        tui_v2_make_field "$port" 5 right; field=$tui_v2_field_result; tui_v2_table_line+=" $field"
        tui_v2_make_field "$security" "$dynamic_width"; field=$tui_v2_field_result; tui_v2_table_line+=" $field"
        tui_v2_make_field "$check_status" 5; field=$tui_v2_field_result; tui_v2_table_line+=" $field"
    else
        dynamic_width=$((tui_v2_inner_width - 28))
        ((dynamic_width >= 4)) || dynamic_width=4
        tui_v2_make_field "$marker" 3; field=$tui_v2_field_result; tui_v2_table_line+=$field
        tui_v2_make_field "$name" "$dynamic_width"; field=$tui_v2_field_result; tui_v2_table_line+=" $field"
        tui_v2_make_field "$protocol" 12; field=$tui_v2_field_result; tui_v2_table_line+=" $field"
        tui_v2_make_field "$port" 5 right; field=$tui_v2_field_result; tui_v2_table_line+=" $field"
        tui_v2_make_field "$check_status" 4; field=$tui_v2_field_result; tui_v2_table_line+=" $field"
    fi
}

tui_v2_emit_frame() {
    local line=''
    local row=0
    local update=''
    local output=''
    local size="$tui_v2_rows|$tui_v2_cols"
    local -a lines=()

    if ((tui_terminal_active)); then
        while IFS= read -r line; do
            lines+=("$line")
        done <<< "$tui_v2_frame"
        if [[ "$size" != "$tui_v2_previous_size" || "$tui_terminal_screen_generation" != "$tui_v2_previous_screen" ]]; then
            printf '\033[H%s%s\033[J' "$tui_v2_frame" "$tui_v2_theme_reset"
        else
            for row in "${!lines[@]}"; do
                if [[ "${lines[$row]}" != "${tui_v2_previous_lines[$row]-}" ]]; then
                    printf -v update '\033[%d;1H%s\033[K' "$((row + 1))" "${lines[$row]}"
                    output+=$update
                fi
            done
            [[ -z "$output" ]] || printf '%s%s' "$output" "$tui_v2_theme_reset"
        fi
        tui_v2_previous_lines=("${lines[@]}")
        tui_v2_previous_size=$size
        tui_v2_previous_screen=$tui_terminal_screen_generation
    else
        printf '%s\n' "$tui_v2_frame"
    fi
}

tui_v2_render_small_frame() {
    local current_size="${tui_v2_cols}x${tui_v2_rows}"

    tui_v2_frame=''
    tui_v2_fit_text 'NetUI - terminal is too small' "$tui_v2_frame_width"
    tui_v2_frame_append "${tui_v2_theme_title}${tui_v2_fit_result}${tui_v2_theme_reset}"
    if ((tui_v2_rows >= 2)); then
        tui_v2_fit_text "Current: $current_size  Need at least: 40x12" "$tui_v2_frame_width"
        tui_v2_frame_append "${tui_v2_theme_canvas}${tui_v2_fit_result}${tui_v2_theme_reset}"
    fi
    if ((tui_v2_rows >= 3)); then
        tui_v2_fit_text 'Resize the terminal, or press q to quit.' "$tui_v2_frame_width"
        tui_v2_frame_append "${tui_v2_theme_toolbar}${tui_v2_fit_result}${tui_v2_theme_reset}"
    fi
    tui_v2_emit_frame
}

tui_v2_render_frame() {
    local size=''
    local version=$tui_v2_version
    local selected_name='-'
    local selected_endpoint='-'
    local environment=''
    local env_mode='off'
    local env_effective='off'
    local env_bytes='0'
    local content_rows=0
    local config_rows=0
    local log_rows=0
    local slot=0
    local index=0
    local log_index=0
    local log_start=0
    local count=${#tui_v2_paths[@]}
    local section_title=''
    local status_text='Ready. Press ? for help.'
    local status_style=''

    size=$(tui_terminal_get_size 2>/dev/null || printf '24|80')
    IFS='|' read -r tui_v2_rows tui_v2_cols <<< "$size"
    [[ "$tui_v2_rows" =~ ^[0-9]+$ ]] || tui_v2_rows=24
    [[ "$tui_v2_cols" =~ ^[0-9]+$ ]] || tui_v2_cols=80
    ((tui_v2_rows >= 1)) || tui_v2_rows=1
    ((tui_v2_cols >= 2)) || tui_v2_cols=2
    tui_v2_frame_width=$((tui_v2_cols - 1))
    ((tui_v2_frame_width >= 1)) || tui_v2_frame_width=1
    tui_v2_inner_width=$((tui_v2_frame_width - 2))
    tui_v2_last_size="$tui_v2_rows|$tui_v2_cols"
    tui_v2_theme_init

    if ((tui_v2_cols < 40 || tui_v2_rows < 12 || tui_v2_frame_width < 3)); then
        tui_v2_render_small_frame
        return 0
    fi

    environment=$tui_v2_environment
    IFS='|' read -r env_mode env_effective env_bytes <<< "$environment"
    tui_v2_sync_selection
    if ((count > 0)); then
        selected_name=${tui_v2_names[$tui_v2_selected_index]%.json}
        selected_endpoint=${tui_v2_locals[$tui_v2_selected_index]}
    fi

    tui_v2_frame=''
    status_style=$tui_v2_theme_footer
    if [[ -n "$tui_v2_modal_message" ]]; then
        status_text="NOTICE: $tui_v2_modal_message"
        status_style=$tui_v2_theme_modal
    elif [[ -n "$tui_v2_status_message" ]]; then
        status_text="STATUS: $tui_v2_status_message"
        if [[ "$tui_v2_status_level" == error ]]; then
            status_style=$tui_v2_theme_error
        else
            status_style=$tui_v2_theme_info
        fi
    fi

    if ((tui_v2_rows >= 20)); then
        content_rows=$((tui_v2_rows - 14))
        log_rows=$((content_rows / 3))
        ((log_rows >= 2)) || log_rows=2
        ((log_rows <= 6)) || log_rows=6
        config_rows=$((content_rows - log_rows))
        ((config_rows >= 1)) || config_rows=1
        tui_v2_adjust_scroll "$config_rows"

        tui_v2_box_rule '╭' '─' '╮'
        tui_v2_line " NetUI v$version  |  Runtime: ${tui_running_status:-stopped} ${tui_running_basename:--}  |  Default: ${tui_v2_default_basename:--}  |  Mode: $env_mode" "$tui_v2_theme_title"
        if ((tui_v2_inner_width >= 96)); then
            tui_v2_line ' [Up/Down] Select   [Enter] Default   [Ctrl+Up/Down] Cycle mode   [Ctrl+R] Restart' "$tui_v2_theme_toolbar"
        else
            tui_v2_line ' [Up/Down] Select   [Enter] Default   [Ctrl+Up/Down] Mode   [Ctrl+R] Restart' "$tui_v2_theme_toolbar"
        fi
        tui_v2_line ' [i] Import   [r] Refresh   [l] Logs   [u/x] Start/Stop   [?] Help   [q] Quit' "$tui_v2_theme_toolbar"
        tui_v2_box_rule '├' '─' '┤'
        if ((count > config_rows)); then
            section_title=" CONFIGURATIONS  $((tui_v2_scroll_offset + 1))-$((tui_v2_scroll_offset + config_rows))/$count  [> selected  * default  + running  ! invalid]"
        else
            section_title=' CONFIGURATIONS  [> selected  * default  + running  ! invalid]'
        fi
        tui_v2_line "$section_title" "$tui_v2_theme_section"
        tui_v2_build_table_line header
        tui_v2_line "$tui_v2_table_line" "$tui_v2_table_style"
        for ((slot = 0; slot < config_rows; slot++)); do
            index=$((tui_v2_scroll_offset + slot))
            if ((index < count)); then
                tui_v2_build_table_line row "$index"
                tui_v2_line "$tui_v2_table_line" "$tui_v2_table_style"
            elif ((count == 0 && slot == 0)); then
                tui_v2_line ' No JSON configurations found. Press i to import a share URI.' "$tui_v2_theme_row"
            else
                tui_v2_line '' "$tui_v2_theme_row"
            fi
        done
        tui_v2_box_rule '├' '─' '┤'
        tui_v2_line ' LOGS  runtime tail' "$tui_v2_theme_section"
        log_start=$((${#tui_v2_logs[@]} - log_rows))
        ((log_start >= 0)) || log_start=0
        for ((slot = 0; slot < log_rows; slot++)); do
            log_index=$((log_start + slot))
            if ((log_index < ${#tui_v2_logs[@]})); then
                tui_v2_line "  ${tui_v2_logs[$log_index]}" "$tui_v2_theme_row"
            else
                tui_v2_line '' "$tui_v2_theme_row"
            fi
        done
        tui_v2_box_rule '├' '─' '┤'
        tui_v2_line " Default: ${tui_v2_default_basename:--}   Running: ${tui_running_basename:--}   Selected: $selected_name" "$tui_v2_theme_footer"
        tui_v2_line " Env: $env_mode (effective $env_effective)   no_proxy: ${env_bytes}B   Local: $selected_endpoint" "$tui_v2_theme_footer"
        tui_v2_line " $status_text" "$status_style"
        tui_v2_box_rule '╰' '─' '╯'
    else
        config_rows=$((tui_v2_rows - 10))
        ((config_rows >= 1)) || config_rows=1
        tui_v2_adjust_scroll "$config_rows"

        tui_v2_box_rule '╭' '─' '╮'
        tui_v2_line " NetUI v$version | ${tui_running_status:-stopped} | mode:$env_mode | default:${tui_v2_default_basename:--}" "$tui_v2_theme_title"
        tui_v2_line ' [Up/Down] Select  [Enter] Default  [Ctrl+Up/Down] Mode  [i] Import  [q] Quit' "$tui_v2_theme_toolbar"
        tui_v2_box_rule '├' '─' '┤'
        tui_v2_line ' CONFIGURATIONS  [> selected  * default  + running  ! invalid]' "$tui_v2_theme_section"
        tui_v2_build_table_line header
        tui_v2_line "$tui_v2_table_line" "$tui_v2_table_style"
        for ((slot = 0; slot < config_rows; slot++)); do
            index=$((tui_v2_scroll_offset + slot))
            if ((index < count)); then
                tui_v2_build_table_line row "$index"
                tui_v2_line "$tui_v2_table_line" "$tui_v2_table_style"
            elif ((count == 0 && slot == 0)); then
                tui_v2_line ' No configurations. Press i to import.' "$tui_v2_theme_row"
            else
                tui_v2_line '' "$tui_v2_theme_row"
            fi
        done
        tui_v2_box_rule '├' '─' '┤'
        tui_v2_line " Selected: $selected_name   Local: $selected_endpoint   Env: $env_mode/$env_effective" "$tui_v2_theme_footer"
        tui_v2_line " $status_text" "$status_style"
        tui_v2_box_rule '╰' '─' '╯'
    fi

    tui_v2_emit_frame
}

tui_v2_run_business() {
    local label=$1
    shift
    local output_file=''
    local output=''
    local status=0

    output_file=$(mktemp "${TMPDIR:-/tmp}/netui-tui-action.XXXXXX") || {
        tui_v2_set_status error "$label failed: temporary file unavailable"
        return 1
    }
    "$@" >"$output_file" 2>&1 || status=$?
    output=$(tail -n 1 -- "$output_file" 2>/dev/null || true)
    rm -f -- "$output_file"
    if ((status == 0)); then
        tui_v2_set_status info "${label}: ${output:-ok}"
    else
        tui_v2_set_status error "${label} failed (exit $status)"
    fi
    case "${1:-}" in
        env_profiles_set_mode|tui_action_start|tui_action_stop|tui_action_restart)
            tui_v2_refresh_status
            ;;
        *) tui_v2_model_refresh ;;
    esac
    return "$status"
}

tui_v2_modal_help() {
    tui_v2_modal_message='↑↓ move | Enter default | Ctrl↑/↓ cycle cn-direct/global | CtrlR restart | i import | u/x start/stop | q quit'
    tui_v2_render_frame
    tui_terminal_read_key 30 || true
    tui_v2_modal_message=''
}

tui_v2_modal_import() {
    local uri=''
    local preview=''
    local fields=''
    local protocol=''
    local server=''
    local port=''
    local warning=''
    local status=0

    tui_v2_set_status info 'Paste one share URI; input is hidden. Press Enter to parse or Esc to cancel.'
    tui_v2_render_frame
    tui_terminal_read_hidden_line 16384 || {
        tui_v2_set_status info 'Import cancelled'
        return 0
    }
    uri=$tui_terminal_hidden_value
    [[ -n "$uri" ]] || {
        tui_v2_set_status error 'Import failed: empty URI'
        return 1
    }
    if ! share_uri_parse "$uri" >/dev/null 2>&1; then
        tui_v2_set_status error "Import failed: $(share_uri_last_error_code)"
        return 1
    fi
    preview=$(share_uri_preview_json 2>/dev/null) || {
        tui_v2_set_status error 'Import failed: preview unavailable'
        return 1
    }
    fields=$(jq -r '[.protocol, (.server // "—"), ((.port // "") | tostring), (.warning // "")] | @tsv' <<< "$preview")
    IFS=$'\t' read -r protocol server port warning <<< "$fields"
    tui_v2_modal_message="Preview $protocol $server:$port${warning:+ [$warning]} | Enter import, Esc cancel"
    tui_v2_render_frame
    tui_terminal_read_key 30 || status=1
    if [[ "$tui_terminal_key" != ENTER ]]; then
        tui_v2_modal_message=''
        tui_v2_set_status info 'Import cancelled'
        return 0
    fi
    if ! share_uri_import "$uri" >/dev/null 2>&1; then
        tui_v2_set_status error "Import failed: $(share_uri_last_error_code)"
        return 1
    fi
    tui_v2_set_status info "Imported ${share_uri_last_path##*/}"
    tui_v2_model_refresh
}

tui_v2_modal_rename() {
    local new_basename=''

    tui_v2_set_status info 'Type a new *.json basename; input is hidden. Press Enter to commit or Esc to cancel.'
    tui_v2_render_frame
    tui_terminal_read_hidden_line 255 || {
        tui_v2_set_status info 'Rename cancelled'
        return 0
    }
    new_basename=$tui_terminal_hidden_value
    [[ -n "$new_basename" ]] || return 1
    if config_store_rename "${tui_v2_paths[$tui_v2_selected_index]}" "$new_basename" >/dev/null 2>&1; then
        tui_v2_set_status info "Renamed to $new_basename"
        tui_v2_model_refresh
    else
        tui_v2_set_status error 'Rename failed'
        return 1
    fi
}

tui_v2_modal_detail() {
    local index=$tui_v2_selected_index

    tui_v2_modal_message="${tui_v2_names[$index]} | ${tui_v2_protocols[$index]} | ${tui_v2_servers[$index]}:${tui_v2_ports[$index]} | credentials hidden | press any key"
    tui_v2_render_frame
    tui_terminal_read_key 30 || true
    tui_v2_modal_message=''
}

tui_v2_restore_for_shell_hook() {
    local status=0

    tui_terminal_restore
    shell_integration_install || status=$?
    tui_terminal_enter || return 1
    if ((status == 0)); then
        tui_v2_set_status info 'Shell hook installed'
    else
        tui_v2_set_status error 'Shell hook installation failed'
    fi
    return "$status"
}

tui_v2_dispatch_key() {
    local key=$1
    local count=${#tui_v2_paths[@]}
    local status=0
    local mode=''

    case "$key" in
        UP)
            ((count > 0)) && ((tui_v2_selected_index > 0)) && tui_v2_selected_index=$((tui_v2_selected_index - 1))
            ;;
        DOWN)
            ((count > 0)) && ((tui_v2_selected_index < count - 1)) && tui_v2_selected_index=$((tui_v2_selected_index + 1))
            ;;
        ENTER)
            ((count > 0)) || return 0
            tui_selected_path=${tui_v2_paths[$tui_v2_selected_index]}
            tui_v2_run_business 'set default' config_store_set_default "$tui_selected_path" || status=$?
            ;;
        CTRL_UP|CTRL_DOWN)
            mode=$(env_profiles_get_mode) || return 1
            [[ "$mode" == global ]] && mode=cn-direct || mode=global
            tui_v2_run_business "$mode mode" env_profiles_set_mode "$mode" || status=$?
            ;;
        MODE_GLOBAL)
            tui_v2_run_business 'global mode' env_profiles_set_mode global || status=$?
            ;;
        MODE_WHITELIST)
            tui_v2_run_business 'cn-direct mode' env_profiles_set_mode cn-direct || status=$?
            ;;
        CTRL_R)
            if tui_terminal_confirm; then
                tui_v2_run_business 'restart' tui_action_restart || status=$?
            else
                tui_v2_set_status info 'Restart cancelled'
            fi
            ;;
        CTRL_T)
            tui_v2_set_status info 'Speed probe is not enabled in this build'
            ;;
        IMPORT)
            tui_v2_modal_import || status=$?
            ;;
        LOG_SOURCE)
            tui_v2_set_status info 'Showing the latest NetUI log entries'
            tui_v2_collect_logs
            ;;
        REFRESH)
            tui_v2_set_status info 'Configuration list refreshed'
            tui_v2_model_refresh
            ;;
        HELP)
            tui_v2_modal_help
            ;;
        TEXT:v|TEXT:V)
            ((count > 0)) || return 0
            tui_selected_path=${tui_v2_paths[$tui_v2_selected_index]}
            tui_v2_run_business 'validate' tui_action_validate || status=$?
            ;;
        TEXT:u|TEXT:U)
            tui_v2_run_business 'start' tui_action_start || status=$?
            ;;
        TEXT:x|TEXT:X)
            if tui_terminal_confirm; then
                tui_v2_run_business 'stop' tui_action_stop || status=$?
            else
                tui_v2_set_status info 'Stop cancelled'
            fi
            ;;
        TEXT:n|TEXT:N)
            ((count > 0)) && tui_v2_modal_rename || status=$?
            ;;
        TEXT:a|TEXT:A)
            if ((count > 0)) && tui_terminal_confirm; then
                tui_v2_run_business 'archive' config_store_archive "${tui_v2_paths[$tui_v2_selected_index]}" || status=$?
                tui_v2_model_refresh
            else
                tui_v2_set_status info 'Archive cancelled'
            fi
            ;;
        TEXT:e|TEXT:E)
            ((count > 0)) && tui_v2_modal_detail
            ;;
        TEXT:h|TEXT:H)
            tui_v2_restore_for_shell_hook || status=$?
            ;;
        QUIT)
            tui_v2_running=0
            ;;
    esac
    tui_v2_sync_selection
    return "$status"
}

tui_v2_run() {
    local key=''
    local status=0
    local size=''
    local saved_traps=''

    saved_traps=$(trap -p INT TERM HUP WINCH)
    tui_v2_model_refresh
    tui_v2_running=1
    tui_v2_needs_redraw=1
    tui_v2_resize_pending=0
    tui_v2_last_size=''
    trap 'tui_v2_resize_pending=1' WINCH
    trap 'tui_terminal_restore; exit 130' INT TERM HUP
    if ! tui_terminal_enter; then
        trap - INT TERM HUP WINCH
        [[ -n "$saved_traps" ]] && eval "$saved_traps"
        return 1
    fi
    while ((tui_v2_running)); do
        if ((tui_v2_resize_pending)); then
            size=$(tui_terminal_get_size 2>/dev/null || printf '24|80')
            [[ "$size" == "$tui_v2_last_size" ]] || tui_v2_needs_redraw=1
            tui_v2_resize_pending=0
        fi
        if ((tui_v2_needs_redraw)); then
            tui_v2_render_frame
            tui_v2_needs_redraw=0
        fi
        if ! tui_terminal_read_key 0.25; then
            continue
        fi
        key=$tui_terminal_key
        tui_v2_dispatch_key "$key" || status=$?
        tui_v2_needs_redraw=1
        if ((status != 0)); then
            tui_v2_set_status error "Action failed (exit $status)"
            status=0
        fi
    done
    tui_terminal_restore
    trap - INT TERM HUP WINCH
    [[ -n "$saved_traps" ]] && eval "$saved_traps"
    return 0
}

tui_v2_render_dashboard() {
    tui_v2_model_refresh
    tui_v2_render_frame
}
