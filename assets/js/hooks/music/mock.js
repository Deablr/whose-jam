// Mock provider player (dev/test only). Plays no audio: a "song" just ends
// after `config.track_ms`, so a whole game can be played without any account.

export default {
  create(ctx) {
    let config = ctx.config
    let timer = null
    let readyTimer = null

    return {
      init() { readyTimer = setTimeout(() => ctx.onReady(), 0) },

      play(_uri) {
        clearTimeout(timer)
        timer = setTimeout(() => ctx.onEnded(), config.track_ms || 5000)
      },

      pause() { clearTimeout(timer) },
      updateConfig(next) { config = next },

      destroy() {
        clearTimeout(timer)
        clearTimeout(readyTimer)
      },
    }
  },
}
