// PreToolUse(Edit|Write)：检测主 Agent 是否直接写业务源码，是则警告并 exit 2 拦下。
import { readStdinJson, toPosix, say, fastOff, runFailOpen } from './lib/io.mjs';
import { gateLog } from './lib/gatelog.mjs';

// 框架文件放行（.claude/ / CLAUDE.md / Product-Spec / DEV-PLAN / progress / feedback / agents / skills / hooks / *.md）
const EXEMPT = /(\.claude\/|CLAUDE\.md|Product-Spec|DEV-PLAN|progress\.md|CHANGELOG|\/feedback\/|\/agents\/|\/skills\/|\/hooks\/|\.md$|\.json$|\.toml$|\.sh$|\.ps1$)/;
// 业务源码路径（src/ / app/ / lib/ / components/ 等），相对/绝对两种形态都拦
const SOURCE = /(^|\/)(src|app|lib|components|pages|api|server|client|utils|models|services)\//;

runFailOpen(async () => {
  if (await fastOff('no-direct-code-guard')) return;

  const ev = readStdinJson();
  const input = ev ? (ev.tool_input || {}) : {};
  // 反斜杠先归一：Windows 侧事件里是 src\app.ts，不归一这条闸在那边等于不存在
  const filePath = toPosix(String(input.file_path || input.path || ''));
  if (!filePath) return;

  if (EXEMPT.test(filePath)) return;
  if (!SOURCE.test(filePath)) return;

  // 先落拦停码再写诊断：写 stderr / 账本失败也不该把已经成立的拦停降级成放行
  process.exitCode = 2;
  say(`⚠️  [no-direct-code-guard] 主 Agent 不应直接写业务源码：${filePath}`);
  say('请派 implementer Sub-Agent 来编写，保持职责边界。');
  gateLog('no-direct-code-guard', `主 Agent 直接写业务源码被拦：${filePath}`);
});
