#!/bin/bash

set -u

script_dir=$(cd -P -- "${0%/*}" && pwd -P)
repo_root=$(cd -P -- "$script_dir/../.." && pwd -P)
test_home=$(mktemp -d "${TMPDIR:-/tmp}/netui-uri.XXXXXX")
fake_sing_box="$test_home/fake-sing-box"
failures=0
checks=0

cleanup() {
    rm -rf -- "$test_home"
}
trap cleanup EXIT HUP INT TERM

export HOME="$test_home"
export XDG_CONFIG_HOME="$test_home/config-home"
export XDG_DATA_HOME="$test_home/data-home"
export XDG_STATE_HOME="$test_home/state-home"
export NETUI_SING_BOX="$fake_sing_box"

cat > "$fake_sing_box" <<'EOF'
#!/bin/bash

if [[ "${1-}" == check && "${2-}" == -c && -n "${3-}" ]]; then
    if [[ "${FAKE_SING_BOX_FAIL:-0}" == 1 ]]; then
        exit 1
    fi
    jq empty -- "$3" >/dev/null 2>&1
    exit $?
fi
exit 2
EOF
chmod 700 -- "$fake_sing_box"

# shellcheck source=../../packages/netui/lib/common.sh
source "$repo_root/packages/netui/lib/common.sh"
# shellcheck source=../../packages/netui/lib/paths.sh
source "$repo_root/packages/netui/lib/paths.sh"
# shellcheck source=../../packages/netui/lib/config_store.sh
source "$repo_root/packages/netui/lib/config_store.sh"
# shellcheck source=../../packages/netui/lib/config_meta.sh
source "$repo_root/packages/netui/lib/config_meta.sh"
# shellcheck source=../../packages/netui/lib/share_uri.sh
source "$repo_root/packages/netui/lib/share_uri.sh"

netui_init_dirs

assert_status() {
    local expected=$1
    local label=$2
    shift 2
    local actual=0

    checks=$((checks + 1))
    "$@"
    actual=$?
    if ((actual != expected)); then
        printf 'FAIL: %s (expected %s, got %s)\n' "$label" "$expected" "$actual" >&2
        failures=$((failures + 1))
    else
        printf 'ok: %s\n' "$label"
    fi
}

assert_true() {
    local label=$1
    shift

    checks=$((checks + 1))
    if "$@"; then
        printf 'ok: %s\n' "$label"
    else
        printf 'FAIL: %s\n' "$label" >&2
        failures=$((failures + 1))
    fi
}

assert_json_query() {
    local label=$1
    local json=$2
    local query=$3

    checks=$((checks + 1))
    if jq -e "$query" <<< "$json" >/dev/null 2>&1; then
        printf 'ok: %s\n' "$label"
    else
        printf 'FAIL: %s\n' "$label" >&2
        failures=$((failures + 1))
    fi
}

scheme_separator=':'
reality_uri="vless${scheme_separator}//00000000-0000-4000-8000-000000000001@192.0.2.10:443?encryption=none&type=tcp&security=reality&flow=xtls-rprx-vision&sni=reality.example.invalid&fp=chrome&pbk=SYNTHETIC_PUBLIC_KEY_1234567890&sid=0123&headerType=none#synthetic-reality"
ws_uri="vless${scheme_separator}//00000000-0000-4000-8000-000000000002@ws.example.invalid:443?type=ws&security=tls&sni=proxy.example.invalid&fp=chrome&host=proxy.example.invalid&path=%2Fsynthetic%2Fpath&alpn=http%2F1.1#synthetic-ws"
hysteria_uri="hysteria2${scheme_separator}//SYNTHETIC-HY2-PASSWORD@hy.example.invalid:443?sni=hy.example.invalid&insecure=1&obfs=salamander&obfs-password=SYNTHETIC-OBFS-PASSWORD#synthetic-hy2"

assert_status 0 'parse VLESS REALITY Vision URI' share_uri_parse "$reality_uri"
reality_preview=$(share_uri_preview_json)
assert_json_query 'REALITY preview exposes only safe summary fields' "$reality_preview" '.protocol == "vless" and .variant == "reality/vision" and .server == "192.0.2.10" and .server_port == 443 and .warnings == []'
assert_true 'REALITY preview omits UUID and public key' bash -c '! grep -Eq "00000000-0000|SYNTHETIC_PUBLIC_KEY|xtls-rprx-vision" <<< "$1"' -- "$reality_preview"
reality_config="$test_home/reality.json"
assert_status 0 'generate VLESS REALITY JSON' share_uri_generate_config "$reality_config"
assert_json_query 'generated REALITY JSON has expected mapping' "$(<"$reality_config")" '.outbounds[0].type == "vless" and .outbounds[0].flow == "xtls-rprx-vision" and .outbounds[0].tls.reality.enabled == true and .outbounds[0].tls.server_name == "reality.example.invalid" and .inbounds[0].listen == "127.0.0.1"'
assert_true 'generated REALITY JSON is private' test "$(stat -c '%a' -- "$reality_config")" = 600

assert_status 0 'parse VLESS WebSocket TLS URI' share_uri_parse "$ws_uri"
ws_preview=$(share_uri_preview_json)
assert_json_query 'WebSocket preview decodes path without credentials' "$ws_preview" '.protocol == "vless" and .variant == "ws/tls" and .server == "ws.example.invalid" and (.warnings | length) == 0'
assert_true 'WebSocket preview omits UUID and authorization' bash -c '! grep -Eq "00000000-0000|SYNTHETIC-AUTHORIZATION" <<< "$1"' -- "$ws_preview"
ws_config="$test_home/ws.json"
assert_status 0 'generate VLESS WebSocket JSON' share_uri_generate_config "$ws_config"
assert_json_query 'generated WebSocket JSON maps transport and ALPN' "$(<"$ws_config")" '.outbounds[0].transport.type == "ws" and .outbounds[0].transport.path == "/synthetic/path" and .outbounds[0].transport.headers.Host == "proxy.example.invalid" and .outbounds[0].tls.alpn == ["http/1.1"]'

assert_status 0 'parse Hysteria2 URI' share_uri_parse "$hysteria_uri"
hysteria_preview=$(share_uri_preview_json)
assert_json_query 'Hysteria2 insecure preview contains warning code' "$hysteria_preview" '.protocol == "hysteria2" and .variant == "quic/tls" and .warnings == ["certificate-verification-disabled"]'
hysteria_config="$test_home/hysteria2.json"
assert_status 0 'generate Hysteria2 JSON' share_uri_generate_config "$hysteria_config"
assert_json_query 'generated Hysteria2 JSON maps insecure TLS and obfs' "$(<"$hysteria_config")" '.outbounds[0].type == "hysteria2" and .outbounds[0].password == "SYNTHETIC-HY2-PASSWORD" and .outbounds[0].tls.insecure == true and .outbounds[0].obfs.type == "salamander"'

for proxy_config in "$reality_config" "$ws_config" "$hysteria_config"; do
    assert_json_query 'mixed proxy uses system routing without binding DNS to a NIC' "$(<"$proxy_config")" '
        .inbounds[0].type == "mixed" and .route.final == "proxy"
        and (.route.auto_detect_interface != true)
        and ((.route.default_interface // "") == "")
        and all(.outbounds[]; (.bind_interface // "") == "")'
done

hy2_uri="hy2${hysteria_uri#hysteria2}"
assert_status 0 'parse hy2 alias' share_uri_parse "$hy2_uri"
assert_true 'hy2 alias normalizes to Hysteria2 protocol' test "$share_uri_protocol" = hysteria2

plus_uri="hysteria2${scheme_separator}//pass+word@hy.example.invalid:443?sni=hy.example.invalid"
assert_status 0 'parse plus as literal credential byte' share_uri_parse "$plus_uri"
assert_true 'plus is not converted to a space' test "$share_uri_password" = 'pass+word'

ipv6_uri="hysteria2${scheme_separator}//SYNTHETIC-PASSWORD@[2001:db8::10]:443?sni=hy.example.invalid"
assert_status 0 'parse bracketed IPv6 authority' share_uri_parse "$ipv6_uri"
assert_true 'IPv6 authority is stored without brackets' test "$share_uri_server" = '2001:db8::10'

reality_query=${reality_uri%%#*}
for invalid_case in \
    "${reality_query}&fp=chrome#synthetic-reality" \
    "${reality_query}&unknown=1#synthetic-reality" \
    "${reality_query}&path=%#synthetic-reality" \
    "${reality_query}&path=%00#synthetic-reality" \
    "${reality_query}&path=%0A#synthetic-reality" \
    "vless${scheme_separator}//not-a-uuid@192.0.2.10:443?type=tcp&security=reality&flow=xtls-rprx-vision&sni=reality.example.invalid&fp=chrome&pbk=SYNTHETIC_PUBLIC_KEY_1234567890" \
    "hysteria2${scheme_separator}//SYNTHETIC-PASSWORD@hy.example.invalid:65536?sni=hy.example.invalid"; do
    assert_status 5 'reject malformed or unsupported URI input' share_uri_parse "$invalid_case"
done

invalid_stderr="$test_home/invalid.stderr"
set +e
share_uri_parse "${reality_query}&path=%00#synthetic-reality" > /dev/null 2> "$invalid_stderr"
invalid_status=$?
assert_true 'invalid URI failure does not echo the raw URI' bash -c '! grep -Fq -- "$1" "$2"' -- 'SYNTHETIC_PUBLIC_KEY_1234567890' "$invalid_stderr"
assert_true 'invalid URI reports a stable error code' test "$invalid_status" -eq 5 && test "$(share_uri_last_error_code)" = nul-byte

export FAKE_SING_BOX_FAIL=0
assert_status 0 'atomic import creates first collision-free config' share_uri_import "$hysteria_uri"
first_import=$(share_uri_last_import_path)
assert_true 'first import uses suggested basename' test "${first_import##*/}" = synthetic-hy2.json
assert_true 'imported config is private' test "$(stat -c '%a' -- "$first_import")" = 600
assert_status 0 'atomic import adds numeric collision suffix' share_uri_import "$hysteria_uri"
second_import=$(share_uri_last_import_path)
assert_true 'second import uses -2 suffix' test "${second_import##*/}" = synthetic-hy2-2.json
assert_true 'import leaves no temporary files' bash -c '! compgen -G "$1/.import.*" >/dev/null && ! compgen -G "$1/.netui-share.*" >/dev/null' -- "$NETUI_CONFIG_DIR"

before_import_count=$(find "$NETUI_CONFIG_DIR" -maxdepth 1 -type f -name '*.json' | wc -l)
export FAKE_SING_BOX_FAIL=1
assert_status 5 'check failure rejects import' share_uri_import "$reality_uri" failed-check
export FAKE_SING_BOX_FAIL=0
after_import_count=$(find "$NETUI_CONFIG_DIR" -maxdepth 1 -type f -name '*.json' | wc -l)
assert_true 'check failure leaves no target or temporary config' test "$before_import_count" -eq "$after_import_count" && bash -c '! compgen -G "$1/.import.*" >/dev/null && ! compgen -G "$1/.netui-share.*" >/dev/null' -- "$NETUI_CONFIG_DIR"

for marker in \
    SYNTHETIC-HY2-PASSWORD \
    SYNTHETIC-OBFS-PASSWORD; do
    assert_true "Hysteria2 preview remains redacted for $marker" bash -c '! grep -Fq -- "$1" <<< "$2"' -- "$marker" "$hysteria_preview"
done
for marker in \
    SYNTHETIC_PUBLIC_KEY_1234567890 \
    00000000-0000-4000-8000-000000000001; do
    assert_true "REALITY preview remains redacted for $marker" bash -c '! grep -Fq -- "$1" <<< "$2"' -- "$marker" "$reality_preview"
done
assert_true 'URI import does not populate NetUI logs with raw credentials' bash -c '! grep -R -Fq -- "SYNTHETIC-HY2-PASSWORD" "$1" "$2" 2>/dev/null' -- "$NETUI_LOG_FILE" "$NETUI_NETUI_LOG_FILE"

if ((failures > 0)); then
    printf '\n%s of %s URI import checks failed\n' "$failures" "$checks" >&2
    exit 1
fi

printf '\nAll %s URI import checks passed\n' "$checks"
