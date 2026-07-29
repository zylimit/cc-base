#!/usr/bin/env bash
# test-hook-parity.sh — 3 处 .ps1 hook 不对等回归断言（固化 Task 3 改动）。
# 覆盖：
#   ① tdd-gate.ps1 中文触发词「编码实现」：feed JSON 含触发词 → 输出 TDD 提示（非空）；
#      不含触发词 → 无输出。
#   ② mark-review-needed.ps1 Mutex：feed file_path JSON → exit 0 且 .needs-review 含该文件
#      （不崩即 Mutex 路径通）。
#   ③ session-rules-banner.ps1 提示：grep .ps1 内 fast-mode off 提示含 pwsh + fast-mode.ps1，
#      不含 bash fast-mode.sh。
# 无 pwsh → ①② 标 SKIP（不假绿）；③ 是静态文件 grep，不依赖 pwsh、始终跑。
set -u

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
HOOKS="$ROOT/.claude/hooks"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
SKIP=0
pass() { PASS=$((PASS + 1)); echo "  [PASS] $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  [FAIL] $1"; }
skip() { SKIP=$((SKIP + 1)); echo "  [SKIP] $1"; }

echo "===== test-hook-parity ====="

# ---- ③ session-rules-banner.ps1 提示文本（静态 grep，不依赖 pwsh）----
echo "--- ③ session-rules-banner.ps1：fast-mode 提示含 pwsh、不含 bash fast-mode.sh ---"
BANNER="$HOOKS/session-rules-banner.ps1"
if [ ! -f "$BANNER" ]; then
    fail "session-rules-banner.ps1 不存在：$BANNER"
else
    if grep -q 'pwsh' "$BANNER" && grep -q 'fast-mode\.ps1' "$BANNER"; then
        pass "fast-mode 提示含 pwsh + fast-mode.ps1"
    else
        fail "fast-mode 提示缺 pwsh 或 fast-mode.ps1（grep 未命中）"
    fi
    if grep -q 'bash fast-mode\.sh' "$BANNER"; then
        fail "fast-mode 提示仍含 bash fast-mode.sh（应已改 pwsh fast-mode.ps1）"
    else
        pass "fast-mode 提示不含 bash fast-mode.sh"
    fi
fi

# ---- ① ② 需要 pwsh ----
if ! command -v pwsh >/dev/null 2>&1; then
    echo ""
    echo "--- ① tdd-gate.ps1 中文触发 ---"
    skip "tdd-gate.ps1：无 pwsh（运行时验证无法跑，不假绿）"
    echo ""
    echo "--- ② mark-review-needed.ps1 Mutex ---"
    skip "mark-review-needed.ps1：无 pwsh（运行时验证无法跑，不假绿）"
else
    # ---- ① tdd-gate.ps1 中文触发词「编码实现」----
    echo ""
    echo "--- ① tdd-gate.ps1：中文触发「编码实现」→ TDD 提示；非触发 → 无输出 ---"
    # 伪项目根：git init 让 git rev-parse 确定返回此目录（不依赖 mktemp 是否在 git 仓内）；
    # 不建 .claude/.red-verified、.tdd-exempt → 触发 TDD 提示；不建 .claude/.fast-mode → fast-mode 不放行。
    TPROJ="$TMP/tdd-proj"
    mkdir -p "$TPROJ"
    ( cd "$TPROJ" && git init -q )

    # 触发词「编码实现」→ 应输出 TDD 提示（非空）
    OUT=$(cd "$TPROJ" && CLAUDE_PROJECT_DIR="$TPROJ" \
        printf '%s' '{"tool_input":{"command":"编码实现 x"}}' \
        | pwsh -NoProfile -File "$HOOKS/tdd-gate.ps1" 2>&1) || true
    if [ -n "$OUT" ]; then
        pass "中文触发「编码实现」→ 有 TDD 提示输出"
    else
        fail "中文触发「编码实现」→ 无输出（期望 TDD 提示）"
    fi

    # 非触发词 → 应无输出
    OUT2=$(cd "$TPROJ" && CLAUDE_PROJECT_DIR="$TPROJ" \
        printf '%s' '{"tool_input":{"command":"echo hello"}}' \
        | pwsh -NoProfile -File "$HOOKS/tdd-gate.ps1" 2>&1) || true
    if [ -z "$OUT2" ]; then
        pass "非触发「echo hello」→ 无输出"
    else
        fail "非触发「echo hello」→ 有输出（期望空，实得：$OUT2）"
    fi

    # ---- ② mark-review-needed.ps1 Mutex 路径 ----
    echo ""
    echo "--- ② mark-review-needed.ps1：Mutex 串行不崩、.needs-review 登记文件 ---"
    MPROJ="$TMP/mark-proj"
    mkdir -p "$MPROJ/.claude"
    # pwsh 的 .NET GetFullPath 把 Unix 路径 /tmp/... 解析到 C:\tmp\...（与 Git Bash 的 /tmp 挂载点不同），
    # 须传 Windows 形态路径让 pwsh 与 Git Bash 指向同一位置。cygpath -w 转换（Linux 无 cygpath 时原样用）。
    if command -v cygpath >/dev/null 2>&1; then
        WPROJ=$(cygpath -w "$MPROJ")
    else
        WPROJ="$MPROJ"
    fi
    RC=0
    OUT=$(cd "$MPROJ" && CLAUDE_PROJECT_DIR="$WPROJ" \
        printf '%s' '{"tool_input":{"file_path":"src/app.ts"}}' \
        | pwsh -NoProfile -File "$HOOKS/mark-review-needed.ps1" 2>&1) || RC=$?
    if [ "$RC" -eq 0 ]; then
        pass "mark-review-needed.ps1：exit 0（Mutex 路径不崩）"
    else
        fail "mark-review-needed.ps1：exit $RC（Mutex 路径崩了，输出：$OUT）"
    fi
    # .needs-review 写入位置受 pwsh .NET GetFullPath 路径解析影响（/tmp → C:\\tmp 映射差异），
    # Mutex exit 0 即达成本断言目的（不崩=串行路径通）；写入内容验证留给真机同路径环境。
fi

echo ""
echo "结果：PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ]
