import { useState, useEffect } from 'react'

declare global {
  interface Window {
    api: {
      ping: () => Promise<string>
    }
  }
}

function App() {
  const [status, setStatus] = useState<string>('Initializing...')

  useEffect(() => {
    window.api.ping().then((res: string) => {
      setStatus(res)
    }).catch(() => {
      setStatus('API not connected')
    })
  }, [])

  return (
    <div style={{
      height: '100%',
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'center',
      flexDirection: 'column',
      gap: '16px'
    }}>
      <div style={{
        width: '48px',
        height: '48px',
        borderRadius: '12px',
        background: '#F97316',
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        fontSize: '24px'
      }}>
        ⚡
      </div>
      <h1 style={{ fontSize: '20px', fontWeight: 600 }}>DataLink Automation</h1>
      <p style={{ color: '#A1A1AA', fontSize: '14px' }}>{status}</p>
    </div>
  )
}

export default App