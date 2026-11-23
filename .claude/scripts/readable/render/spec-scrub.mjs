// spec-scrub.mjs —— 需求规格页面上不带出去的东西（契约 docs/readable-spec/phase2-spec-contract.md C 节「不带出去的东西」）。
// 隐去的规则只有一份，在 ../sensitive.mjs，与第一期同一份；这里只管哪些字过它、换掉的记在来源的第几行，给 spec/index.html 顶上列出来。
// 过的：每块的文字（表格行按格）、锚点（锚点里有章节路径，标题里的字会带进 data-anchor）、来源文件名。
// 出一份换过的副本给各页用，传进来的模型不动——核对器要拿同一份模型在内存里重出一遍来比。
// 落盘前的兜底（check.mjs 的 leaks）照旧扫每一页：这里漏了哪一处，那里拦下并点名那一页。
import { redact } from '../sensitive.mjs';

// 一块里换了几处、各在哪一行：按行各过一遍，加起来与整块过一遍的处数相同就按行记；
// 不同（一处口令的写法跨了行）就整块记在起始行，处数以整块为准。围栏的文字从起始行的下一行开始。
function perLine(b, total, add) {
  const first = b.kind === 'fence' ? b.line + 1 : b.line, per = b.text.split('\n').map((l) => redact(l).hits);
  if (per.reduce((s, n) => s + n, 0) === total) per.forEach((n, k) => add(first + k, n));
  else add(b.line, total);
}

export function scrubSpec(spec) {
  const hits = [];
  const blocks = spec.blocks.map((b) => {
    const add = (line, n) => { if (n) hits.push({ line, n, block: b.n }); };
    const anchor = redact(b.anchor).text;
    if (b.kind === 'table') {
      const cells = b.cells.map((c) => redact(c));
      add(b.line, cells.reduce((s, c) => s + c.hits, 0));
      const shown = cells.map((c) => c.text);
      return { ...b, anchor, cells: shown, text: shown.join(' | ') };
    }
    const r = redact(b.text);
    if (r.hits) perLine(b, r.hits, add);
    return { ...b, anchor, text: r.text };
  });
  return { ...spec, file: redact(spec.file).text, blocks, hits };
}
