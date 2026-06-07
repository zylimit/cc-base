import { ApiSchema } from './index'

declare global {
  interface Window {
    api: ApiSchema
  }
}