import { WebContentsView, BrowserWindow, Event } from 'electron'

/**
 * WebContentsView 在父窗口中的矩形区域。
 *
 * 所有单位均为物理像素，由 BrowserViewManager 内部存储当前值，
 * 父窗口 resize 时自动同步宽高（x/y 保持不变，size 跟随父窗口内容区）。
 */
export interface ViewBounds {
  x: number
  y: number
  width: number
  height: number
}

/**
 * URL 变化 IPC 事件名。
 *
 * 推送到渲染进程时载荷为字符串（目标 URL）。渲染进程通过
 * `window.api.onUrlChanged(handler)` 订阅。
 */
export const URL_CHANGED_EVENT = 'browser:url-changed'

/**
 * 初始空白页 URL。create() 时先 load 这一页以拿到一个干净的 WebContents。
 */
const ABOUT_BLANK = 'about:blank'

/**
 * 浏览器视图管理器。
 *
 * 职责：
 * - 持有单个 WebContentsView 实例，绑定到父 BrowserWindow 的 contentView
 * - 暴露导航/前进/后退/刷新 等控制方法
 * - 父窗口 resize 时自动同步 bounds（x/y 保持，width/height 跟随父窗口内容区）
 * - URL 变化时通过 IPC event 推送给渲染进程（will-navigate 监听）
 *
 * 用法（典型）：
 * ```ts
 * const manager = new BrowserViewManager(mainWindow, { x: 240, y: 0, width: 1200, height: 900 })
 * manager.create()
 * await manager.navigate('https://example.com')
 * // 窗口销毁时
 * manager.destroy()
 * ```
 *
 * 生命周期约束：destroy() 之后调用任何导航/查询方法都会抛错。
 */
export class BrowserViewManager {
  private readonly parentWindow: BrowserWindow
  private currentBounds: ViewBounds
  private view: WebContentsView | null = null

  // 持有监听器引用，destroy 时用于 off()
  private resizeHandler: (() => void) | null = null
  private closedHandler: (() => void) | null = null
  private willNavigateHandler: ((event: Event, url: string) => void) | null = null

  constructor(parentWindow: BrowserWindow, bounds: ViewBounds) {
    this.parentWindow = parentWindow
    this.currentBounds = { ...bounds }
  }

  /**
   * 创建 WebContentsView 并挂载到父窗口。
   *
   * 重复调用是 no-op。完成后内部状态：view 已创建，初始 about:blank 已发起加载。
   */
  create(): void {
    if (this.view !== null) {
      return
    }

    this.view = new WebContentsView()
    this.view.setBounds(this.currentBounds)
    this.parentWindow.contentView.addChildView(this.view)

    // 父窗口 resize → 自动同步 width/height（x/y 保留，size 填满剩余空间）
    this.resizeHandler = (): void => {
      this.syncBoundsToParent()
    }
    this.parentWindow.on('resize', this.resizeHandler)

    // 父窗口关闭 → 联动销毁本视图
    this.closedHandler = (): void => {
      this.destroy()
    }
    this.parentWindow.on('closed', this.closedHandler)

    // URL 变化监听
    const wc = this.view.webContents
    this.willNavigateHandler = (_event: Event, url: string): void => {
      this.notifyUrlChanged(url)
    }
    wc.on('will-navigate', this.willNavigateHandler)

    void wc.loadURL(ABOUT_BLANK)
  }

  /**
   * 销毁 WebContentsView。
   *
   * - 摘除父窗口上的子视图
   * - 移除所有监听器（父窗口 resize/closed + webContents will-navigate）
   * - 关闭 webContents 释放资源
   *
   * 幂等：重复调用安全。
   */
  destroy(): void {
    if (this.resizeHandler !== null) {
      this.parentWindow.off('resize', this.resizeHandler)
      this.resizeHandler = null
    }
    if (this.closedHandler !== null) {
      this.parentWindow.off('closed', this.closedHandler)
      this.closedHandler = null
    }

    if (this.view !== null) {
      const wc = this.view.webContents
      if (this.willNavigateHandler !== null) {
        wc.off('will-navigate', this.willNavigateHandler)
        this.willNavigateHandler = null
      }

      if (!this.parentWindow.isDestroyed()) {
        try {
          this.parentWindow.contentView.removeChildView(this.view)
        } catch {
          // 视图可能已经被父窗口释放，忽略
        }
      }

      // 显式关闭 webContents，避免依赖 GC
      if (!wc.isDestroyed()) {
        wc.close()
      }

      this.view = null
    }
  }

  /**
   * 导航到指定 URL。
   *
   * 等同于 webContents.loadURL，等待 did-finish-load / did-fail-load 之一。
   * 会触发 will-navigate，渲染进程将通过 `browser:url-changed` 收到新 URL。
   */
  async navigate(url: string): Promise<void> {
    const view = this.requireView()
    await view.webContents.loadURL(url)
  }

  /**
   * 后退。无历史可退时是 no-op。
   */
  back(): void {
    const view = this.requireView()
    if (view.webContents.canGoBack()) {
      view.webContents.goBack()
    }
  }

  /**
   * 前进。无历史可进时是 no-op。
   */
  forward(): void {
    const view = this.requireView()
    if (view.webContents.canGoForward()) {
      view.webContents.goForward()
    }
  }

  /**
   * 重新加载当前页。
   */
  reload(): void {
    const view = this.requireView()
    view.webContents.reload()
  }

  /**
   * 当前页 URL。视图未创建或已销毁时返回空串。
   */
  getUrl(): string {
    return this.view?.webContents.getURL() ?? ''
  }

  /**
   * 是否可以后退。视图未创建或已销毁时返回 false。
   */
  canGoBack(): boolean {
    return this.view?.webContents.canGoBack() ?? false
  }

  /**
   * 是否可以前进。视图未创建或已销毁时返回 false。
   */
  canGoForward(): boolean {
    return this.view?.webContents.canGoForward() ?? false
  }

  /**
   * 设置视图矩形区域。会立即应用到 WebContentsView。
   *
   * 后续父窗口 resize 时，自动同步会以本次设置的 x/y 为锚点重新计算 size。
   */
  setBounds(bounds: ViewBounds): void {
    this.currentBounds = { ...bounds }
    this.view?.setBounds(this.currentBounds)
  }

  /**
   * 校验视图处于活动状态。destroy 后调用任何导航/查询方法都通过此方法抛错。
   */
  private requireView(): WebContentsView {
    if (this.view === null) {
      throw new Error('BrowserViewManager: view has been destroyed')
    }
    return this.view
  }

  /**
   * 父窗口 resize 时调用。
   *
   * 规则：x/y 保持不变（保留侧边栏偏移等业务约定），width/height
   * 跟随父窗口 contentBounds 计算剩余可用区域。
   */
  private syncBoundsToParent(): void {
    if (this.view === null || this.parentWindow.isDestroyed()) {
      return
    }
    const content = this.parentWindow.getContentBounds()
    this.currentBounds = {
      x: this.currentBounds.x,
      y: this.currentBounds.y,
      width: Math.max(0, content.width - this.currentBounds.x),
      height: Math.max(0, content.height - this.currentBounds.y)
    }
    this.view.setBounds(this.currentBounds)
  }

  /**
   * 通过 IPC event 推送 URL 变化给父窗口的渲染进程。
   *
   * 父窗口被销毁或 webContents 不可用时静默忽略。
   */
  private notifyUrlChanged(url: string): void {
    if (this.parentWindow.isDestroyed()) {
      return
    }
    const wc = this.parentWindow.webContents
    if (wc.isDestroyed()) {
      return
    }
    wc.send(URL_CHANGED_EVENT, url)
  }
}
