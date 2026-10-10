#!/bin/bash

# add_claude_user.sh —— 让机器上多个 Linux 用户共用同一个 Claude Code 登录。
#
# 做法:目标用户敲 claude 时经 sudo 切到"登录持有者"(默认 winbeau)身份运行,
#       但把环境变量对齐回目标用户,登录态经 ~/.claude 目录软链共享。
# 新建用户会:设默认密码(默认=用户名,CLAUDE_USER_PASSWORD 可覆盖)、加入 sudo 组、并复用 FluxEnv 的 zsh + starship(全线上)。
# 详见 docs/CLAUDE_SHARED_LOGIN.md。
#
# 用法:
#   sudo bash scripts/add_claude_user.sh dev3            # 新增/幂等接入 dev3
#   sudo bash scripts/add_claude_user.sh dev3 cleanup    # 仅移除 dev3(公共基建保留)
#   sudo CLAUDE_LOGIN_USER=alice bash scripts/add_claude_user.sh dev3   # 指定登录持有者
#   sudo CLAUDE_USER_PASSWORD=xxx bash scripts/add_claude_user.sh dev3  # 指定初始密码
#   sudo CLAUDE_USER_SUDO=0 bash scripts/add_claude_user.sh dev3        # 不加入 sudo 组

set -euo pipefail

LOGIN_USER="${CLAUDE_LOGIN_USER:-winbeau}"
SHARE_GROUP="${CLAUDE_SHARE_GROUP:-claudeshare}"
USER_SUDO="${CLAUDE_USER_SUDO:-1}"           # 新建用户是否加入 sudo 组(1=是)
REAL_CLAUDE="/home/${LOGIN_USER}/.local/bin/claude"
WRAPPER="/usr/local/bin/claude"
HELPER="/usr/local/bin/claude-bridge"
SUDOERS="/etc/sudoers.d/claude-share"
FLUXENV_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

NEW_USER="${1:-}"
ACTION="${2:-install}"
USER_PASSWORD="${CLAUDE_USER_PASSWORD:-$NEW_USER}"   # 默认密码=用户名(仅供本地 sudo/su;SSH 密码登录建议关闭)

log()  { printf '  %s\n' "$*"; }
stage() { printf '\n=== %s ===\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ]          || die "请用 sudo/root 运行"
[ -n "$NEW_USER" ]            || die "用法: sudo bash $0 <用户名> [cleanup]"
[ "$NEW_USER" != "$LOGIN_USER" ] || die "不能对登录持有者 $LOGIN_USER 自己操作"

# ---------------- cleanup ----------------
if [ "$ACTION" = "cleanup" ]; then
    stage "移除 $NEW_USER"
    if [ -L "/home/$NEW_USER/.claude" ]; then
        rm -f "/home/$NEW_USER/.claude"
        log "删 .claude 软链"
    fi
    rm -f "/home/$NEW_USER/.claude.json"
    rm -f "/etc/ssh/authorized_keys/$NEW_USER" && log "清 SSH 公钥 /etc/ssh/authorized_keys/$NEW_USER"
    if id "$NEW_USER" &>/dev/null; then
        userdel -r "$NEW_USER" 2>/dev/null && log "删用户 $NEW_USER(含家目录)"
    fi
    log "公共基建(组/wrapper/helper/sudoers)保留"
    exit 0
fi

[ -e "$REAL_CLAUDE" ] || die "登录持有者 $LOGIN_USER 的 claude 未找到于 $REAL_CLAUDE(先让它装好并 /login)"

install_sudoers() {
    # 先 visudo 校验再落盘,校验失败绝不碰真文件
    local tmp; tmp="$(mktemp)"
    printf '%%%s ALL=(%s) NOPASSWD:SETENV: %s, %s, %s\n' \
        "$SHARE_GROUP" "$LOGIN_USER" "$HELPER" "$REAL_CLAUDE" "$WRAPPER" > "$tmp"
    if visudo -cf "$tmp"; then
        install -m 440 -o root -g root "$tmp" "$SUDOERS"
        rm -f "$tmp"
    else
        rm -f "$tmp"
        die "sudoers 校验失败,未改动"
    fi
}

# FluxEnv 的 .zshrc 用 sudo 建 XDG_RUNTIME_DIR,假设用户有 sudo 且处于 logind 会话;
# 经 su/sudo su 进来的用户没有 logind 会话 → 那段会报错或每次开 shell 弹密码。
# 这里把它替换成无特权回退(回退到 /tmp),避免打扰。缺 python3 则跳过(非致命)。
patch_zshrc_xdg() {
    local zshrc="$1"
    [ -f "$zshrc" ] || return 0
    command -v python3 >/dev/null || { log "无 python3,跳过 .zshrc XDG 段修补(非致命)"; return 0; }
    python3 - "$zshrc" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = '''    if [ ! -d "$XDG_RUNTIME_DIR" ]; then
        sudo mkdir -p "$XDG_RUNTIME_DIR"
        sudo chown $(whoami):$(whoami) "$XDG_RUNTIME_DIR"
        sudo chmod 700 "$XDG_RUNTIME_DIR"
    fi'''
new = '''    if [ ! -d "$XDG_RUNTIME_DIR" ]; then
        export XDG_RUNTIME_DIR="${TMPDIR:-/tmp}/runtime-$(id -u)"
        mkdir -m 700 -p "$XDG_RUNTIME_DIR" 2>/dev/null || true
    fi'''
if old in s:
    open(p, "w").write(s.replace(old, new))
PY
}

# 复用 FluxEnv 的 zsh + starship 配置,强制全线上(不碰 offline_resources/)。
# 在子 shell 里加载 lib,避免其 stage/die 等同名函数污染本脚本。
configure_zsh_starship() {
    local user="$1"
    local user_home="$2"
    local lib="$FLUXENV_ROOT/lib/steps/user_shell.sh"

    if [ ! -f "$lib" ]; then
        log "未找到 FluxEnv lib($lib);跳过 zsh/starship(claude 桥接不受影响)"
        return 0
    fi
    command -v zsh >/dev/null || { apt-get update -qq && apt-get install -y -qq zsh; }

    env FLUXENV_ROOT="$FLUXENV_ROOT" FLUXENV_SHELL_USER="$user" FLUXENV_SHELL_HOME="$user_home" /bin/bash <<'SHELL_SETUP'
        set -euo pipefail
        user="$FLUXENV_SHELL_USER"
        user_home="$FLUXENV_SHELL_HOME"
        source "$FLUXENV_ROOT/lib/core.sh"
        source "$FLUXENV_ROOT/lib/config.sh"
        source "$FLUXENV_ROOT/lib/state.sh"
        source "$FLUXENV_ROOT/lib/managed.sh"
        source "$FLUXENV_ROOT/lib/steps/user_shell.sh"
        init_colors
        load_defaults "$FLUXENV_ROOT"
        OFFLINE_DIR="$(mktemp -d)"               # 空目录 → 绕过所有离线资源
        ALLOW_ONLINE_FETCH=1                     # 全线上:starship 走 starship.rs,插件走 git clone
        HOST_NAME="$(hostname 2>/dev/null || echo host)"
        TARGET_USER="$user"
        UV_TOOL_BIN="$user_home/.local/bin"
        state_open "/var/lib/fluxenv/user-shell/$user" "user-shell/$user"
        state_begin
        install_starship || die "Starship 安装失败"
        configure_shell_env_for_user "$user" "$user_home"
        state_finish
        rmdir "$OFFLINE_DIR" 2>/dev/null || true
SHELL_SETUP
    patch_zshrc_xdg "$user_home/.zshrc"
}

printf '########## 公共基建(幂等) ##########\n'

stage "[1] acl 工具"
command -v setfacl >/dev/null || { apt-get update -qq && apt-get install -y -qq acl; }
command -v setfacl >/dev/null || die "acl 安装失败"

stage "[2] 共享组 $SHARE_GROUP + 登录持有者 $LOGIN_USER 入组"
getent group "$SHARE_GROUP" >/dev/null || groupadd "$SHARE_GROUP"
usermod -aG "$SHARE_GROUP" "$LOGIN_USER"

stage "[3] helper $HELPER(以 $LOGIN_USER 跑,但环境对齐回调用者)"
cat > "$HELPER" <<EOF
#!/bin/sh
# 由 sudo 以 $LOGIN_USER 身份调用;把 HOME/USER/.. 钉回真实调用者(\$SUDO_USER),
# 清掉 sudo 留下的 SUDO_*,使 claude 的运行环境与"原生调用者的 claude"一致。
RU="\${SUDO_USER:-$LOGIN_USER}"
if [ "\$RU" != "$LOGIN_USER" ] && [ -L "/home/\$RU/.claude" ]; then
    [ -n "\${BRIDGE_PATH:-}" ] && PATH="\$BRIDGE_PATH"
    HOME="/home/\$RU"; USER="\$RU"; LOGNAME="\$RU"; MAIL="/var/mail/\$RU"
    export PATH HOME USER LOGNAME MAIL
    # 消除因 HOME=调用者 引起的假"安装损坏"自检(claude 内部标志,不碰 git/ssh/hf)
    export DISABLE_INSTALLATION_CHECKS=1
else
    HOME="/home/$LOGIN_USER"; export HOME
fi
unset SUDO_USER SUDO_UID SUDO_GID SUDO_COMMAND SUDO_PS1 BRIDGE_PATH
[ "\${1:-}" = "__envdump__" ] && exec env
exec "$REAL_CLAUDE" "\$@"
EOF
chmod 755 "$HELPER"

stage "[4] wrapper $WRAPPER($LOGIN_USER 直跑;他人 sudo 切过去并带过原生环境)"
cat > "$WRAPPER" <<EOF
#!/bin/sh
if [ "\$(id -un)" = "$LOGIN_USER" ]; then exec "$REAL_CLAUDE" "\$@"; fi
exec sudo -u $LOGIN_USER --preserve-env "BRIDGE_PATH=\$PATH" "$HELPER" "\$@"
EOF
chmod 755 "$WRAPPER"

stage "[5] sudoers(组级 + SETENV + NOPASSWD;仅放行 claude)"
install_sudoers
log "规则: $(cat "$SUDOERS")"

printf '\n########## 用户 %s ##########\n' "$NEW_USER"

stage "[6] 建用户 + 密码 + 入组"
if id "$NEW_USER" &>/dev/null; then
    user_created=0
else
    useradd -m -s /bin/bash "$NEW_USER"
    user_created=1
fi
usermod -aG "$SHARE_GROUP" "$NEW_USER"
if [ "$USER_SUDO" -eq 1 ]; then
    usermod -aG sudo "$NEW_USER"
fi
if [ "$user_created" -eq 1 ]; then
    printf '%s:%s\n' "$NEW_USER" "$USER_PASSWORD" | chpasswd
    log "已设默认密码($USER_PASSWORD)"
else
    log "用户已存在,未改动密码"
fi
log "组: $(id -nG "$NEW_USER")"

stage "[7] zsh + starship(复用 FluxEnv 配置,全线上)"
configure_zsh_starship "$NEW_USER" "/home/$NEW_USER" \
    || log "zsh/starship 配置有部分失败,已跳过(不影响 claude 桥接)"

stage "[8] 开放 /home/$NEW_USER 给 $SHARE_GROUP(claude 任意目录可读写)"
setfacl -R -m  "g:${SHARE_GROUP}:rwx" "/home/$NEW_USER"
setfacl -R -dm "g:${SHARE_GROUP}:rwx" "/home/$NEW_USER"

stage "[9] 保护 .ssh(避免组权限触发 ssh StrictModes 拒绝私钥)"
mkdir -p "/home/$NEW_USER/.ssh"
setfacl -Rb "/home/$NEW_USER/.ssh"
setfacl -db "/home/$NEW_USER/.ssh"
chmod 700 "/home/$NEW_USER/.ssh"
chown -R "$NEW_USER":"$NEW_USER" "/home/$NEW_USER/.ssh"

stage "[10] .claude 目录软链 → $LOGIN_USER 的(共享登录;目录软链抗原子 rename)"
dot_claude="/home/$NEW_USER/.claude"
if [ -L "$dot_claude" ]; then
    ln -sfn "/home/$LOGIN_USER/.claude" "$dot_claude"
elif [ -e "$dot_claude" ]; then
    mv "$dot_claude" "${dot_claude}.bak.$(date +%s)"
    ln -s "/home/$LOGIN_USER/.claude" "$dot_claude"
else
    ln -s "/home/$LOGIN_USER/.claude" "$dot_claude"
fi
chown -h "$NEW_USER":"$NEW_USER" "$dot_claude" 2>/dev/null || true

stage "[11] .claude.json 拷贝(HOME 根文件,原子写不能软链;不含 token)"
dot_json="/home/$NEW_USER/.claude.json"
if [ -e "$dot_json" ] && [ ! -L "$dot_json" ]; then
    log "已存在,保留 $NEW_USER 自己的"
elif [ -f "/home/$LOGIN_USER/.claude.json" ]; then
    rm -f "$dot_json"
    cp "/home/$LOGIN_USER/.claude.json" "$dot_json"
    chown "$NEW_USER":"$SHARE_GROUP" "$dot_json"
    chmod 660 "$dot_json"
    log "已拷贝"
else
    log "$LOGIN_USER 无 .claude.json,跳过(claude 首跑会自建)"
fi

stage "[12] 自测:环境对齐 + 真跑"
# DISABLE_INSTALLATION_CHECKS 是有意注入的 claude 内部标志,比对时排除
env_filter='^(SUDO_[A-Z]*|_|SHLVL|PWD|OLDPWD|BRIDGE_PATH|DISABLE_INSTALLATION_CHECKS)='
native_env="$(mktemp)"; bridge_env="$(mktemp)"
sudo -u "$NEW_USER" bash -c 'env' 2>/dev/null | grep -vE "$env_filter" | sort > "$native_env" || true
sudo -u "$NEW_USER" bash -c \
    "sudo -n -u $LOGIN_USER --preserve-env \"BRIDGE_PATH=\$PATH\" $HELPER __envdump__" \
    2>/dev/null | grep -vE "$env_filter" | sort > "$bridge_env" || true
if diff -q "$native_env" "$bridge_env" >/dev/null; then
    log "✅ 环境变量与原生 $NEW_USER 一致(仅多注入 DISABLE_INSTALLATION_CHECKS,已知/有意)"
else
    log "⚠ env 差异:"
    diff -u "$native_env" "$bridge_env" | grep -E '^[+-]' | grep -vE '^[+-]{3}' | sed 's/^/    /'
fi
rm -f "$native_env" "$bridge_env"
printf '  真跑(借 %s 登录): ' "$LOGIN_USER"
sudo -u "$NEW_USER" -H bash -c "cd /home/$NEW_USER && timeout 90 claude -p 'reply with exactly: ok'" 2>/dev/null \
    || echo "(超时/需手动确认信任目录,不影响 env 结论)"

stage "完成"
log "登录:su - $NEW_USER(或设了密码后直接登录,默认 $USER_PASSWORD),shell 为 zsh + starship"
log "使用:任意目录敲 claude 即用 $LOGIN_USER 的登录;\$HOME/\$USER 等环境为原生 $NEW_USER"
log "移除: sudo bash $0 $NEW_USER cleanup"
