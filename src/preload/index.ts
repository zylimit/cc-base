import { contextBridge, ipcRenderer } from 'electron'

export type ApiSchema = {
  // Placeholder for now - will be expanded in Phase 3+
  ping: () => Promise<string>
}

const api: ApiSchema = {
  ping: () => ipcRenderer.invoke('ping')
}

contextBridge.exposeInMainWorld('api', api)