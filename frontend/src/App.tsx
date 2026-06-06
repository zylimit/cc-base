import { useState } from 'react';
import Sidebar from './components/Sidebar';
import BrowserMock from './components/BrowserMock';
import WorkflowModal from './components/WorkflowModal';
import SettingsModal from './components/SettingsModal';
import ErrorModal from './components/ErrorModal';
import { Workflow, ChatMessage } from './types';

// Mock initial data based on screenshots
const initialWorkflows: Workflow[] = [
  { id: '1', name: 'Box Information 配置', steps: 5, lastRun: '2小时前', status: 'success' },
  { id: '2', name: 'New Duct 配置', steps: 3, lastRun: '昨天', status: 'idle' },
  { id: '3', name: 'DU Export 配置', steps: 7, lastRun: '3天前', status: 'success' },
];

const initialChat: ChatMessage[] = [
  { id: 'msg1', role: 'system', content: 'Datalink AI Automation 已启动。MCP 浏览器桥接连接成功。', timestamp: '10:00' },
  { id: 'msg2', role: 'user', content: '帮我新建一个 Box Information 节点', timestamp: '10:01' },
  { id: 'msg3', role: 'assistant', content: '正在执行...', timestamp: '10:01', type: 'action_result', status: 'running', details: 'Navigating & locating elements' },
];

export default function App() {
  const [isRecording, setIsRecording] = useState(false);
  const [modals, setModals] = useState({
    workflow: false,
    settings: false,
    error: false,
  });
  
  const [workflows] = useState<Workflow[]>(initialWorkflows);
  const [messages, setMessages] = useState<ChatMessage[]>(initialChat);

  const openModal = (name: keyof typeof modals) => {
    setModals({ ...modals, [name]: true });
  };

  const closeModal = (name: keyof typeof modals) => {
    setModals({ ...modals, [name]: false });
  };

  const handleSendMessage = (content: string) => {
    const newMessage: ChatMessage = {
      id: Date.now().toString(),
      role: 'user',
      content,
      timestamp: new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })
    };
    setMessages([...messages, newMessage]);
    
    // Simulate AI response
    setTimeout(() => {
      setMessages(prev => [...prev, {
        id: (Date.now() + 1).toString(),
        role: 'assistant',
        content: '这是一个模拟演示响应。在真实版本中，Claude 会通过 MCP 驱动右侧浏览器执行相关操作。',
        timestamp: new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }),
        type: 'action_result',
        status: 'error',
        details: '操作失败：演示模式模拟报错。'
      }]);
      // Show error modal for demonstration after a delay
      setTimeout(() => openModal('error'), 1000);
    }, 1000);
  };

  return (
    <div className="flex h-screen w-full bg-neutral-950 font-sans antialiased text-neutral-200 overflow-hidden select-none">
      <Sidebar 
        onOpenSettings={() => openModal('settings')}
        onOpenWorkflows={() => openModal('workflow')}
        isRecording={isRecording}
        onToggleRecord={() => setIsRecording(!isRecording)}
        messages={messages}
        onSendMessage={handleSendMessage}
      />
      <BrowserMock />

      {modals.workflow && (
        <WorkflowModal 
          onClose={() => closeModal('workflow')} 
          workflows={workflows}
          onPlay={(wf) => console.log('Playing', wf.name)}
          onImport={() => console.log('Import clicked')}
        />
      )}
      {modals.settings && (
        <SettingsModal onClose={() => closeModal('settings')} />
      )}
      {modals.error && (
        <ErrorModal onClose={() => closeModal('error')} />
      )}
    </div>
  );
}

