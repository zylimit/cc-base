#!/usr/bin/env bash
# setup.sh — 把 cc-base 框架资产注入式安装到 target 项目（Mac/Linux）。
# 用法：./setup.sh [target_dir]    不给 target 默认当前目录 "."
# 流程：复制 .claude 框架文件（跳过运行时产物）→ chmod hooks → settings.json 合并（有 jq 自动 merge；
#   无 jq 降级：新 target 直接复制，已有 settings 备份 .bak + 打印手工合并指引，不静默覆盖）→ 备份 .bak。
set -u

die() {
  printf 'setup: %s\n' "$1" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "缺少必需命令：$1"
}

validate_target() {
  local target=$1
  case "$target" in
    *..*) die "不安全的 target 目录：$target" ;;
  esac
}

copy_file() {
  local src=$1 dest=$2 mode=${3:-}
  mkdir -p "$(dirname "$dest")" || die "无法创建目录：$(dirname "$dest")"
  if [ -e "$dest" ] && ! cmp -s "$src" "$dest"; then
    cp -p "$dest" "$dest.bak" || die "无法备份 $dest"
    printf 'backup: %s.bak\n' "$dest"
  fi
  cp -p "$src" "$dest" || die "无法复制 $src → $dest"
  [ -n "$mode" ] && chmod "$mode" "$dest"
}

# --- 框架核心层 vs 项目私有层（FRAMEWORK-MANIFEST.txt）---
# 目标侧旧 MANIFEST 记录了上次安装时各框架文件的 SHA（LF 归一化后 sha256，抗 autocrlf）。
# 覆盖前对照：目标文件 == 旧框架版本 → 安全覆盖升级；用户改过或无旧 MANIFEST → 不覆盖，
# 落 <name>.framework-new 供手工合并。不在清单里的目标侧文件 = 私有层，一律不动。
norm_sha() { tr -d '\r' <"$1" | sha256sum | awk '{print $1}'; }

OLD_MANIFEST=""          # 目标侧旧 MANIFEST 路径（存在时）
FRAMEWORK_NEW_LIST=""    # 本次落 .framework-new 的文件列表（换行分隔）

manifest_sha_of() {
  # $1=rel 路径；从旧 MANIFEST 查该文件上次安装时的 SHA，查不到输出空
  [ -n "$OLD_MANIFEST" ] || return 0
  awk -F '\t' -v p="$1" '$0 !~ /^#/ && $1 == p { print $2; exit }' "$OLD_MANIFEST"
}

# 复制 .claude 框架树，跳过运行时产物 / 待删 / 机器特定文件；settings.json 不在此复制（走 merge）。
copy_claude_tree() {
  local src_dir=$1 dest_dir=$2 rel src dest mode old_sha
  [ -d "$src_dir" ] || die "源 .claude 不存在：$src_dir"
  [ -f "$dest_dir/FRAMEWORK-MANIFEST.txt" ] && OLD_MANIFEST="$dest_dir/FRAMEWORK-MANIFEST.txt"
  while IFS= read -r -d '' src; do
    rel=${src#"$src_dir"/}
    case "$rel" in
      FRAMEWORK-MANIFEST.txt) continue ;;                          # 清单最后单独覆盖安装
      settings.json) continue ;;                                   # 走 merge_settings，不直接覆盖
      settings-windows.json) continue ;;                           # 无效产物（Claude Code 不加载），不传播
      settings.local.json) continue ;;                             # 机器特定覆盖，不入装
      .needs-review|.needs-review.lock) continue ;;                # stop-gate 运行时状态
      .tdd-exempt|.red-verified|.static-gate|.degraded-review) continue ;;  # 闸门运行时标记
      .fast-mode|.subagent-reminded) continue ;;                   # 运行态标记
      signals.jsonl|*/signals.jsonl) continue ;;                   # evolution 运行态信号队列（任意层级 basename）
      evidence/*) continue ;;                                      # 运行态证据目录
      feedback/templates/*) ;;                                     # 保留模板（顶层 *.md 才是私人经验）
      feedback/*/*) ;;                                              # 保留 feedback 子目录其他文件
      feedback/*.md) continue ;;                                    # 私人进化经验（顶层 *.md）；INDEX 装后重置为模板
    esac
    dest="$dest_dir/$rel"
    mode=""
    case "$rel" in
      hooks/*.sh) mode=0755 ;;
    esac
    # manifest 分层判断：目标已存在且内容不同时才需要区分「可升级」vs「用户改过」
    if [ -e "$dest" ] && ! cmp -s "$src" "$dest"; then
      old_sha=$(manifest_sha_of "$rel")
      if [ -n "$old_sha" ] && [ "$(norm_sha "$dest")" = "$old_sha" ]; then
        : # 目标 == 旧框架版本，安全覆盖升级（copy_file 仍留 .bak）
      else
        # 用户改过（SHA 与旧 MANIFEST 不符）或目标无 MANIFEST（老版本装的）→ 不覆盖
        cp -p "$src" "$dest.framework-new" || die "无法写入 $dest.framework-new"
        [ -n "$mode" ] && chmod "$mode" "$dest.framework-new"
        FRAMEWORK_NEW_LIST="${FRAMEWORK_NEW_LIST}${rel}
"
        continue
      fi
    fi
    copy_file "$src" "$dest" "$mode"
  done < <(find "$src_dir" -type f -print0)
}

merge_settings() {
  local src=$1 dest=$2 tmp
  mkdir -p "$(dirname "$dest")" || die "无法创建 settings 目录"
  if [ ! -f "$dest" ]; then
    copy_file "$src" "$dest"
    return
  fi
  # 无 jq 降级：target 已有 settings.json 时不静默覆盖——备份 .bak 后保留原文件，打印手工合并指引，
  # 其余资产照常已复制完（不中断安装）。有 jq 仍走下面的自动合并。
  if ! command -v jq >/dev/null 2>&1; then
    cp -p "$dest" "$dest.bak" || die "无法备份 $dest"
    printf 'backup: %s.bak\n' "$dest"
    printf 'setup: 本机无 jq，settings.json 未自动合并（保留你原有的 %s）。\n' "$dest" >&2
    printf 'setup: 请手工把框架 settings.json 里的 hooks 合并进去（来源：%s），\n' "$src" >&2
    printf 'setup: 要点：把 source 各 event 下的 hook command 追加到 target 同名 event，已有的不重复加。\n' >&2
    return
  fi
  # target 已有 settings.json：只追加 cc-base 里 target 尚无的 hook command，不动用户其他配置。
  tmp=$(mktemp) || die "无法创建临时文件"
  jq -s '
    def commands: [.. | objects | .command? // empty] | map(select(. != "")) | unique;
    .[0] as $target
    | .[1] as $source
    | ($target | commands) as $existing
    | reduce (($source.hooks // {}) | keys_unsorted[]) as $event ($target;
        reduce (($source.hooks[$event] // [])[]) as $group (.;
          ($group.hooks // []
            | map(select((.command // "") as $cmd | ($cmd != "" and (($existing | index($cmd)) | not)))))
          as $new_hooks
          | if ($new_hooks | length) > 0 then
              .hooks[$event] = ((.hooks[$event] // []) + [($group | .hooks = $new_hooks)])
            else
              .
            end
        )
      )
  ' "$dest" "$src" >"$tmp" || { rm -f "$tmp"; die "无法合并 settings.json"; }
  mv "$tmp" "$dest" || { rm -f "$tmp"; die "无法更新 settings.json"; }
}

main() {
  # jq 可选：有则 settings.json 自动合并；无则降级（新 target 直接复制，已有 settings 备份 .bak + 手工合并指引）
  command -v jq >/dev/null 2>&1 || printf 'setup: 未检测到 jq，settings.json 走无 jq 降级路径。\n' >&2

  local target=${1:-.}
  validate_target "$target"

  local script_dir source_dir hooks_count skills_count
  script_dir=$(cd "$(dirname "$0")" && pwd) || die "无法定位脚本目录"
  source_dir=$script_dir
  [ -d "$source_dir/.claude" ] || die "脚本目录下无 .claude（请在 cc-base 仓库根运行）"
  mkdir -p "$target" || die "无法创建 target：$target"
  [ -w "$target" ] || die "target 不可写：$target"

  copy_claude_tree "$source_dir/.claude" "$target/.claude"
  merge_settings "$source_dir/.claude/settings.json" "$target/.claude/settings.json"

  # 装完把新 MANIFEST 复制进目标（下次升级据此区分「框架旧版可覆盖」vs「用户改过不可覆盖」）
  if [ -f "$source_dir/.claude/FRAMEWORK-MANIFEST.txt" ]; then
    copy_file "$source_dir/.claude/FRAMEWORK-MANIFEST.txt" "$target/.claude/FRAMEWORK-MANIFEST.txt"
  fi

  # 汇总本次未覆盖的用户改动文件（新版本已放 .framework-new 供手工合并）
  if [ -n "$FRAMEWORK_NEW_LIST" ]; then
    local fn_count
    fn_count=$(printf '%s' "$FRAMEWORK_NEW_LIST" | grep -c .)
    printf 'setup: %s 个文件用户侧有改动，未覆盖；新版本已放 <文件>.framework-new 供手工合并：\n' "$fn_count" >&2
    printf '%s' "$FRAMEWORK_NEW_LIST" | sed 's/^/setup:   - .claude\//' >&2
  fi

  # feedback 顶层经验已在 copy_claude_tree 跳过；把 INDEX 重置为干净模板（与 make-release.sh 同源）
  local fb_tpl="$source_dir/.claude/feedback/templates/feedback-index-template.md"
  [ -f "$fb_tpl" ] && copy_file "$fb_tpl" "$target/.claude/feedback/FEEDBACK-INDEX.md"

  hooks_count=$(find "$source_dir/.claude/hooks" -type f -name '*.sh' 2>/dev/null | wc -l | tr -d ' ')
  skills_count=$(find "$source_dir/.claude/skills" -type f 2>/dev/null | wc -l | tr -d ' ')

  printf 'installed: hooks=%s skills=%s target=%s\n' "$hooks_count" "$skills_count" "$target"
  printf '完成。Claude Code 会从 %s/.claude/settings.json 加载 hooks（.sh，需 Git Bash 环境）。\n' "$target"
  printf 'Windows 纯 PowerShell 环境改用： pwsh -File setup.ps1 -Target %s\n' "$target"
}

main "$@"
