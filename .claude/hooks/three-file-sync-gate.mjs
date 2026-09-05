// Stop hook: 三文件同步铁律恢复侧强制闸——只认 git 工作树实际未提交改动（弃用裸 mtime
//   比较，mtime 在 checkout 1ms 先后下会假阳性）。
// C1：未提交改动里有代码/家底文件（.sh/.ps1/.ts/.tsx/.js/.jsx/.py/.css/.go/.rs，以及 .claude/
//     下的家底 CLAUDE.md/agents/skills/settings.json 等；排除 .claude/evidence/node_modules/out/
//     dist）且 progress.md 不在改动集 → 拦停提醒同步。
// C2：改动集含 Product-Spec.md 但不含 Product-Spec-CHANGELOG.md（或反之）→ 需求变更漏记。
//     只校验存在的文件——Spec/CHANGELOG 任一不存在则不强造、不拦停（框架本体可无 Spec）。
// 干净树 / 改动已含 progress 或两份成对 / 非 git 仓 / 无 progress.md → 优雅放行。
// 项目根解析：CLAUDE_PROJECT_DIR 优先，缺失回退 git root，再回退 pwd。
// 子目录场景：项目只是父仓子目录时（show-prefix 非空），status 加 -- . 限定项目子树，
//   记录路径先剥 show-prefix 前缀再分类，剥不掉的跳过；项目即仓根时前缀为空、行为不变。
// fail-closed：闸自身出错（含 git status 跑不成）绝不静默放行，一律拦停——树没被看过就不能
//   当成「树是干净的」。不读 stdin：判定只来自工作树，喂什么都不影响结论。
import fs from 'node:fs';
import path from 'node:path';
import { projectDir, git, emit, runFailClosed } from './lib/io.mjs';
import { gateLog } from './lib/gatelog.mjs';

// fast-mode 总闸：动态 import——库缺失时按严格跑（不崩、也不静默放行）
async function fastOff(id) {
  try {
    const m = await import('./lib/fastmode.mjs');
    return m.gateMode(id) === 'off';
  } catch (_e) {
    return false;
  }
}

runFailClosed(async () => {
  if (await fastOff('three-file-sync-gate')) return;

  const root = projectDir();
  if (!fs.existsSync(path.join(root, 'progress.md'))) return;

  // 非 git 仓 → 无工作树可判，优雅放行。
  if (git(['rev-parse', '--is-inside-work-tree'], { cwd: root }).status !== 0) return;

  // porcelain 路径恒相对仓根：项目是父仓子目录时带前缀（如 proj/progress.md），先取 show-prefix 备剥。
  const prefix = git(['rev-parse', '--show-prefix'], { cwd: root }).stdout.replace(/\r?\n$/, '');

  let codeDirty = false;
  let progDirty = false;
  let specDirty = false;
  let changelogDirty = false;
  let firstCode = '';

  // 把单条改动路径归类到三文档命中 / 代码改动标志。
  const classifyPath = (p) => {
    if (p === 'progress.md') progDirty = true;
    else if (p === 'Product-Spec.md') specDirty = true;
    else if (p === 'Product-Spec-CHANGELOG.md') changelogDirty = true;

    // evidence 账本是机器写的旁路记录，node_modules/out/dist 是产物，都不算「改了要记 progress」
    if (/(^|\/)(\.claude\/evidence|node_modules|out|dist)\//.test(p)) return;
    // .claude/ 下家底（CLAUDE.md / agents / skills / settings.json 等）改了也属「改了要记 progress」
    if (/\.(sh|ps1|ts|tsx|js|jsx|py|css|go|rs)$/.test(p) || /(^|\/)\.claude\//.test(p)) {
      codeDirty = true;
      if (!firstCode) firstCode = p;
    }
  };

  // 剥掉仓根到项目目录的前缀再喂 classifyPath；剥不掉前缀的路径（-- . 限定后理论上不该有）
  // 跳过不分类。项目即仓根时 prefix 为空，原样直通。
  const classifyRel = (p) => {
    let rel = p;
    if (prefix) {
      if (!rel.startsWith(prefix)) return;
      rel = rel.slice(prefix.length);
    }
    classifyPath(rel);
  };

  // --porcelain -z：NUL 分隔、路径不加引号，必须按 NUL 切不能按行读。
  // -- . 限定只看项目子树内改动（cwd 已定到项目目录），仓外无关改动不进改动集。
  // rename/copy 记录是两段：`XY <new-path>` NUL `<old-path>` NUL（旧路径裸路径无前缀），
  // 故 X/Y 命中 R/C 时要再读一段裸 old-path，new/old 都计入改动集。
  const st = git(['status', '--porcelain', '-z', '--', '.'], { cwd: root });
  if (st.status !== 0) {
    // git 自己跑不成（索引损坏 / git 不在）= 工作树压根没被看过，放行就是把「没看」当成「干净」
    const head = String(st.stderr || '').split(/\r?\n/).filter((l) => l.trim() !== '').slice(0, 2).join(' ').slice(0, 300);
    throw new Error(`git status --porcelain -z 以 ${st.status} 退出：${head || '（无 stderr）'}`);
  }
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

  const reasons = [];

  if (codeDirty && !progDirty) {
    reasons.push(`三文件同步铁律：检测到未提交的代码/家底改动（如 ${firstCode}）但 progress.md 未同步。请把本轮的决策/完成事项/进度/新任务即时写入 progress.md（doc 类主 Agent 直接写），保证随时可 Clear→recap 完整恢复，然后重试停止。`);
  }

  // 成对校验只在两份都存在时进行，缺一不强造、不拦停。
  if (fs.existsSync(path.join(root, 'Product-Spec.md')) && fs.existsSync(path.join(root, 'Product-Spec-CHANGELOG.md'))) {
    if (specDirty && !changelogDirty) {
      reasons.push('Product-Spec.md 有未提交改动但 Product-Spec-CHANGELOG.md 未同步，需求变更可能漏记 CHANGELOG。请在 Product-Spec-CHANGELOG.md 补本次需求变更记录后重试停止。');
    }
    if (changelogDirty && !specDirty) {
      reasons.push('Product-Spec-CHANGELOG.md 有未提交改动但 Product-Spec.md 未同步，需求变更须成对更新两份文件。请同步 Product-Spec.md 后重试停止。');
    }
  }

  if (reasons.length === 0) return;

  const reason = reasons.join(' ');
  gateLog('three-file-sync-gate', reason);
  emit({ decision: 'block', reason });
}, 'three-file-sync-gate 自检失败，fail-closed 拦停——请修复闸后重试停止。');
