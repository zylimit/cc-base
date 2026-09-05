// PreToolUse(Bash)：启动 dev server 前清掉常用端口占用进程，避免端口被旧进程占住起不来。
// if = Bash(pnpm dev*) 失效（harness 不稳）→ 脚本内自判：命令非 pnpm dev 直接放行。
// 平台分支是真差异，不是可省的：POSIX 侧 lsof + kill -9，Windows 侧 netstat -ano + taskkill /F。
// 无论清没清到东西都恒 exit 0、零输出——这是顺手清场，不是闸。
import { readStdinRaw, run, runFailOpen } from './lib/io.mjs';

const PORTS = [3000, 3001, 4173, 5173, 8080];

async function fastOff(id) {
  try {
    const m = await import('./lib/fastmode.mjs');
    return m.gateMode(id) === 'off';
  } catch (_e) {
    return false;
  }
}

/** 同步小睡：端口释放到内核回收有延迟，清完立刻起 dev server 照样撞占用。 */
function sleepMs(ms) {
  try { Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms); } catch (_e) { /* 等不了就直接走 */ }
}

function killPosix(port) {
  const r = run('lsof', ['-t', '-i', `:${port}`]);
  if (r.status !== 0) return;                       // lsof 不在或没人占这个端口
  for (const pid of r.stdout.split('\n').map((s) => s.trim()).filter((s) => /^[0-9]+$/.test(s))) {
    run('kill', ['-9', pid]);
  }
}

function killWindows(port, netstatOut) {
  // netstat 一行末尾是 PID；只认 LISTENING 那几行，别把 TIME_WAIT 的对端也算进来
  const re = new RegExp(`:${port}\\s+.*LISTENING`);
  for (const line of netstatOut.split(/\r?\n/)) {
    if (!re.test(line)) continue;
    const pid = line.trim().split(/\s+/).pop();
    if (/^[0-9]+$/.test(pid)) run('taskkill', ['/PID', pid, '/F']);
  }
}

runFailOpen(async () => {
  if (await fastOff('kill-dev-ports')) return;

  const raw = readStdinRaw();
  let cmd = raw;
  try {
    const ev = JSON.parse(raw);
    cmd = String((ev && ev.tool_input && ev.tool_input.command) || '');
  } catch (_e) {
    // 解析不出就拿原文做子串匹配（与 .sh 无 jq 时同一取舍：宁可多判一次，也不漏清端口）
  }
  if (!cmd || !/pnpm\s+dev/.test(cmd)) return;

  if (process.platform === 'win32') {
    const ns = run('netstat', ['-ano']);
    if (ns.status === 0) for (const port of PORTS) killWindows(port, ns.stdout);
  } else {
    for (const port of PORTS) killPosix(port);
  }
  sleepMs(1000);
});
