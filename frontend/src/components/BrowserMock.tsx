import { ArrowLeft, ArrowRight, RotateCw, Lock, LayoutGrid, Plus, FileSpreadsheet, Box, HardDrive } from 'lucide-react';

export default function BrowserMock() {
  return (
    <div className="flex-1 flex flex-col bg-white h-full overflow-hidden border-l border-border-tech">
      {/* Fake Browser Chrome / Address Bar */}
      <div className="h-12 bg-slate-100 border-b border-slate-300 flex items-center px-4 shrink-0 space-x-4 z-10">
        <div className="flex items-center space-x-3 text-slate-500">
          <div className="flex gap-1.5 mr-2">
            <div className="w-3 h-3 rounded-full bg-red-400"></div>
            <div className="w-3 h-3 rounded-full bg-yellow-400"></div>
            <div className="w-3 h-3 rounded-full bg-green-400"></div>
          </div>
          <ArrowLeft size={16} className="cursor-not-allowed opacity-50" />
          <ArrowRight size={16} className="cursor-not-allowed opacity-50" />
          <RotateCw size={16} className="cursor-pointer hover:text-slate-700 transition-colors" />
        </div>
        <div className="flex-1 max-w-2xl bg-white h-8 border border-slate-300 rounded flex items-center px-3 text-xs text-slate-600 font-mono shadow-sm">
          <Lock size={12} className="text-slate-400 mr-2" />
          <span>https://datalink.internal.huawei.com/app/builder</span>
        </div>
      </div>

      {/* Fake Datalink Interface */}
      <div className="flex-1 flex bg-slate-50 text-slate-900 overflow-hidden relative">
        <div className="absolute top-0 left-0 w-full h-full opacity-10 pointer-events-none" style={{ backgroundImage: 'radial-gradient(#000 0.5px, transparent 0.5px)', backgroundSize: '20px 20px' }}></div>
        {/* Mock Datalink Sidebar */}
        <div className="w-56 bg-white border-r border-neutral-200 flex flex-col">
          <div className="p-4 border-b border-neutral-100 font-medium text-sm flex items-center">
            <LayoutGrid size={16} className="mr-2 text-blue-600" />
            节点组件库
          </div>
          <div className="p-2 space-y-1 overflow-y-auto">
            {['空白页面', '文件传入', '表单数据', '人工任务'].map((item, idx) => (
              <div key={idx} className="px-3 py-2 text-xs hover:bg-blue-50 cursor-pointer rounded flex items-center text-neutral-700">
                {idx === 1 ? <FileSpreadsheet size={14} className="mr-2 text-green-600" /> : 
                 idx === 2 ? <Box size={14} className="mr-2 text-purple-600" /> : 
                 <HardDrive size={14} className="mr-2 text-neutral-500" />}
                {item}
              </div>
            ))}
          </div>
        </div>

        {/* Mock Datalink Canvas/Content area */}
        <div className="flex-1 p-8 overflow-y-auto z-10 flex flex-col">
          <div className="max-w-4xl mx-auto w-full bg-white rounded-lg shadow-sm border border-slate-300 p-6 flex flex-col gap-3 relative ring-2 ring-orange-500 ring-offset-4 ring-offset-slate-50">
            <div className="flex items-center justify-between mb-6 pb-4 border-b border-neutral-100">
              <h2 className="text-lg font-medium">Box Information (New Node)</h2>
              <div className="space-x-2">
                <button className="px-3 py-1.5 text-xs text-neutral-600 border border-neutral-300 rounded hover:bg-neutral-50">Cancel</button>
                <button className="px-3 py-1.5 text-xs text-white bg-blue-600 rounded hover:bg-blue-700">Save Node</button>
              </div>
            </div>

            <div className="space-y-6">
               {/* Mock Form Fields */}
               <div className="grid grid-cols-2 gap-6">
                 <div className="space-y-1.5">
                   <label className="text-xs font-medium text-neutral-700 flex items-center">
                     DU Boundary <span className="text-red-500 ml-1">*</span>
                   </label>
                   <input type="text" className="w-full border border-neutral-300 rounded px-3 py-2 text-sm focus:outline-none focus:border-blue-500 focus:ring-1 focus:ring-blue-500" placeholder="Enter boundary ID" />
                 </div>
                 <div className="space-y-1.5">
                   <label className="text-xs font-medium text-neutral-700 block">City</label>
                   <select className="w-full border border-neutral-300 rounded px-3 py-2 text-sm focus:outline-none focus:border-blue-500 focus:ring-1 focus:ring-blue-500 bg-white">
                     <option>Select a city</option>
                     <option>Beijing</option>
                     <option>Shanghai</option>
                     <option>Shenzhen</option>
                   </select>
                 </div>
                 <div className="space-y-1.5 col-span-2">
                   <label className="text-xs font-medium text-neutral-700 block">Description</label>
                   <textarea className="w-full border border-neutral-300 rounded px-3 py-2 text-sm focus:outline-none focus:border-blue-500 focus:ring-1 focus:ring-blue-500" rows={3} placeholder="Optional details..."></textarea>
                 </div>
               </div>
            </div>

            {/* AI Control overlay hint (invisible during normal use, maybe just a little badge) */}
            <div className="absolute top-4 right-4 bg-orange-100 text-orange-800 text-[10px] px-2 py-1 rounded-full flex items-center font-medium border border-orange-200">
              <span className="w-1.5 h-1.5 bg-orange-500 rounded-full animate-pulse mr-1.5"></span>
              MCP Bridge Active
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
