#!/usr/bin/env bash
# setup.sh — 把 cc-base 框架资产注入式安装到 target 项目（Mac/Linux）。
# 用法：./setup.sh [target_dir]    不给 target 默认当前目录 "."
# 流程：复制 .claude 框架文件（跳过运行时产物）→ chmod hooks → settings.json jq merge（不覆盖用户其他配置）→ 备份 .bak。
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

# 复制 .claude 框架树，跳过运行时产物 / 待删 / 机器特定文件；settings.json 不在此复制（走 merge）。
copy_claude_tree() {
  local src_dir=$1 dest_dir=$2 rel src dest mode
  [ -d "$src_dir" ] || die "源 .claude 不存在：$src_dir"
  while IFS= read -r -d '' src; do
    rel=${src#"$src_dir"/}
    case "$rel" in
      settings.json) continue ;;                                   # 走 merge_settings，不直接覆盖
      settings-windows.json) continue ;;                           # 无效产物（Claude Code 不加载），不传播
      settings.local.json) continue ;;                             # 机器特定覆盖，不入装
      .needs-review|.needs-review.lock) continue ;;                # stop-gate 运行时状态
      .tdd-exempt|.red-verified|.static-gate|.degraded-review) continue ;;  # 闸门运行时标记
    esac
    dest="$dest_dir/$rel"
    mode=""
    case "$rel" in
      hooks/*.sh) mode=0755 ;;
    esac
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
  need_cmd jq

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

  hooks_count=$(find "$source_dir/.claude/hooks" -type f -name '*.sh' 2>/dev/null | wc -l | tr -d ' ')
  skills_count=$(find "$source_dir/.claude/skills" -type f 2>/dev/null | wc -l | tr -d ' ')

  printf 'installed: hooks=%s skills=%s target=%s\n' "$hooks_count" "$skills_count" "$target"
  printf '完成。Claude Code 会从 %s/.claude/settings.json 加载 hooks（.sh，需 Git Bash 环境）。\n' "$target"
  printf 'Windows 纯 PowerShell 环境改用： pwsh -File setup.ps1 -Target %s\n' "$target"
}

main "$@"
