# FluxEnv

![Shell](https://img.shields.io/badge/Shell-Bash-4EAA25?logo=gnubash&logoColor=white)
![Platform](https://img.shields.io/badge/Platform-Ubuntu%20%7C%20Debian%20%7C%20WSL-blue)
![Mode](https://img.shields.io/badge/Mode-Offline--first-brightgreen)

FluxEnv 是一个基于 Bash 的环境初始化工具，面向 WSL、Ubuntu / Debian 宿主机、AutoDL 容器用户环境，以及 root-only 容器环境。

## NetUI 代理配置

使用 GitCode Release 中经过校验的 NetUI v0.2.4 固定版本安装器：

```bash
curl -fsSL 'https://gitcode.com/winbeau/FluxEnv/releases/download/v0.2.4/install-v0.2.4.sh' | sh
```

首次安装后重新登录 SSH。`netup` 自动设置当前终端的代理环境，Git 直接继承，无需手动 `export` 或另配 `git config`。

### 容器中节点 DNS 超时

v0.2.4 修复了分享链接导入模板的网卡绑定设置。旧版生成的 `auto_detect_interface: true` 会把出站连接绑定到默认网卡，可能导致容器内网 DNS 超时，表现为代理启动成功、Git/curl 却握手失败。v0.2.4 新导入的节点使用系统路由；升级会保留已有 JSON，旧节点可重新导入，或选为默认后复制以下命令修复。命令只处理本地 HTTP/SOCKS 配置，校验并备份后重启：

```bash
bash <<'NETUI_ROUTE_FIX' && netdown && netup
    set -eu
    umask 077
    netui_config=$(realpath -e "${XDG_CONFIG_HOME:-$HOME/.config}/netui/default.json")
    netui_stage=$(mktemp "${netui_config%/*}/.netui-route.XXXXXX")
    trap 'rm -f -- "$netui_stage"' EXIT
    jq -e 'if (.inbounds | length) > 0 and
        all(.inbounds[]; .type == "mixed" or .type == "http" or .type == "socks")
        then del(.route.auto_detect_interface)
        else error("此修复只适用于 HTTP/SOCKS 代理配置") end' \
        "$netui_config" > "$netui_stage"
    "${XDG_DATA_HOME:-$HOME/.local/share}/netui/current/bin/sing-box" check -c "$netui_stage"
    netui_backup=$(mktemp "${netui_config}.bak.XXXXXX")
    cp -- "$netui_config" "$netui_backup"
    mv -Tf -- "$netui_stage" "$netui_config"
    printf '原配置已备份到：%s\n' "$netui_backup"
NETUI_ROUTE_FIX
```

在 cannlab 实测，同一内网 DNS 查询不绑定网卡约 1 ms 返回，绑定 eth0 后超时；移除该设置后 Hysteria2 和 VLESS WebSocket 均恢复。设置语义见 [sing-box 官方文档](https://sing-box.sagernet.org/configuration/route/#auto_detect_interface)。

### Git 克隆停在传输阶段

如果 DNS 和 TLS 已正常、`git ls-remote` 成功，但完整克隆仍长时间停顿，可让 GitHub 请求使用 HTTP/1.1。cannlab 的 Git 2.25.1 / curl 7.68.0 与当前代理链路实测：HTTP/2 收到 200 后传输停顿，HTTP/1.1 约 8 秒完成同一仓库克隆。以下设置只针对 GitHub，不固定代理端口：

```bash
git config --global http.https://github.com/.version HTTP/1.1
```

curl 遇到相同的传输停顿时，可在该次命令加 `--http1.1`。协议选项说明见 [Git 官方文档](https://git-scm.com/docs/git-config#Documentation/git-config.txt-httpversion)。

### IPv6 或节点 DNS 超时

若出现 `gnutls_handshake() failed`，先在 `netui` 中换节点并重启，再检查 HTTPS 请求和代理日志：

```bash
curl -fsS --connect-timeout 10 --max-time 20 -o /dev/null \
    -w 'HTTP=%{http_code} total=%{time_total}\n' https://github.com/
tail -n 30 "${XDG_STATE_HOME:-$HOME/.local/state}/netui/logs/sing-box.log"
```

如果日志包含节点域名的 `lookup ... i/o timeout`、`exchange6` 或 AAAA 查询超时，可给当前默认配置中的 Hysteria2 / VLESS 公网域名节点指定 DNS，并只查询 IPv4。以下命令使用 `223.5.5.5`，要求它能从当前容器或主机直接访问；请先在 `netui` 中选中需要修复的默认节点。命令会合并 DNS 配置、校验、备份原文件，成功后重启代理：

```bash
bash <<'NETUI_DNS_FIX' && netdown && netup
    set -eu
    umask 077
    netui_config=$(realpath -e "${XDG_CONFIG_HOME:-$HOME/.config}/netui/default.json")
    netui_stage=$(mktemp "${netui_config%/*}/.netui-dns.XXXXXX")
    trap 'rm -f -- "$netui_stage"' EXIT
    jq '
        def domain_proxy:
            (.type == "hysteria2" or .type == "vless")
            and (.server | type == "string")
            and (.server | test(":|^[0-9.]+$") | not);
        if any(.outbounds[]?; domain_proxy) then
            .dns.servers = ((.dns.servers // [])
                | map(select(.tag != "netui-bootstrap-ipv4"))
                + [{type: "udp", tag: "netui-bootstrap-ipv4", server: "223.5.5.5"}])
            | .route.default_domain_resolver //=
                {server: "netui-bootstrap-ipv4", strategy: "ipv4_only"}
            | .outbounds |= map(if domain_proxy then
                .domain_resolver = ((if (.domain_resolver | type) == "object"
                    then .domain_resolver else {} end)
                    + {server: "netui-bootstrap-ipv4", strategy: "ipv4_only"})
                else . end)
        else error("当前配置没有使用域名的 Hysteria2 / VLESS 节点") end
    ' "$netui_config" > "$netui_stage"
    "${XDG_DATA_HOME:-$HOME/.local/share}/netui/current/bin/sing-box" check -c "$netui_stage"
    netui_backup=$(mktemp "${netui_config}.bak.XXXXXX")
    cp -- "$netui_config" "$netui_backup"
    mv -Tf -- "$netui_stage" "$netui_config"
    printf '原配置已备份到：%s\n' "$netui_backup"
NETUI_DNS_FIX
```

`ipv4_only` 避免代理节点的 AAAA 查询及 IPv6 连接等待。`curl -4` 只控制 curl 自身的连接，不能替代代理进程中的节点 DNS 设置。DNS 字段说明见 [sing-box 官方文档](https://sing-box.sagernet.org/configuration/shared/dial/#domain_resolver)，NetUI 用法见 [`packages/netui/README.md`](packages/netui/README.md)。

## 入口脚本

- `scripts/fluxenv`：统一初始化入口
- `scripts/fetch_resources.sh`：离线资源抓取入口
- `scripts/add_claude_user.sh`：让多个 Linux 用户共用同一个 Claude Code 登录（详见 `docs/CLAUDE_SHARED_LOGIN.md`）
- `scripts/add_ssh_key.sh`：给用户加 SSH 公钥登录并打印客户端 ssh config（配合上面的共享用户，详见同文档）
- `scripts/add_user.sh`：用仓库模板（`zshrc.txt` + bare-metal Starship 配置 + 离线插件/二进制）交互式创建新用户（zsh + Starship + sudo/docker 组 + SSH 目录）
- `scripts/ssh_disable_password.sh`：关闭 SSH 密码登录只留公钥（公网加固，带防锁死检查）
- `scripts/setup_reality.sh`：在 VPS 上一键部署 VLESS+Vision+REALITY 代理并产出 v2rayN 链接（详见 `docs/REALITY_PROXY.md`）
- `scripts/deploy-cisco.sh`：一键部署 ISRC Cisco AnyConnect VPN（openconnect + systemd 服务 + `ciscoup` 命令，详见下方「ISRC Cisco VPN」）

## 仓库结构

- `lib/`：公共运行时、配置加载和各阶段安装逻辑
- `config/`：内置 profile、示例配置和资源清单
- `offline_resources/`：安装时使用的离线资源
- `docs/`：补充说明文档

## 使用方法

先进入仓库目录：

```bash
cd /path/to/FluxEnv
```

如需先准备离线资源：

```bash
./scripts/fetch_resources.sh
```

默认 profile 为 `normal`。如果不传 `--profile`，脚本会按非 WSL 宿主机模式执行。

### 1. `standard` WSL 模式

仅支持 WSL 环境；非 WSL 宿主机请使用 `normal`。

普通用户通过 `sudo` 启动：

```bash
cd /path/to/FluxEnv
sudo ./scripts/fluxenv --profile standard
```

这种方式会复用当前 `sudo` 用户，不会新建用户。

纯 root 会话启动：

```bash
cd /path/to/FluxEnv
./scripts/fluxenv --profile standard
```

这种方式会进入新建用户流程。

### 2. `normal` 宿主机模式

适用于非 WSL 的 Ubuntu / Debian 宿主机：

```bash
cd /path/to/FluxEnv
sudo ./scripts/fluxenv --profile normal
```

如需保留当前 apt 源、不执行默认镜像切换：

```bash
cd /path/to/FluxEnv
sudo ./scripts/fluxenv --profile normal --no-apt-mirror
```

普通用户通过 `sudo` 启动时，会复用当前 `sudo` 用户：

```bash
cd /path/to/FluxEnv
sudo ./scripts/fluxenv --profile normal
```

纯 root 会话启动时，会进入新建用户流程：

```bash
cd /path/to/FluxEnv
./scripts/fluxenv --profile normal
```

### 3. `autodl` 模式

适用于 AutoDL 和容器环境，会根据启动上下文自动判定目标用户：

```bash
cd /path/to/FluxEnv
sudo ./scripts/fluxenv --profile autodl
```

普通用户通过 `sudo` 启动时，会复用当前用户：

```bash
cd /path/to/FluxEnv
sudo ./scripts/fluxenv --profile autodl
```

纯 root 会话启动时，会继续配置 `root`：

```bash
cd /path/to/FluxEnv
./scripts/fluxenv --profile autodl
```

如需指定配置文件并关闭交互：

```bash
cd /path/to/FluxEnv
sudo ./scripts/fluxenv --profile normal --config ./config/example.env --non-interactive
```

查看帮助：

```bash
./scripts/fluxenv --help
```

跳过默认 apt 换源：

```bash
sudo ./scripts/fluxenv --profile normal --no-apt-mirror
```

## 常用环境准备

初始化流程会尝试将 `uv` 安装到 `/usr/local/bin`，供 `root` 和普通用户共同使用。默认优先使用 `offline_resources/uv-install.sh`；如需在线回退，可在配置中设置 `ALLOW_ONLINE_FETCH=1`。

```bash
./scripts/fetch_resources.sh
```

如需安装常用 `zsh` 插件：

```bash
mkdir -p ~/.zsh/plugins

# 安装 zsh-autosuggestions
git clone https://github.com/zsh-users/zsh-autosuggestions ~/.zsh/plugins/zsh-autosuggestions

# 安装 zsh-syntax-highlighting
git clone https://github.com/zsh-users/zsh-syntax-highlighting.git ~/.zsh/plugins/zsh-syntax-highlighting
```

## 创建新用户

`scripts/add_user.sh` 泛化自「把 winbeau 配置复制给新用户」的手工脚本，配置源全部改为仓库资产（不依赖个人家目录）：`zshrc.txt`、内嵌的 bare-metal Starship 模板（与 `lib/steps/user_shell.sh` 生成内容一致）、`offline_resources/` 里的 Starship 离线包与 zsh 插件。

```bash
cd /path/to/FluxEnv
bash scripts/add_user.sh                # 交互输入用户名和密码
bash scripts/add_user.sh alice          # 用户名用参数，密码交互输入
```

行为：安装 sudo/zsh/curl（缺失时）、按架构装 Starship、建 docker 组并把用户加入 sudo,docker、复制 zshrc/starship.toml/插件、建 `.ssh/authorized_keys` 占位；旧配置先备份；密码输入两次，留空则跳过（账户保持锁定）。用户已存在时幂等更新。

## Claude 多用户共享登录

`scripts/add_claude_user.sh` 让机器上多个 Linux 用户**共用同一个 Claude Code 登录**（一份订阅/凭证），
而每个用户敲 `claude` 时的环境仍像自己原生的（`HOME`/`USER`/`git`/`ssh` 都是自己的）。适合一个人用多个账号分隔工作。

```bash
# 新增/幂等接入一个用户（登录持有者默认 winbeau，可用 CLAUDE_LOGIN_USER 指定）
sudo bash scripts/add_claude_user.sh dev3

# 移除某用户（公共基建保留）
sudo bash scripts/add_claude_user.sh dev3 cleanup
```

**给用户加 SSH 公钥登录**（`add_ssh_key.sh`；因家目录被 ACL 开成组可写，公钥放 root 拥有的 `/etc/ssh/authorized_keys/<user>` 以绕开 sshd StrictModes）：

```bash
# 加公钥 + 打印客户端 ssh config + 默认关闭密码登录（CLAUDE_SSH_HOSTNAME 指定 config 里的 HostName）
export CLAUDE_SSH_HOSTNAME=<服务器IP或域名>
sudo -E bash scripts/add_ssh_key.sh dev3 "ssh-ed25519 AAAA... you@host"

# 只加公钥、不关密码登录
sudo KEEP_PASSWORD=1 bash scripts/add_ssh_key.sh dev3 "ssh-ed25519 AAAA..."

# 单独关闭 / 恢复 SSH 密码登录（带防锁死检查）
sudo bash scripts/ssh_disable_password.sh
sudo bash scripts/ssh_disable_password.sh undo
```

原理、实测依据与代价（进程 uid、历史共享、额度、git/ssh 身份等）见 `docs/CLAUDE_SHARED_LOGIN.md`。

> ⚠️ 仅用于**同一个人**的多个账号复用一份订阅；给不同的人共享个人订阅违反 Anthropic 条款。

## ISRC Cisco VPN

`scripts/deploy-cisco.sh` 把 `ciscoup` 命令背后的整套部署资产一键装好：`openconnect`（缺失时 apt 自动安装）、`/usr/local/sbin/cisco-vpn-run`、`cisco-vpn.service` 服务单元、`~/bin/ciscoup` 命令；自动创建所需目录、备份已存在文件，重复执行幂等。

```bash
cd /path/to/FluxEnv
bash scripts/deploy-cisco.sh          # 非 root 时自动用 sudo 重执行
```

部署完成后连接 VPN（提示输入 PIN 码 + 当前动态码）：

```bash
ciscoup
```

可选环境变量：`CISCO_USER`、`CISCO_AUTHGROUP`、`CISCO_SERVER`、`CISCO_INTERFACE`、`CISCO_ROUTE_CHECK`、`CISCO_ENABLE=1`（开机自启，默认按需启动）。卸载：`bash scripts/deploy-cisco.sh remove`。

## 代理说明

如果在 WSL 或切换用户后访问 GitHub 很慢，建议直接为目标用户设置 Git 全局代理：

```bash
git config --global http.proxy http://127.0.0.1:xxxx
git config --global https.proxy http://127.0.0.1:xxxx
```

将 `xxxx` 替换为你本地代理端口。相比只设置 `http_proxy` / `https_proxy`，这种方式在 `sudo` 或 `su -` 切换用户后通常更稳定。

如需清空 Git 代理：

```bash
git config --global http.proxy ""
git config --global https.proxy ""
```

## 说明

- 默认会在 `apt update` 前切换 Ubuntu 软件源到清华源；如需关闭，可设置 `ENABLE_APT_MIRROR=0` 或传入 `--no-apt-mirror`
- apt 源备份写入 `/var/backups/fluxenv/apt/`，不会污染 `sources.list.d`
- 默认优先使用 `offline_resources/` 中的离线资源，除非显式开启在线抓取
- `standard`、`normal` 和 `autodl` 三种模式结束后都会自动进入 `zsh`
- 在 WSL 的 `standard` 模式下，会自动检查并修正 `/etc/wsl.conf` 的默认登录用户；修改后需要在 Windows 侧执行 `wsl --shutdown`
- Starship 离线包目前仅内置 `x86_64` 版本；在树莓派等非 `x86_64` 设备上会自动跳过离线安装，不再中途中断
- 资源来源说明见 `docs/RESOURCE_SOURCES.md`
