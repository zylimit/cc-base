import { contextBridge, ipcRenderer } from 'electron'

/**
 * 渲染进程可调用的 IPC API 契约。
 *
 * 这里是 preload 暴露给渲染进程的唯一类型来源。`index.d.ts` 通过
 * `import type { ApiSchema }` 引用本接口并挂到 `window.api`，使
 * 渲染进程能享受到完整的类型推断与编译期检查。
 *
 * 设计约定：
 * - 所有调用返回 `Promise`，与 `ipcRenderer.invoke` 的异步语义对齐
 * - `browser` 分组标记为可选，反映"未来可能存在 preload 入口未注入
 *   该分组"的语义（如轻量预览窗口）；当前默认始终提供
 * - 事件订阅（如 `onUrlChanged`）走 `ipcRenderer.on`，回调签名只暴露
 *   业务载荷，不向渲染层泄漏 Electron 内部的 `IpcRendererEvent`
 */
export interface ApiSchema {
  ping: () => Promise<string>

  browser?: {
    navigate: (url: string) => Promise<void>
    back: () => Promise<void>
    forward: () => Promise<void>
    reload: () => Promise<void>
    getUrl: () => Promise<string>
    canGoBack: () => Promise<boolean>
    canGoForward: () => Promise<boolean>
    onUrlChanged: (callback: (url: string) => void) => void
  }
}

const api: ApiSchema = {
  ping: () => ipcRenderer.invoke('ping'),

  // browser API
  browser: {
    navigate: (url: string) => ipcRenderer.invoke('browser:navigate', url),
    back: () => ipcRenderer.invoke('browser:back'),
    forward: () => ipcRenderer.invoke('browser:forward'),
    reload: () => ipcRenderer.invoke('browser:reload'),
    getUrl: () => ipcRenderer.invoke('browser:get-url') as Promise<string>,
    canGoBack: () => ipcRenderer.invoke('browser:can-go-back') as Promise<boolean>,
    canGoForward: () => ipcRenderer.invoke('browser:can-go-forward') as Promise<boolean>,
    onUrlChanged: (callback: (url: string) => void) => {
      ipcRenderer.on('browser:url-changed', (_event, url: string) => callback(url))
    }
  }
}

contextBridge.exposeInMainWorld('api', api)
