# Daily Memory Archiver

OpenClaw 会话归档 Skill：多 session 按时间合并、检查点增量、本地关键词提取、可选云端 LLM 摘要、按 key 用量触发与选择性 `sessions.compact`。

**面向维护者**：本文描述仓库布局、配置键、入口脚本与扩展点。面向 Cursor / 助手的交互说明见根目录 **[SKILL.md](./SKILL.md)**（安装、配对、cron 等）。

## 版本与兼容

- 实现与 **SKILL.md** 中 `skill_version` / `config.yaml` 中 `config_version` 应对齐；以脚本行为为准。
- Shell：**bash 4+**（使用关联数组 `declare -A`）。

## 仓库布局

| 路径 | 说明 |
|:---|:---|
| `SKILL.md` | Cursor Skill 元数据与用户向文档（必读入口） |
| `README.md` | 本文件：工程与维护说明 |
| `config/config.yaml` | 主配置（无密钥） |
| `config/credentials.enc` | 云端 API 加密凭证（勿提交） |
| `config/.master_key` | 解密用（勿提交） |
| `config/.archive_merge_checkpoint.json` | 各 key 最后已归档消息时间戳（运行时生成，勿提交） |
| `bin/daily-memory-archiver` | CLI 包装：`init`、`archive`、`logs`、`check`、`status`、`creds` |
| `scripts/archive-engine.sh` | 核心：`archive`、`log-maintenance` |
| `scripts/config-manager.sh` | `init-defaults`、`save-json`、merge keys、`status`/`show` |
| `scripts/get-cloud-creds.sh` | 解密并输出 JSON（api_url / api_token / model） |
| `scripts/lib/log-maintenance.sh` | 日志按天龄删除轮转备份、按大小链式轮转 |
| `scripts/lib/credentials-store.sh` | OpenSSL 加解密 |
| `scripts/lib/conversation-noise.sh` | 本地提取噪声过滤 |
| `scripts/extractors/local-extractor.sh` | stdin JSON 消息 → Markdown 块 |
| `scripts/summarizers/cloud-summarizer.sh` | OpenAI 兼容 Chat Completions |
| `scripts/self-check.sh` | 依赖与 `bash -n` |

## 主流程（`archive-engine.sh archive`）

1. `load_config`：读 `config.yaml` + 环境变量覆盖。
2. `run_log_maintenance`：天龄清理 → 按大小轮转（见下节）。
3. 解析 `merge_jsonl_keys` / `DAILY_MEMORY_MERGE_KEYS`，读 `sessions.json` 与各 session jsonl。
4. 阈值 / hybrid / scheduled 判断是否继续。
5. `merged_jsonl_new_messages_json`：按检查点过滤后跨 key 按 `timestamp` 合并。
6. `min_new_messages`、空新增早退；冷却可跳过 memory 写入。
7. 本地提取、`cloud-summarizer`（可分块）、追加 `memory/YYYY-MM-DD.md`，更新检查点与 meta。
8. `sessions.compact`（可选仅超限 key）。

## 日志清理与轮转

默认日志路径：`$OPENCLAW_HOME/logs/daily-memory-archiver.log`（可用 `DAILY_MEMORY_LOG` 覆盖）。

| 配置项（`config.yaml` → `logging`） | 环境变量（优先于 YAML） | 含义 |
|:---|:---|:---|
| `log_max_bytes` | `DAILY_MEMORY_LOG_MAX_BYTES` | 当前日志超过该字节则轮转；**`0` 表示不按大小轮转** |
| `log_keep_rotations` | `DAILY_MEMORY_LOG_KEEP_ROTATIONS` | 保留备份个数 `.1` … `.N`（默认 5） |
| `log_max_age_days` | `DAILY_MEMORY_LOG_MAX_AGE_DAYS` | 删除**轮转备份** `$(basename).*` 中**早于**该天数的文件；**`0` 表示不按天龄删除**（不删当前活动日志） |

行为顺序：先按天龄删旧备份，再判断当前文件是否超 `log_max_bytes` 并链式重命名。

**单独执行维护**（不跑归档）：

```bash
bash scripts/archive-engine.sh log-maintenance
# 或
./bin/daily-memory-archiver logs
```

可与 cron 低频搭配（例如每日一次），与每次 `archive` 内嵌维护二选一或并存均可。

实现文件：`scripts/lib/log-maintenance.sh`。

## 配置速查（扁平 `yaml_scalar`）

脚本用 `grep '^[[:space:]]*key:'` 式读取，键名在全文应唯一。常用键：

- `openclaw`：`agent_id`
- `session`：`key`、`merge_jsonl_keys`（列表由 awk 解析）
- `archive`：`trigger_mode`、`max_input_tokens`、`check_interval_minutes`、`cooldown_minutes`、`min_new_messages`、`compact_only_over_threshold`、`max_lines`（compact）
- `analyzer`：`messages_to_analyze`、`chunk_cloud_summary`、`max_cloud_summary_chunks`、`cloud_summarizer.enabled`
- `logging`：`log_max_bytes`、`log_keep_rotations`、`log_max_age_days`
- `output`：`memory_dir`

## 环境变量（摘录）

| 变量 | 作用 |
|:---|:---|
| `OPENCLAW_HOME` | 默认 `~/.openclaw` |
| `DAILY_MEMORY_CONFIG_DIR` | skill `config/` |
| `DAILY_MEMORY_LOG` | 日志文件路径 |
| `DAILY_MEMORY_LOG_MAX_BYTES` 等 | 见上表 |
| `DAILY_MEMORY_MERGE_KEYS` | 逗号分隔覆盖 merge 列表 |
| `SKIP_SESSION_COMPACT` / `OPENCLAW_SKIP_COMPACT` | `1` 跳过 compact |

完整列表见 **SKILL.md** 第 7 节。

## 修改代码时的检查清单

1. `bash scripts/self-check.sh` 或 `bash -n` 相关脚本。
2. 新增 `config.yaml` 键：在 `load_config` 中读取，在 `config-manager.sh` 的 `save_config_yaml` 中写入默认值（若适用），并更新 **SKILL.md** / **README.md**。
3. 变更归档语义时同步 **SKILL.md**（用户向）与本 **README**（维护向）。
4. 密钥与运行时文件保持在 **`.gitignore`** 中。

## 许可证与上游

本仓库为 OpenClaw 生态下的 Skill；具体许可证以仓库根目录为准（若单独声明）。
