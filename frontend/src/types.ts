export interface Workflow {
  id: string;
  name: string;
  steps: number;
  lastRun?: string;
  status: 'success' | 'idle' | 'failed';
}

export interface ChatMessage {
  id: string;
  role: 'user' | 'assistant' | 'system';
  content: string;
  timestamp: string;
  status?: 'success' | 'error' | 'running';
  type?: 'text' | 'action_result';
  details?: string;
}
