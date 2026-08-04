<script>
  import { rankOf, guardLevelName } from './relay.js'

  // `onGrow` fires when a late image changes the row's height, so the feed can re-stick
  // to the bottom.
  const { message, onGrow } = $props()

  const data = $derived(message.data ?? {})
  const kind = $derived(message.type)
  const highlighted = $derived(kind === 'superChat' || kind === 'member')
  const rank = $derived(highlighted ? 'owner' : rankOf(data))

  const memberText = $derived.by(() => {
    const count = data.num > 1 ? `${data.num}${data.unit ?? ''}` : ''
    return `　开通了${count}${guardLevelName(data.privilegeType)}`
  })
</script>

<div class="row row--{kind}" class:row--highlight={highlighted}>
  {#if data.avatarUrl}
    <img class="avatar" src={data.avatarUrl} alt="" />
  {:else}
    <span class="avatar avatar--empty"></span>
  {/if}

  <div class="body">
    <span class="name" data-rank={rank}>{data.authorName}</span>

    {#if kind === 'text'}
      <span class="colon">：</span>
      {#if data.emoticon}
        <!-- A full-image emote replaces the text, which is only its [name]. -->
        <img class="emote" src={data.emoticon} alt={data.content} onload={onGrow} />
      {:else}
        <span class="text">{data.content}</span>
      {/if}
    {:else if kind === 'superChat'}
      <span class="price">¥{data.price}</span>
      <div class="text">{data.content}</div>
    {:else if kind === 'member'}
      <!-- On one line on purpose: Svelte keeps the newline and it shows up as a gap. -->
      <span class="text">{memberText}</span>
    {:else if kind === 'gift'}
      <span class="text">　送出 {data.giftName} ×{data.num}</span>
      {#if data.giftIconUrl}
        <img class="gift-icon" src={data.giftIconUrl} alt="" onload={onGrow} />
      {/if}
    {/if}
  </div>
</div>
