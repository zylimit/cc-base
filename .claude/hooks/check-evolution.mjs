// SessionStart：检查 .claude/feedback/FEEDBACK-INDEX.md 还有多少条待处理 feedback，
// 有就提醒派 evolution-runner。裸 stdout 文本（SessionStart 的输出直接进 context）。
// 待处理 = 未带「✅[已毕业]」前缀的条目（行首 "- ["）；总数 = 含已毕业一并计数。
import path from 'node:path';
import { projectDir, readTextFile, out, fastOff, runFailOpen } from './lib/io.mjs';

runFailOpen(async () => {
  if (await fastOff('check-evolution')) return;

  const index = path.join(projectDir(), '.claude', 'feedback', 'FEEDBACK-INDEX.md');
  const r = readTextFile(index);
  if (r.text === null) return;

  const lines = r.text.replace(/\r/g, '').split('\n');
  const pending = lines.filter((l) => l.startsWith('- [')).length;
  const total = lines.filter((l) => /^- (✅\[已毕业\] )?\[/.test(l)).length;

  if (pending > 0) {
    out(`📋 项目有 ${pending} 条待处理 feedback（共 ${total} 条）。建议派发 evolution-runner 检查是否有进化建议。`);
  }
});
