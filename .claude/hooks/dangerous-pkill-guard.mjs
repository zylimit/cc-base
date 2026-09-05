// PreToolUse(Bash)：拦截 pkill -f 宽泛匹配，防止误杀主 Agent 进程。
//
// 锚定命令起始/分隔符，只拦真实执行的 pkill -f，放过 echo/grep "pkill -f" 这类字符串场景。
// 正则带 m 标志：底本 grep 是逐行判定的，命令里换行后的第二条同样要被 ^ 锚到。
import { readStdinJson, say, runFailOpen } from './lib/io.mjs';
import { gateLog } from './lib/gatelog.mjs';

const PKILL_F = /(^|;|&&|\|\||`|\$\()\s*pkill\s+-f/m;

// fast-mode 总闸：本闸在 D 阶段吃 fast-mode（底本 .sh 与契约卡都是「开着就静默放行」）。
// 不走 gateMode 是因为 lib 的 FLOOR 已按 Phase A 的 profile.floor 预置（A 阶段本闸升为不吃
// fast-mode），D 阶段照那张表跑就等于提前改行为。换 tier.mjs 时把这里改回 gateMode 即完成切换。
async function fastActive() {
  try {
    const m = await import('./lib/fastmode.mjs');
    return m.fastModeActive();
  } catch (_e) {
    return false;
  }
}

runFailOpen(async () => {
  if (await fastActive()) return;

  const ev = readStdinJson();
  const cmd = ev ? String((ev.tool_input || {}).command || '') : '';
  if (!cmd) return;
  if (!PKILL_F.test(cmd)) return;

  // 先落拦停码再写诊断：写 stderr / 账本失败也不该把已经成立的拦停降级成放行
  process.exitCode = 2;
  say('⛔ [dangerous-pkill-guard] 检测到 pkill -f 宽泛匹配，已拦截。');
  say('宽泛 pkill -f 会误杀主 Agent 自身进程（shell wrapper 含相同关键词）。');
  say('正确做法：先用 ps/pgrep 拿精确 PID，再 kill <PID>。');
  gateLog('dangerous-pkill-guard', '拦截 pkill -f 宽泛匹配');
});
