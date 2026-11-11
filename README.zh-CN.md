<div align="center">

# dsh-syncx

**把 DeepSeek Harness (dsh) 的 profile 同步到你自己的 Git 仓库 —— 一个密钥都不外泄。**
按 profile 快照、配置内联密钥自动脱敏、凭证 AES 加密、推送前硬闸拦截明文敏感信息。

[![npm](https://img.shields.io/npm/v/dsh-syncx?logo=npm&color=cb3837)](https://www.npmjs.com/package/dsh-syncx)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](./LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux-blue)](#-系统要求)
[![Node](https://img.shields.io/node/v/dsh-syncx?logo=nodedotjs&color=339933)](https://www.npmjs.com/package/dsh-syncx)

[English](./README.md) · 简体中文

</div>

---

`dsh-syncx` 备份并恢复每个 [dsh](https://www.npmjs.com/package/@deepseek-ai/dsh)
profile——插件依赖清单、bundle 装载顺序、模型路由与全部用户设置——靠的是把少数几个
**声明式文件**搬进你自己的 git 仓库（GitHub、Gitea、私有服务器都行）。dsh 本身
**没有内置配置同步**，本工具补上这块：

```
dsh-syncx push web        # 导出 → 脱敏 → 扫描 → commit → git push，一条命令
dsh-syncx restore web     # 换机器 → 快照 → profile，密钥在本机自动回填
```

## ✨ v0.3 新增

| 能力 | 命令 | 说明 |
|---|---|---|
| 一条命令发到 GitHub | `push [profile...]` | 导出 + 敏感信息闸 + commit + push |
| 按 profile 同步 | `export acp`、`push web,acp`、`diff all` | 只同步点名的 profile，`all` 表示 `~/.dsh/profiles` 下全部 |
| 配置内联密钥脱敏 | `export` 时自动 | `cordis.patch.yml` 里的 `token:`、`apiKey:`、密码、密钥 → `__REDACTED_<规则>_<哈希>__` |
| 推送前硬闸 | `push` 时自动 | 仓库里还有高危明文敏感信息就拒绝推送（`--allow-findings` 才能强推） |
| 还原仍可用 | `restore` 时自动 | 占位符从本机**加密**映射表回填，恢复出来的 profile 照常能用 |
| 历史清理 | `scrub-history --yes` | 把每个历史 commit 里的快照重新脱敏，清 reflog、丢旧对象 |

## 📦 同步什么

| 状态 | 位置 | 入仓形态 |
|---|---|---|
| 插件依赖 + bundle 装载清单 | `~/.dsh/profiles/<name>/package.json` | 明文 |
| 全部用户设置（模型、主题、语言、插件配置） | `~/.dsh/profiles/<name>/cordis.patch.yml` | 明文，**内联密钥已脱敏** |
| 版本锁定 | `pnpm-lock.yaml`、`pnpm-workspace.yaml` | 明文 |
| 模型路由（仅 `keyRef` 环境变量名） | `~/.dsh/freeroute.json` | 明文，必要时脱敏 |
| 模型凭证（真实 API key） | `~/.dsh/.credentials.yaml` | **AES-256-CBC `.enc`** + sha256 |
| `link:` 插件源路径 | 从 `package.json` 提取 | `links.manifest.json` |
| 脱敏索引（占位符 → 真值） | `~/.config/dsh-syncx/redactions.json.enc` | **永不入仓** |

不同步（会话状态，有意设计）：`~/.dsh/sessions`、`~/.dsh/harness` 记忆。

## 🚀 快速开始

```bash
npm i -g dsh-syncx
cd ~/my-config-repo && git remote add origin git@github.com:<you>/dsh-syncx.git

dsh-syncx push all             # 整套动作：导出 + 脱敏 + 扫描 + commit + push
dsh-syncx push web acp         # 只同步这两个 profile
dsh-syncx diff all             # 快照 vs 本机（占位符先回填，比较是真实差异）
dsh-syncx scan --snapshot      # 只看：敏感信息都在哪（不改文件）
dsh-syncx status               # profile、脱敏条数、加密状态、远端

# 另一台机器
git clone git@github.com:<you>/dsh-syncx.git && cd dsh-syncx
dsh-syncx links                # link: 源目录是否都在
dsh-syncx restore-global       # ~/.dsh/freeroute.json + credentials（解密回写 0600）
dsh-syncx restore web          # profile 文件，密钥从本机映射回填
cd ~/.dsh/profiles/web && pnpm install
```

## 🔐 安全模型（三层独立防线）

1. **凭证永不落明文。** 只写 `.credentials.yaml.enc` + sha256；密钥文件
   `~/.config/dsh-syncx/secret.key`（0600，仅本机，首次 export 生成）。
2. **内联密钥在提交前脱敏。** 扫描器既认 token 形态（`sk-…`、`ghp_…`、`xoxb-…`、
   `AKIA…`、`AIza…`、JWT、SSH/PEM 私钥、0x 私钥、webhook URL、Telegram bot token），
   也认上下文键名（`token:`、`apiKey:`、`password:`、`secret:`、`passphrase:`、
   `webhook:`……），同时放过环境变量引用（`DEEPSEEK_API_KEY`、`${VAR}`、`keyRef`、
   `apiKeyEnv`、`secretStore: keychain`、路径）。真值写进
   `redactions.json.enc`（同一把 AES 密钥、0600、已 gitignore）。
3. **推送有闸。** commit 前再整仓扫一遍，只要有一处高危命中，就带着
   `文件:行 规则` 拒绝推送。

因此整仓即使泄露（哪怕公开）也解不出 API key、bot token 或密码。在本机 restore
会自动回填；换机器则需要手工搬两个文件：`secret.key` 和 `redactions.json.enc`。

## 🖥 跨机器工作流

1. **旧机器**：`dsh-syncx push all`（commit 与 push 都会代办）。
2. **新机器**：clone 仓库，把 `snapshot/links.manifest.json` 里列出的 `link:`
   源码仓库同步到本机，`dsh-syncx links` 到全部 OK。
3. 通过你自己的安全通道传 `~/.config/dsh-syncx/secret.key` **和**
   `redactions.json.enc`（两者都仅本机，缺一个就无法还原真值）。
4. `dsh-syncx restore-global && dsh-syncx restore web`，再在每个 profile 目录 `pnpm install`。

数据目录自动判定：在仓库 clone 里运行就用该仓库的 `snapshot/`；全局安装的命令
默认 `~/.config/dsh-syncx/`。可用 `DSH_SYNC_DIR`、`DSH_SYNC_KEYFILE`、
`DSH_SYNC_REDACTIONS`、`DSH_HOME`、`DSH_SYNC_REMOTE`、`DSH_SYNC_BRANCH` 覆盖。

## 🧰 系统要求

- bash + openssl（支持 `pbkdf2`）——macOS / Linux 自带
- python3 ≥ 3.7——扫描与脱敏（纯标准库，无需 pip）
- Node.js ≥ 18（npm 分发用）
- git（`push` / `scrub-history` 用）

## ❓ 常见问题

**这是官方 dsh 插件吗？** 不是——独立 CLI，只读写 dsh 自己定义的 profile 文件，
不需要 cordis bundle，也不需要宿主注册。

**能同步到公开仓库吗？** v0.3 会脱敏 + 推送闸，公开也扛得住；但设置拓扑本身仍能
看出你用哪些模型和服务，私有仓库依旧是更稳的选择。

**脱敏功能之前就已经把密钥提交进去了怎么办？** 先
`dsh-syncx scrub-history --yes`，再
`git push --force-with-lease origin <branch>`。命令会先写
`backups/history-<ts>.bundle`，本地不会丢东西。

**多 profile 怎么同步？** `export`/`push`/`diff` 都接受列表：
`dsh-syncx push web acp headless`，或 `all`（默认）。

## 🔗 dsh 插件家族

[dsh-bots](https://www.npmjs.com/package/dsh-bots) ·
[dsh-hyperliquid](https://www.npmjs.com/package/dsh-hyperliquid) ·
[dsh-plugin-security](https://www.npmjs.com/package/dsh-plugin-security) ·
[dsh-freeroute](https://www.npmjs.com/package/dsh-freeroute)。
全部：`npm search dsh-plugin`。

## License

[MIT](./LICENSE)
