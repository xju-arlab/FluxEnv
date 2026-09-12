#!/bin/bash

share_uri_fail() {
    share_uri_error_code=${1:-invalid-uri}
    return 5
}

share_uri_reset() {
    share_uri_error_code=''
    share_uri_scheme=''
    share_uri_protocol=''
    share_uri_variant=''
    share_uri_server=''
    share_uri_server_port=''
    share_uri_uuid=''
    share_uri_password=''
    share_uri_encryption=''
    share_uri_flow=''
    share_uri_security=''
    share_uri_sni=''
    share_uri_fingerprint=''
    share_uri_public_key=''
    share_uri_short_id=''
    share_uri_transport_type=''
    share_uri_header_type=''
    share_uri_ws_host=''
    share_uri_ws_path=''
    share_uri_alpn=''
    share_uri_insecure=0
    share_uri_insecure_seen=0
    share_uri_obfs=''
    share_uri_obfs_password=''
    share_uri_obfs_password_seen=0
    share_uri_fragment=''
    share_uri_suggested_basename=''
    share_uri_warning_code=''
    share_uri_parse_succeeded=0
    share_uri_query_seen=''
    share_uri_seen_host=0
    share_uri_seen_path=0
    share_uri_seen_alpn=0
    share_uri_seen_flow=0
    share_uri_seen_security=0
    share_uri_seen_type=0
    share_uri_seen_header_type=0
    share_uri_seen_fp=0
    share_uri_seen_pbk=0
    share_uri_seen_sid=0
}

share_uri_last_error_code() {
    printf '%s\n' "${share_uri_error_code:-}"
}

share_uri_last_import_path() {
    printf '%s\n' "${share_uri_last_path:-}"
}

share_uri_percent_decode() {
    local input=${1:-}
    local output_var=${2:-}
    local decoded=''
    local byte=''
    local hex=''
    local character=''
    local index=0
    local input_length=0
    local LC_ALL=C

    share_uri_decode_error_code=''
    [[ "$output_var" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || {
        share_uri_decode_error_code=invalid-output-variable
        return 1
    }
    input_length=${#input}
    for ((index = 0; index < input_length; index++)); do
        character=${input:index:1}
        if [[ "$character" == '%' ]]; then
            ((index + 2 < input_length)) || {
                share_uri_decode_error_code=truncated-percent-escape
                return 1
            }
            hex=${input:index+1:2}
            [[ "$hex" =~ ^[0-9A-Fa-f]{2}$ ]] || {
                share_uri_decode_error_code=malformed-percent-encoding
                return 1
            }
            [[ "${hex,,}" != 00 ]] || {
                share_uri_decode_error_code=nul-byte
                return 1
            }
            printf -v byte '%b' "\\x$hex" || {
                share_uri_decode_error_code=malformed-percent-encoding
                return 1
            }
            [[ ! "$byte" =~ [[:cntrl:]] ]] || {
                share_uri_decode_error_code=control-character
                return 1
            }
            decoded+=$byte
            index=$((index + 2))
        else
            [[ ! "$character" =~ [[:cntrl:]] ]] || {
                share_uri_decode_error_code=control-character
                return 1
            }
            decoded+=$character
        fi
    done

    printf -v "$output_var" '%s' "$decoded"
}

share_uri_decode_or_fail() {
    local input=$1
    local output_var=$2

    share_uri_percent_decode "$input" "$output_var" || {
        share_uri_fail "${share_uri_decode_error_code:-malformed-percent-encoding}"
        return $?
    }
}

share_uri_validate_ipv6_side() {
    local side=$1
    local group=''
    local -a groups=()
    local LC_ALL=C

    [[ -n "$side" ]] || return 0
    [[ "$side" != :* && "$side" != *: ]] || return 1
    IFS=':' read -r -a groups <<< "$side"
    for group in "${groups[@]}"; do
        [[ "$group" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
    done
}

share_uri_validate_ipv6() {
    local value=$1
    local left=''
    local right=''
    local remainder=''
    local group_count=0
    local -a groups=()
    local LC_ALL=C

    [[ "$value" =~ ^[0-9A-Fa-f:]+$ && "$value" == *:* ]] || return 1
    if [[ "$value" == *::* ]]; then
        remainder=${value#*::}
        [[ "$remainder" != *::* ]] || return 1
        left=${value%%::*}
        right=$remainder
        share_uri_validate_ipv6_side "$left" || return 1
        share_uri_validate_ipv6_side "$right" || return 1
        if [[ -n "$left" ]]; then
            IFS=':' read -r -a groups <<< "$left"
            group_count=$((group_count + ${#groups[@]}))
        fi
        if [[ -n "$right" ]]; then
            IFS=':' read -r -a groups <<< "$right"
            group_count=$((group_count + ${#groups[@]}))
        fi
        ((group_count < 8)) || return 1
        return 0
    fi

    share_uri_validate_ipv6_side "$value" || return 1
    IFS=':' read -r -a groups <<< "$value"
    ((${#groups[@]} == 8))
}

share_uri_validate_ipv4() {
    local address=$1
    local octet=''
    local -a octets=()

    IFS='.' read -r -a octets <<< "$address"
    ((${#octets[@]} == 4)) || return 1
    for octet in "${octets[@]}"; do
        [[ "$octet" =~ ^[0-9]{1,3}$ ]] || return 1
        ((10#$octet <= 255)) || return 1
    done
}

share_uri_validate_host() {
    local host=$1
    local label=''
    local -a labels=()
    local LC_ALL=C

    [[ -n "$host" && ${#host} -le 253 ]] || return 1
    [[ ! "$host" =~ [[:cntrl:][:space:]/?#@\[\]] ]] || return 1
    if [[ "$host" == *:* ]]; then
        share_uri_validate_ipv6 "$host"
        return $?
    fi
    if [[ "$host" =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then
        share_uri_validate_ipv4 "$host"
        return $?
    fi

    [[ "$host" =~ ^[A-Za-z0-9.-]+$ ]] || return 1
    [[ "$host" != .* && "$host" != *..* && "$host" != *. ]] || return 1
    IFS='.' read -r -a labels <<< "$host"
    for label in "${labels[@]}"; do
        [[ -n "$label" && ${#label} -le 63 ]] || return 1
        [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
    done
}

share_uri_validate_port() {
    local port=$1

    [[ ${#port} -le 5 && "$port" =~ ^[0-9]+$ ]] || return 1
    ((10#$port >= 1 && 10#$port <= 65535)) || return 1
}

share_uri_validate_sni() {
    local sni=$1

    share_uri_validate_host "$sni"
}

share_uri_validate_uuid() {
    local uuid=$1

    [[ "$uuid" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]
}

share_uri_validate_fingerprint() {
    case "$1" in
        chrome|firefox|safari|edge)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

share_uri_validate_boolean() {
    case "$1" in
        0|1|true|false|TRUE|FALSE|True|False)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

share_uri_boolean_value() {
    case "$1" in
        1|true|TRUE|True)
            printf '1'
            ;;
        *)
            printf '0'
            ;;
    esac
}

share_uri_normalize_label() {
    local label=$1
    local fallback=$2
    local output=''
    local character=''
    local previous_dash=0
    local index=0
    local label_length=0
    local LC_ALL=C

    label_length=${#label}
    for ((index = 0; index < label_length; index++)); do
        character=${label:index:1}
        case "$character" in
            [A-Za-z0-9._-])
                output+=$character
                previous_dash=0
                ;;
            [[:space:]/\\])
                if ((previous_dash == 0)); then
                    output+='-'
                    previous_dash=1
                fi
                ;;
            *)
                if ((previous_dash == 0)); then
                    output+='-'
                    previous_dash=1
                fi
                ;;
        esac
    done

    while [[ "$output" == -* || "$output" == .* ]]; do
        output=${output:1}
    done
    while [[ "$output" == *- || "$output" == . ]]; do
        output=${output:0:${#output}-1}
    done
    [[ -n "$output" && "$output" != . && "$output" != .. ]] || output=$fallback
    if [[ "$output" == *.json ]]; then
        output=${output%.json}
    fi
    output=${output:0:96}
    [[ -n "$output" ]] || output=$fallback
    printf '%s.json' "$output"
}

share_uri_split_uri() {
    local uri=$1
    local before_fragment=$uri
    local fragment_raw=''
    local main=$uri
    local query_raw=''
    local index=0
    local uri_length=0
    local character=''
    local fragment_index=-1
    local query_index=-1
    local LC_ALL=C

    uri_length=${#uri}
    for ((index = 0; index < uri_length; index++)); do
        character=${uri:index:1}
        if [[ "$character" == '#' ]]; then
            fragment_index=$index
            break
        fi
    done
    if ((fragment_index >= 0)); then
        before_fragment=${uri:0:fragment_index}
        fragment_raw=${uri:fragment_index+1}
    fi

    uri_length=${#before_fragment}
    for ((index = 0; index < uri_length; index++)); do
        character=${before_fragment:index:1}
        if [[ "$character" == '?' ]]; then
            query_index=$index
            break
        fi
    done
    if ((query_index >= 0)); then
        main=${before_fragment:0:query_index}
        query_raw=${before_fragment:query_index+1}
    else
        main=$before_fragment
    fi

    [[ "$main" =~ ^([A-Za-z][A-Za-z0-9+.-]*):\/\/(.+)$ ]] || return 1
    share_uri_scheme=${BASH_REMATCH[1],,}
    share_uri_authority=${BASH_REMATCH[2]}
    share_uri_query_raw=$query_raw
    share_uri_fragment_raw=$fragment_raw
}

share_uri_parse_authority() {
    local authority=$1
    local userinfo_raw=''
    local hostport_raw=''
    local host_raw=''
    local port_raw=''
    local decoded_userinfo=''
    local decoded_host=''
    local rest=''
    local bracketed=0
    local LC_ALL=C

    [[ "$authority" == *@* ]] || {
        share_uri_fail missing-userinfo
        return $?
    }
    userinfo_raw=${authority%@*}
    hostport_raw=${authority##*@}
    [[ -n "$userinfo_raw" && -n "$hostport_raw" && "$userinfo_raw" != *@* ]] || {
        share_uri_fail invalid-authority
        return $?
    }

    share_uri_decode_or_fail "$userinfo_raw" decoded_userinfo || return $?
    if [[ "$share_uri_scheme" == vless ]]; then
        share_uri_validate_uuid "$decoded_userinfo" || {
            share_uri_fail invalid-uuid
            return $?
        }
        share_uri_uuid=${decoded_userinfo,,}
    else
        [[ ${#decoded_userinfo} -le 1024 && -n "$decoded_userinfo" ]] || {
            share_uri_fail invalid-hysteria-password
            return $?
        }
        share_uri_password=$decoded_userinfo
    fi

    if [[ "$hostport_raw" == \[* ]]; then
        bracketed=1
        [[ "$hostport_raw" == *\]* ]] || {
            share_uri_fail invalid-host
            return $?
        }
        host_raw=${hostport_raw#\[}
        host_raw=${host_raw%%\]*}
        rest=${hostport_raw#*\]}
        [[ -n "$host_raw" && "$rest" == :* && "$rest" != *:*:* ]] || {
            share_uri_fail invalid-authority
            return $?
        }
        port_raw=${rest#:}
    else
        [[ "$hostport_raw" == *:* ]] || {
            share_uri_fail missing-port
            return $?
        }
        host_raw=${hostport_raw%:*}
        port_raw=${hostport_raw##*:}
        [[ "$host_raw" != *:* ]] || {
            share_uri_fail invalid-host
            return $?
        }
    fi

    share_uri_decode_or_fail "$host_raw" decoded_host || return $?
    if ((bracketed == 0)) && [[ "$decoded_host" == *:* ]]; then
        share_uri_fail invalid-host
        return $?
    fi
    share_uri_validate_host "$decoded_host" || {
        share_uri_fail invalid-host
        return $?
    }
    share_uri_validate_port "$port_raw" || {
        share_uri_fail invalid-port
        return $?
    }
    share_uri_server=$decoded_host
    share_uri_server_port=$((10#$port_raw))
}

share_uri_query_key() {
    local key=$1

    case "$key" in
        allowinsecure)
            printf 'insecure'
            ;;
        obfspassword)
            printf 'obfs-password'
            ;;
        headertype)
            printf 'headertype'
            ;;
        *)
            printf '%s' "$key"
            ;;
    esac
}

share_uri_assign_query() {
    local key=$1
    local value=$2

    case "$share_uri_scheme:$key" in
        vless:encryption)
            share_uri_encryption=$value
            ;;
        vless:flow)
            share_uri_flow=$value
            share_uri_seen_flow=1
            ;;
        vless:security)
            share_uri_security=${value,,}
            share_uri_seen_security=1
            ;;
        vless:sni)
            share_uri_sni=$value
            ;;
        vless:fp)
            share_uri_fingerprint=${value,,}
            share_uri_seen_fp=1
            ;;
        vless:pbk)
            share_uri_public_key=$value
            share_uri_seen_pbk=1
            ;;
        vless:sid)
            share_uri_short_id=${value,,}
            share_uri_seen_sid=1
            ;;
        vless:type)
            share_uri_transport_type=${value,,}
            share_uri_seen_type=1
            ;;
        vless:headertype)
            share_uri_header_type=${value,,}
            share_uri_seen_header_type=1
            ;;
        vless:host)
            share_uri_ws_host=$value
            share_uri_seen_host=1
            ;;
        vless:path)
            share_uri_ws_path=$value
            share_uri_seen_path=1
            ;;
        vless:alpn)
            share_uri_alpn=$value
            share_uri_seen_alpn=1
            ;;
        hysteria2:sni)
            share_uri_sni=$value
            ;;
        hysteria2:insecure)
            share_uri_validate_boolean "$value" || {
                share_uri_fail invalid-boolean
                return $?
            }
            share_uri_insecure=$(share_uri_boolean_value "$value")
            share_uri_insecure_seen=1
            ;;
        hysteria2:obfs)
            share_uri_obfs=${value,,}
            ;;
        hysteria2:obfs-password)
            share_uri_obfs_password=$value
            share_uri_obfs_password_seen=1
            ;;
        *)
            share_uri_fail "unsupported-${share_uri_scheme}-parameter"
            return $?
            ;;
    esac
}

share_uri_parse_query() {
    local query=$1
    local remaining=$query
    local item=''
    local key_raw=''
    local value_raw=''
    local decoded_key=''
    local decoded_value=''
    local key=''
    local count=0
    local LC_ALL=C

    [[ -n "$query" ]] || return 0
    while :; do
        if [[ "$remaining" == *'&'* ]]; then
            item=${remaining%%&*}
            remaining=${remaining#*&}
        else
            item=$remaining
            remaining=''
        fi
        count=$((count + 1))
        ((count <= 64)) || {
            share_uri_fail too-many-query-parameters
            return $?
        }
        [[ -n "$item" ]] || {
            share_uri_fail empty-query-parameter
            return $?
        }
        if [[ "$item" == *=* ]]; then
            key_raw=${item%%=*}
            value_raw=${item#*=}
        else
            key_raw=$item
            value_raw=''
        fi
        [[ -n "$key_raw" ]] || {
            share_uri_fail empty-query-key
            return $?
        }
        share_uri_decode_or_fail "$key_raw" decoded_key || return $?
        share_uri_decode_or_fail "$value_raw" decoded_value || return $?
        decoded_key=${decoded_key,,}
        [[ ${#decoded_key} -le 64 && "$decoded_key" =~ ^[a-z0-9._-]+$ ]] || {
            share_uri_fail invalid-query-key
            return $?
        }
        key=$(share_uri_query_key "$decoded_key")
        if [[ "$share_uri_query_seen" == *"|$key|"* ]]; then
            share_uri_fail duplicate-query-key
            return $?
        fi
        share_uri_query_seen+="|$key|"
        share_uri_assign_query "$key" "$decoded_value" || return $?
        [[ -n "$remaining" ]] || break
    done
}

share_uri_validate_alpn() {
    local alpn=$1
    local part=''
    local remaining=$alpn

    [[ ${#alpn} -le 256 && -n "$alpn" ]] || return 1
    while :; do
        if [[ "$remaining" == *,* ]]; then
            part=${remaining%%,*}
            remaining=${remaining#*,}
        else
            part=$remaining
            remaining=''
        fi
        [[ -n "$part" && "$part" != *[[:space:]]* ]] || return 1
        case "$part" in
            h2|http/1.1|h3)
                ;;
            *)
                return 1
                ;;
        esac
        [[ -n "$remaining" ]] || break
    done
}

share_uri_is_ip_literal() {
    local host=$1

    if [[ "$host" == *:* ]]; then
        return 0
    fi
    [[ "$host" =~ ^[0-9]+(\.[0-9]+){3}$ ]]
}

share_uri_validate_vless() {
    local alpn_part=''

    [[ "$share_uri_encryption" == '' || "$share_uri_encryption" == none ]] || {
        share_uri_fail invalid-encryption
        return $?
    }
    [[ "$share_uri_security" == reality || "$share_uri_security" == tls ]] || {
        share_uri_fail invalid-security
        return $?
    }
    [[ "$share_uri_transport_type" == tcp || "$share_uri_transport_type" == ws ]] || {
        share_uri_fail invalid-transport
        return $?
    }
    if ((share_uri_seen_fp)); then
        share_uri_validate_fingerprint "$share_uri_fingerprint" || {
            share_uri_fail invalid-fingerprint
            return $?
        }
    fi

    if [[ "$share_uri_security" == reality ]]; then
        [[ "$share_uri_flow" == xtls-rprx-vision ]] || {
            share_uri_fail invalid-flow
            return $?
        }
        [[ "$share_uri_transport_type" == tcp ]] || {
            share_uri_fail unsupported-vless-combination
            return $?
        }
        [[ -n "$share_uri_sni" ]] || {
            share_uri_fail missing-reality-sni
            return $?
        }
        share_uri_validate_sni "$share_uri_sni" || {
            share_uri_fail invalid-sni
            return $?
        }
        ((share_uri_seen_fp)) || {
            share_uri_fail missing-reality-fingerprint
            return $?
        }
        [[ "$share_uri_public_key" =~ ^[A-Za-z0-9_-]{8,128}$ ]] || {
            share_uri_fail missing-reality-public-key
            return $?
        }
        if ((share_uri_seen_sid)); then
            [[ "$share_uri_short_id" =~ ^[0-9A-Fa-f]{0,16}$ && $(( ${#share_uri_short_id} % 2 )) -eq 0 ]] || {
                share_uri_fail invalid-short-id
                return $?
            }
        fi
        if ((share_uri_seen_header_type)); then
            [[ "$share_uri_header_type" == none ]] || {
                share_uri_fail invalid-header-type
                return $?
            }
        fi
        ((share_uri_seen_host == 0 && share_uri_seen_path == 0 && share_uri_seen_alpn == 0)) || {
            share_uri_fail unsupported-vless-combination
            return $?
        }
        share_uri_variant=reality/vision
        share_uri_protocol=vless
        share_uri_warning_code=''
        return 0
    fi

    [[ "$share_uri_transport_type" == ws ]] || {
        share_uri_fail unsupported-vless-combination
        return $?
    }
    [[ -n "$share_uri_sni" ]] || {
        share_uri_fail missing-ws-sni
        return $?
    }
    share_uri_validate_sni "$share_uri_sni" || {
        share_uri_fail invalid-sni
        return $?
    }
    [[ "$share_uri_ws_path" == /* || $share_uri_seen_path == 0 ]] || {
        share_uri_fail invalid-ws-path
        return $?
    }
    [[ ${#share_uri_ws_path} -le 2048 ]] || {
        share_uri_fail invalid-ws-path
        return $?
    }
    if ((share_uri_seen_host)); then
        share_uri_validate_host "$share_uri_ws_host" || {
            share_uri_fail invalid-ws-host
            return $?
        }
    fi
    if ((share_uri_seen_alpn)); then
        share_uri_validate_alpn "$share_uri_alpn" || {
            share_uri_fail invalid-alpn
            return $?
        }
    fi
    ((share_uri_seen_flow == 0 && share_uri_seen_pbk == 0 && share_uri_seen_sid == 0)) || {
        share_uri_fail unsupported-vless-combination
        return $?
    }
    ((share_uri_seen_header_type == 0)) || {
        share_uri_fail unsupported-vless-combination
        return $?
    }
    [[ -n "$share_uri_ws_path" ]] || share_uri_ws_path=/
    share_uri_variant=ws/tls
    share_uri_protocol=vless
    share_uri_warning_code=''
}

share_uri_validate_hysteria2() {
    [[ -n "$share_uri_password" ]] || {
        share_uri_fail invalid-hysteria-password
        return $?
    }
    if [[ -n "$share_uri_sni" ]]; then
        share_uri_validate_sni "$share_uri_sni" || {
            share_uri_fail invalid-sni
            return $?
        }
    elif share_uri_is_ip_literal "$share_uri_server"; then
        share_uri_fail missing-hysteria-sni
        return $?
    else
        share_uri_sni=$share_uri_server
    fi
    case "$share_uri_obfs" in
        '')
            ((share_uri_obfs_password_seen == 0)) || {
                share_uri_fail unsupported-obfs
                return $?
            }
            ;;
        salamander)
            ((share_uri_obfs_password_seen)) || {
                share_uri_fail missing-obfs-password
                return $?
            }
            [[ ${#share_uri_obfs_password} -le 1024 && -n "$share_uri_obfs_password" ]] || {
                share_uri_fail invalid-obfs-password
                return $?
            }
            ;;
        *)
            share_uri_fail unsupported-obfs
            return $?
            ;;
    esac
    share_uri_variant=quic/tls
    share_uri_protocol=hysteria2
    if ((share_uri_insecure)); then
        share_uri_warning_code=certificate-verification-disabled
    else
        share_uri_warning_code=''
    fi
}

share_uri_parse() {
    local uri=${1:-}
    local uri_length=0
    local decoded_fragment=''
    local LC_ALL=C

    share_uri_reset
    (($# == 1)) || return 2
    uri_length=${#uri}
    ((uri_length <= 16384)) || {
        share_uri_fail oversized-input
        return $?
    }
    [[ ! "$uri" =~ [[:cntrl:]] ]] || {
        share_uri_fail control-character
        return $?
    }
    share_uri_split_uri "$uri" || {
        share_uri_fail invalid-uri
        return $?
    }
    case "$share_uri_scheme" in
        vless|hysteria2|hy2)
            ;;
        *)
            share_uri_fail unsupported-scheme
            return $?
            ;;
    esac
    [[ "$share_uri_scheme" != hy2 ]] || share_uri_scheme=hysteria2
    share_uri_protocol=$share_uri_scheme
    share_uri_parse_authority "$share_uri_authority" || return $?
    share_uri_parse_query "$share_uri_query_raw" || return $?
    share_uri_decode_or_fail "$share_uri_fragment_raw" decoded_fragment || return $?
    [[ ${#decoded_fragment} -le 128 ]] || {
        share_uri_fail invalid-label
        return $?
    }
    share_uri_fragment=$decoded_fragment

    if [[ "$share_uri_scheme" == vless ]]; then
        share_uri_validate_vless || return $?
        if [[ "$share_uri_variant" == reality/vision ]]; then
            share_uri_suggested_basename=$(share_uri_normalize_label "$share_uri_fragment" vless-reality)
        else
            share_uri_suggested_basename=$(share_uri_normalize_label "$share_uri_fragment" vless-ws)
        fi
    else
        share_uri_validate_hysteria2 || return $?
        share_uri_suggested_basename=$(share_uri_normalize_label "$share_uri_fragment" hysteria2)
    fi

    share_uri_parse_succeeded=1
    share_uri_error_code=''
    return 0
}

share_uri_require_parsed() {
    ((${share_uri_parse_succeeded:-0} == 1)) || {
        share_uri_fail no-parsed-uri
        return $?
    }
}

share_uri_preview_json() {
    local warning_json='[]'

    (($# == 0)) || return 2
    share_uri_require_parsed || return $?
    command -v jq >/dev/null 2>&1 || return 3
    if [[ -n "$share_uri_warning_code" ]]; then
        warning_json=$(jq -cn --arg warning "$share_uri_warning_code" '[$warning]') || return 1
    fi
    jq -cn \
        --arg protocol "$share_uri_protocol" \
        --arg variant "$share_uri_variant" \
        --arg server "$share_uri_server" \
        --argjson server_port "$share_uri_server_port" \
        --arg basename "$share_uri_suggested_basename" \
        --arg local_listen 127.0.0.1 \
        --argjson local_port 10808 \
        --argjson warnings "$warning_json" \
        '{
            protocol: $protocol,
            variant: $variant,
            server: $server,
            server_port: $server_port,
            suggested_basename: $basename,
            local_listen: $local_listen,
            local_port: $local_port,
            warnings: $warnings
        }'
}

share_uri_validate_output_path() {
    local output_path=$1
    local parent=''

    [[ "$output_path" == /* && "$output_path" != *$'\n'* && "$output_path" != *$'\r'* ]] || return 1
    [[ ! -L "$output_path" && ! -e "$output_path" ]] || return 1
    parent=${output_path%/*}
    [[ -n "$parent" && -d "$parent" && ! -L "$parent" ]] || return 1
}

share_uri_create_temp_file() {
    local directory=$1
    local temporary_path=''

    [[ -d "$directory" && ! -L "$directory" ]] || return 1
    temporary_path=$(umask 077; mktemp "$directory/.netui-share.XXXXXX") || return 1
    [[ -f "$temporary_path" && ! -L "$temporary_path" ]] || {
        rm -f -- "$temporary_path"
        return 1
    }
    chmod 600 -- "$temporary_path" || {
        rm -f -- "$temporary_path"
        return 1
    }
    printf '%s' "$temporary_path"
}

share_uri_json_write() {
    local output_path=$1

    [[ -f "$output_path" && ! -L "$output_path" ]] || {
        share_uri_fail unsafe-output-path
        return $?
    }
    command -v jq >/dev/null 2>&1 || {
        share_uri_error_code=missing-jq
        return 3
    }
    if ! (
        umask 077
        if [[ "$share_uri_variant" == reality/vision ]]; then
            printf '%s\n' \
                "$share_uri_server" "$share_uri_server_port" "$share_uri_uuid" \
                "$share_uri_flow" "$share_uri_sni" "$share_uri_fingerprint" \
                "$share_uri_public_key" "$share_uri_short_id" |
                jq -Rn '
                    input as $server |
                    (input | tonumber) as $server_port |
                    input as $uuid |
                    input as $flow |
                    input as $sni |
                    input as $fp |
                    input as $pbk |
                    input as $sid |
                    {
                        log: {level: "info", timestamp: true},
                        inbounds: [{type: "mixed", tag: "mixed-in", listen: "127.0.0.1", listen_port: 10808}],
                        outbounds: [
                            ({
                                type: "vless",
                                tag: "proxy",
                                server: $server,
                                server_port: $server_port,
                                uuid: $uuid,
                                flow: $flow,
                                tls: ({
                                    enabled: true,
                                    server_name: $sni,
                                    utls: {enabled: true, fingerprint: $fp},
                                    reality: ({enabled: true, public_key: $pbk} + (if $sid == "" then {} else {short_id: $sid} end))
                                })
                            }),
                            {type: "direct", tag: "direct"}
                        ],
                        route: {final: "proxy"}
                    }
                ' > "$output_path"
        elif [[ "$share_uri_variant" == ws/tls ]]; then
            printf '%s\n' \
                "$share_uri_server" "$share_uri_server_port" "$share_uri_uuid" \
                "$share_uri_sni" "$share_uri_fingerprint" "$share_uri_alpn" \
                "$share_uri_ws_host" "$share_uri_ws_path" |
                jq -Rn '
                    input as $server |
                    (input | tonumber) as $server_port |
                    input as $uuid |
                    input as $sni |
                    input as $fp |
                    input as $alpn |
                    input as $host |
                    input as $path |
                    {
                        log: {level: "info", timestamp: true},
                        inbounds: [{type: "mixed", tag: "mixed-in", listen: "127.0.0.1", listen_port: 10808}],
                        outbounds: [
                            ({
                                type: "vless",
                                tag: "proxy",
                                server: $server,
                                server_port: $server_port,
                                uuid: $uuid,
                                tls: ({enabled: true, server_name: $sni}
                                    + (if $fp == "" then {} else {utls: {enabled: true, fingerprint: $fp}} end)
                                    + (if $alpn == "" then {} else {alpn: ($alpn | split(","))} end)),
                                transport: ({type: "ws", path: $path}
                                    + (if $host == "" then {} else {headers: {Host: $host}} end))
                            }),
                            {type: "direct", tag: "direct"}
                        ],
                        route: {final: "proxy"}
                    }
                ' > "$output_path"
        else
            printf '%s\n' \
                "$share_uri_server" "$share_uri_server_port" "$share_uri_password" \
                "$share_uri_sni" "$share_uri_insecure" "$share_uri_obfs" \
                "$share_uri_obfs_password" |
                jq -Rn '
                    input as $server |
                    (input | tonumber) as $server_port |
                    input as $password |
                    input as $sni |
                    input as $insecure |
                    input as $obfs |
                    input as $obfs_password |
                    {
                        log: {level: "info", timestamp: true},
                        inbounds: [{type: "mixed", tag: "mixed-in", listen: "127.0.0.1", listen_port: 10808}],
                        outbounds: [
                            ({
                                type: "hysteria2",
                                tag: "proxy",
                                server: $server,
                                server_port: $server_port,
                                password: $password,
                                tls: {enabled: true, server_name: $sni, insecure: ($insecure == "1")}
                            }
                            + (if $obfs == "" then {} else {obfs: {type: $obfs, password: $obfs_password}} end)),
                            {type: "direct", tag: "direct"}
                        ],
                        route: {final: "proxy"}
                    }
                ' > "$output_path"
        fi
        chmod 600 -- "$output_path"
        jq empty -- "$output_path"
    ); then
        rm -f -- "$output_path"
        share_uri_fail generated-config-invalid
        return $?
    fi
    chmod 600 -- "$output_path"
}

share_uri_generate_config() {
    local output_path=${1:-}
    local parent=''
    local temporary_path=''

    (($# == 1)) || return 2
    share_uri_require_parsed || return $?
    share_uri_validate_output_path "$output_path" || {
        share_uri_fail unsafe-output-path
        return $?
    }
    parent=${output_path%/*}
    temporary_path=$(share_uri_create_temp_file "$parent") || {
        share_uri_fail temporary-file-create-failed
        return $?
    }
    if ! share_uri_json_write "$temporary_path"; then
        rm -f -- "$temporary_path"
        return $?
    fi
    if ! mv -nT -- "$temporary_path" "$output_path" || [[ -e "$temporary_path" || -L "$temporary_path" ]]; then
        rm -f -- "$temporary_path"
        share_uri_fail generated-config-commit-failed
        return $?
    fi
    chmod 600 -- "$output_path"
}

share_uri_resolve_core() {
    local candidate=''
    local resolved=''

    if [[ -n "${NETUI_SING_BOX:-}" ]]; then
        candidate=$NETUI_SING_BOX
        if [[ "$candidate" != */* ]]; then
            candidate=$(command -v "$candidate" 2>/dev/null) || return 1
        fi
    elif [[ -n "${NETUI_PACKAGE_ROOT:-}" && -x "$NETUI_PACKAGE_ROOT/bin/sing-box" ]]; then
        candidate="$NETUI_PACKAGE_ROOT/bin/sing-box"
    else
        candidate=$(command -v sing-box 2>/dev/null) || return 1
    fi
    resolved=$(realpath -e -- "$candidate" 2>/dev/null) || return 1
    [[ -x "$resolved" && -f "$resolved" ]] || return 1
    printf '%s' "$resolved"
}

share_uri_import_basename() {
    local requested=$1
    local fallback=$2
    local normalized=''

    if [[ -n "$requested" ]]; then
        normalized=$(share_uri_normalize_label "$requested" "${fallback%.json}")
    else
        normalized=$fallback
    fi
    [[ "$normalized" == *.json && "$normalized" != */* && "$normalized" != *$'\n'* ]] || return 1
    printf '%s' "$normalized"
}

_share_uri_import_unlocked() {
    local requested=${1:-}
    local target_basename=''
    local base_basename=''
    local target_path=''
    local temporary_path=''
    local core_path=''
    local attempt=0

    target_basename=$(share_uri_import_basename "$requested" "$share_uri_suggested_basename") || {
        share_uri_fail invalid-import-name
        return $?
    }
    base_basename=$target_basename
    while ((attempt < 100)); do
        if ((attempt == 0)); then
            target_basename=$base_basename
        elif [[ "$base_basename" == *.json ]]; then
            target_basename="${base_basename%.json}-$((attempt + 1)).json"
        fi
        target_path="$NETUI_CONFIG_DIR/$target_basename"
        if [[ ! -e "$target_path" && ! -L "$target_path" ]]; then
            break
        fi
        attempt=$((attempt + 1))
    done
    ((attempt < 100)) || {
        share_uri_fail import-name-collision
        return $?
    }

    temporary_path=$(share_uri_create_temp_file "$NETUI_CONFIG_DIR") || {
        share_uri_fail temporary-file-create-failed
        return $?
    }
    share_uri_json_write "$temporary_path" || {
        rm -f -- "$temporary_path"
        return $?
    }
    core_path=$(share_uri_resolve_core) || {
        rm -f -- "$temporary_path"
        share_uri_error_code=missing-sing-box
        return 3
    }
    if ! "$core_path" check -c "$temporary_path" >/dev/null 2>&1; then
        rm -f -- "$temporary_path"
        share_uri_fail sing-box-check-failed
        return $?
    fi
    if ! mv -nT -- "$temporary_path" "$target_path" || [[ -e "$temporary_path" || -L "$temporary_path" ]]; then
        rm -f -- "$temporary_path"
        share_uri_fail import-commit-failed
        return $?
    fi
    chmod 600 -- "$target_path" || return 1
    share_uri_last_path=$target_path
    return 0
}

share_uri_import() {
    local uri=${1:-}
    local requested=${2:-}

    share_uri_last_path=''
    (($# >= 1 && $# <= 2)) || return 2
    share_uri_parse "$uri" || return $?
    [[ -n "${NETUI_CONFIG_DIR:-}" && "$NETUI_CONFIG_DIR" == /* ]] || {
        share_uri_fail missing-config-directory
        return $?
    }
    if declare -F netui_init_dirs >/dev/null 2>&1; then
        netui_init_dirs || {
            share_uri_fail config-directory-unavailable
            return $?
        }
    else
        [[ -d "$NETUI_CONFIG_DIR" && ! -L "$NETUI_CONFIG_DIR" ]] || {
            share_uri_fail config-directory-unavailable
            return $?
        }
    fi
    if declare -F netui_with_lock >/dev/null 2>&1; then
        netui_with_lock _share_uri_import_unlocked "$requested"
    else
        _share_uri_import_unlocked "$requested"
    fi
}
