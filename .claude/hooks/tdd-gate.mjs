// PreToolUse(Agent)：TDD 闸门。检测是否在没有 .red-verified / .tdd-exempt 的情况下派 implementer 写代码。
// 档位（profile.json）：fast=off 静默；standard=advise 只提醒（exit 0）；strict=block 真拦（exit 2）。
// 挂 Agent 不挂 Bash：派 Sub-Agent 走 Agent 工具，这件事永远不经过命令行——按命令文本匹配
// implementer / dev-builder 只会误伤 `cat …implementer.md` 这类读文件的命令（账本里 19 次 strict
// 拦停按构造全是这么来的），还顺带教会模型换个写法绕开闸。
import fs from 'node:fs';
import path from 'node:path';
import { readStdinJson, git, say, errText, gateModeOf, runFailOpen } from './lib/io.mjs';
import { gateLog } from './lib/gatelog.mjs';

// 标记的保质期。验红验的是「这一轮改动」，不是一劳永逸：本仓一枚 9 月 11 日留下的空
// .red-verified 让闸静默放行了四天——过期标记比没有标记更坏，它看着像验过。
const MARK_TTL_MS = 2 * 3600 * 1000;

/** 标记还算不算数：不存在 / 过期都算没有；过期的当场删掉，不留给下一次。 */
function markLive(file) {
  let st;
  try { st = fs.statSync(file); } catch (_e) { return false; }
  if (Date.now() - st.mtimeMs <= MARK_TTL_MS) return true;
  // 判决已经定了（过期 = 没有），删不掉也不翻案，但得留一行看得见的诊断
  try { fs.rmSync(file, { force: true }); } catch (e) { say(`[tdd-gate] 过期标记删不掉，仍按无标记算：${errText(e)}`); }
  return false;
}

runFailOpen(async () => {
  const mode = await gateModeOf('tdd-gate');
  if (mode === 'off') return;

  const ev = readStdinJson();
  const input = ev ? (ev.tool_input || {}) : {};
  if (String(input.subagent_type || '') !== 'implementer') return;

  const top = git(['rev-parse', '--show-toplevel']);
  const projectRoot = (top.status === 0 && top.stdout.trim()) ? top.stdout.trim() : process.cwd();
  const claudeDir = path.join(projectRoot, '.claude');

  if (markLive(path.join(claudeDir, '.red-verified'))
      || markLive(path.join(claudeDir, '.tdd-exempt'))) return;

  // 先落拦停码再写诊断：写 stderr / 账本失败也不该把已经成立的拦停降级成放行
  // standard 档到此为止：建议性提示，不硬拦截。
  // strict 档人是审批者——没验红就不许派编码，同一段提醒后 exit 2 真拦。
  // 前缀与记账两档都有，写法同 stop-gate / three-file-sync-gate：advise 不记账，gate-audit 只读账本，
  // 就会把这道唯一守着 red-lock 的闸当成「从没拦过东西」的死闸删掉——提醒过多少次，账上得看得见。
  const block = mode === 'block';
  if (block) process.exitCode = 2;
  say(`${block ? '[block] ' : '[advise] '}TDD 闸门：派 implementer 做 GREEN 实现前须先完成 RED。`);
  say('高价值逻辑（契约/解析器/状态机/去重/schema 校验/驱动适配层等）：先派 tester 出失败测试 → 验红 → touch .claude/.red-verified，再派 implementer 写最简实现到绿。');
  say('若本 Task 是 UI/样式/非 TDD 逻辑：touch .claude/.tdd-exempt 显式声明豁免。');
  gateLog('tdd-gate', block
    ? '未验红即派 implementer 写码，strict 档拦停'
    : '[advise] 未验红即派 implementer，standard 档只提醒');
});
