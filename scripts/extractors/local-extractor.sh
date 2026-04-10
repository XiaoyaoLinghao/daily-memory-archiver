#!/usr/bin/env bash
# stdin: JSON [{role,content},…]；arg1：最多分析条数（从尾部截取）
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/conversation-noise.sh
source "$SCRIPT_DIR/../lib/conversation-noise.sh"

TAKE="${1:-50}"
msgs=$(cat)
slice=$(echo "$msgs" | jq --argjson t "$TAKE" 'if length > $t then .[-($t):] else . end')

decisions=""
plans=""
done_items=""
discuss=""

while IFS= read -r line; do
    role=$(echo "$line" | jq -r '.role')
    content=$(echo "$line" | jq -r '.content // ""' | tr '\n\r' '  ' | head -c 600)
    is_conversation_noise_line "$content" && continue
    lc=$(echo "$content" | tr '[:upper:]' '[:lower:]')
    if [[ "$role" == "user" || "$role" == "assistant" ]]; then
        if echo "$lc" | grep -qiE '决定|采用|方案|选用|确认|拍板'; then
            decisions+="- ${content:0:280}"$'\n'
        fi
        if echo "$lc" | grep -qiE '计划|待办|下一步|需要.*做|将.*完成'; then
            plans+="- ${content:0:280}"$'\n'
        fi
        if echo "$lc" | grep -qiE '已完成|搞定|实现|部署成功|通过'; then
            done_items+="- **完成**: ${content:0:200}"$'\n'
        fi
        if echo "$lc" | grep -qiE '讨论|问题|风险|注意'; then
            discuss+="- ${content:0:220}"$'\n'
        fi
    fi
done < <(echo "$slice" | jq -c '.[]')

emit() {
    local title="$1" body="$2"
    echo "#### $title"
    if [ -z "$(echo "$body" | tr -d '[:space:]')" ]; then
        echo "- *(本次归档未识别明确条目)*"
    else
        echo "$body" | head -n 14
    fi
    echo ""
}

emit "关键决策" "$decisions"
emit "工作计划" "$plans"
emit "执行进展" "$done_items"
emit "关键讨论" "$discuss"
