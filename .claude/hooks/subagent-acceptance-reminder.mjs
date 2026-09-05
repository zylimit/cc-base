// SubagentStop（matcher: implementer|code-reviewer|tester|deployer）
// 执行类 Sub-Agent 返回时，注入提醒：按「验收以客观证据为准」铁律核验，勿信自报。
import path from 'node:path';
import fs from 'node:fs';
import { createHash } from 'node:crypto';
import { readStdinJson, readTextFile, emit, runFailOpen } from './lib/io.mjs';

// fast-mode 总闸：动态 import——库缺失时按严格跑（不崩、也不静默放行）
async function fastOff(id) {
  try {
    const m = await import('./lib/fastmode.mjs');
    return m.gateMode(id) === 'off';
  } catch (_e) {
    return false;
  }
}

runFailOpen(async () => {
  if (await fastOff('subagent-acceptance-reminder')) return;

  // 事件读不懂也照样提醒（退化成默认称呼）：漏掉一次验收提醒比多提醒一次贵
  const ev = readStdinJson();
  const role = ev ? String(ev.agent_type || ev.subagent_type || '') : '';
  const agent = role || '子 Agent';

  // 去重：同一子代理完成事件可能重复触发本 hook（如 stop 闸拦回子代理、其再停一次），反复提醒
  // 会淹没子代理终报。每个完成事件只提醒一次——有 agent_id 用之，否则取稳定字段哈希做键；
  // 已提醒键记 .claude/.subagent-reminded（保留最近 50 条，状态损坏/缺失只会多提醒一次，不阻断）。
  const root = process.env.CLAUDE_PROJECT_DIR;
  if (root && ev) {
    const key = ev.agent_id
      ? String(ev.agent_id)
      : createHash('sha256')
          .update(`${ev.session_id || ''}|${role}|${ev.transcript_path || ''}`)
          .digest('hex');
    const seen = path.join(root, '.claude', '.subagent-reminded');
    const prior = (readTextFile(seen).text || '').replace(/\r/g, '').split('\n');
    if (prior.includes(key)) return;
    try {
      fs.mkdirSync(path.dirname(seen), { recursive: true });
      fs.appendFileSync(seen, key + '\n');
      const all = (readTextFile(seen).text || '').replace(/\r/g, '').split('\n').filter((l) => l !== '');
      if (all.length > 50) fs.writeFileSync(seen, all.slice(-50).join('\n') + '\n');
    } catch (_e) {
      /* 去重表写不成只会多提醒一次，不阻断子代理 */
    }
  }

  const msg = `${agent} 已返回。按验收铁律：不以它的自报（完成/通过/空回复）为准，核客观证据——编码/修复→复核编译输出 + 对照 Spec 逐条；测试→复核测试运行器真实输出；部署→独立核查三件套。`;
  emit({ hookSpecificOutput: { hookEventName: 'SubagentStop', additionalContext: msg } });
});
