#!/usr/bin/env bash
# run-all.sh — 跑全部框架自测。
# 永远先跑 selftest（无依赖、必跑）；真触发 cases 需要 claude CLI。
# 检测 command -v claude：不存在就明确打印 SKIPPED 并只跑 selftest，绝不静默假绿
#   （呼应框架的反静默失败——缺 CLI 是「跳过」不是「通过」）。
# 退出码：selftest 失败 → 非 0；selftest 过且 cases 全过（或被 SKIP）→ 0；有 case 失败 → 非 0。
set -eu

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(cd "$DIR/.." && pwd)"

echo "########## cc-base 框架自测 · run-all ##########"
echo ""

# ---- 第一段：脚手架自测（无依赖，必跑）----
echo ">>> [1/2] selftest（脚手架自测，无需 claude CLI）"
SELF_RC=0
bash "$TESTS_DIR/selftest.sh" || SELF_RC=$?
if [ "$SELF_RC" -ne 0 ]; then
    echo ""
    echo "########## 结果：selftest 失败（退出码 $SELF_RC），断言库本身不可信，停止。 ##########"
    exit "$SELF_RC"
fi

# ---- 第二段：真触发 cases（需 claude CLI）----
echo ""
echo ">>> [2/2] 真触发 cases（需 claude CLI + 耗 token）"
if ! command -v claude >/dev/null 2>&1; then
    echo "SKIPPED: 无 claude CLI（command -v claude 未找到）——真触发测试跳过，未执行 != 通过。"
    echo ""
    echo "########## 结果：selftest 通过；真触发 cases 已 SKIP（非假绿）。 ##########"
    exit 0
fi

CASE_RC=0
RAN=0
for c in "$DIR"/*.sh; do
    [ "$(basename "$c")" = "run-all.sh" ] && continue
    RAN=$((RAN+1))
    echo ""
    echo "----- 运行 case：$(basename "$c") -----"
    bash "$c" || { CASE_RC=1; echo "（上面这个 case 判 FAIL）"; }
done

echo ""
if [ "$RAN" -eq 0 ]; then
    echo "########## 结果：selftest 通过；cases 目录无可跑用例。 ##########"
elif [ "$CASE_RC" -eq 0 ]; then
    echo "########## 结果：selftest + 全部 $RAN 个真触发 case 通过。 ##########"
else
    echo "########## 结果：selftest 通过，但有真触发 case 失败。 ##########"
fi
exit "$CASE_RC"
