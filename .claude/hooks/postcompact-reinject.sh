#!/bin/bash
# PostCompact hook: 压缩后回注不变量——把「压缩会删掉治理约束」这件事自动补上。
# 压缩不是稀释约束，是主动删除：摘要器为任务连续性服务，二十轮没被引用过的铁律正是它最先丢的。
# 而摘要本身也不修正漂移——它把漂移原样带过去。所以这里不读摘要，改跑 harness invariants
# 从 CLAUDE.md / progress.md / 运行态重新派生「什么不能被交易掉 + 现在处在什么状态」，
# 经 additionalContext 注回当前轮。约 1200 字符预算：注回的东西太长，下一次压缩会把它一起吃掉。
# 与 precompact-gate 是压缩前后两端，不重复：那个在压缩前拦一次让人先固化，这个在压缩后补回来。
# 官方契约（code.claude.com/docs/en/hooks 核证）：
#   输入 compact_trigger / compaction_ratio / messages_before / messages_after 等字段；
#   输出支持顶层 additionalContext 与 systemMessage，PostCompact 无 decision control（拦不住，也不该拦）。
# 守卫（压缩已经发生了，拦也没用；但不许静默）：
#   - node 不在 / 引擎退出码不在 0|3 契约内 → 打可见的降级说明（systemMessage），退出 0 不阻断；
#   - 引擎输出解析不出来 → 同上，说清是哪一步没成，别让人以为不变量已经回来了。

# 消费 stdin（事件 JSON：compact_trigger / compaction_ratio / messages_before|after）
EVENT=$(cat 2>/dev/null || true)

ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
HARNESS="$ROOT/.claude/harness/harness.mjs"

# 降级说明用固定常量串输出——这条路径上 node 可能根本不在，没法拿它拼 JSON，
# 而含变量的手拼 JSON 一旦引号没转义就是坏 JSON（坏 JSON 会被记成 hook error，等于白注）。
degrade() {
  case "$1" in
    no-node)
      echo '{"systemMessage":"PostCompact: node not found on PATH, so the invariants could not be re-derived after this compaction. The non-negotiable rules and the live state were NOT re-injected -- run `node .claude/harness/harness.mjs invariants` yourself, or read .claude/CLAUDE.md and progress.md before acting on anything the summary implies."}' ;;
    no-harness)
      echo '{"systemMessage":"PostCompact: .claude/harness/harness.mjs is missing, so the invariants could not be re-derived after this compaction. The non-negotiable rules and the live state were NOT re-injected -- read .claude/CLAUDE.md and progress.md before acting on anything the summary implies."}' ;;
    *)
      echo '{"systemMessage":"PostCompact: the harness failed while re-deriving the invariants after this compaction (see the debug log for its exit code and stderr). The non-negotiable rules and the live state were NOT re-injected -- fix the engine, or read .claude/CLAUDE.md and progress.md before acting on anything the summary implies."}' ;;
  esac
  exit 0
}

command -v node >/dev/null 2>&1 || degrade no-node
[ -f "$HARNESS" ] || degrade no-harness

INV=$(node "$HARNESS" invariants 2>/dev/null)
RC=$?
# 契约：0 = 派生到了，3 = 源文件缺失但活跃状态仍然派生到了（两者都值得注回）。
# 其余退出码 = 引擎自己出岔，不是「没有不变量」这个结论。
if [ "$RC" != "0" ] && [ "$RC" != "3" ]; then degrade engine; fi
[ -n "$INV" ] || degrade engine

# JSON 由 node 拼（此路径上 node 必然在），输入经环境变量传递，避免任何转义陷阱。
OUT=$(HOOK_EVENT="$EVENT" HOOK_INV="$INV" node -e '
const parse = (s) => { try { return JSON.parse(s || ""); } catch (e) { return null; } };
const ev = parse(process.env.HOOK_EVENT) || {};
const inv = parse(process.env.HOOK_INV);
if (!inv || typeof inv.text !== "string") process.exit(9);
const bits = [];
if (typeof ev.compact_trigger === "string") bits.push("trigger=" + ev.compact_trigger);
if (typeof ev.compaction_ratio === "number") bits.push("compaction_ratio=" + ev.compaction_ratio);
if (typeof ev.messages_before === "number" && typeof ev.messages_after === "number") {
  bits.push("messages " + ev.messages_before + " -> " + ev.messages_after);
}
const what = bits.length ? "（" + bits.join("，") + "）" : "";
const head = "刚刚发生了一次上下文压缩" + what
  + "。压缩不是把约束稀释了，是把它们删了；"
  + "摘要也不修正漂移，只会把漂移原样带过去。"
  + "下面这份是刚从文件重新派生的，不是从摘要里回忆的"
  + "——按它校准，别按压缩后的印象走。\n\n";
const ratio = typeof ev.compaction_ratio === "number" ? " (compaction_ratio=" + ev.compaction_ratio + ")" : "";
process.stdout.write(JSON.stringify({
  systemMessage: "PostCompact: invariants re-derived from files and re-injected" + ratio + ".",
  additionalContext: head + inv.text,
}) + "\n");
')
JRC=$?
if [ "$JRC" != "0" ] || [ -z "$OUT" ]; then degrade engine; fi
printf '%s\n' "$OUT"
exit 0
