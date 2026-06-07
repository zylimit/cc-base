/// <reference path="../../../preload/index.d.ts" />
import { useEffect, useState } from 'react';
import type { KeyboardEvent } from 'react';
import { ArrowLeft, ArrowRight, RotateCw, Lock } from 'lucide-react';

/**
 * 真实浏览器面板：地址栏 chrome + 前进/后退/刷新按钮。
 *
 * 与 BrowserMock 的区别：
 * - URL 来自 `window.api.browser.getUrl()`，而非静态字符串
 * - 按钮的 disabled 状态由 `canGoBack` / `canGoForward` 驱动
 * - 地址栏可编辑，敲回车调用 `navigate(url)`
 * - 订阅 `onUrlChanged` 事件，URL 变化时自动更新地址栏
 *
 * onUrlChanged 的当前契约不返回 unsubscribe 函数，因此用
 * `cancelled` 闭包标志在组件 unmount 时屏蔽状态更新，规避
 * "在已卸载组件上 setState" 警告。事件监听器仍挂在
 * ipcRenderer 上，但回调中只读标志、不触发渲染，泄漏可控。
 */
export default function BrowserPanel() {
  const [url, setUrl] = useState<string>('');
  const [canGoBack, setCanGoBack] = useState<boolean>(false);
  const [canGoForward, setCanGoForward] = useState<boolean>(false);
  const [inputValue, setInputValue] = useState<string>('');

  useEffect(() => {
    const browser = window.api.browser;
    if (!browser) {
      return;
    }

    let cancelled = false;

    // 初始状态：拉取当前 URL 与导航能力
    browser
      .getUrl()
      .then((current) => {
        if (cancelled) return;
        setUrl(current);
        setInputValue(current);
      })
      .catch((err) => console.error('[BrowserPanel] getUrl failed', err));

    browser
      .canGoBack()
      .then((v) => {
        if (!cancelled) setCanGoBack(v);
      })
      .catch((err) => console.error('[BrowserPanel] canGoBack failed', err));

    browser
      .canGoForward()
      .then((v) => {
        if (!cancelled) setCanGoForward(v);
      })
      .catch((err) => console.error('[BrowserPanel] canGoForward failed', err));

    // 订阅 URL 变化
    browser.onUrlChanged((newUrl) => {
      if (cancelled) return;
      setUrl(newUrl);
      setInputValue(newUrl);
      // 每次导航后刷新前进/后退能力
      browser
        .canGoBack()
        .then((v) => {
          if (!cancelled) setCanGoBack(v);
        })
        .catch((err) => console.error('[BrowserPanel] canGoBack failed', err));
      browser
        .canGoForward()
        .then((v) => {
          if (!cancelled) setCanGoForward(v);
        })
        .catch((err) => console.error('[BrowserPanel] canGoForward failed', err));
    });

    return () => {
      cancelled = true;
    };
  }, []);

  const handleBack = (): void => {
    window.api.browser?.back().catch((err) => console.error('[BrowserPanel] back failed', err));
  };

  const handleForward = (): void => {
    window.api.browser?.forward().catch((err) => console.error('[BrowserPanel] forward failed', err));
  };

  const handleReload = (): void => {
    window.api.browser?.reload().catch((err) => console.error('[BrowserPanel] reload failed', err));
  };

  const handleNavigate = (): void => {
    const target = inputValue.trim();
    if (!target) return;
    window.api.browser
      ?.navigate(target)
      .catch((err) => console.error('[BrowserPanel] navigate failed', err));
  };

  const handleKeyDown = (e: KeyboardEvent<HTMLInputElement>): void => {
    if (e.key === 'Enter') {
      handleNavigate();
    }
  };

  return (
    <div className="flex-1 flex flex-col bg-white h-full overflow-hidden border-l border-border-tech">
      {/* Browser Chrome / Address Bar */}
      <div className="h-12 bg-slate-100 border-b border-slate-300 flex items-center px-4 shrink-0 space-x-4 z-10">
        <div className="flex items-center space-x-3 text-slate-500">
          <div className="flex gap-1.5 mr-2">
            <div className="w-3 h-3 rounded-full bg-red-400"></div>
            <div className="w-3 h-3 rounded-full bg-yellow-400"></div>
            <div className="w-3 h-3 rounded-full bg-green-400"></div>
          </div>
          <button
            type="button"
            onClick={handleBack}
            disabled={!canGoBack}
            aria-label="Go back"
            className={
              canGoBack
                ? 'cursor-pointer hover:text-slate-700 transition-colors'
                : 'opacity-50 cursor-not-allowed'
            }
          >
            <ArrowLeft size={16} />
          </button>
          <button
            type="button"
            onClick={handleForward}
            disabled={!canGoForward}
            aria-label="Go forward"
            className={
              canGoForward
                ? 'cursor-pointer hover:text-slate-700 transition-colors'
                : 'opacity-50 cursor-not-allowed'
            }
          >
            <ArrowRight size={16} />
          </button>
          <button
            type="button"
            onClick={handleReload}
            aria-label="Reload"
            className="cursor-pointer hover:text-slate-700 transition-colors"
          >
            <RotateCw size={16} />
          </button>
        </div>
        <div className="flex-1 max-w-2xl bg-white h-8 border border-slate-300 rounded flex items-center px-3 text-xs text-slate-600 font-mono shadow-sm">
          <Lock size={12} className="text-slate-400 mr-2 shrink-0" />
          <input
            type="text"
            value={inputValue}
            onChange={(e) => setInputValue(e.target.value)}
            onKeyDown={handleKeyDown}
            aria-label="Address bar"
            className="flex-1 outline-none bg-transparent min-w-0"
          />
        </div>
      </div>

      {/* Content area: real page content is rendered in a separate WebContentsView.
          This panel only owns the chrome; render a neutral placeholder so the
          React layout stays balanced when the WebContentsView is not yet attached. */}
      <div className="flex-1 flex bg-slate-50 text-slate-900 overflow-hidden relative items-center justify-center">
        <p className="text-xs text-slate-400">Browser view is rendered in a WebContentsView.</p>
      </div>
    </div>
  );
}
