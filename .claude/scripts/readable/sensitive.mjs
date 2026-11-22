// 不带出去的东西：隐去规则只有这一份（契约 G 节「不带出去的东西」）。
// note put 拒收、页面隐去、核对器比对都用它。
// 内网地址三段、带口令的地址、sk-ant- / sk-proj- 开头的串、
// password / passwd / secret / token / api_key 后面用 = 或 : 接着八位以上字母数字、且带数字或总长不少于十六位的。

export const REDACTED = '〔已隐去〕';

// 每条规则：kind 是给人看的原因，re 必须带 g，replace 决定换掉哪一段。
// 地址前后不许紧挨数字或点，免得把版本号、更长的数串里的一截当成地址。
const OCTET = '(?:25[0-5]|2[0-4]\\d|1\\d\\d|[1-9]?\\d)';
const ipTail = (n) => Array.from({ length: n }, () => `\\.${OCTET}`).join('');
const IP_PRE = '(?<![\\d.])';
const IP_POST = '(?!\\.?\\d)';

const RULES = [
  {
    kind: '带口令的地址',
    re: /:\/\/[^\s\/:@'"]+:[^\s\/@'"]+@/g,
    replace: () => `://${REDACTED}@`,
  },
  {
    kind: '内网地址',
    re: new RegExp(`${IP_PRE}10${ipTail(3)}${IP_POST}`, 'g'),
    replace: () => REDACTED,
  },
  {
    kind: '内网地址',
    re: new RegExp(`${IP_PRE}172\\.(?:1[6-9]|2\\d|3[01])${ipTail(2)}${IP_POST}`, 'g'),
    replace: () => REDACTED,
  },
  {
    kind: '内网地址',
    re: new RegExp(`${IP_PRE}192\\.168${ipTail(2)}${IP_POST}`, 'g'),
    replace: () => REDACTED,
  },
  {
    kind: '密钥',
    re: /(?<![A-Za-z0-9_-])sk-(?:ant|proj)-[A-Za-z0-9_-]*/g,
    replace: () => REDACTED,
  },
  {
    kind: '口令或密钥',
    // 真的密钥几乎都带数字或很长；纯字母又不长的（如英文注释「token: refreshes the login session」里的 refreshes）是正常的词，不当密钥。
    re: /(password|passwd|secret|token|api_key)(\s*[=:]\s*['"]?)(?=[A-Za-z0-9]{8,})(?:(?=[A-Za-z]*\d)|(?=[A-Za-z0-9]{16}))[A-Za-z0-9]+/gi,
    replace: (_m, key, sep) => `${key}${sep}${REDACTED}`,
  },
];

// 返回换过的文字与换了几处。
export function redact(text) {
  if (typeof text !== 'string' || text === '') return { text: text ?? '', hits: 0 };
  let out = text;
  let hits = 0;
  for (const rule of RULES) {
    out = out.replace(rule.re, (...args) => {
      hits += 1;
      return rule.replace(...args);
    });
  }
  return { text: out, hits };
}

// 命中了哪几类（按规则顺序去重），给 note put 拒收时说原因。
export function sensitiveKinds(text) {
  if (typeof text !== 'string' || text === '') return [];
  const kinds = [];
  for (const rule of RULES) {
    rule.re.lastIndex = 0;
    if (rule.re.test(text) && !kinds.includes(rule.kind)) kinds.push(rule.kind);
    rule.re.lastIndex = 0;
  }
  return kinds;
}
