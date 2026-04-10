---
name: daily-memory-archiver
description: |
  Daily Memory Archiver v1.3.0 — OpenClaw 会话归档：加密凭证、单次 archive-engine（可选多 session 按时间合并 + 本地提取 + 可选云端 LLM 摘要 + memory + 各通道 sessions.compact）。根目录 ~/.openclaw/skills/daily-memory-archiver。

  **必须读取本 Skill 时**：安装/配置 API、定时归档、credentials.enc、merge_jsonl_keys、pairing、多通道、get-cloud-creds、archive-engine。

  **Skill 根目录**：`~/.openclaw/skills/daily-memory-archiver`
---

# Daily Memory Archiver

**文档与实现版本：1.3.0**（`config.yaml` 中 `skill_version` 可与本文不一致时，以本文与脚本为准。）

## 0. 核心思路

1. **对话驱动**：由助手执行脚本，避免用户死记命令。
2. **敏感信息**：`api_url` / `api_token` / `model` 仅入 **`config/credentials.enc`**；回复中禁止复述完整 Token。
3. **单次入口**：`scripts/archive-engine.sh archive` 或 `bin/daily-memory-archiver archive`。流程：读 `sessions.json` →（可选）多路 jsonl 按 **`timestamp` 合并** → 判阈值 → 取最近 N 条分析 → 写 `memory/YYYY-MM-DD.md` → **对每个 session key 分别** `sessions.compact`。
4. **与轻量 memory 钩子可并存**。

## 1. 依赖

`bash`、`jq`、`openssl`、`curl`；推荐 `flock`、`openclaw`（compact）。

```bash
bash ~/.openclaw/skills/daily-memory-archiver/scripts/self-check.sh
```

## 2. 安装与 API

```bash
~/.openclaw/skills/daily-memory-archiver/bin/daily-memory-archiver init --defaults
```

写入凭证（JSON）：

```bash
jq -n --arg u "BASE_URL" --arg t "TOKEN" --arg m "MODEL" \
  '{api_url:$u, api_token:$t, model:$m}' | \
  bash ~/.openclaw/skills/daily-memory-archiver/scripts/config-manager.sh save-json
```

**`save-json` 会保留**已有 **`session.key`** 与 **`merge_jsonl_keys`**，不会清空多通道列表。

状态：`config-manager.sh status` / `show`（脱敏）。

## 3. 归档命令

```bash
bash ~/.openclaw/skills/daily-memory-archiver/scripts/archive-engine.sh archive
bash ~/.openclaw/skills/daily-memory-archiver/scripts/archive-engine.sh archive --force
```

日志：`~/.openclaw/logs/daily-memory-archiver.log`  
可选轮转：环境变量 **`DAILY_MEMORY_LOG_MAX_BYTES`**（超过则改名为 `.1` 并新开）。

## 4. 多通道 `merge_jsonl_keys`

在 **`config/config.yaml`**：

```yaml
session:
  key: "agent:main:main"
  merge_jsonl_keys:
    - "agent:main:main"
    - "agent:main:feishu:direct:<open_id>"
```

- 合并：多 jsonl 的 user/assistant 按 **`timestamp`** 排序；多于一路时正文前缀 **`[session_key]`**。
- **阈值**：各 key 的 `usage_tokens` 取 **最大值**。
- **compact**：每个 key **独立** 调用 Gateway（行数各自统计，与合并记忆无关）。
- 临时覆盖：**`DAILY_MEMORY_MERGE_KEYS=key1,key2`**（逗号分隔，key 内勿加空格）。

### 对话中追加 key

1. `jq -r 'keys[]' "$OPENCLAW_HOME/agents/main/sessions/sessions.json"` 核对完整 key。  
2. `bash scripts/config-manager.sh merge-jsonl-keys-add "<key>"`  
3. `merge-jsonl-keys-list` 查看列表。

## 5. pairing（CLI compact）

`openclaw gateway call` 需 **设备配对**。遇 `pairing required`：

```bash
export OPENCLAW_HOME="${OPENCLAW_HOME:-$HOME/.openclaw}"
export GW_TOKEN="$(jq -r '.gateway.auth.token // empty' "$OPENCLAW_HOME/openclaw.json")"
openclaw devices list --json --token "$GW_TOKEN"
openclaw devices approve --latest --token "$GW_TOKEN"
```

勿在聊天中粘贴完整 `GW_TOKEN`。cron 需 **`HOME`、`OPENCLAW_HOME`、`PATH`**（含 `openclaw`）。

## 6. `compacted: false`

Gateway 在 transcript **行数 ≤ max_lines（默认 400）** 时返回 **`compacted: false`**，属正常，未截断文件。

## 7. 环境变量摘要

| 变量 | 作用 |
|:---|:---|
| `OPENCLAW_HOME` | 默认 `~/.openclaw` |
| `OPENCLAW_AGENT_ID` | 覆盖 agent |
| `SESSIONS_JSON` | 显式 sessions.json |
| `DAILY_MEMORY_CONFIG_DIR` | skill `config/` |
| `DAILY_MEMORY_MEMORY_DIR` | memory 输出目录 |
| `DAILY_MEMORY_LOG` | 日志路径 |
| `DAILY_MEMORY_LOG_MAX_BYTES` | 超此字节轮转日志 |
| `DAILY_MEMORY_MERGE_KEYS` | 覆盖 merge 列表 |
| `SKIP_SESSION_COMPACT` / `OPENCLAW_SKIP_COMPACT` | `1` 跳过 compact |
| `ARCHIVE_MODE` | 与向导生成 YAML 相关 |
| `MESSAGES_TO_ANALYZE` / `THRESHOLD_INPUT_TOKENS` 等 | 见 `config-manager` 模板 |

## 8. 脚本索引

| 路径 | 说明 |
|:---|:---|
| `scripts/archive-engine.sh` | `archive [--force] [--session] [--agent]` |
| `scripts/config-manager.sh` | `init-defaults`、`save-json`、`merge-jsonl-keys-*`、`status`、`show` |
| `scripts/get-cloud-creds.sh` | JSON / `--export` |
| `scripts/extractors/local-extractor.sh` | 本地四类关键词块 |
| `scripts/summarizers/cloud-summarizer.sh` | OpenAI 兼容 Chat Completions |
| `scripts/lib/credentials-store.sh` | 加解密 |
| `scripts/self-check.sh` | 自检 |
| `bin/daily-memory-archiver` | 快捷入口 |

## 9. 重载 Skill

修改 `SKILL.md` 后请 **新开会话** 或 `openclaw skills check`，并用 **read** 重新加载本文。

---

*Made for OpenClaw.*
