// PreToolUse(Bash)：密钥读取/拷贝/外传闸——把「密钥隐私是安全护栏」做成机器拦截。
// 判据是「参数里有没有密钥路径」，不是「动词是不是读取器」：读取器那张表列不完（tac / paste /
//   jq -R / base64 / sort 都能把 .env 整份吐出来，换个形态就绕过），放行表列得完——所以判据翻过来，
//   任何动词只要参数里有一个密钥路径就拦，只对一张封闭的「只碰元数据、不读内容」表放行。
// 判定顺序：样例名剔除（.env.example/.sample/.template/.dist 属合法）→ wrapper 剥壳 →
//   按 shell 分隔符切成简单命令 → 逐条取动词与参数判。
// 另留两条整命令级规则（形态横跨简单命令，切开就看不见了）：
//   R3 环境变量外传：env/printenv/set 输出管进 curl/wget/nc
//   R3b 网络命令携带密钥文件：curl/wget/nc + 密钥文件名（-F f=@id_rsa 这类粘连形态切词看不出）
// 判据翻面之后又照出两处绕过（TODO #76 二轮 review）：一是动词位本身可以是命令替换——按 $( 与
//   反引号切段后密钥路径会自己坐到动词位上，动词位一向只用来查放行表、没人判它是不是密钥路径，
//   于是漏过去；契约补一句：简单命令的动词位本身就是密钥路径（或整段只剩这一个 token）同样算
//   命中。二是参数 token 带 glob 元字符（* ? [）时不能只按字面比对——.en* / .??v / .* 一律
//   放行、*.pem 却拦得住，命中全看模式串碰巧长得像不像路径；契约补一句：这类 token 当模式看，
//   去试一组列得完的典型密钥名（TYPICAL_SECRET_NAMES），模式命中就算命中。两条都仍是
//   命令行里**字面写出来**的东西，跟下面「代码里拼路径」那条边界不是一回事。
// 三轮 review 又照出 glob 判据本身的两个坑（TODO #76 三轮）：① 原实现用 new RegExp() 把用户写的
//   模式串直接编译成正则，字符类倒序范围（.env[z-a]）会让 RegExp 构造函数抛 SyntaxError，闸没接
//   住，异常冒到最外层 runFailOpen，把整条命令（连同后面真正的 .env）一起静默放行——异常穿透到
//   fail-open 正是这类安全闸最危险的失败模式，兄弟仓 ccb-base 同款「认不出就放行」的闸吃过这个亏
//   （AGY 载荷全放行）。② 拼出来的 [^/]*[^/]*… 形态在长输入上灾难性回溯，一条命令能把 PreToolUse
//   拖死几秒到几十秒。两条根子都是「拿正则引擎当 glob 匹配器用」，所以不再用 RegExp 做 glob：改成
//   线性时间的双指针通配匹配（globMatch，思路同经典 wildcard-matching 题解，* 靠记录回溯点而非枚
//   举展开，复杂度有界为「模式长度 × 候选名长度」，候选名清单里最长的也只有 16 字符，怎么拼都跑
//   不出灾难性回溯）。契约三条：字符类未闭合或范围倒序（[z-a] 这种 from > to）一律把 `[` 当字面
//   字符处理，不构造正则、永不抛异常；单个 token 判不出来就当它未命中、继续判后面的 token
//   （.env[z-a] 判不出不影响它后面那个真 .env 照样被拦）；模式串长度超过 512 不进 glob 分支，按
//   字面判据处理，防止病态输入拖慢 token 化本身。另外，没有任何字面字符的纯通配（*、**、?、*? 这
//   类只由通配符组成的模式）不算命中——它没有指向任何具体密钥名，`for f in *; do …; done` 是常见
//   shell 写法，拦了只会逼人绕开这道闸；`cat *` 读到当前目录里恰好有的密钥属于「目录内容」问题，
//   不归这道判据管，边界在这里声明清楚。
// 边界：只对命令行里**字面出现**的密钥路径负责。把路径在代码里拼出来的读法（chr() 拼、变量拼接、
//   $(printf …) 现生成）hook 层原理上拦不住——那一层的防线在人不在闸，别以为这里绿了就没漏。
// wrapper 剥壳：剥 sudo/nohup/nice/timeout/env 前缀与 bash -c 引号壳再判——套壳绕闸是已知逃逸
//   路径（借鉴 codex-base v3），剥出新形态就按新形态重切一遍。
// 本闸属安全护栏，是地板闸（profile.floor）：任何档位都放行不了（放水不放安全），所以这里根本不问档位。
// 输入解析不出命令时降级放行（与 dangerous-pkill-guard 同一取舍——无解析能力时不误伤正常命令）。
import { readStdinJson, say, runFailOpen } from './lib/io.mjs';
import { gateLog } from './lib/gatelog.mjs';

// 密钥文件名集合（.pem/.ppk 任意路径命中；.env 尾界防误伤 .env2/.envoy 之类）
const SECRET_NAMES = "\\.env(\\.[A-Za-z0-9_-]+)?|id_rsa[A-Za-z0-9_.-]*|id_ed25519[A-Za-z0-9_.-]*|\\S*\\.(pem|ppk)|credentials\\.json|\\.aws/credentials|\\.ssh/\\S+";
// 整命令级规则用：命中后以空白/引号/行尾收边
const SECRET_CORE = `(${SECRET_NAMES})([\\s"']|$)`;
// 单个 token 用：整段就是一个密钥路径，可带任意目录前缀与 ~（./config/.env.production、~/.aws/credentials）
const SECRET_PATH = new RegExp(`^([^\\s"']*/)?(${SECRET_NAMES})$`);
// glob 判据用：典型密钥名固定清单——像放行表一样列得完，不像「还有哪些命令能读文件」那张表。
// token 里带 * ? [ 时当模式看，用线性时间的 globMatch（见下）逐个试这份清单，match 到一个就算命中。
const TYPICAL_SECRET_NAMES = [
  '.env', '.env.local', 'id_rsa', 'id_ed25519', 'key.pem', 'key.ppk',
  'credentials.json', '.aws/credentials', '.ssh/id_rsa',
];
// 参数区前缀：动词后紧跟（空格即边界）或经任意参数后以空格/斜杠/引号/=/@ 为前界——两种都算命中
const ARGPFX = "\\s+([^|;&]*[\\s/\"'=@])?";
// 命令锚定（起始或 ; && || ` $( 之后）
const ANCHOR = '(^|;|&&|\\|\\||`|\\$\\()\\s*';

// 一律带 m：底本 grep 是逐行判定，命令换行后的第二条同样要被 ^ 锚到（少了它多行命令能绕过）。
const RULES = [
  { re: new RegExp(`${ANCHOR}(env|printenv|set)\\b[^|]*\\|\\s*(curl|wget|nc)\\b`, 'm'),
    reason: '检测到环境变量整包管道外传（env/printenv | curl/wget/nc）' },
  { re: new RegExp(`${ANCHOR}(curl|wget|nc)${ARGPFX}${SECRET_CORE}`, 'm'),
    reason: '检测到网络命令携带密钥文件（curl/wget/nc + 密钥文件名）' },
];

const ARG_REASON = '检测到命令参数是密钥文件路径（.env/id_rsa/*.pem/credentials），动词又不在只碰元数据的放行表里';

// 只碰元数据、不读内容的动词——放行表是封闭集合、列得完，这是判据翻面的前提。
// echo / printf 敢进来是因为它们从不打开路径：`echo $(tac .env)` 里真读密钥的那条由 $( 自己切出来受判。
// find 只列文件名、不读内容，敢进来同理；`find -exec cat {}` 本来就在「路径拼出来」那条免责
// 边界外（{} 是 find 求值时现生成的参数，不是命令行里字面写出来的密钥路径），加不加 find 都拦不住
// 那种写法，所以加它不新开口子。
const METADATA_VERBS = new Set([
  'ls', 'stat', 'test', '[', '[[', 'file', 'du', 'chmod', 'chown', 'chgrp',
  'rm', 'unlink', 'touch', 'mkdir', 'rmdir', 'cd', 'pushd', 'popd',
  'basename', 'dirname', 'realpath', 'readlink', 'which', 'echo', 'printf', 'find',
]);

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

// 按 shell 分隔符（; & | 换行 反引号 $( ) ）切成简单命令。全程带引号状态：引号里的分隔符不算
// 分隔符，`echo "cat .env"` 切不出第二条命令，照契约该放行。
function splitSimple(cmd) {
  const out = [];
  let cur = '';
  let q = null;
  for (let i = 0; i < cmd.length; i += 1) {
    const ch = cmd[i];
    if (q) {
      cur += ch;
      if (ch === q) q = null;
    } else if (ch === '"' || ch === "'") {
      q = ch;
      cur += ch;
    } else if (ch === '$' && cmd[i + 1] === '(') {
      out.push(cur); cur = ''; i += 1;
    } else if (/[;&|\n`()]/.test(ch)) {
      out.push(cur); cur = '';
    } else {
      cur += ch;
    }
  }
  out.push(cur);
  return out.map((s) => s.trim()).filter(Boolean);
}

// 按引号切词。引号原样留在 token 里：嵌套那一层后面还要看（解释器 -c 一族的密钥藏在里层引号）。
function splitTokens(s) {
  const out = [];
  let cur = '';
  let q = null;
  for (const ch of s) {
    if (q) {
      cur += ch;
      if (ch === q) q = null;
    } else if (ch === '"' || ch === "'") {
      q = ch;
      cur += ch;
    } else if (/\s/.test(ch)) {
      if (cur) out.push(cur);
      cur = '';
    } else {
      cur += ch;
    }
  }
  if (cur) out.push(cur);
  return out;
}

// glob 模式长度上限：超过这个长度不进 glob 分支，按字面判据处理——候选名清单里最长的都只有
// 16 字符，没有任何一条真实密钥路径需要写这么长的模式，超长多半是病态/恶意输入，直接跳过更安全。
const GLOB_PATTERN_MAX = 512;

/**
 * 解析 `[` 之后的一个字符类：start 指向 `[` 之后的第一个字符。
 * 支持 `!`/`^` 取反、单字符项与 `a-z` 范围项。解析不出合法字符类（未闭合、或范围倒序如
 * `z-a`）一律返回 null，交给调用方把 `[` 当字面字符处理——绝不构造正则、绝不抛异常。
 * @returns {{matcher: (ch: string) => boolean, next: number} | null}
 */
function parseCharClass(pattern, start) {
  let i = start;
  let negate = false;
  if (pattern[i] === '!' || pattern[i] === '^') { negate = true; i += 1; }
  const items = [];
  while (i < pattern.length && pattern[i] !== ']') {
    const ch = pattern[i];
    if (pattern[i + 1] === '-' && i + 2 < pattern.length && pattern[i + 2] !== ']') {
      const from = ch;
      const to = pattern[i + 2];
      if (from.charCodeAt(0) > to.charCodeAt(0)) return null; // 倒序范围，[ 当字面字符
      items.push({ from, to });
      i += 3;
    } else {
      items.push({ from: ch, to: ch });
      i += 1;
    }
  }
  if (i >= pattern.length) return null; // 未闭合
  const matcher = (c) => {
    const hit = items.some((it) => c >= it.from && c <= it.to);
    return negate ? !hit : hit;
  };
  return { matcher, next: i + 1 };
}

// 模式串切成 token 序列：字面字符 lit / 单字符通配 any（?）/ 任意片段 star（*）/ 字符类 class（[...]）。
// 字符类解析失败时把 [ 降级成 lit，紧跟其后的字符从下一轮重新切——不消耗、不报错、不猜。
function tokenizeGlob(pattern) {
  const tokens = [];
  let i = 0;
  while (i < pattern.length) {
    const ch = pattern[i];
    if (ch === '*') { tokens.push({ t: 'star' }); i += 1; }
    else if (ch === '?') { tokens.push({ t: 'any' }); i += 1; }
    else if (ch === '[') {
      const cls = parseCharClass(pattern, i + 1);
      if (cls) { tokens.push({ t: 'class', matcher: cls.matcher }); i = cls.next; }
      else { tokens.push({ t: 'lit', ch: '[' }); i += 1; }
    } else { tokens.push({ t: 'lit', ch }); i += 1; }
  }
  return tokens;
}

function tokenMatchesChar(tok, ch) {
  if (tok.t === 'lit') return tok.ch === ch;
  if (tok.t === 'any') return true;
  if (tok.t === 'class') return tok.matcher(ch);
  return false; // star 不在这里判，由 globMatch 单独处理
}

/**
 * 线性时间通配匹配：经典双指针算法（wildcard-matching 题解同款）—— `*` 只记录一个回溯点
 * （starTi/starSi），不枚举展开成多条正则分支，复杂度有界为 O(模式 token 数 × 候选名长度)，
 * 候选名最长 16 字符，无论模式多长都不会出现正则那种指数级回溯。
 */
function globMatch(tokens, text) {
  let ti = 0;
  let si = 0;
  let starTi = -1;
  let starSi = -1;
  const n = tokens.length;
  const m = text.length;
  while (si < m) {
    if (ti < n && tokens[ti].t === 'star') {
      starTi = ti; starSi = si; ti += 1;
    } else if (ti < n && tokenMatchesChar(tokens[ti], text[si])) {
      ti += 1; si += 1;
    } else if (starTi !== -1) {
      ti = starTi + 1; starSi += 1; si = starSi;
    } else {
      return false;
    }
  }
  while (ti < n && tokens[ti].t === 'star') ti += 1;
  return ti === n;
}

// token 含 glob 元字符时才当模式看，试 TYPICAL_SECRET_NAMES 那份列得完的清单——没有元字符的
// 普通字符串不进这条分支，交给上面的字面判据（SECRET_PATH）去管。两道防线都判不出来就是未命中，
// 从不抛异常：解析不出的字符类降级成字面字符、模式串超长直接跳过、纯通配（没有 lit/class token，
// 只有 star/any）不算命中——它没有指向任何具体密钥名（* 单独一个字符会命中放行表里的 ls/echo
// 这类命令，不该被这道判据拦，见文件头「纯通配」边界说明）。整模式匹配之外再补一道文件名部分
// 匹配：带目录前缀的模式（./config/.en*）整模式对不上任何典型名，字面判据 SECRET_PATH 本就带
// 前缀剥离能力，这里让通配判据补齐同样的口径（SE-26 字面已拦、SE-56b 通配翻面不许漏），否则同
// 一个路径换成 glob 写法就能绕过去。
function globHits(bare) {
  if (!/[*?[]/.test(bare)) return false;
  if (bare.length > GLOB_PATTERN_MAX) return false;
  const tokens = tokenizeGlob(bare);
  if (tokens.some((t) => t.t === 'lit' || t.t === 'class') &&
      TYPICAL_SECRET_NAMES.some((name) => globMatch(tokens, name))) return true;
  const slash = bare.lastIndexOf('/');
  if (slash === -1) return false;
  const filename = bare.slice(slash + 1);
  const fnTokens = tokenizeGlob(filename);
  if (!fnTokens.some((t) => t.t === 'lit' || t.t === 'class')) return false;
  return TYPICAL_SECRET_NAMES.some((name) => globMatch(fnTokens, name.slice(name.lastIndexOf('/') + 1)));
}

// 一个参数 token 算不算密钥路径：整体去引号后是（cat ".env"）；key=value 的右值是（dd if=.env）；
// 或 token 里还嵌着一层引号、被引的子串整个是（python3 -c "print(open('.env').read())"）；
// 或整体/右值/被引子串含 glob 元字符、展开后落得到典型密钥名上（tac .en*、cp id_rsa*）。
// 重定向符号不属于路径，先剥掉——`node app.js < .env` 里那个路径同样算参数。
function tokenHits(raw) {
  const t = raw.replace(/^<{1,3}/, '');
  const bare = t.replace(/["']/g, '');
  if (SECRET_PATH.test(bare) || globHits(bare)) return true;
  const eq = bare.indexOf('=');
  if (eq > 0) {
    const val = bare.slice(eq + 1);
    if (SECRET_PATH.test(val) || globHits(val)) return true;
  }
  const quoted = t.length >= 2 && (t[0] === '"' || t[0] === "'") && t[t.length - 1] === t[0];
  const inner = quoted ? t.slice(1, -1) : t;
  for (const m of inner.matchAll(/'([^']*)'|"([^"]*)"/g)) {
    const s = m[1] === undefined ? m[2] : m[1];
    if (SECRET_PATH.test(s) || globHits(s)) return true;
  }
  return false;
}

// 一条简单命令：动词 = 跳过前导 VAR=val 赋值后的第一个词（带路径的取文件名）。动词在放行表里
// 整条放过，否则任一 token 命中即拦——赋值本身也算参数，`X=.env tac y` 不该从赋值那一侧漏出去；
// 动词位自己也要判：命令替换切段后密钥路径会独占一段、自己坐到动词位上（$(which tac) .env
// 切完是 ".env" 单独一段，这段里唯一的 token 就在 vi 位），不判 vi 就是白留了这个绕过口子。
function checkSimple(seg) {
  const tokens = splitTokens(seg);
  let vi = 0;
  while (vi < tokens.length && /^[A-Za-z_][A-Za-z0-9_]*=/.test(tokens[vi])) vi += 1;
  if (vi >= tokens.length) return false;
  const verb = tokens[vi].replace(/["']/g, '').replace(/^.*\//, '');
  if (METADATA_VERBS.has(verb)) return false;
  return tokens.some((t) => tokenHits(t));
}

// 切分与剥壳互为下一轮的输入：`bash -c "tac .env; cat x"` 剥完壳里面还是一串带分隔符的命令，
// 剥出新形态就重切一遍（上限 3 层，免得畸形输入把递归拖垮）。
function scanSegments(cmd, depth) {
  for (const seg of splitSimple(cmd)) {
    const bare = stripWrappers(seg);
    const hit = (bare !== seg && depth < 3) ? scanSegments(bare, depth + 1) : checkSimple(bare);
    if (hit) return true;
  }
  return false;
}

/** 命中则返回理由，没命中返回 null。 */
function checkOne(cmd) {
  const c = stripExamples(cmd);
  for (const r of RULES) {
    if (r.re.test(c)) return r.reason;
  }
  return scanSegments(c, 0) ? ARG_REASON : null;
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
  say('- 只需确认存在/大小/权限 → ls / stat / test / chmod 这类只碰元数据的命令本闸不拦');
  say('- 确需操作密钥（轮换/迁移）→ 停下来向用户说明并由用户亲自执行');
  say('- 需要个别环境变量 → 按名取用（printf \'%s\' "$VAR_NAME"），不整包导出外传');
  gateLog('secret-exfil-guard', reason);
});
