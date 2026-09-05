// Stop hook: 有项目代码待 review 时阻止停止
// 状态文件 .needs-review（按文件登记，每行一个相对路径）
// 优先级反转（防 clean 与待审路径混存被误放行）：
//   - 去掉空行与 "clean" 行后，仍有文件 = 阻止并列出
//   - 否则（只剩 clean / 全空 / 不存在）= 放行并清理
// 连拦上限（防死锁）：.stop-gate-strikes（sig=/count= 两行自描述，损坏当无状态重建）记
//   同一待审清单被连拦的次数——子代理场景无法自行派 reviewer 满足闸条件，会被无限重验。
//   同一清单连拦 3 次后第 4 次放行并醒目提示欠账仍在；正常放行或清单变化即清零重计。
// 放行契约（向后兼容）：审查通过后 `echo clean > .claude/.needs-review` 即可。
// 删状态文件一律 rmSync(..., {force:true})：删不掉又被静默吞掉时 .stop-gate-strikes 会残留，
//   下一轮同一清单立刻撞上限提前放行——闸把自己关了（历史缺陷 81c63c9）。
// fail-closed：闸自身出错（含状态文件清理失败）绝不静默放行，一律拦停。不读 stdin。
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { projectDir, readTextFile, pendingReviewLines, emit, fastOff, runFailClosed } from './lib/io.mjs';
import { gateLog } from './lib/gatelog.mjs';
import { harnessEnabled, harnessRun, rcInContract, errHead } from './lib/harness.mjs';

/** 读连拦计数：只认与本次 sig 相同的记录，sig 一变即从 0 重计；文件损坏当无状态。 */
function readStrikes(file, sig) {
  const st = readTextFile(file);
  if (!st.text) return 0;
  const lines = st.text.replace(/\r/g, '').split('\n');
  const oldSig = (lines.find((l) => l.startsWith('sig=')) || '').slice(4);
  const oldN = (lines.find((l) => l.startsWith('count=')) || '').slice(6);
  if (oldSig !== sig) return 0;
  return /^\d+$/.test(oldN) ? Number(oldN) : 0;
}

function writeStrikes(file, sig, n) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `sig=${sig}\ncount=${n}\n`);
}

/** 拦停：账本 + decision JSON 一起走（gate-audit 靠账本统计哪些闸真拦下过东西）。 */
function blockWith(reason) {
  gateLog('stop-gate', reason);
  emit({ decision: 'block', reason });
}

/** 达连拦上限时的放行：不是「过了」，是欠账带着放行，必须让人看见。 */
function releaseWith(notice) {
  gateLog('stop-gate', notice);
  emit({ systemMessage: notice });
}

runFailClosed(async () => {
  if (await fastOff('stop-gate')) return;

  const root = projectDir();
  const stateFile = path.join(root, '.claude', '.needs-review');
  const strikeFile = path.join(root, '.claude', '.stop-gate-strikes');

  const state = readTextFile(stateFile);
  if (state.absent) { fs.rmSync(strikeFile, { force: true }); return; }
  // 读不出来 ≠ 没有：状态未知时放行就是拿「没看到欠账」当「没有欠账」，交给 fail-closed
  if (state.error) throw state.error;

  const files = pendingReviewLines(state.text);

  if (files.length === 0) {
    // 大仓回执网关（catalog 存在才启用；不启用时走原逻辑零行为变化）：清单已清空（口头释放）后，
    // 再校验当前工作树 diff 是否有已通过回执绑定——代码越过所有已审回执（STALE, rc=4）则强制重审，
    // 此时不清状态文件、保留 .needs-review 让下轮仍拦；rc=0/3 照原样清理放行。
    // 契约外退出码（receipt verify 契约只有 0/3/4）= 引擎自己崩了、闸压根没跑成，放行就是假绿：同样拦停、
    // 点名实际退出码、保留 .needs-review，并走同一套 .stop-gate-strikes 三振熔断（引擎长期崩不至于拦死人）。
    if (harnessEnabled()) {
      // stderr 收进变量、stdout 丢弃：引擎崩掉时那几行是唯一有用的线索，要带进诊断
      const rv = harnessRun(['receipt', 'verify'], { cwd: root });
      const rc = rv.status;
      if (rc === 4) {
        blockWith('代码在上次审查后又有改动，无匹配的已通过回执（diff 已越过所有已审回执）。请重新派 code-reviewer 审查当前改动并写回执后再停止。');
        return;
      }
      if (!rcInContract(rc, 0, 3)) {
        // 连拦计数复用同一状态文件，sig 按退出码记（码一变即清零重计），与待审清单那套互不串味
        const hsig = `harness-receipt-verify-rc${rc}`;
        const strikes = readStrikes(strikeFile, hsig);
        const head = errHead(rv.stderr) || '（引擎无 stderr 输出）';
        if (strikes >= 3) {
          fs.rmSync(strikeFile, { force: true });
          releaseWith(`stop-gate：harness receipt verify 连续 3 次以契约外退出码 ${rc} 退出（引擎异常，不是回执过期），达连拦上限本次放行——但回执绑定始终没被验过，欠账仍在，请尽快修引擎：node .claude/harness/harness.mjs receipt verify。引擎报错：${head}`);
          return;
        }
        writeStrikes(strikeFile, hsig, strikes + 1);
        blockWith(`stop-gate：harness receipt verify 以契约外退出码 ${rc} 退出（契约只有 0/3/4），回执闸没跑成——这是引擎异常（如 .claude/harness/lib/ 缺失、node 出岔），不是回执过期。跑 node .claude/harness/harness.mjs receipt verify 看真实报错，修好引擎再停止。引擎报错：${head}`);
        return;
      }
    }
    fs.rmSync(stateFile, { force: true });
    fs.rmSync(`${stateFile}.lock`, { force: true });
    fs.rmSync(strikeFile, { force: true });
    return;
  }

  const count = files.length;
  const inline = files.join('、');

  // 连拦计数：只对同一待审清单指纹累加，清单一变即清零重计（顺序无关，先排序再算）
  const sig = crypto.createHash('sha256').update([...files].sort().join('\n')).digest('hex');
  const strikes = readStrikes(strikeFile, sig);
  if (strikes >= 3) {
    fs.rmSync(strikeFile, { force: true });
    releaseWith(`stop-gate：同一待审清单连续拦截已达 3 次上限，本次放行——但待审清单未清空（${count} 个欠账仍在：${inline}），条件允许时务必尽快派 code-reviewer 审查。`);
    return;
  }
  writeStrikes(strikeFile, sig, strikes + 1);
  blockWith(`代码已修改但未 code review（${count} 个待审文件：${inline}）。请派发 code-reviewer sub-agent 两阶段审查；通过后执行 echo clean > .claude/.needs-review 放行。`);
}, 'stop-gate 自检失败，fail-closed 拦停——请修复闸/状态文件后重试停止。');
