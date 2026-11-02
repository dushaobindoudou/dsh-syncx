<div align="center">

# dsh-syncx

**跨机器同步 DeepSeek Harness (dsh) 的 profile** ——
插件与设置以声明式快照进 git，模型凭证用仅存本机的密钥 AES 加密。

[![npm](https://img.shields.io/npm/v/dsh-syncx?logo=npm&color=cb3837)](https://www.npmjs.com/package/dsh-syncx)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](./LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux-blue)](#-系统要求)
[![Node](https://img.shields.io/node/v/dsh-syncx?logo=nodedotjs&color=339933)](https://www.npmjs.com/package/dsh-syncx)

[English](./README.md) · 简体中文

</div>

---

`dsh-syncx` 备份并恢复每个 [dsh](https://www.npmjs.com/package/@deepseek-ai/dsh)
profile——插件依赖清单、bundle 装载顺序、模型路由和全部用户设置——把少数几个
**声明式文件**经由私有 git 仓库搬运。dsh 本身**没有内置配置同步**（CLI 无
sync/export/import 命令）；本工具用「快照 → 推送 → clone → 恢复」的工作流补上这块，
让一台新机器几分钟进入生产状态。

## ✨ 为什么可行

dsh profile 本来就是声明式的——一个 `package.json`（插件依赖 + bundle 装载清单）、
一个 `cordis.patch.yml`（全部用户设置），加上锁文件。所以同步本质就是：
**捕获这些文件，用 `pnpm install` 重放**。本工具在此基础上增加：

- **每方向一条命令**：`export` / `restore`，配 `diff` 检测漂移
- **凭证加密**：真实 API key 永不进 git——只有 AES-256-CBC 密文，且只能用
  存于本机的密钥文件解开
- **`link:` 感知**：dsh profile 通过 `link:` 依赖加载本地插件源码；快照记录全部
  源路径，`links` 在目标机器逐一校验
- **自动备份**：每次恢复先把现状存入 `backups/`

## 📦 同步什么

| 状态 | 位置 | 入仓形态 |
|---|---|---|
| 插件依赖 + bundle 装载清单 | `~/.dsh/profiles/<name>/package.json` | 明文 |
| 全部用户设置（模型、主题、语言、插件配置） | `~/.dsh/profiles/<name>/cordis.patch.yml` | 明文 |
| 版本锁定 | `pnpm-lock.yaml`、`pnpm-workspace.yaml` | 明文 |
| 模型路由（仅含 `keyRef` 引用名——无密钥） | `~/.dsh/freeroute.json` | 明文 |
| 模型凭证（真实 API key） | `~/.dsh/.credentials.yaml` | **AES-256-CBC `.enc`** + sha256 |
| `link:` 插件源路径 | 从 `package.json` 提取 | `links.manifest.json` |

不同步（会话状态，有意设计）：`~/.dsh/sessions`、`~/.dsh/harness` 记忆。

## 🚀 快速开始

```bash
npm i -g dsh-syncx

dsh-sync export          # 本机 ~/.dsh -> snapshot/（credentials 自动加密）
dsh-sync diff web        # 对比快照与本机（profile + 全局，credentials 按 sha256）
dsh-sync restore web     # 快照 -> web profile（自动备份现状）
dsh-sync restore-global  # 快照 -> ~/.dsh（freeroute.json + 解密回写 credentials）
dsh-sync links           # 校验 link: 插件源目录在本机是否存在
dsh-sync status          # 概览（加密状态、校验和）
```

## 🔐 安全模型

- 加密密钥**只存在你的机器上**（`~/.config/dsh-sync/secret.key`，`0600`，
  首次 `export` 自动生成，永不提交）。
- 仓库整体泄露也暴露不了一个 API key——没有本地密钥文件，密文无用。
  密钥文件丢失等于凭证快照丢失，请自行妥善备份密钥。
- 明文凭证永不落入快照目录与 git 历史（脚本只写 `.enc`，`.gitignore` 双保险）。
- `cordis.patch.yml` 可能含本地 ACP token——只对本机 `127.0.0.1:<端口>` 有效，
  远程无法使用。

## 🖥 跨机器工作流

1. **旧机器**：`dsh-sync export`，commit 并 push 本仓库（建议私有）。
2. **新机器**：clone 仓库，同步 `snapshot/links.manifest.json` 里列出的 `link:`
   源码仓库，然后 `dsh-sync links` 直到全部 OK。
3. 通过你自己的安全通道传 `~/.config/dsh-sync/secret.key`。
4. `dsh-sync restore-global && dsh-sync restore web`，再在每个 profile 目录 `pnpm install`。

自动支持两种数据模式：在本仓库 clone 内运行使用仓库的 `snapshot/`；
全局安装后运行使用 `~/.config/dsh-sync/`。两者都可用 `DSH_SYNC_DIR` 覆盖；
密钥文件用 `DSH_SYNC_KEYFILE`，dsh 主目录用 `DSH_HOME`。

## 🧰 系统要求

- bash + openssl（支持 `pbkdf2`）——macOS 与 Linux 原生自带
- Node.js ≥ 18（npm 分发）
- python3（仅 `links` 清单生成/校验用）

## ❓ FAQ

**这是 dsh 官方插件吗？**
不是——它是独立 CLI，直接操作 dsh 的 profile 目录。不需要 cordis bundle、
不需要 host 注册；只是读写 dsh 已定义的声明式文件。

**能同步到公开仓库吗？**
除凭证 blob 外技术上可以——但仓库还带着你完整的设置拓扑（哪里用什么模型）。
建议私有；若公开，把 `snapshot/global/` 排除出 git。

**多 profile？**
快照携带 `~/.dsh/profiles` 下发现的全部 profile；用
`dsh-sync restore <name>` 按需恢复。

## 🔗 dsh 插件家族

同一作者的更多 DeepSeek Harness 工具：
[dsh-bots](https://www.npmjs.com/package/dsh-bots)（多 bot 工作台）·
[dsh-hyperliquid](https://www.npmjs.com/package/dsh-hyperliquid)（Hyperliquid 交易台）·
[dsh-plugin-security](https://www.npmjs.com/package/dsh-plugin-security)（插件安全门）·
[dsh-freeroute](https://www.npmjs.com/package/dsh-freeroute)（模型路由）。
浏览全部：`npm search dsh-plugin`。

## 许可

[MIT](./LICENSE)
