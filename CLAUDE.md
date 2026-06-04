# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**Daily Memory Archiver v1.6.0** - An OpenClaw Skill for archiving conversation sessions:
- Multi-session merging by timestamp with checkpoint-based incremental processing
- Local keyword extraction and optional cloud LLM summarization
- Per-session-key usage threshold triggering with selective `sessions.compact`
- Written in **bash 4+** (uses associative arrays)

## Common Commands

### Self-check & Validation
```bash
bash scripts/self-check.sh          # Check dependencies and syntax
bash -n scripts/<script-name>.sh    # Syntax check individual script
```

### Main Operations
```bash
# Archive (main entry point)
bash scripts/archive-engine.sh archive
bash scripts/archive-engine.sh archive --force              # Ignore threshold
bash scripts/archive-engine.sh archive --session <key>      # Single session
bash scripts/archive-engine.sh archive --agent <id>         # Specific agent

# Log maintenance only
bash scripts/archive-engine.sh log-maintenance
./bin/daily-memory-archiver logs

# CLI wrapper (preferred for interactive use)
./bin/daily-memory-archiver init --defaults
./bin/daily-memory-archiver archive
./bin/daily-memory-archiver status
./bin/daily-memory-archiver check
./bin/daily-memory-archiver creds
```

### Config Management
```bash
bash scripts/config-manager.sh init-defaults
bash scripts/config-manager.sh save-json              # Save encrypted credentials
bash scripts/config-manager.sh merge-jsonl-keys-add <key>
bash scripts/config-manager.sh merge-jsonl-keys-list
bash scripts/config-manager.sh status                 # Desensitized status
bash scripts/config-manager.sh show
```

### Credentials
```bash
bash scripts/get-cloud-creds.sh                       # Output decrypted JSON
bash scripts/get-cloud-creds.sh --export              # Export to env vars
```

### Interactive Configuration
```bash
bash scripts/skill-interactive.sh                     # Conversation-based setup wizard
```

## Code Architecture

### Core Execution Flow (`archive-engine.sh archive`)
1. **Config Loading** (`load_config`): Read `config.yaml` + environment variable overrides
2. **Log Maintenance**: Age-based pruning → size-based rotation (chain rename)
3. **Session Discovery**: Parse `merge_jsonl_keys`, read `sessions.json` and session jsonl files
4. **Trigger Decision**: threshold/hybrid/scheduled mode + optional `periodic_archive_minutes`
5. **Incremental Merge**: Cross-key merge by timestamp, filtered by checkpoint
6. **Guard Checks**: `min_new_messages`, empty early exit, cooldown skip
7. **Analysis & Output**: Local extraction, cloud summarization (chunkable), append to `memory/YYYY-MM-DD.md`
8. **Compact**: `sessions.compact` (only for threshold-exceeding keys by default)

**Trigger Modes** (`archive.trigger_mode`):
- `threshold`: Archive only when session usage exceeds thresholds
- `hybrid`: Threshold-based + periodic fallback via `periodic_archive_minutes`
- `scheduled`: Ignore thresholds, archive strictly on schedule

### Key Modules

| Module | Responsibility |
|:---|:---|
| `archive-engine.sh` | Orchestration, flow control, checkpoint management |
| `config-manager.sh` | Config initialization, credentials encryption, merge key management |
| `skill-interactive.sh` | OpenClaw dialog interaction entry (`status`, `warnings`, `add-noise-pattern`, etc.) |
| `lib/credentials-store.sh` | OpenSSL encryption/decryption layer |
| `lib/log-maintenance.sh` | Log rotation (by age + size) |
| `lib/conversation-noise.sh` | Context-aware noise filtering (removes system prompts, tool calls, etc.) for cleaner local extraction |
| `lib/config-loader.sh` | Unified config loading (`yaml_scalar`, `yaml_bool`, `config_load_all`, `config_get_status_json`, `config_get_warnings`)
| `extractors/local-extractor.sh` | Message JSON → Markdown keyword blocks |
| `summarizers/cloud-summarizer.sh` | OpenAI-compatible Chat Completions API (payload/response via temp files to avoid ARG_MAX) |
| `get-cloud-creds.sh` | Credentials decryption and export interface |
| `bin/daily-memory-archiver` | CLI user-friendly wrapper |

**Module Subdirectories**:
- `scripts/extractors/` - Local keyword and message extraction
- `scripts/summarizers/` - Cloud-based LLM summarization (chunkable for long context)

### Configuration Strategy
- **Public config**: `config/config.yaml` (agent_id, thresholds, intervals, logging)
- **Secrets**: `config/credentials.enc` (encrypted JSON: `api_url`, `api_token`, `model`)
- **Master key**: `config/.master_key` (gitignored)
- **Runtime state**: `config/.archive_merge_checkpoint.json`, `config/.last_archive_meta.json`, `config/.last_archive_ts`, `config/.archive.lock`

### Environment Variable Overrides
Critical ones to know:
- `DAILY_MEMORY_CONFIG_DIR` - Override config directory
- `DAILY_MEMORY_MERGE_KEYS` - Comma-separated session key list
- `DAILY_MEMORY_LOG_MAX_BYTES` / `LOG_KEEP_ROTATIONS` / `LOG_MAX_AGE_DAYS`
- `DAILY_MEMORY_MEMORY_DIR` - Override memory output directory
- `DAILY_MEMORY_PERIODIC_ARCHIVE_MINUTES` - Override periodic archive interval
- `SKIP_SESSION_COMPACT=1` / `OPENCLAW_SKIP_COMPACT=1` - Bypass compact operation
- `OPENCLAW_HOME` - Defaults to `~/.openclaw`

## Important Development Notes

1. **Config parsing**: Uses `grep` + `sed` for yaml scalar extraction via `yaml_scalar()` in `lib/config-loader.sh` (not a full YAML parser) — keep key names globally unique. List values (`merge_jsonl_keys`, `custom_patterns`) parsed by awk.
2. **Bash version**: Requires bash 4.x for associative arrays (`declare -A`)
3. **Gitignore**: `config/credentials.enc`, `config/.master_key`, `config/.archive_merge_checkpoint.json` must not be committed
4. **Dual documentation**:
   - `SKILL.md` - User-facing (installation, cron, pairing, migration)
   - `README.md` - Maintainer-facing (architecture, config keys, checklist)
5. **Lock file**: `archive` uses `flock -n` on `config/.archive.lock` for mutual exclusion; without `flock` available it proceeds without locking
6. **Memory output format**: Files in `memory/YYYY-MM-DD.md` follow KW SPEC v1.1: YAML frontmatter + `## HH:MM` time slots + `### 原始细节` (local-extractor 8-category output) + `### 摘要` (cloud-summarizer narrative + `[关键X]` tags). KW indexes only `### 摘要` for entities; `### 原始细节` is preserved for OpenClaw memory_search verbatim recall.
7. **Noise filtering**: `conversation-noise.sh` is context-aware — short heartbeat/tool lines are filtered, but longer messages or those containing discussion keywords are preserved. Custom patterns loaded from `config.yaml` `noise_filter.custom_patterns`
8. **Cloud summarizer**: Uses temp files for payload/response to avoid `ARG_MAX` overflow and `curl: (23)` pipe-write failures

## Code Change Checklist

When modifying code:
1. Run `bash scripts/self-check.sh` or `bash -n <script>` for syntax
2. New `config.yaml` keys need: `load_config` reading + `save_config_yaml` defaults + documentation update
3. Sync both `SKILL.md` and `README.md` for semantic changes
4. Verify secrets and runtime state files are in `.gitignore`

## Pairing for Compact

`openclaw gateway call` requires device pairing. On `pairing required` error:
```bash
export OPENCLAW_HOME="${OPENCLAW_HOME:-$HOME/.openclaw}"
export GW_TOKEN="$(jq -r '.gateway.auth.token // empty' "$OPENCLAW_HOME/openclaw.json")"
openclaw devices list --json --token "$GW_TOKEN"
openclaw devices approve --latest --token "$GW_TOKEN"
```
