#!/usr/bin/env bash
# Daily Memory Archiver：读 sessions.json → 合并 jsonl（可选）→ 提取 → 云端摘要 → memory → sessions.compact
# 用法: archive-engine.sh archive [--force] [--session <key>] [--agent <id>]
#       archive-engine.sh log-maintenance
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_DIR="${DAILY_MEMORY_CONFIG_DIR:-$SKILL_ROOT/config}"
export CONFIG_DIR
CONFIG_FILE="$CONFIG_DIR/config.yaml"
LOCK_FILE="$CONFIG_DIR/.archive.lock"
OPENCLAW_HOME="${OPENCLAW_HOME:-$HOME/.openclaw}"
LOG_FILE="${DAILY_MEMORY_LOG:-$OPENCLAW_HOME/logs/daily-memory-archiver.log}"

# shellcheck source=lib/log-maintenance.sh
source "$SCRIPT_DIR/lib/log-maintenance.sh"

LOCAL_EXTRACTOR="$SCRIPT_DIR/extractors/local-extractor.sh"
CLOUD_SUMMARIZER="$SCRIPT_DIR/summarizers/cloud-summarizer.sh"
GET_CREDS="$SCRIPT_DIR/get-cloud-creds.sh"

mkdir -p "$(dirname "$LOG_FILE")"
mkdir -p "$CONFIG_DIR"
export PATH="/usr/local/bin:/usr/bin:/bin:${PATH:-}"

log() {
    local line="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    printf '%s\n' "$line" >>"$LOG_FILE"
    # 仅当 stderr 是终端时再镜像一行，避免 crontab 里 `2>&1 >>…-cron.log` 与 LOG_FILE 双份相同内容
    if [ -t 2 ] 2>/dev/null; then
        printf '%s\n' "$line" >&2
    fi
}

run_log_maintenance() {
    local pruned
    pruned=$(daily_memory_prune_logs_by_age "$LOG_FILE" "${LOG_MAX_AGE_DAYS:-0}")
    if [ "${pruned:-0}" -gt 0 ] 2>/dev/null; then
        log "[INFO] 日志清理：按天龄删除 ${pruned} 个旧轮转文件（log_max_age_days=${LOG_MAX_AGE_DAYS:-0}）"
    fi
    if daily_memory_rotate_log_chain "$LOG_FILE" "${LOG_MAX_BYTES:-0}" "${LOG_KEEP_ROTATIONS:-5}"; then
        log "[INFO] 日志已按大小轮转（log_max_bytes=${LOG_MAX_BYTES:-0} log_keep_rotations=${LOG_KEEP_ROTATIONS:-5}）"
    fi
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

# 供 jq --argjson：必须为正整数 JSON，避免空串/非数字触发 invalid JSON
canonical_uint() {
    local v="${1:-}" d="${2:-0}"
    v=$(echo "$v" | tr -cd '0-9')
    case "$v" in
        ''|0) echo "$d" ;;
        *) echo "$((10#$v))" ;;
    esac
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
    MAX_INPUT_TOKENS=$(canonical_uint "$MAX_INPUT_TOKENS" 200000)
    CHECK_INTERVAL_MINUTES="$(yaml_scalar check_interval_minutes)"
    [ -n "$CHECK_INTERVAL_MINUTES" ] || CHECK_INTERVAL_MINUTES="5"
    CHECK_INTERVAL_MINUTES=$(canonical_uint "$CHECK_INTERVAL_MINUTES" 5)
    PERIODIC_ARCHIVE_MINUTES="$(yaml_scalar periodic_archive_minutes)"
    [ -n "${DAILY_MEMORY_PERIODIC_ARCHIVE_MINUTES:-}" ] && PERIODIC_ARCHIVE_MINUTES="${DAILY_MEMORY_PERIODIC_ARCHIVE_MINUTES}"
    PERIODIC_ARCHIVE_MINUTES=$(canonical_uint "${PERIODIC_ARCHIVE_MINUTES:-}" 0)
    COOLDOWN_MINUTES="$(yaml_scalar cooldown_minutes)"
    COOLDOWN_MINUTES=$(canonical_uint "$COOLDOWN_MINUTES" 45)
    COMPACT_MAX_LINES="$(yaml_scalar max_lines)"
    COMPACT_MAX_LINES=$(canonical_uint "$COMPACT_MAX_LINES" 400)
    MESSAGES_TO_ANALYZE="$(yaml_scalar messages_to_analyze)"
    MESSAGES_TO_ANALYZE=$(canonical_uint "$MESSAGES_TO_ANALYZE" 50)
    [ "$MESSAGES_TO_ANALYZE" -lt 1 ] && MESSAGES_TO_ANALYZE=50
    [ "$COMPACT_MAX_LINES" -lt 1 ] && COMPACT_MAX_LINES=400

    MIN_NEW_MESSAGES="$(yaml_scalar min_new_messages)"
    MIN_NEW_MESSAGES=$(canonical_uint "$MIN_NEW_MESSAGES" 1)
    [ "$MIN_NEW_MESSAGES" -lt 1 ] && MIN_NEW_MESSAGES=1

    MAX_CLOUD_SUMMARY_CHUNKS="$(yaml_scalar max_cloud_summary_chunks)"
    MAX_CLOUD_SUMMARY_CHUNKS=$(canonical_uint "$MAX_CLOUD_SUMMARY_CHUNKS" 20)
    [ "$MAX_CLOUD_SUMMARY_CHUNKS" -lt 1 ] && MAX_CLOUD_SUMMARY_CHUNKS=20

    CHUNK_CLOUD_RAW="$(yaml_scalar chunk_cloud_summary)"
    if [ -z "$CHUNK_CLOUD_RAW" ]; then
        CHUNK_CLOUD_SUMMARY=1
    else
        case "$(echo "$CHUNK_CLOUD_RAW" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')" in
            true|1|yes|on) CHUNK_CLOUD_SUMMARY=1 ;;
            *) CHUNK_CLOUD_SUMMARY=0 ;;
        esac
    fi

    COO_RAW="$(yaml_scalar compact_only_over_threshold)"
    if [ -z "$COO_RAW" ]; then
        COMPACT_ONLY_OVER_THRESHOLD=1
    else
        case "$(echo "$COO_RAW" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')" in
            false|0|no|off) COMPACT_ONLY_OVER_THRESHOLD=0 ;;
            *) COMPACT_ONLY_OVER_THRESHOLD=1 ;;
        esac
    fi

    MERGE_CHECKPOINT_FILE="$CONFIG_DIR/.archive_merge_checkpoint.json"

    LOG_MAX_BYTES="$(yaml_scalar log_max_bytes)"
    LOG_MAX_BYTES=$(canonical_uint "$LOG_MAX_BYTES" 0)
    [ -n "${DAILY_MEMORY_LOG_MAX_BYTES:-}" ] && LOG_MAX_BYTES=$(canonical_uint "${DAILY_MEMORY_LOG_MAX_BYTES}" 0)

    LOG_KEEP_ROTATIONS="$(yaml_scalar log_keep_rotations)"
    LOG_KEEP_ROTATIONS=$(canonical_uint "$LOG_KEEP_ROTATIONS" 5)
    [ "$LOG_KEEP_ROTATIONS" -lt 1 ] && LOG_KEEP_ROTATIONS=5
    [ -n "${DAILY_MEMORY_LOG_KEEP_ROTATIONS:-}" ] && LOG_KEEP_ROTATIONS=$(canonical_uint "${DAILY_MEMORY_LOG_KEEP_ROTATIONS}" 5)

    LOG_MAX_AGE_DAYS="$(yaml_scalar log_max_age_days)"
    LOG_MAX_AGE_DAYS=$(canonical_uint "$LOG_MAX_AGE_DAYS" 0)
    [ -n "${DAILY_MEMORY_LOG_MAX_AGE_DAYS:-}" ] && LOG_MAX_AGE_DAYS=$(canonical_uint "${DAILY_MEMORY_LOG_MAX_AGE_DAYS}" 0)

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

merge_checkpoint_get() {
    local sk="$1"
    [ -f "$MERGE_CHECKPOINT_FILE" ] || { echo ""; return; }
    jq -r --arg sk "$sk" '.[$sk] // empty' "$MERGE_CHECKPOINT_FILE" 2>/dev/null || echo ""
}

merge_checkpoint_bump_from_messages() {
    local mf_json="$1"
    [ -f "$MERGE_CHECKPOINT_FILE" ] || echo '{}' >"$MERGE_CHECKPOINT_FILE"
    local merged
    merged=$(echo "$mf_json" | jq -c '
        group_by(.sk)
        | map({ (.[0].sk): (map(.ts) | max) })
        | add
        // {}
    ')
    jq -s --argjson m "$merged" '.[0] * $m' "$MERGE_CHECKPOINT_FILE" >"${MERGE_CHECKPOINT_FILE}.new" \
        && mv "${MERGE_CHECKPOINT_FILE}.new" "$MERGE_CHECKPOINT_FILE"
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

# 参数：sk1 path1 ckpt1 sk2 path2 ckpt2 …（ckpt 为该 key 上次已归档的最大 timestamp ISO 串，空=首次全量）
merged_jsonl_new_messages_json() {
    local tmpdir sk f ck part_files i
    tmpdir=$(mktemp -d)
    part_files=()
    i=0
    while [ "$#" -ge 3 ]; do
        sk="$1"
        f="$2"
        ck="$3"
        shift 3
        [ -f "$f" ] || continue
        jq -s --arg sk "$sk" --arg ck "$ck" '
          map(select(.type == "message" and (.message.role == "user" or .message.role == "assistant")))
          | map(select( (($ck | length) == 0) or ((.timestamp // "") > $ck) ))
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
    jq -s --argjson nparts "${#part_files[@]}" '
      add
      | sort_by(.ts)
      | map(
          if ($nparts > 1) then .content = ("[" + .sk + "] " + .content) else . end
        )
    ' "${part_files[@]}"
    rm -rf "$tmpdir"
}

# 距上次成功写入 memory 的时间（秒）；由 do_archive 在写入后更新 .last_archive_ts
minutes_since_last_archive() {
    [ -f "$CONFIG_DIR/.last_archive_ts" ] || return 1
    local last now
    last=$(cat "$CONFIG_DIR/.last_archive_ts")
    now=$(date +%s)
    echo $(( (now - last) / 60 ))
}

should_run_archive() {
    FORCE_RUN="${FORCE_RUN:-0}"
    RUN_ARCHIVE_TRIGGER=""
    [ "$FORCE_RUN" = "1" ] && {
        RUN_ARCHIVE_TRIGGER=force
        return 0
    }
    case "$TRIGGER_MODE" in
        scheduled)
            RUN_ARCHIVE_TRIGGER=scheduled
            return 0
            ;;
        hybrid)
            if [ "$USAGE_TOKENS" -ge "$MAX_INPUT_TOKENS" ] 2>/dev/null; then
                RUN_ARCHIVE_TRIGGER=hybrid_threshold
                return 0
            fi
            if [ "${PERIODIC_ARCHIVE_MINUTES:-0}" -gt 0 ]; then
                local pdiff
                if pdiff=$(minutes_since_last_archive 2>/dev/null); then
                    if [ "${pdiff:-999999999}" -ge "$PERIODIC_ARCHIVE_MINUTES" ]; then
                        RUN_ARCHIVE_TRIGGER=hybrid_periodic
                        log "[INFO] hybrid：定期归档间隔已满 ${pdiff}m ≥ ${PERIODIC_ARCHIVE_MINUTES}m（用量未达阈值），将检查新增消息"
                        return 0
                    fi
                fi
            fi
            if [ -f "$CONFIG_DIR/.last_archive_ts" ]; then
                local last now diff
                last=$(cat "$CONFIG_DIR/.last_archive_ts")
                now=$(date +%s)
                diff=$(( (now - last) / 60 ))
                if [ "$diff" -ge "$CHECK_INTERVAL_MINUTES" ]; then
                    RUN_ARCHIVE_TRIGGER=hybrid_interval
                    return 0
                fi
            else
                RUN_ARCHIVE_TRIGGER=hybrid_first
                return 0
            fi
            log "[INFO] hybrid：未达阈值、未到 check_interval 且未到定期归档间隔，跳过"
            return 1
            ;;
        threshold|*)
            if [ "$USAGE_TOKENS" -ge "$MAX_INPUT_TOKENS" ] 2>/dev/null; then
                RUN_ARCHIVE_TRIGGER=threshold
                return 0
            fi
            if [ "${PERIODIC_ARCHIVE_MINUTES:-0}" -gt 0 ]; then
                local pdiff
                if pdiff=$(minutes_since_last_archive 2>/dev/null); then
                    if [ "${pdiff:-999999999}" -ge "$PERIODIC_ARCHIVE_MINUTES" ]; then
                        RUN_ARCHIVE_TRIGGER=periodic
                        log "[INFO] threshold：定期归档间隔已满 ${pdiff}m ≥ ${PERIODIC_ARCHIVE_MINUTES}m（用量 $USAGE_TOKENS < $MAX_INPUT_TOKENS），将检查新增消息"
                        return 0
                    fi
                fi
            fi
            if [ "${PERIODIC_ARCHIVE_MINUTES:-0}" -gt 0 ]; then
                if [ ! -f "$CONFIG_DIR/.last_archive_ts" ]; then
                    log "[INFO] threshold：用量 $USAGE_TOKENS < $MAX_INPUT_TOKENS；尚无 .last_archive_ts，定期补归档尚未开始计时（首次成功写入 memory 后每 ${PERIODIC_ARCHIVE_MINUTES}m 检查；可用 --force）"
                else
                    log "[INFO] threshold：用量 $USAGE_TOKENS < $MAX_INPUT_TOKENS，且距上次归档不足 ${PERIODIC_ARCHIVE_MINUTES}m，跳过（可用 --force）"
                fi
            else
                log "[INFO] threshold：用量 $USAGE_TOKENS < $MAX_INPUT_TOKENS，跳过（可用 --force）；可设 archive.periodic_archive_minutes 做定时补归档）"
            fi
            return 1
            ;;
    esac
}

cooldown_blocks_write() {
    FORCE_RUN="${FORCE_RUN:-0}"
    [ "$FORCE_RUN" = "1" ] && return 1
    # 定期补归档：不因「用量与上次相同」而跳过写入，避免少量重要对话被挡在冷却外
    case "${RUN_ARCHIVE_TRIGGER:-}" in periodic) return 1 ;; esac
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
    local _ck _u did=0
    for _ck in "${MERGE_PAIR_KEYS[@]}"; do
        _u="${SESSION_USAGE_BY_KEY[$_ck]:-0}"
        if [ "${COMPACT_ONLY_OVER_THRESHOLD:-1}" = "1" ]; then
            if ! [ "${_u:-0}" -ge "$MAX_INPUT_TOKENS" ] 2>/dev/null; then
                continue
            fi
        fi
        did=1
        run_compact_one "$_ck"
    done
    if [ "${COMPACT_ONLY_OVER_THRESHOLD:-1}" = "1" ] && [ "$did" = "0" ]; then
        log "[INFO] compact_only_over_threshold：无 key ≥ $MAX_INPUT_TOKENS，跳过 sessions.compact"
    fi
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
    params=$(jq -n --arg k "$compact_target_key" --argjson m "$(canonical_uint "$COMPACT_MAX_LINES" 400)" '{key:$k, maxLines:$m}')
    compact_log=$(mktemp)
    if openclaw gateway call sessions.compact --params "$params" --json --expect-final "${gw_extra[@]}" >"$compact_log" 2>&1; then
        cat "$compact_log" >>"$LOG_FILE"
        if jq -e '.ok == true' "$compact_log" >/dev/null 2>&1; then
            local c k r extra
            # jq 的 a // b 在 a 为 false 时也会落到 b，不能用 .compacted // "?"
            c=$(jq -r 'if (.compacted|type)=="boolean" then (.compacted|tostring) elif .compacted==null then "?" else (.compacted|tostring) end' "$compact_log")
            k=$(jq -r 'if (.kept|type)=="number" then (.kept|tostring) else (.kept // empty | tostring) end' "$compact_log")
            r=$(jq -r 'if (.reason|type)=="string" then .reason else empty end' "$compact_log")
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
    load_config || exit 1
    run_log_maintenance
    resolve_session_key
    load_merge_session_keys
    [ -n "${CLI_SESSION_KEY:-}" ] && SESSION_MERGE_KEYS=("$CLI_SESSION_KEY") && SESSION_KEY="$CLI_SESSION_KEY"

    [ -f "$SESSIONS_JSON" ] || {
        log "[ERROR] 无 sessions.json: $SESSIONS_JSON"
        exit 1
    }

    MERGE_PAIR_KEYS=()
    MERGE_PAIR_PATHS=()
    declare -A SESSION_USAGE_BY_KEY=()
    local sk entry jsonl u rep_entry pk_log
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
        u=$(resolve_usage_tokens "$entry")
        SESSION_USAGE_BY_KEY["$sk"]=$u
        MERGE_PAIR_KEYS+=("$sk")
        MERGE_PAIR_PATHS+=("$jsonl")
    done
    [ ${#MERGE_PAIR_KEYS[@]} -gt 0 ] || {
        log "[ERROR] 无可用 jsonl（列表: ${SESSION_MERGE_KEYS[*]}）"
        exit 1
    }

    USAGE_TOKENS=0
    rep_entry=""
    pk_log=""
    for sk in "${MERGE_PAIR_KEYS[@]}"; do
        u="${SESSION_USAGE_BY_KEY[$sk]:-0}"
        [ -n "$pk_log" ] && pk_log+=" | "
        pk_log+="${sk}=${u}"
        entry=$(jq -c --arg sk "$sk" '.[$sk] // empty' "$SESSIONS_JSON")
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

    log "[INFO] session_merge=[$SESSION_MERGE_LABEL] usage_max=$USAGE_TOKENS | per_key: $pk_log | rep_input=$INPUT_TOKENS_RAW rep_total=$TOTAL_TOKENS_RAW fresh=$TOTAL_FRESH trigger=$TRIGGER_MODE"

    should_run_archive || exit 0

    local merge_args messages_all msg_count messages_slice _i ck
    merge_args=()
    for _i in "${!MERGE_PAIR_KEYS[@]}"; do
        ck=$(merge_checkpoint_get "${MERGE_PAIR_KEYS[$_i]}")
        merge_args+=("${MERGE_PAIR_KEYS[$_i]}" "${MERGE_PAIR_PATHS[$_i]}" "$ck")
    done
    messages_all=$(merged_jsonl_new_messages_json "${merge_args[@]}")
    msg_count=$(echo "$messages_all" | jq 'length')
    if [ "${msg_count:-0}" -eq 0 ]; then
        log "[INFO] 检查点之后无新增 user/assistant 消息，跳过合并与摘要"
        run_compact
        exit 0
    fi

    local bypass_min_new=0
    [ "${FORCE_RUN:-0}" = "1" ] && bypass_min_new=1
    [ "$USAGE_TOKENS" -ge "$MAX_INPUT_TOKENS" ] 2>/dev/null && bypass_min_new=1
    case "${RUN_ARCHIVE_TRIGGER:-}" in periodic | hybrid_periodic) bypass_min_new=1 ;; esac

    if [ "$bypass_min_new" != "1" ] && [ "${msg_count:-0}" -lt "$MIN_NEW_MESSAGES" ]; then
        log "[INFO] 新增消息 ${msg_count} < min_new_messages=${MIN_NEW_MESSAGES}，累积后再归档（不写 memory、不推进检查点）；超阈值 / 定期间隔触发时可放宽"
        run_compact
        exit 0
    fi

    local skip_write=0
    cooldown_blocks_write && skip_write=1

    local messages_stripped total_new chunk_note PER_KEY_USAGE_ROW
    messages_stripped=$(echo "$messages_all" | jq 'map({role, content})')
    total_new=$(echo "$messages_stripped" | jq 'length')
    messages_slice=$(echo "$messages_stripped" | jq --argjson take "$MESSAGES_TO_ANALYZE" '.[-($take):]')
    chunk_note="本地关键词：尾部 ${MESSAGES_TO_ANALYZE} 条；本周期新增 ${total_new} 条。"

    PER_KEY_USAGE_ROW=""
    for sk in "${MERGE_PAIR_KEYS[@]}"; do
        [ -n "$PER_KEY_USAGE_ROW" ] && PER_KEY_USAGE_ROW+=" / "
        PER_KEY_USAGE_ROW+="${sk}=${SESSION_USAGE_BY_KEY[$sk]}"
    done

    local insights cloud_block trigger_reason
    case "${RUN_ARCHIVE_TRIGGER:-}" in
        force) trigger_reason="手动强制归档" ;;
        scheduled) trigger_reason="定时 / scheduled" ;;
        hybrid_threshold) trigger_reason="hybrid 阈值" ;;
        hybrid_periodic) trigger_reason="hybrid：定期归档间隔（用量未达阈值）" ;;
        hybrid_interval) trigger_reason="hybrid 间隔（check_interval_minutes）" ;;
        hybrid_first) trigger_reason="hybrid 首次（无 .last_archive_ts）" ;;
        periodic) trigger_reason="定期归档间隔（用量未达阈值，有新增则写 memory）" ;;
        threshold) trigger_reason="达到阈值" ;;
        *) trigger_reason="归档（trigger=${RUN_ARCHIVE_TRIGGER:-?}）" ;;
    esac

    insights=""
    cloud_block=""
    if [ "$skip_write" = "0" ]; then
        insights=$("$LOCAL_EXTRACTOR" - <<<"$messages_slice" "$MESSAGES_TO_ANALYZE" || true)
        if cloud_summarizer_enabled && [ -f "$CONFIG_DIR/credentials.enc" ]; then
            local tmp_plain api_url api_tok model_id cloud_out full_chunks used_chunks chunk_start_ci cidx start chunk_json clen cend sect
            tmp_plain=$(mktemp)
            chmod 600 "$tmp_plain"
            if API_JSON=$("$GET_CREDS" 2>>"$LOG_FILE"); then
                api_url=$(echo "$API_JSON" | jq -r .api_url)
                api_tok=$(echo "$API_JSON" | jq -r .api_token)
                model_id=$(echo "$API_JSON" | jq -r .model)
                if [ -z "$api_url" ] || [ "$api_url" = "null" ] || [ -z "$api_tok" ] || [ "$api_tok" = "null" ] || [ -z "$model_id" ] || [ "$model_id" = "null" ]; then
                    cloud_block="- *（凭证字段不完整，请 save-json）*"
                elif [ "$CHUNK_CLOUD_SUMMARY" = "1" ] && [ "$total_new" -gt "$MESSAGES_TO_ANALYZE" ]; then
                    full_chunks=$(( (total_new + MESSAGES_TO_ANALYZE - 1) / MESSAGES_TO_ANALYZE ))
                    chunk_start_ci=0
                    used_chunks=$full_chunks
                    if [ "$full_chunks" -gt "$MAX_CLOUD_SUMMARY_CHUNKS" ]; then
                        used_chunks=$MAX_CLOUD_SUMMARY_CHUNKS
                        chunk_start_ci=$(( full_chunks - MAX_CLOUD_SUMMARY_CHUNKS ))
                        log "[WARN] 云端分块共 ${full_chunks} 段；仅摘要最近 ${used_chunks} 段（每段 ${MESSAGES_TO_ANALYZE} 条），更早的新增未送 LLM"
                    fi
                    chunk_note="云端分块：每段 ${MESSAGES_TO_ANALYZE} 条；本次第 $((chunk_start_ci + 1))–$((chunk_start_ci + used_chunks)) 段 / 共 ${full_chunks} 段；本周期新增 ${total_new} 条"
                    cloud_block=""
                    cidx=0
                    while [ "$cidx" -lt "$used_chunks" ]; do
                        start=$(( (chunk_start_ci + cidx) * MESSAGES_TO_ANALYZE ))
                        chunk_json=$(echo "$messages_stripped" | jq --argjson s "$start" --argjson n "$MESSAGES_TO_ANALYZE" '.[$s:$s+$n]')
                        clen=$(echo "$chunk_json" | jq 'length')
                        cend=$((start + clen - 1))
                        sect=$((cidx + 1))
                        echo "$chunk_json" | jq -r '.[] | "\(.role): \(.content)"' >"$tmp_plain"
                        if cloud_out=$("$CLOUD_SUMMARIZER" --file "$tmp_plain" "openai-compatible" "$model_id" "$api_url" "$api_tok" 2>>"$LOG_FILE"); then
                            cloud_block+="##### 云端段 ${sect}/${used_chunks}（消息序号 ${start}–${cend}）"$'\n\n'"$cloud_out"$'\n\n'
                        else
                            cloud_block+="- *（段 ${sect}/${used_chunks} 摘要失败）*"$'\n\n'
                        fi
                        cidx=$((cidx + 1))
                    done
                    log "[INFO] 云端分块摘要完成 ${used_chunks} 段（本周期新增 ${total_new} 条）"
                else
                    if [ "$total_new" -gt "$MESSAGES_TO_ANALYZE" ]; then
                        log "[WARN] 本周期新增 ${total_new} 条，chunk_cloud_summary 关闭：云端仅摘要最后 ${MESSAGES_TO_ANALYZE} 条"
                        chunk_note="本地：尾部 ${MESSAGES_TO_ANALYZE} 条。云端：仅最后 ${MESSAGES_TO_ANALYZE} 条。本周期新增 ${total_new} 条（未开分块）。"
                    fi
                    echo "$messages_slice" | jq -r '.[] | "\(.role): \(.content)"' >"$tmp_plain"
                    if cloud_out=$("$CLOUD_SUMMARIZER" --file "$tmp_plain" "openai-compatible" "$model_id" "$api_url" "$api_tok" 2>>"$LOG_FILE"); then
                        cloud_block=$cloud_out
                    else
                        cloud_block="- *（云端摘要失败，见日志）*"
                    fi
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
            echo "| **各 Key 用量（total/input 规则同 OpenClaw）** | $PER_KEY_USAGE_ROW |"
            echo "| **代表会话 input/total/fresh** | input=$INPUT_TOKENS_RAW total=$TOTAL_TOKENS_RAW fresh=$TOTAL_FRESH（usage_max=$USAGE_TOKENS 的 key） |"
            echo "| **本周期新增消息** | $total_new（检查点之后合并） |"
            echo "| **摘要窗口说明** | $chunk_note |"
            echo "| **触发** | $ts_local |"
            echo "| **原因** | $trigger_reason |"
            echo "| **trigger_mode** | $TRIGGER_MODE |"
            echo "| **messages_to_analyze** | $MESSAGES_TO_ANALYZE |"
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
            echo "- [x] Daily Memory 归档（仅本周期新增合并） / 本地提取 / 云端摘要 / 仅超限 key 的 sessions.compact"
            echo ""
        } >>"$fpath"
        merge_checkpoint_bump_from_messages "$messages_all"
        date +%s >"$CONFIG_DIR/.last_archive_ts"
        local per_key_json sk_u uu
        per_key_json="{}"
        for sk_u in "${MERGE_PAIR_KEYS[@]}"; do
            uu=$(canonical_uint "${SESSION_USAGE_BY_KEY[$sk_u]:-0}" 0)
            per_key_json=$(jq -c --arg k "$sk_u" --argjson v "$uu" '. + {($k): $v}' <<<"$per_key_json")
        done
        jq -n --arg sk "$SESSION_MERGE_LABEL" \
            --argjson u "$(canonical_uint "$USAGE_TOKENS" 0)" \
            --argjson ts "$(date +%s)" \
            --argjson pk "$per_key_json" \
            '{session_key:$sk, usage_tokens:$u, ts:$ts, per_key_usage:$pk}' >"$CONFIG_DIR/.last_archive_meta.json"
        log "[INFO] 已写入 $fpath；已更新合并检查点 $MERGE_CHECKPOINT_FILE"
    else
        log "[INFO] 跳过 memory（冷却）"
    fi
    run_compact
}

do_log_maintenance_only() {
    load_config || exit 1
    run_log_maintenance
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
        log-maintenance|logs)
            do_log_maintenance_only
            ;;
        help)
            echo "Usage: $0 archive [--force] [--session <key>] [--agent <id>]"
            echo "       $0 log-maintenance   # 仅执行日志天龄清理 + 按大小轮转（读 config.yaml）"
            echo "多通道: session.merge_jsonl_keys 或 DAILY_MEMORY_MERGE_KEYS"
            echo "日志: logging.log_max_bytes / log_keep_rotations / log_max_age_days；环境变量见 README"
            ;;
        *)
            echo "Unknown: $cmd" >&2
            exit 2
            ;;
    esac
}

main_cli "$@"
