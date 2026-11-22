// check-read.mjs —— 核对器自带的最小页面读取器（契约 docs/readable-spec/phase1-db-contract.md H 节第 2、4 项；架构稿 §3 禁边）。
// 为什么自带：第 2 项要把磁盘上页面显示的东西读回来、与重新取的事实比；借出页面的代码去读，那段代码吞了一个列、串了一行，
// 读回来的会跟着错，两边错得一样看不出来。所以这里不 import render/ 下的任何东西，也不是完整的 HTML 解析器：
// 只认标签、属性与文字，够读 C 节「机器读得回来」的 data-anchor / data-k / data-note / data-state，以及第 4 项要的站内链接。
// 读不懂的写法不抛错，照字面当文字留着——宁可让比对报一条对不上，也不让一页读不出来就整次失败。

const VOID = new Set(['area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link', 'meta', 'source', 'track', 'wbr']);
const RAW = new Set(['script', 'style']);
// 显示时自成一块的元素：读文字时前后补一个空白，免得两段贴成一个词；行内的（code、span、a、strong、wbr）不补。
const BLOCK = new Set(['address', 'article', 'blockquote', 'br', 'caption', 'dd', 'details', 'div', 'dl', 'dt', 'figure', 'footer', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6',
  'header', 'hr', 'li', 'main', 'nav', 'ol', 'p', 'pre', 'section', 'summary', 'table', 'tbody', 'td', 'tfoot', 'th', 'thead', 'tr', 'ul']);
const NAMED = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ' };

// 字符引用：五个常用的名字、十进制与十六进制码点；不认识的照字面留着。
export function decode(s) {
  return s.replace(/&(#[xX][0-9a-fA-F]+|#\d+|[A-Za-z]+);/g, (m, e) => {
    if (e[0] === '#') {
      const n = e[1] === 'x' || e[1] === 'X' ? parseInt(e.slice(2), 16) : parseInt(e.slice(1), 10);
      return n <= 0x10ffff ? String.fromCodePoint(n) : m;
    }
    const k = e.toLowerCase();
    return Object.hasOwn(NAMED, k) ? NAMED[k] : m;
  });
}

function attrsOf(raw) {
  const out = Object.create(null);
  for (const m of raw.matchAll(/([^\s=/>"']+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+)))?/g)) {
    const k = m[1].toLowerCase();
    if (!Object.hasOwn(out, k)) out[k] = decode(m[2] ?? m[3] ?? m[4] ?? '');
  }
  return out;
}

// 读成一棵树：元素 {tag, attrs, children}，文字 {text}（字符引用已解开）。注释与 <!doctype> 丢掉；
// <style> / <script> 的内容不进树；关闭标签往上找同名的开着的元素，找不到就不理（手改坏的页面也读得下去）。
export function parse(src) {
  const root = { tag: '#root', attrs: Object.create(null), children: [] };
  const stack = [root];
  const top = () => stack[stack.length - 1];
  const text = (s) => { if (s) top().children.push({ text: decode(s) }); };
  const token = /<!--[\s\S]*?(?:-->|$)|<![^>]*>|<\/([A-Za-z][\w:-]*)[^>]*>|<([A-Za-z][\w:-]*)((?:[^>"']|"[^"]*"|'[^']*')*)>/g;
  let last = 0, m;
  while ((m = token.exec(src))) {
    text(src.slice(last, m.index));
    last = token.lastIndex;
    if (m[1]) {
      const i = stack.map((n) => n.tag).lastIndexOf(m[1].toLowerCase());
      if (i > 0) stack.length = i;
    } else if (m[2]) {
      const tag = m[2].toLowerCase(), raw = m[3] || '', selfClose = /\/\s*$/.test(raw);
      const node = { tag, attrs: attrsOf(raw.replace(/\/\s*$/, '')), children: [] };
      top().children.push(node);
      if (RAW.has(tag)) {
        const end = new RegExp(`</${tag}\\s*>`, 'gi');
        end.lastIndex = last;
        last = end.exec(src) ? end.lastIndex : src.length;
        token.lastIndex = last;
      } else if (!VOID.has(tag) && !selfClose) stack.push(node);
    }
  }
  text(src.slice(last));
  return root;
}

// 子孙里满足 pred 的元素，按文档先后。
export function findAll(node, pred, out = []) {
  for (const c of node.children || []) {
    if (!c.tag) continue;
    if (pred(c)) out.push(c);
    findAll(c, pred, out);
  }
  return out;
}

export const hasClass = (n, c) => String(n.attrs.class || '').split(/\s+/).includes(c);
// 空白归一：连续空白压成一个空格、去掉两头——页面显示时浏览器也是这样压的。
export const squash = (s) => String(s ?? '').replace(/\s+/g, ' ').trim();

// 显示出来的纯文字：去掉标签、块与块之间隔一个空白、空白归一。skip 命中的元素连同里面的文字都不算。
export function textOf(node, skip = () => false) {
  const parts = [];
  const walk = (n) => {
    for (const c of n.children) {
      if (!c.tag) { parts.push(c.text); continue; }
      if (RAW.has(c.tag) || skip(c)) continue;
      const b = BLOCK.has(c.tag);
      if (b) parts.push(' ');
      walk(c);
      if (b) parts.push(' ');
    }
  };
  walk(node);
  return squash(parts.join(''));
}
