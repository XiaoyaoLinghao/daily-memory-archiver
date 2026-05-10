#!/usr/bin/env bash
# stdin: JSON [{role,content},…]；arg1：最多分析条数（从尾部截取）
# 输出：供 Dream 模式读取的结构化本地提取要点
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${DAILY_MEMORY_CONFIG_DIR:-$(cd "$SCRIPT_DIR/../../config" && pwd)}"
# shellcheck source=../lib/conversation-noise.sh
source "$SCRIPT_DIR/../lib/conversation-noise.sh"

# 加载用户自定义噪声过滤规则
load_custom_noise_patterns "$CONFIG_DIR"

raw_take="${1:-50}"
t=$(printf '%s' "$raw_take" | tr -cd '0-9')
[ -n "$t" ] && [ "$((10#$t))" -ge 1 ] 2>/dev/null || t=50
msgs=$(cat)
slice=$(echo "$msgs" | jq --argjson t "$t" 'if length > $t then .[-($t):] else . end')

# ============================================================================
# 本地关键词提取 - Dream 模式优化版
# 分类更明确，便于机器读取和跨天整合
# ============================================================================

decisions=""        # 🎯 决策与结论
plans=""            # 📋 计划与待办
done_items=""       # ✅ 已完成
discuss=""          # 💬 关键讨论
preferences=""      # 🧠 用户偏好
project_notes=""    # 🔧 项目要点
risks=""            # ⚠️ 风险与注意
facts=""            # 📌 重要事实

while IFS= read -r line; do
    role=$(echo "$line" | jq -r '.role')
    content=$(echo "$line" | jq -r '.content // ""' | tr '\n\r' '  ' | head -c 600)
    # 先检查整条消息是否为噪声
    is_noise_message "$content" && continue
    # 再检查单行噪声
    is_conversation_noise_line "$content" && continue
    lc=$(echo "$content" | tr '[:upper:]' '[:lower:]')

    if [[ "$role" == "user" || "$role" == "assistant" ]]; then
        # 🎯 决策
        if echo "$lc" | grep -qiE '决定|采用|方案|选用|确认|拍板|定了|就这么|同意|拒绝'; then
            decisions+="- ${content:0:280}"$'\n'
        fi
        # 📋 计划待办
        if echo "$lc" | grep -qiE '计划|待办|下一步|需要.*做|将.*完成|要.*做|应该|todo|TODO|安排'; then
            plans+="- ${content:0:280}"$'\n'
        fi
        # ✅ 已完成
        if echo "$lc" | grep -qiE '已完成|搞定|实现|部署成功|通过|修复|完成了|做好了'; then
            done_items+="- ${content:0:200}"$'\n'
        fi
        # 💬 关键讨论
        if echo "$lc" | grep -qiE '讨论|问题|风险|注意|疑问|困惑|不懂|为什么|怎么'; then
            discuss+="- ${content:0:220}"$'\n'
        fi
        # 🧠 用户偏好
        if echo "$lc" | grep -qiE '我喜欢|我偏好|我习惯|希望|想要|不要|别|最好|推荐|觉得|认为'; then
            preferences+="- ${content:0:280}"$'\n'
        fi
        # 🔧 项目/技术要点
        if echo "$lc" | grep -qiE '代码|bug|测试|部署|架构|设计|接口|API|函数|类|模块|文件|目录|项目|仓库'; then
            project_notes+="- ${content:0:280}"$'\n'
        fi
        # ⚠️ 风险
        if echo "$lc" | grep -qiE '风险|小心|注意|可能会|容易|问题|麻烦|担心|怕|别忘了'; then
            risks+="- ${content:0:220}"$'\n'
        fi
        # 📌 重要事实
        if echo "$lc" | grep -qiE '是|叫|名为|等于|就是|实际上|事实上|本质上|其实'; then
            facts+="- ${content:0:220}"$'\n'
        fi
    fi
done < <(echo "$slice" | jq -c '.[]')

# ============================================================================
# 输出统一格式（与 cloud-summarizer 分类一致，便于 Dream 模式整合）
# ============================================================================

emit_section() {
    local title="$1" body="$2"
    echo "**$title**"
    if [ -z "$(echo "$body" | tr -d '[:space:]')" ]; then
        echo "- 无"
    else
        echo "$body" | head -n 14
    fi
    echo ""
}

emit_section "重要事实" "$facts"
emit_section "决策与结论" "$decisions"
emit_section "已完成事项" "$done_items"
emit_section "计划与待办" "$plans"
emit_section "用户偏好" "$preferences"
emit_section "项目与技术要点" "$project_notes"
emit_section "风险与注意" "$risks"
emit_section "关键讨论" "$discuss"
