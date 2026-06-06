import { Send, Settings, Book, Circle, Square } from 'lucide-react';
import { useState } from 'react';
import { ChatMessage } from '../types';

interface Props {
  onOpenSettings: () => void;
  onOpenWorkflows: () => void;
  isRecording: boolean;
  onToggleRecord: () => void;
  messages: ChatMessage[];
  onSendMessage: (msg: string) => void;
}

export default function Sidebar({
  onOpenSettings,
  onOpenWorkflows,
  isRecording,
  onToggleRecord,
  messages,
  onSendMessage
}: Props) {
  const [input, setInput] = useState('');

  const handleSend = () => {
    if (!input.trim()) return;
    onSendMessage(input);
    setInput('');
  };

  return (
    <div className="flex h-full border-r border-border-tech">
      {/* Thin Sidebar Panel */}
      <div className="w-16 flex flex-col items-center py-6 border-r border-border-tech bg-bg-sidebar shrink-0 z-20">
        <div className="w-10 h-10 bg-orange-600 rounded-lg flex items-center justify-center mb-10 shadow-lg shadow-orange-900/20">
          <span className="text-white text-xs font-bold font-mono">DL</span>
        </div>
        <div className="flex flex-col gap-8 opacity-60">
          <button onClick={onOpenWorkflows} className="p-2 hover:bg-white/5 rounded-md cursor-pointer transition-colors focus:opacity-100 hover:text-primary" title="作业流库">
            <Book size={20} />
          </button>
          <button onClick={onOpenSettings} className="p-2 hover:bg-white/5 rounded-md cursor-pointer transition-colors focus:opacity-100 hover:text-primary" title="设置">
            <Settings size={20} />
          </button>
        </div>
      </div>

      <div className="w-80 flex flex-col bg-bg-panel shrink-0">
        {/* Header */}
        <div className="p-4 border-b border-border-tech flex items-center justify-between shrink-0">
          <span className="text-xs font-bold uppercase tracking-widest text-slate-500">Automation Engine</span>
          <button onClick={onToggleRecord} className="focus:outline-none">
            {isRecording ? (
              <div className="flex items-center gap-2 px-2 py-1 bg-orange-500/10 rounded border border-orange-500/30 hover:bg-orange-500/20 transition-colors">
                <div className="recording-pulse"></div>
                <span className="text-[10px] text-primary font-bold uppercase">Recording</span>
              </div>
            ) : (
              <div className="flex items-center gap-2 px-2 py-1 bg-white/5 rounded border border-white/10 hover:bg-white/10 transition-colors">
                <Circle size={10} className="text-slate-400" fill="currentColor" />
                <span className="text-[10px] text-slate-400 font-bold uppercase">Standby</span>
              </div>
            )}
          </button>
        </div>

        {/* Chat Messages */}
        <div className="flex-1 overflow-y-auto p-4 flex flex-col gap-4">
          {messages.map((msg) => (
            <div key={msg.id} className={`rounded-lg p-3 text-xs leading-relaxed border ${
              msg.role === 'user' 
                ? 'bg-white/5 border-white/5' 
                : 'bg-slate-800/40 border-white/10'
            }`}>
              <span className={`font-bold uppercase block mb-1 ${
                msg.role === 'user' ? 'text-primary' : 'text-blue-400'
              }`}>
                {msg.role === 'user' ? 'User' : 'Claude-Sonnet-4.6'}
              </span>
              <div className="text-slate-200">
                {msg.content}
              </div>
              {msg.role === 'assistant' && msg.type === 'action_result' && (
                <div className="mt-2 font-mono text-[10px] text-slate-400 break-all leading-tight">
                  {msg.status === 'success' && <span className="text-green-500 mr-1">✓</span>}
                  {msg.status === 'error' && <span className="text-red-500 mr-1">✗</span>}
                  {msg.status === 'running' && <span className="text-primary mr-1 animate-pulse">●</span>}
                  &gt; tool_use: {msg.details}
                </div>
              )}
            </div>
          ))}
        </div>

        {/* Input Area */}
        <div className="p-4 border-t border-border-tech shrink-0 bg-black/20">
          <div className="relative">
            <input
              type="text"
              value={input}
              onChange={(e) => setInput(e.target.value)}
              onKeyDown={(e) => e.key === 'Enter' && handleSend()}
              placeholder="输入操作指令..."
              className="w-full bg-white/5 border border-border-tech rounded-md py-3 px-4 text-sm focus:outline-none focus:border-primary transition-colors text-slate-200"
            />
            <button 
              onClick={handleSend}
              disabled={!input.trim()}
              className="absolute right-2 top-2 p-1.5 bg-primary text-black rounded hover:bg-orange-400 disabled:opacity-50 disabled:bg-slate-300 transition-colors"
            >
              <Send size={20} />
            </button>
          </div>
          <div className="flex justify-between mt-4 items-center">
             <span className="text-[10px] text-slate-500 font-mono">v1.0.4-stable</span>
          </div>
        </div>
      </div>
    </div>
  );
}
