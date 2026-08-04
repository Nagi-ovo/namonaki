const RECONNECT_CEILING_MS = 10_000

/**
 * Connects to the app's local relay and hands every payload to the caller.
 *
 * The relay only ever pushes; nothing is sent back up. The token comes from the URL the
 * app generates ("copy OBS address") and is unrelated to the Bilibili identity code.
 */
export function connectToRelay({ onMessage, onStyle, onStatus }) {
  const token = new URLSearchParams(location.search).get('token') ?? ''
  const endpoint = `ws://${location.host}/events?token=${encodeURIComponent(token)}`

  let socket = null
  let attempt = 0
  let closed = false

  const open = () => {
    if (closed) return
    socket = new WebSocket(endpoint)

    socket.addEventListener('open', () => {
      attempt = 0
    })

    socket.addEventListener('message', (event) => {
      let payload
      try {
        payload = JSON.parse(event.data)
      } catch {
        console.warn('Namonaki relay message parse failed')
        return
      }
      if (!payload || typeof payload.type !== 'string') return

      switch (payload.type) {
        case 'style':
          onStyle?.(payload.data ?? {})
          break
        case 'debug':
          onStatus?.(payload.data?.content ?? '')
          break
        default:
          onMessage?.(payload)
      }
    })

    socket.addEventListener('close', () => {
      if (closed) return
      attempt += 1
      setTimeout(open, Math.min(500 * attempt, RECONNECT_CEILING_MS))
    })

    socket.addEventListener('error', () => socket?.close())
  }

  open()

  return () => {
    closed = true
    socket?.close()
  }
}

/** Mirrors `DanmakuAuthor.rank` on the Swift side. */
export function rankOf(data) {
  if (data.authorType === 3) return 'owner'
  if (data.authorType === 2) return 'moderator'
  if (data.authorType === 1 || data.privilegeType) return 'guard'
  return 'viewer'
}

export function guardLevelName(privilegeType) {
  switch (privilegeType) {
    case 1:
      return '总督'
    case 2:
      return '提督'
    case 3:
      return '舰长'
    default:
      return '大航海'
  }
}
