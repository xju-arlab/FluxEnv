# NetUI（第二阶段）

本目录是 FluxEnv 中 NetUI 的第二阶段实现：配置模型、tmux 单实例 CLI、持久代理环境 profile、Bash/Zsh shell 同步，以及低闪烁的全屏 ANSI 配置管理 TUI。

## 当前命令

将 `bin/netctl` 以三个名称调用即可复用同一个核心：

```bash
ln -s /path/to/packages/netui/bin/netctl ~/.local/bin/netup
ln -s /path/to/packages/netui/bin/netdown ~/.local/bin/netdown
ln -s /path/to/packages/netui/bin/netctl ~/.local/bin/netui
```

- `netup` 校验并启动 `default.json` 指向的配置，并自动启用当前用户的代理环境，不接受临时配置参数。默认模式为 `cn-direct`，已有 `global` 偏好会保留。
- `netdown` 只停止经过 NetUI token、tmux marker、pane PID、进程 starttime 和核心绝对路径交叉验证的实例；没有实例时幂等清理 stale state。
- `netui` 在交互终端中提供全屏键盘 TUI；方向键移动选择，`Ctrl+↑` 和 `Ctrl+↓` 都在 `cn-direct` / `global` 之间循环切换。界面只输出发生变化的行，并在终端尺寸变化时重排。`TERM=dumb` 或 raw mode 不可用时退回行式界面。

运行依赖：Bash、`jq`、`tmux`、`flock`、`sha256sum`、`realpath`、`tail`，以及 PATH 中、包内 `bin/sing-box` 或 `NETUI_SING_BOX` 指定的可执行核心。gum 优先使用包内 `bin/gum`，缺失时不阻断 TUI。全屏界面默认在彩色 TTY 中启用分层主题；设置 `NO_COLOR=1` 或 `NETUI_TUI_COLOR=never` 可关闭颜色。

## 用户目录

默认使用 XDG 用户态目录：

```text
~/.config/netui/configs/*.json
~/.config/netui/default.json -> configs/<name>.json
~/.config/netui/env-mode                 # cn-direct (default) | global
~/.local/share/netui/
~/.local/state/netui/runtime/
~/.local/state/netui/logs/
~/.local/state/netui/backups/config-trash/
```

配置目录只发现第一层普通 `*.json` 文件。配置会经过 `jq empty` 和 `sing-box check -c` 两级校验，并收紧为 mode `600`。默认链接由配置库以相对 symlink 原子替换，不能指向目录外、symlink、FIFO、设备或其他非普通文件。

## 环境 profile

- `global`：HTTP/HTTPS/ALL proxy 指向当前 loopback endpoint，`no_proxy` 只有 `localhost,127.0.0.1,::1`。
- `cn-direct`（默认）：使用固定、去重且运行时计算长度的大陆域名后缀列表，长度不超过 512 bytes。这是域名后缀白名单，不是按 IP 地理位置分流。

安装器默认在 `.bashrc`、`.zshenv` 和 `.zshrc` 中安装 `share/shell/init.sh`，编辑前创建备份。首次安装后打开一个新终端即可使用。`netup`、`netdown`、`netui` 的 shell 函数调用对应可执行文件后立即同步当前 shell，支持 `netup && curl https://github.com`，无需手动 `export`。Bash 的 hook 位于非交互 early return 之前，Zsh 通过 `.zshenv` 加载，因此 `ssh host 'curl ...'` 也会继承正在运行的代理。prompt hook 同步其他终端改变的模式，tmux global environment 影响之后创建的 pane/window。

`sudo` shell 函数只通过 `--preserve-env` 传递八个 HTTP/HTTPS/ALL/no_proxy 大小写变量，遵循服务器现有的 sudo 授权策略；不会改写 sudoers 或系统服务环境。使用绝对路径 `/usr/bin/sudo` 或 `command sudo` 会绕过函数。未加载 hook 的独立脚本也不会获得这些函数；可以从已加载 hook 的终端启动脚本，让脚本继承环境。

两种模式都需要运行中的代理；`netdown` 或代理异常退出后自动清除由 NetUI 设置的变量，保留模式供下次启动使用。旧版本的 `off` 偏好会迁移为 `cn-direct`。HTTP/HTTPS 使用本地 HTTP 代理，ALL_PROXY 使用 `socks5h`，让代理端解析目标域名，避免访问 GitHub 等站点前等待本机 DNS 超时。代理仅覆盖支持这些环境变量的命令。

模式写入 `env-mode`，generation 写入 runtime state。配置归档移动到可恢复的 trash 目录，并支持恢复，不直接删除原文件。

测试时可以设置 `HOME`、`XDG_CONFIG_HOME`、`XDG_DATA_HOME`、`XDG_STATE_HOME`，并用 `NETUI_SING_BOX` 指向脱敏 fake sing-box；`NETUI_TMUX_SOCKET` 可隔离测试用 tmux server。`NETUI_TUI_ACTIONS` 可用于无 TTY 的确定性业务测试，不替代真实交互终端验证。

## 安装与 Release 链路

当前包已包含安装和本地 Release 构建入口：

固定版本安装：

```bash
curl -fsSL 'https://gitcode.com/winbeau/FluxEnv/releases/download/v0.2.3/install-v0.2.3.sh' | sh
```

本地构建：

```bash
bash packages/netui/install.sh --asset-dir /path/to/locked-assets
bash packages/netui/scripts/build-release.sh --asset-dir /path/to/locked-assets \
    --release-base-url 'https://gitcode.com/winbeau/FluxEnv/releases/download/v0.2.3'
```

`manifest.lock` 固定 sing-box 1.13.18、gum 2.0.0 的 Linux amd64/arm64 来源和 SHA256。安装器会校验资产、创建版本目录和 `current` 原子链接，并只在验证通过后建立 `netup`、`netdown`、`netui` 链接。`bootstrap.sh`/`install-v*.sh` 只接受固定 HTTPS Release 目录，不接受 `latest`。GPL 对应源码入口见 `SOURCE-CODE-OFFER.md`。

发布前仍必须完成 GitCode 公开下载链路实测、临时 HOME 安装验证、秘密扫描、VHS 视觉 smoke 和许可证/第三方声明审查。legacy migration、h100 操作和未验证的 GitCode URL 不由安装器静默执行。
