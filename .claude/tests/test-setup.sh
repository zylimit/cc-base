#!/usr/bin/env bash
# test-setup.sh — 安装器回归测试：把 cc-base 用 setup.sh 装到临时目录，断言产物正确。
# 验三件事：① 关键文件装齐（CLAUDE.md / 7 个 agents / 各 skill 的 SKILL.md / hooks 有可执行位 /
#   settings.json 合法 JSON）；② 私有 feedback 已排除（target 只剩 templates/ + 重置的
#   FEEDBACK-INDEX.md，无顶层私有 *.md，守 setup.sh #5）；③ 幂等性（装两次产物 SHA256 一致）。
# 另有 ④ 框架分层 / ⑤ 运行态隔离 / ⑥ 四份排除表逐臂对照（各自表内比，含臂序与 drop/keep 处置）
#   + ⑥b 系统垃圾不入装不入清单（行为）+ ⑦ Claude Code 的 .claude/worktrees/ 不入装不入清单不入库。
# ⑦–⑩ 验的是安装过程本身扛不扛得住事故：⑦ --dry-run 零写入 + 打计划、⑧ 独占锁、
#   ⑨ 维护标记（doctor 与 SessionStart 横幅两个消费方）、⑩ validate_target 逐段路径边界。
#   这四段用 pass/fail 逐条计数、末尾汇总，不像前六段撞见第一条就 exit——四项互相独立，
#   要一次看全各红在哪。①–⑥ 的写法不动。
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
# hook 的依赖库是 hooks/lib/ 四件 .mjs——只点 harness.mjs 一件的话，另外三件漏装照样静默：
# 缺哪一件都是「注册了但每次事件报 hook error」，装齐要逐件判。
[ -f "$CL/harness/harness.mjs" ]         || fail "harness/harness.mjs 未安装"
for m in io gatelog tier harness; do
  [ -f "$CL/hooks/lib/$m.mjs" ]          || fail "hooks/lib/$m.mjs 未安装"
done
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

# hooks/*.mjs 装齐。执行位不判：.mjs 由 settings.json 里的 `node <路径>` 拉起，
# 不走 shebang，位在不在与能不能跑无关（判它只会变成恒红）。
# 数量下限写 22 而不是 >0：21 个注册 hook + 未注册的 static-check，少一个就是漏装，
# 而「>0」在只装进一个文件时也照样绿。
hook_count=$(find "$CL/hooks" -maxdepth 1 -type f -name '*.mjs' | wc -l | tr -d ' ')
[ "$hook_count" -ge 22 ] || fail "hooks/*.mjs 装少了：实得 $hook_count 个，至少应有 22 个"

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
EXPECTED_ARMS=38
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
    'tests/*'|'research/*'|'agent-memory/*')
                       printf '%s' '^(tests|research|agent-memory)/' ;;  # 分发面收口：三者一条正则
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

# ---- ⑥c 单一真相源：三份生成表与 harness/exclusions.json 零漂移（手改任一份都在这红）----
node "$ROOT/.claude/scripts/gen-exclusions.mjs" --check >/dev/null 2>&1 \
  || fail "排除表口径：gen-exclusions.mjs --check 报漂移（有人手改了 gen-manifest.sh / setup.sh / setup.ps1 的 @exclusions 区而没改 harness/exclusions.json；跑 node .claude/scripts/gen-exclusions.mjs 重生）"
echo "test-setup: ⑥c gen-exclusions --check 零漂移"

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
# ---- ⑦–⑩ 安装器事务化 + 路径边界（批 5 红锁，实现落地前整段为红）----
# 前六段验的是「装出来的东西对不对」，这四段验的是「装的过程扛不扛得住事故」：
#   ⑦ --dry-run 零写入 + 打计划、⑧ 独占锁、⑨ 维护标记（含 doctor 与 SessionStart 横幅两个消费方）、
#   ⑩ validate_target 逐段路径边界。setup.sh 当前只有 `case "$target" in *..*)` 一条路径检查，
#   另三项一行实现都没有——所以这四段现在必须红，红因是功能缺失不是夹具坏。
# 与前六段的差别：这里不用 fail() 直接中断，改 pass/fail 逐条计数。红锁在库期间要一次看全四段
# 各红在哪，撞见第一条就 exit 的话后面三段永远看不见。脚手架自证（首装成功、探针文件在、
# doctor 基线绿）仍用 fail()——它红了后面的断言没有判别力，继续跑只会产出误导性的红。
B5_PASS=0
B5_FAIL=0

chk() {  # chk <0=通过/非0=失败> <标题> <EXPECT> <GOT>
  if [ "$1" = "0" ]; then
    B5_PASS=$((B5_PASS + 1)); printf '  [PASS] %s\n' "$2"
  else
    B5_FAIL=$((B5_FAIL + 1)); printf '  [FAIL] %s\n' "$2"
  fi
  printf '         EXPECT %s\n' "$3"
  printf '         GOT    %s\n' "$4"
}
# 日志首行塞进 GOT，主 Agent 不用重跑就能分辨「没实现」和「夹具没搭起来」。
# 控制字符会被路径用例带进输出，先滤掉再截断，别把终端搞花；只删 C0，别用 tr -cd '[:print:]'——
# C locale 下那个会把中文一起吃掉，中文路径用例的 GOT 就成了看不出所以然的空壳。
b5_head() { head -1 "$1" 2>/dev/null | tr -d '\000-\011\013-\037\177' | cut -c1-140; }

# ---- ⑦ --dry-run：目标一个字节不动，只在 stdout 打计划 ----
# 判据设计：光跑一次 dry-run 再比 sha 是不够的——幂等安装本来产物就不变（③ 已证），
# 那样「没变化」是恒真的废话。先在目标上种两处「真装一定会动」的扰动：
#   改过一个框架文件（真装会落 .framework-new）、删掉一个框架文件（真装会补回来），
# 这样 sha 清单相同才真的等于「一个字节没动」。
T7="$TMP/b5-dryrun"
bash "$ROOT/setup.sh" -ubt "$T7" >"$TMP/b5-d7-install.log" 2>&1 \
  || { cat "$TMP/b5-d7-install.log" >&2; fail "⑦ 脚手架：dry-run 目标首装失败"; }
[ -f "$T7/.claude/hooks/notify.mjs" ] || fail "⑦ 脚手架：装完没有 hooks/notify.mjs（换个仍存在的文件当 create 探针）"
[ -f "$T7/.claude/CLAUDE.md" ]       || fail "⑦ 脚手架：装完没有 CLAUDE.md（换个仍存在的文件当 conflict 探针）"
[ -z "$(find "$T7" -type f \( -name '*.framework-new' -o -name '*.bak' \) -print)" ] \
  || fail "⑦ 脚手架：首装就留下了 .bak/.framework-new，「dry-run 不许产生它们」的断言会失去判别力"
printf '# user local edit for dry-run probe\n' >>"$T7/.claude/CLAUDE.md"
rm -f "$T7/.claude/hooks/notify.mjs"
find "$T7" -type f -exec sha256sum {} + | LC_ALL=C sort >"$TMP/b5-d7.before"

D7RC=0
bash "$ROOT/setup.sh" -ubt --dry-run "$T7" >"$TMP/b5-d7.out" 2>"$TMP/b5-d7.err" || D7RC=$?
find "$T7" -type f -exec sha256sum {} + | LC_ALL=C sort >"$TMP/b5-d7.after"

ok=0; [ "$D7RC" = "0" ] || ok=1
chk "$ok" "⑦-1 --dry-run 是被识别的开关、正常退出" \
  "rc=0（防回归位：现在偶然绿——--dry-run 没被当开关，是被参数循环当成 target 顺位吃掉了）" \
  "rc=$D7RC stderr=[$(b5_head "$TMP/b5-d7.err")]"

ok=0; cmp -s "$TMP/b5-d7.before" "$TMP/b5-d7.after" || ok=1
chk "$ok" "⑦-2 --dry-run 后目标目录逐字节不变" \
  "find -type f 的 sha256 清单前后完全相同（含文件增删）" \
  "差异 $(diff "$TMP/b5-d7.before" "$TMP/b5-d7.after" 2>/dev/null | grep -c '^[<>]' || true) 行：$(diff "$TMP/b5-d7.before" "$TMP/b5-d7.after" 2>/dev/null | grep '^[<>]' | sed "s#$T7##g" | tr '\n' ' ' | cut -c1-200)"

ok=0
[ ! -e "$T7/.claude/CLAUDE.md.framework-new" ] || ok=1
[ -z "$(find "$T7" -type f \( -name '*.framework-new' -o -name '*.bak' \) -print)" ] || ok=1
chk "$ok" "⑦-3 --dry-run 不落 .framework-new / .bak" \
  "被用户改过的 CLAUDE.md 只该出现在计划的 conflict 清单里，不该在磁盘上多出一份新文件" \
  "残留=[$(find "$T7" -type f \( -name '*.framework-new' -o -name '*.bak' \) -print | sed "s#$T7##g" | tr '\n' ' ')]"

ok=0
[ ! -e "$T7/.claude/.runtime/install.lock" ]   || ok=1
[ ! -e "$T7/.claude/.runtime/install.marker" ] || ok=1
chk "$ok" "⑦-4 --dry-run 不建锁、不留维护标记（防回归位：现在偶然绿，.runtime 本就没人写）" \
  ".claude/.runtime/install.lock 与 install.marker 都不存在" \
  "lock=$([ -e "$T7/.claude/.runtime/install.lock" ] && echo yes || echo no) marker=$([ -e "$T7/.claude/.runtime/install.marker" ] && echo yes || echo no)"

# 计划的四类计数。形态不钉死（`create: 1` 与 `plan: create=1 update=233 ...` 都算），
# 只要求四个类别词各自与一个数字同行——「文件数」是契约明写的，没数字等于没报计划。
d7miss=""
for w in create update conflict skip; do
  grep -qiE "${w}[^0-9]*[0-9]" "$TMP/b5-d7.out" || d7miss="$d7miss $w"
done
ok=0; [ -z "$d7miss" ] || ok=1
chk "$ok" "⑦-5 stdout 打出 create / update / conflict / skip 四类的文件数" \
  "四个类别词各有一行带计数（大小写不限）" \
  "缺的类别=[${d7miss# }] stdout 首行=[$(b5_head "$TMP/b5-d7.out")] 行数=$(wc -l <"$TMP/b5-d7.out" | tr -d ' ')"

ok=0
grep -q 'hooks/notify\.mjs' "$TMP/b5-d7.out" || ok=1
grep -q 'CLAUDE\.md'       "$TMP/b5-d7.out" || ok=1
chk "$ok" "⑦-6 计划点名具体文件：被删的进 create、被改的进 conflict" \
  "stdout 同时出现 hooks/notify.mjs（本地已删，真装会补回）与 CLAUDE.md（本地改过，真装会落 .framework-new）" \
  "notify=$(grep -c 'hooks/notify\.mjs' "$TMP/b5-d7.out" || true) claude_md=$(grep -c 'CLAUDE\.md' "$TMP/b5-d7.out" || true)"

# ---- ⑧ 独占锁：活锁拒绝、陈旧锁接管、装完清锁 ----
# 不起两个真并发进程（那是 flaky 的来源），改手工造锁——锁的语义本来就是「文件里的 pid 还活着吗」，
# 造一个活 pid（本测试脚本自己）和一个死 pid 就能把两条分支都走到。
T8="$TMP/b5-lock"
bash "$ROOT/setup.sh" -ubt "$T8" >"$TMP/b5-l8-install.log" 2>&1 \
  || { cat "$TMP/b5-l8-install.log" >&2; fail "⑧ 脚手架：锁场景目标首装失败"; }
LOCKF="$T8/.claude/.runtime/install.lock"
mkdir -p "$T8/.claude/.runtime"

# 活锁：pid 用本脚本自己的 $$，跑测期间必然活着，不受 pid 复用/权限影响
printf '{"pid": %s, "startedAt": "2026-09-04T00:00:00Z"}\n' "$$" >"$LOCKF"
LOCK_SHA=$(sha256sum "$LOCKF" | awk '{print $1}')
L8RC=0
bash "$ROOT/setup.sh" -ubt "$T8" >"$TMP/b5-l8.out" 2>"$TMP/b5-l8.err" || L8RC=$?
cat "$TMP/b5-l8.out" "$TMP/b5-l8.err" >"$TMP/b5-l8.all"

ok=0; [ "$L8RC" != "0" ] || ok=1
chk "$ok" "⑧-1 锁里的 pid 还活着时，第二个 setup 必须拒绝安装" \
  "rc 非 0（不许一声不吭地和持锁进程并发写同一棵目标树）" \
  "rc=$L8RC 输出首行=[$(b5_head "$TMP/b5-l8.all")]"

ok=0
grep -q 'install\.lock' "$TMP/b5-l8.all" || ok=1
grep -qF -- "$$"        "$TMP/b5-l8.all" || ok=1
chk "$ok" "⑧-2 拒绝时点名锁文件与持锁 pid" \
  "输出同时含 install.lock 与持锁 pid=$$（不点名的话用户无从判断该等还是该清）" \
  "含 install.lock=$(grep -c 'install\.lock' "$TMP/b5-l8.all" || true) 含 pid=$(grep -cF -- "$$" "$TMP/b5-l8.all" || true)"

ok=0
[ -f "$LOCKF" ] || ok=1
[ "$(sha256sum "$LOCKF" 2>/dev/null | awk '{print $1}')" = "$LOCK_SHA" ] || ok=1
chk "$ok" "⑧-3 被拒的一方不许删改别人的锁（防砖，现在偶然绿：.runtime/* 在排除表里没人碰）" \
  "锁文件仍在且内容逐字节不变" \
  "存在=$([ -f "$LOCKF" ] && echo yes || echo no) sha 一致=$([ "$(sha256sum "$LOCKF" 2>/dev/null | awk '{print $1}')" = "$LOCK_SHA" ] && echo yes || echo no)"

# 陈旧锁：挑一个确实不存在的 pid。pid_max 在本机是 4194304，999999 是合法 pid 号、
# 理论上可能正被占用，所以现查现挑，别把 flaky 埋进来。
DEADPID=""
for cand in 999999 999998 999997 999996 999995; do
  if [ -d /proc ]; then
    [ -d "/proc/$cand" ] || DEADPID=$cand
  else
    kill -0 "$cand" 2>/dev/null || DEADPID=$cand
  fi
  [ -z "$DEADPID" ] || break
done
[ -n "$DEADPID" ] || fail "⑧ 脚手架：挑不出一个确定已死的 pid，陈旧锁分支没法验"
printf '{"pid": %s, "startedAt": "2026-09-04T00:00:00Z"}\n' "$DEADPID" >"$LOCKF"
L8SRC=0
bash "$ROOT/setup.sh" -ubt "$T8" >"$TMP/b5-l8s.out" 2>"$TMP/b5-l8s.err" || L8SRC=$?

ok=0; [ "$L8SRC" = "0" ] || ok=1
chk "$ok" "⑧-4 锁里的 pid 已死时，视为陈旧锁并接管，安装照常成功" \
  "rc=0（防回归位：现在偶然绿——根本没人读锁；实现后它变成「别被自己的崩溃残留锁死」的防砖位）" \
  "rc=$L8SRC 输出首行=[$(b5_head "$TMP/b5-l8s.err")]"

# 关键词不许只写「说了句什么」就算数，还得点名说的是哪把锁——试过一版把「残留」也放进
# 备选词，当场被 setup.sh 自己那句「清理异平台残留 + chmod」冒充成绿的。
ok=0
grep -qiE 'stale|陈旧|过期' "$TMP/b5-l8s.err" || ok=1
{ grep -q 'install\.lock' "$TMP/b5-l8s.err" || grep -qF -- "$DEADPID" "$TMP/b5-l8s.err"; } || ok=1
chk "$ok" "⑧-5 接管陈旧锁要在 stderr 说一句，且点名是哪把锁" \
  "stderr 含 stale / 陈旧 / 过期 之一，并且含 install.lock 或死 pid=$DEADPID（静默接管 = 用户看不出上一次装崩过）" \
  "stderr=[$(b5_head "$TMP/b5-l8s.err")]"

ok=0; [ ! -e "$LOCKF" ] || ok=1
chk "$ok" "⑧-6 装完删锁" \
  "安装成功返回后 .claude/.runtime/install.lock 不存在" \
  "锁仍在=$([ -e "$LOCKF" ] && echo yes || echo no)"

# ---- ⑧-7~⑧-11 锁的创建必须是原子的（TODO #41）----
# 上面六条验的是「锁已经在那儿时认不认」，这五条验的是「锁是怎么建出来的」。当前 acquire_lock
# 走「先 [ -f "$lock" ] 判存在、再 printf >"$lock" 写入」两步，中间没有任何互斥：两个 setup
# 同时起，都能通过存在性判断、各写一次锁，双双以为自己拿到了锁继续往下装。
# 契约：锁的创建必须原子（mkdir 目录形态 / set -o noclobber 配 : > lock / 等价手段），无论两个
# 进程的时序怎么交错，同一时刻只有一个能拿到锁，另一个必须拒绝（rc 非 0 + 点名锁文件）。
# 陈旧锁接管与装完清锁是 ⑧-4/⑧-5/⑧-6 的事，这里不重复。
#
# 判据取「恰好一个 rc 0，且被拒的那个点名 install.lock」这条合取，不是光看「双双 rc 0」。
# 实测注入版 20 轮：一半是双双装成功（都以为自己持锁），另一半是其中一个死在 copy_claude_tree
# 的 `cp: cannot create regular file ... File exists`——GNU cp 对不存在的 dest 用
# O_CREAT|O_EXCL，两个进程同时 stat 到 ENOENT 就撞。后者 rc 确实非 0，可它报的是「无法复制」，
# 跟锁毫无关系，只断言 rc 会被这半边冒充成绿。两半合取今天 0/20 全违规，修好后两半都该成立。
b8_verdict() {  # b8_verdict <rc1> <rc2> <log1> <log2> → OK / BOTH0 / BOTHFAIL / NOLOCK
  local r1=$1 r2=$2 loser
  if [ "$r1" = "0" ] && [ "$r2" = "0" ]; then echo BOTH0; return 0; fi
  if [ "$r1" != "0" ] && [ "$r2" != "0" ]; then echo BOTHFAIL; return 0; fi
  loser=$4; [ "$r1" = "0" ] || loser=$3
  if grep -q 'install\.lock' "$loser"; then echo OK; else echo NOLOCK; fi
}

# 并发跑两个 setup 到同一个 target，各自取 rc。pid 记进 B8_PIDS，两个都 wait 完立刻清空——
# 清理 trap 只杀「还没 wait 过」的，wait 过的 pid 可能已被系统回收再分配，盲杀会误伤别人。
B8_PIDS=""
B8_R1=0; B8_R2=0; B8_LA=""; B8_LB=""
b8_reap() { local p; for p in $B8_PIDS; do kill -9 "$p" 2>/dev/null || true; done; }
trap 'b8_reap; rm -rf "$TMP"' EXIT

b8_race() {  # b8_race <setup路径> <target> <rendezvous 文件；空=用发令枪> <日志前缀>
  local S=$1 T=$2 RV=$3 LP=$4 p1 p2 GO RDY n
  B8_LA="$LP.a"; B8_LB="$LP.b"; B8_R1=0; B8_R2=0
  if [ -n "$RV" ]; then
    : >"$RV"
    CC_RACE_RV="$RV" bash "$S" -ubt "$T" >"$B8_LA" 2>&1 & p1=$!
    CC_RACE_RV="$RV" bash "$S" -ubt "$T" >"$B8_LB" 2>&1 & p2=$!
  else
    # 裸 `bash x & bash x &` 起两个进程，第一个天然领先几毫秒，本机实测 36 轮零命中——竞态窗口
    # 只有「判存在→写入」那几微秒，起跑差稍大就整个错过，那样这条断言就是块永久绿的橡皮图章。
    # 发令枪：两个 worker 先起好、各报一次到、都到齐了再放 flag，几乎同一瞬间 exec 进 setup.sh。
    # 实测命中率回到 4~7%/轮，与派单里 code-reviewer 报的 ~8%（36 轮 3 次）同量级。
    GO="$LP.go"; RDY="$LP.rdy"; rm -f "$GO"; : >"$RDY"
    ( printf r >>"$RDY"; while [ ! -e "$GO" ]; do :; done; exec bash "$S" -ubt "$T" ) >"$B8_LA" 2>&1 & p1=$!
    ( printf r >>"$RDY"; while [ ! -e "$GO" ]; do :; done; exec bash "$S" -ubt "$T" ) >"$B8_LB" 2>&1 & p2=$!
    B8_PIDS="$p1 $p2"
    n=0
    while [ "$(wc -c <"$RDY" 2>/dev/null | tr -d ' ')" -lt 2 ] && [ "$n" -lt 300 ]; do
      n=$((n + 1)); sleep 0.01
    done
    : >"$GO"
  fi
  B8_PIDS="$p1 $p2"
  wait "$p1" || B8_R1=$?
  wait "$p2" || B8_R2=$?
  B8_PIDS=""
}

# 迷你源码树：并发轮数多，5 个文件的树每趟省 1.6 秒。竞态窗口在 copy_claude_tree 之前，
# 与源码树规模无关（⑩ 同样的理由用了同样的招）。setup.sh 是 cp -p 过来的**逐字节原版**，
# 下面 ⑧-8 的脚手架自证会拿 sha256 对着仓里那份核一遍，别让「原版」变成一句自称。
B8SRC="$TMP/b8-src"
mkdir -p "$B8SRC/.claude/hooks" "$B8SRC/.claude/skills/demo" "$B8SRC/.claude/feedback/templates"
cp -p "$ROOT/setup.sh" "$B8SRC/setup.sh"
printf '# b8 主控\n' >"$B8SRC/.claude/CLAUDE.md"
printf '{}\n'        >"$B8SRC/.claude/settings.json"
printf 'echo hi\n'   >"$B8SRC/.claude/hooks/demo.sh"
printf '# demo\n'    >"$B8SRC/.claude/skills/demo/SKILL.md"
printf '# 模板\n'    >"$B8SRC/.claude/feedback/templates/feedback-index-template.md"
bash "$B8SRC/setup.sh" -ubt "$TMP/b8-warm" >"$TMP/b8-warm.log" 2>&1 \
  || { cat "$TMP/b8-warm.log" >&2; fail "⑧ 脚手架：迷你源码树装不进去，后面的并发用例全无意义"; }
[ -f "$TMP/b8-warm/.claude/CLAUDE.md" ] || fail "⑧ 脚手架：迷你源码树装完没有 CLAUDE.md"
# 判据关键词自证：正常装完的输出里不许出现 install.lock，否则 b8_verdict 的 OK 会被自己冒充
if grep -q 'install\.lock' "$TMP/b8-warm.log"; then
  fail "⑧ 脚手架：正常安装输出里就有 install.lock，b8_verdict 的「被拒方点名锁」失去判别力"
fi

# ---- ⑧-7 主断言：把「判存在」和「写锁」之间撑开，两个进程必须只有一个拿到锁 ----
# 注入点从 acquire_lock 函数体里现找：存在性判断行（[ -f/-e "$lock" ]）与其后第一条重定向到
# **锁本身**的写入行（>"$lock"，闭引号紧跟，"$lock/xxx" 这种目录形态不算）之间插一行。
# 插的不是 sleep：本机实测 sleep 1 / sleep 2 都只有 9/10 命中（机器忙时起跑差能超过 2 秒），
# 固定睡眠换不来确定性。改插一个**会合点**——两个进程各报一次到、都到齐了才继续，于是「都通过
# 了存在性判断」从碰运气变成同步事实，实测 20/20 全部命中。会合有 3 秒上限，只有一个进程走到
# 这里时不会把测试挂死。CC_RACE_RV 没设时整行是空操作，注入版单跑照常。
# 锁逻辑改成原子创建后这两个锚点会消失（mkdir 目录形态没有 >"$lock" 行），那时注入失败，
# 本条以「注入点已不存在」判过并打印说明——修好之后它不会变成假红。
B8_INJ_NOTE=""
B8_INJ_OK=0
B8_LKS=$(grep -n '^acquire_lock()' "$ROOT/setup.sh" | head -1 | cut -d: -f1 || true)
if [ -z "$B8_LKS" ]; then
  B8_INJ_NOTE="setup.sh 里找不到顶格的 acquire_lock() 定义，注入点无从谈起"
else
  B8_LKE=$(awk -v s="$B8_LKS" 'NR>s && /^}/ {print NR; exit}' "$ROOT/setup.sh")
  B8_CHK=$(awk -v s="$B8_LKS" -v e="$B8_LKE" \
    'NR>=s && NR<=e && /\[[[:space:]]+-[fe][[:space:]]+"\$lock"[[:space:]]+\]/ {print NR; exit}' "$ROOT/setup.sh")
  B8_WRT=""
  [ -z "$B8_CHK" ] || B8_WRT=$(awk -v s="$B8_CHK" -v e="$B8_LKE" \
    'NR>s && NR<=e && />[[:space:]]*"\$lock"/ {print NR; exit}' "$ROOT/setup.sh")
  if [ -z "$B8_CHK" ] || [ -z "$B8_WRT" ]; then
    B8_INJ_NOTE="acquire_lock 里已经没有「先 [ -f \"\$lock\" ] 判存在、后 >\"\$lock\" 写入」这一对锚点（锁创建多半已原子化）"
  else
    B8_INJ_OK=1
  fi
fi

if [ "$B8_INJ_OK" = "1" ]; then
  B8RV='  { [ -z "${CC_RACE_RV:-}" ] || { printf x >>"$CC_RACE_RV"; __rv=0; while [ "$(wc -c <"$CC_RACE_RV" 2>/dev/null | tr -d " " || echo 9)" -lt 2 ] && [ "$__rv" -lt 300 ]; do __rv=$((__rv + 1)); sleep 0.01; done; }; }'
  B8INJSRC="$TMP/b8-inj-src"
  mkdir -p "$B8INJSRC"
  ( cd "$B8SRC" && tar -cf - . ) | ( cd "$B8INJSRC" && tar -xf - )
  awk -v n="$B8_WRT" -v inj="$B8RV" 'NR==n { print inj } { print }' "$ROOT/setup.sh" >"$B8INJSRC/setup.sh"
  if ! bash -n "$B8INJSRC/setup.sh" 2>"$TMP/b8-inj-syntax.err"; then
    B8_INJ_OK=0
    B8_INJ_NOTE="锚点找到了（判存在 L$B8_CHK / 写锁 L$B8_WRT），但插完 bash -n 不过：$(b5_head "$TMP/b8-inj-syntax.err")"
  fi
fi

if [ "$B8_INJ_OK" = "1" ]; then
  B8_VS=""; B8_BAD=0
  for i in 1 2 3; do
    b8_race "$B8INJSRC/setup.sh" "$(mktemp -d "$TMP/b8-inj-t-XXXXXX")" "$TMP/b8-rv.$i" "$TMP/b8-inj.$i"
    v=$(b8_verdict "$B8_R1" "$B8_R2" "$B8_LA" "$B8_LB")
    B8_VS="$B8_VS $i=$v(rc=$B8_R1/$B8_R2)"
    if [ "$v" != "OK" ]; then B8_BAD=$((B8_BAD + 1)); fi
  done
  ok=0; [ "$B8_BAD" = "0" ] || ok=1
  chk "$ok" "⑧-7 判存在与写锁之间被撑开时，两个并发 setup 仍必须只有一个拿到锁" \
    "3 轮全部 OK＝恰好一个 rc 0、另一个 rc 非 0 且输出点名 install.lock（BOTH0＝两边都以为自己持锁；NOLOCK＝被拒方报的不是锁而是 copy 撞车）" \
    "轮次判定：${B8_VS# }；末轮 a=[$(b5_head "$B8_LA")] b=[$(b5_head "$B8_LB")]"
else
  chk 0 "⑧-7 判存在与写锁之间被撑开时，两个并发 setup 仍必须只有一个拿到锁（**本轮没验到**，注入点不在了）" \
    "两步式锚点还在时把它撑开验原子性；锚点没了说明锁创建已不是「先判后写」，这条只能弃权" \
    "注入未生效：$B8_INJ_NOTE ——注意这个 PASS 是「没扫」不是「扫过没问题」，此时原子性只剩 ⑧-8 那条概率信号在守；换成 mkdir 目录形态的锁请回来给这段补一条对应形态的确定性红"
fi

# ---- ⑧-8 统计辅助：仓内原版 setup.sh 并发多轮，一次违规都不许有 ----
# 这条是**概率信号，不是判据**——⑧-7 才是判据。今天每轮约 4~7% 命中，24 轮约 6 成会红；
# 它绿不代表锁是原子的，只代表这 24 轮没掷中。反过来它红就一定是真的。
# 修好之后它变成守在**真正出货的那份 setup.sh** 上的回归位（⑧-7 跑的是注入过的副本）。
ok=0
[ "$(sha256sum "$B8SRC/setup.sh" | awk '{print $1}')" = "$(sha256sum "$ROOT/setup.sh" | awk '{print $1}')" ] || ok=1
chk "$ok" "⑧-8a 脚手架自证：并发跑的确实是仓内原版 setup.sh（逐字节）" \
  "$B8SRC/setup.sh 与 $ROOT/setup.sh 的 sha256 相同" \
  "副本=$(sha256sum "$B8SRC/setup.sh" | awk '{print $1}' | cut -c1-16) 仓内=$(sha256sum "$ROOT/setup.sh" | awk '{print $1}' | cut -c1-16)"

B8_N=24; B8_BAD2=0; B8_HIT=""
i=0
while [ "$i" -lt "$B8_N" ]; do
  i=$((i + 1))
  b8_race "$B8SRC/setup.sh" "$(mktemp -d "$TMP/b8-orig-t-XXXXXX")" "" "$TMP/b8-orig.$i"
  v=$(b8_verdict "$B8_R1" "$B8_R2" "$B8_LA" "$B8_LB")
  if [ "$v" != "OK" ]; then
    B8_BAD2=$((B8_BAD2 + 1))
    B8_LOSER=$B8_LB; [ "$B8_R1" = "0" ] || B8_LOSER=$B8_LA
    B8_HIT="$B8_HIT 轮$i=$v(rc=$B8_R1/$B8_R2 败方=[$(b5_head "$B8_LOSER")])"
  fi
done
ok=0; [ "$B8_BAD2" = "0" ] || ok=1
chk "$ok" "⑧-8 原版 setup.sh 并发 $B8_N 轮，零次「锁没挡住」（概率信号，判据是 ⑧-7）" \
  "$B8_N 轮每轮都是 OK；红了必是真竞态，绿了只说明没掷中——别拿这条单独下结论" \
  "违规 $B8_BAD2/$B8_N：${B8_HIT# }"

# ---- ⑧-9 对照：单个 setup 正常跑完，装完不留锁（防砖）----
B8SOLO="$TMP/b8-solo"
S9RC=0
bash "$B8SRC/setup.sh" -ubt "$B8SOLO" >"$TMP/b8-solo.log" 2>&1 || S9RC=$?
ok=0
[ "$S9RC" = "0" ] || ok=1
[ -f "$B8SOLO/.claude/CLAUDE.md" ] || ok=1
[ ! -e "$B8SOLO/.claude/.runtime/install.lock" ] || ok=1
chk "$ok" "⑧-9 对照：没人抢的时候单个 setup 照常装完、装完不留锁（防砖）" \
  "rc=0 且装出 CLAUDE.md 且 .claude/.runtime/install.lock 不存在（-e 判，文件形态和 mkdir 目录形态都盖）" \
  "rc=$S9RC 装出=$([ -f "$B8SOLO/.claude/CLAUDE.md" ] && echo yes || echo no) 锁残留=$([ -e "$B8SOLO/.claude/.runtime/install.lock" ] && echo yes || echo no) 输出=[$(b5_head "$TMP/b8-solo.log")]"

# ---- ⑧-10 对照：已有活锁时第二个 setup 拒绝（锁由实现自己建，不手工造）----
# ⑧-1/⑧-2 用的是手工写的**文件**锁；实现要是改成 mkdir 目录形态，手工那份就不再被认。
# 这条让持锁方是一个真的 setup 进程，锁长什么样由实现自己决定，只 poll 路径存不存在（-e）。
# 用全仓源码树是有意的：迷你树 0.15 秒就装完，抓不住持锁窗口。
B8HOLD="$TMP/b8-holder"
bash "$ROOT/setup.sh" -ubt "$B8HOLD" >"$TMP/b8-hold.log" 2>&1 & B8HPID=$!
B8_PIDS="$B8HPID"
B8HLOCK="$B8HOLD/.claude/.runtime/install.lock"
n=0
while [ ! -e "$B8HLOCK" ] && [ "$n" -lt 600 ]; do n=$((n + 1)); sleep 0.005; done
B8_SAW=no; [ ! -e "$B8HLOCK" ] || B8_SAW=yes
B8_ALIVE=no; if kill -0 "$B8HPID" 2>/dev/null; then B8_ALIVE=yes; fi
SEC=0
bash "$ROOT/setup.sh" -ubt "$B8HOLD" >"$TMP/b8-second.log" 2>&1 || SEC=$?
HRC=0
wait "$B8HPID" || HRC=$?
B8_PIDS=""
if [ "$B8_SAW" = "yes" ] && [ "$B8_ALIVE" = "yes" ]; then
  ok=0
  [ "$SEC" != "0" ] || ok=1
  grep -q 'install\.lock' "$TMP/b8-second.log" || ok=1
  [ "$HRC" = "0" ] || ok=1
  chk "$ok" "⑧-10 对照：持锁方是真 setup 进程时，第二个必须被拒且持锁方照常装完（防砖）" \
    "第二个 rc 非 0 且输出点名 install.lock；持锁方 rc=0（拒绝不许把持锁方一起搞挂）" \
    "第二个 rc=$SEC 点名锁=$(grep -c 'install\.lock' "$TMP/b8-second.log" || true) 持锁方 rc=$HRC 第二个输出=[$(b5_head "$TMP/b8-second.log")]"
else
  chk 0 "⑧-10 对照：持锁方是真 setup 进程时，第二个必须被拒（这轮没抓到持锁窗口，判过）" \
    "poll 到锁出现且持锁进程仍活着，才有判别力" \
    "看到锁=$B8_SAW 持锁进程还活着=$B8_ALIVE 持锁方 rc=$HRC（窗口没抓到就不判，免得机器忙时假红）"
fi

# ---- ⑧-11 测试自身卫生：并发用例不许把后台进程漏在外面 ----
# 这几条一轮起两个 setup，漏一个在后台就会继续往 /tmp 写（本仓有过 /tmp 被写满的事故）。
# 判据取 bash 自己的作业表，不拿 kill -0 查记下来的 pid——wait 过的 pid 可能已被回收再分配。
B8_LEFT=$(jobs -r -p 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')
ok=0; [ -z "$B8_LEFT" ] || ok=1
chk "$ok" "⑧-11 并发用例跑完，后台作业表清空（测试自身卫生）" \
  "jobs -r -p 为空——每个起过的 setup 都 wait 过了" \
  "还在跑的作业=[$B8_LEFT]"

# ---- ⑨ 维护标记：中途失败留痕，doctor 与 SessionStart 横幅都要看得见 ----
# 目标先完整装一遍再打断，是为了让 doctor 的判据有判别力：装了一半的空目录 doctor 本来就报一堆
# 缺失、rc 恒 1，那条「未完成」断言会永远偶然绿。仓根的 make-release.sh 是 doctor 的必查项、
# 装出来的 target 天然没有，补个 stub 把这条无关的红去掉，doctor 基线才能压到 rc=0。
T9="$TMP/b5-marker"
bash "$ROOT/setup.sh" -ubt "$T9" >"$TMP/b5-m9-install.log" 2>&1 \
  || { cat "$TMP/b5-m9-install.log" >&2; fail "⑨ 脚手架：标记场景目标首装失败"; }
: >"$T9/make-release.sh"
DOCTOR="$ROOT/.claude/scripts/doctor.sh"
[ -f "$DOCTOR" ] || fail "⑨ 脚手架：找不到 doctor.sh（$DOCTOR）"
D0RC=0
bash "$DOCTOR" "$T9" >"$TMP/b5-doc0.out" 2>"$TMP/b5-doc0.err" || D0RC=$?
[ "$D0RC" = "0" ] || { cat "$TMP/b5-doc0.err" >&2; fail "⑨ 脚手架：干净目标上 doctor 基线不是 rc=0（实得 $D0RC），「上次安装未完成」的断言会永远偶然绿"; }

MARKER="$T9/.claude/.runtime/install.marker"
M9RC=0
env CC_SETUP_FAIL_AFTER=3 bash "$ROOT/setup.sh" -ubt "$T9" >"$TMP/b5-m9.out" 2>"$TMP/b5-m9.err" || M9RC=$?

ok=0; [ "$M9RC" != "0" ] || ok=1
chk "$ok" "⑨-1 CC_SETUP_FAIL_AFTER=3 注入的中途失败要如实报错" \
  "rc 非 0（这个环境变量是测试用的故障注入口；不认它就没法验中断留痕）" \
  "rc=$M9RC 输出首行=[$(b5_head "$TMP/b5-m9.err")]"

ok=0; [ -f "$MARKER" ] || ok=1
chk "$ok" "⑨-2 中途失败后维护标记留在原地" \
  ".claude/.runtime/install.marker 存在" \
  "存在=$([ -f "$MARKER" ] && echo yes || echo no) .runtime 内容=[$(ls -A "$T9/.claude/.runtime" 2>/dev/null | tr '\n' ' ')]"

ok=0; grep -q 'interrupted' "$MARKER" 2>/dev/null || ok=1
chk "$ok" "⑨-3 标记的 status 从 active 翻成 interrupted" \
  "标记内容含 interrupted（装完删掉的那条路径走的是正常结束，中断留下的必须能自证是中断）" \
  "标记内容=[$(b5_head "$MARKER")]"

ok=0; grep -qE '"[^"]*\.(md|sh|ps1|mjs|json|txt)"' "$MARKER" 2>/dev/null || ok=1
chk "$ok" "⑨-4 标记附已写文件清单" \
  "标记里至少出现一个带扩展名的文件名（重装/回滚要知道上次写到哪）" \
  "标记内容=[$(b5_head "$MARKER")]"

D9RC=0
bash "$DOCTOR" "$T9" >"$TMP/b5-doc9.out" 2>"$TMP/b5-doc9.err" || D9RC=$?
cat "$TMP/b5-doc9.out" "$TMP/b5-doc9.err" >"$TMP/b5-doc9.all"
ok=0
[ "$D9RC" != "0" ] || ok=1
grep -qiE '未完成|INSTALL INTERRUPTED|install\.marker|interrupted' "$TMP/b5-doc9.all" || ok=1
chk "$ok" "⑨-5 doctor 对该目标报「上次安装未完成」且 rc 非 0" \
  "rc 非 0 且输出含 未完成 / INSTALL INTERRUPTED / install.marker / interrupted 之一（同一目标在中断前刚验过 doctor rc=0，所以这条红不是别的缺失撑出来的）" \
  "rc=$D9RC（中断前基线 rc=$D0RC）点名=$(grep -ciE '未完成|INSTALL INTERRUPTED|install\.marker|interrupted' "$TMP/b5-doc9.all" || true)"

BANNER="$ROOT/.claude/hooks/session-rules-banner.mjs"
if [ -f "$BANNER" ]; then
  printf '{"source":"startup"}' | env CLAUDE_PROJECT_DIR="$T9" node "$BANNER" >"$TMP/b5-ban9.out" 2>"$TMP/b5-ban9.err" || true
  cat "$TMP/b5-ban9.out" "$TMP/b5-ban9.err" >"$TMP/b5-ban9.all"
  ok=0; grep -qiE '未完成|安装中断|INSTALL INTERRUPTED|install\.marker|interrupted' "$TMP/b5-ban9.all" || ok=1
  chk "$ok" "⑨-6 SessionStart 横幅看到 marker 也打一行警告" \
    "输出含 未完成 / 安装中断 / INSTALL INTERRUPTED / install.marker / interrupted 之一（现有六条铁律横幅一个都不含，所以这条不会被原文蒙混）" \
    "输出行数=$(wc -l <"$TMP/b5-ban9.all" | tr -d ' ') 首行=[$(b5_head "$TMP/b5-ban9.all")]"

  # 对照组：期望值写死「一条都不许命中」，不从上面那次探测回填——没有 marker 的项目
  # 每次开 session 都被吓一跳，比不告警还糟。
  printf '{"source":"startup"}' | env CLAUDE_PROJECT_DIR="$T7" node "$BANNER" >"$TMP/b5-ban7.out" 2>"$TMP/b5-ban7.err" || true
  cat "$TMP/b5-ban7.out" "$TMP/b5-ban7.err" >"$TMP/b5-ban7.all"
  ban7hit=$(grep -ciE '未完成|安装中断|INSTALL INTERRUPTED|install\.marker|interrupted' "$TMP/b5-ban7.all" || true)
  ok=0; [ "$ban7hit" = "0" ] || ok=1
  chk "$ok" "⑨-6b 对照组：目标没有 marker 时横幅不许打这条警告" \
    "命中数 = 0" \
    "命中数=$ban7hit 首行=[$(b5_head "$TMP/b5-ban7.all")]"
else
  chk 1 "⑨-6 SessionStart 横幅看到 marker 也打一行警告" \
    "hooks/session-rules-banner.mjs 存在并可跑" "找不到 $BANNER"
fi

R9RC=0
bash "$ROOT/setup.sh" -ubt "$T9" >"$TMP/b5-m9re.out" 2>"$TMP/b5-m9re.err" || R9RC=$?
ok=0; [ "$R9RC" = "0" ] || ok=1
chk "$ok" "⑨-7 重跑安装能从中断态恢复" \
  "rc=0（顺带压住一个坑：崩溃时留下的锁 pid 已死，重跑必须能接管，不能被自己的残留锁死）" \
  "rc=$R9RC 输出首行=[$(b5_head "$TMP/b5-m9re.err")]"

ok=0; [ ! -e "$MARKER" ] || ok=1
chk "$ok" "⑨-8 重跑成功后标记消失（防回归位：现在偶然绿，标记压根没被创建过）" \
  "install.marker 不存在" \
  "标记仍在=$([ -e "$MARKER" ] && echo yes || echo no)"

ok=0; [ ! -e "$T9/.claude/.runtime/install.lock" ] || ok=1
chk "$ok" "⑨-9 正常安装结束不留锁（防回归位，同上）" \
  "install.lock 不存在" \
  "锁仍在=$([ -e "$T9/.claude/.runtime/install.lock" ] && echo yes || echo no)"

# 锁和标记住在 .claude/.runtime/ 里，而 ⑤ 的运行态隔离是按 `[ ! -e ]` 判**目录**的——
# 装完只删两个文件、把空目录留在原地，⑤ 当场红。这条把跨段约束摆到明面上，
# 免得实现者只看到 ⑤ 报「运行态目录被装进产物」一头雾水地去翻排除表。
ok=0; [ ! -e "$T9/.claude/.runtime" ] || ok=1
chk "$ok" "⑨-9b 正常安装结束后 .claude/.runtime 整个不留（含空目录，⑤ 按 -e 判目录）" \
  ".claude/.runtime 不存在" \
  "残留=[$(ls -A "$T9/.claude/.runtime" 2>/dev/null | tr '\n' ' ')] 目录还在=$([ -e "$T9/.claude/.runtime" ] && echo yes || echo no)"

DR9RC=0
bash "$DOCTOR" "$T9" >"$TMP/b5-docr.out" 2>"$TMP/b5-docr.err" || DR9RC=$?
cat "$TMP/b5-docr.out" "$TMP/b5-docr.err" >"$TMP/b5-docr.all"
docr_hit=$(grep -ciE '未完成|INSTALL INTERRUPTED|install\.marker' "$TMP/b5-docr.all" || true)
ok=0
[ "$DR9RC" = "0" ] || ok=1
[ "$docr_hit" = "0" ] || ok=1
chk "$ok" "⑨-10 恢复后 doctor 不再报未完成（防回归位：别把告警做成一装上就永久粘着）" \
  "rc=0 且「未完成」类点名 0 次" \
  "rc=$DR9RC 点名数=$docr_hit"

# ---- ⑩ validate_target 逐段路径边界 ----
# 拿真安装器跑真路径，但源码树换成一棵 5 个文件的迷你树：validate_target 在 main() 里跑在
# mkdir -p "$target" 之前，与源码树规模无关，而每趟少 2 秒，二十几个用例才跑得起。
TINY="$TMP/b5-tiny-src"
mkdir -p "$TINY/.claude/hooks" "$TINY/.claude/skills/demo" "$TINY/.claude/feedback/templates"
cp -p "$ROOT/setup.sh" "$TINY/setup.sh"
printf '# tiny 主控\n' >"$TINY/.claude/CLAUDE.md"
printf '{}\n'          >"$TINY/.claude/settings.json"
printf 'echo hi\n'     >"$TINY/.claude/hooks/demo.sh"
printf '# demo\n'      >"$TINY/.claude/skills/demo/SKILL.md"
printf '# 模板\n'      >"$TINY/.claude/feedback/templates/feedback-index-template.md"
TINYOK="$TMP/b5-tiny-sanity"
bash "$TINY/setup.sh" -ubt "$TINYOK" >"$TMP/b5-tiny.log" 2>&1 \
  || { cat "$TMP/b5-tiny.log" >&2; fail "⑩ 脚手架：迷你源码树装不进普通路径，后面的路径用例全无意义"; }
[ -f "$TINYOK/.claude/CLAUDE.md" ] || fail "⑩ 脚手架：迷你源码树装完没有 CLAUDE.md"

B5_CASE=0
b5_reject() {  # b5_reject <标题> <caseroot 下的相对目标路径> <应被点名的段；- = 这条规则没有可点名的段> <规则关键词正则；空=不查>
  local title=$1 rel=$2 seg=$3 rule=$4
  local caseroot log rc named ruled created
  B5_CASE=$((B5_CASE + 1))
  caseroot="$TMP/b5-pc-$B5_CASE"
  log="$TMP/b5-pc-$B5_CASE.log"
  rc=0
  bash "$TINY/setup.sh" -ubt "$caseroot/$rel" >"$log" 2>&1 || rc=$?
  # 「段」这一列有两种情况没法查：段本身是 `.`（grep -F 恒真，查了等于没查），
  # 以及规则根本不针对某一段（总段数超限点名的是数量）。这两条传 `-` 显式跳过，
  # 判据落在 rc / 没建目录 / 规则关键词上，别为了凑一列而写出必然误伤正确实现的断言。
  named=n/a
  if [ "$seg" != "-" ]; then
    named=no; grep -qF -- "$seg" "$log" && named=yes
  fi
  ruled=n/a;  [ -z "$rule" ] || { ruled=no; grep -qiE -- "$rule" "$log" && ruled=yes; }
  created=no; [ ! -e "$caseroot" ] || created=yes
  ok=0
  [ "$rc" != "0" ]     || ok=1
  [ "$created" = "no" ] || ok=1
  [ "$named" != "no" ]  || ok=1
  [ "$ruled" != "no" ]  || ok=1
  chk "$ok" "$title" \
    "rc 非 0 / 一个目录都不许建（validate_target 跑在 mkdir 之前）/ 点名犯规的那一段${rule:+ / 报得出是哪条规则（认 $rule）}" \
    "rc=$rc 建了目录=$created 点名段=$named 点名规则=$ruled 输出=[$(b5_head "$log")]"
}
b5_accept() {  # b5_accept <标题> <caseroot 下的相对目标路径>
  local title=$1 rel=$2 caseroot log rc
  B5_CASE=$((B5_CASE + 1))
  caseroot="$TMP/b5-pc-$B5_CASE"
  log="$TMP/b5-pc-$B5_CASE.log"
  rc=0
  bash "$TINY/setup.sh" -ubt "$caseroot/$rel" >"$log" 2>&1 || rc=$?
  ok=0
  [ "$rc" = "0" ] || ok=1
  [ -f "$caseroot/$rel/.claude/CLAUDE.md" ] || ok=1
  chk "$ok" "$title" \
    "rc=0 且真的装进去了（对照组：边界收严不许误伤正常路径）" \
    "rc=$rc 装出 CLAUDE.md=$([ -f "$caseroot/$rel/.claude/CLAUDE.md" ] && echo yes || echo no) 输出=[$(b5_head "$log")]"
}

# ⑩-A 非法字符 <>:"|?* ——逐个一条断言，一张表 N 条就写 N 条，
# 少写哪个哪个就永久免检（`*` 还顺带验了引用没漏，路径不许被 glob 展开）。
for ch in '<' '>' ':' '"' '|' '?' '*'; do
  b5_reject "⑩ 非法字符 [$ch]" "a/x${ch}y/b" "x${ch}y" 'char|字符|非法|illegal|invalid|禁'
done

# ⑩-B Windows 保留名 22 个全覆盖 + 大小写变体。不分大小写是契约明写的，
# 只测小写的话 `CON` 从 Windows 侧漏过去这套断言一声不吭。
for rn in con prn aux nul com1 com2 com3 com4 com5 com6 com7 com8 com9 \
          lpt1 lpt2 lpt3 lpt4 lpt5 lpt6 lpt7 lpt8 lpt9 CON Nul LPT3; do
  b5_reject "⑩ Windows 保留名 [$rn]" "a/$rn/b" "$rn" ''
done

CTRLSEG=$(printf 'x\001y')
b5_reject "⑩ 段以 . 结尾"        'a/x./b'      'x.'       'trailing|结尾|末尾|点|dot'
b5_reject "⑩ 段以空格结尾"      'a/x /b'      'x '       'trailing|结尾|末尾|空格|space'
b5_reject "⑩ 段含控制字符 0x01" "a/$CTRLSEG/b" "$CTRLSEG" 'control|控制'
b5_reject "⑩ 段是单个 ."        'a/./b'       '-'        'dot|点|段'
# `..` 是当前唯一已实现的那条：现在就该全绿，摆在这儿是防回归位，
# 别在改写成逐段检查时把这条老规则弄丢了。规则关键词不查——现有 die 文案本来就没有。
b5_reject "⑩ 段是 ..（防回归位，现在已实现）" 'a/../b' '..' ''
# 长度那条的关键词不收 `too long`：mkdir 自己的 ENAMETOOLONG 就叫 "File name too long"，
# 收了它等于让内核的报错替 validate_target 顶包（现在正是这条 rc 非 0 的来源）。
SEG256=$(head -c 256 /dev/zero | tr '\0' 'a')
b5_reject "⑩ 单段 256 字节" "a/$SEG256/b" "$SEG256" '255|长度|length|字节|byte'
DEEPREL=""
b5_i=0
while [ "$b5_i" -lt 200 ]; do DEEPREL="$DEEPREL/s$b5_i"; b5_i=$((b5_i + 1)); done
DEEPREL=${DEEPREL#/}
# 段数那条的关键词不收裸 `64`：路径里本来就有一段叫 s64，回显整条路径就把它蒙过去了。
# 「段」那列传 `-`：这条规则违反的是数量不是某一段，硬要求点名 s199 会误伤正确实现。
b5_reject "⑩ 总段数 200 段" "$DEEPREL" '-' '段数|层数|depth|too deep|过深|嵌套'

# ---- ⑩ 对照组：正常路径不许被误伤 ----
b5_accept "⑩ 对照：中文 + 空格路径" '正常/目录 名'
b5_accept "⑩ 对照：形近保留名不是保留名（console / com10 / auxiliary）" 'console/com10/auxiliary'
SEG255=$(head -c 255 /dev/zero | tr '\0' 'a')
b5_accept "⑩ 对照：单段 255 字节（边界内，>255 才拒）" "$SEG255/x"

# `.` 与 `./sub` 是文档里写死的默认调用形态（setup.sh 不给 target 就是 "."）。
# 契约说「拒绝 . 段」，字面照做会把这两种用法一起砖掉——这两条防砖位摆在这里，
# 逼实现把「路径中间的 . 段」和「以 . 起头的相对路径」分开处理。
B5_CASE=$((B5_CASE + 1))
DOTROOT="$TMP/b5-pc-$B5_CASE"
mkdir -p "$DOTROOT"
DOTRC=0
( cd "$DOTROOT" && bash "$TINY/setup.sh" -ubt . ) >"$TMP/b5-pc-$B5_CASE.log" 2>&1 || DOTRC=$?
ok=0
[ "$DOTRC" = "0" ] || ok=1
[ -f "$DOTROOT/.claude/CLAUDE.md" ] || ok=1
chk "$ok" "⑩ 防砖：target 为 .（不给参数时的默认值）必须照装" \
  "rc=0 且装进当前目录" \
  "rc=$DOTRC 装出 CLAUDE.md=$([ -f "$DOTROOT/.claude/CLAUDE.md" ] && echo yes || echo no) 输出=[$(b5_head "$TMP/b5-pc-$B5_CASE.log")]"

B5_CASE=$((B5_CASE + 1))
DOTROOT2="$TMP/b5-pc-$B5_CASE"
mkdir -p "$DOTROOT2"
DOT2RC=0
( cd "$DOTROOT2" && bash "$TINY/setup.sh" -ubt ./sub ) >"$TMP/b5-pc-$B5_CASE.log" 2>&1 || DOT2RC=$?
ok=0
[ "$DOT2RC" = "0" ] || ok=1
[ -f "$DOTROOT2/sub/.claude/CLAUDE.md" ] || ok=1
chk "$ok" "⑩ 防砖：target 为 ./sub（最常见的相对写法）必须照装" \
  "rc=0 且装进 ./sub" \
  "rc=$DOT2RC 装出 CLAUDE.md=$([ -f "$DOTROOT2/sub/.claude/CLAUDE.md" ] && echo yes || echo no) 输出=[$(b5_head "$TMP/b5-pc-$B5_CASE.log")]"

echo "==== test-setup ⑦–⑩（批 5 安装器事务化 + 路径边界）：PASS=$B5_PASS FAIL=$B5_FAIL ===="
if [ "$B5_FAIL" -ne 0 ]; then
  echo "test-setup: ⑦–⑩ 有 $B5_FAIL 条未通过（批 5 实现落地前这是预期的红；①–⑥ 已在上面全绿）" >&2
  exit 1
fi
