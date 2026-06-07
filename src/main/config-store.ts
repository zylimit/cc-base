import Store from 'electron-store'
import { app } from 'electron'
import { join } from 'path'

/**
 * electron-store 10.x 是 ESM-only 包（package.json "type": "module"），
 * electron-vite 默认把 main 进程编译为 CJS bundle，运行时通过 require()
 * 加载 ESM 模块会得到 `{ __esModule: true, default: Store }`，因此默认 import
 * 拿到的实际上是 namespace 对象而非构造函数。
 *
 * 下面这一行做 CJS/ESM 互操作兜底：优先取 .default，回落到 import 本身，
 * 兼容两种加载形态。`Store` 仍保留为类型使用，`StoreCtor` 是 runtime 构造函数。
 * 当未来 main 进程切到 ESM 输出后可移除。
 */
const StoreCtor = ((Store as unknown as { default?: typeof Store }).default
  ?? Store) as typeof Store

/**
 * 持久化存储的结构定义。
 *
 * - apiKey: Google AI Studio API Key（通过 encryptionKey 做磁盘混淆存储）
 * - userDataDir: 用户数据根目录（默认使用 app.getPath('userData')）
 * - workflowDir: 作业流 JSON 存放目录（默认 userDataDir/workflows）
 */
interface StoreSchema {
  apiKey: string
  userDataDir: string
  workflowDir: string
}

/**
 * 用于 electron-store 的 encryptionKey 选项。
 *
 * 注意：electron-store 的"加密"是 obscurity 级别（aes-256-cbc + 密钥硬编码在
 * 源码中可被反编译获取），并非真正的安全加密。其主要作用是：
 *   1. 防止用户直接编辑明文配置文件
 *   2. 保证文件完整性（被改动后无法解密会重置为默认值）
 * 对真正的敏感数据应在使用时再做应用层加密。
 */
const ENCRYPTION_KEY = 'datalink-automation-store-v1'

let storeInstance: Store<StoreSchema> | null = null

/**
 * 懒加载 Store 实例。
 *
 * 必须懒加载是因为 app.getPath('userData') 只能在 app.ready 之后调用，
 * 而模块顶层执行可能早于 app.ready。所有公开 API 都通过 getStore() 间接访问，
 * 确保第一次实际读写时 app 已就绪。
 */
function getStore(): Store<StoreSchema> {
  if (storeInstance) {
    return storeInstance
  }

  const defaultUserDataDir = app.getPath('userData')
  const defaultWorkflowDir = join(defaultUserDataDir, 'workflows')

  storeInstance = new StoreCtor<StoreSchema>({
    encryptionKey: ENCRYPTION_KEY,
    defaults: {
      apiKey: '',
      userDataDir: defaultUserDataDir,
      workflowDir: defaultWorkflowDir
    }
  })

  return storeInstance
}

/**
 * 配置存储的单例对象。所有方法均为同步调用。
 *
 * 用法示例：
 * ```ts
 * import { configStore } from './config-store'
 * configStore.setApiKey('AIza...')
 * const key = configStore.getApiKey()
 * ```
 */
export const configStore = {
  /**
   * 获取 API Key。未配置时返回 null（空字符串被视为未配置）。
   */
  getApiKey(): string | null {
    const key = getStore().get('apiKey')
    return key.length > 0 ? key : null
  },

  /**
   * 设置 API Key。传入空字符串等同于清空（后续 getApiKey 返回 null）。
   */
  setApiKey(key: string): void {
    getStore().set('apiKey', key)
  },

  /**
   * 获取用户数据目录。未显式设置时返回 app.getPath('userData') 默认值。
   */
  getUserDataDir(): string {
    return getStore().get('userDataDir')
  },

  /**
   * 设置用户数据目录。调用方应自行确保目录存在或可创建。
   */
  setUserDataDir(dir: string): void {
    getStore().set('userDataDir', dir)
  },

  /**
   * 获取作业流存储目录。未显式设置时返回 userDataDir/workflows 默认值。
   */
  getWorkflowDir(): string {
    return getStore().get('workflowDir')
  },

  /**
   * 设置作业流存储目录。调用方应自行确保目录存在或可创建。
   */
  setWorkflowDir(dir: string): void {
    getStore().set('workflowDir', dir)
  }
}
