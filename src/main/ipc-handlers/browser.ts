import { ipcMain, BrowserWindow } from 'electron'
import { EventEmitter } from 'events'
import { BrowserViewManager, URL_CHANGED_EVENT } from '../browser-view'

/**
 * 浏览器 IPC handler 返回值统一类型。
 *
 * 成功时返回原类型 T，异常时统一转为 `{ error: string }`。
 * 约束：handler 内禁止 throw 异常，所有错误经此形式向上传递，
 * 渲染进程端通过判断 `'error' in result` 即可识别。
 */
type SafeResult<T> = T | { error: string }

/**
 * 将 handler 包裹一层 try-catch：异常时返回 `{ error: message }`，正常时透传结果。
 *
 * 使用 ipcMain.handle 而非 ipcMain.on，因为本组 channel 多有返回值
 * （URL 字符串、canGoBack 布尔等），invoke 语义更贴合。
 */
function safeHandle<TArgs extends unknown[], TResult>(
  channel: string,
  fn: (...args: TArgs) => TResult | Promise<TResult>
): void {
  ipcMain.handle(channel, async (_event, ...args): Promise<SafeResult<TResult>> => {
    try {
      return await fn(...(args as TArgs))
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err)
      return { error: message }
    }
  })
}

/**
 * 注册浏览器相关的 IPC handlers。
 *
 * 通道列表（统一 ipcMain.handle 形式）：
 * - browser:navigate        (url: string)              → void | { error }
 * - browser:back                                       → void | { error }
 * - browser:forward                                    → void | { error }
 * - browser:reload                                     → void | { error }
 * - browser:get-url                                    → string | { error }
 * - browser:can-go-back                                → boolean | { error }
 * - browser:can-go-forward                             → boolean | { error }
 *
 * URL 变化转发：
 *   BrowserViewManager 在 URL 变化时通过 URL_CHANGED_EVENT 通知父窗口
 *   webContents；本函数订阅该事件，并以 'browser:url-changed' 推送给
 *   渲染进程，渲染端通过 window.api.onUrlChanged(handler) 订阅。
 *
 * 注意：本函数无注销能力。调用方需保证同一对 (manager, mainWindow)
 * 上不重复注册——通常在 app.whenReady 内 createWindow 完成后调用一次。
 */
export function registerBrowserIpcHandlers(
  browserViewManager: BrowserViewManager,
  mainWindow: BrowserWindow
): void {
  // 导航控制
  safeHandle<[string], void>('browser:navigate', (url) => {
    void browserViewManager.navigate(url)
  })

  safeHandle<[], void>('browser:back', () => {
    browserViewManager.back()
  })

  safeHandle<[], void>('browser:forward', () => {
    browserViewManager.forward()
  })

  safeHandle<[], void>('browser:reload', () => {
    browserViewManager.reload()
  })

  // 状态查询
  safeHandle<[], string>('browser:get-url', () => {
    return browserViewManager.getUrl()
  })

  safeHandle<[], boolean>('browser:can-go-back', () => {
    return browserViewManager.canGoBack()
  })

  safeHandle<[], boolean>('browser:can-go-forward', () => {
    return browserViewManager.canGoForward()
  })

  // URL 变化转发：监听父窗口 webContents 上的 URL_CHANGED_EVENT，
  // 以 'browser:url-changed' 推送给渲染进程。
  // 注：WebContents 暴露了大量具名事件 on() 重载，自定义 IPC channel
  // 不在其中。这里通过 EventEmitter 接口访问通用 on()，
  // 绕过类型重载约束，运行时行为与 webContents.on 一致。
  const wcEmitter = mainWindow.webContents as unknown as EventEmitter
  wcEmitter.on(URL_CHANGED_EVENT, (url: string) => {
    if (mainWindow.isDestroyed()) {
      return
    }
    mainWindow.webContents.send('browser:url-changed', url)
  })
}
