#!/usr/bin/env bash
# lib-harness.sh — 大仓治理 harness 共享判定库（各 hook source 后调 harness_enabled / harness_node_ok / harness_run）。
# 默认关闭：唯一开关是 catalog 文件 $CLAUDE_PROJECT_DIR/.claude/harness/module-catalog.json——
# 存在才算启用（harness_enabled 返回 0），不存在时调用方跳过 harness 分支、走原逻辑、零行为变化。
# node 定位靠 command -v；找不到 node 时 harness_node_ok 返回非 0（可判定的降级信号，非 crash、非假绿），
# 调用方据此可见跳过 harness 判定，绝不 block 小项目。故意不依赖 jq，Bash / PowerShell 各读同一 catalog 开关。

# catalog 开关文件路径（缺 CLAUDE_PROJECT_DIR 输出空并返回非 0）
harness_catalog() {
  [ -n "${CLAUDE_PROJECT_DIR:-}" ] || return 1
  printf '%s/.claude/harness/module-catalog.json\n' "$CLAUDE_PROJECT_DIR"
}

# harness 是否启用：0 = catalog 存在（大仓治理开），非 0 = 未启用（走原逻辑）
harness_enabled() {
  local catalog
  catalog=$(harness_catalog) || return 1
  [ -f "$catalog" ]
}

# 定位 node 可执行文件；找到输出路径并返回 0，找不到返回非 0
harness_node() { command -v node 2>/dev/null; }

# node 是否可用：0 = 可跑 harness，非 0 = 降级信号（调用方可见跳过、非假绿）
harness_node_ok() { harness_node >/dev/null 2>&1; }

# 跑 harness 子命令（透传 argv）；调用方须先 harness_node_ok 确认 node 在，否则本调用返回 node 的非 0 退出码
harness_run() { node "$CLAUDE_PROJECT_DIR/.claude/harness/harness.mjs" "$@"; }

# 退出码是否在契约内（首参 rc，其余为该子命令的契约码）：0 = 契约内，非 0 = 契约外。
# 契约外 = 引擎自己崩了（缺 lib/ / node 出岔 / 内部异常），不是闸给出的结论——闸据此把
# 「引擎跑不起来」和「回执不匹配 / 门真没过」分开说，两者该做的事完全不同。
# 契约表见 .claude/rules/harness-large-repo.md 退出码契约段。
harness_rc_in_contract() {
  local rc="$1" c found=1
  shift
  for c in "$@"; do
    if [ "$rc" = "$c" ]; then found=0; fi
  done
  return "$found"
}

# 引擎 stderr 的头几行（去空行、取前 3 行、拼成一行截到 400 字符）：引擎崩的时候那几行才是
# 有用信息，带进闸的诊断里；无内容时输出空串。
harness_err_head() {
  printf '%s' "${1:-}" | grep -v '^[[:space:]]*$' | head -3 | tr '\n' ' ' | cut -c1-400
}
