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
# shellcheck source=lib/config-loader.sh
source "$SCRIPT_DIR/lib/config-loader.sh"
# shellcheck source=lib/conversation-noise.sh
source "$SCRIPT_DIR/lib/conversation-noise.sh"

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

# Wave 10: 判断一批消息是否含至少一条"实质内容"。
# 入参：messages JSON 数组（每元素含 .role/.content）
# 返回：0 = 有实质内容；1 = 全为心跳/系统噪声
slot_has_substance() {
    local messages_json="$1"
    local n i content role
    n=$(echo "$messages_json" | jq 'length' 2>/dev/null || echo 0)
    for ((i = 0; i < n; i++)); do
        role=$(echo "$messages_json" | jq -r ".[$i].role // empty")
        content=$(echo "$messages_json" | jq -r ".[$i].content // empty")
        [ -z "$content" ] && continue
        # 仅检查 SUBSTANCE_ROLES 中配置的角色，默认 user
        if [[ ",${SUBSTANCE_ROLES:-user}," == *",$role,"* ]]; then
            if ! is_noise_message "$content"; then
                return 0   # 找到实质内容，立即判定"有"
            fi
        fi
    done
    return 1           # 全部噪声
}

# Wave 10 Part B: 若"上一个活跃日"未产生任何 memory 文件（整日被跳过），
# 在跨日后补写一个【零时间槽、KW 不收录】的空日标记文件。
finalize_empty_previous_day() {
    local today prev prev_file
    today=$(date +%Y-%m-%d)
    prev=$(cat "$CONFIG_DIR/.last_active_day" 2>/dev/null || echo "")

    # 仅当确有"上一个活跃日"且它早于今天时才收尾（ISO 日期可直接字典序比较）
    if [ -n "$prev" ] && [[ "$prev" < "$today" ]]; then
        prev_file="$MEMORY_DIR/${prev}.md"
        if [ ! -e "$prev_file" ]; then
            mkdir -p "$MEMORY_DIR"
            {
                echo "---"
                echo "title: \"${prev} 会话记忆\""
                echo "date: \"${prev}\""
                echo "---"
                echo ""
                echo "# ${prev}"
                echo ""
                echo "<!-- 本日无对话内容：DMA 全时段仅心跳/系统巡检，无实质用户交互。"
                echo "     此标记为 HTML 注释、且文件不含任何时间槽与摘要，KW 结构性不收录；"
                echo "     保留文件用于区分『当日无对话』与『DMA 故障/未运行（文件缺失）』。 -->"
            } >>"$prev_file"
            log "[INFO] Wave10: ${prev} 全天无实质对话，已写入空日标记 ${prev_file}（零时间槽，KW 不收录）。"
        fi
    fi

    # 每周期更新"最近活跃日"为今天
    echo "$today" >"$CONFIG_DIR/.last_active_day"
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

cloud_summarizer_enabled() {
    [ "$CLOUD_SUMMARIZER_ENABLED" = "1" ] 2>/dev/null || return 1
}

load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        log "[WARN] 缺少 $CONFIG_FILE，执行 init-defaults …"
        bash "$SCRIPT_DIR/config-manager.sh" init-defaults >>"$LOG_FILE" 2>&1 || {
            log "[ERROR] init-defaults 失败"
            return 1
        }
    fi

    # 使用统一配置加载器
    eval "$(config_load_all "$CONFIG_FILE")"

    # 环境变量覆盖（优先级最高）
    [ -n "${OPENCLAW_AGENT_ID:-}" ] && AGENT_ID="$OPENCLAW_AGENT_ID"
    [ -n "${DAILY_MEMORY_PERIODIC_ARCHIVE_MINUTES:-}" ] && PERIODIC_ARCHIVE_MINUTES=$(canonical_uint "$DAILY_MEMORY_PERIODIC_ARCHIVE_MINUTES" 0)
    [ -n "${DAILY_MEMORY_LOG_MAX_BYTES:-}" ] && LOG_MAX_BYTES=$(canonical_uint "$DAILY_MEMORY_LOG_MAX_BYTES" 0)
    [ -n "${DAILY_MEMORY_LOG_KEEP_ROTATIONS:-}" ] && LOG_KEEP_ROTATIONS=$(canonical_uint "$DAILY_MEMORY_LOG_KEEP_ROTATIONS" 5)
    [ -n "${DAILY_MEMORY_LOG_MAX_AGE_DAYS:-}" ] && LOG_MAX_AGE_DAYS=$(canonical_uint "$DAILY_MEMORY_LOG_MAX_AGE_DAYS" 0)
    if [ -n "${DAILY_MEMORY_MEMORY_DIR:-}" ]; then
        MEMORY_DIR="$(expand_tilde "$DAILY_MEMORY_MEMORY_DIR")"
    elif [ -z "$MEMORY_DIR" ]; then
        MEMORY_DIR="$OPENCLAW_HOME/workspace/memory"
    else
        MEMORY_DIR="$(expand_tilde "$MEMORY_DIR")"
    fi

    SESSION_KEY_CFG=$(grep -E '^session:' -A30 "$CONFIG_FILE" | grep -E '^[[:space:]]+key:' | head -1 | \
        sed -E 's/^[[:space:]]*key:[[:space:]]*//;s/^["'\'']//;s/["'\'']$//;s/[[:space:]]*$//') || true

    MERGE_CHECKPOINT_FILE="$CONFIG_DIR/.archive_merge_checkpoint.json"
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
    done < <(yaml_merge_keys "$CONFIG_FILE")
    if [ ${#SESSION_MERGE_KEYS[@]} -eq 0 ]; then
        SESSION_MERGE_KEYS=("$SESSION_KEY")
    fi
}

# usage 计算已内联到 sessions.json 快照读取中，减少一次 jq 调用

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

# 参数：sk1 path1 ckpt1 sk2 path2 ckpt2 …
# 返回: {count: N, data: [...], stripped: [{role,content}]} - 一次 jq 完成过滤、排序、标记、计数
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
        jq -c --arg sk "$sk" --arg ck "$ck" '
          select(.type == "message" and (.message.role == "user" or .message.role == "assistant"))
          | select( (($ck | length) == 0) or ((.timestamp // "") > $ck) )
          | {
              ts: (.timestamp // ""),
              role: .message.role,
              content: (.message.content
                | if type == "string" then .
                  elif type == "array" then (map(select(.type == "text") | .text) | join("\n"))
                  else "" end),
              sk: $sk
            }
          | select(.content != null and (.content | length) > 0)
          # ========== 噪声过滤：不包含以下任意噪声关键词才保留 ==========
          | select(
              (.content | length > 3) and (
                ( .content | contains("[heartbeat") | not )
                and ( .content | contains("heartbeat poll") | not )
                and ( .content | contains("HEARTBEAT") | not )
                and ( .content | contains("[tool") | not )
                and ( .content | contains("toolCall") | not )
                and ( .content | contains("tool_call_id") | not )
                and ( .content | contains("Sender (untrusted") | not )
                and ( .content | contains("[system") | not )
                and ( .content | contains("[SYSTEM") | not )
                and ( .content | contains("[MCP") | not )
                and ( .content | contains("[Spinner") | not )
                and ( .content | contains("<<<") | not )
                and ( .content | contains(">>>") | not )
                and ( .content | test("^\\s*\\{\"") | not )
              )
            )
        ' "$f" >"$tmpdir/p${i}.jsonl"
        part_files+=("$tmpdir/p${i}.jsonl")
        i=$((i + 1))
    done
    if [ ${#part_files[@]} -eq 0 ]; then
        rm -rf "$tmpdir"
        echo '{"count":0,"data":[],"stripped":[]}'
        return
    fi
    cat "${part_files[@]}" | jq -s --argjson nparts "${#part_files[@]}" '
      sort_by(.ts)
      | map(
          if ($nparts > 1) then .content = ("[" + .sk + "] " + .content) else . end
        )
      | {count: length, data: ., stripped: map({role, content})}
    '
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
            log "[HINT] pairing required：见 SKILL.md §5（devices approve）；cron 需 HOME/OPENCLAW_HOME/PATH"
        rm -f "$compact_log"
        log "[WARN] sessions.compact 失败；memory 可能已写入"
    fi
}

# ===== Fix 3B: reconcile — 扫 .pending sidecar，调云端摘要替换(待补)块 =====
do_reconcile() {
    load_config || exit 1
    local pending_dir="$MEMORY_DIR/.pending"
    [ -d "$pending_dir" ] || { log "[INFO] reconcile: 无 .pending 目录，跳过"; return 0; }
    local sidecars
    sidecars=$(find "$pending_dir" -maxdepth 1 -name '*.json' -type f 2>/dev/null || true)
    [ -n "$sidecars" ] || { log "[INFO] reconcile: 无待补 sidecar"; return 0; }

    if ! cloud_summarizer_enabled || [ ! -f "$CONFIG_DIR/credentials.enc" ]; then
        log "[INFO] reconcile: cloud_summarizer 禁用或无凭据，跳过"
        return 0
    fi

    local API_JSON api_url api_tok model_id
    API_JSON=$("$GET_CREDS" 2>>"$LOG_FILE")
    api_url=$(echo "$API_JSON" | jq -r .api_url)
    api_tok=$(echo "$API_JSON" | jq -r .api_token)
    model_id=$(echo "$API_JSON" | jq -r .model)
    if [ -z "$api_url" ] || [ "$api_url" = "null" ] || [ -z "$api_tok" ] || [ "$api_tok" = "null" ] || [ -z "$model_id" ] || [ "$model_id" = "null" ]; then
        log "[WARN] reconcile: 凭据不完整，跳过"
        return 0
    fi

    local sc day hhmm md_file tmp_plain cloud_out
    while IFS= read -r sc; do
        [ -f "$sc" ] || continue
        local bn
        bn=$(basename "$sc" .json)
        day="${bn%%_*}"
        hhmm="${bn#*_}"
        md_file="$MEMORY_DIR/${day}.md"
        if [ ! -f "$md_file" ]; then
            log "[WARN] reconcile: .md 不存在 $md_file，删除孤儿 sidecar $sc"
            rm -f "$sc"
            continue
        fi

        # 前置校验：检查 ## HH:MM 块内是否含 ### 原始细节(待补)
        if ! awk -v h="## ${hhmm}" '
            $0 == h { inb=1; next }
            inb && /^## / { inb=0 }
            inb && /^### 原始细节\(待补\)/ { found=1 }
            END { exit !found }
        ' "$md_file"; then
            log "[WARN] reconcile: ${day}_${hhmm} 无待补块(孤儿 sidecar),删除并跳过"
            rm -f "$sc"
            continue
        fi

        # 将 messages_all 转为 role: content 文本送云端
        tmp_plain=$(mktemp)
        chmod 600 "$tmp_plain"
        jq -r '.[] | "\(.role): \(.content)"' "$sc" | tr -d '\000' | head -c 120000 >"$tmp_plain"

        if cloud_out=$("$CLOUD_SUMMARIZER" --file "$tmp_plain" "openai-compatible" "$model_id" "$api_url" "$api_tok" 2>>"$LOG_FILE"); then
            # 成功：用 ### 摘要 就地替换 .md 中对应 ## HH:MM 的 ### 原始细节(待补) 块
            # 幂等：用 ## HH:MM + (待补) 双标记锚定
            local tmp_md
            tmp_md=$(mktemp)
            local in_block=0
            local wrote=0
            while IFS= read -r line; do
                if [[ "$line" == "## ${hhmm}"* ]] && [ "$in_block" = "0" ]; then
                    # 标记进入目标时段块，向前看确认有 (待补) 标记
                    echo "$line" >>"$tmp_md"
                    in_block=1
                    wrote=0
                elif [ "$in_block" = "1" ]; then
                    if [[ "$line" == "## "* ]]; then
                        # 遇到下一个时段，如果还没写摘要（前置校验已过滤孤儿，此处为防御）
                        if [ "$wrote" = "0" ]; then
                            log "[WARN] reconcile: ${day}_${hhmm} 未找到待补标记，跳过摘要追加（可能已补档）"
                        fi
                        echo "$line" >>"$tmp_md"
                        in_block=0
                    elif [[ "$line" == "### 原始细节(待补)" ]]; then
                        # 找到待补标记，输出摘要替换
                        echo "### 摘要" >>"$tmp_md"
                        echo "" >>"$tmp_md"
                        echo "$cloud_out" >>"$tmp_md"
                        echo "" >>"$tmp_md"
                        wrote=1
                    elif [ "$wrote" = "1" ]; then
                        # 已写摘要，跳过后续属于(待补)块的剩余行直到空行或下一个 ##
                        :
                    else
                        echo "$line" >>"$tmp_md"
                    fi
                else
                    echo "$line" >>"$tmp_md"
                fi
            done <"$md_file"
            # 文件末尾仍在时段块内
            if [ "$in_block" = "1" ] && [ "$wrote" = "0" ]; then
                log "[WARN] reconcile: ${day}_${hhmm} 未找到待补标记，跳过摘要追加（可能已补档）"
            fi
            mv "$tmp_md" "$md_file"
            rm -f "$sc"
            log "[INFO] reconcile: ${day}_${hhmm} 补档成功，sidecar 已删除"
        else
            log "[WARN] reconcile: ${day}_${hhmm} 云端调用失败，保留 sidecar 待下次重试"
        fi
        rm -f "$tmp_plain"
    done <<<"$sidecars"
}

do_archive() {
    load_config || exit 1
    # W2/B: best-effort fetch the KW project lexicon and export it so the cloud
    # summarizer outputs canonical project names in ### 结构化事实. Opt-in via
    # DAILY_MEMORY_LEXICON_CMD (e.g. "python3 -m knowledge_weaver.registry --lexicon");
    # disabled when unset, so default behaviour is unchanged.
    if [ -n "${DAILY_MEMORY_LEXICON_CMD:-}" ] && [ -z "${DAILY_MEMORY_LEXICON:-}" ]; then
        _lex=$(timeout 15 ${DAILY_MEMORY_LEXICON_CMD} 2>/dev/null || true)
        if [ -n "$_lex" ]; then
            export DAILY_MEMORY_LEXICON="$_lex"
            log "[INFO] W2: 已注入项目词表到云端摘要器（${#_lex} 字节）"
        fi
    fi
    # Fix 3B: 自动扫一次 .pending → 补档
    do_reconcile
    finalize_empty_previous_day
    run_log_maintenance
    resolve_session_key
    load_merge_session_keys
    [ -n "${CLI_SESSION_KEY:-}" ] && SESSION_MERGE_KEYS=("$CLI_SESSION_KEY") && SESSION_KEY="$CLI_SESSION_KEY"

    [ -f "$SESSIONS_JSON" ] || {
        log "[ERROR] 无 sessions.json: $SESSIONS_JSON"
        exit 1
    }

    # 一次性读取所有 key 的 sessionFile 和 usage，避免多次遍历 sessions.json
    local sessions_snapshot sk_json sk jsonl u rep_entry pk_log found_sk
    sessions_snapshot=$(mktemp)
    chmod 600 "$sessions_snapshot"
    # 构建 jq 查询参数：--argjson keys '["k1","k2"]' -> {k1: .k1, k2: .k2} 过滤后输出
    sk_json=$(printf '%s\n' "${SESSION_MERGE_KEYS[@]}" | jq -R . | jq -s .)
    jq -c --argjson keys "$sk_json" '
      [to_entries[] | select(.key as $k | $keys | index($k))]
      | map({key, sessionFile: .value.sessionFile,
             inputTokens: (.value.inputTokens // 0),
             totalTokens: (.value.totalTokens // 0),
             totalTokensFresh: (.value.totalTokensFresh // false)})
    ' "$SESSIONS_JSON" >"$sessions_snapshot"

    MERGE_PAIR_KEYS=()
    MERGE_PAIR_PATHS=()
    declare -A SESSION_USAGE_BY_KEY=()
    declare -A SESSION_ENTRY_CACHE=()

    while IFS= read -r entry; do
        sk=$(echo "$entry" | jq -r '.key')
        jsonl=$(echo "$entry" | jq -r '.sessionFile // empty')
        if [ -z "$jsonl" ] || [ ! -f "$jsonl" ]; then
            log "[WARN] sessionFile 无效，跳过: $sk"
            continue
        fi
        u=$(echo "$entry" | jq -r 'if (.totalTokensFresh == false) then (.inputTokens // 0) else (.totalTokens // .inputTokens // 0) end')
        SESSION_USAGE_BY_KEY["$sk"]=$u
        SESSION_ENTRY_CACHE["$sk"]="$entry"
        MERGE_PAIR_KEYS+=("$sk")
        MERGE_PAIR_PATHS+=("$jsonl")
    done < <(jq -c '.[]' "$sessions_snapshot")
    rm -f "$sessions_snapshot"

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
        if [ "${u:-0}" -ge "${USAGE_TOKENS:-0}" ] 2>/dev/null; then
            USAGE_TOKENS=$u
            rep_entry="${SESSION_ENTRY_CACHE[$sk]}"
        fi
    done
    [ -n "$rep_entry" ] || rep_entry="${SESSION_ENTRY_CACHE[${MERGE_PAIR_KEYS[0]}]}"

    # 清理不再需要的关联数组，释放内存
    unset SESSION_ENTRY_CACHE

    INPUT_TOKENS_RAW=$(echo "$rep_entry" | jq -r '.inputTokens // 0')
    TOTAL_TOKENS_RAW=$(echo "$rep_entry" | jq -r '.totalTokens // 0')
    TOTAL_FRESH=$(echo "$rep_entry" | jq -r '.totalTokensFresh // false')
    SESSION_MERGE_LABEL=$(IFS=','; echo "${MERGE_PAIR_KEYS[*]}")

    log "[INFO] session_merge=[$SESSION_MERGE_LABEL] usage_max=$USAGE_TOKENS | per_key: $pk_log | rep_input=$INPUT_TOKENS_RAW rep_total=$TOTAL_TOKENS_RAW fresh=$TOTAL_FRESH trigger=$TRIGGER_MODE"

    should_run_archive || exit 0

    local merge_args merge_result msg_count messages_all messages_stripped messages_slice _i ck
    merge_args=()
    for _i in "${!MERGE_PAIR_KEYS[@]}"; do
        ck=$(merge_checkpoint_get "${MERGE_PAIR_KEYS[$_i]}")
        merge_args+=("${MERGE_PAIR_KEYS[$_i]}" "${MERGE_PAIR_PATHS[$_i]}" "$ck")
    done
    merge_result=$(merged_jsonl_new_messages_json "${merge_args[@]}")
    msg_count=$(echo "$merge_result" | jq -r '.count')
    if [ "${msg_count:-0}" -eq 0 ]; then
        log "[INFO] 检查点之后无新增 user/assistant 消息，跳过合并与摘要"
        run_compact
        exit 0
    fi

    # Wave 10 Part A: 纯噪声时段——不写 memory，但推进 checkpoint + compact 以消费/丢弃消息。
    messages_all=$(echo "$merge_result" | jq '.data')
    if ! slot_has_substance "$messages_all"; then
        log "[INFO] Wave10: 本时段 ${msg_count} 条消息均为心跳/系统巡检噪声，跳过 memory 写入；推进 checkpoint 并 compact 丢弃。"
        merge_checkpoint_bump_from_messages "$messages_all"
        date +%s >"$CONFIG_DIR/.last_archive_ts"
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

    local total_new chunk_note
    total_new=$msg_count
    messages_all=$(echo "$merge_result" | jq '.data')
    messages_stripped=$(echo "$merge_result" | jq '.stripped')
    messages_slice=$(echo "$messages_stripped" | jq --argjson take "$MESSAGES_TO_ANALYZE" '.[-($take):]')
    chunk_note="本地关键词：尾部 ${MESSAGES_TO_ANALYZE} 条；本周期新增 ${total_new} 条。"

    local insights cloud_block cloud_recoverable_fail
    cloud_recoverable_fail=0

    insights=""
    cloud_block=""
    if [ "$skip_write" = "0" ]; then
        # Fix 2: normal path no longer needs LOCAL_EXTRACTOR;
        # fallback (Fix 3) generates raw detail directly from messages_all
        insights=""
        if cloud_summarizer_enabled && [ -f "$CONFIG_DIR/credentials.enc" ]; then
            local tmp_plain api_url api_tok model_id cloud_out full_chunks used_chunks chunk_start_ci cidx start chunk_json clen cend sect
            tmp_plain=$(mktemp)
            chmod 600 "$tmp_plain"
            if API_JSON=$("$GET_CREDS" 2>>"$LOG_FILE"); then
                api_url=$(echo "$API_JSON" | jq -r .api_url)
                api_tok=$(echo "$API_JSON" | jq -r .api_token)
                model_id=$(echo "$API_JSON" | jq -r .model)
                if [ -z "$api_url" ] || [ "$api_url" = "null" ] || [ -z "$api_tok" ] || [ "$api_tok" = "null" ] || [ -z "$model_id" ] || [ "$model_id" = "null" ]; then
                    cloud_block="- *DMA-ERR: incomplete credentials (use save-json)*"
                    cloud_recoverable_fail=1
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
                            cloud_block+="- *DMA-ERR: chunk ${sect}/${used_chunks} summary failed*"$'\n\n'
                            cloud_recoverable_fail=1
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
                        cloud_block="- *DMA-ERR: cloud summary failed (see log)*"
                        cloud_recoverable_fail=1
                    fi
                fi
            else
                cloud_block="- *DMA-ERR: get-cloud-creds failed (check .master_key & credentials.enc)*"
                cloud_recoverable_fail=1
            fi
            rm -f "$tmp_plain"
        elif cloud_summarizer_enabled; then
            cloud_block="- *DMA-ERR: no credentials.enc*"
        else
            cloud_block="- *DMA-ERR: cloud summarizer disabled*"
        fi

        if [ "$cloud_recoverable_fail" = "1" ]; then
            # 云端可恢复失败：跳过本次写入/checkpoint/compact，等下个周期重试
            local _retry_n
            _retry_n=$(cat "$CONFIG_DIR/.cloud_retry_count" 2>/dev/null || echo 0)
            _retry_n=$(canonical_uint "$_retry_n" 0)
            _retry_n=$((_retry_n + 1))
            echo "$_retry_n" >"$CONFIG_DIR/.cloud_retry_count"
            log "[WARN] 云端摘要可恢复失败（第 ${_retry_n} 次），跳过本次 memory 写入/checkpoint/compact，下个周期重试。请检查 cloud API key / 凭据。"

            # retry 上限保护：超阈值则强制归档避免会话无限堆积
            local _max_retry
            _max_retry=$(canonical_uint "${MAX_CLOUD_RETRY:-20}" 20)
            if [ "$_max_retry" -gt 0 ] && [ "$_retry_n" -ge "$_max_retry" ]; then
                log "[ERROR] 云端摘要连续失败 ${_retry_n} 次，达上限 ${_max_retry}，强制归档（写入 DMA-ERR 占位 + 推进 checkpoint）避免 sessions 无限堆积。请立即修复 cloud 凭据。"
                touch "$CONFIG_DIR/.cloud_fail_alert"

                # Fix 3A 暂存：云端连续失败达上限 → 写入原始细节(待补) + sidecar
                mkdir -p "$MEMORY_DIR" "$MEMORY_DIR/.pending"
                local day fpath ts_local ts_hhmm
                day=$(date +%Y-%m-%d)
                fpath="$MEMORY_DIR/${day}.md"
                ts_local=$(date '+%Y-%m-%d %H:%M:%S')
                ts_hhmm="${ts_local:11:5}"
                if [ ! -s "$fpath" ]; then
                    {
                        echo "---"
                        echo "title: \"${day} 会话记忆\""
                        echo "date: \"${day}\""
                        echo "---"
                        echo ""
                        echo "# ${day}"
                        echo ""
                    } >>"$fpath"
                fi
                # Fix 3A: 写入 ### 原始细节(待补) — 根据 raw_detail 决定内容量
                local sidecar_path
                sidecar_path="$MEMORY_DIR/.pending/${day}_${ts_hhmm}.json"
                echo "$messages_all" >"$sidecar_path"
                {
                    echo ""
                    echo "## ${ts_hhmm}"
                    echo ""
                    if [ "$RAW_DETAIL" = "off" ]; then
                        echo "### 原始细节(待补)"
                        echo ""
                        echo "- *（raw_detail=off：原始细节仅保留在 sidecar 中）*"
                    else
                        echo "### 原始细节(待补)"
                        echo ""
                        echo "$messages_all" | jq -r '.[] | if .role == "user" then "用户: \(.content)" elif .role == "assistant" then "助手: \(.content)" else "\(.role): \(.content)" end'
                    fi
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
                log "[INFO] 已写入 $fpath（待补归档）+ sidecar $sidecar_path；已更新合并检查点 $MERGE_CHECKPOINT_FILE"
            fi
        else
            # 正常路径：云端成功或 cloud_summarizer 禁用
            : >"$CONFIG_DIR/.cloud_retry_count"
            rm -f "$CONFIG_DIR/.cloud_fail_alert" 2>/dev/null || true

            local _sentinel_hit _sentinel_lc
            _sentinel_hit=0
            if cloud_summarizer_enabled; then
                # ===== Fix 1b: 哨兵后闸 =====
                # 主判据：cloud_block 不含任何 [关键 tag；辅判据：含哨兵短语
                if [[ "$cloud_block" != *'[关键'* ]]; then
                    _sentinel_lc=$(echo "$cloud_block" | tr '[:upper:]' '[:lower:]')
                    if [[ "$_sentinel_lc" == *'无实质内容'* ]] || \
                       [[ "$_sentinel_lc" == *'仅系统'* ]] || \
                       [[ "$_sentinel_lc" == *'心跳'* ]]; then
                        _sentinel_hit=1
                        log "[INFO] Fix1b 哨兵后闸：云端摘要无 [关键 tag 且命中哨兵短语，不写块，推进 checkpoint + compact"
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
                        run_compact
                        exit 0
                    fi
                fi
            fi

            if [ "$_sentinel_hit" = "0" ]; then
                mkdir -p "$MEMORY_DIR"
                local day fpath ts_local ts_hhmm
                day=$(date +%Y-%m-%d)
                fpath="$MEMORY_DIR/${day}.md"
                ts_local=$(date '+%Y-%m-%d %H:%M:%S')
                ts_hhmm="${ts_local:11:5}"

                if [ ! -s "$fpath" ]; then
                    {
                        echo "---"
                        echo "title: \"${day} 会话记忆\""
                        echo "date: \"${day}\""
                        echo "---"
                        echo ""
                        echo "# ${day}"
                        echo ""
                    } >>"$fpath"
                fi

                if cloud_summarizer_enabled; then
                    # ===== Fix 2: 正常路径——云端成功 → 写摘要（根据 raw_detail 决定是否同时写原始细节）=====
                    if [ "$RAW_DETAIL" = "on" ]; then
                        # 旧行为回滚：也写原始细节
                        {
                            echo ""
                            echo "## ${ts_hhmm}"
                            echo ""
                            echo "### 原始细节"
                            echo ""
                            echo "$messages_all" | jq -r '.[] | if .role == "user" then "用户: \(.content)" elif .role == "assistant" then "助手: \(.content)" else "\(.role): \(.content)" end'
                            echo ""
                            echo "### 摘要"
                            echo ""
                            echo "$cloud_block"
                            echo ""
                        } >>"$fpath"
                    else
                        # Fix 2 默认 fallback_only: 只写摘要
                        {
                            echo ""
                            echo "## ${ts_hhmm}"
                            echo ""
                            echo "### 摘要"
                            echo ""
                            echo "$cloud_block"
                            echo ""
                        } >>"$fpath"
                    fi
                else
                    # ===== Fix 3A: cloud_summarizer 禁用 → 暂存原始细节(待补) =====
                    mkdir -p "$MEMORY_DIR/.pending"
                    local sidecar_path
                    sidecar_path="$MEMORY_DIR/.pending/${day}_${ts_hhmm}.json"
                    echo "$messages_all" >"$sidecar_path"
                    {
                        echo ""
                        echo "## ${ts_hhmm}"
                        echo ""
                        if [ "$RAW_DETAIL" = "off" ]; then
                            echo "### 原始细节(待补)"
                            echo ""
                            echo "- *（raw_detail=off：原始细节仅保留在 sidecar 中）*"
                        else
                            echo "### 原始细节(待补)"
                            echo ""
                            echo "$messages_all" | jq -r '.[] | if .role == "user" then "用户: \(.content)" elif .role == "assistant" then "助手: \(.content)" else "\(.role): \(.content)" end'
                        fi
                        echo ""
                    } >>"$fpath"
                    echo "$messages_all" >"$sidecar_path"
                    log "[INFO] cloud_summarizer 禁用，已写入 $fpath（待补归档）+ sidecar $sidecar_path"
                fi
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
            fi
        fi
    else
        log "[INFO] 跳过 memory（冷却）"
    fi

    # compact 仅在非可恢复失败时执行
    if [ "${cloud_recoverable_fail:-0}" != "1" ]; then
        run_compact
    else
        log "[INFO] 云端失败，跳过 sessions.compact（保留原始会话供重试）"
    fi
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
        reconcile)
            exec 9>>"$LOCK_FILE"
            with_lock do_reconcile
            ;;
        help)
            echo "Usage: $0 archive [--force] [--session <key>] [--agent <id>]"
            echo "       $0 log-maintenance   # 仅执行日志天龄清理 + 按大小轮转（读 config.yaml）"
            echo "       $0 reconcile          # 扫描 .pending 目录，补档待补摘要"
            echo "多通道: session.merge_jsonl_keys 或 DAILY_MEMORY_MERGE_KEYS"
            echo "日志: logging.log_max_bytes / log_keep_rotations / log_max_age_days；环境变量见 README"
            ;;
        *)
            echo "Unknown: $cmd" >&2
            exit 2
            ;;
    esac
}

# 仅在被直接执行时运行 CLI；被 source 时只导出函数，便于测试单独调用
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main_cli "$@"
fi
