// Stop hook: 三文件同步铁律恢复侧强制闸——只认 git 工作树实际未提交改动（弃用裸 mtime
//   比较，mtime 在 checkout 1ms 先后下会假阳性）。
// C1：未提交改动里有代码/家底文件（.sh/.ps1/.mjs/.cjs/.ts/.tsx/.js/.jsx/.py/.css/.go/.rs，以及 .claude/
//     下的家底 CLAUDE.md/agents/skills/settings.json 等；排除 .claude/evidence/node_modules/out/
//     dist）且 progress.md 不在改动集 → 拦停提醒同步。
// C2：改动集含 Product-Spec.md 但不含 Product-Spec-CHANGELOG.md（或反之）→ 需求变更漏记。
//     只校验存在的文件——Spec/CHANGELOG 任一不存在则不强造、不拦停（框架本体可无 Spec）。
// 干净树 / 改动已含 progress 或两份成对 / 非 git 仓 / 无 progress.md → 优雅放行。
// 项目根解析：CLAUDE_PROJECT_DIR 优先，缺失回退 git root，再回退 pwd。
// 子目录场景：项目只是父仓子目录时（show-prefix 非空），status 加 -- . 限定项目子树，
//   记录路径先剥 show-prefix 前缀再分类，剥不掉的跳过；项目即仓根时前缀为空、行为不变。
// 档位（profile.json）：off 静默放行；advise（fast 档）照判照记账但出 systemMessage 不 block；
//   block（standard/strict）走原逻辑。
// fail-closed：闸自身出错（含 git status 跑不成）绝不静默放行，一律拦停——树没被看过就不能
//   当成「树是干净的」。不读 stdin：判定只来自工作树，喂什么都不影响结论。
import fs from 'node:fs';
import path from 'node:path';
import { projectDir, git, porcelainZ, classifyChange, relToProject, emit, gateModeOf, runFailClosed } from './lib/io.mjs';
import { gateLog } from './lib/gatelog.mjs';

runFailClosed(async () => {
  const mode = await gateModeOf('three-file-sync-gate');
  if (mode === 'off') return;

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

  // 剥掉仓根到项目目录的前缀（剥不掉的跳过不分类，-- . 限定后理论上不该有），再把 kind
  // 映射回本闸的四个标志。前缀剥法与分类表都在 io.mjs，precompact-gate 用的是同一份。
  const take = (p) => {
    const rel = relToProject(p, prefix);
    if (rel === null) return;
    switch (classifyChange(rel)) {
      case 'progress': progDirty = true; break;
      case 'spec': specDirty = true; break;
      case 'changelog': changelogDirty = true; break;
      case 'code':
        codeDirty = true;
        if (!firstCode) firstCode = rel;
        break;
      default: break;
    }
  };

  // -z 记录解析（NUL 切、R/C 的 new/old 双记录）在 io.mjs。
  // -- . 限定只看项目子树内改动（cwd 已定到项目目录），仓外无关改动不进改动集。
  // -uall 不能省：未跟踪的新目录默认折叠成一条 `newmod/`，目录名匹配不上扩展名表，整个新模块就逃过了 C2。
  const st = porcelainZ(root, ['-uall', '--', '.']);
  if (st.status !== 0) {
    // git 自己跑不成（索引损坏 / git 不在）= 工作树压根没被看过，放行就是把「没看」当成「干净」
    const head = String(st.stderr || '').split(/\r?\n/).filter((l) => l.trim() !== '').slice(0, 2).join(' ').slice(0, 300);
    throw new Error(`git status --porcelain -z 以 ${st.status} 退出：${head || '（无 stderr）'}`);
  }
  for (const p of st.paths) take(p);

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
  // advise 档（fast）：同一段话照说、照记账，只是不拦——欠账得看得见
  if (mode === 'advise') {
    const msg = `[fast] ${reason}`;
    gateLog('three-file-sync-gate', msg);
    emit({ systemMessage: msg });
    return;
  }
  gateLog('three-file-sync-gate', reason);
  emit({ decision: 'block', reason });
}, 'three-file-sync-gate 自检失败，fail-closed 拦停——请修复闸后重试停止。');
