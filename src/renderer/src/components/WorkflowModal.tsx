import { X, Play, Upload } from 'lucide-react';
import { Workflow } from '../types';

interface Props {
  onClose: () => void;
  workflows: Workflow[];
  onPlay: (workflow: Workflow) => void;
  onImport: () => void;
}

export default function WorkflowModal({ onClose, workflows, onPlay, onImport }: Props) {
  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 backdrop-blur-sm">
      <div className="w-[480px] bg-bg-panel border border-border-tech rounded-lg shadow-2xl flex flex-col overflow-hidden text-slate-200">
        <div className="flex items-center justify-between px-6 py-4 border-b border-border-tech bg-black/20">
          <h2 className="text-sm font-bold uppercase tracking-widest text-slate-400">作业流库</h2>
          <button onClick={onClose} className="text-slate-500 hover:text-slate-300 transition-colors">
            <X size={16} />
          </button>
        </div>
        
        <div className="px-6 py-4 border-b border-border-tech">
          <button 
            onClick={onImport}
            className="flex items-center text-primary hover:text-orange-400 font-bold uppercase text-[10px] transition-colors"
          >
            <Upload size={14} className="mr-2" />
            导入作业流
          </button>
        </div>

        <div className="flex-1 overflow-y-auto max-h-[400px]">
          {workflows.length === 0 ? (
            <div className="px-6 py-12 text-center text-slate-500 text-xs font-mono">
              暂无作业流 — 点击录制按钮开始录制第一个
            </div>
          ) : (
            <ul className="divide-y divide-border-tech bg-black/10">
              {workflows.map((wf) => (
                <li key={wf.id} className="flex items-center justify-between px-6 py-4 hover:bg-white/5 group transition-colors">
                  <div className="flex items-center space-x-3">
                    <div className={`w-2 h-2 rounded-full shadow-sm ${
                      wf.status === 'success' ? 'bg-green-500 shadow-green-500/50' : 
                      wf.status === 'failed' ? 'bg-red-500 shadow-red-500/50' : 'bg-slate-600'
                    }`} />
                    <span className="font-bold text-xs text-slate-200">{wf.name}</span>
                    <span className="text-[10px] font-mono text-slate-500">{wf.steps} 步</span>
                    <span className="text-[10px] font-mono text-slate-500">{wf.lastRun}</span>
                  </div>
                  <button 
                    onClick={() => onPlay(wf)}
                    className="text-primary hover:text-orange-400 opacity-0 group-hover:opacity-100 transition-all font-bold text-[10px] uppercase tracking-wider flex items-center border border-orange-500/30 bg-orange-500/10 px-2 py-1 rounded"
                  >
                    PLAY <Play size={12} fill="currentColor" className="ml-1" />
                  </button>
                </li>
              ))}
            </ul>
          )}
        </div>
      </div>
    </div>
  );
}
