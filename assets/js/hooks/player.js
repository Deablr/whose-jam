// Player-phone hooks. Registered in app.js (do not touch app.js).

// Countdown — renders whole seconds remaining until `data-deadline` (epoch ms).
// Ticks every 250ms, shows mm:ss when a minute or more remains, otherwise ss,
// stops at zero, and re-reads the attribute whenever the element is patched.
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

    const remaining = Math.max(0, Math.round((deadline - Date.now()) / 1000))
    const minutes = Math.floor(remaining / 60)
    const seconds = remaining % 60

    this.el.textContent =
      minutes > 0 ? `${minutes}:${String(seconds).padStart(2, "0")}` : `${seconds}`

    if (remaining <= 0) {
      this.stopTicking()
    }
  },
}

export default { Countdown }
