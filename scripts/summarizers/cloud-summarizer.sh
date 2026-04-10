#!/usr/bin/env bash
# 用法: cloud-summarizer.sh --file <plain.txt> openai-compatible <model> <base_url> <api_key>
set -euo pipefail
[ "${1:-}" = "--file" ] && shift && file="$1" && shift || exit 2
kind="$1" model="$2" base="$3" key="$4"
[ -f "$file" ] || exit 1

# 去掉 NUL，限制长度，避免 shell/jq 处理异常
body_tmp=$(mktemp)
chmod 600 "$body_tmp"
tr -d '\000' <"$file" | head -c 120000 >"$body_tmp"

sys='你是会话归档助手。用中文 Markdown bullet 输出：核心决策、行动项、关键讨论。简洁，勿复述全文。'

base="${base%/}"
case "$base" in
    */chat/completions) url="$base" ;;
    *) url="${base}/chat/completions" ;;
esac

# --rawfile 避免对话中的引号/反斜杠破坏 jq（需 jq ≥1.5）
if ! payload=$(jq -n \
    --arg m "$model" \
    --arg s "$sys" \
    --rawfile b "$body_tmp" \
    '{model:$m, messages:[{role:"system",content:$s},{role:"user",content:("以下为近期对话摘录，请归纳：\n\n" + $b)}], temperature:0.3}' 2>/dev/null); then
    echo "- *（构建请求 JSON 失败；检查 jq 版本与输入内容）*" >&2
    rm -f "$body_tmp"
    exit 1
fi
rm -f "$body_tmp"

resp=$(curl -sS --max-time 120 -X POST "$url" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $key" \
    -d "$payload") || {
    echo "- *（curl 请求失败）*" >&2
    exit 1
}

if ! echo "$resp" | jq empty 2>/dev/null; then
    echo "- *（API 返回非 JSON；可能被网关/HTML 拦截，见日志前 500 字）*" >&2
    echo "$resp" | head -c 500 >>"${DAILY_MEMORY_LOG:-/dev/null}" 2>/dev/null || true
    exit 1
fi

if echo "$resp" | jq -e '.error' >/dev/null 2>&1; then
    echo "- *（API 错误: $(echo "$resp" | jq -r '.error.message // .error | tostring')）*" >&2
    exit 1
fi

out=$(echo "$resp" | jq -r '.choices[0].message.content // empty')
if [ -z "$out" ]; then
    echo "- *（摘要响应为空）*"
    exit 1
fi
echo "$out"
