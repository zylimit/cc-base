---
paths:
  - ".claude/feedback/**"
  - ".claude/agent-memory/**"
---

本文件由 CLAUDE.md 下沉；主控命中指针时必须完整读取本文件再行动，不得凭指针行猜测内容。（frontmatter 的 paths 让 Claude Code 原生按需加载本规则——碰 .claude/feedback/ 或 .claude/agent-memory/ 下文件时自动进上下文；判断某条该记哪儿时仍按 CLAUDE.md 指针手动读，两条路都通。）

[三套系统的边界（feedback / 用户 memory / agent memory）]
    - feedback 记录到 .claude/feedback/ 目录，由 evolution-engine 扫描并生成进化建议，用于改进 Skill 和规则
    - memory 记录到用户的 memory/ 目录，用于跨 session 记住用户偏好和项目上下文
    - 用户修正 AI 行为时，必须走 feedback 流程（派发 feedback-observer），不能只写 memory
    - **agent memory（第三类，别和前两者混）**：code-reviewer / tester 挂了 `memory: project` 持久记忆，存的是角色自己的战术笔记（本项目高发缺陷模式 / flaky 区），由角色自维护、无人工审核——它不承载框架规则（那是 feedback 的事），也不承载项目事实。
    - **Claude Code 原生 auto memory 的边界**：原生 auto memory（~/.claude/projects/<repo>/memory/）默认开启，只许存机器本地琐碎（构建命令、调试线索）；**决策 / 约束 / 完成事项只认 progress.md**——三文件同步铁律不因 auto memory 存了什么而豁免，恢复上下文以 /recap 三份文件为准、不以 auto memory 为准。
