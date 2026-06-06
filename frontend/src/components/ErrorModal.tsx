import { X } from 'lucide-react';

interface Props {
  onClose: () => void;
}

export default function ErrorModal({ onClose }: Props) {
  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 backdrop-blur-sm">
      <div className="w-[600px] bg-bg-panel border border-border-tech rounded-lg shadow-2xl flex flex-col overflow-hidden text-slate-200 relative">
        {/* Red accent bar */}
        <div className="absolute left-0 top-0 bottom-0 w-1 bg-red-500"></div>
        
        <div className="flex items-center justify-between px-6 py-4 border-b border-border-tech bg-black/20 pl-8">
          <h2 className="text-sm font-bold uppercase tracking-widest text-red-500">执行失败</h2>
          <button onClick={onClose} className="text-slate-500 hover:text-slate-300 transition-colors">
            <X size={16} />
          </button>
        </div>
        
        <div className="p-6 space-y-4 pl-8">
          
          <div className="bg-red-500/5 border border-red-500/20 rounded p-4">
            <h3 className="text-[10px] font-bold uppercase tracking-widest text-red-400/80 mb-2">错误信息</h3>
            <p className="text-xs text-red-400 font-mono break-all leading-relaxed">
              ElementNotFoundError: 无法定位元素 [text="保存", role="button"]
            </p>
          </div>

          <div className="bg-black/40 border border-border-tech rounded p-4">
            <h3 className="text-[10px] font-bold uppercase tracking-widest text-slate-500 mb-2">失败步骤</h3>
            <p className="text-xs text-slate-300 font-mono break-all">
              Step 3: click [text="保存", role="button"] @ 12.34s
            </p>
          </div>

          <div className="bg-black/40 border border-border-tech rounded p-4">
            <h3 className="text-[10px] font-bold uppercase tracking-widest text-slate-500 mb-2">错误截图</h3>
            <p className="text-xs text-slate-400 font-mono">
              screenshot_2026-06-07_14-30-00.png
            </p>
          </div>

        </div>

        <div className="px-6 py-4 border-t border-border-tech pl-8 flex justify-end space-x-4">
          <button disabled className="text-slate-500 text-xs font-bold uppercase tracking-wider cursor-not-allowed hidden">
            重试
          </button>
          <button onClick={onClose} className="bg-white/10 hover:bg-white/20 border border-white/20 text-white px-4 py-2 text-[10px] font-bold tracking-wider uppercase transition-colors rounded">
            关闭
          </button>
        </div>
      </div>
    </div>
  );
}
