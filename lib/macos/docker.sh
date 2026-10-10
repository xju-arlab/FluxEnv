#!/bin/bash

macos_docker_formula_ready() {
    case "$1" in
        docker) "$BREW_PREFIX/bin/docker" --version >/dev/null 2>&1 ;;
        colima) "$BREW_PREFIX/bin/colima" version >/dev/null 2>&1 ;;
        docker-compose|docker-buildx) "$BREW_PREFIX/lib/docker/cli-plugins/$1" version >/dev/null 2>&1 ;;
    esac
}

macos_docker_plugin() {
    local name="$1"
    local formula="docker-$name"
    local destination="$MACOS_DOCKER_CONFIG_DIR/cli-plugins/$formula"
    local source="$BREW_PREFIX/lib/docker/cli-plugins/$formula"
    if "$DOCKER_BIN" "$name" version >/dev/null 2>&1; then
        state_record "docker-plugin/$name" reused
        return 0
    fi
    macos_ensure_formulae "Docker $name" macos_docker_formula_ready "$formula"
    if [ "$DRY_RUN" -eq 1 ]; then
        progress "[dry-run] 注册 Docker $name 插件: $destination"
        return 0
    fi
    if [ -e "$destination" ] || [ -L "$destination" ]; then
        [ -L "$destination" ] && [ "$(readlink "$destination")" = "$source" ] ||
            die "已有 Docker 插件无法运行，请检查: $destination"
    else
        mkdir -p "$(dirname "$destination")"
        ln -s "$source" "$destination"
    fi
    "$DOCKER_BIN" "$name" version >/dev/null 2>&1 || die "Docker $name 插件注册失败"
    state_record "docker-plugin/$name" applied
}

step_macos_docker() {
    stage "Docker / Colima"
    if ! macos_choose_optional ENABLE_DOCKER docker "是否安装 Docker（CLI、Compose、Buildx 和 Colima）？"; then
        progress "跳过 Docker；可用 --with-docker 安装"
        return 0
    fi
    [[ "$MACOS_DOCKER_CONFIG_DIR" = /* ]] || die "Docker 配置目录必须是绝对路径"
    export DOCKER_CONFIG="$MACOS_DOCKER_CONFIG_DIR"
    DOCKER_BIN="$(command -v docker || true)"
    if [ -z "$DOCKER_BIN" ] || ! "$DOCKER_BIN" --version >/dev/null 2>&1; then
        macos_ensure_formulae "Docker CLI" macos_docker_formula_ready docker
        DOCKER_BIN="$BREW_PREFIX/bin/docker"
    else
        state_record tools/docker-cli reused
    fi
    macos_docker_plugin compose
    macos_docker_plugin buildx
    if "$DOCKER_BIN" info >/dev/null 2>&1; then
        progress "复用当前 Docker 引擎和 context"
        state_record tools/docker-engine reused
        return 0
    fi
    local context=""
    context="$("$DOCKER_BIN" context show 2>/dev/null || true)"
    if [ -n "${DOCKER_HOST:-}" ] || [ -n "${DOCKER_CONTEXT:-}" ]; then
        die "指定的 Docker 引擎不可用，请检查 DOCKER_HOST / DOCKER_CONTEXT 后重试"
    fi
    case "$context" in
        ""|default|colima) ;;
        *) die "当前 Docker context ($context) 不可用，请先启动对应引擎；已有 context 保留" ;;
    esac
    macos_ensure_formulae "Colima" macos_docker_formula_ready colima
    STATE_CURRENT_RESOURCE=tools/docker-engine
    run_cmd "启动 Colima Docker 引擎" "$BREW_PREFIX/bin/colima" start
    [ "$DRY_RUN" -eq 0 ] || return 0
    "$DOCKER_BIN" info >/dev/null 2>&1 || die "Colima 已启动但 Docker 不可用，请检查 colima status"
    state_record tools/docker-engine applied
    progress "Docker 已就绪；使用 colima stop / colima start 管理引擎"
}
