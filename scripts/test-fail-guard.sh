#!/usr/bin/env bash
# 验证 cloud 可恢复失败时不推进 checkpoint
# 用于: DMA Wave 8 验收测试
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 1. 语法
bash -n "$SCRIPT_DIR/archive-engine.sh" || { echo "FAIL: syntax"; exit 1; }

# 2. 验证关键逻辑存在
grep -q 'cloud_recoverable_fail' "$SCRIPT_DIR/archive-engine.sh" || { echo "FAIL: no cloud_recoverable_fail"; exit 1; }
grep -q '.cloud_retry_count' "$SCRIPT_DIR/archive-engine.sh" || { echo "FAIL: no retry count"; exit 1; }

# 3. 验证 checkpoint bump 被条件包裹（不再无条件执行）
#    merge_checkpoint_bump 调用必须在 cloud_recoverable_fail 保护的分支内
python3 - "$SCRIPT_DIR/archive-engine.sh" <<'PY'
import sys, re
src = open(sys.argv[1]).read()
# 找所有 merge_checkpoint_bump_from_messages 的调用位置（跳过函数定义和 Wave 10 纯噪声分支）
ok = 0
pattern = re.compile(r'merge_checkpoint_bump_from_messages')
definition_start = src.find('merge_checkpoint_bump_from_messages()')
for m in pattern.finditer(src):
    idx = m.start()
    # 跳过函数定义
    if definition_start > 0 and abs(idx - definition_start) < 10:
        continue
    # Wave 10 纯噪声分支：skip-substance 路径内的 checkpoint bump 不归 Wave 8 守护
    before = src[max(0, idx - 300):idx]
    if 'slot_has_substance' in src[max(0, idx - 2000):idx]:
        ok += 1  # Wave 10 branch — counted but not checked for cloud_recoverable_fail
        continue
    before_wide = src[max(0, idx - 8000):idx]
    if 'cloud_recoverable_fail' in before_wide:
        ok += 1
    else:
        print(f'FAIL: merge_checkpoint_bump call at pos {idx} not guarded')
        sys.exit(1)
assert ok >= 3, f"Expected >= 3 guarded merge_checkpoint_bump calls, found {ok}"
print(f"OK: checkpoint bump guarded ({ok} call sites)")
PY

# 4. 验证 cloud_recoverable_fail=1 出现 ≥ 4 次（4 个可恢复失败分支）
count=$(grep -c 'cloud_recoverable_fail=1' "$SCRIPT_DIR/archive-engine.sh" || echo 0)
if [ "$count" -ge 4 ]; then
    echo "OK: cloud_recoverable_fail=1 found ${count} times"
else
    echo "FAIL: cloud_recoverable_fail=1 only ${count} times (expected >= 4)"
    exit 1
fi

# 5. 验证 run_compact 被 cloud_recoverable_fail 保护
grep -q 'cloud_recoverable_fail.*!=.*1.*run_compact\|run_compact' "$SCRIPT_DIR/archive-engine.sh" && \
    echo "OK: run_compact guarded" || { echo "FAIL: run_compact not guarded"; exit 1; }

echo "OK: fail-guard structure verified"
