#!/usr/bin/env bash
# statusline.sh — Claude Code 状态行（settings.json statusLine 注册，stdin 吃会话 JSON）。
# 把框架治理状态做成全程可见：session-rules-banner 只在开场播一次，本状态行常驻——
#   [模型] ctx NN% | $成本 | FAST-MODE 剩余h | 待审 N | harness ON
# 数据源：stdin JSON（model/context_window/cost/workspace）+ 项目运行态文件
# （.claude/.fast-mode expires_epoch / .claude/.needs-review / harness/module-catalog.json）。
# 程序经 -c 传入、stdin 留给会话 JSON（heredoc 会占掉 stdin，数据就丢了）。
# python3 缺失时降级输出静态标识，绝不报错刷屏（状态行每次渲染都会跑，必须便宜、必须安静）。
set -u

python3 -c '
import json, os, sys, time

try:
    d = json.load(sys.stdin)
except Exception:
    d = {}

ws = d.get("workspace") or {}
root = ws.get("project_dir") or ws.get("current_dir") or os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()

segs = []

model = (d.get("model") or {}).get("display_name") or ""
if model:
    segs.append("[%s]" % model)

pct = (d.get("context_window") or {}).get("used_percentage")
if isinstance(pct, (int, float)):
    p = int(pct)
    seg = "ctx %d%%" % p
    if p >= 80:
        seg = "\033[31m%s\033[0m" % seg
    segs.append(seg)

cost = (d.get("cost") or {}).get("total_cost_usd")
if isinstance(cost, (int, float)) and cost > 0:
    segs.append("$%.2f" % cost)

# fast-mode：expires_epoch 未过期才算开（与 lib-fast-mode 同口径），黄色醒目防忘关
try:
    with open(os.path.join(root, ".claude", ".fast-mode"), encoding="utf-8") as f:
        for line in f:
            if line.startswith("expires_epoch="):
                exp = int(line.split("=", 1)[1].strip())
                left = exp - int(time.time())
                if left > 0:
                    segs.append("\033[33mFAST-MODE %.1fh\033[0m" % (left / 3600.0))
                break
except Exception:
    pass

# 待审欠账：去空行去 clean 后仍有条目即红色示数（与 stop-gate 同口径）
try:
    with open(os.path.join(root, ".claude", ".needs-review"), encoding="utf-8") as f:
        n = sum(1 for line in f if line.strip() and line.strip() != "clean")
    if n > 0:
        segs.append("\033[31m\u5f85\u5ba1 %d\033[0m" % n)
except Exception:
    pass

# 大仓治理开关（catalog 存在即启用）
if os.path.isfile(os.path.join(root, ".claude", "harness", "module-catalog.json")):
    segs.append("\033[32mharness ON\033[0m")

sys.stdout.write(" | ".join(segs) if segs else "cc-base")
' 2>/dev/null || printf 'cc-base'
