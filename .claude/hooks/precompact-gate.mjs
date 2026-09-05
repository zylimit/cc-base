// PreCompact：压缩前守门——「session 内压缩丢决策」的可拦截化。
// 压缩会把对话正文换成摘要，未落盘的决策/待审状态最容易在这一步蒸发。本闸在压缩前检查：
//   C1：.needs-review 有待审文件（审查闭环没走完，压缩后欠账语境丢失）
//   C2：工作树有未提交代码/家底改动但 progress.md 不在改动集（决策还没写进项目记忆）
// 命中任一 → 拦一次压缩（decision:block），提示先 /record 固化 + 处理待审再压缩。
// 防砖设计（与 stop 闸相反，本闸倾向放行）：
//   - 同一 session 拦过一次后 10 分钟内不再拦（.precompact-block-epoch 记上次拦截时间）——
//     auto 压缩可能是上下文触顶的恢复动作，拦第二次只会让请求反复失败；
//   - 脚本自身出错 fail-open 放行（拦不住压缩顶多丢注记，拦死压缩会卡死整个会话）。
// 状态干净 / 非 git / 无 progress.md → 放行并清标记。
import fs from 'node:fs';
import path from 'node:path';
import { projectDir, readStdinRaw, readTextFile, git, emit, runFailOpen } from './lib/io.mjs';
import { gateLog } from './lib/gatelog.mjs';

const COOLDOWN_SECONDS = 600;

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
  if (await fastOff('precompact-gate')) return;

  // 消费 stdin（trigger/custom_instructions 本闸不区分，manual/auto 同一判定）
  readStdinRaw();

  const root = projectDir();
  const mark = path.join(root, '.claude', '.precompact-block-epoch');
  const now = Math.floor(Date.now() / 1000);

  // 10 分钟冷却窗：拦过一次就先放行，给「记录后重试」留通道，也防 auto 压缩反复失败
  const prior = readTextFile(mark);
  if (prior.text !== null) {
    const last = prior.text.replace(/\r/g, '').split('\n').find((l) => /^\d+$/.test(l));
    if (last && now - Number(last) < COOLDOWN_SECONDS) return;
  }

  let dirtyReason = '';

  // C1：待审清单未清（复用 stop-gate 的清单语义：去空行去 clean 后仍有条目）
  const state = readTextFile(path.join(root, '.claude', '.needs-review'));
  const pending = (state.text || '')
    .replace(/\r/g, '')
    .split('\n')
    .filter((l) => l.trim() !== '' && l !== 'clean');
  if (pending.length > 0) dirtyReason = `待审清单未清（${pending.length} 个文件待 code review）`;

  // C2：代码/家底脏而 progress.md 未同步（three-file-sync C1 的简化版，只判是否需要先记录）
  if (!dirtyReason && fs.existsSync(path.join(root, 'progress.md'))
      && git(['rev-parse', '--is-inside-work-tree'], { cwd: root }).status === 0) {
    const prefix = git(['rev-parse', '--show-prefix'], { cwd: root }).stdout.replace(/\n$/, '');
    let codeDirty = false;
    let progDirty = false;

    const classifyPath = (p) => {
      if (p === 'progress.md') progDirty = true;
      if (/(^|\/)(\.claude\/evidence|node_modules|out|dist)\//.test(p)) return;
      if (/\.(sh|ps1|ts|tsx|js|jsx|py|css|go|rs)$/.test(p)) { codeDirty = true; return; }
      if (/(^|\/)\.claude\//.test(p)) codeDirty = true;
    };
    const classifyRel = (p) => {
      let rel = p;
      if (prefix) {
        if (!rel.startsWith(prefix)) return;
        rel = rel.slice(prefix.length);
      }
      classifyPath(rel);
    };

    // -z 形态：每条记录 `XY <path>`，R/C 另跟一条旧路径记录——必须按 NUL 切，不能按行读
    const st = git(['status', '--porcelain', '-z', '--', '.'], { cwd: root });
    const recs = st.stdout.split('\0');
    for (let i = 0; i < recs.length; i++) {
      const rec = recs[i];
      if (!rec) continue;
      const status = rec.slice(0, 2);
      classifyRel(rec.slice(3));
      if (/^[RC]/.test(status) || /^.[RC]/.test(status)) {
        i += 1;
        if (recs[i]) classifyRel(recs[i]);
      }
    }
    if (codeDirty && !progDirty) {
      dirtyReason = '工作树有未提交代码/家底改动但 progress.md 未同步（本轮决策还没进项目记忆）';
    }
  }

  if (!dirtyReason) {
    fs.rmSync(mark, { force: true });
    return;
  }

  try { fs.mkdirSync(path.dirname(mark), { recursive: true }); fs.writeFileSync(mark, `${now}\n`); } catch (_e) { /* 冷却标记写不成只会多拦一次 */ }

  const reason = `压缩前守门：${dirtyReason}。压缩会把对话正文换成摘要，这些状态最容易随之蒸发——请先派 progress-recorder /record 固化决策/完成事项（待审项处理或显式记欠账），再重试压缩。本次拦截后 10 分钟内不会再拦。`;
  gateLog('precompact-gate', reason);
  emit({ decision: 'block', reason });
});
