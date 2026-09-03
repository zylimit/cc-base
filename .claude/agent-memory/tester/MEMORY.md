# tester memory index

- [测试基建约定](testing-infra.md) — bash 脚本式测试形状、零依赖三件套、基线当场重测、整仓红了先拿 git archive 归因、harness 行为断言挂 cases/test-harness.sh
- [审计脚本易碎区](audit-scripts-fragile-zones.md) — 工作树/索引之别、pwsh 缺席要守卫、测试文件自己会被自举扫描扫到
- [红锁测试写法](red-lock-test-writing.md) — 断言写「修好后应成立」、标注偶然绿、对照组期望写死字面量、单测守不住调用点、拿 /tmp 打补丁副本验红
- [Git Bash 进程测试坑](windows-gitbash-process-tests.md) — kill 杀不动原生进程、/PID 被路径转换、SIGTERM 是硬杀、双层垫片在 Linux 上验 win32 分支（CI 已不跑 Windows .sh）
