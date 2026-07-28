// TV-screen hooks. Owned by the TV/host agent.
//
// Exports one LiveView hook:
//
//   * "SpotifyPlayer" — drives the Spotify Web Playback SDK on the TV browser
//     using the host's Premium OAuth token. It is entirely attribute-driven:
//     the LiveView renders `data-token` (host access token) and `data-uri`
//     (the track to play right now, or "" to pause) on the hook element, and
//     the hook reconciles the real playback state toward those attributes.
//     End-of-song is reported back to the server via a pushed "song_ended"
//     event; any SDK/token failure pushes "playback_error" so the LiveView can
//     surface a visible banner instead of silently dying.
//
// The "Countdown" hook lives in hooks/player.js and is registered globally, so
// TV templates using phx-hook="Countdown" pick it up from there (its mm:ss +
// stop-at-zero rendering is fine on the TV).

const SDK_SRC = "https://sdk.scdn.co/spotify-player.js"

// Load the Web Playback SDK exactly once for the whole page. Resolves when the
// global `Spotify` object is ready to use.
let sdkPromise = null
function loadSpotifySDK() {
  if (window.Spotify) return Promise.resolve()
  if (sdkPromise) return sdkPromise

  sdkPromise = new Promise((resolve) => {
    // The SDK calls this global when it finishes initializing.
    const prev = window.onSpotifyWebPlaybackSDKReady
    window.onSpotifyWebPlaybackSDKReady = () => {
      if (typeof prev === "function") { try { prev() } catch (_e) {} }
      resolve()
    }

    if (!document.getElementById("spotify-sdk-script")) {
      const script = document.createElement("script")
      script.id = "spotify-sdk-script"
      script.src = SDK_SRC
      script.async = true
      document.head.appendChild(script)
    }
  })

  return sdkPromise
}

const SpotifyPlayer = {
  mounted() {
    this.token = this.el.dataset.token || null
    this.wantUri = this.el.dataset.uri || ""
    this.deviceId = null
    this.currentUri = null
    this.wasPlaying = false
    this.lastPos = 0
    this.player = null

    if (!this.token) {
      this.pushEvent("playback_error", {reason: "no_token"})
      return
    }

    loadSpotifySDK()
      .then(() => this.initPlayer())
      .catch(() => this.pushEvent("playback_error", {reason: "sdk_load_failed"}))
  },

  updated() {
    // Pick up a refreshed token and/or a changed target track.
    this.token = this.el.dataset.token || this.token
    const want = this.el.dataset.uri || ""
    if (want !== this.wantUri) {
      this.wantUri = want
      this.sync()
    }
  },

  destroyed() {
    if (this.player) {
      try { this.player.disconnect() } catch (_e) {}
    }
  },

  initPlayer() {
    if (!window.Spotify) {
      this.pushEvent("playback_error", {reason: "sdk_unavailable"})
      return
    }

    this.player = new window.Spotify.Player({
      name: "whose-jam TV",
      getOAuthToken: (cb) => cb(this.token),
      volume: 0.8,
    })

    const fail = (reason) => (e) => {
      this.pushEvent("playback_error", {reason, message: (e && e.message) || ""})
    }
    this.player.addListener("initialization_error", fail("initialization_error"))
    this.player.addListener("authentication_error", fail("authentication_error"))
    this.player.addListener("account_error", fail("account_error"))
    this.player.addListener("playback_error", fail("playback_error"))

    this.player.addListener("ready", ({device_id}) => {
      this.deviceId = device_id
      this.pushEvent("playback_ready", {})
      this.sync()
    })

    this.player.addListener("not_ready", () => {
      this.deviceId = null
    })

    this.player.addListener("player_state_changed", (state) => {
      if (!state) return
      const pos = state.position
      const paused = state.paused
      // A single-track play ends by pausing at position 0 after having played.
      if (this.wantUri && this.wasPlaying && paused && pos === 0 && this.lastPos > 0) {
        this.wasPlaying = false
        this.currentUri = null
        this.pushEvent("song_ended", {})
      }
      this.lastPos = pos
    })

    this.player.connect()
  },

  // Reconcile actual playback toward the desired `wantUri`.
  sync() {
    if (!this.deviceId) return
    if (this.wantUri) {
      if (this.wantUri !== this.currentUri) this.playUri(this.wantUri)
    } else {
      this.pauseNow()
    }
  },

  playUri(uri) {
    this.currentUri = uri
    this.wasPlaying = true
    this.lastPos = 0

    fetch(
      `https://api.spotify.com/v1/me/player/play?device_id=${encodeURIComponent(this.deviceId)}`,
      {
        method: "PUT",
        headers: {
          Authorization: `Bearer ${this.token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({uris: [uri], position_ms: 0}),
      }
    ).then((resp) => {
      if (!resp.ok) {
        this.pushEvent("playback_error", {reason: "play_failed", status: resp.status})
      }
    }).catch(() => {
      this.pushEvent("playback_error", {reason: "play_request_failed"})
    })
  },

  pauseNow() {
    this.currentUri = null
    this.wasPlaying = false
    if (this.player) {
      try { this.player.pause() } catch (_e) {}
    }
  },
}

export default {SpotifyPlayer}
