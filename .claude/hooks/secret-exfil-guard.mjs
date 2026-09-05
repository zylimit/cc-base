// PreToolUse(Bash)：密钥读取/拷贝/外传闸——把「密钥隐私是安全护栏」做成机器拦截。
// 拦三类高置信度动作（锚定命令起始/分隔符，放过 echo/grep 字符串场景）：
//   R1 读密钥文件：cat/less/head/tail/strings/xxd/od 直读 .env 家族 / id_rsa / *.pem /
//      credentials 等（读 .env.example/.sample/.template/.dist 属合法，先剔除再判）
//   R2 拷贝/搬运密钥文件：cp/scp/rsync/mv 命中同一密钥文件集
//   R3 环境变量外传：env/printenv/set 输出管进 curl/wget/nc
// wrapper 剥壳：先剥 sudo/nohup/nice/timeout/env 前缀与 bash -c 引号壳再判——套壳绕闸是
// 已知逃逸路径（借鉴 codex-base v3），原文与剥壳后两个形态都要过检。
// 本闸属安全护栏，是地板闸（profile.floor）：任何档位都放行不了（放水不放安全），所以这里根本不问档位。
// 输入解析不出命令时降级放行（与 dangerous-pkill-guard 同一取舍——无解析能力时不误伤正常命令）。
import { readStdinJson, say, runFailOpen } from './lib/io.mjs';
import { gateLog } from './lib/gatelog.mjs';

// 密钥文件核心集（.pem/.ppk 任意路径命中；尾界防误伤 .env2/.envoy 之类）
const SECRET_CORE = "(\\.env(\\.[A-Za-z0-9_-]+)?|id_rsa[A-Za-z0-9_.-]*|id_ed25519[A-Za-z0-9_.-]*|\\S*\\.(pem|ppk)|credentials\\.json|\\.aws/credentials|\\.ssh/\\S+)([\\s\"']|$)";
// 参数区前缀：动词后紧跟（空格即边界）或经任意参数后以空格/斜杠/引号/= 为前界——两种都算命中
const ARGPFX = "\\s+([^|;&]*[\\s/\"'=@])?";
// 命令锚定（起始或 ; && || ` $( 之后）
const ANCHOR = '(^|;|&&|\\|\\||`|\\$\\()\\s*';

// 一律带 m：底本 grep 是逐行判定，命令换行后的第二条同样要被 ^ 锚到（少了它多行命令能绕过）。
const RULES = [
  { re: new RegExp(`${ANCHOR}(cat|less|more|head|tail|strings|xxd|od|bat|grep|rg|awk|sed)${ARGPFX}${SECRET_CORE}`, 'm'),
    reason: '检测到直读密钥文件（cat/head 等 + .env/id_rsa/*.pem/credentials）' },
  { re: new RegExp(`${ANCHOR}(cp|scp|rsync|mv)${ARGPFX}${SECRET_CORE}`, 'm'),
    reason: '检测到拷贝/搬运密钥文件（cp/scp/rsync/mv + 密钥文件名）' },
  { re: new RegExp(`${ANCHOR}(env|printenv|set)\\b[^|]*\\|\\s*(curl|wget|nc)\\b`, 'm'),
    reason: '检测到环境变量整包管道外传（env/printenv | curl/wget/nc）' },
  { re: new RegExp(`${ANCHOR}(curl|wget|nc)${ARGPFX}${SECRET_CORE}`, 'm'),
    reason: '检测到网络命令携带密钥文件（curl/wget/nc + 密钥文件名）' },
];

// 剔除合法样例文件名，再做密钥判定（.env.example 等不当密钥算）
function stripExamples(s) {
  return s.replace(/\.env\.(example|sample|template|dist)[A-Za-z0-9_.-]*/g, '');
}

// wrapper 剥壳：迭代剥 sudo/nohup/nice/timeout/env 前缀与 shell -c 引号壳（上限 5 层）
const WRAPPERS = [
  /^\s+/,
  /^sudo\s+/,
  /^nohup\s+/,
  /^nice(\s+-n\s*[0-9]+)?\s+/,
  /^timeout(\s+--?[A-Za-z-]+(\s+\S+)?)*\s+[0-9]+[smhd]?\s+/,
  /^env(\s+[A-Za-z_][A-Za-z0-9_]*=\S*)*\s+/,
  /^(ba|z|da)?sh\s+-l?c\s+["']?/,
  /["']$/,
];

function stripWrappers(cmd) {
  let c = cmd;
  let prev = null;
  for (let i = 0; i < 5 && c !== prev; i += 1) {
    prev = c;
    for (const re of WRAPPERS) c = c.replace(re, '');
  }
  return c;
}

/** 命中则返回理由，没命中返回 null。 */
function checkOne(cmd) {
  const c = stripExamples(cmd);
  for (const r of RULES) {
    if (r.re.test(c)) return r.reason;
  }
  return null;
}

runFailOpen(() => {
  const ev = readStdinJson();
  const cmd = ev ? String((ev.tool_input || {}).command || '') : '';
  if (!cmd) return;

  const stripped = stripWrappers(cmd);
  const reason = checkOne(cmd) || (stripped !== cmd ? checkOne(stripped) : null);
  if (!reason) return;

  // 先落拦停码再写诊断：写 stderr / 账本失败也不该把已经成立的拦停降级成放行
  process.exitCode = 2;
  say(`⛔ [secret-exfil-guard] ${reason}，已拦截。`);
  say('密钥/隐私是安全护栏，Fast Mode 也不豁免。正确做法：');
  say('- 需要了解配置结构 → 读 .env.example / 文档，不读真实密钥文件');
  say('- 确需操作密钥（轮换/迁移）→ 停下来向用户说明并由用户亲自执行');
  say('- 需要个别环境变量 → 按名取用（printf \'%s\' "$VAR_NAME"），不整包导出外传');
  gateLog('secret-exfil-guard', reason);
});
