// io.mjs — hook 侧最小 I/O 契约（stdin / stdout / stderr / 退出码 / 外部命令 / 路径）。
//
// 故意不 import .claude/harness/lib/*：hook 与引擎是**进程级隔离**，引擎的 lib/ 被删时
// hook 必须还起得来、还能判出「引擎跑不成」——若直接 import 引擎代码，缺 lib/ 会让 hook
// 自己 ERR_MODULE_NOT_FOUND 起不来，「闸跑起来了但引擎坏了」与「闸自己没起来」这两件
// 完全不同的事就混成一件。core.mjs 里好用的东西只许在本目录抄精简版，不许 import。
//
// 输出一律 fs.writeSync：管道下 process.stdout.write 是异步的，写完立刻退出会丢内容。
// 退出码一律只设 process.exitCode 后自然退出，唯一例外是 runFailClosed 的 catch 分支
// （闸自身崩了必须当场把拦停 JSON 落出去，不能指望后续代码还有机会跑）。
import fs from 'node:fs';
import { spawnSync } from 'node:child_process';

/** 反斜杠→正斜杠。无条件替换，不按 path.sep 分支：Windows 形态的路径会经夹具/事件流到任何平台。 */
export function toPosix(p) {
  return String(p).replace(/\\/g, '/');
}

/**
 * 读文本文件：只有 ENOENT 算「不存在」，其余 I/O 错单独报。
 * 读不出来 ≠ 没有——两者的下一步动作相反，一个 catch 全吞掉就分不出来了。
 * @returns {{text:(string|null),absent:boolean,error:(Error|null)}}
 */
export function readTextFile(file) {
  try { return { text: fs.readFileSync(file, 'utf8'), absent: false, error: null }; } catch (e) {
    if (e && e.code === 'ENOENT') return { text: null, absent: true, error: null };
    return { text: null, absent: false, error: e };
  }
}

/** 读完 stdin 的原始文本；没有输入或读不了返回空串。 */
export function readStdinRaw() {
  try {
    if (process.stdin.isTTY) return '';
    return fs.readFileSync(0, 'utf8');
  } catch (_e) {
    return '';
  }
}

/** 读完 stdin 并解析：空输入 → {}；解析失败或不是对象 → null（不抛，由调用方决定降级形态）。 */
export function readStdinJson() {
  const raw = readStdinRaw();
  if (!raw.trim()) return {};
  try {
    const v = JSON.parse(raw);
    return (v && typeof v === 'object' && !Array.isArray(v)) ? v : null;
  } catch (_e) {
    return null;
  }
}

/** 项目根：CLAUDE_PROJECT_DIR → git 顶层 → cwd。 */
export function projectDir() {
  const env = process.env.CLAUDE_PROJECT_DIR;
  if (env) return env;
  const top = git(['rev-parse', '--show-toplevel']);
  if (top.status === 0 && top.stdout.trim()) return top.stdout.trim();
  return process.cwd();
}

/** 单行 JSON 到 stdout（hook 与宿主之间的机器契约，多行会被记成 hook error）。 */
export function emit(obj) {
  fs.writeSync(1, JSON.stringify(obj) + '\n');
}

/** 裸文本到 stdout（SessionStart 横幅这类直接进 context 的形态）。 */
export function out(text) {
  fs.writeSync(1, String(text) + '\n');
}

/** 一行诊断到 stderr。 */
export function say(text) {
  fs.writeSync(2, String(text) + '\n');
}

/** 拦停：靠 stdout 的 decision JSON，不靠退出码（Stop / PreCompact / UserPromptExpansion 的契约）。 */
export function block(reason) {
  emit({ decision: 'block', reason: String(reason) });
  process.exitCode = 0;
}

/** 跑外部命令：一律 shell:false + argv 数组，禁字符串拼命令。 */
export function run(cmd, argv, opts = {}) {
  const r = spawnSync(cmd, argv, { shell: false, encoding: 'utf8', ...opts });
  return {
    status: (r.status === null || r.status === undefined) ? -1 : r.status,
    stdout: r.stdout || '',
    stderr: r.stderr || '',
    error: r.error || null,
  };
}

/** git 子命令。git 不在 / 起不来时 status = -1（可判定的降级信号，不是「命令成功了」）。 */
export function git(args, opts = {}) {
  return run('git', args, opts);
}

/** 异常文本（只取首行，进 stderr 与账本的都是一行）。 */
export function errText(e) {
  return String((e && (e.stack || e.message)) || e || 'unknown').split('\n')[0];
}

/**
 * fail-closed 闸：主体任何异常都当场落一条拦停 JSON。
 * 闸自己崩了 = 它没能证明状态是干净的，此时放行就是假绿。
 */
export function runFailClosed(main, reason) {
  const fail = (e) => {
    try { emit({ decision: 'block', reason: `${reason}（闸自身异常：${errText(e)}）` }); } catch (_e) { /* stdout 都写不出去了，没有别的通道 */ }
    process.exit(0);
  };
  try {
    const r = main();
    if (r && typeof r.then === 'function') r.then(undefined, fail);
  } catch (e) {
    fail(e);
  }
}

/**
 * fail-open 闸/提醒类 hook：主体异常时留一行可见诊断后放行。
 * 留这一行是有意的——静默吞掉异常等于把「hook 坏了」伪装成「没什么可提醒的」。
 */
export function runFailOpen(main) {
  const fail = (e) => {
    try { say(`[hook] 内部异常，已放行：${errText(e)}`); } catch (_e) { /* 连 stderr 都没有就只能放行 */ }
    // 已经定下的拦停码不因为收尾时的异常被降级：判决先落码、再写诊断，写诊断失败不该翻案
    if (!process.exitCode) process.exitCode = 0;
  };
  try {
    const r = main();
    if (r && typeof r.then === 'function') r.then(undefined, fail);
  } catch (e) {
    fail(e);
  }
}
