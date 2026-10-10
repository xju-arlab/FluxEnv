# 增量框架与用户工具验证（2026-10-10）

## 环境

macOS 15.6.1 arm64，系统 Bash 3.2.57、zsh 5.9、Vim 9.1、Python 3.9.6；现有 Homebrew `/opt/homebrew`、uv 0.13.0。开发直接在 `main`。

## 检查结果

全部运行时 Bash 文件、Mac 模块、修改的辅助脚本与两个测试入口逐个通过 `/bin/bash -n`。Python 交互辅助文件语法检查和 `git diff --check` 通过。本机没有 ShellCheck。

`bash tests/incremental/run.sh` 全部通过，使用临时状态/用户目录和模拟 Linux 系统命令，覆盖：

- 成功与失败历史、部分完成记录、失败保留此前成功标记、退出清锁、活跃锁拒绝、失效锁回收。
- Bash 3.2 函数内未定义变量异常不会对调用者报告成功。
- 未修改模板可以更新；本地文件/块修改保留；块外个人设置保留；删除文件补齐；预览不写状态。
- uv 离线安装、二次复用和安装器退出成功却未生成 uv 时拒绝。
- Linux 统一入口、sudo 用户复用、通过目标用户执行 uv 工具操作、只补装缺失 apt 软件包及 gh。
- 重复执行不重装软件、不创建用户、不改密码；新增包/缺失 hf/配置/插件入口单独修复，插件目录个人文件保留。
- gh 包已安装但可执行文件消失时定向重装；各 Linux profile 共用设备历史。
- 系统升级失败必须重试；升级成功后 hf 失败，重跑不会重复升级。
- 非交互显式登录在安装前拒绝，提示稍后手动授权。

`bash tests/macos/run.sh` 全部通过，保留已有的 Mac 安装与改名测试，并新增：

- 重跑不仅内容一致，配置 inode / 修改时间也保持不变；成功历史追加。
- hf/生成配置消失后补齐；手动编辑的生成配置保留。
- Homebrew 包存在但 uv / gh 可执行文件消失时定向修复。
- 老版本 hf 仅因缺少设备码支持而升级，正常版本复用。
- hf 安装失败记录失败而不标记完成，重试复用已安装 formula。
- 伪终端内调用 `hf auth login` 并完成模拟浏览器授权；第二次复用登录，设备码不进入历史。

## 真实工具检查

在临时目录设置 `UV_TOOL_DIR`、`UV_TOOL_BIN_DIR`、`UV_CACHE_DIR`、`UV_PYTHON_INSTALL_DIR`，用真实 uv 执行：

```text
uv tool install 'huggingface_hub>=1.20'
Installed 2 executables: hf, tiny-agents
hf version
version=2.2.0
hf auth login --help
Login from your browser, or using a token from huggingface.co/settings/tokens.
```

uv 自动下载兼容的 CPython 3.10.22 并安装 17 个依赖。确认已安装包包含 `_device_code_login` 与 `_prompt_login_method`。工具、Python 和缓存均位于临时目录，检查后清理；没有更改 `HOME`、真实 hf 登录或终端配置。

真实 Mac 的 `bash scripts/fluxenv --dry-run --skip-device-name --skip-hf-login` 通过，输出摘录：

```text
检测到旧版 FluxEnv 配置，将接入历史记录并增量更新
复用已有工具: uv
[dry-run] ... /opt/homebrew/bin/brew install gh
[dry-run] uv tool install 'huggingface_hub>=1.20'（当前用户: winbeau）
保留已有自定义配置: /Users/winbeau/.config/fluxenv/macos.zsh
复用配置: /Users/winbeau/.config/fluxenv/starship-macos.toml
[dry-run] 补齐/更新托管块: /Users/winbeau/.zshrc
预览完成，未执行安装或改名
```

## 验证边界

没有可用的 Ubuntu VM / Docker，未执行真实 Linux apt、用户、SSH、WSL 或系统配置操作；Linux 结果来自入口级模拟检查，仍需在可丢弃的 Ubuntu / Debian 环境验证完整安装。Mac 没有执行真实 gh 安装、改名或 chsh；Intel 路径仅模拟。真实 Hugging Face 包安装与登录帮助已验证，账号授权仅在模拟终端中验证，未使用真实账号或令牌。
