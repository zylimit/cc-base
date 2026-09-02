#!/usr/bin/env bash
# run-all.sh — 跑全部框架自测。
# 永远先跑 selftest（无依赖、必跑）；再跑静态自测（test-setup/test-routing，无需 claude CLI）；
#   最后跑真触发 cases（需 claude CLI）。
# 检测 command -v claude：不存在就明确打印 SKIPPED 并只跑前两段，绝不静默假绿
#   （呼应框架的反静默失败——缺 CLI 是「跳过」不是「通过」）。
# 退出码：selftest 失败 → 非 0；静态自测失败 → 非 0；真触发 cases 全过（或被 SKIP）→ 0；有 case 失败 → 非 0。
set -eu

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(cd "$DIR/.." && pwd)"

echo "########## cc-base 框架自测 · run-all ##########"
echo ""

# ---- 第一段：脚手架自测（无依赖，必跑）----
echo ">>> [1/3] selftest（脚手架自测，无需 claude CLI）"
SELF_RC=0
bash "$TESTS_DIR/selftest.sh" || SELF_RC=$?
if [ "$SELF_RC" -ne 0 ]; then
    echo ""
    echo "########## 结果：selftest 失败（退出码 $SELF_RC），断言库本身不可信，停止。 ##########"
    exit "$SELF_RC"
fi

# ---- 第二段：静态自测（安装器回归 + 配置一致性，无需 claude CLI，必跑）----
echo ""
echo ">>> [2/3] 静态自测（test-setup / test-routing / 闸回归，无需 claude CLI）"
STATIC_RC=0
for s in test-setup.sh test-routing.sh test-fix-platform.sh test-hook-parity.sh test-gate-audit.sh test-three-file-sync-gate.sh test-fast-mode.sh test-supervisor.sh; do
    echo "----- 运行 $s -----"
    bash "$TESTS_DIR/$s" || { STATIC_RC=1; echo "（上面这个静态测试判 FAIL）"; }
done
# harness 自测在 cases/（无需 claude CLI，只需 node），归第二段跑；无 node 时其自身打 SKIPPED 非假绿。
echo "----- 运行 test-harness.sh -----"
bash "$DIR/test-harness.sh" || { STATIC_RC=1; echo "（上面这个静态测试判 FAIL）"; }
# harness golden 基线：同样只需 node，归第二段跑。test-harness.sh 卡退出码契约，
#   这条卡 stdout JSON 全字段 + stderr——拆库重构要证「零行为变化」靠的就是它。
#   基线漂了先看 diff 再决定是真回归还是该重录（node .claude/tests/harness-golden.mjs --record）。
#   --strict 让「没跑成」以退出码 3 现形：不加它时 SKIPPED 也返回 0，被 `||` 读成通过。
echo "----- 运行 harness-golden.mjs --check -----"
GOLDEN_NOTE=""
if command -v node >/dev/null 2>&1; then
    GOLDEN_RC=0
    node "$TESTS_DIR/harness-golden.mjs" --check --strict || GOLDEN_RC=$?
    if [ "$GOLDEN_RC" -eq 3 ]; then
        GOLDEN_NOTE="；golden 基线 SKIPPED（未执行 != 通过）"
    elif [ "$GOLDEN_RC" -ne 0 ]; then
        STATIC_RC=1; echo "（上面这个静态测试判 FAIL）"
    fi
else
    echo "SKIPPED: 无 node（command -v node 未找到）——golden 基线比对跳过，未执行 != 通过。"
    GOLDEN_NOTE="；golden 基线 SKIPPED（无 node）"
fi
# audit 三只哨兵：同样只需 node + git，归第二段跑。两套分工不同，都要跑——
#   test-audit-scripts 锁「脚本该有的行为」（干净仓 rc 0 / 坏样例 rc 1 / 豁免可见 / 非 git rc 3），
#   test-audit-defects 锁「已修的那批缺陷不再复发」（--staged 只判索引、压制外置、超限不假绿……）。
#   无 node 时这两个脚本自身是 exit 1 而不是 SKIPPED，所以守卫放在这里：没装 node 打 SKIPPED，
#   不让「跑不了」冒充「没通过」，也不让它冒充通过。
AUDIT_NOTE=""
if command -v node >/dev/null 2>&1; then
    for s in test-audit-scripts.sh test-audit-defects.sh; do
        echo "----- 运行 $s -----"
        bash "$TESTS_DIR/$s" || { STATIC_RC=1; echo "（上面这个静态测试判 FAIL）"; }
    done
else
    echo "SKIPPED: 无 node（command -v node 未找到）——audit 三只哨兵的两套测试跳过，未执行 != 通过。"
    AUDIT_NOTE="；audit 测试 SKIPPED（无 node）"
fi
# 引擎异常退出红锁：harness 崩掉给出契约外退出码时，stop-gate / pre-commit-check 不许静默放行。
#   与 cases/test-harness.sh 分工——那份锁「引擎端到端链路该有的行为」，这份锁「引擎崩掉时闸不许假绿」。
#   同样只需 node + git；无 node 时它自身是 exit 1 而不是 SKIPPED，所以守卫放在这里。
FAILOPEN_NOTE=""
if command -v node >/dev/null 2>&1; then
    echo "----- 运行 test-hook-failopen.sh -----"
    bash "$TESTS_DIR/test-hook-failopen.sh" || { STATIC_RC=1; echo "（上面这个静态测试判 FAIL）"; }
else
    echo "SKIPPED: 无 node（command -v node 未找到）——引擎异常退出红锁跳过，未执行 != 通过。"
    FAILOPEN_NOTE="；引擎异常退出红锁 SKIPPED（无 node）"
fi
# 证据层红锁：账本读不出来要降级、并发追加不许断链、证据被改写要有命令看得见、
#   闸的范围不许由调用方伪造、被压制的失败不许冒充「从没跑过」。
#   与 cases/test-harness.sh 分工——那份锁「引擎端到端链路该有的行为」，这份锁「证据层的核心主张」。
#   只需 node + git + sleep；无 node 时它自身是 exit 1 而不是 SKIPPED，所以守卫放在这里。
EVIDENCE_NOTE=""
if command -v node >/dev/null 2>&1; then
    echo "----- 运行 test-evidence-defects.sh -----"
    bash "$TESTS_DIR/test-evidence-defects.sh" || { STATIC_RC=1; echo "（上面这个静态测试判 FAIL）"; }
else
    echo "SKIPPED: 无 node（command -v node 未找到）——证据层红锁跳过，未执行 != 通过。"
    EVIDENCE_NOTE="；证据层红锁 SKIPPED（无 node）"
fi
# git hooks 强制层（.claude/githooks/）：会话外的提交路径归它管，与 .claude/hooks/ 那层分工不同。
#   打桩控退出码，所以只需 node + git；无 node 时它自身是 exit 1 而不是 SKIPPED，守卫放在这里。
#   注意它**不跑** pre-push 的 FULL 模式——那会反过来拉起本文件，再拉起 claude -p。
GITHOOKS_NOTE=""
if command -v node >/dev/null 2>&1; then
    echo "----- 运行 test-githooks.sh -----"
    bash "$TESTS_DIR/test-githooks.sh" || { STATIC_RC=1; echo "（上面这个静态测试判 FAIL）"; }
else
    echo "SKIPPED: 无 node（command -v node 未找到）——git hooks 强制层回归跳过，未执行 != 通过。"
    GITHOOKS_NOTE="；git hooks 回归 SKIPPED（无 node）"
fi
if [ "$STATIC_RC" -ne 0 ]; then
    echo ""
    echo "########## 结果：静态自测失败（安装器/路由一致性不过），停止。 ##########"
    exit "$STATIC_RC"
fi

# ---- 第三段：真触发 cases（需 claude CLI）----
echo ""
echo ">>> [3/3] 真触发 cases（需 claude CLI + 耗 token）"
if ! command -v claude >/dev/null 2>&1; then
    echo "SKIPPED: 无 claude CLI（command -v claude 未找到）——真触发测试跳过，未执行 != 通过。"
    echo ""
    echo "########## 结果：selftest + 静态自测通过${GOLDEN_NOTE}${AUDIT_NOTE}${FAILOPEN_NOTE}${EVIDENCE_NOTE}${GITHOOKS_NOTE}；真触发 cases 已 SKIP（非假绿）。 ##########"
    exit 0
fi

CASE_RC=0
RAN=0
for c in "$DIR"/*.sh; do
    [ "$(basename "$c")" = "run-all.sh" ] && continue
    [ "$(basename "$c")" = "test-harness.sh" ] && continue   # 已在第二段跑（只需 node，不需 claude CLI）
    [ "$(basename "$c")" = "test-skill-behavior.sh" ] && continue  # opt-in（RUN_LIVE_SKILL=1），默认不跑，单独执行
    RAN=$((RAN+1))
    echo ""
    echo "----- 运行 case：$(basename "$c") -----"
    bash "$c" || { CASE_RC=1; echo "（上面这个 case 判 FAIL）"; }
done

echo ""
if [ "$RAN" -eq 0 ]; then
    echo "########## 结果：selftest + 静态自测通过${GOLDEN_NOTE}${AUDIT_NOTE}${FAILOPEN_NOTE}${EVIDENCE_NOTE}${GITHOOKS_NOTE}；cases 目录无可跑用例。 ##########"
elif [ "$CASE_RC" -eq 0 ]; then
    echo "########## 结果：selftest + 静态自测${GOLDEN_NOTE}${AUDIT_NOTE}${FAILOPEN_NOTE}${EVIDENCE_NOTE}${GITHOOKS_NOTE} + 全部 $RAN 个真触发 case 通过。 ##########"
else
    echo "########## 结果：selftest + 静态自测通过${GOLDEN_NOTE}${AUDIT_NOTE}${FAILOPEN_NOTE}${EVIDENCE_NOTE}${GITHOOKS_NOTE}，但有真触发 case 失败。 ##########"
fi
exit "$CASE_RC"
