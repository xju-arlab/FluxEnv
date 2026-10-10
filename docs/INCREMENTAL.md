# 增量初始化、历史与用户工具

`scripts/fluxenv` 的 macOS、normal、standard、autodl 流程共用 `lib/state.sh`、`lib/managed.sh`、`lib/user_tools.sh` 和 `lib/node_tools.sh`。先建立状态和配置复用规则，再由各平台安装缺失的工具。独立的代理、VPN、新用户等辅助脚本不属于这个初始化流程。

## 重复运行

第一次运行也会检测当前安装状态，不要求设备为空。完成后保存成功标记，再次运行显示“当前设备已完成过初始化”，随后继续检测实际环境：

- 已安装的软件包、可运行的 uv / gh 和支持设备码登录的 hf 会复用；不按历史记录直接跳过实际检测。
- nvm 管理的 Node.js 24、默认版本、Corepack / pnpm 和 gc 均检测实际可用性；只补装缺失部分。重复运行不会追随 `latest` 强制升级，默认版本被改动时恢复为 24。
- 缺失的软件包、hf 或生成配置会单独补齐。Linux 的全量系统升级只在首次初始化执行，成功后保存检查点；后续阶段失败不会导致下次重复升级。
- 相同内容的配置不重写、不重复插入托管块、不新增备份。模板更新仅替换未被手动修改的受管文件；有本地修改时保留并提示。托管块之外的个人设置保持原样。
- 没有历史的旧配置按现有文件接入；内容不同的生成文件保留，必要的工具 PATH 通过独立托管块补齐。
- 保存 Vim 开关、目标用户等选择。Linux 已存在的用户默认复用，不重新设置密码或删除家目录；显式重建需终端确认。
- Mac 已初始化时不再重复询问设备改名。使用 `--rename-device` 可再次交互改名，或传 `--device-name` / `--local-hostname`；三个名字已匹配时无需管理员权限。

登录不是初始化完成的必要条件。默认 `HF_LOGIN=ask`，交互询问且默认跳过；非交互安装不会等待浏览器授权。

成功完成后，终端会显示目标用户的环境刷新命令。请在该用户的 zsh 终端执行它，使 nvm、Node.js、pnpm、gc、uv 等 PATH 变量立即生效；也可以重新打开终端。

## 查看状态与历史

macOS：

```bash
./scripts/fluxenv --status
./scripts/fluxenv --history
./scripts/fluxenv --dry-run
./scripts/fluxenv --rename-device
```

Linux：

```bash
sudo ./scripts/fluxenv --profile normal --status
sudo ./scripts/fluxenv --profile normal --history
sudo ./scripts/fluxenv --profile normal --dry-run
```

默认历史目录为 Mac 的 `${XDG_STATE_HOME:-$HOME/.local/state}/fluxenv/macos` 和 Linux 的 `/var/lib/fluxenv`。Linux 各 profile 共享同一设备记录，历史中保留本次 profile。可以使用 `--state-dir /absolute/path` 指定目录；Linux 配置名为 `FLUXENV_STATE_DIR`，Mac 为 `MACOS_STATE_DIR`。继续使用同一目录才能继承此前记录。

目录权限 700、记录文件 600。文件用途如下：

| 文件 | 内容 |
| --- | --- |
| `history.tsv` | UTC 时间、运行 ID、profile、事件、资源、简短说明；追加保存 |
| `receipts.tsv` | 最近一次受管资源的签名或安装记录，用于比较配置变化 |
| `choices.tsv` | 上次 Vim / 目标用户 / 主机名选择 |
| `initialized` | 最近一次成功完成记录；失败不会覆盖此前成功记录 |
| `backups/<运行 ID>/` | 本次确实修改的已有配置的原件；无修改则不创建 |

事件包括 `started`、`applied`、`reused`、`preserved`、`skipped`、`completed`、`failed`。历史不保存密码、令牌、设备码、登录命令输出或环境变量。Hugging Face 自己管理登录凭据。

通过预检后取得运行锁并开始记录；安装中断会记录失败、保留已完成资源的记录，修复后原命令重跑即可。活跃运行互斥，异常退出遗留且 PID 已结束的锁会自动回收。预检失败和只读命令不创建新的安装记录。`--dry-run` 不写状态、用户配置或备份，不安装工具、不登录、不改设备名。

## uv、Hugging Face 和 GitHub CLI

Mac 通过 Homebrew 安装 uv / gh，Linux 优先复用 uv，再尝试离线安装器或 Astral 官方安装器；gh 使用 apt。Ubuntu 20.04 在安装 gh 前自动创建 `/etc/apt/keyrings/githubcli-archive-keyring.gpg`（可供 apt 读取），并写入带当前 dpkg 架构和 `signed-by` 的 `/etc/apt/sources.list.d/github-cli.list`，使用 `https://cli.github.com/packages stable main`。重复运行复用文件，缺失 keyring 时补齐；已有源中的本地修改会保留并要求检查。`GH_APT_REPOSITORY=always` 可在其他 Ubuntu / Debian 上使用官方源，`never` 可关闭此步骤。

Linux 默认 `ALLOW_ONLINE_FETCH=1`，已有或离线资源优先；设为 `0` 且缺少可用 uv 时会明确失败，hf 安装也会限制为 uv 本地缓存。这个开关也禁止新下载 nvm / Node / pnpm / gc，但不禁止 apt 本身获取缺失的软件包或所需的官方 keyring。

安装 hf 使用官方 `huggingface_hub` 包；PyPI 上的 `huggingface` 不是提供这个 CLI 的包。命令为：

```bash
uv tool install 'huggingface_hub>=1.20'
hf version
hf auth login
gh --version
```

`hf` 原生浏览器设备码登录从 1.20 开始支持，脚本会检测版本并仅在版本太旧或无法运行时修复。新安装使用 uv 为目标用户创建工具环境，不把 Python 包装到系统 Python 中。Linux 通过当前 sudo 用户或选定用户执行 `uv tool` 和 `hf`；Mac 使用当前普通用户。uv 的实际工具目录自动加入 shell PATH，也可用 `FLUXENV_TOOL_BIN_DIR` 指定可执行目录。首次安装 hf 需要网络，uv 会在需要时获取兼容 Python。

交互初始化时可选择登录，或显式要求登录：

```bash
./scripts/fluxenv --hf-login                 # Mac；Linux 在前面加 sudo
./scripts/fluxenv --skip-hf-login            # 只安装，不询问登录
./scripts/fluxenv --non-interactive --skip-hf-login
```

`--hf-login` 需要终端；选择 `Log in with your browser`，按 hf 给出的网页地址和设备码完成授权。脚本不拼接不存在的 `--device-code` 参数。已有有效登录时复用，不重复授权；非交互环境需要稍后自行运行 `hf auth login`。GitHub CLI 安装后如需登录可自行运行 `gh auth login`。

安装和登录依据：[Hugging Face CLI 官方说明](https://huggingface.co/docs/huggingface_hub/en/guides/cli#hf-auth-login)、[1.20 浏览器登录发布说明](https://github.com/huggingface/huggingface_hub/releases/tag/v1.20.0)、[uv 工具管理](https://docs.astral.sh/uv/guides/tools/)、[GitHub CLI 登录](https://cli.github.com/manual/gh_auth_login)。

## nvm、Node.js 24、Corepack / pnpm 和 GitCode CLI

两端使用目标用户的 nvm 安装 Node，默认固定主版本 24：

```bash
nvm install -b 24
nvm alias default 24
nvm use 24
corepack enable pnpm
corepack install --global pnpm@latest
pnpm add --global atomgit-cli@latest
```

nvm 缺失时使用 `nvm-sh/nvm` 的 0.39.7 官方安装器。安装器不自行改写启动文件，FluxEnv 通过受管 zsh 块加载 nvm、使用默认 Node 和设置 pnpm 命令路径，同时兼容 pnpm 旧版根目录和新版 `bin` 子目录。Node 只下载官方二进制；已有符合主版本的安装直接复用。Corepack 缺失时用当前 nvm Node 的 npm 安装；旧版本 Corepack 的安装命令或签名验证不兼容时，尝试 `prepare`，必要时更新 Corepack 后重试。

GitCode CLI 项目已更名为 AtomGit CLI，提供 `gc` / `gitcode` 命令，其社区维护的 npm 包名为 `atomgit-cli`。FluxEnv 使用 pnpm 安装这个包，并验证 `gc version` 和 `gc auth login --help`。安装成功后，在新终端中执行：

```bash
node -v                        # v24.x
npm -v
pnpm -v
gc version
gc auth login
gh auth login
pnpm exec vite --host 0.0.0.0 --port 8888   # 在已有 Vite 项目中使用
```

gc 和 gh 的账号登录由用户执行。FluxEnv 只安装和验证命令，不替账号授权。失败后可以用原命令重跑：nvm / Node / pnpm 已成功时直接复用，例如 gc 下载失败不会导致整套工具重新安装。

| 配置项 | 默认值 |
| --- | --- |
| `NVM_VERSION` | `0.39.7`；新安装的 nvm 版本 |
| `NODE_VERSION` | `24`；指定 24 或更高的主版本 |
| `PNPM_VERSION` | `latest`；首次安装版本，已有可用版本复用；可指定版本号 |
| `GITCODE_CLI_SPEC` | `atomgit-cli@latest`；首次安装包及版本 |
| `NVM_DIR` | 目标用户的 `~/.nvm` |
| `PNPM_HOME` | 目标用户的 `~/.local/share/pnpm` |

安装依据：[nvm 官方项目](https://github.com/nvm-sh/nvm)、[Corepack 官方项目](https://github.com/nodejs/corepack)、[pnpm 全局命令目录](https://pnpm.io/cli/bin)、[AtomGit CLI 项目说明](https://github.com/atomgit-cli/cli)、[GitHub CLI 官方 Linux 安装说明](https://github.com/cli/cli/blob/trunk/docs/install_linux.md)。

## 验证

```bash
bash tests/incremental/run.sh
bash tests/macos/run.sh
```

这些检查使用临时目录和模拟系统工具，包含配置复用、失败恢复、锁、Linux 入口和 Mac 设备码交互，不改变真实设备。环境与实测范围见 [`verification/incremental-2026-10-10.md`](verification/incremental-2026-10-10.md) 和 [`verification/node-gitcode-2026-10-10.md`](verification/node-gitcode-2026-10-10.md)。
