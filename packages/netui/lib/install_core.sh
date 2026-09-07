#!/bin/bash

install_core_error() {
    printf 'netui install: %s\n' "$*" >&2
}

install_core_info() {
    printf 'netui install: %s\n' "$*"
}

install_core_read_version() {
    local package_root=$1
    local version=''

    [[ -f "$package_root/VERSION" && ! -L "$package_root/VERSION" ]] || return 1
    IFS= read -r version < "$package_root/VERSION" || return 1
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || return 1
    printf '%s' "$version"
}

install_core_detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)
            printf 'amd64'
            ;;
        aarch64|arm64)
            printf 'arm64'
            ;;
        *)
            install_core_error "unsupported architecture: $(uname -m)"
            return 2
            ;;
    esac
}

install_core_require_command() {
    local command_name=$1

    if ! command -v "$command_name" >/dev/null 2>&1; then
        install_core_error "missing dependency: $command_name"
        return 3
    fi
}

install_core_require_base_dependencies() {
    local command_name=''
    local missing=''

    if ((BASH_VERSINFO[0] < 4)); then
        install_core_error 'Bash 4 or newer is required'
        return 3
    fi
    for command_name in jq tmux flock sha256sum realpath tar gzip install mktemp; do
        if ! command -v "$command_name" >/dev/null 2>&1; then
            missing="$missing $command_name"
        fi
    done
    if [[ -n "$missing" ]]; then
        install_core_error "missing runtime dependencies:${missing}"
        install_core_error 'Ubuntu/Debian suggestion:'
        install_core_error '  sudo apt-get update && sudo apt-get install -y jq tmux curl'
        return 3
    fi
}

install_core_require_clone_dependencies() {
    install_core_require_command curl
}

install_core_user_paths() {
    local home_dir=${HOME:-}
    local data_home=${XDG_DATA_HOME:-}
    local bin_home=${XDG_BIN_HOME:-}
    local config_home=${XDG_CONFIG_HOME:-}
    local state_home=${XDG_STATE_HOME:-}
    local path=''

    [[ -n "$home_dir" && "$home_dir" == /* ]] || {
        install_core_error 'HOME must be an absolute path'
        return 1
    }
    [[ -n "$data_home" ]] || data_home="$home_dir/.local/share"
    [[ -n "$bin_home" ]] || bin_home="$home_dir/.local/bin"
    [[ -n "$config_home" ]] || config_home="$home_dir/.config"
    [[ -n "$state_home" ]] || state_home="$home_dir/.local/state"
    [[ "$data_home" == /* && "$bin_home" == /* && "$config_home" == /* && "$state_home" == /* ]] || {
        install_core_error 'XDG data, bin, config and state paths must be absolute'
        return 1
    }
    for path in "$data_home" "$bin_home" "$config_home" "$state_home"; do
        [[ ! -L "$path" ]] || {
            install_core_error "refusing symlink XDG base directory: $path"
            return 1
        }
    done

    NETUI_INSTALL_DATA_HOME=$data_home
    NETUI_INSTALL_BIN_HOME=$bin_home
    NETUI_INSTALL_CONFIG_HOME=$config_home
    NETUI_INSTALL_STATE_HOME=$state_home
    NETUI_INSTALL_LOCK_FILE="$data_home/netui-install.lock"
    NETUI_INSTALL_ROOT="$data_home/netui"
    NETUI_INSTALL_RELEASES="$NETUI_INSTALL_ROOT/releases"
    NETUI_INSTALL_CURRENT="$NETUI_INSTALL_ROOT/current"
}

install_core_secure_dir() {
    local path=$1

    [[ -n "$path" && "$path" == /* ]] || return 1
    [[ ! -L "$path" ]] || {
        install_core_error "refusing symlink directory: $path"
        return 1
    }
    mkdir -p -- "$path" || return 1
    chmod 700 -- "$path"
}

install_core_secure_parent() {
    local path=$1
    local parent=${path%/*}

    [[ "$parent" != "$path" && -n "$parent" ]] || return 1
    install_core_secure_dir "$parent"
}

install_core_safe_file() {
    local path=$1

    [[ -f "$path" && ! -L "$path" ]] || return 1
    [[ "$path" != *$'\n'* && "$path" != *$'\r'* ]] || return 1
}

install_core_manifest_row() {
    local package_root=$1
    local asset_name=$2
    local arch=$3
    local name=''
    local version=''
    local os_name=''
    local manifest_arch=''
    local url=''
    local sha256=''
    local license_name=''
    local note=''

    install_core_manifest_file="$package_root/manifest.lock"
    install_core_safe_file "$install_core_manifest_file" || return 1
    while IFS=$'\t' read -r name version os_name manifest_arch url sha256 license_name note; do
        [[ -n "$name" && "$name" != \#* ]] || continue
        if [[ "$name" == "$asset_name" && "$os_name" == linux && "$manifest_arch" == "$arch" ]]; then
            [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || return 1
            [[ "$url" == https://* && "$url" != *latest* && "$url" != *HEAD* ]] || return 1
            [[ "$sha256" =~ ^[0-9a-f]{64}$ && "$sha256" != - ]] || return 1
            [[ -n "$license_name" && "$license_name" != - ]] || return 1
            install_core_asset_version=$version
            install_core_asset_url=$url
            install_core_asset_sha256=$sha256
            install_core_asset_license=$license_name
            install_core_asset_filename=${url##*/}
            [[ "$install_core_asset_filename" != "$url" && "$install_core_asset_filename" != *$'\n'* ]] || return 1
            return 0
        fi
    done < "$install_core_manifest_file"
    return 1
}

install_core_verify_archive() {
    local archive=$1
    local expected_sha256=$2
    local actual_sha256=''

    install_core_safe_file "$archive" || return 1
    actual_sha256=$(sha256sum -- "$archive" 2>/dev/null) || return 1
    actual_sha256=${actual_sha256%% *}
    [[ "$actual_sha256" == "$expected_sha256" ]] || {
        install_core_error "checksum mismatch: ${archive##*/}"
        return 1
    }
}

install_core_validate_tar_listing() {
    local archive=$1
    local member=''
    local listing=''

    listing=$(tar -tzf "$archive" 2>/dev/null) || {
        install_core_error "cannot list archive: ${archive##*/}"
        return 1
    }
    while IFS= read -r member || [[ -n "$member" ]]; do
        [[ -n "$member" ]] || continue
        case "$member" in
            /*|../*|*/../*|*/..|..|*"$'\n'"*)
                install_core_error "unsafe archive member: $member"
                return 1
                ;;
        esac
    done <<< "$listing"

    while IFS= read -r member || [[ -n "$member" ]]; do
        [[ -n "$member" ]] || continue
        case "$member" in
            d*|-*)
                ;;
            *)
                install_core_error "archive contains a non-regular entry: $member"
                return 1
                ;;
        esac
    done < <(tar -tvzf "$archive" 2>/dev/null)
}

install_core_extract_asset() {
    local archive=$1
    local executable_name=$2
    local binary_destination=$3
    local license_destination=$4
    local extract_dir=$5
    local -a binary_matches=()
    local -a license_matches=()
    local binary_source=''
    local license_source=''

    install_core_validate_tar_listing "$archive" || return 1
    mkdir -p -- "$extract_dir" || return 1
    tar -xzf "$archive" -C "$extract_dir" --no-same-owner --no-same-permissions --no-overwrite-dir || return 1

    mapfile -t binary_matches < <(find -P "$extract_dir" -type f -name "$executable_name" -print)
    ((${#binary_matches[@]} == 1)) || {
        install_core_error "archive does not contain exactly one $executable_name executable"
        return 1
    }
    binary_source=${binary_matches[0]}
    [[ -x "$binary_source" ]] || chmod 755 -- "$binary_source"
    install -D -m 755 -- "$binary_source" "$binary_destination" || return 1

    if [[ -n "$license_destination" ]]; then
        mapfile -t license_matches < <(
            find -P "$extract_dir" -type f \( -iname 'LICENSE' -o -iname 'LICENSE.txt' -o -iname 'COPYING' -o -iname 'COPYING.txt' \) -print
        )
        ((${#license_matches[@]} >= 1)) || {
            install_core_error "archive does not contain a license file for $executable_name"
            return 1
        }
        license_source=${license_matches[0]}
        install -D -m 644 -- "$license_source" "$license_destination" || return 1
    fi
}

install_core_prepare_asset() {
    local package_root=$1
    local asset_name=$2
    local arch=$3
    local asset_dir=$4
    local download_dir=$5
    local archive_path=''

    install_core_manifest_row "$package_root" "$asset_name" "$arch" || {
        install_core_error "no locked $asset_name asset for linux/$arch"
        return 1
    }
    mkdir -p -- "$download_dir" || return 1
    archive_path="$download_dir/$install_core_asset_filename"
    if [[ -n "$asset_dir" ]]; then
        [[ "$asset_dir" == /* && ! -L "$asset_dir" && -d "$asset_dir" ]] || {
            install_core_error "asset directory is not a regular directory: $asset_dir"
            return 1
        }
        [[ -f "$asset_dir/$install_core_asset_filename" && ! -L "$asset_dir/$install_core_asset_filename" ]] || {
            install_core_error "missing locked asset: $asset_dir/$install_core_asset_filename"
            return 1
        }
        cp -- "$asset_dir/$install_core_asset_filename" "$archive_path" || return 1
    else
        install_core_require_clone_dependencies || return $?
        [[ "$install_core_asset_url" == https://* ]] || return 1
        curl --fail --location --silent --show-error --retry 3 --proto '=https' --tlsv1.2 \
            --output "$archive_path" "$install_core_asset_url" || {
            install_core_error "download failed: $install_core_asset_filename"
            return 1
        }
    fi
    install_core_verify_archive "$archive_path" "$install_core_asset_sha256" || return 1
    printf '%s' "$archive_path"
}

install_core_validate_source_tree() {
    local package_root=$1
    local path=''
    local required_file=''
    local -a required_files=(
        install.sh
        bootstrap.sh
        lib/install_core.sh
        manifest.lock
        VERSION
        bin/netctl
        lib/common.sh
        lib/paths.sh
        lib/config_store.sh
        lib/config_meta.sh
        lib/share_uri.sh
        lib/env_profiles.sh
        lib/runtime_tmux.sh
        lib/shell_integration.sh
        lib/tui.sh
        lib/tui_terminal.sh
        lib/tui_render.sh
        share/shell/init.sh
        examples/config.example.json
        THIRD_PARTY_NOTICES.md
        SOURCE-CODE-OFFER.md
    )

    [[ -d "$package_root" && ! -L "$package_root" ]] || return 1
    for required_file in "${required_files[@]}"; do
        path="$package_root/$required_file"
        install_core_safe_file "$path" || {
            install_core_error "missing or unsafe package file: $required_file"
            return 1
        }
    done
    [[ -f "$package_root/../../LICENSE" && ! -L "$package_root/../../LICENSE" ]] || {
        install_core_error 'repository LICENSE is missing'
        return 1
    }
    return 0
}

install_core_validate_release_tree() {
    local release_root=$1
    local version=$2
    local expected_arch=${3:-}
    local required_file=''
    local path=''
    local asset_name=''
    local asset_version=''
    local asset_sha256=''
    local sing_box_version=''
    local gum_version=''
    local expected_sing_version=''
    local expected_gum_version=''

    if [[ -z "$expected_arch" ]]; then
        expected_arch=$(install_core_detect_arch) || return $?
    fi
    local -a required_files=(
        install.sh
        lib/install_core.sh
        VERSION
        manifest.json
        bin/netctl
        bin/sing-box
        bin/gum
        lib/common.sh
        lib/paths.sh
        lib/config_store.sh
        lib/config_meta.sh
        lib/share_uri.sh
        lib/env_profiles.sh
        lib/runtime_tmux.sh
        lib/shell_integration.sh
        lib/tui.sh
        lib/tui_terminal.sh
        lib/tui_render.sh
        share/shell/init.sh
        examples/config.example.json
        THIRD_PARTY_NOTICES.md
        SOURCE-CODE-OFFER.md
        licenses/NETUI-LICENSE
        licenses/sing-box-LICENSE
        licenses/gum-LICENSE
    )

    [[ -d "$release_root" && ! -L "$release_root" ]] || return 1
    for required_file in "${required_files[@]}"; do
        path="$release_root/$required_file"
        install_core_safe_file "$path" || {
            install_core_error "release is missing or contains unsafe file: $required_file"
            return 1
        }
    done
    [[ -x "$release_root/bin/netctl" && -x "$release_root/bin/sing-box" && -x "$release_root/bin/gum" ]] || return 1
    jq -e --arg version "$version" --arg arch "$expected_arch" \
        '.version == $version and .arch == $arch and (.assets | type == "array")' \
        "$release_root/manifest.json" >/dev/null 2>&1 || {
        install_core_error 'release manifest does not match the current version or architecture'
        return 1
    }
    jq -e '.assets | (length == 2 and ((map(.name) | sort) == ["gum", "sing-box"]))' \
        "$release_root/manifest.json" >/dev/null 2>&1 || {
        install_core_error 'release manifest must describe exactly sing-box and gum'
        return 1
    }
    while IFS=$'\t' read -r asset_name asset_version asset_sha256; do
        [[ "$asset_name" == sing-box || "$asset_name" == gum ]] || return 1
        [[ "$asset_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || return 1
        [[ "$asset_sha256" =~ ^[0-9a-f]{64}$ ]] || return 1
    done < <(jq -r '.assets[] | [.name, .version, .sha256] | @tsv' "$release_root/manifest.json")
}

install_core_check_existing_config() {
    local core_path=$1
    local config_home=${XDG_CONFIG_HOME:-$HOME/.config}
    local default_link="$config_home/netui/default.json"

    if [[ -L "$default_link" || -e "$default_link" ]]; then
        [[ -L "$default_link" && -e "$default_link" ]] || {
            install_core_error 'existing default.json is not a valid symlink'
            return 1
        }
        "$core_path" check -c "$default_link" >/dev/null 2>&1 || {
            install_core_error 'new sing-box rejected the existing default configuration'
            return 1
        }
    fi
}

install_core_check_command_links() {
    local link=''
    local expected_root=$1

    install_core_secure_dir "$NETUI_INSTALL_BIN_HOME" || return 1
    for link in netup netdown netui; do
        if [[ -e "$NETUI_INSTALL_BIN_HOME/$link" || -L "$NETUI_INSTALL_BIN_HOME/$link" ]]; then
            [[ -L "$NETUI_INSTALL_BIN_HOME/$link" ]] || {
                install_core_error "refusing to replace regular file: $NETUI_INSTALL_BIN_HOME/$link"
                return 1
            }
            case "$(readlink -f -- "$NETUI_INSTALL_BIN_HOME/$link" 2>/dev/null || true)" in
                "$expected_root/bin/netctl"|*/netui/releases/*/bin/netctl)
                    ;;
                *)
                    install_core_error "refusing to replace unrelated symlink: $NETUI_INSTALL_BIN_HOME/$link"
                    return 1
                    ;;
            esac
        fi
    done
}

install_core_update_command_links() {
    local link=''
    local temporary_link=''
    local target="$NETUI_INSTALL_CURRENT/bin/netctl"

    for link in netup netdown netui; do
        temporary_link="$NETUI_INSTALL_BIN_HOME/.$link.netui.tmp.$$.$RANDOM"
        rm -f -- "$temporary_link"
        ln -s -- "$target" "$temporary_link" || return 1
        mv -Tf -- "$temporary_link" "$NETUI_INSTALL_BIN_HOME/$link" || {
            rm -f -- "$temporary_link"
            return 1
        }
    done
}

install_core_path_block_install() {
    local rc_file=$1
    local start_marker='# >>> netui path integration >>>'
    local end_marker='# <<< netui path integration <<<'
    local block=''

    [[ -f "$rc_file" && ! -L "$rc_file" ]] || return 0
    case ":${PATH:-}:" in
        *":$NETUI_INSTALL_BIN_HOME:"*)
            return 0
            ;;
    esac
    grep -Fqx -- "$start_marker" "$rc_file" 2>/dev/null && return 0
    local escaped_bin_home=''

    escaped_bin_home=$(printf '%q' "$NETUI_INSTALL_BIN_HOME")
    block=$(printf '\n%s\nexport PATH=%s:$PATH\n%s\n' "$start_marker" "$escaped_bin_home" "$end_marker")
    printf '%s' "$block" >> "$rc_file"
}

install_core_path_block_remove() {
    local rc_file=$1
    local start_marker='# >>> netui path integration >>>'
    local end_marker='# <<< netui path integration <<<'
    local temporary_file="$rc_file.netui-path.tmp.$$.$RANDOM"
    local inside_block=0
    local line=''

    [[ -f "$rc_file" && ! -L "$rc_file" ]] || return 0
    grep -Fqx -- "$start_marker" "$rc_file" 2>/dev/null || return 0
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

install_core_initialize_runtime() {
    local package_root=$1

    NETUI_PACKAGE_ROOT=$package_root
    NETUI_SHELL_INIT_PATH="$NETUI_INSTALL_CURRENT/share/shell/init.sh"
    export NETUI_PACKAGE_ROOT NETUI_SHELL_INIT_PATH
    # shellcheck source=./common.sh
    source "$package_root/lib/common.sh"
    # shellcheck source=./paths.sh
    source "$package_root/lib/paths.sh"
    # shellcheck source=./env_profiles.sh
    source "$package_root/lib/env_profiles.sh"
    # shellcheck source=./shell_integration.sh
    source "$package_root/lib/shell_integration.sh"
    netui_init_dirs || return 1
    env_profiles_read_mode || return 1
    env_profiles_set_mode "$env_mode" || return 1
}

install_core_acquire_lock() {
    install_core_user_paths || return 1
    install_core_secure_dir "$NETUI_INSTALL_DATA_HOME" || return 1
    [[ ! -e "$NETUI_INSTALL_LOCK_FILE" || -f "$NETUI_INSTALL_LOCK_FILE" ]] || {
        install_core_error "install lock is not a regular file: $NETUI_INSTALL_LOCK_FILE"
        return 1
    }
    exec {install_core_lock_fd}>"$NETUI_INSTALL_LOCK_FILE" || {
        install_core_error 'cannot open install lock'
        return 1
    }
    chmod 600 -- "$NETUI_INSTALL_LOCK_FILE" || {
        exec {install_core_lock_fd}>&-
        return 1
    }
    if ! flock -w 30 "$install_core_lock_fd"; then
        exec {install_core_lock_fd}>&-
        install_core_error 'install lock timed out'
        return 8
    fi
}

install_core_release_lock() {
    if [[ -n "${install_core_lock_fd:-}" ]]; then
        flock -u "$install_core_lock_fd" 2>/dev/null || true
        exec {install_core_lock_fd}>&-
        unset install_core_lock_fd
    fi
}

install_core_install_release() {
    install_core_acquire_lock || return $?
    local status=0
    install_core_install_release_locked "$@" || status=$?
    install_core_release_lock
    return "$status"
}

install_core_install_release_locked() {
    local release_root=$1
    local version=$2
    local package_root=$3

    install_core_info 'checking runtime dependencies'
    install_core_require_base_dependencies || return $?
    install_core_info 'validating release tree and bundled binaries'
    install_core_validate_release_tree "$release_root" "$version" || return 1
    local final_release=''
    local temporary_release=''
    local current_tmp=''
    local file=''
    local path=''
    local current_resolved=''
    local -a copy_files=(
        install.sh
        lib/install_core.sh
        VERSION
        manifest.json
        README.md
        THIRD_PARTY_NOTICES.md
        SOURCE-CODE-OFFER.md
        bin/netctl
        bin/sing-box
        bin/gum
        lib/common.sh
        lib/paths.sh
        lib/config_store.sh
        lib/config_meta.sh
        lib/share_uri.sh
        lib/env_profiles.sh
        lib/runtime_tmux.sh
        lib/shell_integration.sh
        lib/tui.sh
        lib/tui_terminal.sh
        lib/tui_render.sh
        share/shell/init.sh
        examples/config.example.json
        licenses/NETUI-LICENSE
        licenses/sing-box-LICENSE
        licenses/gum-LICENSE
    )

    install_core_user_paths || return 1
    final_release="$NETUI_INSTALL_RELEASES/$version"
    temporary_release="$NETUI_INSTALL_RELEASES/.$version.tmp.$$.$RANDOM"
    current_tmp="$NETUI_INSTALL_ROOT/.current.tmp.$$.$RANDOM"
    install_core_secure_dir "$NETUI_INSTALL_ROOT" || return 1
    install_core_secure_dir "$NETUI_INSTALL_RELEASES" || return 1
    install_core_info "preparing $final_release"
    install_core_check_command_links "$final_release" || return 1

    if [[ -e "$NETUI_INSTALL_CURRENT" || -L "$NETUI_INSTALL_CURRENT" ]]; then
        [[ -L "$NETUI_INSTALL_CURRENT" ]] || {
            install_core_error 'current is not a symlink'
            return 1
        }
        current_resolved=$(realpath -e -- "$NETUI_INSTALL_CURRENT" 2>/dev/null || true)
        [[ "$current_resolved" == "$NETUI_INSTALL_RELEASES/"* ]] || {
            install_core_error 'current points outside the NetUI releases directory'
            return 1
        }
    fi

    if [[ -e "$final_release" || -L "$final_release" ]]; then
        [[ -d "$final_release" && ! -L "$final_release" ]] || {
            install_core_error "existing release path is unsafe: $version"
            return 1
        }
        install_core_validate_release_tree "$final_release" "$version" || return 1
        path="$final_release"
    else
        mkdir -p -- "$temporary_release" || return 1
        chmod 755 -- "$temporary_release"
        for file in "${copy_files[@]}"; do
            install_core_safe_file "$release_root/$file" || {
                install_core_error "release file disappeared: $file"
                rm -rf -- "$temporary_release"
                return 1
            }
            install_core_secure_parent "$temporary_release/$file" || {
                rm -rf -- "$temporary_release"
                return 1
            }
            if [[ "$file" == bin/* || "$file" == install.sh ]]; then
                install -D -m 755 -- "$release_root/$file" "$temporary_release/$file"
            else
                install -D -m 644 -- "$release_root/$file" "$temporary_release/$file"
            fi
        done
        install_core_validate_release_tree "$temporary_release" "$version" || {
            rm -rf -- "$temporary_release"
            return 1
        }
        mv -T -- "$temporary_release" "$final_release" || {
            rm -rf -- "$temporary_release"
            return 1
        }
        path="$final_release"
    fi

    sing_box_version=$("$path/bin/sing-box" version 2>/dev/null) || {
        install_core_error 'bundled sing-box failed its version check'
        return 1
    }
    gum_version=$("$path/bin/gum" --version 2>/dev/null) || {
        install_core_error 'bundled gum failed its version check'
        return 1
    }
    expected_sing_version=$(jq -r '.assets[] | select(.name == "sing-box") | .version' "$path/manifest.json")
    expected_gum_version=$(jq -r '.assets[] | select(.name == "gum") | .version' "$path/manifest.json")
    [[ "$sing_box_version" == *"$expected_sing_version"* ]] || {
        install_core_error 'bundled sing-box version does not match the release manifest'
        return 1
    }
    [[ "$gum_version" == *"$expected_gum_version"* ]] || {
        install_core_error 'bundled gum version does not match the release manifest'
        return 1
    }
    install_core_info 'validating existing default configuration'
    install_core_check_existing_config "$path/bin/sing-box" || return 1

    install_core_info 'switching current symlink'
    ln -s -- "releases/$version" "$current_tmp" || return 1
    mv -Tf -- "$current_tmp" "$NETUI_INSTALL_CURRENT" || {
        rm -f -- "$current_tmp"
        return 1
    }
    install_core_update_command_links || return 1
    install_core_info 'installing netup/netdown/netui command links'

    install_core_initialize_runtime "$path" || return 1
    install_core_info 'installing automatic Bash/Zsh proxy synchronization'
    shell_integration_install || return 1
    for file in "$HOME/.bashrc" "$HOME/.zshrc"; do
        install_core_path_block_install "$file" || return 1
    done

    install_core_info "installed NetUI $version for linux/$(install_core_detect_arch)"
    install_core_info "commands: $NETUI_INSTALL_BIN_HOME/netup, netdown, netui"
    install_core_info 'netup enables proxy variables automatically; sudo inherits the proxy variables'
    install_core_info 'open a new shell before checking command resolution'
    install_core_info 'completed'
}

install_core_install_from_release() {
    local release_root=$1
    local package_root=$2
    local version=''
    local arch=''

    version=$(install_core_read_version "$release_root") || {
        install_core_error 'release VERSION is missing or invalid'
        return 1
    }
    arch=$(install_core_detect_arch) || return $?
    install_core_require_base_dependencies || return $?
    install_core_validate_release_tree "$release_root" "$version" || return 1
    install_core_install_release "$release_root" "$version" "$package_root"
}

install_core_build_release_tree() {
    local package_root=$1
    local output_root=$2
    local arch=$3
    local asset_dir=$4
    local work_dir=$5
    local version=''
    local sing_archive=''
    local gum_archive=''
    local asset_extract="$work_dir/extract"
    local release_root=''

    version=$(install_core_read_version "$package_root") || return 1
    release_root="$output_root/netui-v$version-linux-$arch"
    install_core_validate_source_tree "$package_root" || return 1
    mkdir -p -- "$release_root/bin" "$release_root/lib" "$release_root/share/shell" "$release_root/examples" "$release_root/licenses" || return 1

    sing_archive=$(install_core_prepare_asset "$package_root" sing-box "$arch" "$asset_dir" "$work_dir/downloads") || return 1
    gum_archive=$(install_core_prepare_asset "$package_root" gum "$arch" "$asset_dir" "$work_dir/downloads") || return 1
    install_core_extract_asset "$sing_archive" sing-box "$release_root/bin/sing-box" "$release_root/licenses/sing-box-LICENSE" "$asset_extract/sing-box" || return 1
    install_core_extract_asset "$gum_archive" gum "$release_root/bin/gum" "$release_root/licenses/gum-LICENSE" "$asset_extract/gum" || return 1

    install -D -m 755 -- "$package_root/install.sh" "$release_root/install.sh"
    install -D -m 755 -- "$package_root/lib/install_core.sh" "$release_root/lib/install_core.sh"
    install -D -m 644 -- "$package_root/VERSION" "$release_root/VERSION"
    install -D -m 644 -- "$package_root/README.md" "$release_root/README.md"
    install -D -m 644 -- "$package_root/THIRD_PARTY_NOTICES.md" "$release_root/THIRD_PARTY_NOTICES.md"
    install -D -m 644 -- "$package_root/SOURCE-CODE-OFFER.md" "$release_root/SOURCE-CODE-OFFER.md"
    install -D -m 644 -- "$package_root/../../LICENSE" "$release_root/licenses/NETUI-LICENSE"
    install -D -m 644 -- "$package_root/examples/config.example.json" "$release_root/examples/config.example.json"
    for path in "$package_root/bin/netctl" "$package_root/lib/common.sh" "$package_root/lib/paths.sh" \
        "$package_root/lib/config_store.sh" "$package_root/lib/config_meta.sh" "$package_root/lib/share_uri.sh" \
        "$package_root/lib/env_profiles.sh" "$package_root/lib/runtime_tmux.sh" \
        "$package_root/lib/shell_integration.sh" "$package_root/lib/tui.sh" \
        "$package_root/lib/tui_terminal.sh" "$package_root/lib/tui_render.sh" \
        "$package_root/share/shell/init.sh"; do
        file=${path#"$package_root/"}
        if [[ "$file" == bin/* || "$file" == share/shell/* ]]; then
            install -D -m 755 -- "$path" "$release_root/$file"
        else
            install -D -m 755 -- "$path" "$release_root/$file"
        fi
    done
    printf '%s\n' "$(jq -cn --arg version "$version" --arg arch "$arch" \
        --arg sing_version "$(install_core_manifest_row "$package_root" sing-box "$arch" && printf '%s' "$install_core_asset_version")" \
        --arg gum_version "$(install_core_manifest_row "$package_root" gum "$arch" && printf '%s' "$install_core_asset_version")" \
        --arg sing_sha "$(install_core_manifest_row "$package_root" sing-box "$arch" && printf '%s' "$install_core_asset_sha256")" \
        --arg gum_sha "$(install_core_manifest_row "$package_root" gum "$arch" && printf '%s' "$install_core_asset_sha256")" \
        '{schema:1,project:"netui",version:$version,os:"linux",arch:$arch,assets:[{name:"sing-box",version:$sing_version,sha256:$sing_sha},{name:"gum",version:$gum_version,sha256:$gum_sha}]}' )" \
        > "$release_root/manifest.json"
    chmod 644 -- "$release_root/manifest.json"
    install_core_validate_release_tree "$release_root" "$version" "$arch"
}

install_core_uninstall_locked() {
    local purge=${1:-0}
    local confirm_yes=${2:-0}
    local current_root=''
    local link=''
    local release_root=''
    local config_root=''
    local state_root=''
    local root=''
    local answer=''

    install_core_require_base_dependencies || return $?
    install_core_user_paths || return 1
    [[ "$purge" == 0 || "$purge" == 1 ]] || return 2
    install_core_secure_dir "$NETUI_INSTALL_BIN_HOME" || return 1

    if [[ -L "$NETUI_INSTALL_CURRENT" ]]; then
        current_root=$(realpath -e -- "$NETUI_INSTALL_CURRENT" 2>/dev/null || true)
        [[ "$current_root" == "$NETUI_INSTALL_RELEASES/"* ]] || {
            install_core_error 'current points outside the NetUI releases directory; refusing uninstall'
            return 1
        }
        if [[ -x "$NETUI_INSTALL_CURRENT/bin/netctl" ]]; then
            "$NETUI_INSTALL_CURRENT/bin/netctl" netdown >/dev/null 2>&1 || true
        fi
        NETUI_PACKAGE_ROOT=$current_root
        NETUI_SHELL_INIT_PATH="$NETUI_INSTALL_CURRENT/share/shell/init.sh"
        export NETUI_PACKAGE_ROOT NETUI_SHELL_INIT_PATH
        # shellcheck source=./common.sh
        source "$current_root/lib/common.sh"
        # shellcheck source=./paths.sh
        source "$current_root/lib/paths.sh"
        # shellcheck source=./shell_integration.sh
        source "$current_root/lib/shell_integration.sh"
        netui_init_dirs >/dev/null 2>&1 || true
        shell_integration_remove >/dev/null 2>&1 || true
    fi

    for link in netup netdown netui; do
        if [[ -L "$NETUI_INSTALL_BIN_HOME/$link" ]]; then
            case "$(readlink -f -- "$NETUI_INSTALL_BIN_HOME/$link" 2>/dev/null || true)" in
                "$NETUI_INSTALL_RELEASES/"*/bin/netctl)
                    rm -f -- "$NETUI_INSTALL_BIN_HOME/$link"
                    ;;
                *)
                    install_core_error "leaving unrelated symlink: $NETUI_INSTALL_BIN_HOME/$link"
                    ;;
            esac
        elif [[ -e "$NETUI_INSTALL_BIN_HOME/$link" ]]; then
            install_core_error "leaving regular file: $NETUI_INSTALL_BIN_HOME/$link"
        fi
    done

    for link in "$HOME/.bashrc" "$HOME/.zshrc"; do
        install_core_path_block_remove "$link" || return 1
    done

    [[ "$NETUI_INSTALL_ROOT" == "$NETUI_INSTALL_DATA_HOME/netui" && "$NETUI_INSTALL_ROOT" != / && -n "$NETUI_INSTALL_ROOT" ]] || return 1
    if [[ -e "$NETUI_INSTALL_ROOT" || -L "$NETUI_INSTALL_ROOT" ]]; then
        [[ ! -L "$NETUI_INSTALL_ROOT" && -d "$NETUI_INSTALL_ROOT" ]] || {
            install_core_error 'NetUI install root is not a private directory'
            return 1
        }
        rm -rf -- "$NETUI_INSTALL_CURRENT" "$NETUI_INSTALL_RELEASES"
        rmdir -- "$NETUI_INSTALL_ROOT" 2>/dev/null || true
    fi

    if ((purge)); then
        if ((confirm_yes == 0)); then
            if [[ ! -t 0 || ! -t 1 ]]; then
                install_core_error '--purge requires --yes in a non-interactive shell'
                return 2
            fi
            printf 'Delete NetUI config and state under %s and %s? [y/N] ' \
                "$NETUI_INSTALL_CONFIG_HOME/netui" "$NETUI_INSTALL_STATE_HOME/netui"
            read -r answer || answer=''
            [[ "$answer" == y || "$answer" == Y ]] || {
                install_core_info 'purge cancelled; config and state were kept'
                return 0
            }
        fi
        config_root="$NETUI_INSTALL_CONFIG_HOME/netui"
        state_root="$NETUI_INSTALL_STATE_HOME/netui"
        [[ "$config_root" == "$NETUI_INSTALL_CONFIG_HOME/netui" && "$state_root" == "$NETUI_INSTALL_STATE_HOME/netui" ]] || return 1
        [[ "$config_root" != / && "$state_root" != / ]] || return 1
        for root in "$config_root" "$state_root"; do
            if [[ -e "$root" || -L "$root" ]]; then
                [[ -d "$root" && ! -L "$root" ]] || {
                    install_core_error "refusing to purge unsafe path: $root"
                    return 1
                }
            fi
        done
        rm -rf -- "$config_root" "$state_root"
    fi
    install_core_info 'NetUI programs removed; configuration and state were preserved unless --purge was confirmed'
}

install_core_uninstall() {
    install_core_acquire_lock || return $?
    local status=0
    install_core_uninstall_locked "$@" || status=$?
    install_core_release_lock
    return "$status"
}
