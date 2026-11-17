// Player-phone hooks. Registered in app.js (do not touch app.js).

// Countdown — renders the time remaining until `data-deadline` (epoch ms) as
// m:ss, always, so a clock never changes shape as it runs down. It rounds up:
// the clock reads 0:01 until the moment is reached, so it never sits on 0:00
// waiting for the screen to change. Ticks every 250ms, stops at zero, and
// re-reads the attribute whenever the element is patched.
const Countdown = {
  mounted() {
    this.startTicking()
  },
  updated() {
    this.startTicking()
  },
  destroyed() {
    this.stopTicking()
  },
  startTicking() {
    this.stopTicking()
    this.tick()
    this.timer = setInterval(() => this.tick(), 250)
  },
  stopTicking() {
    if (this.timer) {
      clearInterval(this.timer)
      this.timer = null
    }
  },
  tick() {
    const deadline = parseInt(this.el.dataset.deadline, 10)
    if (!deadline || Number.isNaN(deadline)) {
      this.el.textContent = "--"
      this.stopTicking()
      return
    }

    const remaining = Math.max(0, Math.ceil((deadline - Date.now()) / 1000))
    const minutes = Math.floor(remaining / 60)
    const seconds = remaining % 60

    this.el.textContent = `${minutes}:${String(seconds).padStart(2, "0")}`

    // The last five seconds are marked, so a screen can say "hurry" in its
    // own way (`data-urgent`, styled where the clock is used).
    if (remaining > 0 && remaining <= 5) {
      this.el.dataset.urgent = ""
    } else {
      delete this.el.dataset.urgent
    }

    if (remaining <= 0) {
      this.stopTicking()
    }
  },
}

// Progress — drains the element's first child from full to empty over the
// `data-duration` (ms) that ends at `data-deadline` (epoch ms): the same wait a
// Countdown reads out, as a line to glance at (what is left of it, as the
// clock says what is left). Put `phx-update="ignore"` on the element, so a
// patch never resets it.
const Progress = {
  mounted() {
    this.draw()
  },
  updated() {
    this.draw()
  },
  destroyed() {
    this.stop()
  },
  stop() {
    if (this.frame) {
      cancelAnimationFrame(this.frame)
      this.frame = null
    }
  },
  draw() {
    this.stop()

    const bar = this.el.firstElementChild
    const deadline = parseInt(this.el.dataset.deadline, 10)
    const duration = parseInt(this.el.dataset.duration, 10)
    if (!bar || !deadline || Number.isNaN(deadline)) return

    const left = duration > 0 ? Math.min(1, Math.max(0, (deadline - Date.now()) / duration)) : 0

    bar.style.transform = `scaleX(${left})`

    if (left > 0) {
      this.frame = requestAnimationFrame(() => this.draw())
    }
  },
}

// SeatKeeper — keeps a phone's seat in a game on the phone. The session
// cookie holds one seat (the latest game joined) and is lost with the browser
// session; local storage keeps one per room code, so a phone that comes back
// to a game by the back button, a reload or a closed tab is the same player,
// not a stranger who would join the audience, and a game it has since left
// for another stays its own.
//
//   * "seat:save" {code, token}  — the server has this phone seated: keep it.
//   * "seat:forget" {code}       — the game no longer knows the seat.
//   * on mount, a phone with no seat on screen offers the saved one back
//     ("resume_seat"), once per mount.
const SEAT_PREFIX = "whose-jam:seat:"
// As long as a seat's token is good for (`WhoseJamWeb.PlayerToken`); an
// older saved seat is dropped rather than offered.
const SEAT_MAX_AGE_MS = 4 * 60 * 60 * 1000

function seatKey(code) { return SEAT_PREFIX + String(code).toUpperCase() }

// A saved seat is `{token, at}` (when it was saved, ms), or null.
function parseSeat(raw) {
  try {
    const seat = JSON.parse(raw)
    if (seat && typeof seat.token === "string" && typeof seat.at === "number") return seat
  } catch (_e) {}
  return null
}

function readSeat(code) {
  try {
    const seat = parseSeat(window.localStorage.getItem(seatKey(code)))
    return seat && Date.now() - seat.at < SEAT_MAX_AGE_MS ? seat.token : null
  } catch (_e) { return null }
}

function writeSeat(code, token) {
  try { window.localStorage.setItem(seatKey(code), JSON.stringify({token, at: Date.now()})) } catch (_e) {}
}

function dropSeat(code) {
  try { window.localStorage.removeItem(seatKey(code)) } catch (_e) {}
}

const SeatKeeper = {
  mounted() {
    this.handleEvent("seat:save", ({code, token}) => {
      if (code && typeof token === "string" && token) writeSeat(code, token)
    })
    this.handleEvent("seat:forget", ({code}) => { if (code) dropSeat(code) })

    if (this.el.dataset.seated !== "true") {
      const token = readSeat(this.el.dataset.code)
      if (token) this.pushEvent("resume_seat", {token})
    }
  },
}

// SeatFinder — on the home page: offers the seats this phone saved, newest
// first ("saved_seats"), so the page can show the way back to a game that is
// on. Seats too old to be good any more are cleared out on the way.
const SeatFinder = {
  mounted() {
    const seats = []
    try {
      const keys = []
      for (let i = 0; i < window.localStorage.length; i++) {
        const key = window.localStorage.key(i)
        if (key && key.startsWith(SEAT_PREFIX)) keys.push(key)
      }
      for (const key of keys) {
        const seat = parseSeat(window.localStorage.getItem(key))
        if (seat && Date.now() - seat.at < SEAT_MAX_AGE_MS) {
          seats.push(seat)
        } else {
          window.localStorage.removeItem(key)
        }
      }
    } catch (_e) {}

    seats.sort((a, b) => b.at - a.at)
    if (seats.length > 0) this.pushEvent("saved_seats", {tokens: seats.slice(0, 10).map((s) => s.token)})
  },
}

export default { Countdown, Progress, SeatKeeper, SeatFinder }
