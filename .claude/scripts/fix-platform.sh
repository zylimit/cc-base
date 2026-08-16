#!/usr/bin/env bash
# fix-platform.sh — 把项目 .claude/settings.json 的 hook command 归一为当前平台（.sh）形态。
# 跨平台搬迁后旧平台（.ps1）command 残留会与本地平台 command 并存报错；搬到 Linux/Mac 后跑本脚本一次即可。
# 不依赖 cc-base 仓库在场、不依赖 jq——用 python3 解析/写回 JSON（python3 是 cc-base 已有依赖，
# session-rules-banner.sh 已用 python3 -c 解析 JSON）。python3 不可用时降级报错+指引，不自作主张换实现。
set -u

die() {
  printf 'fix-platform: %s\n' "$1" >&2
  exit 1
}

# 定位项目根：优先 CLAUDE_PROJECT_DIR，其次脚本所在目录往上推断（脚本在 <root>/.claude/scripts/ 下）。
script_dir=$(cd "$(dirname "$0")" && pwd) || die "无法定位脚本目录"
project_root="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$project_root" ]; then
  case "$script_dir" in
    */.claude/scripts|*/.claude/scripts/|*\\.claude\\scripts|*\\.claude\\scripts\\)
      project_root=$(cd "$script_dir/../.." && pwd) || die "无法推断项目根"
      ;;
    *)
      project_root="$script_dir"
      ;;
  esac
fi

settings="$project_root/.claude/settings.json"
[ -f "$settings" ] || die "找不到 settings.json：$settings（请在项目根运行，或设 CLAUDE_PROJECT_DIR）"

hooks_dir="$project_root/.claude/hooks"

if ! command -v python3 >/dev/null 2>&1; then
  die "本机无 python3，无法解析 JSON。python3 是 fix-platform.sh 的必需依赖（不用 jq）。请安装 python3 后重跑；或改在 Windows 跑 fix-platform.ps1。"
fi

# python3 脚本：归一 settings.json 的 hook command 为 .sh 形态。
# 逻辑：遍历 hooks 各 event 各 group.hooks，① 删所有「.ps1 形态」command（含 powershell/pwsh + 指向 .claude/hooks/<name>.ps1）
#       ② 对每个被删的 .ps1 command 反推 hook name，若对应 .sh command 不在同 group 则补一条 .sh 形态
#       ③ 保留所有 .sh command 不动 ④ 保留用户自定义 command（不匹配框架 .ps1 路径的不动）。幂等。
python3 - "$settings" <<'PYEOF'
import json, re, sys

settings_path = sys.argv[1]

with open(settings_path, 'r', encoding='utf-8') as f:
    data = json.load(f)

# .ps1 残留判定：command 同时匹配 powershell/pwsh 解释器 与 .claude/hooks/<name>.ps1 路径
# （与 setup.sh jq is_ps1_residue 同口径，只删框架 .ps1 形态，不误伤用户自定义 powershell 命令）。
PS1_RESIDUE_RE = re.compile(r'powershell|pwsh', re.IGNORECASE)
PS1_HOOK_RE = re.compile(r'\.claude[/\\]hooks[/\\]([A-Za-z0-9_-]+)\.ps1')
SH_HOOK_RE = re.compile(r'\.claude[/\\]hooks[/\\]([A-Za-z0-9_-]+)\.sh')

# .sh 形态模板（与仓库 settings.json 一致）："$CLAUDE_PROJECT_DIR"/.claude/hooks/<name>.sh
SH_FORM = '"$CLAUDE_PROJECT_DIR"/.claude/hooks/'

deleted_ps1 = 0
added_sh = 0

hooks = data.get('hooks')
if isinstance(hooks, dict):
    for groups in hooks.values():
        if not isinstance(groups, list):
            continue
        for group in groups:
            if not isinstance(group, dict):
                continue
            hook_list = group.get('hooks')
            if not isinstance(hook_list, list):
                continue
            # 先收集本 group 已有的 .sh hook name（避免补重复）
            existing_sh = set()
            for h in hook_list:
                if isinstance(h, dict):
                    m = SH_HOOK_RE.search(h.get('command', '') or '')
                    if m:
                        existing_sh.add(m.group(1))
            new_list = []
            deleted_entries = []
            for h in hook_list:
                if not isinstance(h, dict):
                    new_list.append(h)
                    continue
                cmd = h.get('command', '') or ''
                if PS1_RESIDUE_RE.search(cmd) and PS1_HOOK_RE.search(cmd):
                    name = PS1_HOOK_RE.search(cmd).group(1)
                    deleted_entries.append((name, h))
                    deleted_ps1 += 1
                else:
                    new_list.append(h)
            # 对每个被删的 name，若同 group 无对应 .sh 则补一条（保留原 entry 的 type/timeout）
            for name, orig in deleted_entries:
                if name in existing_sh:
                    continue
                new_h = dict(orig)
                new_h['command'] = SH_FORM + name + '.sh'
                new_list.append(new_h)
                added_sh += 1
                existing_sh.add(name)
            group['hooks'] = new_list

# statusLine：框架状态行 command 同口径归一为 .sh 形态（只认框架 statusline 路径，不动用户自定义状态行）
STATUSLINE_PS1_RE = re.compile(r'\.claude[/\\]scripts[/\\]statusline\.ps1', re.IGNORECASE)
statusline_fixed = 0
sl = data.get('statusLine')
if isinstance(sl, dict):
    cmd = sl.get('command', '') or ''
    if PS1_RESIDUE_RE.search(cmd) and STATUSLINE_PS1_RE.search(cmd):
        sl['command'] = '"$CLAUDE_PROJECT_DIR"/.claude/scripts/statusline.sh'
        statusline_fixed = 1

# 写回（indent=2 保结构；ensure_ascii=False 保中文若存在）
with open(settings_path, 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write('\n')

print('fix-platform: deleted .ps1 residue commands=%d, added .sh commands=%d, statusline fixed=%d' % (deleted_ps1, added_sh, statusline_fixed))
PYEOF
py_rc=$?
[ $py_rc -eq 0 ] || die "python3 归一失败（exit $py_rc）"

# chmod 0755 .claude/hooks/*.sh 与 .claude/scripts/*.sh（补执行位——.sh 在 Linux/Mac 必须有执行位才能被 hook / statusLine 触发）
chmod_count=0
for d in "$hooks_dir" "$project_root/.claude/scripts"; do
  [ -d "$d" ] || continue
  while IFS= read -r -d '' sh; do
    if chmod 0755 "$sh"; then chmod_count=$((chmod_count + 1)); fi
  done < <(find "$d" -maxdepth 1 -type f -name '*.sh' -print0 2>/dev/null)
done
printf 'fix-platform: chmod 0755 hooks/*.sh files=%d\n' "$chmod_count"
printf '完成。settings.json 已归一为 .sh 形态（Linux/Mac）。路径：%s\n' "$settings"
