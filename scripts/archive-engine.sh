#!/usr/bin/env bash
# Daily Memory Archiver：读 sessions.json → 合并 jsonl（可选）→ 提取 → 云端摘要 → memory → sessions.compact
# 用法: archive-engine.sh archive [--force] [--session <key>] [--agent <id>]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_DIR="${DAILY_MEMORY_CONFIG_DIR:-$SKILL_ROOT/config}"
export CONFIG_DIR
CONFIG_FILE="$CONFIG_DIR/config.yaml"
LOCK_FILE="$CONFIG_DIR/.archive.lock"
OPENCLAW_HOME="${OPENCLAW_HOME:-$HOME/.openclaw}"
LOG_FILE="${DAILY_MEMORY_LOG:-$OPENCLAW_HOME/logs/daily-memory-archiver.log}"

LOCAL_EXTRACTOR="$SCRIPT_DIR/extractors/local-extractor.sh"
CLOUD_SUMMARIZER="$SCRIPT_DIR/summarizers/cloud-summarizer.sh"
GET_CREDS="$SCRIPT_DIR/get-cloud-creds.sh"

mkdir -p "$(dirname "$LOG_FILE")"
mkdir -p "$CONFIG_DIR"
export PATH="/usr/local/bin:/usr/bin:/bin:${PATH:-}"

log() {
    local line="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    printf '%s\n' "$line" >>"$LOG_FILE"
    printf '%s\n' "$line" >&2
}

rotate_log_if_needed() {
    local max_bytes="${DAILY_MEMORY_LOG_MAX_BYTES:-0}"
    [ "$max_bytes" -gt 0 ] 2>/dev/null || return 0
    [ -f "$LOG_FILE" ] || return 0
    local sz
    sz=$(wc -c <"$LOG_FILE" 2>/dev/null || echo 0)
    [ "$sz" -gt "$max_bytes" ] 2>/dev/null || return 0
    mv "$LOG_FILE" "${LOG_FILE}.1"
    log "[INFO] 日志已轮转（超过 DAILY_MEMORY_LOG_MAX_BYTES=$max_bytes）"
}

expand_tilde() {
    local p="$1"
    case "$p" in
        "~"|"~"/*) printf '%s\n' "${p/\~/$HOME}" ;;
        *) printf '%s\n' "$p" ;;
    esac
}

yaml_scalar() {
    local key="$1"
    grep -E "^[[:space:]]*${key}:" "$CONFIG_FILE" 2>/dev/null | head -1 | \
        sed -E "s/^[[:space:]]*${key}:[[:space:]]*//" | \
        sed -E 's/^["'\'']//;s/["'\'']$//;s/[[:space:]]*$//;s/#.*$//'
}

cloud_summarizer_enabled() {
    [ -f "$CONFIG_FILE" ] || return 1
    awk '
      /^analyzer:/ { ina=1; next }
      ina && /^[a-z]/ && !/^analyzer/ { exit }
      ina && /^[[:space:]]+cloud_summarizer:/ { inc=1; next }
      inc && /^[[:space:]]+enabled:[[:space:]]*true/ { found=1; exit }
      inc && /^[[:space:]]+[a-z_]+:/ && !/^([[:space:]]+enabled:)/ { inc=0 }
      END { exit found ? 0 : 1 }
    ' "$CONFIG_FILE"
}

load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        log "[WARN] 缺少 $CONFIG_FILE，执行 init-defaults …"
        bash "$SCRIPT_DIR/config-manager.sh" init-defaults >>"$LOG_FILE" 2>&1 || {
            log "[ERROR] init-defaults 失败"
            return 1
        }
    fi
    AGENT_ID="${OPENCLAW_AGENT_ID:-$(yaml_scalar agent_id)}"
    [ -n "$AGENT_ID" ] || AGENT_ID="main"

    SESSION_KEY_CFG=$(grep -E '^session:' -A30 "$CONFIG_FILE" | grep -E '^[[:space:]]+key:' | head -1 | \
        sed -E 's/^[[:space:]]*key:[[:space:]]*//;s/^["'\'']//;s/["'\'']$//;s/[[:space:]]*$//') || true

    TRIGGER_MODE="$(yaml_scalar trigger_mode)"
    [ -n "$TRIGGER_MODE" ] || TRIGGER_MODE="threshold"
    MAX_INPUT_TOKENS="$(yaml_scalar max_input_tokens)"
    [ -n "$MAX_INPUT_TOKENS" ] || MAX_INPUT_TOKENS="${THRESHOLD_INPUT_TOKENS:-200000}"
    CHECK_INTERVAL_MINUTES="$(yaml_scalar check_interval_minutes)"
    [ -n "$CHECK_INTERVAL_MINUTES" ] || CHECK_INTERVAL_MINUTES="5"
    COOLDOWN_MINUTES="$(yaml_scalar cooldown_minutes)"
    [ -n "$COOLDOWN_MINUTES" ] || COOLDOWN_MINUTES="45"
    COMPACT_MAX_LINES="$(yaml_scalar max_lines)"
    [ -n "$COMPACT_MAX_LINES" ] || COMPACT_MAX_LINES="400"
    MESSAGES_TO_ANALYZE="$(yaml_scalar messages_to_analyze)"
    [ -n "$MESSAGES_TO_ANALYZE" ] || MESSAGES_TO_ANALYZE="50"

    if [ -n "${DAILY_MEMORY_MEMORY_DIR:-}" ]; then
        MEMORY_DIR="$(expand_tilde "$DAILY_MEMORY_MEMORY_DIR")"
    else
        MEMORY_DIR_RAW="$(yaml_scalar memory_dir)"
        [ -n "$MEMORY_DIR_RAW" ] || MEMORY_DIR_RAW="${MEMORY_DIR:-$OPENCLAW_HOME/workspace/memory}"
        MEMORY_DIR="$(expand_tilde "$MEMORY_DIR_RAW")"
    fi

    SESSIONS_JSON="${SESSIONS_JSON:-$OPENCLAW_HOME/agents/$AGENT_ID/sessions/sessions.json}"
}

resolve_session_key() {
    if [ -n "${CLI_SESSION_KEY:-}" ]; then
        SESSION_KEY="$CLI_SESSION_KEY"
        return
    fi
    if [ -n "${SESSION_KEY_CFG:-}" ] && [ "$SESSION_KEY_CFG" != '""' ] && [ -n "$(echo "$SESSION_KEY_CFG" | tr -d '[:space:]')" ]; then
        SESSION_KEY="$SESSION_KEY_CFG"
        return
    fi
    SESSION_KEY="agent:${AGENT_ID}:main"
}

load_merge_session_keys() {
    SESSION_MERGE_KEYS=()
    if [ -n "${DAILY_MEMORY_MERGE_KEYS:-}" ]; then
        IFS=',' read -ra SESSION_MERGE_KEYS <<<"$DAILY_MEMORY_MERGE_KEYS"
        local _i
        for _i in "${!SESSION_MERGE_KEYS[@]}"; do
            SESSION_MERGE_KEYS[$_i]=$(echo "${SESSION_MERGE_KEYS[$_i]}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        done
        return
    fi
    [ -f "$CONFIG_FILE" ] || { SESSION_MERGE_KEYS=("$SESSION_KEY"); return; }
    local line
    while IFS= read -r line; do
        [ -n "$line" ] && SESSION_MERGE_KEYS+=("$line")
    done < <(awk '
        /^session:/ { ins=1; next }
        ins && /^[a-z][a-z0-9_]*:/ && !/^session/ { ins=0 }
        ins && /^[[:space:]]+merge_jsonl_keys:/ { inlist=1; next }
        inlist && /^[[:space:]]+-[[:space:]]/ {
            line=$0
            sub(/^[[:space:]]+-[[:space:]]+/, "", line)
            gsub(/^["'\'']|["'\'']$/, "", line)
            if (line != "") print line
            next
        }
        inlist && /^[[:space:]]+[a-zA-Z_][a-zA-Z0-9_.-]*:/ && !/^([[:space:]]+-)/ { inlist=0 }
    ' "$CONFIG_FILE")
    if [ ${#SESSION_MERGE_KEYS[@]} -eq 0 ]; then
        SESSION_MERGE_KEYS=("$SESSION_KEY")
    fi
}

resolve_usage_tokens() {
    local blob="$1"
    echo "$blob" | jq -r '
        if (.totalTokensFresh == false) then (.inputTokens // 0)
        else (.totalTokens // .inputTokens // 0) end
    '
}

jsonl_to_messages_json() {
    local f="$1"
    jq -s '
      map(select(.type == "message" and (.message.role == "user" or .message.role == "assistant")))
      | map({
          role: .message.role,
          content: (.message.content
            | if type == "string" then .
              elif type == "array" then (map(select(.type == "text") | .text) | join("\n"))
              else "" end)
        })
      | map(select(.content != null and (.content | length) > 0))
    ' <"$f"
}

merged_jsonl_to_messages_json() {
    local tmpdir sk f part_files i do_prefix
    tmpdir=$(mktemp -d)
    part_files=()
    i=0
    while [ "$#" -ge 2 ]; do
        sk="$1"
        f="$2"
        shift 2
        [ -f "$f" ] || continue
        jq -s --arg sk "$sk" '
          map(select(.type == "message" and (.message.role == "user" or .message.role == "assistant")))
          | map({
              ts: (.timestamp // ""),
              role: .message.role,
              content: (.message.content
                | if type == "string" then .
                  elif type == "array" then (map(select(.type == "text") | .text) | join("\n"))
                  else "" end),
              sk: $sk
            })
          | map(select(.content != null and (.content | length) > 0))
        ' "$f" >"$tmpdir/p${i}.json"
        part_files+=("$tmpdir/p${i}.json")
        i=$((i + 1))
    done
    if [ ${#part_files[@]} -eq 0 ]; then
        rm -rf "$tmpdir"
        echo '[]'
        return
    fi
    do_prefix=false
    [ ${#part_files[@]} -gt 1 ] && do_prefix=true
    jq -s --argjson prefix "$do_prefix" '
      add
      | sort_by(.ts)
      | map(
          if $prefix then .content = ("[" + .sk + "] " + .content) else . end
          | {role, content}
        )
    ' "${part_files[@]}"
    rm -rf "$tmpdir"
}

should_run_archive() {
    FORCE_RUN="${FORCE_RUN:-0}"
    [ "$FORCE_RUN" = "1" ] && return 0
    case "$TRIGGER_MODE" in
        scheduled) return 0 ;;
        hybrid)
            if [ "$USAGE_TOKENS" -ge "$MAX_INPUT_TOKENS" ] 2>/dev/null; then return 0; fi
            if [ -f "$CONFIG_DIR/.last_archive_ts" ]; then
                local last now diff
                last=$(cat "$CONFIG_DIR/.last_archive_ts")
                now=$(date +%s)
                diff=$(( (now - last) / 60 ))
                [ "$diff" -ge "$CHECK_INTERVAL_MINUTES" ] && return 0
            else
                return 0
            fi
            log "[INFO] hybrid：未达阈值且未到间隔，跳过"
            return 1
            ;;
        threshold|*)
            if [ "$USAGE_TOKENS" -ge "$MAX_INPUT_TOKENS" ] 2>/dev/null; then return 0; fi
            log "[INFO] threshold：用量 $USAGE_TOKENS < $MAX_INPUT_TOKENS，跳过（可用 --force）"
            return 1
            ;;
    esac
}

cooldown_blocks_write() {
    FORCE_RUN="${FORCE_RUN:-0}"
    [ "$FORCE_RUN" = "1" ] && return 1
    [ "$TRIGGER_MODE" = "threshold" ] || return 1
    [ "${COOLDOWN_MINUTES:-0}" -gt 0 ] 2>/dev/null || return 1
    [ -f "$CONFIG_DIR/.last_archive_meta.json" ] || return 1
    local last_usage last_ts now diff
    last_usage=$(jq -r '.usage_tokens // empty' "$CONFIG_DIR/.last_archive_meta.json" 2>/dev/null || echo "")
    last_ts=$(jq -r '.ts // 0' "$CONFIG_DIR/.last_archive_meta.json" 2>/dev/null || echo "0")
    [ -n "$last_usage" ] || return 1
    [ "$last_usage" = "$USAGE_TOKENS" ] || return 1
    now=$(date +%s)
    diff=$(( (now - last_ts) / 60 ))
    if [ "$diff" -lt "$COOLDOWN_MINUTES" ]; then
        log "[INFO] 冷却中（${diff}m < ${COOLDOWN_MINUTES}m）且用量未变，跳过 memory 写入（仍尝试 compact）"
        return 0
    fi
    return 1
}

run_compact() {
    if [ "${SKIP_SESSION_COMPACT:-0}" = "1" ] || [ "${OPENCLAW_SKIP_COMPACT:-0}" = "1" ]; then
        log "[INFO] 已跳过 sessions.compact（环境变量）"
        return 0
    fi
    command -v openclaw >/dev/null 2>&1 || {
        log "[WARN] 未找到 openclaw CLI，跳过 compact"
        return 0
    }
    local _ck
    for _ck in "${MERGE_PAIR_KEYS[@]}"; do
        run_compact_one "$_ck"
    done
}

run_compact_one() {
    local compact_target_key="${1:?}"
    [ "${SKIP_SESSION_COMPACT:-0}" = "1" ] && return 0
    command -v openclaw >/dev/null 2>&1 || return 0
    if [ -z "${HOME:-}" ]; then
        HOME="$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f6)"
        export HOME
    fi
    [ -z "${HOME:-}" ] && export HOME="/tmp"
    export OPENCLAW_HOME="${OPENCLAW_HOME:-$HOME/.openclaw}"
    local gw_token gw_extra params compact_log
    gw_token="${OPENCLAW_GATEWAY_TOKEN:-${GATEWAY_TOKEN:-}}"
    [ -z "$gw_token" ] && [ -f "$OPENCLAW_HOME/openclaw.json" ] && \
        gw_token=$(jq -r '.gateway.auth.token // empty' "$OPENCLAW_HOME/openclaw.json" 2>/dev/null || true)
    gw_extra=()
    [ -n "$gw_token" ] && [ "$gw_token" != "null" ] && gw_extra=(--token "$gw_token")
    params=$(jq -n --arg k "$compact_target_key" --argjson m "${COMPACT_MAX_LINES:-400}" '{key:$k, maxLines:$m}')
    compact_log=$(mktemp)
    if openclaw gateway call sessions.compact --params "$params" --json --expect-final "${gw_extra[@]}" >"$compact_log" 2>&1; then
        cat "$compact_log" >>"$LOG_FILE"
        if jq -e '.ok == true' "$compact_log" >/dev/null 2>&1; then
            local c k r extra
            c=$(jq -r '.compacted // "?"' "$compact_log")
            k=$(jq -r '.kept // empty' "$compact_log")
            r=$(jq -r '.reason // empty' "$compact_log")
            extra=""
            [ -n "$r" ] && extra=" reason=$r"
            log "[INFO] sessions.compact[$compact_target_key]：compacted=$c kept=${k:-?} maxLines=$COMPACT_MAX_LINES$extra"
        else
            log "[INFO] sessions.compact 已调用（非标准 JSON，见日志）"
        fi
        rm -f "$compact_log"
    else
        cat "$compact_log" >>"$LOG_FILE"
        grep -qi 'pairing required' "$compact_log" 2>/dev/null && \
            log "[HINT] pairing required：见 SKILL.md §3.7（devices approve）；cron 需 HOME/OPENCLAW_HOME/PATH"
        rm -f "$compact_log"
        log "[WARN] sessions.compact 失败；memory 可能已写入"
    fi
}

do_archive() {
    rotate_log_if_needed
    load_config || exit 1
    resolve_session_key
    load_merge_session_keys
    [ -n "${CLI_SESSION_KEY:-}" ] && SESSION_MERGE_KEYS=("$CLI_SESSION_KEY") && SESSION_KEY="$CLI_SESSION_KEY"

    [ -f "$SESSIONS_JSON" ] || {
        log "[ERROR] 无 sessions.json: $SESSIONS_JSON"
        exit 1
    }

    MERGE_PAIR_KEYS=()
    MERGE_PAIR_PATHS=()
    local sk entry jsonl u rep_entry
    for sk in "${SESSION_MERGE_KEYS[@]}"; do
        entry=$(jq -c --arg sk "$sk" '.[$sk] // empty' "$SESSIONS_JSON")
        [ -z "$entry" ] && {
            log "[WARN] 无此 session key，跳过: $sk"
            continue
        }
        jsonl=$(echo "$entry" | jq -r '.sessionFile // empty')
        [ -n "$jsonl" ] && [ -f "$jsonl" ] || {
            log "[WARN] sessionFile 无效，跳过: $sk"
            continue
        }
        MERGE_PAIR_KEYS+=("$sk")
        MERGE_PAIR_PATHS+=("$jsonl")
    done
    [ ${#MERGE_PAIR_KEYS[@]} -gt 0 ] || {
        log "[ERROR] 无可用 jsonl（列表: ${SESSION_MERGE_KEYS[*]}）"
        exit 1
    }

    USAGE_TOKENS=0
    rep_entry=""
    for sk in "${MERGE_PAIR_KEYS[@]}"; do
        entry=$(jq -c --arg sk "$sk" '.[$sk] // empty' "$SESSIONS_JSON")
        u=$(resolve_usage_tokens "$entry")
        if [ "${u:-0}" -ge "${USAGE_TOKENS:-0}" ] 2>/dev/null; then
            USAGE_TOKENS=$u
            rep_entry="$entry"
        fi
    done
    [ -n "$rep_entry" ] || rep_entry=$(jq -c --arg sk "${MERGE_PAIR_KEYS[0]}" '.[$sk] // empty' "$SESSIONS_JSON")

    INPUT_TOKENS_RAW=$(echo "$rep_entry" | jq -r '.inputTokens // 0')
    TOTAL_TOKENS_RAW=$(echo "$rep_entry" | jq -r '.totalTokens // 0')
    TOTAL_FRESH=$(echo "$rep_entry" | jq -r '.totalTokensFresh // false')
    SESSION_MERGE_LABEL=$(IFS=','; echo "${MERGE_PAIR_KEYS[*]}")

    log "[INFO] session_merge=[$SESSION_MERGE_LABEL] usage=$USAGE_TOKENS(max) input=$INPUT_TOKENS_RAW total=$TOTAL_TOKENS_RAW fresh=$TOTAL_FRESH trigger=$TRIGGER_MODE"

    local skip_write=0
    should_run_archive || exit 0
    cooldown_blocks_write && skip_write=1

    local merge_args messages_all msg_count messages_slice _i
    merge_args=()
    for _i in "${!MERGE_PAIR_KEYS[@]}"; do
        merge_args+=("${MERGE_PAIR_KEYS[$_i]}" "${MERGE_PAIR_PATHS[$_i]}")
    done
    messages_all=$(merged_jsonl_to_messages_json "${merge_args[@]}")
    msg_count=$(echo "$messages_all" | jq 'length')
    if [ "${msg_count:-0}" -eq 0 ]; then
        log "[WARN] 无 user/assistant 消息，跳过内容归档"
        run_compact
        exit 0
    fi
    messages_slice=$(echo "$messages_all" | jq --argjson take "$MESSAGES_TO_ANALYZE" '.[-($take):]')

    local insights cloud_block trigger_reason
    if [ "${FORCE_RUN:-0}" = "1" ]; then trigger_reason="手动强制归档"
    elif [ "$TRIGGER_MODE" = "scheduled" ]; then trigger_reason="定时 / scheduled"
    elif [ "$TRIGGER_MODE" = "hybrid" ]; then
        [ "$USAGE_TOKENS" -ge "$MAX_INPUT_TOKENS" ] 2>/dev/null && trigger_reason="hybrid 阈值" || trigger_reason="hybrid 间隔"
    else trigger_reason="达到阈值"
    fi

    insights=""
    cloud_block=""
    if [ "$skip_write" = "0" ]; then
        insights=$("$LOCAL_EXTRACTOR" - <<<"$messages_slice" "$MESSAGES_TO_ANALYZE" || true)
        if cloud_summarizer_enabled && [ -f "$CONFIG_DIR/credentials.enc" ]; then
            local tmp_plain api_url api_tok model_id
            tmp_plain=$(mktemp)
            chmod 600 "$tmp_plain"
            echo "$messages_slice" | jq -r '.[] | "\(.role): \(.content)"' >"$tmp_plain"
            if API_JSON=$("$GET_CREDS" 2>>"$LOG_FILE"); then
                api_url=$(echo "$API_JSON" | jq -r .api_url)
                api_tok=$(echo "$API_JSON" | jq -r .api_token)
                model_id=$(echo "$API_JSON" | jq -r .model)
                if [ -z "$api_url" ] || [ "$api_url" = "null" ] || [ -z "$api_tok" ] || [ "$api_tok" = "null" ] || [ -z "$model_id" ] || [ "$model_id" = "null" ]; then
                    cloud_block="- *（凭证字段不完整，请 save-json）*"
                elif cloud_out=$("$CLOUD_SUMMARIZER" --file "$tmp_plain" "openai-compatible" "$model_id" "$api_url" "$api_tok" 2>>"$LOG_FILE"); then
                    cloud_block=$cloud_out
                else
                    cloud_block="- *（云端摘要失败，见日志）*"
                fi
            else
                cloud_block="- *（get-cloud-creds 失败；检查 .master_key 与 credentials.enc）*"
            fi
            rm -f "$tmp_plain"
        elif cloud_summarizer_enabled; then
            cloud_block="- *（无 credentials.enc）*"
        else
            cloud_block="- *（云端摘要已关闭）*"
        fi

        mkdir -p "$MEMORY_DIR"
        local day fpath ts_local
        day=$(date +%Y-%m-%d)
        fpath="$MEMORY_DIR/${day}.md"
        ts_local=$(date '+%Y-%m-%d %H:%M:%S')
        if [ ! -s "$fpath" ]; then
            {
                echo "# ${day} - Daily Memory"
                echo ""
                echo "## 元数据"
                echo "- **创建**: $ts_local"
                echo "- **Daily Memory Archiver**"
                echo ""
                echo "## 详细记录"
                echo ""
            } >>"$fpath"
        fi
        {
            echo ""
            echo "### 自动归档 - $ts_local"
            echo ""
            echo "#### 会话元数据"
            echo "| 属性 | 值 |"
            echo "|:---|:---|"
            echo "| **Session Key(s)** | $SESSION_MERGE_LABEL |"
            echo "| **Agent** | $AGENT_ID |"
            echo "| **上下文用量** | $USAGE_TOKENS（totalTokens 优先，totalTokensFresh=$TOTAL_FRESH；input=$INPUT_TOKENS_RAW） |"
            echo "| **触发** | $ts_local |"
            echo "| **原因** | $trigger_reason |"
            echo "| **trigger_mode** | $TRIGGER_MODE |"
            echo "| **分析条数** | $MESSAGES_TO_ANALYZE |"
            echo ""
            echo "$insights"
            echo "---"
            echo ""
            echo "#### 云端 LLM 摘要"
            echo ""
            echo "$cloud_block"
            echo ""
            echo "---"
            echo ""
            echo "#### 归档动作"
            echo "- [x] Daily Memory 归档 / 本地提取 / 云端摘要 / compact 调用"
            echo ""
        } >>"$fpath"
        date +%s >"$CONFIG_DIR/.last_archive_ts"
        jq -n --arg sk "$SESSION_MERGE_LABEL" --argjson u "$USAGE_TOKENS" --argjson ts "$(date +%s)" \
            '{session_key:$sk, usage_tokens:$u, ts:$ts}' >"$CONFIG_DIR/.last_archive_meta.json"
        log "[INFO] 已写入 $fpath"
    else
        log "[INFO] 跳过 memory（冷却）"
    fi
    run_compact
}

with_lock() {
    if command -v flock >/dev/null 2>&1; then
        flock -n 9 || {
            log "[WARN] 另一实例运行中"
            exit 0
        }
    fi
    "$@"
}

main_cli() {
    local cmd="${1:-}"
    shift || true
    FORCE_RUN=0
    CLI_SESSION_KEY=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --force) FORCE_RUN=1 ;;
            --session) CLI_SESSION_KEY="${2:?}"; shift ;;
            --agent) OPENCLAW_AGENT_ID="${2:?}"; shift ;;
            -h|--help) cmd=help ;;
            *) ;;
        esac
        shift
    done
    case "$cmd" in
        archive|"")
            exec 9>>"$LOCK_FILE"
            with_lock do_archive
            ;;
        help)
            echo "Usage: $0 archive [--force] [--session <key>] [--agent <id>]"
            echo "多通道: session.merge_jsonl_keys 或 DAILY_MEMORY_MERGE_KEYS"
            echo "日志轮转: DAILY_MEMORY_LOG_MAX_BYTES（字节）"
            ;;
        *)
            echo "Unknown: $cmd" >&2
            exit 2
            ;;
    esac
}

main_cli "$@"
