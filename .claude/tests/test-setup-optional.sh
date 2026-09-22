#!/usr/bin/env bash
# risk: high
# test-setup-optional.sh — 可选包（--with-tests / --with-harness，ps1 对等 -WithTests / -WithHarness）
#   绕过主循环三层保护的回归（progress.md TODO #74，2026-09-19 审查实测）：copy_claude_tree 的主循环
#   对已存在且被用户改过的文件走 manifest 分层（不覆盖、落 .framework-new），走四份排除表
#   （@exclusions:begin...end），且 rules/*.md 只收顶层；--with-tests/--with-harness 两支线各自
#   另起一段 find，逐文件直接 copy_file/Copy-Item，不经过上面任何一层。
# 契约（按它写断言，实现归 implementer，不预设修法）：
#   ①目标已存在且内容不同：不静默覆盖，两侧行为一致（保留用户副本+明确报告，形态与主循环一致；
#     dry-run 报的动作名与实际动作一致，已存在的报 skip 或明确的覆盖名，不报 create）
#   ②排除表照用：.DS_Store / *.bak / state/* 不拷
#   ③harness/ext/rules/ 只顶层 .md 进 rules/，嵌套目录里的不压平、两侧一致
#   ④默认（不带开关）行为不变
# 本文件只锁「修好后应成立」的行为，不改安装器（tester 不是安装器作者）。
# R1（数据保留）现状：sh 侧 copy_file 的 .bak 是通用机制（任何覆盖都会留），已经满足「可辨识地
#   保留」这条最低线——标为防回归位，不是本次红锁的靶子；ps1 侧 Copy-Item -Force 完全不写备份，
#   真实、不可逆的数据丢失，是这组里唯一的真红（2026-09-22 行为探测实测，未读实现代码推断）。
# R2（dry-run 动作名）两侧都红：两支线的 plan_note/Add-Plan 一律硬编码 'create'，不看 dest 是否已存在。
# R3（排除表）两侧都红：两支线各自的 find 循环不经过 case/@exclusions 分支，直接整目录照拷。
# R4（rules 顶层限定）只 sh 红：case "$rel" in harness/ext/rules/*.md) 的 * 在 bash case 里跨 /，
#   会把 rules/nested/z.md 压平成 rules/z.md；ps1 侧 [^/]+ 正则本就不跨 /，现状已经对——标防回归位。
# R5（默认不装）两侧防回归：不带开关时两条支线各自的 if 判断不生效，行为不该被这次改动带坏。
#
# 夹具：把本仓 setup.sh / setup.ps1 / .claude 整棵拷进 mktemp 当源（git ls-files，天然跳过
#   .claude/worktrees），在拷贝里种 R3/R4 的诱饵文件——对本仓只读，安装目标另开 mktemp。
# ps1 臂靠 command -v pwsh 现查现判，缺席打 [SKIP]（判「跑没跑过」查账本别查记忆——本机 2026-09
#   起实测在场，不假定，也不硬赌）。
# 独立 PASS/FAIL 计数，不 fail-fast：同一类缺陷（数据丢失/dry-run/排除表/rules）要一次性把红因全亮出来，
#   不能撞见第一条就退出，那样后面几条的红因永远看不见。
set -eu

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
[ -f "$ROOT/setup.sh" ]  || { echo "test-setup-optional: 仓库根缺 setup.sh：$ROOT" >&2; exit 1; }
[ -f "$ROOT/setup.ps1" ] || { echo "test-setup-optional: 仓库根缺 setup.ps1：$ROOT" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
SKIPN=0
chk() {  # chk <0=通过/非0=失败> <标题> <EXPECT> <GOT>
  if [ "$1" = "0" ]; then
    PASS=$((PASS + 1)); printf '  [PASS] %s\n' "$2"
  else
    FAIL=$((FAIL + 1)); printf '  [FAIL] %s\n' "$2"
  fi
  printf '         EXPECT %s\n' "$3"
  printf '         GOT    %s\n' "$4"
}
sk() { SKIPN=$((SKIPN + 1)); printf '  [SKIP] %s\n' "$1"; }

echo "===== test-setup-optional ====="

# ---- 夹具：拷源，只读本仓 ----
SRC="$TMP/src"
mkdir -p "$SRC"
cp "$ROOT/setup.sh" "$SRC/setup.sh"
cp "$ROOT/setup.ps1" "$SRC/setup.ps1"
(cd "$ROOT" && git ls-files -z --cached --others --exclude-standard -- .claude | tar --null -T - -cf -) \
  | (cd "$SRC" && tar -xf -) \
  || { echo "test-setup-optional: 拷贝源 .claude 失败" >&2; exit 1; }
[ -d "$SRC/.claude/harness/ext" ] || { echo "test-setup-optional: 源仓缺 .claude/harness/ext，无法造夹具" >&2; exit 1; }

# R3/R4 诱饵：DS_Store / *.bak / state/y / 嵌套 rules（种进拷贝的源，不碰本仓）
mkdir -p "$SRC/.claude/harness/ext/state"
: > "$SRC/.claude/harness/ext/.DS_Store"
: > "$SRC/.claude/harness/ext/x.bak"
: > "$SRC/.claude/harness/ext/state/y"
mkdir -p "$SRC/.claude/harness/ext/rules/nested"
printf '# nested doc（应留在 nested/ 里，不许压平进 rules/）\n' > "$SRC/.claude/harness/ext/rules/nested/z.md"

MARK_FILE="harness/ext/catalog.mjs"   # 主循环之外确定存在、非二进制的探针文件
[ -f "$SRC/.claude/$MARK_FILE" ] || { echo "test-setup-optional: 源缺探针文件 .claude/$MARK_FILE" >&2; exit 1; }

# ==================== sh 臂 ====================
T1="$TMP/target-sh"
RC1=0
bash "$SRC/setup.sh" --with-harness "$T1" >"$TMP/sh-install1.log" 2>&1 || RC1=$?
WIN_ROUTED=0
grep -q "cc-base setup (Windows/.ps1)" "$TMP/sh-install1.log" 2>/dev/null && WIN_ROUTED=1

if [ "$RC1" != "0" ] || [ "$WIN_ROUTED" = "1" ]; then
  sk "sh 臂整组：首次 --with-harness 安装 rc=$RC1 路由到ps1=$WIN_ROUTED（见 $TMP/sh-install1.log；本机预期走 .sh 直装路径，非零多半是环境问题不是本文件要锁的缺陷）"
else
  CL1="$T1/.claude"

  # ---- R3：DS_Store / *.bak / state/y 不许被拷进目标 ----
  ok=0; [ ! -e "$CL1/harness/ext/.DS_Store" ] || ok=1
  chk "$ok" "R3a(sh) harness/ext/.DS_Store 不进安装产物" \
    "不存在（同 .claude/harness/exclusions.json 的 */.DS_Store 臂）" \
    "存在=$([ -e "$CL1/harness/ext/.DS_Store" ] && echo yes || echo no)"

  ok=0; [ ! -e "$CL1/harness/ext/x.bak" ] || ok=1
  chk "$ok" "R3b(sh) harness/ext/x.bak 不进安装产物" \
    "不存在（同 exclusions.json 的 *.bak 臂——它本是安装器自己产物的排除项，不该被可选包绕开）" \
    "存在=$([ -e "$CL1/harness/ext/x.bak" ] && echo yes || echo no)"

  ok=0; [ ! -e "$CL1/harness/ext/state/y" ] || ok=1
  chk "$ok" "R3c(sh) harness/ext/state/y 不进安装产物" \
    "不存在（运行态子目录不该整目录跟着 harness/ext/ 一起装出去）" \
    "存在=$([ -e "$CL1/harness/ext/state/y" ] && echo yes || echo no)"

  # ---- R4：rules/ 只收顶层 .md，嵌套目录不压平；原文件仍照常落在 harness/ext/rules/nested/ ----
  ok=0; [ ! -e "$CL1/rules/z.md" ] || ok=1
  chk "$ok" "R4a(sh) 嵌套 rules/nested/z.md 不许被压平进 .claude/rules/z.md" \
    "不存在（bash case 的 harness/ext/rules/*.md 臂里 * 跨 / 是红因所在）" \
    "存在=$([ -e "$CL1/rules/z.md" ] && echo yes || echo no)"

  ok=0; [ -f "$CL1/harness/ext/rules/nested/z.md" ] || ok=1
  chk "$ok" "R4b(sh) 嵌套文件本身仍原样落在 harness/ext/rules/nested/z.md（防止把 R4a 的修法连累成整体不装）" \
    "存在" "存在=$([ -f "$CL1/harness/ext/rules/nested/z.md" ] && echo yes || echo no)"

  # ---- R1：用户改过 harness/ext/catalog.mjs 后重装，内容必须保留在原地或可辨识地保留 ----
  MARKER="// test-setup-optional user edit marker sh $$"
  printf '%s\n' "$MARKER" >> "$CL1/$MARK_FILE"
  RC2=0
  bash "$SRC/setup.sh" --with-harness "$T1" >"$TMP/sh-install2.log" 2>&1 || RC2=$?
  ok=0; [ "$RC2" = "0" ] || ok=1
  chk "$ok" "R1 前置(sh) 二次安装本身应成功" "rc=0" "rc=$RC2"

  LIVE_HAS=no; grep -qF -- "$MARKER" "$CL1/$MARK_FILE" 2>/dev/null && LIVE_HAS=yes
  BAK_FOUND=无
  for f in "$CL1/$MARK_FILE.bak" "$CL1/$MARK_FILE.framework-new"; do
    [ -f "$f" ] && grep -qF -- "$MARKER" "$f" 2>/dev/null && BAK_FOUND="$f"
  done
  ok=1; { [ "$LIVE_HAS" = "yes" ] || [ "$BAK_FOUND" != "无" ]; } && ok=0
  chk "$ok" "R1(sh) 用户改动重装后必须还在，或按契约①保留为可辨识副本" \
    "改动仍在 \$MARK_FILE 里，或在 .bak/.framework-new 类文件里可辨识地保留" \
    "live含改动=$LIVE_HAS 可辨识副本=$BAK_FOUND"

  ok=1; [ "$BAK_FOUND" != "无" ] && ok=0
  chk "$ok" "R1(sh)-防回归位 .bak/.framework-new 等价保留物真的落盘（sh 现状已如此，标注防回归、非本次红锁靶子）" \
    "存在 .bak 或 .framework-new 且内容含改动" "$BAK_FOUND"

  # ---- R2：改动已被上面那次重装吃掉（catalog.mjs 已回到框架版本），dry-run 不许报 create ----
  RC3=0
  bash "$SRC/setup.sh" --dry-run --with-harness "$T1" >"$TMP/sh-dry.log" 2>&1 || RC3=$?
  ok=0; [ "$RC3" = "0" ] || ok=1
  chk "$ok" "R2 前置(sh) dry-run 本身应成功" "rc=0" "rc=$RC3"

  DRY_LINE=$(grep -E "\\.claude/$MARK_FILE\$" "$TMP/sh-dry.log" | head -1 || true)
  DRY_ACTION=$(printf '%s' "$DRY_LINE" | awk '{print $1}')
  ok=1; [ -n "$DRY_ACTION" ] && [ "$DRY_ACTION" != "create" ] && ok=0
  chk "$ok" "R2(sh) 对已存在且未变化的文件，dry-run 不许报 create" \
    "create 之外（skip 或明确的覆盖动作名），且这一行确实存在" \
    "动作=[${DRY_ACTION:-<未找到该行>}] 原始行=[$DRY_LINE]"
fi

# ---- R5：默认安装（不带任何 --with-*）不含 harness/ext/ 与 tests/（防回归，两条排除臂不该被带坏）----
T5="$TMP/target-sh-default"
RC5=0
bash "$SRC/setup.sh" "$T5" >"$TMP/sh-install5.log" 2>&1 || RC5=$?
if [ "$RC5" != "0" ]; then
  sk "R5(sh) 默认安装本身失败（rc=$RC5，见 $TMP/sh-install5.log），跳过防回归判定"
else
  ok=0; [ ! -e "$T5/.claude/harness/ext" ] || ok=1
  chk "$ok" "R5a(sh) 默认安装不含 .claude/harness/ext/" \
    "不存在" "存在=$([ -e "$T5/.claude/harness/ext" ] && echo yes || echo no)"
  ok=0; [ ! -e "$T5/.claude/tests" ] || ok=1
  chk "$ok" "R5b(sh) 默认安装不含 .claude/tests/" \
    "不存在" "存在=$([ -e "$T5/.claude/tests" ] && echo yes || echo no)"
fi

# ==================== ps1 臂（本机现查现判，缺 pwsh 打 SKIP 不假绿）====================
if ! command -v pwsh >/dev/null 2>&1; then
  sk "ps1 臂整组：无 pwsh（本机 2026-09 起实测在场，判「跑没跑过」查账本不查记忆——这里现场再查一次不赌旧结论）"
else
  T1P="$TMP/target-ps"
  RC1P=0
  pwsh -NoProfile -ExecutionPolicy Bypass -File "$SRC/setup.ps1" -Target "$T1P" -WithHarness \
    >"$TMP/ps-install1.log" 2>&1 || RC1P=$?
  if [ "$RC1P" != "0" ]; then
    sk "ps1 臂整组：首次 -WithHarness 安装 rc=$RC1P（见 $TMP/ps-install1.log，多半是本机 pwsh 环境问题不是本文件要锁的缺陷）"
  else
    CL1P="$T1P/.claude"

    ok=0; [ ! -e "$CL1P/harness/ext/.DS_Store" ] || ok=1
    chk "$ok" "R3a(ps1) harness/ext/.DS_Store 不进安装产物" \
      "不存在" "存在=$([ -e "$CL1P/harness/ext/.DS_Store" ] && echo yes || echo no)"
    ok=0; [ ! -e "$CL1P/harness/ext/x.bak" ] || ok=1
    chk "$ok" "R3b(ps1) harness/ext/x.bak 不进安装产物" \
      "不存在" "存在=$([ -e "$CL1P/harness/ext/x.bak" ] && echo yes || echo no)"
    ok=0; [ ! -e "$CL1P/harness/ext/state/y" ] || ok=1
    chk "$ok" "R3c(ps1) harness/ext/state/y 不进安装产物" \
      "不存在" "存在=$([ -e "$CL1P/harness/ext/state/y" ] && echo yes || echo no)"

    ok=0; [ ! -e "$CL1P/rules/z.md" ] || ok=1
    chk "$ok" "R4a(ps1)-防回归位 嵌套 rules/nested/z.md 不许被压平进 .claude/rules/z.md（ps1 现状本就不压平，别读成已经按本次要求修好）" \
      "不存在" "存在=$([ -e "$CL1P/rules/z.md" ] && echo yes || echo no)"
    ok=0; [ -f "$CL1P/harness/ext/rules/nested/z.md" ] || ok=1
    chk "$ok" "R4b(ps1) 嵌套文件本身仍原样落在 harness/ext/rules/nested/z.md" \
      "存在" "存在=$([ -f "$CL1P/harness/ext/rules/nested/z.md" ] && echo yes || echo no)"

    MARKER_P="// test-setup-optional user edit marker ps $$"
    printf '%s\n' "$MARKER_P" >> "$CL1P/$MARK_FILE"
    RC2P=0
    pwsh -NoProfile -ExecutionPolicy Bypass -File "$SRC/setup.ps1" -Target "$T1P" -WithHarness \
      >"$TMP/ps-install2.log" 2>&1 || RC2P=$?
    ok=0; [ "$RC2P" = "0" ] || ok=1
    chk "$ok" "R1 前置(ps1) 二次安装本身应成功" "rc=0" "rc=$RC2P"

    LIVE_HAS_P=no; grep -qF -- "$MARKER_P" "$CL1P/$MARK_FILE" 2>/dev/null && LIVE_HAS_P=yes
    BAK_FOUND_P=无
    for f in "$CL1P/$MARK_FILE.bak" "$CL1P/$MARK_FILE.framework-new"; do
      [ -f "$f" ] && grep -qF -- "$MARKER_P" "$f" 2>/dev/null && BAK_FOUND_P="$f"
    done
    ok=1; { [ "$LIVE_HAS_P" = "yes" ] || [ "$BAK_FOUND_P" != "无" ]; } && ok=0
    chk "$ok" "R1(ps1) 用户改动重装后必须还在，或按契约①保留为可辨识副本" \
      "改动仍在 \$MARK_FILE 里，或在 .bak/.framework-new 类文件里可辨识地保留" \
      "live含改动=$LIVE_HAS_P 可辨识副本=$BAK_FOUND_P"

    RC3P=0
    pwsh -NoProfile -ExecutionPolicy Bypass -File "$SRC/setup.ps1" -Target "$T1P" -WithHarness -DryRun \
      >"$TMP/ps-dry.log" 2>&1 || RC3P=$?
    ok=0; [ "$RC3P" = "0" ] || ok=1
    chk "$ok" "R2 前置(ps1) dry-run 本身应成功" "rc=0" "rc=$RC3P"

    DRY_LINE_P=$(grep -E "\\.claude/$MARK_FILE\$" "$TMP/ps-dry.log" | head -1 || true)
    DRY_ACTION_P=$(printf '%s' "$DRY_LINE_P" | awk '{print $1}')
    ok=1; [ -n "$DRY_ACTION_P" ] && [ "$DRY_ACTION_P" != "create" ] && ok=0
    chk "$ok" "R2(ps1) 对已存在且未变化的文件，dry-run 不许报 create" \
      "create 之外（skip 或明确的覆盖动作名），且这一行确实存在" \
      "动作=[${DRY_ACTION_P:-<未找到该行>}] 原始行=[$DRY_LINE_P]"
  fi

  T5P="$TMP/target-ps-default"
  RC5P=0
  pwsh -NoProfile -ExecutionPolicy Bypass -File "$SRC/setup.ps1" -Target "$T5P" >"$TMP/ps-install5.log" 2>&1 || RC5P=$?
  if [ "$RC5P" != "0" ]; then
    sk "R5(ps1) 默认安装本身失败（rc=$RC5P，见 $TMP/ps-install5.log），跳过防回归判定"
  else
    ok=0; [ ! -e "$T5P/.claude/harness/ext" ] || ok=1
    chk "$ok" "R5a(ps1) 默认安装不含 .claude/harness/ext/" \
      "不存在" "存在=$([ -e "$T5P/.claude/harness/ext" ] && echo yes || echo no)"
    ok=0; [ ! -e "$T5P/.claude/tests" ] || ok=1
    chk "$ok" "R5b(ps1) 默认安装不含 .claude/tests/" \
      "不存在" "存在=$([ -e "$T5P/.claude/tests" ] && echo yes || echo no)"
  fi
fi

echo "==== test-setup-optional：PASS=$PASS FAIL=$FAIL SKIP=$SKIPN ===="
[ "$FAIL" -eq 0 ]
