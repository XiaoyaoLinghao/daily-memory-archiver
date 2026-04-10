#!/usr/bin/env bash
# 用法: cloud-summarizer.sh --file <plain.txt> openai-compatible <model> <base_url> <api_key>
set -euo pipefail
[ "${1:-}" = "--file" ] && shift && file="$1" && shift || exit 2
kind="$1" model="$2" base="$3" key="$4"
[ -f "$file" ] || exit 1
text=$(cat "$file")
[ -n "$text" ] || { echo "- *（无文本可摘要）*"; exit 0; }

# 去掉末尾斜杠，补全 chat/completions
base="${base%/}"
case "$base" in
    */chat/completions) url="$base" ;;
    *) url="${base}/chat/completions" ;;
esac

sys='你是会话归档助手。用中文 Markdown  bullet 输出：核心决策、行动项、关键讨论。简洁，勿复述全文。'
user_msg="以下为近期对话摘录，请归纳：\n\n${text:0:120000}"

payload=$(jq -n \
    --arg m "$model" \
    --arg s "$sys" \
    --arg u "$user_msg" \
    '{model:$m, messages:[{role:"system",content:$s},{role:"user",content:$u}], temperature:0.3}')

resp=$(curl -sS --max-time 120 -X POST "$url" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $key" \
    -d "$payload") || exit 1

if echo "$resp" | jq -e '.error' >/dev/null 2>&1; then
    echo "- *（API 错误: $(echo "$resp" | jq -r '.error.message // .error')）*" >&2
    exit 1
fi

out=$(echo "$resp" | jq -r '.choices[0].message.content // empty')
if [ -z "$out" ]; then
    echo "- *（摘要响应为空）*"
    exit 1
fi
echo "$out"
