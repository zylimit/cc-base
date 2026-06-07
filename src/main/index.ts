import { app, BrowserWindow, shell, ipcMain } from 'electron'
import { join } from 'path'
import { electronApp, optimizer, is } from '@electron-toolkit/utils'
import { BrowserViewManager } from './browser-view'
import { registerBrowserIpcHandlers } from './ipc-handlers/browser'

// BrowserViewManager instance (set after window creation)
let browserViewManager: BrowserViewManager | null = null

function createWindow(): BrowserWindow {
  const mainWindow = new BrowserWindow({
    width: 1440,
    height: 900,
    minWidth: 1200,
    minHeight: 700,
    frame: false,
    titleBarStyle: 'hidden',
    webPreferences: {
      preload: join(__dirname, '../preload/index.js'),
      sandbox: false,
      contextIsolation: true,
      nodeIntegration: false
    }
  })

  mainWindow.webContents.setWindowOpenHandler((details) => {
    shell.openExternal(details.url)
    return { action: 'deny' }
  })

  if (is.dev && process.env['ELECTRON_RENDERER_URL']) {
    mainWindow.loadURL(process.env['ELECTRON_RENDERER_URL'])
  } else {
    mainWindow.loadFile(join(__dirname, '../renderer/index.html'))
  }

  return mainWindow
}

app.whenReady().then(() => {
  // Enable remote debugging port for Chrome DevTools
  app.commandLine.appendSwitch('remote-debugging-port', '9222')

  electronApp.setAppUserModelId('com.datalink.automation')

  app.on('browser-window-created', (_, window) => {
    optimizer.watchWindowShortcuts(window)
  })

  // IPC ping handler for connection test
  ipcMain.handle('ping', () => 'Electron connected')

  const mainWindow = createWindow()

  // Create BrowserViewManager and register IPC handlers
  const sidebarWidth = 240
  const toolbarHeight = 48
  browserViewManager = new BrowserViewManager(mainWindow, {
    x: sidebarWidth,
    y: toolbarHeight,
    width: mainWindow.getBounds().width - sidebarWidth,
    height: mainWindow.getBounds().height - toolbarHeight
  })
  browserViewManager.create()

  registerBrowserIpcHandlers(browserViewManager, mainWindow)

  app.on('activate', function () {
    if (BrowserWindow.getAllWindows().length === 0) createWindow()
  })
})

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') {
    app.quit()
  }
})