// Mock provider player (dev/test only). Most of its songs are made up and
// play nothing: such a "song" just ends after `config.track_ms`, so a whole
// game can be played without any account. A few are real (NCS) songs: when
// `config.audio` names a file for the URI, it is played for real and ends
// when it ends; if it can't be played (not copied in, or the browser won't),
// it falls back to the made-up kind.

export default {
  create(ctx) {
    let config = ctx.config
    let timer = null
    let readyTimer = null
    let audio = null

    const stopAudio = () => {
      if (!audio) return
      audio.onended = null
      audio.onerror = null
      audio.pause()
      audio = null
    }

    const fakeEnd = () => {
      clearTimeout(timer)
      timer = setTimeout(() => ctx.onEnded(), config.track_ms || 5000)
    }

    return {
      init() { readyTimer = setTimeout(() => ctx.onReady(), 0) },

      play(uri) {
        clearTimeout(timer)
        stopAudio()
        const src = config.audio && config.audio[uri]
        if (!src) return fakeEnd()

        const song = new Audio(src)
        audio = song
        song.onended = () => { if (audio === song) { audio = null; ctx.onEnded() } }
        song.onerror = () => { if (audio === song) { audio = null; fakeEnd() } }
        song.play().catch(() => { if (audio === song) { stopAudio(); fakeEnd() } })
      },

      pause() {
        clearTimeout(timer)
        stopAudio()
      },

      updateConfig(next) { config = next },

      destroy() {
        clearTimeout(timer)
        clearTimeout(readyTimer)
        stopAudio()
      },
    }
  },
}
