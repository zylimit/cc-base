// PreToolUse(Edit|Write)：检测主 Agent 是否直接写业务源码，是则警告并 exit 2 拦下。
// 档位（profile.json）：off 静默放行；advise（fast 档）只警告不拦（exit 0）；block 走原逻辑。
import { readStdinJson, toPosix, say, gateModeOf, runFailOpen } from './lib/io.mjs';
import { gateLog } from './lib/gatelog.mjs';

// 框架文件放行（.claude/ / CLAUDE.md / Product-Spec / DEV-PLAN / progress / feedback / agents / skills / hooks / *.md）
const EXEMPT = /(\.claude\/|CLAUDE\.md|Product-Spec|DEV-PLAN|progress\.md|CHANGELOG|\/feedback\/|\/agents\/|\/skills\/|\/hooks\/|\.md$|\.json$|\.toml$|\.sh$|\.ps1$)/;
// 业务源码路径（src/ / app/ / lib/ / components/ 等），相对/绝对两种形态都拦
const SOURCE = /(^|\/)(src|app|lib|components|pages|api|server|client|utils|models|services)\//;

runFailOpen(async () => {
  const mode = await gateModeOf('no-direct-code-guard');
  if (mode === 'off') return;

  const ev = readStdinJson();
  const input = ev ? (ev.tool_input || {}) : {};
  // 反斜杠先归一：Windows 侧事件里是 src\app.ts，不归一这条闸在那边等于不存在
  const filePath = toPosix(String(input.file_path || input.path || ''));
  if (!filePath) return;

  if (EXEMPT.test(filePath)) return;
  if (!SOURCE.test(filePath)) return;

  // 先落拦停码再写诊断：写 stderr / 账本失败也不该把已经成立的拦停降级成放行
  // advise 档（fast）只提醒不拦：话照说、账照记，退出码留 0
  if (mode !== 'advise') process.exitCode = 2;
  say(`⚠️  [no-direct-code-guard] 主 Agent 不应直接写业务源码：${filePath}`);
  say('请派 implementer Sub-Agent 来编写，保持职责边界。');
  gateLog('no-direct-code-guard', `${mode === 'advise' ? '[fast] ' : ''}主 Agent 直接写业务源码被拦：${filePath}`);
});
