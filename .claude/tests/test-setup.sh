#!/usr/bin/env bash
# test-setup.sh — 安装器回归测试：把 cc-base 用 setup.sh 装到临时目录，断言产物正确。
# 验三件事：① 关键文件装齐（CLAUDE.md / 7 个 agents / 各 skill 的 SKILL.md / hooks 有可执行位 /
#   settings.json 合法 JSON）；② 私有 feedback 已排除（target 只剩 templates/ + 重置的
#   FEEDBACK-INDEX.md，无顶层私有 *.md，守 setup.sh #5）；③ 幂等性（装两次产物 SHA256 一致）。
# 另有 ④ 框架分层 / ⑤ 运行态隔离 / ⑥ 四份排除表逐臂对照（各自表内比，含臂序与 drop/keep 处置）
#   + ⑥b 系统垃圾不入装不入清单（行为）+ ⑦ Claude Code 的 .claude/worktrees/ 不入装不入清单不入库。
# 无依赖 claude CLI，纳入 cases/run-all.sh 在 selftest 之后跑。装完清理临时目录。
set -eu

# tests/ 在 .claude/tests/ 下，仓库根 = 上溯三层（tests → .claude → repo root）
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
[ -f "$ROOT/setup.sh" ] || { echo "test-setup: 仓库根缺 setup.sh：$ROOT" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() { echo "test-setup: $*" >&2; exit 1; }

TARGET="$TMP/project"
bash "$ROOT/setup.sh" "$TARGET" >"$TMP/setup-1.log" 2>&1 || { cat "$TMP/setup-1.log" >&2; fail "首次安装失败"; }

CL="$TARGET/.claude"

# ---- ① 关键文件装齐 ----
[ -f "$CL/CLAUDE.md" ] || fail "CLAUDE.md 未安装"
[ -f "$CL/settings.json" ] || fail "settings.json 未安装"
[ -f "$CL/EVOLUTION.md" ] || fail "EVOLUTION.md 未安装"

# harness 安装产物（大仓治理运行时 + 接线依赖库 + 大仓 rules）
[ -f "$CL/harness/harness.mjs" ]         || fail "harness/harness.mjs 未安装"
[ -f "$CL/hooks/lib-harness.sh" ]        || fail "hooks/lib-harness.sh 未安装"
[ -f "$CL/hooks/lib-harness.ps1" ]       || fail "hooks/lib-harness.ps1 未安装"
[ -f "$CL/rules/harness-large-repo.md" ] || fail "rules/harness-large-repo.md 未安装"

# 7 个 agent 全装齐
for ag in implementer code-reviewer tester deployer feedback-observer evolution-runner progress-recorder; do
  [ -f "$CL/agents/$ag.md" ] || fail "agent 缺失：$ag.md"
done
agent_count=$(find "$CL/agents" -maxdepth 1 -type f -name '*.md' | wc -l | tr -d ' ')
[ "$agent_count" = "7" ] || fail "agent 数量应为 7，实得 $agent_count"

# 每个 skills/<name>/ 都有 SKILL.md 实体
while IFS= read -r d; do
  [ -f "$d/SKILL.md" ] || fail "skill 缺 SKILL.md：$(basename "$d")"
done < <(find "$CL/skills" -mindepth 1 -maxdepth 1 -type d)

# hooks/*.sh 装齐且带可执行位
hook_count=0
while IFS= read -r h; do
  hook_count=$((hook_count + 1))
  [ -x "$h" ] || fail "hook 缺可执行位：$(basename "$h")"
done < <(find "$CL/hooks" -maxdepth 1 -type f -name '*.sh')
[ "$hook_count" -gt 0 ] || fail "未装任何 hooks/*.sh"

# settings.json 合法 JSON（有 jq 用 jq，无 jq 用 python3 解析——降级环境同样要验）
if command -v jq >/dev/null 2>&1; then
  jq empty "$CL/settings.json" >/dev/null 2>&1 || fail "settings.json 不是合法 JSON"
else
  python3 -c "import json,sys; json.load(open(sys.argv[1], encoding='utf-8'))" "$CL/settings.json" >/dev/null 2>&1 \
    || fail "settings.json 不是合法 JSON"
fi

# ---- ② #5 验证：私有 feedback 已排除 ----
# 顶层私有 *.md 不该出现（FEEDBACK-INDEX.md 是重置模板，允许）
leaked=$(find "$CL/feedback" -maxdepth 1 -type f -name '*.md' ! -name 'FEEDBACK-INDEX.md' 2>/dev/null || true)
[ -z "$leaked" ] || fail "私有 feedback 泄漏到安装产物：$(echo "$leaked" | tr '\n' ' ')"
# templates/ 应保留
[ -d "$CL/feedback/templates" ] || fail "feedback/templates/ 未保留"
# FEEDBACK-INDEX.md 应被重置为干净模板（无私人条目，与模板同源）
[ -f "$CL/feedback/FEEDBACK-INDEX.md" ] || fail "FEEDBACK-INDEX.md 未安装"
TPL="$ROOT/.claude/feedback/templates/feedback-index-template.md"
if [ -f "$TPL" ]; then
  cmp -s "$TPL" "$CL/feedback/FEEDBACK-INDEX.md" || fail "FEEDBACK-INDEX.md 未重置为干净模板（与 template 不一致）"
fi

# ---- ③ 幂等性：装两次产物一致 ----
# 顶层先按「首次安装是否被路由到 setup.ps1」分流：setup.sh 在 MINGW/MSYS/CYGWIN 上会 exec pwsh
# 转交 setup.ps1（原生合并、不依赖 jq），此时断言语义与走 .sh 路径的 jq 有无是正交的，必须先判路由。
if grep -q "cc-base setup (Windows/.ps1)" "$TMP/setup-1.log"; then
  # 路由到 setup.ps1（Windows/MINGW）：原生合并语义。二次安装遇已有 settings.json 会先备份 .bak
  # 再原生重写；无新增 hook 命令时重写字节稳定，排除 .bak 后其余产物应保持幂等。
  cp -p "$CL/settings.json" "$TMP/settings.before"
  before=$(find "$TARGET" -type f ! -name '*.bak' | sort | xargs sha256sum 2>/dev/null | sha256sum | awk '{print $1}')
  bash "$ROOT/setup.sh" "$TARGET" >"$TMP/setup-2.log" 2>&1 || { cat "$TMP/setup-2.log" >&2; fail "二次安装报错（.ps1 原生合并）"; }
  after=$(find "$TARGET" -type f ! -name '*.bak' | sort | xargs sha256sum 2>/dev/null | sha256sum | awk '{print $1}')
  [ "$before" = "$after" ] || fail ".ps1 原生合并：二次安装后非 .bak 产物变化（before=$before after=$after）"
  [ -f "$CL/settings.json.bak" ] || fail ".ps1 原生合并：已有 settings.json 时未生成 .bak 备份"
  cmp -s "$TMP/settings.before" "$CL/settings.json" || fail ".ps1 原生合并：二次安装后 settings.json 变化（无新增 hook 时重写应字节稳定）"
  grep -q "installed: ps1_hooks=" "$TMP/setup-2.log" || fail ".ps1 原生合并：未打印 .ps1 安装完成标志行"
  MODE=".ps1 原生合并"
elif command -v jq >/dev/null 2>&1; then
  # 走 setup.sh .sh 路径且有 jq：二次安装走自动合并，产物应完全一致
  before=$(find "$TARGET" -type f | sort | xargs sha256sum 2>/dev/null | sha256sum | awk '{print $1}')
  bash "$ROOT/setup.sh" "$TARGET" >"$TMP/setup-2.log" 2>&1 || { cat "$TMP/setup-2.log" >&2; fail "二次安装报错"; }
  after=$(find "$TARGET" -type f | sort | xargs sha256sum 2>/dev/null | sha256sum | awk '{print $1}')
  [ "$before" = "$after" ] || fail "安装非幂等：二次安装后产物 SHA256 变化（before=$before after=$after）"
  MODE="jq 合并"
else
  # 走 setup.sh .sh 路径且无 jq 降级：二次安装遇到已有 settings.json 应备份 .bak + 原文件原样保留、不静默覆盖；
  # 其余产物（排除 .bak）保持幂等。
  cp -p "$CL/settings.json" "$TMP/settings.before"
  before=$(find "$TARGET" -type f ! -name '*.bak' | sort | xargs sha256sum 2>/dev/null | sha256sum | awk '{print $1}')
  bash "$ROOT/setup.sh" "$TARGET" >"$TMP/setup-2.log" 2>&1 || { cat "$TMP/setup-2.log" >&2; fail "二次安装报错（无 jq 降级路径）"; }
  after=$(find "$TARGET" -type f ! -name '*.bak' | sort | xargs sha256sum 2>/dev/null | sha256sum | awk '{print $1}')
  [ "$before" = "$after" ] || fail "无 jq 降级：二次安装后非 .bak 产物变化（before=$before after=$after）"
  [ -f "$CL/settings.json.bak" ] || fail "无 jq 降级：已有 settings.json 时未生成 .bak 备份"
  cmp -s "$TMP/settings.before" "$CL/settings.json" || fail "无 jq 降级：已有 settings.json 被改动（应原样保留、只打印手工合并指引）"
  grep -q "手工" "$TMP/setup-2.log" || fail "无 jq 降级：未打印手工合并指引"
  MODE="无 jq 降级"
fi

echo "test-setup: passed（agents=$agent_count hooks=$hook_count，私有 feedback 已排除，幂等校验通过，settings 路径=$MODE）"

# ---- ③b 强制 -mac + 无 jq 路径回归锁（本机 Windows 也能覆盖该分支）----
# 不依赖 uname：强制 bash setup.sh -mac；构造不含 jq 的 PATH，断言二次装打印「手工」、
# 生成 settings.json.bak、settings 内容未变。setup.sh 合并逻辑本身不改。
TARGET2="$TMP/project-nojq-mac"
FAKEBIN=$(mktemp -d)
# 精简命令集：setup.sh / fix-platform 所需基础工具；明确不链 jq
for c in bash sh cp mv mkdir printf cat find sort tr wc sed cmp xargs dirname basename uname \
         chmod ln rm touch date env mktemp awk head tail cut grep tee python3 node git; do
  src=$(command -v "$c" 2>/dev/null || true)
  if [ -n "$src" ] && [ -x "$src" ]; then
    # Windows Git Bash 上 ln -s 可能失败，退回直接复制或包装脚本
    ln -s "$src" "$FAKEBIN/$c" 2>/dev/null || cp -p "$src" "$FAKEBIN/$c" 2>/dev/null || {
      printf '#!/usr/bin/env bash\nexec %s "$@"\n' "$src" >"$FAKEBIN/$c"
      chmod +x "$FAKEBIN/$c" 2>/dev/null || true
    }
  fi
done
# 双保险：即便系统 PATH 漏进 jq，FAKEBIN 优先且无 jq 可执行文件
[ ! -e "$FAKEBIN/jq" ] || rm -f "$FAKEBIN/jq"
NOJQ_PATH="$FAKEBIN:/usr/bin:/bin"
# 逐个踢掉所有能找到 jq 的目录——usrmerge 系统（/bin -> /usr/bin）jq 有双入口，
# 只踢第一处会残留第二处，隔离必失败（本机 Ubuntu/WSL 实测踩坑）。有界循环防意外死转。
for _i in 1 2 3 4 5 6 7 8; do
  JQ_REAL=$(PATH="$NOJQ_PATH" command -v jq 2>/dev/null || true)
  [ -n "$JQ_REAL" ] || break
  JQ_DIR=$(dirname "$JQ_REAL")
  NOJQ_PATH=$(printf '%s' "$NOJQ_PATH" | tr ':' '\n' | grep -v -F -x "$JQ_DIR" | tr '\n' ':' | sed 's/:$//')
done
# 验证隔离有效
if PATH="$NOJQ_PATH" command -v jq >/dev/null 2>&1; then
  fail "强制 -mac 无 jq 路径：构造 PATH 后仍能找到 jq（隔离失败）"
fi
PATH="$NOJQ_PATH" bash "$ROOT/setup.sh" -mac "$TARGET2" >"$TMP/setup-nojq-1.log" 2>&1 \
  || { cat "$TMP/setup-nojq-1.log" >&2; fail "强制 -mac 无 jq 路径：首次安装失败"; }
CL2="$TARGET2/.claude"
[ -f "$CL2/settings.json" ] || fail "强制 -mac 无 jq 路径：首次安装未生成 settings.json"
cp -p "$CL2/settings.json" "$TMP/settings.nojq.before"
PATH="$NOJQ_PATH" bash "$ROOT/setup.sh" -mac "$TARGET2" >"$TMP/setup-nojq-2.log" 2>&1 \
  || { cat "$TMP/setup-nojq-2.log" >&2; fail "强制 -mac 无 jq 路径：二次安装报错"; }
[ -f "$CL2/settings.json.bak" ] || fail "强制 -mac 无 jq 路径：二次安装未生成 settings.json.bak"
cmp -s "$TMP/settings.nojq.before" "$CL2/settings.json" \
  || fail "强制 -mac 无 jq 路径：二次安装后 settings.json 被改动（应原样保留）"
grep -q "手工" "$TMP/setup-nojq-2.log" \
  || { cat "$TMP/setup-nojq-2.log" >&2; fail "强制 -mac 无 jq 路径：二次 log 未含「手工」合并指引"; }
rm -rf "$FAKEBIN"
echo "test-setup: ③b 强制 -mac 无 jq 路径回归锁通过"

# ---- ④ 框架分层（FRAMEWORK-MANIFEST）----
# ④-1 首装含 MANIFEST
[ -f "$CL/FRAMEWORK-MANIFEST.txt" ] || fail "首装未安装 FRAMEWORK-MANIFEST.txt"
grep -q 'agents/implementer.md' "$CL/FRAMEWORK-MANIFEST.txt" || fail "MANIFEST 缺少框架文件条目"

# ④-2 用户改一个框架文件后重装 → 不覆盖 + 出现 .framework-new
echo "# user local modification" >>"$CL/agents/implementer.md"
user_sha=$(sha256sum "$CL/agents/implementer.md" | awk '{print $1}')
# ④-3 前置：私有新增文件
echo "private note" >"$CL/feedback/my-private-note-keepme.txt"
mkdir -p "$CL/skills/my-private-skill" && echo "# mine" >"$CL/skills/my-private-skill/SKILL.md"

bash "$ROOT/setup.sh" "$TARGET" >"$TMP/setup-3.log" 2>&1 || { cat "$TMP/setup-3.log" >&2; fail "三次安装（升级场景）报错"; }
after_sha=$(sha256sum "$CL/agents/implementer.md" | awk '{print $1}')
[ "$user_sha" = "$after_sha" ] || fail "manifest 分层：用户改过的框架文件被覆盖了"
[ -f "$CL/agents/implementer.md.framework-new" ] || fail "manifest 分层：未生成 .framework-new"
cmp -s "$ROOT/.claude/agents/implementer.md" "$CL/agents/implementer.md.framework-new" \
  || fail "manifest 分层：.framework-new 内容与框架源不一致"
grep -q "framework-new" "$TMP/setup-3.log" || fail "manifest 分层：未打印 .framework-new 汇总提示"

# ④-3 私有新增文件重装后仍在
[ -f "$CL/feedback/my-private-note-keepme.txt" ] || fail "私有层：feedback 私有文件被删"
[ -f "$CL/skills/my-private-skill/SKILL.md" ] || fail "私有层：私有 skill 被删"
grep -q "# mine" "$CL/skills/my-private-skill/SKILL.md" || fail "私有层：私有 skill 内容被改"

echo "test-setup: manifest 分层校验通过（首装含 MANIFEST / 用户改动不覆盖落 .framework-new / 私有文件保留）"

# ---- ⑤ 运行态目录不入装、不入清单 ----
# 源仓跑过 review-pack / supervisor / gate 之后这些目录就有文件，它们是本机专属产物：
# 装进别人项目里是脏数据，登记进 MANIFEST 则让 release 的 manifest 检查随手一跑就转 FAIL。
# setup.sh copy_claude_tree 与 gen-manifest.sh 的排除表必须同时盖住它们，这里两侧一起验。
for rt in harness/receipts harness/state harness/waivers harness/trend harness/evidence .runtime evidence; do
  [ ! -e "$CL/$rt" ] || fail "运行态目录被装进产物：$rt"
  if grep -q "^$rt/" "$CL/FRAMEWORK-MANIFEST.txt"; then fail "运行态目录被登记进 MANIFEST：$rt"; fi
done
for rt in .stop-gate-strikes .precompact-block-epoch .async-verify-last .fast-mode .subagent-reminded; do
  [ ! -e "$CL/$rt" ] || fail "运行态标记被装进产物：$rt"
done
# 反向：排除表只许挡运行态目录，不许连带把 harness / scripts 本体挡掉（静默漏装比多装贵得多）
[ -f "$CL/harness/harness.mjs" ]      || fail "排除表过宽：harness.mjs 未安装"
[ -f "$CL/harness/lib/release.mjs" ]  || fail "排除表过宽：harness/lib/release.mjs 未安装"
[ -f "$CL/scripts/supervisor.mjs" ]   || fail "排除表过宽：scripts/supervisor.mjs 未安装"
grep -q '^harness/harness\.mjs	' "$CL/FRAMEWORK-MANIFEST.txt" || fail "排除表过宽：harness.mjs 不在 MANIFEST"

echo "test-setup: 运行态目录隔离校验通过（不入装 / 不入清单 / harness 本体照常分发）"

# ---- ⑥ 四份排除表口径一致 + 系统垃圾不入装 ----
# 「哪些文件算框架文件」这张表在仓里有四份手工同步的拷贝：gen-manifest.sh 的 case（生成器）、
# setup.sh copy_claude_tree 的 case 与 setup.ps1 的 $skip+正则（两个安装器）、
# harness/lib/release.mjs MANIFEST_RULES（审计者）。不抽单一来源是权衡后的结论：安装器要能被
# 单独取走对着源码树跑（setup.sh 连 jq 都不敢依赖），审计者读被审者的表就审不出漂移。
# 代价是手工同步会漂——上一批 .runtime/* 补了四份、系统垃圾四份全漏，就是这么漂出来的——
# 所以口径改由这一节兜：基准表从 gen-manifest.sh 的 case 块**自动抽**（硬编码一份清单只是把
# 漂移挪个地方藏），另三份也各自只从**自己那张表里**抽出来逐臂对照。
# 比对一律在表内做，不拿整文件 grep：`settings.json` 在 setup.sh 别处还有 13 行、
# `'FRAMEWORK-MANIFEST.txt'` 在 release.mjs 另有一处 MANIFEST_FILE 常量——整文件子串匹配下
# 这些臂从表里删掉照样绿，等于臂名只要在文件别处露过脸就永久免检。
# 序和处置也是真语义：case 与 manifestIncludes 都首中即返回，垃圾臂挪到 keep 臂之后就漏出去了，
# 所以三份 glob 表比的是「臂序 + 每臂 drop/keep」的完整序列，不是集合。
GEN_SH="$ROOT/.claude/scripts/gen-manifest.sh"
SETUP_SH="$ROOT/setup.sh"
SETUP_PS1="$ROOT/setup.ps1"
RELEASE_MJS="$ROOT/.claude/harness/lib/release.mjs"
for f in "$GEN_SH" "$SETUP_SH" "$SETUP_PS1" "$RELEASE_MJS"; do
  [ -f "$f" ] || fail "排除表口径：找不到 $f"
done

# 从 shell case 块抽臂：只取第一个 `case "$rel" in`（setup.sh 后面还有个判 mode 的），
# 每行一条 "<臂>TAB<drop|keep>"——body 里有 continue 是 drop，空 body（`;;`）是 keep。
extract_case_arms() {
  awk '
    !f && index($0, "case \"$rel\" in") { f = 1; next }
    f && $0 ~ /^[[:space:]]*esac[[:space:]]*$/ { exit }
    f {
      line = $0; sub(/#.*/, "", line)
      if (line !~ /\)/) next
      body = line; sub(/^[^)]*\)/, "", body)
      disp = (body ~ /continue/) ? "drop" : "keep"
      pats = line; sub(/\).*/, "", pats)
      n = split(pats, a, "|")
      for (i = 1; i <= n; i++) {
        gsub(/^[[:space:]]+/, "", a[i]); gsub(/[[:space:]]+$/, "", a[i])
        if (a[i] != "") printf "%s\t%s\n", a[i], disp
      }
    }
  ' "$1"
}

extract_case_arms "$GEN_SH"   >"$TMP/tbl.gen"
extract_case_arms "$SETUP_SH" >"$TMP/tbl.setup"
cut -f1 "$TMP/tbl.gen" >"$TMP/arms.gen"
# release.mjs 只从 MANIFEST_RULES 数组里抽，keep: true/false 直接就是处置
sed -n '/^const MANIFEST_RULES = \[/,/^\];/p' "$RELEASE_MJS" \
  | sed -n "s/.*pattern: '\([^']*\)',[[:space:]]*keep:[[:space:]]*\([a-z]*\).*/\1 \2/p" \
  | awk '{ printf "%s\t%s\n", $1, ($2 == "true" ? "keep" : "drop") }' >"$TMP/tbl.release"

# 抽取自检：条数写死。抽取正则半坏（只抽到一部分）时当场红，别让后面的逐臂比对空转——
# 下限式的 -ge 挡不住半坏。四份表增删臂时同步改这个数。
EXPECTED_ARMS=35
arm_count=$(grep -c . "$TMP/tbl.gen" || true)
[ "$arm_count" = "$EXPECTED_ARMS" ] \
  || fail "排除表口径：从 gen-manifest.sh 抽出 $arm_count 条臂，应为 $EXPECTED_ARMS（改过排除表就同步改这个数；数字对不上而表没动 = 抽取正则坏了，断言会空转）。release.mjs 相对它多出的臂：$(grep -vxF -f "$TMP/tbl.gen" "$TMP/tbl.release" | tr '\n' ' ' || true)"

# 逐臂对照：缺臂 / 多臂 / 臂序，三种漂移各自点名
cmp_table() {
  local name=$1 f=$2 arm
  while IFS= read -r arm; do
    [ -n "$arm" ] || continue
    grep -qxF -- "$arm" "$f" || fail "排除表口径：$name 少了臂 [$arm]（gen-manifest.sh 有）"
  done <"$TMP/tbl.gen"
  while IFS= read -r arm; do
    [ -n "$arm" ] || continue
    grep -qxF -- "$arm" "$TMP/tbl.gen" \
      || fail "排除表口径：$name 多出臂 [$arm]（gen-manifest.sh 没有——审计者比生成器严会把框架文件判成 unlisted，安装器比生成器严则静默漏装）"
  done <"$f"
  cmp -s "$TMP/tbl.gen" "$f" || fail "排除表口径：$name 臂序与 gen-manifest.sh 不一致（首中即返回，垃圾臂排到 keep 臂之后就漏出去）：$(
    awk -v n="$name" -F '\t' 'NR==FNR{g[FNR]=$0;next} $0!=g[FNR]{printf "第 %d 位 gen=[%s] %s=[%s]", FNR, g[FNR], n, $0; exit}' "$TMP/tbl.gen" "$f")"
}
cmp_table "setup.sh copy_claude_tree" "$TMP/tbl.setup"
cmp_table "release.mjs MANIFEST_RULES" "$TMP/tbl.release"

# setup.ps1 按名字数组 + 目录正则编码，和另三份的 glob 词汇结构性不同，硬对齐没有价值；
# 逐臂给出它在 ps1 里的对应 token，映射表必须覆盖全部臂——新增臂没进映射就红（return 1）。
ps1_token_for() {
  case "$1" in
    FRAMEWORK-MANIFEST.txt|settings.json|settings-windows.json|settings.local.json|\
    .needs-review|.needs-review.lock|.tdd-exempt|.red-verified|.static-gate|.degraded-review|\
    .fast-mode|.subagent-reminded|.stop-gate-strikes|.precompact-block-epoch|.async-verify-last|\
    signals.jsonl|.DS_Store|Thumbs.db) printf "'%s'" "$1" ;;             # $skip 系列数组按名字匹配
    '*/signals.jsonl') printf '%s' "'signals.jsonl'" ;;                  # 任意层级那份同名，走同一个 token
    '*/.DS_Store')     printf '%s' "'.DS_Store'" ;;
    '*/Thumbs.db')     printf '%s' "'Thumbs.db'" ;;
    'evidence/*')      printf '%s' '^evidence/' ;;
    'harness/receipts/*'|'harness/state/*'|'harness/waivers/*'|'harness/trend/*'|'harness/evidence/*')
                       printf '%s' '^harness/(receipts|state|waivers|trend|evidence)/' ;;
    '.runtime/*')      printf '%s' '^\.runtime/' ;;
    'worktrees/*')     printf '%s' '^worktrees/' ;;                      # Claude Code sub-agent 的 worktree 副本
    '*.bak'|'*.framework-new'|'*.swp')
                       printf '%s' '\.(bak|framework-new|swp)$' ;;
    # keep 臂：ps1 只排顶层 feedback/*.md，模板与子目录天然保留，语义等价
    'feedback/templates/*'|'feedback/*/*'|'feedback/*.md')
                       printf '%s' '^feedback/[^/]+\.md$' ;;
    *) return 1 ;;
  esac
}

# ps1 的表体：$skip 系列数组 + 紧随的目录/后缀正则，止于复制逻辑起点（$dest = Join-Path）。
# 只在这段里找 token——整文件找的话 'settings.json' 在 ps1 别处还有 3 行，从表里删了照样绿。
awk '
  !f && index($0, "$skip") == 1 { f = 1 }
  f && index($0, "$dest = Join-Path") { exit }
  f
' "$SETUP_PS1" >"$TMP/ps1-table.txt"
grep -q '= @(' "$TMP/ps1-table.txt" || fail "排除表口径：setup.ps1 抽不出 \$skip 表体（形态变了？断言会空转）"
grep -qE -- '-match' "$TMP/ps1-table.txt" || fail "排除表口径：setup.ps1 表体里一条目录/后缀正则都没有（抽早了？）"

# 表体实际持有的 token：各 $skip* 数组里的引号名 + 各条 -match 正则字面量。
# 数组按变量名一把抓（ps1 侧拆过 $skip / $skipAnyDepth），别钉死单个变量名，拆表就漏。
{
  awk 'index($0, "= @(") { a = 1 } a { print; if (/\)[[:space:]]*$/) a = 0 }' "$TMP/ps1-table.txt" \
    | grep -o "'[^']*'"
  sed -n "s/.*-match '\(.*\)')[[:space:]]*{[[:space:]]*return[[:space:]]*}.*/\1/p" "$TMP/ps1-table.txt"
} | sort -u >"$TMP/ps1-actual.txt"

: >"$TMP/ps1-expected.txt"
while IFS= read -r arm; do
  [ -n "$arm" ] || continue
  tok=$(ps1_token_for "$arm") || fail "排除表口径：新臂 [$arm] 没有 setup.ps1 对应 token（补 ps1_token_for 映射，并确认 ps1 真挡住了）"
  printf '%s\n' "$tok" >>"$TMP/ps1-expected.txt"
done <"$TMP/arms.gen"
sort -u "$TMP/ps1-expected.txt" -o "$TMP/ps1-expected.txt"

while IFS= read -r tok; do
  grep -qxF -- "$tok" "$TMP/ps1-actual.txt" \
    || fail "排除表口径：setup.ps1 的 \$skip+正则表缺 token [$tok]（gen-manifest.sh 有臂映射到它）"
done <"$TMP/ps1-expected.txt"
while IFS= read -r tok; do
  grep -qxF -- "$tok" "$TMP/ps1-expected.txt" \
    || fail "排除表口径：setup.ps1 多出 token [$tok]（另三份表没有对应臂，Windows 侧会静默漏装）"
done <"$TMP/ps1-actual.txt"

# ps1 那份不比臂序：表体里每条规则都是无条件 return（drop），没有 keep 分支，谁先谁后同解。
# 这个前提本身要有断言守着——一旦加进 keep 分支，序就变成真语义，得回来补 ps1 的序检查。
ps1_rules=$(grep -cE -- '(-match|-contains)' "$TMP/ps1-table.txt" || true)
ps1_drops=$(grep -cE -- '(-match|-contains).*\{[[:space:]]*return[[:space:]]*\}' "$TMP/ps1-table.txt" || true)
[ "$ps1_rules" = "$ps1_drops" ] \
  || fail "排除表口径：setup.ps1 表体 $ps1_rules 条规则里只有 $ps1_drops 条是无条件 return——出现 keep 分支后臂序变成真语义，⑥ 需要补 ps1 序检查"

echo "test-setup: ⑥ 四份排除表逐臂对照通过（基准 gen-manifest.sh $arm_count 条臂：setup.sh / release.mjs 臂序+处置全等，setup.ps1 token 集合全等）"

# ---- ⑥b 行为面：系统垃圾既不入装、也不入清单 ----
# 上面比的是字面，这里造真文件跑真安装器——规则还在但 case 臂序被挪到 keep 臂之后（
# feedback/templates/.DS_Store 就会漏出去），字面比对看不出来。
# 在 mktemp 里搭一棵迷你源码树跑，不污染本仓：setup.sh / gen-manifest.sh 的 source 都取自脚本自身位置。
MINI="$TMP/mini-src"
mkdir -p "$MINI/.claude/hooks" "$MINI/.claude/scripts" "$MINI/.claude/skills/demo" "$MINI/.claude/feedback/templates"
cp -p "$ROOT/setup.sh" "$MINI/setup.sh"
cp -p "$GEN_SH" "$MINI/.claude/scripts/gen-manifest.sh"
printf '# mini 主控\n'  >"$MINI/.claude/CLAUDE.md"
printf '{}\n'           >"$MINI/.claude/settings.json"
printf 'echo hi\n'      >"$MINI/.claude/hooks/demo.sh"
printf '# demo\n'       >"$MINI/.claude/skills/demo/SKILL.md"
printf '# 模板\n'       >"$MINI/.claude/feedback/templates/feedback-index-template.md"
# 每一类各造一份，含嵌套层与 keep 臂目录下的那份
JUNK=".DS_Store hooks/.DS_Store feedback/templates/.DS_Store Thumbs.db skills/demo/Thumbs.db hooks/demo.sh.swp"
for j in $JUNK; do printf 'junk\n' >"$MINI/.claude/$j"; done

MINI_TARGET="$TMP/mini-target"
bash "$MINI/setup.sh" -mac "$MINI_TARGET" >"$TMP/setup-mini.log" 2>&1 \
  || { cat "$TMP/setup-mini.log" >&2; fail "⑥b：迷你源码树安装失败"; }
for j in $JUNK; do
  [ ! -e "$MINI_TARGET/.claude/$j" ] || fail "⑥b：系统垃圾被 setup.sh 装进产物：$j"
done
# 反向：排除表不许过宽，正常框架文件照装
[ -f "$MINI_TARGET/.claude/CLAUDE.md" ] || fail "⑥b：排除表过宽，CLAUDE.md 未安装"
[ -f "$MINI_TARGET/.claude/hooks/demo.sh" ] || fail "⑥b：排除表过宽，hooks/demo.sh 未安装"
[ -f "$MINI_TARGET/.claude/feedback/templates/feedback-index-template.md" ] || fail "⑥b：排除表过宽，feedback 模板未安装"

bash "$MINI/.claude/scripts/gen-manifest.sh" >/dev/null 2>&1 || fail "⑥b：迷你源码树上 gen-manifest.sh 跑失败"
MINI_MANIFEST="$MINI/.claude/FRAMEWORK-MANIFEST.txt"
# 比路径列全等，不用 grep -F 子串——`.DS_Store` 是 `feedback/templates/.DS_Store` 的子串，
# 子串匹配红是红了，点名的却是另一份文件，照着去查会查错地方。
for j in $JUNK; do
  awk -F '\t' -v p="$j" '$1 == p { hit = 1 } END { exit !hit }' "$MINI_MANIFEST" \
    && fail "⑥b：系统垃圾被登记进 MANIFEST：$j"
done
grep -q '^CLAUDE.md	' "$MINI_MANIFEST" || fail "⑥b：排除表过宽，CLAUDE.md 不在 MANIFEST"
grep -q '^feedback/templates/feedback-index-template.md	' "$MINI_MANIFEST" \
  || fail "⑥b：排除表过宽，feedback/templates/ 下的模板不在 MANIFEST（垃圾臂排到了 keep 臂之后？）"

echo "test-setup: ⑥b 系统垃圾隔离校验通过（$(printf '%s' "$JUNK" | wc -w | tr -d ' ') 份垃圾不入装 / 不入清单，框架文件照常）"

# ---- ⑦ Claude Code 的 .claude/worktrees/ 不是框架文件 ----
# sub-agent 的 worktree 隔离会在 .claude/worktrees/<agent>/ 下建一整棵仓副本，里面有它自己的
# .claude/（含 harness/harness.mjs、hooks/、agents/…），文件名与框架文件逐个同名。六份排除表
# （生成器 / 两个安装器 / release / core 的两张 STATE_EXCLUDE / .claude/.gitignore）里一份都没有
# worktrees/，所以有 worktree 在场时开发机上跑一次安装，别人的项目里就会多出一整棵别人的仓副本。
# 契约：.claude/worktrees/ 整目录按根锚定排除。本段管安装侧 + 清单侧 + 入库侧三面，
# 字面口径（四份表逐臂）由 ⑥ 兜——那边 EXPECTED_ARMS 已按新增 worktrees/* 臂加到 35。
MINI_WT="$TMP/mini-wt-src"
mkdir -p "$MINI_WT/.claude/hooks" "$MINI_WT/.claude/scripts" "$MINI_WT/.claude/skills/demo" \
         "$MINI_WT/.claude/feedback/templates"
cp -p "$ROOT/setup.sh" "$MINI_WT/setup.sh"
cp -p "$GEN_SH" "$MINI_WT/.claude/scripts/gen-manifest.sh"
printf '# mini 主控\n'  >"$MINI_WT/.claude/CLAUDE.md"
printf '{}\n'           >"$MINI_WT/.claude/settings.json"
printf 'echo hi\n'      >"$MINI_WT/.claude/hooks/demo.sh"
printf '# demo\n'       >"$MINI_WT/.claude/skills/demo/SKILL.md"
printf '# 模板\n'       >"$MINI_WT/.claude/feedback/templates/feedback-index-template.md"
# 真实形态：副本里还有一层 .claude/，且里面的文件名与框架文件同名（naive 的按 leaf 名匹配会漏）
mkdir -p "$MINI_WT/.claude/worktrees/agent-x/.claude/harness" "$MINI_WT/.claude/worktrees/agent-x/.claude/hooks"
printf 'export const wt = 1;\n' >"$MINI_WT/.claude/worktrees/agent-x/.claude/harness/harness.mjs"
printf 'echo wt\n'              >"$MINI_WT/.claude/worktrees/agent-x/.claude/hooks/notify.sh"
printf '# worktree 副本\n'      >"$MINI_WT/.claude/worktrees/agent-x/README.md"

WT_TARGET="$TMP/mini-wt-target"
bash "$MINI_WT/setup.sh" -mac "$WT_TARGET" >"$TMP/setup-wt.log" 2>&1 \
  || { cat "$TMP/setup-wt.log" >&2; fail "⑦：带 worktree 副本的源码树安装失败"; }
[ ! -e "$WT_TARGET/.claude/worktrees" ] \
  || fail "⑦：setup.sh 把 worktree 副本装进了别人项目（copy_claude_tree 缺 worktrees/* 臂），泄漏：$(
       find "$WT_TARGET/.claude/worktrees" -type f | sed "s|$WT_TARGET/.claude/||" | tr '\n' ' ')"
# 反向：排除表不许过宽，正常框架文件照装
[ -f "$WT_TARGET/.claude/CLAUDE.md" ]        || fail "⑦：排除表过宽，CLAUDE.md 未安装"
[ -f "$WT_TARGET/.claude/hooks/demo.sh" ]    || fail "⑦：排除表过宽，hooks/demo.sh 未安装"

# 清单侧：worktree 副本不许被登记成框架文件
bash "$MINI_WT/.claude/scripts/gen-manifest.sh" >/dev/null 2>&1 || fail "⑦：迷你源码树上 gen-manifest.sh 跑失败"
WT_MANIFEST="$MINI_WT/.claude/FRAMEWORK-MANIFEST.txt"
if grep -q '^worktrees/' "$WT_MANIFEST"; then
  fail "⑦：worktree 副本被登记进 MANIFEST（gen-manifest.sh 缺 worktrees/* 臂）：$(
    grep '^worktrees/' "$WT_MANIFEST" | cut -f1 | tr '\n' ' ')"
fi
grep -q '^CLAUDE.md	' "$WT_MANIFEST" || fail "⑦：排除表过宽，CLAUDE.md 不在 MANIFEST"

# 入库侧：.claude/.gitignore 必须挡住 worktrees/——沙箱 sub-agent 一开工整棵副本就冒出来，
# 不挡的话它会被 git 当未跟踪文件报进 status，也会被 force-add 类操作误收进库。
[ -f "$ROOT/.claude/.gitignore" ] || fail "⑦：找不到 $ROOT/.claude/.gitignore"
grep -qx 'worktrees/' "$ROOT/.claude/.gitignore" \
  || fail "⑦：.claude/.gitignore 缺 worktrees/ 一行（六份排除表里的入库那份）"
# 行为面：真起个仓验 git 确实认这条（有 git 才跑；无 git 只剩上面的字面断言）
if command -v git >/dev/null 2>&1; then
  WT_IGN="$TMP/wt-ignore-probe"
  mkdir -p "$WT_IGN/.claude/worktrees/agent-x"
  cp -p "$ROOT/.claude/.gitignore" "$WT_IGN/.claude/.gitignore"
  printf 'x\n' >"$WT_IGN/.claude/worktrees/agent-x/foo.txt"
  ( cd "$WT_IGN" && git init -q . ) >/dev/null 2>&1 || fail "⑦：ignore 探针仓 git init 失败"
  ( cd "$WT_IGN" && git check-ignore -q .claude/worktrees/agent-x/foo.txt ) \
    || fail "⑦：.claude/.gitignore 里的 worktrees/ 没真挡住 .claude/worktrees/agent-x/foo.txt（写法不对？）"
  ( cd "$WT_IGN" && git check-ignore -q .claude/hooks/demo.sh ) \
    && fail "⑦：ignore 探针退化——.claude/hooks/demo.sh 也被忽略了，上面那条断言不作数"
fi

echo "test-setup: ⑦ worktrees 隔离校验通过（不入装 / 不入清单 / .claude/.gitignore 挡住，框架文件照常）"
