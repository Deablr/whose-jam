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

// Progress — fills the element's first child from empty to full over the
// `data-duration` (ms) that ends at `data-deadline` (epoch ms): the same wait a
// Countdown reads out, as a line to glance at. Put `phx-update="ignore"` on
// the element, so a patch never resets the fill.
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

    const done =
      duration > 0 ? Math.min(1, Math.max(0, 1 - (deadline - Date.now()) / duration)) : 1

    bar.style.transform = `scaleX(${done})`

    if (done < 1) {
      this.frame = requestAnimationFrame(() => this.draw())
    }
  },
}

export default { Countdown, Progress }
