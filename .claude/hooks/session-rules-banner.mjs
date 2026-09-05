// SessionStart：输出 CC 框架核心铁律横幅（source=compact/resume 时静默）。
// 档位（profile.json）：三档全 on——它是唯一反向用法的闸，fast 档下别的闸都静默，就它必须喊。
import path from 'node:path';
import fs from 'node:fs';
import { readStdinJson, out, runFailOpen } from './lib/io.mjs';

// 判定走共享库，动态 import——库缺失时按「什么都没开」处理（不播报，只出正常横幅）：
// 与本 hook 反向用法一致，其余 hook 静默、本横幅必须喊出来，缺库也不能因此崩掉开场。

/** 当前档位；档位未启用（没装 profile.json）返回 null，由下面的旧开关分支接手。 */
async function tierState(root) {
  try {
    const m = await import('./lib/tier.mjs');
    if (!m.loadProfile(root).present) return null;
    return m.effectiveTier({ projectDir: root });
  } catch (_e) {
    return null;
  }
}

/** 旧开关是否还开着（只在档位未启用时问）。 */
async function legacyFastActive(root) {
  try {
    const m = await import('./lib/fastmode.mjs');
    return m.fastModeActive(root);
  } catch (_e) {
    return false;
  }
}

/** 距过期还剩几小时（一位小数）；没有过期时间返回 null。 */
function hoursLeft(epoch) {
  if (!Number.isFinite(Number(epoch))) return null;
  return Math.max(0, Math.round((Number(epoch) * 1000 - Date.now()) / 360000) / 10);
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

  // 档位播报：防 fast 忘关，也让自动升档说得出「为什么今天全是硬拦」。
  const tier = root ? await tierState(root) : null;
  if (tier) {
    if (tier.tier === 'fast') {
      const left = hoursLeft(tier.expiresEpoch);
      out(`‼️ tier: fast（${left === null ? '无过期时间' : `剩 ${left} h`}）：治理闸只提醒不拦，欠账照记（.claude/.runtime/tier.json）。修完跑 bash .claude/scripts/fast-mode.sh off 恢复严格模式（Windows 纯 PowerShell 环境跑 pwsh .claude/scripts/fast-mode.ps1 off）。`);
      return;
    }
    if (tier.source === 'raise') {
      const hits = (tier.raisedBy || []).slice(0, 3).join('、');
      out(`tier: ${tier.tier}（来源 raise：工作树改了 ${hits}${(tier.raisedBy || []).length > 3 ? ' 等' : ''}）——治理面改动自动升档，本轮闸按最严跑。`);
    }
  } else if (root && fs.existsSync(path.join(root, '.claude', '.fast-mode'))) {
    // 档位未启用（没装 profile.json）时的旧开关口径：开着就喊、过期就说已自动失效。
    if (await legacyFastActive(root)) {
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
