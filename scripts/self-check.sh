#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ok=0
fail() { echo "FAIL: $*"; ok=1; }
pass() { echo "OK  : $*"; }

command -v bash >/dev/null || fail bash
command -v jq >/dev/null || fail jq
command -v openssl >/dev/null || fail openssl
command -v curl >/dev/null || fail curl

[ -x "$ROOT/scripts/archive-engine.sh" ] || fail "archive-engine.sh not executable"
[ -x "$ROOT/scripts/config-manager.sh" ] || fail "config-manager.sh not executable"
[ -f "$ROOT/scripts/lib/credentials-store.sh" ] || fail credentials-store
[ -f "$ROOT/SKILL.md" ] || fail SKILL.md

bash -n "$ROOT/scripts/archive-engine.sh" || fail "archive-engine bash -n"
bash -n "$ROOT/scripts/config-manager.sh" || fail "config-manager bash -n"

pass "依赖与脚本语法"
exit "$ok"
