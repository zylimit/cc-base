// PreToolUse(Bash)：TDD 闸门。
// 档位（profile.json）：fast=off 静默；standard=advise 只提醒（exit 0，历史行为）；strict=block 真拦（exit 2）。
// 检测是否在没有 .red-verified / .tdd-exempt 的情况下派 implementer 写代码。
import fs from 'node:fs';
import path from 'node:path';
import { readStdinJson, git, say, gateModeOf, runFailOpen } from './lib/io.mjs';
import { gateLog } from './lib/gatelog.mjs';

runFailOpen(async () => {
  const mode = await gateModeOf('tdd-gate');
  if (mode === 'off') return;

  const ev = readStdinJson();
  const cmd = ev ? String((ev.tool_input || {}).command || '') : '';
  if (!cmd) return;

  const top = git(['rev-parse', '--show-toplevel']);
  const projectRoot = (top.status === 0 && top.stdout.trim()) ? top.stdout.trim() : process.cwd();

  // 只对看起来是在启动 implementer 的命令触发
  if (!/(implementer|dev-builder|GREEN|编码实现)/i.test(cmd)) return;

  if (fs.existsSync(path.join(projectRoot, '.claude', '.red-verified'))
      || fs.existsSync(path.join(projectRoot, '.claude', '.tdd-exempt'))) return;

  say('TDD 闸门：派 implementer 做 GREEN 实现前须先完成 RED。');
  say('高价值逻辑（契约/解析器/状态机/去重/schema 校验/驱动适配层等）：先派 tester 出失败测试 → 验红 → touch .claude/.red-verified，再派 implementer 写最简实现到绿。');
  say('若本 Task 是 UI/样式/非 TDD 逻辑：touch .claude/.tdd-exempt 显式声明豁免。');

  // standard 档到此为止：建议性提示，不硬拦截。
  // strict 档人是审批者——没验红就不许派编码，同一段提醒后 exit 2 真拦。
  if (mode === 'block') {
    process.exitCode = 2;
    gateLog('tdd-gate', '未验红即派 implementer 写码，strict 档拦停');
  }
});
