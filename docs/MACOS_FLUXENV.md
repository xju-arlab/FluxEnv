# FluxEnv macOS

`scripts/fluxenv` 在 macOS 上自动进入 Mac 初始化流程，也可以直接运行 `scripts/fluxenv-macos`。安装器兼容 macOS 自带的 `/bin/bash 3.2`，区分 Apple Silicon 和 Intel Homebrew 路径，并复用当前普通用户。

## 开始使用

```bash
cd /path/to/FluxEnv
bash scripts/fluxenv --dry-run
bash scripts/fluxenv
```

不要使用 `sudo bash scripts/fluxenv`；Homebrew 应由普通用户管理。首次安装 Homebrew 时由官方安装器请求所需权限，设备改名时单独使用 `sudo scutil`。

Apple 命令行开发工具缺失时，交互模式可打开 `xcode-select --install` 的系统安装窗口；完成安装后重新执行 FluxEnv。非交互模式会提示先安装开发工具并退出，避免等待图形界面。

macOS 无需运行 `scripts/fetch_resources.sh`。仓库内的 Starship 离线包是 Linux 二进制，Mac 流程使用 Homebrew 提供的对应架构版本；原有离线资源保持原样。

## 工具对应关系

| Linux 工具 / 步骤 | macOS 方式 |
| --- | --- |
| wget、jq、Git、autojump、universal-ctags | Homebrew 同名 formula |
| uv、Starship | Homebrew 同名 formula |
| GitHub CLI（gh） | Homebrew `gh` |
| Hugging Face CLI（hf） | 当前用户的 `uv tool install 'huggingface_hub>=1.20'` |
| nvm / Node.js 24 | 官方 nvm 安装器和 `nvm install -b 24`，设置默认版本 24 |
| pnpm | 当前 nvm Node 的 Corepack 启用和管理 |
| GitCode CLI（gc） | 当前用户的 `pnpm add --global atomgit-cli@latest` |
| zsh-autosuggestions、zsh-syntax-highlighting | Homebrew 安装并自动加载相同插件 |
| zsh、curl、unzip、sudo、locale | 使用 macOS 自带工具 / 设置 |
| gcc / g++ / make | Apple 命令行开发工具提供 Clang 和兼容命令；需要 GNU GCC 可配置 `MACOS_EXTRA_FORMULAE="gcc"` |
| Vim、astyle | 可选安装 Homebrew 版本，Vim 使用 macOS 剪贴板 |
| Linux xclip、glibc-doc、用户 / SSH / systemd 设置 | Mac 流程不执行 |

安装只补充缺失的 formula，已有工具不会被 FluxEnv 主动升级。Homebrew 可能为新工具安装或更新所需依赖。不添加镜像、不写入代理配置；已有终端配置中的网络设置保留。

安装依据：[Homebrew 官方安装说明](https://docs.brew.sh/Installation)、[Apple 命令行工具说明](https://developer.apple.com/documentation/xcode/installing-the-command-line-tools/)、[autojump 配置说明](https://formulae.brew.sh/formula/autojump)、[zsh 自动建议](https://formulae.brew.sh/formula/zsh-autosuggestions)、[zsh 语法高亮](https://formulae.brew.sh/formula/zsh-syntax-highlighting)。Homebrew 对系统版本和 Intel 硬件的支持以官方当前说明为准。

## 设备名交互

首次安装流程显示当前设备名，再询问是否改名。默认保留，输入新名后还会再次确认；已初始化设备不重复询问，可用 `--rename-device` 再次进入交互：

```text
是否修改这台 Mac 的设备名？ [y/N]: y
请输入新设备显示名（留空取消，可含中文和空格）: 我的 MacBook
Bonjour/主机名 [MacBook]: my-macbook
ComputerName → 我的 MacBook
LocalHostName / HostName → my-macbook
确认修改以上三个名字？（需要管理员密码） [y/N]: y
```

`ComputerName` 可包含中文和空格；`LocalHostName` / `HostName` 使用同一个最长 63 字符的字母、数字、连字符名字，首尾不能是连字符。只含中文、无法自动派生 Bonjour 名时，优先提供当前 Bonjour 名作为默认值，可手动修改。

确认后请求管理员权限，并把改名前三个名字记录到 `~/.local/state/fluxenv/macos/device-name.<时间>.<随机值>`，权限为 600。某个写入失败时，会尝试恢复全部原名；恢复失败会显示原始记录位置。原来未设置的 `HostName` 会以空值恢复。

也可以通过参数指定名字：

```bash
bash scripts/fluxenv --device-name "我的 MacBook" --local-hostname my-macbook
bash scripts/fluxenv --skip-device-name
bash scripts/fluxenv --rename-device
```

交互运行时仍会确认。`--non-interactive` 只有显式参数或配置中的 `DEVICE_NAME` 才授权改名，否则保留当前名字。`--skip-device-name` 优先于任何指定名字。`--dry-run` 不调用 `sudo`，包括显式指定名字时也只展示计划。

需要手动恢复时，从记录中读取原值，逐条执行；原本为空的 `HostName` 使用空字符串：

```bash
sudo scutil --set ComputerName "原设备显示名"
sudo scutil --set LocalHostName "原 Bonjour 名"
sudo scutil --set HostName ""   # 如果原来未设置 HostName
```

## 参数和配置

```bash
bash scripts/fluxenv --help
bash scripts/fluxenv --with-vim
bash scripts/fluxenv --without-vim --skip-device-name
bash scripts/fluxenv --config config/example-macos.env --non-interactive
bash scripts/fluxenv --dry-run --with-vim --device-name "工作 Mac" --local-hostname work-mac
```

默认配置在 `config/profile-macos.env`，用户覆盖示例在 `config/example-macos.env`。配置文件按 Bash 加载，只使用可信文件；命令行的改名 / 跳过改名 / Vim 开关优先于配置。

| 配置 | 默认值 / 作用 |
| --- | --- |
| `INSTALL_HOMEBREW` | `1`；缺失时安装官方 Homebrew，`0` 要求提前安装 |
| `ENABLE_VIM` | `ask`；交互询问，非交互默认不安装；也可设 `1` / `0` |
| `HF_LOGIN` | `ask`；交互可选浏览器设备码登录，`0` 跳过，`1` 请求终端授权 |
| `HF_TOOL_SPEC` | `huggingface_hub>=1.20`；确保支持原生设备码登录 |
| `FLUXENV_TOOL_BIN_DIR` | 可选；指定 uv 工具的可执行目录，自动加入 zsh PATH |
| `NVM_VERSION` / `NODE_VERSION` | `0.39.7` / `24`；复用已有 nvm，安装并使用指定 Node 主版本 |
| `PNPM_VERSION` / `GITCODE_CLI_SPEC` | `latest` / `atomgit-cli@latest`；首次安装版本，后续检测并复用 |
| `NVM_DIR` / `PNPM_HOME` | `$HOME/.nvm` / `$HOME/.local/share/pnpm`；用户工具目录 |
| `CHANGE_DEFAULT_SHELL` | `ask`；当前用户已使用 `/bin/zsh` 时跳过，否则可选择切换 |
| `MACOS_EXTRA_FORMULAE` | 空；额外的 Homebrew formula，以空格分隔 |
| `DEVICE_NAME`、`LOCAL_HOST_NAME` | 空；设备显示名和可选的 Bonjour / 主机名 |
| `SKIP_DEVICE_NAME` | `0`；设 `1` 始终跳过改名 |
| `MACOS_BREW_BIN` | 可选；显式指定现有 Homebrew 可执行文件 |
| `MACOS_CONFIG_DIR` | `${XDG_CONFIG_HOME:-$HOME/.config}/fluxenv` |
| `MACOS_STATE_DIR` | `${XDG_STATE_HOME:-$HOME/.local/state}/fluxenv/macos` |
| `MACOS_ZDOTDIR` | `${ZDOTDIR:-$HOME}`；zsh 启动文件所在目录 |
| `MACOS_VIMRC` | `$HOME/.vimrc`；可选自定义 Vim 启动文件路径 |

若 `.zshenv` 内才设置 `ZDOTDIR`，运行时请显式传入相同路径，例如 `ZDOTDIR="$HOME/.config/zsh" bash scripts/fluxenv`。

## 终端配置与备份

`.zprofile` 增加 Homebrew 初始化块，`.zshrc` 在末尾加载 FluxEnv 的 macOS 配置，托管标记为 `# >>> fluxenv macos >>>`。托管块之外的内容保留，重复运行不会重复插入。遇到符号链接、非普通文件或不完整托管标记时，会要求手动处理。

生成文件位于 `~/.config/fluxenv/`：

- `macos.zsh`：Homebrew PATH / 补全、共享去重历史、macOS 颜色别名、autojump、Starship、两个 zsh 插件。
- `starship-macos.toml`：沿用 Linux 宿主机提示符样式，显示用户名和真实主机名。
- `vimrc-macos`：选择 Vim 时生成基本编辑设置，保留已有 Vim 配置和插件，不导入 Linux 的 Vundle 配置。

`macos.local.zsh` 可放个人设置，安装器不会创建或覆盖它。已有 `STARSHIP_CONFIG` 设置优先于默认主题。不会读取或复制仓库中的个人 `zshrc.txt`。

仅在内容确实需要修改时，在 `~/.local/state/fluxenv/macos/backups/<运行 ID>/` 备份现有文件。相同文件和本地修改的生成文件不会重写；重复运行也不会产生多余备份。需要回退时，恢复对应启动文件；首次安装前不存在的文件，可移除其中的 FluxEnv 托管块。生成配置独立于仓库路径，安装后无需保留原仓库位置。

## 增量历史与登录

```bash
bash scripts/fluxenv --status
bash scripts/fluxenv --history
bash scripts/fluxenv --hf-login
bash scripts/fluxenv --non-interactive --skip-hf-login
```

成功初始化后会显示已初始化并继续检查增量，补齐缺失工具、复用已有配置和登录。Vim 选择自动记忆，显式 `--with-vim` / `--without-vim` 可覆盖；需要再次交互改设备名时使用 `--rename-device`。

Hugging Face 登录使用 `hf auth login` 自带的浏览器设备码流程，默认可跳过。设备码和令牌不写入 FluxEnv 历史。详细状态文件、失败恢复、Linux 对应行为和官方依据见 [`INCREMENTAL.md`](INCREMENTAL.md)。

新终端自动加载 nvm 并使用默认 Node.js 24；初始化完成时会输出对应启动文件的 `source` 命令（默认是 `~/.zshrc`），可直接复制到当前 zsh 终端刷新环境变量。配置 `MACOS_ZDOTDIR` 时使用该目录的 `.zshrc`。`node -v` / `npm -v` / `pnpm -v` 用于检查工具。GitCode CLI 安装后自行执行 `gc auth login`，GitHub 使用 `gh auth login`。

## 验证

```bash
for script in scripts/fluxenv scripts/fluxenv-macos lib/*.sh lib/steps/*.sh lib/macos/*.sh scripts/fetch_resources.sh tests/macos/run.sh; do
    /bin/bash -n "$script" || exit 1
done
bash tests/macos/run.sh
bash tests/incremental/run.sh
```

测试以临时配置目录和模拟的 Homebrew / 管理员 / 设备改名命令运行，不改变 `HOME`、真实用户文件或设备名，包含伪终端中的实际交互。测试依赖本机 Bash、zsh、Vim 和 Python 3，不需要联网。

验证环境和安装边界见 [`verification/macos-2026-10-10.md`](verification/macos-2026-10-10.md)。
