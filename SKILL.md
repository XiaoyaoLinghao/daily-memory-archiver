---
name: daily-memory-archiver
description: |
  Daily Memory Archiver v1.4.0 — OpenClaw 会话归档：按 session key 统计用量、检查点后仅合并新增消息、可选分块云端摘要、默认仅对超限 key 执行 sessions.compact。根目录 ~/.openclaw/skills/daily-memory-archiver。

  **必须读取本 Skill 时**：安装/配置 API、定时归档、credentials.enc、merge_jsonl_keys、检查点、pairing、多通道、get-cloud-creds、archive-engine。

  **Skill 根目录**：`~/.openclaw/skills/daily-memory-archiver`

  **维护文档**：同目录 `README.md`（工程布局、日志策略、改代码清单）。
---

# Daily Memory Archiver

**文档与实现版本：1.4.0**（`config.yaml` 中 `skill_version` 可与本文不一致时，以本文与脚本为准。）

## 0. 核心思路

1. **对话驱动**：由助手执行脚本，避免用户死记命令。
2. **敏感信息**：`api_url` / `api_token` / `model` 仅入 **`config/credentials.enc`**；回复中禁止复述完整 Token。
3. **单次入口**：`scripts/archive-engine.sh archive` 或 `bin/daily-memory-archiver archive`。整体流程：**读 `sessions.json` → 按 key 统计用量 → 判断是否应运行 → 自检查点起仅合并各 key 的新消息（跨 key 按 `timestamp` 排序）→ 本地提取 + 可选云端摘要（可分段）→ 写 `memory/YYYY-MM-DD.md` → 仅对用量达阈值的 key 调用 `sessions.compact`（可配置）**。
4. **与轻量 memory 钩子可并存**。

## 1. 依赖

`bash`（建议 4.x，使用关联数组）、`jq`、`openssl`、`curl`；推荐 `flock`、`openclaw`（compact）。

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
# 可选：只处理单个 session（覆盖 merge 列表）
bash ~/.openclaw/skills/daily-memory-archiver/scripts/archive-engine.sh archive --session 'agent:main:main'
bash ~/.openclaw/skills/daily-memory-archiver/scripts/archive-engine.sh archive --agent main
# 仅清理/轮转日志（读 config.yaml 中 logging.*）
bash ~/.openclaw/skills/daily-memory-archiver/scripts/archive-engine.sh log-maintenance
~/.openclaw/skills/daily-memory-archiver/bin/daily-memory-archiver logs
```

| 参数 | 含义 |
|:---|:---|
| `--force` | 忽略阈值判断；仍受检查点与合并逻辑约束。**不**绕过 `min_new_messages` 以外的检查点（0 条新增仍会早退）；与 `--force` 组合时 **`min_new_messages` 不生效**，可立即写 memory。 |
| `--session <key>` | 仅归档该 session key（不读 `merge_jsonl_keys` 多路）。 |
| `--agent <id>` | 覆盖 `openclaw.agent_id`，影响 `sessions.json` 路径。 |

日志默认：`~/.openclaw/logs/daily-memory-archiver.log`  
可选轮转：环境变量 **`DAILY_MEMORY_LOG_MAX_BYTES`**（超过则改名为 `.1` 并新开）。

## 4. 多通道、阈值、检查点与摘要

### 4.1 `merge_jsonl_keys`

在 **`config/config.yaml`** 的 `session.merge_jsonl_keys` 中列出要合并的完整 session key（与 `sessions.json` 中键名一致）：

```yaml
session:
  key: ""
  merge_jsonl_keys:
    - "agent:main:main"
    - "agent:main:feishu:direct:<open_id>"
```

- **合并顺序**：只取 **检查点之后** 的新消息；多路 jsonl 的 user/assistant 按各自行里的 **`timestamp`** 排序合成一条时间线。
- **多路前缀**：合并路数大于 1 时，正文前加 **`[session_key]`**，便于区分来源。

临时覆盖（逗号分隔、键内勿加空格）：**`DAILY_MEMORY_MERGE_KEYS=key1,key2`**

**对话中追加 key**：用 `jq -r 'keys[]' "$OPENCLAW_HOME/agents/<agent>/sessions/sessions.json"` 核对 key → `bash scripts/config-manager.sh merge-jsonl-keys-add "<key>"` → `merge-jsonl-keys-list` 查看。

### 4.2 用量与触发（`archive.trigger_mode`）

- **按 key 统计**：每个 key 从 `sessions.json` 对应项读取用量（`totalTokens` / `inputTokens` 规则与 `resolve_usage_tokens` 一致）；日志中会输出 **`per_key: key=用量`**。
- **是否执行本次 `archive` 主流程**（读 jsonl、合并、可能写 memory）由 **`trigger_mode`** 决定：
  - **`threshold`（默认）**：至少有一个 key 的用量 **≥ `archive.threshold.max_input_tokens`** 时才继续；否则直接退出（可用 **`archive --force`** 跳过阈值）。
  - **`scheduled`**：每次调用都进入后续步骤（适合纯定时扫增量）。
  - **`hybrid`**：满足 **阈值** 或 **距上次归档超过 `check_interval_minutes`** 之一即运行。

**说明**：在 `threshold` 下，“是否存在 key 超阈值”与“所有 key 用量取 max 再与阈值比较”在数学上等价；差别在于后续 **compact 只打超限 key**（见下）。

### 4.3 检查点 `config/.archive_merge_checkpoint.json`

- 每个 session key 记录已归档的 **最后一条已处理消息的 `timestamp`（ISO 8601）**；下一轮只拉 **严格晚于** 该时间的消息参与合并。
- **成功写入 memory 段落**后更新检查点；**因冷却跳过 memory 写入**时不更新（避免“没写 md 却认为已处理”）。
- **删除该文件** 等价于清空检查点，下次会对各 key **全量**再扫一遍（历史极长时首跑成本高，且可能 **重复写入 memory**，慎用）。
- 该文件为本地状态，已在 skill **`.gitignore`** 中忽略。

### 4.4 本周期无新增 / 攒批（`archive.min_new_messages`）

- 若检查点之后 **合并结果为 0 条**消息：不写 memory、不推进检查点；仍会按规则尝试 **compact**（仅超限 key）。
- 若有新增但条数 **&lt; `min_new_messages`** 且 **未**使用 `--force`：不写 memory、不推进检查点（便于攒够一批再摘要，减轻“零星一句反复摘要”）。**`--force` 时忽略本条**，仍要求有 ≥1 条新增才会写内容（0 条仍会早退）。

### 4.5 本地与云端摘要（`analyzer.*`）

| 配置 | 作用 |
|:---|:---|
| `messages_to_analyze` | **本地关键词提取**与**非分块时云端**默认只处理合并后 **尾部 N 条**（本周期新增流上的尾部）。 |
| `chunk_cloud_summary` | **`true`（推荐）**：若本周期新增条数 **&gt; `messages_to_analyze`**，按每段 N 条 **顺序**多次调用云端摘要，减少“只摘要尾部、前面丢失”。 |
| `max_cloud_summary_chunks` | 云端最多段数；超出时 **只摘要时间上较新的若干段**，更旧的新增可能未进 LLM，日志 **`[WARN]`**；检查点仍按 **本批全部新增**推进（若已写 memory）。 |
| `cloud_summarizer.enabled` | 是否调用云端；关闭时仅本地提取。 |

### 4.6 冷却（`archive.threshold.cooldown_minutes`）

- 仅在 **`threshold`** 模式且 **`--force` 未开启**时生效：若与 **上次写入** 的 `usage_tokens` 相同且在冷却时间内，**跳过本次 memory 写入**，但仍可执行 **compact**。

### 4.7 Compact（`archive.compact`）

| 配置 | 作用 |
|:---|:---|
| `compact.max_lines` | 传给 Gateway `sessions.compact` 的 `maxLines`（默认 400）。 |
| `compact_only_over_threshold` | **`true`（默认）**：仅对用量 **≥ `max_input_tokens`** 的 key 调用 compact；**`false`** 则对每个 merge 中的 key 都调用（与 v1.3 前行为接近）。 |

`openclaw gateway call` 需 **设备配对**；遇 `pairing required` 见 **第 5 节**。

### 4.8 配置示例（与实现对齐）

```yaml
openclaw:
  agent_id: main

session:
  key: ""
  merge_jsonl_keys:
    - "agent:main:main"

archive:
  trigger_mode: "threshold"
  threshold:
    max_input_tokens: 200000
    check_interval_minutes: 5
    cooldown_minutes: 45
  min_new_messages: 1
  compact_only_over_threshold: true
  compact:
    max_lines: 400

analyzer:
  messages_to_analyze: 50
  chunk_cloud_summary: true
  max_cloud_summary_chunks: 20
  cloud_summarizer:
    enabled: true

logging:
  log_max_bytes: 10485760
  log_keep_rotations: 5
  log_max_age_days: 30

output:
  memory_dir: "~/.openclaw/workspace/memory"

skill_version: "1.4.0"
config_version: "6"
```

### 4.9 日志轮转与清理

每次 **`archive` 开头**会执行：先按 **`log_max_age_days`** 删除过期**轮转备份**（`日志名.1`、`.2`…），再判断当前日志是否超过 **`log_max_bytes`**，若超过则链式重命名并保留 **`log_keep_rotations`** 个备份。当前活动日志不会被按天龄删除。

- **`log_max_bytes: 0`**：关闭按大小轮转。
- **`log_max_age_days: 0`**：关闭按天龄删除。

仅做日志维护、不跑归档：

```bash
bash ~/.openclaw/skills/daily-memory-archiver/scripts/archive-engine.sh log-maintenance
~/.openclaw/skills/daily-memory-archiver/bin/daily-memory-archiver logs
```

工程结构、实现文件与维护清单见仓库根目录 **[README.md](./README.md)**。

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

Gateway 在 transcript **行数 ≤ max_lines（默认 400）** 时返回 **`compacted: false`**，属正常，表示未因超限而截断/压缩文件。

## 7. 环境变量摘要

| 变量 | 作用 |
|:---|:---|
| `OPENCLAW_HOME` | 默认 `~/.openclaw` |
| `OPENCLAW_AGENT_ID` | 覆盖 agent |
| `SESSIONS_JSON` | 显式 sessions.json 路径 |
| `DAILY_MEMORY_CONFIG_DIR` | skill `config/` |
| `DAILY_MEMORY_MEMORY_DIR` | memory 输出目录 |
| `DAILY_MEMORY_LOG` | 日志路径 |
| `DAILY_MEMORY_LOG_MAX_BYTES` | 覆盖 `logging.log_max_bytes`（字节，`0` 关闭轮转） |
| `DAILY_MEMORY_LOG_KEEP_ROTATIONS` | 覆盖 `logging.log_keep_rotations` |
| `DAILY_MEMORY_LOG_MAX_AGE_DAYS` | 覆盖 `logging.log_max_age_days`（`0` 关闭按天龄删备份） |
| `DAILY_MEMORY_MERGE_KEYS` | 覆盖 merge 列表 |
| `SKIP_SESSION_COMPACT` / `OPENCLAW_SKIP_COMPACT` | `1` 跳过 compact |
| `ARCHIVE_MODE` | 与向导生成 YAML 相关 |
| `MESSAGES_TO_ANALYZE` / `THRESHOLD_INPUT_TOKENS` 等 | 见 `config-manager` 模板 |

## 8. 脚本索引

| 路径 | 说明 |
|:---|:---|
| `scripts/archive-engine.sh` | `archive …`、`log-maintenance` |
| `scripts/config-manager.sh` | `init-defaults`、`save-json`、`merge-jsonl-keys-*`、`status`、`show` |
| `scripts/get-cloud-creds.sh` | JSON / `--export` |
| `scripts/extractors/local-extractor.sh` | 本地四类关键词块 |
| `scripts/summarizers/cloud-summarizer.sh` | OpenAI 兼容 Chat Completions |
| `scripts/lib/credentials-store.sh` | 加解密 |
| `scripts/lib/log-maintenance.sh` | 日志天龄清理与链式轮转 |
| `scripts/self-check.sh` | 自检 |
| `bin/daily-memory-archiver` | `archive`、`logs` 等快捷入口 |
| `README.md` | 维护者：目录、配置、扩展清单 |

## 9. 重载 Skill

修改 `SKILL.md` 后请 **新开会话** 或 `openclaw skills check`，并用 **read** 重新加载本文。

---

*Made for OpenClaw.*
