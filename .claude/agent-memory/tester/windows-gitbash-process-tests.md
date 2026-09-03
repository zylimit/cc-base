---
name: windows-gitbash-process-tests
description: 在 Git Bash（CI windows 格）上测进程/信号的坑——kill 对原生进程无效、/PID 会被路径转换、SIGTERM 是硬杀，以及怎么在 Linux 上验 Windows 分支
metadata:
  type: project
---

cc-base 的 gate 跑 `windows-latest` + `shell: bash`（= Git for Windows 的 Git Bash）。测试碰进程/信号时，这几处是 Windows 专属红：

- **Git Bash 的 `kill` 只对 MSYS 进程有效**，给 node.exe / cmd.exe 这类原生进程发信号发不出去，进程根本不死。配上惯用的 `2>/dev/null || true` 后完全静默，后面的断言就在验一个没成立的前提。杀原生进程一律分平台走 `taskkill /PID <pid> /T /F`（`/T` 收 `shell:true` 起的孙进程）。
- **`/PID` 这类开关会被 MSYS 当路径转换**成 `C:/Program Files/Git/PID`，taskkill 报 `Invalid argument/option`。两种解法**不能叠加**：`//PID` 靠运行时把 `//` 缩成 `/`，一旦环境里设了 `MSYS2_ARG_CONV_EXCL=*` 就原样传出去反而失效。选命令级前缀 `MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' taskkill /PID ... /T /F`——Git Bash 认前者、MSYS2 原生认后者，前缀赋值还能盖掉环境里的既有值。
- **平台检测照仓里的 `case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*)`**（setup.sh 已这么写，Git Bash 必带 uname）。
- **Windows 上没有优雅信号**：node 的 `process.kill(pid,'SIGTERM')` 走 TerminateProcess，目标的 `process.on('SIGTERM')` 监听器压根不触发（官方文档明写）。凡「停止后状态应收敛成 X」的断言，先想清楚实现是不是被自己发的 SIGTERM 抢在写状态之前打死了——这类红是实现缺陷，不是测试缺陷，别改断言迁就。
- **验 Windows 专属分支不用等 CI**：`PATH` 垫片造假 `uname`（`-s` 回 `MINGW64_NT-10.0`）就能把脚本逼进该分支；再加个假 `taskkill` 垫片（记 argv 到日志 + 用 `kill -9` 真杀）整套就能在 Linux 上跑绿，一次证到三件事——分支可达、argv 形状对、结果语义等价。只装假 uname 不装 taskkill 那一版更值：断言会红成 CI 里一模一样的样子，顺带证明它不是空断言。
- 相关：[[cc-base-testing-infra]]
