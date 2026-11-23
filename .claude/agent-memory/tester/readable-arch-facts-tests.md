---
name: readable-arch-facts-tests
description: 人读文档第三期取事实四套 bash 测试的写法坑（改契约后原断言会因夹具而红、旧脚本取法、HEAD 无 why 字段）
metadata:
  type: project
---

routes 测试夹具里的路由器改契约后默认「没被挂载 = fullPath null」：原断言要保留就得加一份无前缀 include_router 的挂载文件（orphan 故意不挂当对照），否则整串 /lit/ok 类断言一起红。

**How to apply:** 对旧代码验红用 `git archive HEAD .claude/scripts | tar -x -C <临时目录>` 再 `bash <测试> <临时>/.claude/scripts/readable-docs.mjs`；HEAD 的 routes 没有 `why` 字段（undefined 不是 null），断言写 `v===null?'N':v` 时 undefined 会显成 "undefined"，写红断言时别当成实现细节。JS 取值遇 undefined 会 JSONERR，红断言用 `String(x.head)` / `(x||{}).k` 兜住，别让 JSONERR 冒充红因。
