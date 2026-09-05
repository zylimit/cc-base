// fastmode.mjs — fast-mode 总闸判定（各 hook 动态 import 后调 gateMode）。
// 开关文件 $CLAUDE_PROJECT_DIR/.claude/.fast-mode 内 expires_epoch=<unix秒> 行决定有效性：
// > now 才算开着；缺环境变量 / 缺文件 / 缺行 / 非数字 / 已过期一律按关着算（fail-closed，走严格逻辑）。
//
// 读之前先剥 \r：Windows 侧 fast-mode.ps1 写过 CRLF，行尾锚点不认 \r 会把该行读成「没这行」，
// 而引擎侧的 JS 把 \r 当行终止符照样读到——同一个开关一边判开一边判关，比两边都关更糟（#38）。
//
// gateMode 是给 hook 用的唯一入口（Phase A 会换成 tier.mjs 的同名函数，届时 hook 不用改）：
//   floor 里的闸不吃 fast-mode——安全护栏、发布闸、压缩后回注、通知，放水不放这些。
import fs from 'node:fs';
import path from 'node:path';

/** 永不被 fast-mode 静默的闸：安全护栏 / 发布授权 / 压缩后回注 / 可见性通知。 */
const FLOOR = new Set([
  'secret-exfil-guard',
  'dangerous-pkill-guard',
  'release-gate',
  'postcompact-reinject',
  'notify',
]);

/** 契约卡里以 decision:block 或 exit 2 表态的闸；其余是记账/提醒类。 */
const GUARDS = new Set([
  'dangerous-pkill-guard',
  'harness-async-verify',
  'no-direct-code-guard',
  'pre-commit-check',
  'precompact-gate',
  'release-gate',
  'secret-exfil-guard',
  'stop-gate',
  'three-file-sync-gate',
]);

/** 开关文件路径；缺 CLAUDE_PROJECT_DIR 返回 null。 */
export function fastModeFlagPath() {
  const root = process.env.CLAUDE_PROJECT_DIR;
  return root ? path.join(root, '.claude', '.fast-mode') : null;
}

/** fast-mode 是否生效。读不到 / 读不懂 / 已过期一律 false（严格模式）。 */
export function fastModeActive() {
  try {
    const flag = fastModeFlagPath();
    if (!flag) return false;
    let raw;
    try { raw = fs.readFileSync(flag, 'utf8'); } catch (_e) { return false; }
    const m = raw.replace(/\r/g, '').match(/^expires_epoch=(\d+)$/m);
    if (!m) return false;
    return Number(m[1]) * 1000 > Date.now();
  } catch (_e) {
    return false;
  }
}

/**
 * 某个闸此刻该怎么跑：'off' = 静默放行，'block' = 按拦停闸跑，'on' = 按记账/提醒跑。
 * 未登记的 id 按其种类的最严值跑，不会因为漏登记就静默。
 */
export function gateMode(id) {
  if (fastModeActive() && !FLOOR.has(id)) return 'off';
  return GUARDS.has(id) ? 'block' : 'on';
}
