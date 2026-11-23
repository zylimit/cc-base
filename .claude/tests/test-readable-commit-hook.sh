#!/usr/bin/env bash
# risk: high
# test-readable-commit-hook.sh — 人读文档 · 提交前自动重出黑盒回归（docs/readable-spec/phase1-db-contract.md I 节第 1 条）。
# 钩子从本仓调，夹具是 mktemp -d 里的 git 仓（拷入引擎）；断言只从契约推导，每个「拦」配「不拦」对照。
set -eu
REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
HOOK="${1:-$REPO_ROOT/.claude/hooks/pre-commit-check.mjs}"
SCRIPTS="$(cd "$(dirname "$HOOK")/../scripts" && pwd)"  # 换了被测钩子（$1）时，生成器取它同一棵 .claude 下的
echo "===== test-readable-commit-hook ====="
if ! command -v node >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then echo "SKIPPED: 无 node 或 git，未执行 != 通过。"; exit 0; fi
[ -f "$HOOK" ] || { echo "  [FAIL] 缺被测钩子：$HOOK" >&2; exit 1; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
chk() {  # chk <0 过|非 0 不过> <标题> <EXPECT> <GOT>
  if [ "$1" -eq 0 ]; then PASS=$((PASS + 1)); printf '  [PASS] %s\n' "$2"; else FAIL=$((FAIL + 1)); printf '  [FAIL] %s\n' "$2"; fi
  printf '         EXPECT %s\n         GOT    %s\n' "$3" "$4"
}
G() { git -C "$1" -c user.name=t -c user.email=t@example.com "${@:2}"; }
nd() { env -u CLAUDE_PROJECT_DIR node "$SCRIPTS/readable-docs.mjs" "$@"; }
tree() { (cd "$1" && find . -type f | LC_ALL=C sort | xargs -r sha256sum | sha256sum | cut -c1-16); }
yn() { if "$@" >/dev/null 2>&1; then printf y; else printf n; fi; }
# hook <root> <命令>：喂一次 Bash 工具调用，RC 与 OUT（标准输出 + 标准错误）
hook() { RC=0; printf '{"tool_input":{"command":"%s"}}' "$2" | ( cd "$1" && CLAUDE_PROJECT_DIR="$1" node "$HOOK" ) >"$TMP/o" 2>&1 || RC=$?; OUT=$(cat "$TMP/o"); }
has() { printf '%s' "$OUT" | grep -qF -- "$1" && printf y || printf n; }
sql() {  # sql <root> [多一列]
  { echo "CREATE TABLE orders (id int PRIMARY KEY, status text${2:+, $2 text});"; echo "CREATE TABLE order_items (id int PRIMARY KEY, order_id int REFERENCES orders(id));"; } >"$1/sql/s.sql"
}
mk() {  # mk <root> [无配置|fast|ignore]：提交好的 git 仓；有配置时页面已重出并入库
  local r="$1"; mkdir -p "$r/sql" "$r/.claude/scripts" "$r/.claude/harness"; git -C "$r" init -q; : >"$r/Product-Spec.md"
  cp "$SCRIPTS/readable-docs.mjs" "$r/.claude/scripts/"; cp -r "$SCRIPTS/readable" "$r/.claude/scripts/"
  cp "$REPO_ROOT/.claude/harness/profile.json" "$r/.claude/harness/" 2>/dev/null || true
  [ "${2:-}" = fast ] && node -e 'const fs=require("fs"),f=process.argv[1],p=JSON.parse(fs.readFileSync(f,"utf8"));p.default="fast";fs.writeFileSync(f,JSON.stringify(p))' "$r/.claude/harness/profile.json"
  [ "${2:-}" = ignore ] && echo 'docs/readable/' >"$r/.gitignore"
  sql "$r"
  if [ "${2:-}" != 无配置 ]; then
    mkdir -p "$r/docs/readable-src"
    printf '{"version":1,"title":"t","spec":"Product-Spec.md","ddl":["sql/s.sql"],"codeRoots":[],"ignore":[]}\n' >"$r/docs/readable-src/config.json"
    nd build --root "$r" >/dev/null 2>&1
  fi
  G "$r" add -A; G "$r" commit -qm init
}
CM='git commit -m x'
# 1 打死：没有配置的项目也出声 / 也跑
A="$TMP/a1"; mk "$A" 无配置; sql "$A" extra; G "$A" add -A; hook "$A" "$CM"
chk "$([ "$RC" = 0 ] && [ "$(has 人读文档)" = n ] && [ ! -d "$A/docs" ] && echo 0 || echo 1)" "无 docs/readable-src/config.json 的仓库：提交退出码 0、输出无「人读文档」、没生出 docs 目录" "0|n|无 docs" "$RC|$(has 人读文档)|$([ -d "$A/docs" ] && echo 有 docs || echo 无 docs)"
# 2 对照：页面现行且已提交 → 不拦
B="$TMP/a2"; mk "$B"; echo x >"$B/n.txt"; G "$B" add n.txt; hook "$B" "$CM"
chk "$([ "$RC" = 0 ] && [ "$(has 'git add docs/readable')" = n ] && echo 0 || echo 1)" "页面现行且已提交：退出码 0、不提示 git add docs/readable（拦错的对照）" "0|n" "$RC|$(has 'git add docs/readable')"
# 3 打死：只报不重出、重出后不拦、暂存后仍拦
C="$TMP/a3"; mk "$C"; sql "$C" memo_x; G "$C" add sql; hook "$C" "$CM"; R1=$RC; H1=$(has 'git add docs/readable'); P1=$(yn grep -qF memo_x "$C/docs/readable/db/t-orders.html")
G "$C" add docs/readable; hook "$C" "$CM"
chk "$([ "$R1|$H1|$P1|$RC" = "2|y|y|0" ] && echo 0 || echo 1)" "加一列不重出：退出码 2、提示 git add docs/readable、页面已含新列 memo_x；暂存 docs/readable 后再提交退出码 0" "2|y|y|0" "$R1|$H1|$P1|$RC"
# 4 打死：出文档的毛病卡死提交
D="$TMP/a4"; mk "$D"; sed -i 's#sql/s.sql#sql/none.sql#' "$D/docs/readable-src/config.json"; G "$D" add -A; hook "$D" "$CM"
chk "$([ "$RC" = 0 ] && [ "$(has 没重出)" = y ] && echo 0 || echo 1)" "ddl 指到不存在的文件：退出码 0、输出写明「没重出」" "0|y" "$RC|$(has 没重出)"
# 5 打死：说明过期不报 / 过期还拦
E="$TMP/a5"; mk "$E"; printf '## table:orders\n订单主表。\n' | nd note put --root "$E" >/dev/null 2>&1; nd build --root "$E" >/dev/null 2>&1; G "$E" add -A; G "$E" commit -qm note
sql "$E" memo_x; nd build --root "$E" >/dev/null 2>&1; G "$E" add -A; hook "$E" "$CM"
chk "$([ "$RC" = 0 ] && [ "$(has 待更新)" = y ] && echo 0 || echo 1)" "表说明遇上加列、重出并暂存后：退出码 0（不拦）、输出提到「待更新」" "0|y" "$RC|$(has 待更新)"
# 6 打死：docs/readable 被 .gitignore 还拦
F="$TMP/a6"; mk "$F" ignore; sql "$F" memo_x; G "$F" add sql; hook "$F" "$CM"
chk "$([ "$RC" = 0 ] && echo 0 || echo 1)" "docs/readable 在 .gitignore 里、来源变了：退出码 0（没有可暂存的页面，不拦）" "0" "$RC"
# 7 打死：不是提交也重出
H="$TMP/a7"; mk "$H"; sql "$H" memo_x; T0=$(tree "$H/docs/readable"); hook "$H" "git status"; T1=$(tree "$H/docs/readable")
chk "$([ "$RC" = 0 ] && [ "$T0" = "$T1" ] && echo 0 || echo 1)" "命令是 git status、来源已变：退出码 0、docs/readable 总哈希不变（没重出）" "0|same" "$RC|$([ "$T0" = "$T1" ] && echo same || echo changed)"
# 8 打死：advise 档（fast）也拦
K="$TMP/a8"; mk "$K" fast; sql "$K" memo_x; G "$K" add sql; hook "$K" "$CM"
chk "$([ "$RC|$(has 'git add docs/readable')" = "0|y" ] && echo 0 || echo 1)" "fast 档（pre-commit-check 为 advise）：来源变了照重出照报，退出码 0 不拦" "0|y" "$RC|$(has 'git add docs/readable')"
# 9 打死：配置漏了项目里的建表文件却不吭声（契约 I 节第 5 条）/ 吭声却拦提交 / 只说「有漏项」不点名
M="$TMP/a9"; mk "$M"; printf 'CREATE TABLE audit_log (id int PRIMARY KEY);\n' >"$M/sql/audit_log.sql"; G "$M" add -A; hook "$M" "$CM"
chk "$([ "$RC|$(has audit_log.sql)" = "0|y" ] && echo 0 || echo 1)" "配置没列 sql/audit_log.sql：提交照样成功（退出码 0），输出点名 audit_log.sql" "0|y" "$RC|$(has audit_log.sql)"
# 10 打死：没有漏项也多说话（提醒太吵，人就不看了）。对照基线 = 同一提交里只多一个无关文件、页面现行的输出；漏项那条的输出里多出的部分才是新提醒，这里要求没有
N="$TMP/a10"; mk "$N"; echo x >"$N/n.txt"; G "$N" add n.txt; hook "$N" "$CM"; NOISE=$(printf '%s' "$OUT" | grep -cE '漏|suggest|配置跟' || true)
chk "$([ "$RC|$NOISE|${#OUT}" = "0|0|0" ] && echo 0 || echo 1)" "配置跟得上项目、页面现行：退出码 0、输出为空（这一段不多说一个字）" "0|0|0" "$RC|$NOISE|${#OUT}"
echo "===== 汇总：PASS=$PASS FAIL=$FAIL ====="
[ "$FAIL" -eq 0 ]
