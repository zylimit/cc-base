#!/usr/bin/env bash
# gen-manifest.sh — 在框架源仓库生成 .claude/FRAMEWORK-MANIFEST.txt（框架核心文件清单）。
# 用法： bash .claude/scripts/gen-manifest.sh   （在 cc-base 仓库根或任意位置跑均可）
# 清单格式：每行 <相对 .claude/ 的路径>TAB<sha256>；# 开头为注释头。
# 哈希算法：LF 归一化后再 SHA256（先 tr -d '\r' 再 sha256sum）——git autocrlf 会让不同
#   checkout 的工作树字节 CRLF/LF 不一，直接对字节算会误判"用户改过"，归一化后跨平台稳定。
# 排除逻辑对齐 setup.sh copy_claude_tree：运行态/机器特定/私有 feedback 不入清单；
#   settings.json 走 merge 不套 manifest；FEEDBACK-INDEX.md 装后重置为模板也不入清单。
set -eu

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SRC="$ROOT/.claude"
OUT="$SRC/FRAMEWORK-MANIFEST.txt"
[ -d "$SRC" ] || { echo "gen-manifest: 找不到 .claude：$SRC" >&2; exit 1; }

norm_sha() { tr -d '\r' <"$1" | sha256sum | awk '{print $1}'; }

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

while IFS= read -r -d '' src; do
  rel=${src#"$SRC"/}
  case "$rel" in
    FRAMEWORK-MANIFEST.txt) continue ;;                          # 清单自身不入清单
    settings.json) continue ;;                                   # 天生合并对象，走 merge 逻辑
    settings-windows.json|settings.local.json) continue ;;       # 无效产物 / 机器特定
    .needs-review|.needs-review.lock) continue ;;                # stop-gate 运行时状态
    .tdd-exempt|.red-verified|.static-gate|.degraded-review) continue ;;  # 闸门运行时标记
    .fast-mode|.subagent-reminded) continue ;;                   # 运行态标记
    signals.jsonl|*/signals.jsonl) continue ;;                   # evolution 运行态信号队列
    evidence/*) continue ;;                                      # 运行态证据目录
    harness/receipts/*) continue ;;                              # 大仓治理运行态回执（harness.mjs / catalog 本体照常入清单）
    *.bak|*.framework-new) continue ;;                           # 安装器产物
    feedback/templates/*) ;;                                     # 保留模板（框架资产）
    feedback/*/*) ;;                                             # feedback 子目录其他文件
    feedback/*.md) continue ;;                                   # 私人经验 + FEEDBACK-INDEX（装后重置为模板）
  esac
  printf '%s\t%s\n' "$rel" "$(norm_sha "$src")"
done < <(find "$SRC" -type f -print0) | sort >"$TMP"

{
  printf '# cc-base FRAMEWORK-MANIFEST（框架核心文件清单，由 gen-manifest.sh 生成）\n'
  printf '# algorithm: sha256 of LF-normalized bytes（哈希前 tr -d '"'"'\\r'"'"'，抗 git autocrlf 干扰）\n'
  printf '# format: <path relative to .claude/>\tsha256\n'
  printf '# 不在本清单里的文件 = 项目私有层，升级安装一律不动。\n'
  cat "$TMP"
} >"$OUT"

count=$(wc -l <"$TMP" | tr -d ' ')
echo "gen-manifest: 已写入 $OUT（$count 个框架文件）"
