// db-scrub.mjs —— 数据库设计页面上不带出去的东西（契约 docs/readable-spec/phase1-db-contract.md G 节「不带出去的东西」，
// 取代 C 节「原样照出、只在顶上警告」的做法）。规格把「生成物里不出现密钥、内网地址与账号」定为 P0。
// 隐去的规则只有一份，在 ../sensitive.mjs；这里只管哪些字段过它、换掉的记在哪个文件哪一行（说明记锚点），给 db/index.html 顶上列出来。
// 出一份换过的模型副本给各页用，传进来的模型不动——核对器要拿同一份模型在内存里重出一遍来比。
// 过的字段：契约点名的来源里的注释（表、列、改动备注）、默认值、CHECK 原文、视图定义、「表名是运行时拼的」的原文开头、说明的正文；
// 另外页面上照录的来源原文——表级约束原文、索引的列与条件、四张问题清单的原文开头——也一并过，免得从这几处漏出去。
import { redact } from '../sensitive.mjs';
import { cmp } from '../model.mjs';

export function scrub(model) {
  const hits = [];
  // where：{file, line} 或 {anchor}；what：哪一项。count 为 false 的只换不记——同一段原文在模型里存了两份、页面只显示其中一份时用。
  const r = (s, where, what, count = true) => {
    if (typeof s !== 'string') return s;
    const o = redact(s);
    if (o.hits && count) hits.push({ ...where, what, n: o.hits });
    return o.text;
  };
  const at = (x) => ({ file: x.file, line: x.line });
  const tables = model.tables.map((t) => ({
    ...t,
    comment: r(t.comment, at(t), `表 ${t.name} 的注释`),
    columns: t.columns.map((c) => {
      const w = at(c.file ? c : t), who = `列 ${t.name}.${c.name}`;
      return { ...c, comment: r(c.comment, w, `${who} 的注释`), default: r(c.default, w, `${who} 的默认值`), check: r(c.check, w, `${who} 的 CHECK`) };
    }),
    // 页面上的约束原文显示 raw，没有 raw 才显示 check：只记显示的那一份。
    constraints: t.constraints.map((c) => ({
      ...c,
      raw: r(c.raw, at(c), `表 ${t.name} 的表级约束原文`),
      check: r(c.check, at(c), `表 ${t.name} 的表级约束原文`, c.raw == null),
      comment: r(c.comment, at(c), '', false),
    })),
    indexes: t.indexes.map((x) => ({
      ...x,
      columns: r(x.columns, at(x), `索引 ${x.name ?? ''} 的列`),
      options: r(x.options, at(x), `索引 ${x.name ?? ''} 的选项`),
      where: r(x.where, at(x), `索引 ${x.name ?? ''} 的条件`),
    })),
    changes: (t.changes || []).map((x) => ({ ...x, comment: r(x.comment, at(x), `表 ${t.name} 的改动备注`) })),
  }));
  const views = model.views.map((v) => ({ ...v, sql: r(v.sql, at(v), `视图 ${v.name} 的定义`) }));
  const heads = (list, what) => list.map((x) => ({ ...x, head: r(x.head, at(x), what), text: r(x.text, at(x), what) }));
  const notes = {};
  for (const k of Object.keys(model.notes || {}).sort(cmp)) {
    const n = model.notes[k];
    notes[k] = { ...n, text: r(n.text, { anchor: k }, '说明的正文') };
  }
  return {
    model: {
      ...model, tables, views, notes,
      unfolded: heads(model.unfolded, '未合并的动态定义的原文开头'),
      unparsed: heads(model.unparsed, '未解析的语句的原文开头'),
      conflicts: heads(model.conflicts, '定义冲突的原文开头'),
      orphanAlters: heads(model.orphanAlters, '改了不存在的表的原文开头'),
      dynamic: model.dynamic.map((d) => ({ ...d, head: r(d.head, at(d), '表名是运行时拼的原文开头') })),
    },
    hits,
  };
}
