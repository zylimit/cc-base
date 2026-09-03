#!/usr/bin/env bash
# run-all.sh — 跑全部框架自测。
# 永远先跑 selftest（无依赖、必跑）；再跑静态自测（test-setup/test-routing，无需 claude CLI）；
#   最后跑真触发 cases（需 claude CLI）。
# 检测 command -v claude：不存在就明确打印 SKIPPED 并只跑前两段，绝不静默假绿
#   （呼应框架的反静默失败——缺 CLI 是「跳过」不是「通过」）。
# 退出码：selftest 失败 → 非 0；静态自测失败 → 非 0；真触发 cases 全过（或被 SKIP）→ 0；有 case 失败 → 非 0。
set -eu

# 内嵌 python3 的编码：Windows runner 上 python 的 stdout 默认是 cp1252，从 python 里打中文
#   直接 UnicodeEncodeError（CI 抓到的是 test-routing 的全角括号 '（' 崩在 cp1252.py）。本仓 8 个
#   测试脚本内嵌 python3 -c / python3 - <<PY，眼下只有 test-routing 和 cases/test-harness 会从
#   python 里打中文，其余六个离同一个崩只差一句 print——所以设在这里而不是逐个脚本里，散点写法
#   下次加测试必然漏一个。两个变量分工不同，都要设：PYTHONIOENCODING 管 std 流，PYTHONUTF8 管
#   open() 的默认编码（漏写 encoding= 的读文件）；且前者优先级高于后者，只设 PYTHONUTF8 救不了
#   stdout。覆盖的是所有走 run-all 的路径（含它拉起的静态自测与 dod）；CI 单独跑某个脚本的路径
#   由 .github/workflows/gate.yml 的 job 级 env 兜，两处覆盖面不同，不算重复。
export PYTHONIOENCODING=utf-8
export PYTHONUTF8=1

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
#   无 node 时这两个脚本自身已经打 SKIPPED 退 0（不再是 exit 1），这里的守卫留着是为了汇总行里
#   那句 AUDIT_NOTE —— 跳过了要在最后一行说出来，不让「跑不了」冒充通过。
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
# 两个一键闸自己也要进回归网：dod（静态治理总闸）和 release（发版就绪装配器）是提交/发版前
#   最后两道，此前谁都没跑过它们——最外层的闸没人守，是最容易烂掉的那种。
#   dod 断 rc 0：本仓静态治理常态全绿，红了就是真有 blocking step 挂了。
#   release **不能**断 rc 0——工作树脏 / Fast Mode 开着 / CI 红都会让它正确地判「未就绪」(rc 1)，
#   断 rc 0 会把它变成恒红。这里断的是「引擎跑出了结构完整的清单」：rc 在 {0,1} 内、stdout 是
#   JSON、七个装配项齐、状态在枚举内、每条 blocker 带 nextStep。引擎崩了也给 rc 1 但吐不出 JSON，
#   正好被结构这一层区分开——「判定为未就绪」和「引擎崩了」不许混成同一个红。
ONEKEY_NOTE=""
if command -v node >/dev/null 2>&1; then
    REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"
    HARNESS_MJS="$TESTS_DIR/../harness/harness.mjs"
    echo "----- 运行 dod（一键静态治理闸）-----"
    DOD_RC=0
    ( cd "$REPO_ROOT" && node "$HARNESS_MJS" dod >/dev/null ) || DOD_RC=$?
    if [ "$DOD_RC" -eq 0 ]; then
        echo "dod: rc 0（每条 blocking 治理步都有结论）"
    else
        STATIC_RC=1
        echo "dod: rc $DOD_RC（有 blocking step 没过或引擎崩了，跑 node .claude/harness/harness.mjs dod 看是哪条）"
        echo "（上面这个静态测试判 FAIL）"
    fi

    echo "----- 运行 release（发版就绪装配器，判结构不判就绪）-----"
    RELEASE_RC=0
    RELEASE_JSON=$( cd "$REPO_ROOT" && node "$HARNESS_MJS" release 2>/dev/null ) || RELEASE_RC=$?
    if [ "$RELEASE_RC" -eq 3 ]; then
        echo "SKIPPED: release rc 3（非 git 仓，或七项全 UNKNOWN 什么都没确立）——未执行 != 通过。"
        ONEKEY_NOTE="；release SKIPPED（rc 3 什么都没确立）"
    elif [ "$RELEASE_RC" -ne 0 ] && [ "$RELEASE_RC" -ne 1 ]; then
        STATIC_RC=1
        echo "release: rc $RELEASE_RC 不在 {0,1,3} 契约内——引擎崩了，不是判定未就绪"
        echo "（上面这个静态测试判 FAIL）"
    else
        printf '%s' "$RELEASE_JSON" | node -e '
let s = "";
process.stdin.on("data", d => s += d).on("end", () => {
  let j;
  try { j = JSON.parse(s); } catch (e) {
    console.error("release: stdout 不是 JSON（引擎崩了，不是判定未就绪）：" + e.message);
    process.exit(1);
  }
  const want = ["worktree", "remote", "dod", "manifest", "review-queue", "fast-mode", "ci"];
  const got = (j.checks || []).map(c => c.id);
  const miss = want.filter(w => !got.includes(w));
  if (miss.length) {
    console.error("release: 装配项缺 " + miss.join(", ") + "（实得 " + (got.join(", ") || "空") + "）");
    process.exit(1);
  }
  const bad = (j.checks || []).filter(c => !["PASS", "FAIL", "DEGRADED"].includes(c.status));
  if (bad.length) {
    console.error("release: 状态越界 " + bad.map(c => c.id + "=" + c.status).join(", "));
    process.exit(1);
  }
  const noStep = (j.blockers || []).filter(b => !b.nextStep);
  if (noStep.length) {
    console.error("release: blocker 缺 nextStep（只诊断不给下一步，闸就没人用）：" + noStep.map(b => b.id).join(", "));
    process.exit(1);
  }
  console.log("release: 清单结构完整（" + got.length + " 项，blockers=" + (j.blockers || []).length
    + "，established=" + j.established + "）——就绪与否是它的判定，不是本测试的断言");
});
' || { STATIC_RC=1; echo "（上面这个静态测试判 FAIL）"; }
    fi
else
    echo "SKIPPED: 无 node（command -v node 未找到）——dod / release 一键闸跳过，未执行 != 通过。"
    ONEKEY_NOTE="；dod / release 一键闸 SKIPPED（无 node）"
fi
# .ps1 hook 真跑回归：喂真实 JSON 断言退出码 / stdout / .needs-review 与 gate-block.log 的副作用。
#   与 test-hook-parity.sh 分工——那份从 Git Bash 验对等且明说 .needs-review 内容留给真机，
#   这份用原生 pwsh 把那块补上，另加 stop-gate / pre-commit-check 的 fail-closed（.sh 侧归
#   test-hook-failopen.sh，.ps1 侧此前全空）。
#   本机没 pwsh 就明示 SKIP：CI 的 ps1 那格会真跑，那里 rc 3 直接判失败。
#   退出码：0=全过 / 1=有断言红 / 3=有整组没跑成（缺 node 或 git）。
PS1_NOTE=""
PS1_BEHAVIOR="$TESTS_DIR/test-ps1-behavior.ps1"
if command -v pwsh >/dev/null 2>&1; then
    echo "----- 运行 test-ps1-behavior.ps1（原生 pwsh 真跑 .ps1 hook）-----"
    PS1_RC=0
    pwsh -NoProfile -File "$PS1_BEHAVIOR" || PS1_RC=$?
    if [ "$PS1_RC" -eq 3 ]; then
        PS1_NOTE="；.ps1 行为回归有整组 SKIPPED（未执行 != 通过）"
    elif [ "$PS1_RC" -ne 0 ]; then
        STATIC_RC=1; echo "（上面这个静态测试判 FAIL）"
    fi
else
    echo "SKIPPED: 无 pwsh（command -v pwsh 未找到）——.ps1 行为回归跳过，未执行 != 通过。"
    PS1_NOTE="；.ps1 行为回归 SKIPPED（无 pwsh）"
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
    echo "########## 结果：selftest + 静态自测通过${GOLDEN_NOTE}${AUDIT_NOTE}${FAILOPEN_NOTE}${EVIDENCE_NOTE}${GITHOOKS_NOTE}${ONEKEY_NOTE}${PS1_NOTE}；真触发 cases 已 SKIP（非假绿）。 ##########"
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
    echo "########## 结果：selftest + 静态自测通过${GOLDEN_NOTE}${AUDIT_NOTE}${FAILOPEN_NOTE}${EVIDENCE_NOTE}${GITHOOKS_NOTE}${ONEKEY_NOTE}${PS1_NOTE}；cases 目录无可跑用例。 ##########"
elif [ "$CASE_RC" -eq 0 ]; then
    echo "########## 结果：selftest + 静态自测${GOLDEN_NOTE}${AUDIT_NOTE}${FAILOPEN_NOTE}${EVIDENCE_NOTE}${GITHOOKS_NOTE}${ONEKEY_NOTE}${PS1_NOTE} + 全部 $RAN 个真触发 case 通过。 ##########"
else
    echo "########## 结果：selftest + 静态自测通过${GOLDEN_NOTE}${AUDIT_NOTE}${FAILOPEN_NOTE}${EVIDENCE_NOTE}${GITHOOKS_NOTE}${ONEKEY_NOTE}${PS1_NOTE}，但有真触发 case 失败。 ##########"
fi
exit "$CASE_RC"
