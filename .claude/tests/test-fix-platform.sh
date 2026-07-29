#!/usr/bin/env bash
# test-fix-platform.sh — fix-platform 跨平台归一回归测试（固化 Task 2 改动）。
# 覆盖：
#   ① fix-platform.sh（python3）：.ps1+.sh 混合 fixture → .ps1 残留清空、.sh 齐全、
#      hooks/*.sh 0755 执行位、幂等重跑不变。
#   ② fix-platform.ps1（pwsh，对称路径）：.sh+.ps1 混合 fixture → .sh 残留清空、.ps1 齐全。
# 无 python3 → ① 标 SKIP；无 pwsh → ② 标 SKIP。不假绿（SKIP ≠ PASS）。
# fixture JSON 用 python3 json.dump 生成，不用 heredoc 裸写（Task 1/2 验证踩过 $/引号转义坑）。
set -u

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
[ -f "$ROOT/.claude/scripts/fix-platform.sh" ] || { echo "test-fix-platform: 缺 fix-platform.sh" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
SKIP=0
pass() { PASS=$((PASS + 1)); echo "  [PASS] $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  [FAIL] $1"; }
skip() { SKIP=$((SKIP + 1)); echo "  [SKIP] $1"; }

# gen_fixture <out_path> <mode>：用 python3 生成 fixture settings.json（避免 heredoc 转义坑）。
# mode=ps1_residue：.ps1 + .sh 并存（.ps1 是异平台残留，搬到 Linux/Mac 后的形态）。
# mode=sh_residue： .sh + .ps1 并存（.sh 是异平台残留，搬到 Windows 后的形态）。
gen_fixture() {
  python3 - "$1" "$2" <<'PYEOF'
import json, sys
out, mode = sys.argv[1], sys.argv[2]
sh_cmd = '"$CLAUDE_PROJECT_DIR"/.claude/hooks/tdd-gate.sh'
ps1_cmd = 'pwsh -File .claude/hooks/tdd-gate.ps1'
if mode == 'ps1_residue':
    data = {"hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [
        {"type": "command", "command": ps1_cmd, "timeout": 5},
        {"type": "command", "command": sh_cmd, "timeout": 5}
    ]}]}}
elif mode == 'sh_residue':
    data = {"hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [
        {"type": "command", "command": sh_cmd, "timeout": 5},
        {"type": "command", "command": ps1_cmd, "timeout": 5}
    ]}]}}
else:
    data = {"hooks": {}}
with open(out, 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
PYEOF
}

# count_cmds <settings_path> <python_regex>：数 settings.json 里匹配 regex 的 command 条数。
count_cmds() {
  python3 - "$1" "$2" <<'PYEOF'
import json, re, sys
settings, pattern = sys.argv[1], sys.argv[2]
with open(settings, 'r', encoding='utf-8') as f:
    data = json.load(f)
count = 0
def walk(o):
    global count
    if isinstance(o, dict):
        c = o.get('command')
        if isinstance(c, str) and re.search(pattern, c):
            count += 1
        for v in o.values():
            walk(v)
    elif isinstance(o, list):
        for i in o:
            walk(i)
walk(data)
print(count)
PYEOF
}

echo "===== test-fix-platform ====="

# ---- ① fix-platform.sh（python3，归一为 .sh）----
echo "--- ① fix-platform.sh：.ps1 残留 → 清空、.sh 齐全、chmod 0755、幂等 ---"
if ! command -v python3 >/dev/null 2>&1; then
    skip "fix-platform.sh：无 python3（fix-platform.sh 依赖 python3 解析 JSON，不假绿）"
else
    FP="$ROOT/.claude/scripts/fix-platform.sh"
    PROJ="$TMP/proj-sh"
    CL="$PROJ/.claude"
    mkdir -p "$CL/hooks"
    # 造两个 .sh 文件验 chmod（先去执行位，确证 fix-platform.sh 加了位而非本来就带）
    echo '#!/usr/bin/env bash' > "$CL/hooks/tdd-gate.sh"
    echo '#!/usr/bin/env bash' > "$CL/hooks/pre-commit-check.sh"
    chmod -x "$CL/hooks"/*.sh 2>/dev/null || true

    gen_fixture "$CL/settings.json" ps1_residue

    CLAUDE_PROJECT_DIR="$PROJ" bash "$FP" >"$TMP/fp-1.log" 2>&1 \
      || { cat "$TMP/fp-1.log" >&2; fail "fix-platform.sh 首次跑失败（exit $?）"; }

    # 断言 .ps1 残留清空（含 powershell/pwsh 的 command 应为 0）
    ps1=$(count_cmds "$CL/settings.json" 'powershell|pwsh')
    if [ "$ps1" -eq 0 ]; then pass "fix-platform.sh：.ps1 残留 command 已清空"; \
    else fail "fix-platform.sh：仍有 $ps1 条 .ps1 残留 command"; fi

    # 断言 .sh command 齐全（指向 .claude/hooks/<name>.sh）
    sh_n=$(count_cmds "$CL/settings.json" '\.claude[/\\]hooks[/\\][A-Za-z0-9_-]+\.sh')
    if [ "$sh_n" -gt 0 ]; then pass "fix-platform.sh：.sh command 存在（$sh_n 条）"; \
    else fail "fix-platform.sh：无 .sh command（应至少 1 条）"; fi

    # 断言 hooks/*.sh 有 0755 执行位
    exec_ok=0; total=0
    while IFS= read -r -d '' h; do
        total=$((total + 1))
        [ -x "$h" ] && exec_ok=$((exec_ok + 1))
    done < <(find "$CL/hooks" -maxdepth 1 -type f -name '*.sh' -print0 2>/dev/null)
    if [ "$total" -gt 0 ] && [ "$exec_ok" -eq "$total" ]; then \
        pass "fix-platform.sh：hooks/*.sh 全有执行位（$exec_ok/$total）"; \
    else fail "fix-platform.sh：执行位不全（$exec_ok/$total）"; fi

    # 幂等：重跑，settings.json 不变
    cp -p "$CL/settings.json" "$TMP/settings.before"
    CLAUDE_PROJECT_DIR="$PROJ" bash "$FP" >"$TMP/fp-2.log" 2>&1 \
      || { cat "$TMP/fp-2.log" >&2; fail "fix-platform.sh 二次跑失败（exit $?）"; }
    if cmp -s "$TMP/settings.before" "$CL/settings.json"; then \
        pass "fix-platform.sh：幂等（二次跑 settings.json 不变）"; \
    else fail "fix-platform.sh：非幂等（二次跑后 settings.json 变化）"; fi
fi

# ---- ② fix-platform.ps1（pwsh，归一为 .ps1，对称路径）----
echo ""
echo "--- ② fix-platform.ps1：.sh 残留 → 清空、.ps1 齐全（对称路径） ---"
if ! command -v pwsh >/dev/null 2>&1; then
    skip "fix-platform.ps1：无 pwsh（对称路径无法验证，不假绿）"
else
    if ! command -v python3 >/dev/null 2>&1; then
        skip "fix-platform.ps1：无 python3（断言需要 python3 解析 JSON）"
    else
        FPPS1="$ROOT/.claude/scripts/fix-platform.ps1"
        PROJ2="$TMP/proj-ps1"
        CL2="$PROJ2/.claude"
        mkdir -p "$CL2/hooks"
        gen_fixture "$CL2/settings.json" sh_residue

        CLAUDE_PROJECT_DIR="$PROJ2" pwsh -NoProfile -File "$FPPS1" >"$TMP/fpp-1.log" 2>&1 \
          || { cat "$TMP/fpp-1.log" >&2; fail "fix-platform.ps1 首次跑失败（exit $?）"; }

        # 断言 .sh 残留清空（纯 .sh command：含 .sh 路径且不含 powershell/pwsh）
        sh_res=$(python3 - "$CL2/settings.json" <<'PYEOF'
import json, re, sys
with open(sys.argv[1], 'r', encoding='utf-8') as f: data = json.load(f)
n = 0
def walk(o):
    global n
    if isinstance(o, dict):
        c = o.get('command')
        if isinstance(c, str) and re.search(r'\.claude[/\\]hooks[/\\][A-Za-z0-9_-]+\.sh', c) \
           and not re.search(r'powershell|pwsh', c, re.I):
            n += 1
        for v in o.values(): walk(v)
    elif isinstance(o, list):
        for i in o: walk(i)
walk(data)
print(n)
PYEOF
)
        if [ "$sh_res" -eq 0 ]; then pass "fix-platform.ps1：.sh 残留 command 已清空"; \
        else fail "fix-platform.ps1：仍有 $sh_res 条 .sh 残留 command"; fi

        # 断言 .ps1 command 存在（含 powershell/pwsh）
        ps1_n=$(count_cmds "$CL2/settings.json" 'powershell|pwsh')
        if [ "$ps1_n" -gt 0 ]; then pass "fix-platform.ps1：.ps1 command 存在（$ps1_n 条）"; \
        else fail "fix-platform.ps1：无 .ps1 command（应至少 1 条）"; fi
    fi
fi

echo ""
echo "结果：PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ]
