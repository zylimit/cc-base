import { contextBridge, ipcRenderer } from 'electron'

export interface ApiSchema {
  ping: () => Promise<string>
}

const api: ApiSchema = {
  ping: () => ipcRenderer.invoke('ping')
}

contextBridge.exposeInMainWorld('api', api)