#!/usr/bin/env bash
# risk: low
# test-project-status.sh — project-status.mjs「现在到哪 / 活文档多重」只读报告回归（docs/living-docs-contract-2026-11.md 第 3 节）。
# 断言只从契约推导，只对关键数字与字段，不逐字对整行。夹具一律 mktemp -d + --root。
set -eu
REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
ENGINE="${1:-$REPO_ROOT/.claude/scripts/project-status.mjs}"
echo "===== test-project-status ====="
if ! command -v node >/dev/null 2>&1; then
  echo "SKIPPED: 无 node——project-status.mjs 是纯 node 脚本，未执行 != 通过。"
  exit 0
fi
[ -f "$ENGINE" ] || { echo "  [FAIL] 缺被测脚本：$ENGINE" >&2; exit 1; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
chk() {
  if [ "$1" = "0" ]; then PASS=$((PASS + 1)); printf '  [PASS] %s\n' "$2"
  else FAIL=$((FAIL + 1)); printf '  [FAIL] %s\n' "$2"; fi
  printf '         EXPECT %s\n         GOT    %s\n' "$3" "$4"
}
jf() {
  node -e '
    const fs=require("fs"); let d;
    try { d=JSON.parse(fs.readFileSync(process.argv[1],"utf8")); } catch(e){ process.stdout.write("<parse-error>"); process.exit(0); }
    for (const k of process.argv[2].split(".")) d=(d==null?undefined:d[k]);
    process.stdout.write(d===undefined?"<undefined>":String(d));
  ' "$1" "$2"
}
run_ps() { PS_OUT=$(mktemp "$TMP/o.XXXXXX"); PS_RC=0; ( env -u CLAUDE_PROJECT_DIR node "$ENGINE" --root "$ROOT" "$@" >"$PS_OUT" 2>/dev/null ) || PS_RC=$?; }
ROOT="$TMP/r"; mkdir -p "$ROOT"
# Spec：3 条需求（推断 1、默认 1，REQ-A-001 带修订史）；围栏里还有一条假条目，不许算；待定问题 1 行数据。
cat > "$ROOT/Product-Spec.md" <<'EOF'
# Spec（夹具）

## 功能需求
- [REQ-A-001] 条目一 [推断]
  续行：~~旧文~~ 修订：改过
- [REQ-A-002] 条目二 [默认]
- [REQ-A-003] 条目三 [确认]

```
- [REQ-FAKE-009] 围栏里的假条目 [推断]
```

## 待定问题
| 问题 | 状态 |
|---|---|
| 某事 | 待定 |
EOF
# 计划：现存 3 个 Phase + 1 条归档指针 → y=4；✅ 两个 + 指针 1 → x=3；当前=Phase 3；Phase 2 标题带「回放」。
cat > "$ROOT/DEV-PLAN.md" <<'EOF'
# DEV-PLAN（夹具）

## 已归档 Phase
- Phase 0: 旧阶段 ✅（2026-01-01，PASS） → DEV-PLAN.archive.md

## Phase 1: 第一阶段 ✅（2026-10-01，PASS）
- **Task 1.1：做事 REQ-A-001**

## Phase 2: 第二阶段回放 ✅（2026-10-02，PASS）
- **Task 2.1：做事 REQ-A-002**

## Phase 3: 第三阶段
- **Task 3.1：做事**
EOF
printf '# progress\n\n## Done\n- 2026-01-01 一条\n' > "$ROOT/progress.md"
# ============================== S1 ==============================
# 两行人读输出。打死：数错条数 / 把围栏里的行算进去（会得到 4 条）/ x、y 漏算归档指针 / 漏报回放与修订史 / 没有待归档也硬接「先跑 /archive」。
run_ps
L1=$(sed -n 1p "$PS_OUT"); L2=$(sed -n 2p "$PS_OUT")
ok=0; [ "$PS_RC" = "0" ] || ok=1
case "$L1" in '现在到哪：'*) : ;; *) ok=1 ;; esac
for k in '需求 3 条（含推断 1、默认 1）' '待定 1 项' 'Phase 3/4 完成，当前 Phase 3：' '1 个带回放待重验'; do grep -Fq -- "$k" <<<"$L1" || ok=1; done
case "$L2" in '活文档：'*) : ;; *) ok=1 ;; esac
for k in 'Spec ' '（带修订史 1 条，最长一条 ' 'DEV-PLAN ' 'progress '; do grep -Fq -- "$k" <<<"$L2" || ok=1; done
grep -Eq 'Spec [0-9]+\.[0-9]KB' <<<"$L2" || ok=1; grep -Fq '先跑 /archive' <<<"$L2" && ok=1
chk "$ok" "S1 人读两行：需求 3 条（围栏不算）、待定 1、Phase 3/4（含归档指针）、回放 1、修订史 1 条、无待归档不催 /archive" \
  "rc=0；第一行以「现在到哪：」开头含上述片段；第二行以「活文档：」开头，体积一位小数 KB" "rc=$PS_RC L1=[$L1] L2=[$L2]"
# ============================== S2 ==============================
# --json 字段。打死：缺字段、bytes 不是真字节数、reqs 状态/阶段算错（REQ-A-003 没人排 → 状态「—」）。
run_ps --json
ok=0; [ "$PS_RC" = "0" ] || ok=1; GOT=""
for f in "command:project-status" "spec.exists:true" "spec.bytes:$(wc -c < "$ROOT/Product-Spec.md" | tr -d ' ')" "spec.entries:3" "spec.inferred:1" "spec.defaulted:1" \
  "spec.pending:1" "spec.withHistory:1" "plan.total:4" "plan.done:3" "plan.current.n:3" "plan.replay:1" "plan.archiveDue:0" \
  "progress.exists:true" "progress.archiveDue:0" "progress.pinned.cap:15" "progress.pinned.overCap:false" \
  "reqs.0.id:REQ-A-001" "reqs.0.tag:推断" "reqs.0.phases.0:Phase 1" "reqs.0.state:完成" "reqs.1.tag:默认" "reqs.2.tag:确认" "reqs.2.state:—"; do
  v=$(jf "$PS_OUT" "${f%%:*}"); [ "$v" = "${f#*:}" ] || { ok=1; GOT="$GOT ${f%%:*}=$v"; }
done
chk "$ok" "S2 --json 的关键字段与数值（spec/plan/progress/reqs）逐项对得上" "rc=0；23 个字段值与契约一致" "rc=$PS_RC 不符:${GOT:- 无}"
# ============================== S3 ==============================
# 归档脚本拒绝（Decisions 31 条首末同日判不出方向，rc 1）时，第二行写「待归档未知：<原因>」带出 stderr 首行，不催 /archive。
# 打死：只写「（待归档未知）」把拒绝原因吞掉，没人知道该去理顺序。
ROOT="$TMP/s3"; mkdir -p "$ROOT"
{ printf '# progress\n\n## Decisions\n'; for i in $(seq 1 31); do printf -- '- 2026-11-01 决策%s\n' "$i"; done; } > "$ROOT/progress.md"
run_ps; L2=$(sed -n 2p "$PS_OUT")
ok=0; [ "$PS_RC" = "0" ] || ok=1; grep -Fq '待归档未知：' <<<"$L2" || ok=1; grep -Fq '同日' <<<"${L2#*待归档未知：}" || ok=1; grep -Fq '先跑 /archive' <<<"$L2" && ok=1
chk "$ok" "S3 归档脚本因首末同日拒绝：第二行「待归档未知：」后带出原因（含「同日」），不催 /archive" "rc=0；第二行含「待归档未知：」且其后含「同日」；不含「先跑 /archive」" "rc=$PS_RC L2=[$L2]"
printf '==== test-project-status：PASS=%s FAIL=%s ====\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ] || exit 1
