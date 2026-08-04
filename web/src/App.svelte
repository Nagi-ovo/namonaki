<script>
  import { onMount } from 'svelte'
  import Row from './lib/Row.svelte'
  import { connectToRelay } from './lib/relay.js'

  /** Past this the browser source is just holding memory it will never paint. */
  const MAX_ROWS = 200

  const showsStatus = new URLSearchParams(location.search).get('showDebugMessages') === 'true'

  let rows = $state([])
  let feed = $state(null)
  let nextKey = 0

  const append = (row) => {
    rows.push({ key: nextKey++, ...row })
    if (rows.length > MAX_ROWS) rows.splice(0, rows.length - MAX_ROWS)
  }

  const applyStyle = (style) => {
    const root = document.documentElement
    if (typeof style.fontSize === 'number') {
      root.style.setProperty('--nmk-font-size', `${style.fontSize}px`)
    }
    if (typeof style.nameOpacity === 'number') {
      root.style.setProperty('--nmk-name-opacity', String(style.nameOpacity))
    }
    if (typeof style.backdropAlpha === 'number') {
      root.style.setProperty('--nmk-backdrop-alpha', String(style.backdropAlpha))
    }
    if (typeof style.lineHeight === 'number') {
      root.style.setProperty('--nmk-line-height', String(style.lineHeight))
    }
    if (typeof style.preset === 'string') {
      root.dataset.preset = style.preset
    }
  }

  onMount(() =>
    connectToRelay({
      onMessage: (payload) => {
        if (payload.type === 'deleteSuperChat') {
          const removed = new Set(payload.data?.ids ?? [])
          rows = rows.filter((row) => !removed.has(row.message?.data?.id))
          return
        }
        // Free gifts arrive constantly and would bury the conversation. The HUD drops
        // them too.
        if (payload.type === 'gift' && !(payload.data?.totalCoin > 0)) return
        append({ message: payload })
      },
      onStyle: applyStyle,
      onStatus: (text) => {
        if (showsStatus && text) append({ status: text })
      },
    })
  )

  // Stick to the newest message unless the viewer has scrolled away from the bottom.
  // An OBS browser source never scrolls, so in practice this always follows.
  let following = true
  const onScroll = () => {
    if (!feed) return
    following = feed.scrollHeight - feed.scrollTop - feed.clientHeight < 40
  }

  const stickToBottom = () => {
    if (feed && following) feed.scrollTop = feed.scrollHeight
  }

  $effect(() => {
    rows.length
    stickToBottom()
  })
</script>

<div class="feed" bind:this={feed} onscroll={onScroll}>
  {#each rows as row (row.key)}
    {#if row.status}
      <div class="status">{row.status}</div>
    {:else}
      <Row message={row.message} onGrow={stickToBottom} />
    {/if}
  {/each}
</div>
