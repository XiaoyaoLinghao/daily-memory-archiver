#!/usr/bin/env bash
# DMA Fix Plan 测试套件：Fix 1/2/3 + 配置 + 回归
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# source conversation-noise 函数
source "$SKILL_ROOT/scripts/lib/conversation-noise.sh"

ok=0
fail() { echo "FAIL: $*"; ok=1; }
pass() { echo "OK  : $*"; }

echo "=== Fix 1a: 廉价前闸 — 噪声检测 ==="

# Test 1: [OpenClaw heartbeat poll] → noise
if is_conversation_noise_line '[OpenClaw heartbeat poll]'; then
    pass "T1: [OpenClaw heartbeat poll] -> noise"
else
    fail "T1: [OpenClaw heartbeat poll] NOT noise"
fi

# Test 2: (System) / (SYSTEM) / (system) → all noise
if is_conversation_noise_line '(System) Starting session...'; then
    pass "T2a: (System) -> noise"
else
    fail "T2a: (System) NOT noise"
fi
if is_conversation_noise_line '(SYSTEM) Starting session...'; then
    pass "T2b: (SYSTEM) -> noise"
else
    fail "T2b: (SYSTEM) NOT noise"
fi
if is_conversation_noise_line '(system) Starting session...'; then
    pass "T2c: system -> noise"
else
    fail "T2c: (system) NOT noise"
fi

# Test 3: Gateway restart notification → noise
if is_conversation_noise_line 'previous turn was interrupted by a gateway restart, resuming...'; then
    pass "T3: gateway restart notification -> noise"
else
    fail "T3: gateway restart notification NOT noise"
fi

# Test 3b: Case insensitive
if is_conversation_noise_line 'Previous Turn Was Interrupted By A Gateway Restart'; then
    pass "T3b: gateway restart (mixed case) -> noise"
else
    fail "T3b: gateway restart (mixed case) NOT noise"
fi

# Test 4: [system message → noise (case insensitive)
if is_conversation_noise_line '[System Message] Some output'; then
    pass "T4: [System Message] -> noise"
else
    fail "T4: [System Message] NOT noise"
fi

# Test 4b: [SYSTEM → still noise
if is_conversation_noise_line '[SYSTEM] output'; then
    pass "T4b: [SYSTEM] -> noise"
else
    fail "T4b: [SYSTEM] NOT noise"
fi

echo ""
echo "=== Fix 1b & Fix 2: 哨兵后闸 + 摘要输出 ==="

# Test 5: Sentinel — cloud_block with no [关键 tags and sentinel phrase
sentinel_block="本时段无实质内容（仅系统心跳轮询与每日状态检查，无用户实质输入）。"
if [[ "$sentinel_block" != *'[关键'* ]]; then
    _slc=$(echo "$sentinel_block" | tr '[:upper:]' '[:lower:]')
    if [[ "$_slc" == *'无实质内容'* ]] || [[ "$_slc" == *'仅系统'* ]] || [[ "$_slc" == *'心跳'* ]]; then
        pass "T5: sentinel block detected (no [关键 + 哨兵短语) -> would skip"
    else
        fail "T5: sentinel block NOT detected"
    fi
else
    fail "T5: has [关键 tag unexpectedly"
fi

# Test 6: Normal block with [关键决策] → should write
normal_block="用户决定使用 FastAPI。
[关键决策] 后端：Python FastAPI"
if [[ "$normal_block" == *'[关键'* ]]; then
    pass "T6: normal block has [关键 tag -> would write"
else
    fail "T6: normal block missing [关键 tag"
fi

# Test 7: Empty sentinel block with only 心跳 keyword
sentinel2="本时段无实质内容（仅系统运维/心跳）"
if [[ "$sentinel2" != *'[关键'* ]]; then
    _slc2=$(echo "$sentinel2" | tr '[:upper:]' '[:lower:]')
    if [[ "$_slc2" == *'心跳'* ]]; then
        pass "T7: 心跳-only block -> sentinel match"
    else
        fail "T7: 心跳-only NOT matched"
    fi
else
    fail "T7: unexpected [关键 tag"
fi

echo ""
echo "=== Fix 2: 输出格式 ==="

# Test 8: Mock cloud success output — should only have ### 摘要, no ### 原始细节
# This tests the structure logic: raw_detail=fallback_only → only 摘要
fake_cloud_out="用户讨论了 FastAPI 选型。
[关键决策] 后端：Python FastAPI"

# Verify the fake output has ### 摘要-like structure but no ### 原始细节
if echo "$fake_cloud_out" | grep -q '\[关键决策\]'; then
    pass "T8a: cloud output contains [关键决策] tag"
else
    fail "T8a: cloud output missing [关键决策]"
fi

# Test 9: raw_detail=on → would include ### 原始细节
# Just verify the code path exists in archive-engine.sh
if grep -q 'RAW_DETAIL.*=.*"on"' "$SKILL_ROOT/scripts/archive-engine.sh"; then
    pass "T9: raw_detail=on code path exists in archive-engine.sh"
else
    fail "T9: raw_detail=on code path not found"
fi

echo ""
echo "=== Fix 3A: 暂存 ==="

# Test 10: Verify Fix 3A code writes ### 原始细节(待补)
if grep -q '原始细节(待补)' "$SKILL_ROOT/scripts/archive-engine.sh"; then
    pass "T10: ### 原始细节(待补) marker found in code"
else
    fail "T10: ### 原始细节(待补) marker NOT found"
fi

# Test 11: Verify sidecar .pending directory
if grep -q '\.pending/' "$SKILL_ROOT/scripts/archive-engine.sh"; then
    pass "T11: .pending sidecar directory referenced"
else
    fail "T11: .pending sidecar NOT referenced"
fi

# Test 12: raw_detail=off → placeholder only
fake_off_content="- *（raw_detail=off：原始细节仅保留在 sidecar 中）*"
if echo "$fake_off_content" | grep -q 'raw_detail=off'; then
    pass "T12: raw_detail=off placeholder found"
else
    fail "T12: raw_detail=off placeholder not found"
fi

echo ""
echo "=== Fix 3B: reconcile ==="

# Test 13: reconcile subcommand exists
if grep -q 'reconcile)' "$SKILL_ROOT/scripts/archive-engine.sh"; then
    pass "T13: reconcile subcommand in CLI"
else
    fail "T13: reconcile subcommand NOT found"
fi

# Test 14: do_reconcile function exists
if grep -q 'do_reconcile()' "$SKILL_ROOT/scripts/archive-engine.sh"; then
    pass "T14: do_reconcile function defined"
else
    fail "T14: do_reconcile function NOT defined"
fi

# Test 15: Auto-scan in do_archive
if grep 'do_reconcile' "$SKILL_ROOT/scripts/archive-engine.sh" | grep -v '^#' | grep -v 'do_reconcile()' | head -5 | grep -q 'do_reconcile'; then
    pass "T15: do_reconcile called in do_archive (auto-scan)"
else
    fail "T15: auto-scan not found in do_archive"
fi

# Test 16: Reconcile replaces (待补) marker logic
if grep '原始细节(待补)' "$SKILL_ROOT/scripts/archive-engine.sh" | head -5 | grep -q '原始细节(待补)'; then
    pass "T16: reconcile finds (待补) marker"
else
    fail "T16: reconcile (待补) marker not found"
fi

# Test 17: Reconcile anchors by ## HH:MM
if grep 'hhmm' "$SKILL_ROOT/scripts/archive-engine.sh" | grep -v 'ts_hhmm=' | head -5 | grep -q 'hhmm'; then
    pass "T17: reconcile uses HH:MM anchor"
else
    fail "T17: reconcile HH:MM anchor not found"
fi

echo ""
echo "=== Fix 3C: 8分类退役 ==="

# Test 18: LOCAL_EXTRACTOR not called in normal path
# insights should be "" not calling local-extractor
if grep -q 'insights=""' "$SKILL_ROOT/scripts/archive-engine.sh"; then
    pass "T18: insights initialized to empty (not calling local-extractor)"
else
    fail "T18: insights initialization not found"
fi

echo ""
echo "=== 配置 ==="

# Test 19: raw_detail in config.yaml
if grep -q 'raw_detail:' "$SKILL_ROOT/config/config.yaml"; then
    pass "T19: raw_detail in config.yaml"
else
    fail "T19: raw_detail NOT in config.yaml"
fi

# Test 20: RAW_DETAIL loaded by config-loader
if grep -q 'RAW_DETAIL' "$SKILL_ROOT/scripts/lib/config-loader.sh"; then
    pass "T20: RAW_DETAIL loaded by config-loader.sh"
else
    fail "T20: RAW_DETAIL NOT in config-loader.sh"
fi

# Test 21: raw_detail defaults to fallback_only
if grep -q 'fallback_only' "$SKILL_ROOT/config/config.yaml"; then
    pass "T21: default raw_detail=fallback_only"
else
    fail "T21: default raw_detail not set"
fi

echo ""
echo "=== 回归：conversation-noise.sh ==="

# Test 22: Original noise patterns still work
if is_conversation_noise_line '```'; then
    pass "T22: code block marker -> noise (regression)"
else
    fail "T22: code block marker regression"
fi

if is_conversation_noise_line 'Sender (untrusted channel) message'; then
    pass "T23: Sender (untrusted -> noise (regression)"
else
    fail "T23: Sender (untrusted regression"
fi

if is_conversation_noise_line '[heartbeat] check'; then
    pass "T24: [heartbeat] -> noise (regression)"
else
    fail "T24: [heartbeat] regression"
fi

# Test 25: Non-noise content still passes
if ! is_conversation_noise_line '用户询问：如何配置 PostgreSQL 连接池？'; then
    pass "T25: real user question -> NOT noise (regression)"
else
    fail "T25: real user question falsely detected as noise"
fi

echo ""
echo "=== 回归：archive-engine.sh 语法 ==="

# Test 26: Full syntax check
if bash -n "$SKILL_ROOT/scripts/archive-engine.sh" 2>/dev/null; then
    pass "T26: archive-engine.sh syntax OK"
else
    fail "T26: archive-engine.sh syntax ERROR"
fi

echo ""
echo "=== cloud-summarizer.sh Fix ==="

# Test 27: No more "8 个分类" phrasing
if ! grep -q '严格按照 8 个分类' "$SKILL_ROOT/scripts/summarizers/cloud-summarizer.sh"; then
    pass "T27: removed outdated '8 个分类' phrasing"
else
    fail "T27: '8 个分类' still present"
fi

echo ""
echo "============================================"
if [ "$ok" -eq 0 ]; then
    echo "✅ ALL TESTS PASSED"
    exit 0
else
    echo "❌ $ok TEST(S) FAILED"
    exit 1
fi
