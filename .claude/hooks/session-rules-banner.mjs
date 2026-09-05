// SessionStart：输出 CC 框架核心铁律横幅（source=compact/resume 时静默）。
import path from 'node:path';
import fs from 'node:fs';
import { readStdinJson, out, runFailOpen } from './lib/io.mjs';

// fast-mode 判定走共享库，动态 import——库缺失时按未生效处理（不播报 ON，走「已过期」提示 + 正常横幅），
// 与本 hook 反向用法一致：其余 hook 静默，本横幅必须喊出来，缺库也不能因此崩掉开场。
async function fastActive() {
  try {
    const m = await import('./lib/fastmode.mjs');
    return m.fastModeActive();
  } catch (_e) {
    return false;
  }
}

const BANNER = [
  '🔒 CC框架核心铁律：',
  '1. 主 Agent 不亲自编码/审查/测试/部署——一律派 Sub-Agent（implementer / code-reviewer / tester / deployer）',
  '2. 交叉审查：implementer 写 → code-reviewer 审（用 fresh 实例，非同 session 自审）',
  '3. 验收以客观证据为准：跑命令核查，不只信 Sub-Agent 自述',
  '4. 存量资产保留复用：删/停/重写现有 hook/skill 须用户拍板',
  '5. 查证后再结论：结论前必须有证据（WebSearch / 命令输出 / 官方文档）',
  '6. 三文件同步：决策/约束/完成即时写 progress.md；需求变更写 Product-Spec + CHANGELOG',
].join('\n');

runFailOpen(async () => {
  const root = process.env.CLAUDE_PROJECT_DIR || '';

  // 上次 setup 挂在半路会留下 .claude/.runtime/install.marker——在半装的框架上开工全是坑，
  // 先把它顶到脸上（正常装完这文件不存在，不会天天吓人）。
  if (root && fs.existsSync(path.join(root, '.claude', '.runtime', 'install.marker'))) {
    out('⚠️ 上次安装未完成（.claude/.runtime/install.marker）：重跑 setup.sh 补装完再干活。');
  }

  // fast-mode 总闸播报版：防开关忘关；
  // 过期（expires_epoch 已过 / 缺行 / 非法）则提示已自动失效并继续正常横幅（严格模式已恢复）。
  if (root && fs.existsSync(path.join(root, '.claude', '.fast-mode'))) {
    if (await fastActive()) {
      out('‼️ FAST-MODE ON：全部门闸静默中（.claude/.fast-mode）。修完跑 bash .claude/scripts/fast-mode.sh off 恢复严格模式（Windows 纯 PowerShell 环境跑 pwsh .claude/scripts/fast-mode.ps1 off）。');
      return;
    }
    out('fast-mode 已过期自动失效（TTL 到期或开关文件格式非法），严格模式已恢复；如需继续请重新 fast-mode.sh on，不用就 off 清掉开关文件。');
  }

  // compact/resume 不重复输出
  const ev = readStdinJson();
  const source = ev ? String(ev.source || '') : '';
  if (source === 'compact' || source === 'resume') return;

  out(BANNER);
});
