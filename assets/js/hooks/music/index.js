// Provider-neutral music hooks for the host screen.
//
//   * "MusicPlayer"  — plays the current round's song. Entirely
//     attribute-driven: HostLive renders `data-provider` (which module below),
//     `data-config` (the provider's `client_config/1` as JSON), `data-uri` (the
//     song to be playing *right now*, or "" to pause) and `data-round` (the
//     round's identity), and the hook reconciles real playback toward them. A
//     new round restarts the song even when its URI matches the previous
//     round's. Within a round the song can change and change back (head to
//     head, the TV switches between a matchup's two songs): each song picks
//     up where it left off, never from the top again, and a song's first
//     play in a round starts `data-start-ms` in (0 unless the round says
//     otherwise). It reports back with pushed events: "playback_ready",
//     "song_ended" and "playback_error" (so the LiveView can show a banner
//     instead of the game silently dying).
//
//     While `data-background="true"` the song is the host's background track,
//     played under the lobby and the song-picking: quietly (`setVolume`), on
//     a loop (it starts again when it ends, and "song_ended" is not pushed),
//     and without a banner if the browser won't start sound until the page
//     has been clicked (it starts at the first click instead).
//
// A provider module is a plain object (see ./mock.js for the smallest one):
//
//   create(ctx) -> { init(), play(uri, fromMs), pause(), updateConfig(config), destroy() }
//
// where `play` starts the song `fromMs` milliseconds in (0: from the top).
//
// where `ctx` is `{el, videoEl, config, onReady(), onNotReady(), onEnded(), onError(reason, message)}`
// and a module may also have `setVolume(level)` (0 to 1), which the hook calls
// before it starts a song: quiet for the background track, full for the game's.
// `onNotReady()` tells the hook the player lost its device: it holds off
// playing until the next `onReady()`, which then plays whatever is wanted by
// then (so a round that advanced while the device was down is not lost).
// Modules own everything provider-specific (SDK loading, how "ended" is
// detected); this file owns the reconciliation logic every provider shares.

import spotify from "./spotify"
import youtube from "./youtube"
import mock from "./mock"

const PROVIDERS = {spotify, youtube, mock}

// How loud the background track is, against the game's songs.
const BACKGROUND_VOLUME = 0.25
const SONG_VOLUME = 1

function parseConfig(el) {
  try { return JSON.parse(el.dataset.config || "{}") } catch (_e) { return {} }
}

const MusicPlayer = {
  mounted() {
    this.wantUri = this.el.dataset.uri || ""
    this.round = this.el.dataset.round || ""
    this.background = this.el.dataset.background === "true"
    this.currentUri = null
    // Where each song of this round got to: uri -> ms into it, kept when the
    // round moves to its other song, so coming back resumes it.
    this.positions = {}
    // The song playing now, from where, and since when (for its position).
    this.playingFrom = null
    this.ready = false
    // The browser refused to start the background track without a click.
    this.blocked = false

    this.retryAfterClick = () => {
      if (!this.blocked) return
      this.blocked = false
      this.currentUri = null
      this.sync()
    }
    document.addEventListener("pointerdown", this.retryAfterClick)

    const provider = PROVIDERS[this.el.dataset.provider]
    if (!provider) {
      this.pushEvent("playback_error", {reason: "unknown_provider"})
      return
    }

    this.player = provider.create({
      el: this.el,
      videoEl: this.el.querySelector("[data-music-video]"),
      config: parseConfig(this.el),
      onReady: () => {
        this.ready = true
        this.pushEvent("playback_ready", {})
        this.sync()
      },
      onNotReady: () => { this.ready = false },
      onEnded: () => {
        if (this.currentUri) delete this.positions[this.currentUri]
        this.playingFrom = null
        this.currentUri = null
        if (this.background) {
          this.sync()
        } else {
          this.pushEvent("song_ended", {})
        }
      },
      onError: (reason, message) => {
        if (this.background && reason === "autoplay_blocked") {
          this.blocked = true
          return
        }
        this.pushEvent("playback_error", {reason, message: message || ""})
      },
    })

    Promise.resolve(this.player.init()).catch((e) => {
      this.pushEvent("playback_error", {reason: "init_failed", message: (e && e.message) || ""})
    })
  },

  updated() {
    if (!this.player) return

    // Pick up refreshed credentials, and a changed target song or round.
    this.player.updateConfig(parseConfig(this.el))
    const want = this.el.dataset.uri || ""
    const round = this.el.dataset.round || ""
    this.background = this.el.dataset.background === "true"
    if (round !== this.round) {
      // A new round always (re)starts its song, even a repeat of the last one.
      this.round = round
      this.wantUri = want
      this.positions = {}
      this.playingFrom = null
      if (want) this.currentUri = null
      this.sync()
    } else if (want !== this.wantUri) {
      this.wantUri = want
      this.sync()
    }
  },

  destroyed() {
    document.removeEventListener("pointerdown", this.retryAfterClick)
    if (this.player) {
      try { this.player.destroy() } catch (_e) {}
    }
  },

  // Reconcile actual playback toward the desired `wantUri`.
  sync() {
    if (!this.ready) return
    if (this.wantUri) {
      if (this.wantUri !== this.currentUri) {
        this.keepPosition()
        this.currentUri = this.wantUri
        const from = this.background ? 0 : this.resumeAt(this.wantUri)
        this.playingFrom = {uri: this.wantUri, from, at: Date.now()}
        if (this.player.setVolume) this.player.setVolume(this.background ? BACKGROUND_VOLUME : SONG_VOLUME)
        this.player.play(this.wantUri, from)
      }
    } else if (this.currentUri !== null) {
      // Only pause if we started something (pausing an idle player makes some
      // SDKs emit a spurious error).
      this.keepPosition()
      this.currentUri = null
      this.player.pause()
    }
  },

  // Note how far the song playing got, before it gives way to another.
  keepPosition() {
    const playing = this.playingFrom
    if (playing && playing.uri === this.currentUri) {
      this.positions[playing.uri] = playing.from + (Date.now() - playing.at)
    }
    this.playingFrom = null
  },

  // Where a song picks up: where it left off this round, else the round's
  // starting point.
  resumeAt(uri) {
    if (uri in this.positions) return this.positions[uri]
    const start = parseInt(this.el.dataset.startMs || "0", 10)
    return Number.isNaN(start) || start < 0 ? 0 : start
  },
}

export default {MusicPlayer}
