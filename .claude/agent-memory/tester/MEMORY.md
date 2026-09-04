# tester memory index

- [测试基建约定](testing-infra.md) — bash 测试形状、基线当场重测、selftest/golden 只能仓内变异、CI 三段平台待遇不同、EISDIR/ENOTDIR 是跨平台那档「读不出来」
- [审计脚本易碎区](audit-scripts-fragile-zones.md) — 工作树/索引之别、pwsh 缺席要守卫、测试文件自己会被自举扫描扫到
- [红锁测试写法](red-lock-test-writing.md) — 断言写「修好后应成立」、期望引用已修好的同族而非发明、对照组写死字面量、验红之外拿候选修复验「修得好」
- [Git Bash 进程测试坑](windows-gitbash-process-tests.md) — kill 杀不动原生进程、/PID 被路径转换、SIGTERM 是硬杀、双层垫片在 Linux 上验 win32 分支（CI 已不跑 Windows .sh）
