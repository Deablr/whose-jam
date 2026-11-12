// YouTube provider player: drives the IFrame Player API. Song URIs are
// `youtube:video:<id>`; the video plays in `ctx.videoEl`, which HostLive shows
// on screen while a song plays (YouTube's terms require a visible player).
//
// The player is embedded from www.youtube.com (not youtube-nocookie.com) on
// purpose: it then runs with the host browser's own YouTube session, which is
// what lets a Premium account play without ads.
//
// YouTube refuses to play ("This video is unavailable") in a page opened by IP
// address, loopback included, and plays in one opened by name. That refusal
// doesn't say why, so the page's address is checked up front instead.

const API_SRC = "https://www.youtube.com/iframe_api"
const URI_PREFIX = "youtube:video:"

// IFrame API `onError` codes -> the reasons the provider module words
// (`playback_error_message/1`). 101 and 150 are the same error.
const ERROR_REASONS = {
  2: "invalid_video",
  5: "player_error",
  100: "video_unavailable",
  101: "embed_blocked",
  150: "embed_blocked",
}

// Load the IFrame API exactly once for the whole page. Resolves when the
// global `YT.Player` is ready to use.
let apiPromise = null
function loadAPI() {
  if (window.YT && window.YT.Player) return Promise.resolve()
  if (apiPromise) return apiPromise

  apiPromise = new Promise((resolve, reject) => {
    // The API calls this global when it finishes initializing.
    const prev = window.onYouTubeIframeAPIReady
    window.onYouTubeIframeAPIReady = () => {
      if (typeof prev === "function") { try { prev() } catch (_e) {} }
      resolve()
    }

    if (!document.getElementById("youtube-iframe-api")) {
      const script = document.createElement("script")
      script.id = "youtube-iframe-api"
      script.src = API_SRC
      script.async = true
      script.onerror = () => {
        // Let a later mount try again rather than caching the failure.
        apiPromise = null
        script.remove()
        reject(new Error("YouTube IFrame API failed to load"))
      }
      document.head.appendChild(script)
    }
  })

  return apiPromise
}

// An IPv4 literal, or a bracketed IPv6 one (how `location.hostname` gives it).
function ipAddressHost(hostname) {
  return /^\d{1,3}(\.\d{1,3}){3}$/.test(hostname) || hostname.startsWith("[")
}

function videoId(uri) {
  return uri.startsWith(URI_PREFIX) ? uri.slice(URI_PREFIX.length) : ""
}

export default {
  create(ctx) {
    let player = null
    let destroyed = false
    // Whether the video loaded by the last play() has started, so an "ended"
    // is only ever reported for a video that actually played.
    let started = false
    // Set by a failed video; the next one that plays clears the host's banner.
    let failed = false

    const initPlayer = () => {
      // The hook can be torn down while the API script is still loading.
      if (destroyed) return

      if (!ctx.videoEl) {
        ctx.onError("no_video_element")
        return
      }

      // YT.Player replaces its target with the iframe. Hand it a child, so the
      // element LiveView knows about (phx-update="ignore") stays in place.
      const mount = document.createElement("div")
      ctx.videoEl.replaceChildren(mount)

      player = new window.YT.Player(mount, {
        width: "100%",
        height: "100%",
        playerVars: {
          controls: 0,
          disablekb: 1,
          fs: 0,
          iv_load_policy: 3,
          playsinline: 1,
          rel: 0,
          origin: window.location.origin,
        },
        events: {
          onReady: () => { if (!destroyed) ctx.onReady() },

          onStateChange: (event) => {
            if (destroyed) return
            const states = window.YT.PlayerState

            if (event.data === states.PLAYING) {
              started = true
              if (failed) {
                failed = false
                ctx.onReady()
              }
            } else if (event.data === states.ENDED && started) {
              started = false
              ctx.onEnded()
            }
          },

          onError: (event) => {
            if (destroyed) return
            failed = true
            ctx.onError(ERROR_REASONS[event.data] || "player_error", `code ${event.data}`)
          },

          // The browser refused to start playback without a user gesture.
          onAutoplayBlocked: () => {
            if (destroyed) return
            failed = true
            ctx.onError("autoplay_blocked")
          },
        },
      })
    }

    return {
      init() {
        if (ipAddressHost(window.location.hostname)) {
          ctx.onError("ip_address_origin")
          return Promise.resolve()
        }

        return loadAPI()
          .then(initPlayer)
          .catch(() => ctx.onError("sdk_load_failed"))
      },

      play(uri) {
        const id = videoId(uri)
        started = false

        if (!id) {
          failed = true
          ctx.onError("invalid_video")
          return
        }

        player.loadVideoById(id)
      },

      pause() {
        started = false
        if (player) { try { player.stopVideo() } catch (_e) {} }
      },

      updateConfig(_next) {},

      destroy() {
        destroyed = true
        if (player) { try { player.destroy() } catch (_e) {} }
      },
    }
  },
}
