// fastmode.mjs — 旧开关 .claude/.fast-mode 的读法，Phase A 起只剩兼容用途。
//
// 档位（tier.mjs）接管之后，判「某个闸此刻怎么跑」的唯一入口是 tier.mjs 的 gateMode——
// 本文件不再有 gateMode，也不再被任何 hook 直接调；留下的只有旧开关本身怎么读：
//   装了 .claude/harness/profile.json = 档位启用，本文件的答案一概不参与判定（旧开关不再被读）；
//   没装 profile.json = 档位未启用，tier.mjs 退回 Phase D 语义时从这里取「快速模式开着没」。
// 文件名保留：升级老安装时它是「判定库还在不在」的那块石头——tier.mjs 静态 import 它，
//   缺了就整条判定链加载失败、调用方退到 standard 列走严格，而不是静默变成「不响」。
//
// 开关文件内 expires_epoch=<unix秒> 行决定有效性：> now 才算开着；缺环境变量 / 缺文件 /
// 缺行 / 非数字 / 已过期一律按关着算（fail-closed，走严格逻辑）。
// 读之前先剥 \r：Windows 侧 fast-mode.ps1 写过 CRLF，行尾锚点不认 \r 会把该行读成「没这行」，
// 而引擎侧的 JS 把 \r 当行终止符照样读到——同一个开关一边判开一边判关，比两边都关更糟（#38）。
import fs from 'node:fs';
import path from 'node:path';

/** 开关文件路径；不给 root 时取 CLAUDE_PROJECT_DIR，两者都没有返回 null。 */
export function fastModeFlagPath(root) {
  const base = root || process.env.CLAUDE_PROJECT_DIR;
  return base ? path.join(base, '.claude', '.fast-mode') : null;
}

/** 旧开关是否还开着。读不到 / 读不懂 / 已过期一律 false（严格模式）。 */
export function fastModeActive(root) {
  try {
    const flag = fastModeFlagPath(root);
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
