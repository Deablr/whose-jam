// Spotify provider player: drives the Web Playback SDK with the host's Premium
// OAuth token (`config.token`). Song URIs are `spotify:track:<id>` and are
// handed to Spotify as-is.
//
// End-of-song is not reported by the SDK for a single track, so it is inferred:
// a play ends by pausing at position 0 after having played.

const SDK_SRC = "https://sdk.scdn.co/spotify-player.js"

// Load the Web Playback SDK exactly once for the whole page. Resolves when the
// global `Spotify` object is ready to use.
let sdkPromise = null
function loadSDK() {
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

export default {
  create(ctx) {
    let token = ctx.config.token || null
    let player = null
    let deviceId = null
    let wasPlaying = false
    let lastPos = 0
    let destroyed = false
    let volume = 0.8

    const initPlayer = () => {
      // The hook can be torn down while the SDK script is still loading.
      if (destroyed) return

      if (!window.Spotify) {
        ctx.onError("sdk_unavailable")
        return
      }

      player = new window.Spotify.Player({
        name: "whose-jam TV",
        getOAuthToken: (cb) => cb(token),
        volume,
      })

      const fail = (reason) => (e) => ctx.onError(reason, (e && e.message) || "")
      player.addListener("initialization_error", fail("initialization_error"))
      player.addListener("authentication_error", fail("authentication_error"))
      player.addListener("account_error", fail("account_error"))
      player.addListener("playback_error", fail("playback_error"))

      player.addListener("ready", ({device_id}) => {
        deviceId = device_id
        ctx.onReady()
      })

      player.addListener("not_ready", () => {
        deviceId = null
        ctx.onNotReady()
      })

      player.addListener("player_state_changed", (state) => {
        if (!state) return
        const pos = state.position
        // A single-track play ends by pausing at position 0 after having played.
        if (wasPlaying && state.paused && pos === 0 && lastPos > 0) {
          wasPlaying = false
          // The track Spotify says it was playing (as asked for, if it was
          // relinked to another release).
          const track = state.track_window && state.track_window.current_track
          ctx.onEnded(track ? (track.linked_from && track.linked_from.uri) || track.uri : null)
        }
        lastPos = pos
      })

      player.connect()
    }

    return {
      init() {
        if (!token) {
          ctx.onError("no_token")
          return Promise.resolve()
        }
        return loadSDK()
          .then(initPlayer)
          .catch(() => ctx.onError("sdk_load_failed"))
      },

      play(uri, fromMs = 0) {
        wasPlaying = true
        lastPos = 0

        fetch(
          `https://api.spotify.com/v1/me/player/play?device_id=${encodeURIComponent(deviceId)}`,
          {
            method: "PUT",
            headers: {
              Authorization: `Bearer ${token}`,
              "Content-Type": "application/json",
            },
            body: JSON.stringify({uris: [uri], position_ms: Math.max(0, Math.round(fromMs))}),
          }
        ).then((resp) => {
          if (!resp.ok) ctx.onError("play_failed", `status ${resp.status}`)
        }).catch(() => ctx.onError("play_request_failed"))
      },

      pause() {
        wasPlaying = false
        if (player) player.pause().catch(() => {})
      },

      // 0 to 1; the game's songs are a little under full volume.
      setVolume(level) {
        volume = Math.min(1, Math.max(0, level * 0.8))
        if (player) player.setVolume(volume).catch(() => {})
      },

      updateConfig(next) { token = next.token || token },

      destroy() {
        destroyed = true
        if (player) { try { player.disconnect() } catch (_e) {} }
      },
    }
  },
}
