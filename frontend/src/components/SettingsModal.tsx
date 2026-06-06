import { X } from 'lucide-react';

interface Props {
  onClose: () => void;
}

export default function SettingsModal({ onClose }: Props) {
  return (
    <div className="fixed inset-0 z-50 flex flex-col items-center justify-center bg-black/60 backdrop-blur-sm">
      <div className="w-[520px] bg-bg-panel border border-border-tech rounded-lg shadow-2xl flex flex-col overflow-hidden text-slate-200">
        <div className="flex items-center justify-between px-6 py-4 border-b border-border-tech bg-black/20">
          <h2 className="text-sm font-bold uppercase tracking-widest text-slate-400">设置</h2>
          <button onClick={onClose} className="text-slate-500 hover:text-slate-300 transition-colors">
            <X size={16} />
          </button>
        </div>
        
        <div className="p-6 space-y-6 overflow-y-auto max-h-[70vh]">
          {/* API Key */}
          <div className="space-y-2">
            <label className="text-[10px] font-bold uppercase tracking-widest text-slate-500">Claude API Key</label>
            <input 
              type="password" 
              defaultValue="sk-ant-1234567890abcdef"
              className="w-full bg-black/40 border border-border-tech rounded px-3 py-2.5 text-xs text-slate-200 focus:outline-none focus:border-primary transition-colors font-mono"
            />
          </div>

          {/* Model */}
          <div className="space-y-2">
            <label className="text-[10px] font-bold uppercase tracking-widest text-slate-500">Claude 模型</label>
            <select className="w-full bg-black/40 border border-border-tech rounded px-3 py-2.5 text-xs text-slate-200 focus:outline-none focus:border-primary transition-colors appearance-none">
              <option>claude-haiku-4-5</option>
              <option>claude-sonnet-4-6</option>
            </select>
          </div>

          {/* Directory */}
          <div className="space-y-2">
            <label className="text-[10px] font-bold uppercase tracking-widest text-slate-500">作业流存储目录</label>
            <div className="flex items-center w-full bg-black/40 border border-border-tech rounded overflow-hidden focus-within:border-primary transition-colors">
              <input 
                type="text" 
                defaultValue="C:\Users\z00632348\datalink"
                className="flex-1 bg-transparent px-3 py-2.5 text-xs text-slate-200 focus:outline-none font-mono"
                readOnly
              />
              <button className="px-4 py-2.5 text-[10px] text-primary hover:bg-white/5 font-bold uppercase tracking-wider border-l border-border-tech transition-colors">
                浏览
              </button>
            </div>
          </div>

          {/* URL */}
          <div className="space-y-2">
            <label className="text-[10px] font-bold uppercase tracking-widest text-slate-500">Datalink URL</label>
            <input 
              type="text" 
              defaultValue="https://datalink.huawei.com"
              className="w-full bg-black/40 border border-border-tech rounded px-3 py-2.5 text-xs text-slate-200 focus:outline-none focus:border-primary transition-colors font-mono"
            />
          </div>

          {/* Save Button */}
          <button className="w-full bg-primary hover:bg-orange-400 text-black font-bold uppercase tracking-wider py-3 rounded transition-colors text-xs mt-4">
            保存设置
          </button>

          {/* Divider */}
          <div className="border-t border-border-tech pt-6 mt-6">
            <label className="text-[10px] font-bold uppercase tracking-widest text-slate-500 block mb-3">数据管理</label>
            <button className="w-full bg-red-500/10 border border-red-500/20 hover:bg-red-500/20 text-red-500 font-bold uppercase tracking-wider py-3 rounded transition-colors text-xs">
              清除所有数据
            </button>
          </div>
        </div>
      </div>
    </div>
  );
}
