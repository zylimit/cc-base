// SubagentStop（matcher: implementer|code-reviewer|tester|deployer）
// 执行类 Sub-Agent 返回时，注入提醒：按「验收以客观证据为准」铁律核验，勿信自报。
import path from 'node:path';
import fs from 'node:fs';
import { createHash } from 'node:crypto';
import { readStdinJson, readTextFile, emit, fastOff, runFailOpen } from './lib/io.mjs';

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

  // 回执真报了领域发现才点一句：口径库是沟通 / 澄清过程的副产品，催不来——催出来的是凑数，凑的
  // 没有现场依据，进库即噪音，正是 domain-rulings 自己要防的东西。没这一栏、栏里写 None、回执
  // 压根读不到，一律静默：那是无从判断，不是漏填。栏名容忍加粗与列表符，正文算到下一个字段标签为止。
  const receipt = ev && typeof ev.last_assistant_message === 'string' ? ev.last_assistant_message : '';
  const label = /(?:^|\n)[\s>*+-]*\**\s*domain findings\s*\**\s*[:：]?/i.exec(receipt);
  const tail = label ? receipt.slice(label.index + label[0].length) : '';
  const found = tail.split(/\n[\s>*+-]*\**\s*(?:needs review by|evidence)\b/i)[0].replace(/[\s*`_>-]/g, '');
  const hasDomain = found !== '' && !/^(none|n\/a|无)[.。]?$/i.test(found);

  const msg = `${agent} 已返回。按验收铁律：不以它的自报（完成/通过/空回复）为准，核客观证据——编码/修复→复核编译输出 + 对照 Spec 逐条；测试→复核测试运行器真实输出；部署→独立核查三件套。${hasDomain ? '另：它报了领域发现，按 .claude/rules/domain-rulings.md 判一句够不够格收（依据齐不齐、离开本项目还成不成立），够格就问用户一句要不要收、收则派 domain-recorder。' : ''}`;
  emit({ hookSpecificOutput: { hookEventName: 'SubagentStop', additionalContext: msg } });
});
