#!/usr/bin/env bash
# 用法: cloud-summarizer.sh --file <plain.txt> openai-compatible <model> <base_url> <api_key>
# 输出: 为 OpenClaw Dream 模式优化的结构化 Markdown
set -euo pipefail
[ "${1:-}" = "--file" ] && shift && file="$1" && shift || exit 2
kind="$1" model="$2" base="$3" key="$4"
[ -f "$file" ] || exit 1

# 去掉 NUL，限制长度，避免 shell/jq 处理异常
body_tmp=$(mktemp)
payload_tmp=$(mktemp)
resp_tmp=$(mktemp)
chmod 600 "$body_tmp" "$payload_tmp" "$resp_tmp"
trap 'rm -f "$body_tmp" "$payload_tmp" "$resp_tmp"' EXIT
tr -d '\000' <"$file" | head -c 120000 >"$body_tmp"

# ============================================================================
# Dream 模式优化的 Prompt
# 输出格式包含：重要性标记、分类、可检索的结构化内容
# ============================================================================
sys='你是 Daily Memory Archiver 的对话归纳助手。请用中文输出以下严格结构化的内容，供 OpenClaw Dream 模式读取和长期记忆整合：

**核心要点**
- 每条用 "- " 开头，内容必须简洁、明确，可作为长期记忆存储
- 按重要性排序，最重要的放在前面
- ⚠️ 以下内容不属于"核心要点"，请勿写入：
  * 会话操作日志（如"XX:XX UTC - 上线""登录""重装 skill""执行命令"等系统事件）
  * 工具安装/卸载/更新的过程记录
  * cron 部署和时区切换的操作步骤
  * 这些属于系统运维日志，不构成可复用的长期知识

**决策与结论**
- 明确做出的决定、结论、选择
- 包含决策背景和原因

**已完成事项**
- 已完成的任务、实现的功能、解决的问题

**待办与计划**
- 后续需要执行的具体事项
- 如有时间节点请注明

**用户偏好与习惯**
- 明确的用户偏好、工作习惯、沟通方式
- 这是 Dream 模式重点提取的长期记忆

**技术/项目要点**
- 项目进展、技术方案、架构设计
- 代码规范、工具选择

**风险与注意事项**
- 需要留意的问题、潜在风险、注意事项

**创意与想法**
- 讨论中产生的新想法、灵感、可能性

重要说明：
1. 所有条目必须用 "- " 开头，保持列表格式
2. 内容要具体，避免模糊描述
3. Dream 模式会跨多天扫描这些分类，保持分类名称严格一致
4. 如果某分类下没有内容，写 "- 无"
5. 不要添加额外的解释或说明，只输出上述 8 个分类
6. 区分"知识"与"操作日志"：用户讨论了什么、决定了什么、偏好什么 → 知识，应写入对应分类；Agent 执行了什么操作、何时上线/下线、安装了哪些工具 → 操作日志，不应写入任何分类'

base="${base%/}"
case "$base" in
    */chat/completions) url="$base" ;;
    *) url="${base}/chat/completions" ;;
esac

# --rawfile 避免对话中的引号/反斜杠破坏 jq（需 jq ≥1.5）
# payload 写临时文件，避免 -d "$payload" 超过 ARG_MAX 导致 curl 失败
if ! jq -n \
    --arg m "$model" \
    --arg s "$sys" \
    --rawfile b "$body_tmp" \
    '{model:$m, temperature: 0.3, messages:[{role:"system",content:$s},{role:"user",content:("请归纳以下对话内容，严格按照 8 个分类的 Markdown 格式输出：\n\n" + $b)}]}' \
    >"$payload_tmp" 2>/dev/null; then
    echo "- *（构建请求 JSON 失败；检查 jq 版本与输入内容）*" >&2
    exit 1
fi

# response 写临时文件（-o），避免 resp=$(curl) 管道写入失败触发 curl: (23)
if ! curl -sS --max-time 120 -X POST "$url" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $key" \
    -d @"$payload_tmp" \
    -o "$resp_tmp"; then
    echo "- *（curl 请求失败）*" >&2
    exit 1
fi

if ! jq empty "$resp_tmp" 2>/dev/null; then
    echo "- *（API 返回非 JSON；可能被网关/HTML 拦截，见日志前 500 字）*" >&2
    head -c 500 "$resp_tmp" >>"${DAILY_MEMORY_LOG:-/dev/null}" 2>/dev/null || true
    exit 1
fi

if jq -e '.error' "$resp_tmp" >/dev/null 2>&1; then
    echo "- *（API 错误: $(jq -r '.error.message // .error | tostring' "$resp_tmp")）*" >&2
    exit 1
fi

out=$(jq -r '.choices[0].message.content // empty' "$resp_tmp")
if [ -z "$out" ]; then
    echo "- *（摘要响应为空）*"
    exit 1
fi
echo "$out"
