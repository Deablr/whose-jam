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
    let volume = 1

    const stopAudio = () => {
      if (!audio) return
      audio.onended = null
      audio.onerror = null
      audio.pause()
      audio = null
    }

    const fakeEnd = (uri) => {
      clearTimeout(timer)
      timer = setTimeout(() => ctx.onEnded(uri), config.track_ms || 5000)
    }

    return {
      init() { readyTimer = setTimeout(() => ctx.onReady(), 0) },

      play(uri, fromMs = 0) {
        clearTimeout(timer)
        stopAudio()
        const src = config.audio && config.audio[uri]
        if (!src) return fakeEnd(uri)

        const song = new Audio(src)
        song.volume = volume
        if (fromMs > 0) song.currentTime = fromMs / 1000
        audio = song
        song.onended = () => { if (audio === song) { audio = null; ctx.onEnded(uri) } }
        song.onerror = () => { if (audio === song) { audio = null; fakeEnd(uri) } }
        song.play().catch(() => { if (audio === song) { stopAudio(); fakeEnd(uri) } })
      },

      pause() {
        clearTimeout(timer)
        stopAudio()
      },

      setVolume(level) {
        volume = Math.min(1, Math.max(0, level))
        if (audio) audio.volume = volume
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
