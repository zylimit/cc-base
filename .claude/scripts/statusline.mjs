// statusline.mjs — Claude Code 状态行（settings.json statusLine 注册，stdin 吃会话 JSON）。
// 把框架治理状态做成全程可见：session-rules-banner 只在开场播一次，本状态行常驻——
//   [模型] ctx NN% | $成本 | FAST-MODE 剩余h | 待审 N | harness ON
// 数据源：stdin JSON（model/context_window/cost/workspace）+ 项目运行态文件
// （.claude/.fast-mode expires_epoch / .claude/.needs-review / harness/module-catalog.json）。
// 不 import hooks/lib：状态行每次渲染都会跑，必须便宜、必须安静，也不该因为别处的模块出岔就刷屏；
//   任何异常一律降级输出静态标识 cc-base，绝不报错。
// 输出不带换行：宿主按整段文本渲染一行，多的换行会被当成第二行。
import fs from 'node:fs';
import path from 'node:path';

/** 状态行的兜底形态：什么都算不出来时也得给宿主一段稳定文本。 */
function fallback() {
  try { fs.writeSync(1, 'cc-base'); } catch (_e) { /* stdout 都没了就只能沉默 */ }
}

try {
  let d = {};
  try {
    const raw = process.stdin.isTTY ? '' : fs.readFileSync(0, 'utf8');
    const v = raw.trim() ? JSON.parse(raw) : null;
    if (v && typeof v === 'object' && !Array.isArray(v)) d = v;
  } catch (_e) {
    d = {};
  }

  const ws = d.workspace || {};
  const root = ws.project_dir || ws.current_dir || process.env.CLAUDE_PROJECT_DIR || process.cwd();

  const segs = [];

  const model = (d.model || {}).display_name;
  if (model) segs.push(`[${model}]`);

  const pct = (d.context_window || {}).used_percentage;
  if (typeof pct === 'number' && Number.isFinite(pct)) {
    const p = Math.trunc(pct);
    segs.push(p >= 80 ? `\u001b[31mctx ${p}%\u001b[0m` : `ctx ${p}%`);
  }

  const cost = (d.cost || {}).total_cost_usd;
  if (typeof cost === 'number' && Number.isFinite(cost) && cost > 0) segs.push(`$${cost.toFixed(2)}`);

  // fast-mode：expires_epoch 未过期才算开（与 lib fastmode 同口径），黄色醒目防忘关
  try {
    const raw = fs.readFileSync(path.join(root, '.claude', '.fast-mode'), 'utf8');
    for (const line of raw.split('\n')) {
      if (line.startsWith('expires_epoch=')) {
        const exp = Number.parseInt(line.slice('expires_epoch='.length).trim(), 10);
        const left = exp - Math.floor(Date.now() / 1000);
        if (Number.isFinite(exp) && left > 0) segs.push(`\u001b[33mFAST-MODE ${(left / 3600).toFixed(1)}h\u001b[0m`);
        break;
      }
    }
  } catch (_e) {
    /* 没开 fast-mode 是常态，不是错 */
  }

  // 待审欠账：去空行去 clean 后仍有条目即红色示数（与 stop-gate 同口径）
  try {
    const raw = fs.readFileSync(path.join(root, '.claude', '.needs-review'), 'utf8');
    const n = raw.split('\n').filter((l) => l.trim() !== '' && l.trim() !== 'clean').length;
    if (n > 0) segs.push(`\u001b[31m待审 ${n}\u001b[0m`);
  } catch (_e) {
    /* 清单不存在 = 没有欠账 */
  }

  // 大仓治理开关（catalog 存在即启用）
  if (fs.existsSync(path.join(root, '.claude', 'harness', 'module-catalog.json'))) {
    segs.push('\u001b[32mharness ON\u001b[0m');
  }

  fs.writeSync(1, segs.length ? segs.join(' | ') : 'cc-base');
} catch (_e) {
  fallback();
}
