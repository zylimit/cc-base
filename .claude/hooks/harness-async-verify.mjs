// PostToolUse(Edit|Write)：大仓定向门的后台早警——asyncRewake 形态（settings 里
// async+asyncRewake 注册，本脚本只管跑与退出码）。
// 与 pre-commit-check 的关系：commit 闸仍是同步硬门；本 hook 在两次 commit 之间的编辑期
// 后台跑同一套 harness verify（四态门+五性证据门），FAIL/BLOCKED 时 exit 2 唤醒主 Agent
// 读 stderr 摘要——失败早暴露（fail-visible），不挤占交互时延。
// 启用条件与降级：catalog 存在才跑（大仓治理默认关闭）；fast-mode 放行（质量闸）；
// 180 秒防抖（.async-verify-last 记上次运行 epoch，异步并发场景先写后跑防风暴）。
// 摘要预算：只回 gate + 失败/受阻 check 前 5 条 + 属性缺口计数，不贴全量 JSON。
import fs from 'node:fs';
import path from 'node:path';
import { readStdinRaw, readTextFile, say, errText } from './lib/io.mjs';
import { gateLog } from './lib/gatelog.mjs';
import { harnessEnabled, harnessRun, rcInContract, errHead } from './lib/harness.mjs';

const DEBOUNCE_SEC = 180;

async function fastOff(id) {
  try {
    const m = await import('./lib/fastmode.mjs');
    return m.gateMode(id) === 'off';
  } catch (_e) {
    return false;
  }
}

/** 上次跑完的 epoch；文件缺失 / 不是纯数字都当「没跑过」。 */
function lastRun(mark) {
  const state = readTextFile(mark);
  const m = (state.text || '').replace(/\r/g, '').match(/^([0-9]+)$/m);
  return m ? Number(m[1]) : null;
}

/** verify 的 stdout 压成人读得完的几行；解析不出就给一句「自己去跑全量」。 */
function summarize(stdout) {
  let d;
  try { d = JSON.parse(stdout); } catch (_e) { d = null; }
  if (!d || typeof d !== 'object') {
    return 'verify rc=2（FAIL/BLOCKED 或五性证据缺口）——跑 node .claude/harness/harness.mjs verify 看全量';
  }
  const lines = [`gate=${d.gate || d.state || 'FAIL'}`];
  if (d.emptyPlan) lines.push('空验证计划：受影响模块没有任何 check（配置缺口，不算绿）');
  const bad = (Array.isArray(d.checks) ? d.checks : []).filter((c) => c && (c.state === 'FAIL' || c.state === 'BLOCKED'));
  for (const c of bad.slice(0, 5)) {
    lines.push(`- ${c.module || '?'} [${c.state}] ${c.id} ${c.reason || `exit=${c.exit}`}`);
  }
  if (bad.length > 5) lines.push(`- …另有 ${bad.length - 5} 条`);
  const gaps = d.attributeGaps || [];
  if (gaps.length) lines.push(`五性证据缺口 ${gaps.length} 处（critical/high 属性缺认领 PASS）`);
  return lines.join('\n');
}

async function main() {
  if (await fastOff('harness-async-verify')) return;

  // 消费 stdin（file_path 不用——verify 自己从 git 工作树算 changed 集）
  readStdinRaw();

  if (!harnessEnabled()) return;

  const root = process.env.CLAUDE_PROJECT_DIR || process.cwd();
  const mark = path.join(root, '.claude', '.async-verify-last');
  const now = Math.floor(Date.now() / 1000);
  const last = lastRun(mark);
  if (last !== null && now - last < DEBOUNCE_SEC) return;
  // 先写后跑：异步并发下后来者要立刻看到「有人在跑」，写在跑完之后就挡不住风暴
  try { fs.writeFileSync(mark, `${now}\n`); } catch (_e) { /* 写不下防抖标记也照跑，最多多跑一次 */ }

  const r = harnessRun(['verify'], { cwd: root });

  // 契约外退出码（verify 契约只有 0/2/3）= 引擎自己崩了、门没跑成。早警不硬拦（commit 硬门仍是
  // pre-commit-check），但闸跑不起来这件事同样得说话——照唤醒形态发一条可见诊断，不静默 exit 0 吞掉。
  if (!rcInContract(r.status, 0, 2, 3)) {
    process.exitCode = 2;
    say(`[harness-async-verify] 编辑期后台质量门跑不起来：harness verify 以契约外退出码 ${r.status} 退出（契约只有 0/2/3）。`);
    say(errHead(r.stderr) || '（引擎无 stderr 输出）');
    say('这是引擎异常（如 .claude/harness/lib/ 缺失、node 出岔），不是门未过；commit 时 pre-commit-check 会硬拦，建议现在就修引擎。');
    gateLog('harness-async-verify', `后台 verify 以契约外退出码 ${r.status} 退出（引擎异常，早警）`);
    return;
  }
  if (r.status !== 2) return;

  process.exitCode = 2;
  say('[harness-async-verify] 编辑期后台质量门未过：');
  say(summarize(r.stdout));
  say('commit 前会被 pre-commit-check 硬拦，建议现在就修或派 bug-fixer。');
  gateLog('harness-async-verify', '后台 verify 未过（早警，非硬拦）');
}

// 闸自身崩了（stdin 读不了、防抖文件读写抛错、判定中途出岔）不许静默 exit 0——那等于把
// 「早警根本没跑」伪装成「跑过了、没问题」。本 hook 没有 decision 通道，fail-closed 在这里
// 的形态是唤醒：一行诊断 + exit 2，主 Agent 至少知道这轮没人验过。
main().catch((e) => {
  process.exitCode = 2;
  say(`[harness-async-verify] 早警自身异常，按唤醒处理（本轮未验）：${errText(e)}`);
});
