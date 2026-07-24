# AI 脚本项目开发约定

本文件适用于整个仓库。任何 AI 或自动化工具在新增、修改脚本项目前，必须先阅读并遵守这些规则。用户在具体任务中的明确要求优先，但不得静默绕过安全检查或 CI 约定。

## 仓库结构

1. 每个脚本项目必须放在一个独立的顶层子目录中，目录名使用小写字母、数字和连字符，例如 `backup-tool/`。
2. 禁止在仓库根目录直接新增 `.sh` 文件。
3. 项目中的 Shell 源文件必须以 `.sh` 结尾，并使用与实际语法一致的 shebang：
   - Bash：`#!/usr/bin/env bash` 或 `#!/bin/bash`
   - POSIX sh：`#!/bin/sh` 或 `#!/usr/bin/env sh`
4. 每个包含 `.sh` 文件的项目目录必须至少包含：
   - `README.md`：用途、支持系统、安装、使用、安全风险和卸载说明；
   - `LICENSE`：项目许可证；
   - `tests/run-tests.sh`：该项目唯一、稳定的测试入口。
5. 新增项目后必须更新根目录 `README.md` 的脚本列表。

推荐结构：

```text
project-name/
├── README.md
├── LICENSE
├── install.sh
├── project-name.sh
├── lib/
└── tests/
    ├── run-tests.sh
    └── test-*.sh
```

## 测试入口约定

1. `tests/run-tests.sh` 必须可以在 GitHub Actions 的 Ubuntu runner 中通过 `bash tests/run-tests.sh` 执行。
2. 测试入口必须自行定位项目根目录，不能依赖调用者当前所在目录。
3. 测试成功返回 `0`；任一断言失败必须返回非 `0`。
4. 测试必须自包含、可重复执行并使用临时目录隔离数据。
5. 测试不得要求交互输入、真实 root 权限或免密 `sudo`。
6. 测试不得修改开发机或 CI runner 的真实防火墙、服务、软件包、用户配置以及 `/etc`、`/usr`、`/var` 中的系统状态。
7. nftables、systemd、OpenRC、包管理器和其他高权限操作必须使用 mock、fixture 或 dry-run 验证。
8. 测试默认不得依赖外部网络；确有需要时，必须在 README 和 workflow 中明确说明并提供可控的失败行为。

## 通用 CI 约定

仓库使用 `.github/workflows/shellcheck.yml` 作为通用 CI，不为普通新脚本复制 workflow。

CI 会：

1. 在任意 push 和 pull request 时触发；
2. 自动发现仓库中的全部 `*.sh`；
3. 按 shebang 分别执行 `bash -n` 或 `sh -n`；
4. 对全部 Shell 文件执行 ShellCheck；
5. 拒绝根目录中的 `.sh` 文件；
6. 自动识别含 Shell 文件的顶层项目，并检查 `README.md`、`LICENSE`、`tests/run-tests.sh`；
7. 自动发现并逐个运行所有 `tests/run-tests.sh`。

禁止把通用 workflow 的 `paths` 或 `working-directory` 写死到某个项目。只有项目确实需要特殊操作系统、容器、架构或外部服务时，才可以在保留通用 CI 的前提下增加专用 workflow。

## 完成标准

AI 在交付任何脚本改动前必须：

1. 运行相关项目的 `tests/run-tests.sh`；
2. 对所有改动的 Shell 文件运行对应语法检查；
3. 确认 ShellCheck 无 warning；
4. 检查 `git diff`，避免提交密钥、Token、密码、真实服务器地址或无关改动；
5. 同步更新项目 README、变更记录和根目录脚本列表（如适用）；
6. 推送后确认通用 GitHub Actions workflow 通过。

如果受环境限制无法完成其中一项，必须明确说明未完成的检查及原因，不能声称已经全部验证。
