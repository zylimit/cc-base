#!/usr/bin/env bash
# test-setup.sh — 安装器回归测试：把 cc-base 用 setup.sh 装到临时目录，断言产物正确。
# 验三件事：① 关键文件装齐（CLAUDE.md / 7 个 agents / 各 skill 的 SKILL.md / hooks 有可执行位 /
#   settings.json 合法 JSON）；② 私有 feedback 已排除（target 只剩 templates/ + 重置的
#   FEEDBACK-INDEX.md，无顶层私有 *.md，守 setup.sh #5）；③ 幂等性（装两次产物 SHA256 一致）。
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
# 若 /usr/bin 或 /bin 里碰巧有 jq，再从 PATH 里踢掉其所在目录
JQ_REAL=$(command -v jq 2>/dev/null || true)
if [ -n "$JQ_REAL" ]; then
  JQ_DIR=$(dirname "$JQ_REAL")
  case ":$NOJQ_PATH:" in
    *":$JQ_DIR:"*) NOJQ_PATH=$(printf '%s' "$NOJQ_PATH" | tr ':' '\n' | grep -v -F -x "$JQ_DIR" | tr '\n' ':' | sed 's/:$//') ;;
  esac
  NOJQ_PATH="$FAKEBIN:$NOJQ_PATH"
fi
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
