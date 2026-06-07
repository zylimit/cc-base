/**
 * 渲染进程全局类型声明。
 *
 * 仅做类型 import（`import type`）：本文件被 web tsconfig 引入用于
 * 让渲染代码识别 `window.api.*`，但本身不参与运行时；type-only
 * import 避免 bundler 误把 preload 实现拉进渲染产物。
 *
 * `ApiSchema` 在 `./index.ts` 中定义，是 preload <-> renderer 之间的
 * 单一类型来源；任何 IPC 契约变更都改 `./index.ts` 即可，d.ts 不需要
 * 同步维护字段列表。
 */
import type { ApiSchema } from './index'

declare global {
  interface Window {
    api: ApiSchema
  }
}

export {}
