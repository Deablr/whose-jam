// Provider-neutral music hooks for the host screen.
//
//   * "MusicPlayer"  — plays the current round's song. Entirely
//     attribute-driven: HostLive renders `data-provider` (which module below),
//     `data-config` (the provider's `client_config/1` as JSON), `data-uri` (the
//     song to be playing *right now*, or "" to pause) and `data-round` (the
//     round's identity), and the hook reconciles real playback toward them. A
//     new round restarts the song even when its URI matches the previous
//     round's. It reports back with pushed events: "playback_ready",
//     "song_ended" and "playback_error" (so the LiveView can show a banner
//     instead of the game silently dying).
//
// A provider module is a plain object (see ./mock.js for the smallest one):
//
//   create(ctx) -> { init(), play(uri), pause(), updateConfig(config), destroy() }
//
// where `ctx` is `{el, videoEl, config, onReady(), onNotReady(), onEnded(), onError(reason, message)}`.
// `onNotReady()` tells the hook the player lost its device: it holds off
// playing until the next `onReady()`, which then plays whatever is wanted by
// then (so a round that advanced while the device was down is not lost).
// Modules own everything provider-specific (SDK loading, how "ended" is
// detected); this file owns the reconciliation logic every provider shares.

import spotify from "./spotify"
import mock from "./mock"

const PROVIDERS = {spotify, mock}

function parseConfig(el) {
  try { return JSON.parse(el.dataset.config || "{}") } catch (_e) { return {} }
}

const MusicPlayer = {
  mounted() {
    this.wantUri = this.el.dataset.uri || ""
    this.round = this.el.dataset.round || ""
    this.currentUri = null
    this.ready = false

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
        this.currentUri = null
        this.pushEvent("song_ended", {})
      },
      onError: (reason, message) => {
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
    if (round !== this.round) {
      // A new round always (re)starts its song, even a repeat of the last one.
      this.round = round
      this.wantUri = want
      if (want) this.currentUri = null
      this.sync()
    } else if (want !== this.wantUri) {
      this.wantUri = want
      this.sync()
    }
  },

  destroyed() {
    if (this.player) {
      try { this.player.destroy() } catch (_e) {}
    }
  },

  // Reconcile actual playback toward the desired `wantUri`.
  sync() {
    if (!this.ready) return
    if (this.wantUri) {
      if (this.wantUri !== this.currentUri) {
        this.currentUri = this.wantUri
        this.player.play(this.wantUri)
      }
    } else if (this.currentUri !== null) {
      // Only pause if we started something (pausing an idle player makes some
      // SDKs emit a spurious error).
      this.currentUri = null
      this.player.pause()
    }
  },
}

export default {MusicPlayer}
