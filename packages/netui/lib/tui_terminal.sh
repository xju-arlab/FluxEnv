#!/bin/bash

# Terminal lifecycle and bounded key decoding for the fullscreen NetUI UI.

tui_terminal_active=0
tui_terminal_saved_stty=''
tui_terminal_alt_screen=0
tui_terminal_key=''
tui_terminal_hidden_value=''
tui_terminal_char_cells=0
tui_terminal_text_locale=''
tui_terminal_text_cells=0
tui_terminal_screen_generation=0

tui_terminal_init_text_locale() {
    [[ -n "$tui_terminal_text_locale" ]] && return 0
    if [[ "$(LC_ALL=C.UTF-8 locale charmap 2>/dev/null)" == UTF-8 ]]; then
        tui_terminal_text_locale=C.UTF-8
    else
        tui_terminal_text_locale=${LC_ALL:-${LC_CTYPE:-${LANG:-C}}}
    fi
}

tui_terminal_char_width() {
    local char=${1:-}
    local code=0

    tui_terminal_init_text_locale
    local LC_ALL=$tui_terminal_text_locale
    tui_terminal_char_cells=0
    [[ -n "$char" ]] || return 0
    printf -v code '%d' "'$char" 2>/dev/null || {
        tui_terminal_char_cells=1
        return 0
    }

    if ((
        code == 0 || code < 32 || (code >= 127 && code < 160) ||
        (code >= 0x200B && code <= 0x200F) ||
        (code >= 0x202A && code <= 0x202E) ||
        (code >= 0x2060 && code <= 0x206F) ||
        code == 0xFEFF
    )); then
        tui_terminal_char_cells=0
    elif ((
        (code >= 0x0300 && code <= 0x036F) ||
        (code >= 0x0483 && code <= 0x0489) ||
        (code >= 0x0591 && code <= 0x05BD) ||
        code == 0x05BF ||
        (code >= 0x05C1 && code <= 0x05C2) ||
        (code >= 0x05C4 && code <= 0x05C5) ||
        code == 0x05C7 ||
        (code >= 0x0610 && code <= 0x061A) ||
        (code >= 0x064B && code <= 0x065F) ||
        code == 0x0670 ||
        (code >= 0x06D6 && code <= 0x06ED) ||
        (code >= 0x0711 && code <= 0x0711) ||
        (code >= 0x0730 && code <= 0x074A) ||
        (code >= 0x07A6 && code <= 0x07B0) ||
        (code >= 0x07EB && code <= 0x07F3) ||
        (code >= 0x0816 && code <= 0x082D) ||
        (code >= 0x0859 && code <= 0x085B) ||
        (code >= 0x08D3 && code <= 0x0903) ||
        (code >= 0x093A && code <= 0x093C) ||
        (code >= 0x0941 && code <= 0x0948) ||
        code == 0x094D ||
        (code >= 0x0951 && code <= 0x0957) ||
        (code >= 0x0962 && code <= 0x0963) ||
        (code >= 0x1AB0 && code <= 0x1AFF) ||
        (code >= 0x1DC0 && code <= 0x1DFF) ||
        (code >= 0x20D0 && code <= 0x20FF) ||
        (code >= 0xFE00 && code <= 0xFE0F) ||
        (code >= 0xFE20 && code <= 0xFE2F) ||
        (code >= 0x1F3FB && code <= 0x1F3FF) ||
        (code >= 0xE0100 && code <= 0xE01EF)
    )); then
        tui_terminal_char_cells=0
    elif ((
        (code >= 0x1100 && code <= 0x115F) ||
        code == 0x2329 || code == 0x232A ||
        (code >= 0x2E80 && code <= 0x303E) ||
        (code >= 0x3040 && code <= 0xA4CF) ||
        (code >= 0xAC00 && code <= 0xD7A3) ||
        (code >= 0xF900 && code <= 0xFAFF) ||
        (code >= 0xFE10 && code <= 0xFE19) ||
        (code >= 0xFE30 && code <= 0xFE6F) ||
        (code >= 0xFF00 && code <= 0xFF60) ||
        (code >= 0xFFE0 && code <= 0xFFE6) ||
        (code >= 0x1F300 && code <= 0x1FAFF) ||
        (code >= 0x20000 && code <= 0x3FFFD)
    )); then
        tui_terminal_char_cells=2
    else
        tui_terminal_char_cells=1
    fi
}

tui_terminal_measure_text() {
    local value=${1:-}
    local char=''
    local index=0
    local width=0
    local ascii_pattern='^[ -~]*$'

    if [[ "$value" =~ $ascii_pattern ]]; then
        tui_terminal_text_cells=${#value}
        return 0
    fi

    tui_terminal_init_text_locale
    local LC_ALL=$tui_terminal_text_locale
    for ((index = 0; index < ${#value}; index++)); do
        char=${value:index:1}
        tui_terminal_char_width "$char"
        width=$((width + tui_terminal_char_cells))
    done
    tui_terminal_text_cells=$width
}

tui_terminal_cell_width() {
    tui_terminal_measure_text "${1:-}"
    printf '%s' "$tui_terminal_text_cells"
}

tui_terminal_get_size() {
    local rows=''
    local cols=''

    if [[ "${NETUI_TUI_FIXED_ROWS:-}" =~ ^[0-9]+$ && "${NETUI_TUI_FIXED_COLS:-}" =~ ^[0-9]+$ ]]; then
        printf '%s|%s' "$NETUI_TUI_FIXED_ROWS" "$NETUI_TUI_FIXED_COLS"
        return 0
    fi
    if read -r rows cols < <(stty size 2>/dev/null); then
        [[ "$rows" =~ ^[0-9]+$ && "$cols" =~ ^[0-9]+$ ]] || return 1
        printf '%s|%s' "$rows" "$cols"
        return 0
    fi
    rows=${LINES:-24}
    cols=${COLUMNS:-80}
    [[ "$rows" =~ ^[0-9]+$ && "$cols" =~ ^[0-9]+$ ]] || return 1
    printf '%s|%s' "$rows" "$cols"
}

tui_terminal_restore() {
    if ((tui_terminal_active)); then
        if ((tui_terminal_alt_screen)); then
            printf '\033[0m\033[?2004l\033[?25h\033[?1049l' >&1
        else
            printf '\033[0m\033[?2004l\033[?25h' >&1
        fi
        if [[ -n "$tui_terminal_saved_stty" ]]; then
            stty "$tui_terminal_saved_stty" 2>/dev/null || true
        fi
        tui_terminal_active=0
        tui_terminal_saved_stty=''
        tui_terminal_alt_screen=0
    fi
}

tui_terminal_enter() {
    [[ -t 0 && -t 1 ]] || return 1
    tui_terminal_saved_stty=$(stty -g 2>/dev/null) || return 1
    tui_terminal_active=1
    tui_terminal_screen_generation=$((tui_terminal_screen_generation + 1))
    stty -icanon -echo min 0 time 0 2>/dev/null || {
        tui_terminal_active=0
        tui_terminal_saved_stty=''
        return 1
    }
    if [[ "${NETUI_TUI_DISABLE_ALT_SCREEN:-0}" != 1 ]]; then
        printf '\033[?1049h\033[0m\033[2J\033[H\033[?25l\033[?2004h' >&1
        tui_terminal_alt_screen=1
    else
        printf '\033[0m\033[2J\033[H\033[?25l\033[?2004h' >&1
    fi
}

tui_terminal_read_key() {
    local timeout=${1:-0.2}
    local esc_timeout=${NETUI_TUI_ESC_TIMEOUT_MS:-50}
    local esc_seconds='0.050'
    local first=''
    local next=''
    local sequence=''
    local byte=''

    if [[ "$esc_timeout" =~ ^[0-9]{1,4}$ ]]; then
        esc_timeout=$((10#$esc_timeout))
        printf -v esc_seconds '%d.%03d' "$((esc_timeout / 1000))" "$((esc_timeout % 1000))"
    fi
    tui_terminal_key=''
    IFS= read -r -N 1 -t "$timeout" first || return 1
    case "$first" in
        $'\r'|$'\n') tui_terminal_key=ENTER ;;
        $'\x12') tui_terminal_key=CTRL_R ;;
        $'\x14') tui_terminal_key=CTRL_T ;;
        $'\x7f'|$'\b') tui_terminal_key=BACKSPACE ;;
        $'\x1b')
            if ! IFS= read -r -N 1 -t "$esc_seconds" next; then
                tui_terminal_key=ESC
            elif [[ "$next" == '[' || "$next" == 'O' ]]; then
                sequence=''
                if [[ "$next" == 'O' ]]; then
                    IFS= read -r -N 1 -t "$esc_seconds" byte || byte=''
                    case "$byte" in
                        A) tui_terminal_key=UP ;;
                        B) tui_terminal_key=DOWN ;;
                        *) tui_terminal_key=UNKNOWN ;;
                    esac
                else
                    while ((${#sequence} < 12)); do
                        IFS= read -r -N 1 -t "$esc_seconds" byte || {
                            tui_terminal_key=UNKNOWN
                            break
                        }
                        sequence+=$byte
                        if [[ "$byte" =~ [A-Za-z~] ]]; then
                            case "$sequence" in
                                A) tui_terminal_key=UP ;;
                                B) tui_terminal_key=DOWN ;;
                                '1;5A'|'5A') tui_terminal_key=CTRL_UP ;;
                                '1;5B'|'5B') tui_terminal_key=CTRL_DOWN ;;
                                '200~') tui_terminal_key=PASTE_START ;;
                                '201~') tui_terminal_key=PASTE_END ;;
                                *) tui_terminal_key=UNKNOWN ;;
                            esac
                            break
                        fi
                    done
                fi
            else
                tui_terminal_key=UNKNOWN
            fi
            ;;
        i|I) tui_terminal_key=IMPORT ;;
        l|L) tui_terminal_key=LOG_SOURCE ;;
        r|R) tui_terminal_key=REFRESH ;;
        g|G) tui_terminal_key=MODE_GLOBAL ;;
        w|W) tui_terminal_key=MODE_WHITELIST ;;
        q|Q) tui_terminal_key=QUIT ;;
        '?') tui_terminal_key=HELP ;;
        *)
            if [[ "$first" =~ [[:cntrl:]] ]]; then
                tui_terminal_key=UNKNOWN
            else
                tui_terminal_key="TEXT:$first"
            fi
            ;;
    esac
    [[ -n "$tui_terminal_key" ]] || tui_terminal_key=UNKNOWN
    return 0
}

tui_terminal_read_hidden_line() {
    local max_bytes=${1:-16384}
    local value=''
    local byte=''
    local next=''
    local sequence=''
    local paste_mode=0

    tui_terminal_hidden_value=''
    while :; do
        IFS= read -r -N 1 -t 0.25 byte || continue
        case "$byte" in
            $'\r'|$'\n')
                break
                ;;
            $'\x7f'|$'\b')
                value=${value%?}
                ;;
            $'\x1b')
                sequence=''
                if ! IFS= read -r -N 1 -t 0.05 next; then
                    tui_terminal_hidden_value=''
                    return 1
                fi
                if [[ "$next" == '[' ]]; then
                    while ((${#sequence} < 8)); do
                        IFS= read -r -N 1 -t 0.05 next || break
                        sequence+=$next
                        [[ "$next" =~ [A-Za-z~] ]] && break
                    done
                    case "$sequence" in
                        '200~') paste_mode=1 ;;
                        '201~') paste_mode=0 ;;
                    esac
                fi
                ;;
            *)
                if [[ ! "$byte" =~ [[:cntrl:]] ]]; then
                    value+=$byte
                    ((${#value} <= max_bytes)) || return 2
                elif ((paste_mode)); then
                    return 2
                fi
                ;;
        esac
    done
    tui_terminal_hidden_value=$value
}

tui_terminal_confirm() {
    local answer=''

    while :; do
        tui_terminal_read_key 30 || return 1
        answer=$tui_terminal_key
        case "$answer" in
            TEXT:y|TEXT:Y|ENTER) return 0 ;;
            TEXT:n|TEXT:N|ESC|QUIT) return 1 ;;
        esac
    done
}
