#!/usr/bin/env bash
# 统一配置加载与校验
# 供 archive-engine.sh / config-manager.sh 调用
# 同时为 OpenClaw Skill 对话交互提供结构化配置查询
set -euo pipefail

# 依赖环境：CONFIG_DIR 必须已设置
CRED_DIR="${CONFIG_DIR:?CONFIG_DIR must be set}"
CONFIG_FILE_DEFAULT="$CRED_DIR/config.yaml"

# yaml_scalar: 读取标量值（兼容原调用）
yaml_scalar() {
    local key="$1" file="${2:-$CONFIG_FILE_DEFAULT}"
    [ -f "$file" ] || return 0
    grep -E "^[[:space:]]*${key}:" "$file" 2>/dev/null | head -1 | \
        sed -E "s/^[[:space:]]*${key}:[[:space:]]*//" | \
        sed -E 's/^["'\'']//;s/["'\'']$//;s/[[:space:]]*$//;s/#.*$//'
}

# yaml_bool: 读取布尔值，归一化为 0/1
yaml_bool() {
    local key="$1" default="${2:-0}" file="${3:-$CONFIG_FILE_DEFAULT}"
    local val
    val=$(yaml_scalar "$key" "$file" || true)
    [ -z "$val" ] && { echo "$default"; return; }
    case "$(echo "$val" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')" in
        true|1|yes|on) echo 1 ;;
        *) echo 0 ;;
    esac
}

# canonical_uint: 归一化为正整数（兼容原调用）
# 注意：仅空字符串时返回默认值 d，明确传入 0 会保留 0（用于关闭功能如 log_max_bytes=0）
canonical_uint() {
    local v="${1:-}" d="${2:-0}"
    v=$(echo "$v" | tr -cd '0-9')
    if [ -z "$v" ]; then
        echo "$d"  # 空值 → 返回默认值
    else
        echo "$((10#$v))"  # 非空（包括 0）→ 原样返回
    fi
}

# 读取用户自定义噪声模式（每行一个关键词/正则
yaml_custom_noise_patterns() {
    local file="${1:-$CONFIG_FILE_DEFAULT}"
    [ -f "$file" ] || return 0
    awk '
      /^noise_filter:/ { ins=1; next }
      ins && /^[a-z][a-z0-9_]*:/ && !/^noise_filter/ { ins=0 }
      ins && /^[[:space:]]+custom_patterns:/ { inlist=1; next }
      inlist && /^[[:space:]]+-[[:space:]]/ {
          line=$0
          sub(/^[[:space:]]+-[[:space:]]+/, "", line)
          gsub(/^["'\'']|["'\'']$/, "", line)
          if (line != "" && line !~ /^#/ && line !~ /^[[:space:]]*$/) {
              sub(/[[:space:]]+#.*$/, "", line)
              print line
          }
          next
      }
      inlist && /^[[:space:]]+[a-zA-Z_][a-zA-Z0-9_.-]*:/ && !/^([[:space:]]+-)/ { inlist=0 }
    ' "$file"
}

# 读取 merge_jsonl_keys 列表（每行一个 key）
yaml_merge_keys() {
    local file="${1:-$CONFIG_FILE_DEFAULT}"
    [ -f "$file" ] || return 0
    awk '
      /^session:/ { ins=1; next }
      ins && /^[a-z][a-z0-9_]*:/ && !/^session/ { ins=0 }
      ins && /^[[:space:]]+merge_jsonl_keys:/ { inlist=1; next }
      inlist && /^[[:space:]]+-[[:space:]]/ {
          line=$0
          sub(/^[[:space:]]+-[[:space:]]+/, "", line)
          gsub(/^["'\'']|["'\'']$/, "", line)
          # 过滤：注释行、空行、纯空白行
          if (line != "" && line !~ /^#/ && line !~ /^[[:space:]]*$/) {
              # 去掉行尾注释
              sub(/[[:space:]]+#.*$/, "", line)
              print line
          }
          next
      }
      inlist && /^[[:space:]]+[a-zA-Z_][a-zA-Z0-9_.-]*:/ && !/^([[:space:]]+-)/ { inlist=0 }
    ' "$file"
}

# ============================================================================
# 统一配置校验：输出 shell 可 eval 的变量定义
# 用法：eval "$(config_load_all)"
# ============================================================================
config_load_all() {
    local file="${1:-$CONFIG_FILE_DEFAULT}"
    [ ! -f "$file" ] && return 1

    cat <<'EOF'
# ===== openclaw =====
EOF
    echo "AGENT_ID=\"$(yaml_scalar agent_id "$file" || echo main)\""

    cat <<'EOF'

# ===== archive =====
EOF
    echo "TRIGGER_MODE=\"$(yaml_scalar trigger_mode "$file" || echo threshold)\""
    echo "MAX_INPUT_TOKENS=$(canonical_uint "$(yaml_scalar max_input_tokens "$file")" 200000)"
    echo "CHECK_INTERVAL_MINUTES=$(canonical_uint "$(yaml_scalar check_interval_minutes "$file")" 5)"
    echo "PERIODIC_ARCHIVE_MINUTES=$(canonical_uint "$(yaml_scalar periodic_archive_minutes "$file")" 0)"
    echo "COOLDOWN_MINUTES=$(canonical_uint "$(yaml_scalar cooldown_minutes "$file")" 45)"
    echo "MIN_NEW_MESSAGES=$(canonical_uint "$(yaml_scalar min_new_messages "$file")" 1)"
    [ "$MIN_NEW_MESSAGES" -lt 1 ] 2>/dev/null && echo "MIN_NEW_MESSAGES=1"
    echo "COMPACT_MAX_LINES=$(canonical_uint "$(yaml_scalar max_lines "$file")" 400)"
    [ "$COMPACT_MAX_LINES" -lt 1 ] 2>/dev/null && echo "COMPACT_MAX_LINES=400"
    echo "COMPACT_ONLY_OVER_THRESHOLD=$(yaml_bool compact_only_over_threshold 1 "$file")"

    cat <<'EOF'

# ===== analyzer =====
EOF
    echo "MESSAGES_TO_ANALYZE=$(canonical_uint "$(yaml_scalar messages_to_analyze "$file")" 50)"
    [ "$MESSAGES_TO_ANALYZE" -lt 1 ] 2>/dev/null && echo "MESSAGES_TO_ANALYZE=50"
    echo "CHUNK_CLOUD_SUMMARY=$(yaml_bool chunk_cloud_summary 1 "$file")"
    echo "MAX_CLOUD_SUMMARY_CHUNKS=$(canonical_uint "$(yaml_scalar max_cloud_summary_chunks "$file")" 20)"
    [ "$MAX_CLOUD_SUMMARY_CHUNKS" -lt 1 ] 2>/dev/null && echo "MAX_CLOUD_SUMMARY_CHUNKS=20"
    echo "CLOUD_SUMMARIZER_ENABLED=$(yaml_bool 'cloud_summarizer.enabled' 1 "$file")"

    cat <<'EOF'

# ===== logging =====
EOF
    echo "LOG_MAX_BYTES=$(canonical_uint "$(yaml_scalar log_max_bytes "$file")" 0)"
    echo "LOG_KEEP_ROTATIONS=$(canonical_uint "$(yaml_scalar log_keep_rotations "$file")" 5)"
    [ "$LOG_KEEP_ROTATIONS" -lt 1 ] 2>/dev/null && echo "LOG_KEEP_ROTATIONS=5"
    echo "LOG_MAX_AGE_DAYS=$(canonical_uint "$(yaml_scalar log_max_age_days "$file")" 0)"

    cat <<'EOF'

# ===== output =====
EOF
    echo "MEMORY_DIR=\"$(yaml_scalar memory_dir "$file" || echo '')\""

    cat <<'EOF'

# ===== skill meta =====
EOF
    echo "CONFIG_SKILL_VERSION=\"$(yaml_scalar skill_version "$file" || echo '')\""
    echo "CONFIG_VERSION=\"$(yaml_scalar config_version "$file" || echo '')\""
}

# ============================================================================
# 为 OpenClaw Skill 对话交互提供：配置状态查询（JSON 输出）
# 用于：自然语言询问配置状态、确认修改建议等
# ============================================================================
config_get_status_json() {
    local file="${1:-$CONFIG_FILE_DEFAULT}"
    local has_creds=0 has_master=0
    [ -f "$CRED_DIR/credentials.enc" ] && has_creds=1
    [ -f "$CRED_DIR/.master_key" ] && has_master=1

    # 读取 merge keys
    local mk_json="[]"
    if [ -f "$file" ]; then
        mk_json=$(yaml_merge_keys "$file" | jq -R . | jq -s .)
    fi

    jq -n \
        --argjson has_config "$([ -f "$file" ] && echo 1 || echo 0)" \
        --argjson has_credentials "$has_creds" \
        --argjson has_master_key "$has_master" \
        --argjson has_checkpoint "$([ -f "$CRED_DIR/.archive_merge_checkpoint.json" ] && echo 1 || echo 0)" \
        --argjson has_last_archive "$([ -f "$CRED_DIR/.last_archive_ts" ] && echo 1 || echo 0)" \
        --arg trigger_mode "$(yaml_scalar trigger_mode "$file" 2>/dev/null || echo threshold)" \
        --argjson max_tokens "$(canonical_uint "$(yaml_scalar max_input_tokens "$file" 2>/dev/null)" 200000)" \
        --argjson periodic_minutes "$(canonical_uint "$(yaml_scalar periodic_archive_minutes "$file" 2>/dev/null)" 0)" \
        --argjson cloud_enabled "$(yaml_bool 'cloud_summarizer.enabled' 1 "$file")" \
        --argjson chunk_enabled "$(yaml_bool chunk_cloud_summary 1 "$file")" \
        --argjson compact_only_over_threshold "$(yaml_bool compact_only_over_threshold 1 "$file")" \
        --argjson merge_keys "$mk_json" \
        '{
            files: {
                config_exists: ($has_config == 1),
                credentials_encrypted: ($has_credentials == 1),
                master_key_exists: ($has_master_key == 1),
                checkpoint_exists: ($has_checkpoint == 1),
                last_archive_exists: ($has_last_archive == 1)
            },
            archive: {
                trigger_mode: $trigger_mode,
                max_input_tokens: $max_tokens,
                periodic_archive_minutes: $periodic_minutes,
                compact_only_over_threshold: ($compact_only_over_threshold == 1)
            },
            analyzer: {
                cloud_summarizer_enabled: ($cloud_enabled == 1),
                chunk_cloud_summary: ($chunk_enabled == 1)
            },
            session: {
                merge_keys: $merge_keys
            }
        }'
}

# ============================================================================
# 配置校验：返回所有不符合最佳实践的警告（供对话交互使用）
# ============================================================================
config_get_warnings() {
    local file="${1:-$CONFIG_FILE_DEFAULT}"
    local warnings=()

    [ ! -f "$file" ] && { echo "WARN: 缺少 config.yaml"; return; }

    # 凭证相关
    [ ! -f "$CRED_DIR/credentials.enc" ] && warnings+=("API 凭证未设置（credentials.enc 不存在）")
    [ ! -f "$CRED_DIR/.master_key" ] && warnings+=("缺少 .master_key，无法解密凭证")

    # 触发模式建议
    local tm
    tm=$(yaml_scalar trigger_mode "$file")
    [ "$tm" = "threshold" ] && [ "$(yaml_scalar periodic_archive_minutes "$file")" = "0" ] && \
        warnings+=("建议设置 periodic_archive_minutes>0（如 120），避免对话较少时永不归档")

    # merge keys 建议
    local mk_count
    mk_count=$(yaml_merge_keys "$file" | wc -l)
    [ "$mk_count" -eq 0 ] && warnings+=("merge_jsonl_keys 为空，将只使用默认 session key")

    # 输出
    if [ ${#warnings[@]} -gt 0 ]; then
        for w in "${warnings[@]}"; do
            echo "$w"
        done
    fi
}
