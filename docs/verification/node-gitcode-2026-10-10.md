# Node.js 24、pnpm、GitCode CLI 和 Ubuntu 20.04 gh 验证

## 环境与检查

开发在 `main`，macOS 15.6.1 arm64，系统 Bash 3.2.57、zsh 5.9、Python 3.9.6。运行时、Mac 模块、测试入口和共享 nvm 测试辅助文件逐个通过 `/bin/bash -n`，`git diff --check` 通过。本机没有 ShellCheck。

`bash tests/macos/run.sh` 与 `bash tests/incremental/run.sh` 使用临时目录和模拟系统命令，覆盖：

- 两端 nvm 安装、Node 24 安装和默认版本、Corepack 启用 pnpm、pnpm 全局安装 `atomgit-cli`。
- 重复初始化不重复安装；gc 消失时单独补装；gc 下载失败后复用已完成的 Node / pnpm。
- Node 安装失败后保留并复用 nvm；默认版本被改动后恢复为 24，无需重新安装工具。
- Mac 生成的 `.zshrc` 实际加载 nvm，Node 24 的路径优先于现有 Homebrew / pnpm 目录中的 Node。
- pnpm 旧版全局目录和新版 `PNPM_HOME/bin` 均可找到 gc；gc 仅执行版本和登录帮助检查。
- Ubuntu 20.04 在 gh 安装前获得官方源、正确 dpkg 架构、`signed-by` 和可读 keyring；二次运行不重复下载；keyring 权限修复、删除后补齐和下载失败重试。
- 保留此前历史、配置、工具、登录及设备改名的全部检查。

真实 Mac 的 `bash scripts/fluxenv --dry-run --skip-device-name --skip-hf-login` 通过，显示复用已有工具与新增 Node / pnpm / gc 的安装计划，未执行完整设备初始化。

## 真实工具安装

临时目录内使用真实官方 nvm 安装器、Node 二进制、Corepack 和 pnpm。Node 下载的 SHA-256 校验通过；当前代码的只读检测确认默认版本与工具可用：

```text
nvm --version:      0.39.7
node --version:     v24.21.0
npm --version:      11.19.0
corepack --version: 0.36.0
pnpm --version:     12.11.2
```

pnpm 的 registry 下载在约 11 MB 处变慢，测试停止该传输，保留临时 Node / Corepack 环境继续验证。随后通过 curl HTTP/1.1 从同一 `registry.npmjs.org` 获取 `atomgit-cli@0.15.0` 的 tarball（19,037,910 字节），SHA-512 与 npm 元数据中的 integrity 匹配。用临时 `GITCODE_CLI_SPEC` 指向该包，通过实际 `install_javascript_tools` 安装并重复执行，结果为：

```text
复用 Node.js 24、nvm、Corepack 和 pnpm
通过 pnpm 安装 GitCode CLI（gc auth login）
Done in 333ms using pnpm v12.11.2
复用 Node.js 24、nvm、Corepack 和 pnpm
复用 GitCode CLI（gc）
gc version 0.15.0
gc auth login --help
Usage: gc auth login [flags]
```

pnpm 默认跳过包的 postinstall 脚本时，gc 自带的二进制和包装器仍可正常运行。安装、版本、登录帮助和重复复用已实测；默认 registry 传输未在这次实测中完整走通。所有工具、缓存、配置和测试状态均放在临时目录并清理，没有修改 `HOME`、真实账号登录或用户终端配置。

## 验证边界

没有可用的 Ubuntu VM / Docker；Ubuntu 20.04 的 apt 安装、源和权限操作由入口级模拟验证，未在真实 Ubuntu 主机运行。未执行真实 gc / gh 账号登录，也未运行 Vite 服务。设备初始化仅预览，未通过本次检查更改真实设备名或终端配置。
