#!/usr/bin/env bash
# test-three-file-sync-gate.sh — 三文件同步闸的家底覆盖回归测试（无依赖 claude CLI）。
# 契约：一个工作单元若有未提交的代码/**家底**改动而 progress.md 未同步，Stop 闸须拦停
#   （decision:block）。家底 = .claude/** 下的可控文件（CLAUDE.md / agents / skills / settings.json
#   等），它们与 .sh/.py 同属「改了要记 progress」的范畴；只有 .claude/evidence/（账本，机器写）
#   除外。
# 红测试：现状闸的代码集只认 .sh/.ps1/.ts/.py 等扩展名，不含 .md/.json，故「只改家底 .md/.json」
#   漏判不拦 → 本测试的家底用例 FAIL；修复（.claude/** 纳入、排除 .claude/evidence/）后 → PASS。
# 同带：① 只改普通代码 .sh 仍拦（对照绿，防修复回归）② 只改 .claude/evidence/ 不拦（边界）。
# 临时 git 仓建在 scratchpad，trap 清理。
set -eu

HOOK=$(cd "$(dirname "$0")/.." && pwd)/hooks/three-file-sync-gate.sh
[ -x "$HOOK" ] || { echo "test-three-file-sync-gate: 缺 hook：$HOOK" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  [PASS] $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  [FAIL] $1"; }

# 建一个干净的临时仓：progress.md + 家底 + 普通代码 + evidence 账本，全部已提交。
fresh_repo() {
  local t="$1"
  rm -rf "$t"
  mkdir -p "$t/.claude/agents" "$t/.claude/skills/x" "$t/.claude/evidence" "$t/src"
  git -C "$t" init -q
  git -C "$t" config user.email t@t.t
  git -C "$t" config user.name t
  printf '# progress\n' > "$t/progress.md"
  printf '# claude\n'   > "$t/.claude/CLAUDE.md"
  printf '{"a":1}\n'    > "$t/.claude/settings.json"
  printf '# agent\n'    > "$t/.claude/agents/impl.md"
  printf '# skill\n'    > "$t/.claude/skills/x/SKILL.md"
  printf 'echo hi\n'    > "$t/src/app.sh"
  printf 'log\n'        > "$t/.claude/evidence/gate-block.log"
  git -C "$t" add -A
  git -C "$t" commit -qm init
}

# 跑闸，回显 stdout（block 时为 {"decision":"block",...}，放行时为空）。
run_gate() {
  local t="$1"
  CLAUDE_PROJECT_DIR="$t" bash "$HOOK" 2>/dev/null
}

# 断言改某家底文件（progress 未同步）→ 必须 block。
assert_family_blocks() {
  local relpath="$1" t="$TMP/repo"
  fresh_repo "$t"
  printf 'changed\n' >> "$t/$relpath"
  local out; out=$(run_gate "$t")
  if printf '%s' "$out" | grep -q '"decision":"block"'; then
    pass "改家底 $relpath（progress 未同步）→ 闸拦停"
  else
    fail "改家底 $relpath（progress 未同步）→ 闸放行了，漏判（期望 decision:block，实得：[${out}]）"
  fi
}

echo "── 红：只改家底文件，progress 未同步 → 应拦停 ──"
assert_family_blocks ".claude/CLAUDE.md"
assert_family_blocks ".claude/settings.json"
assert_family_blocks ".claude/agents/impl.md"
assert_family_blocks ".claude/skills/x/SKILL.md"

echo "── 绿对照：只改普通代码 .sh，progress 未同步 → 应拦停（防修复回归）──"
{
  t="$TMP/repo"; fresh_repo "$t"
  printf 'echo more\n' >> "$t/src/app.sh"
  out=$(run_gate "$t")
  if printf '%s' "$out" | grep -q '"decision":"block"'; then
    pass "改 src/app.sh（progress 未同步）→ 闸拦停"
  else
    fail "改 src/app.sh（progress 未同步）→ 未拦停（期望 decision:block，实得：[${out}]）"
  fi
}

echo "── 边界：只改 .claude/evidence/ 账本，progress 未同步 → 不应拦停 ──"
{
  t="$TMP/repo"; fresh_repo "$t"
  printf 'more log\n' >> "$t/.claude/evidence/gate-block.log"
  out=$(run_gate "$t")
  if printf '%s' "$out" | grep -q '"decision":"block"'; then
    fail ".claude/evidence/ 改动被拦停了（期望放行，实得：[${out}]）"
  else
    pass ".claude/evidence/ 改动→ 闸放行（账本机器写，不计入家底）"
  fi
}

echo ""
echo "==== test-three-file-sync-gate：PASS=$PASS FAIL=$FAIL ===="
if [ "$FAIL" -gt 0 ]; then
  echo "test-three-file-sync-gate: failed（家底 .md/.json 改动未纳入闸的代码集，漏判不拦）" >&2
  exit 1
fi
echo "test-three-file-sync-gate: passed（家底改动拦停、普通代码拦停、evidence 放行均符合契约）"
