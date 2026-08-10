import { Controller } from "@hotwired/stimulus"
import { SessionEngine, YourInputMethodAdapter, fingerprint, graphemes } from "controllers/transcription_core"

export default class extends Controller {
  static values = { variants: Object }

  static targets = [
    "source", "title", "stage", "track", "fullText", "input", "score", "status",
    "report", "reportBody", "windowSize", "viewMode", "direction", "hard", "zen",
    "fade", "pastColor", "futureColor", "unsupportedColor", "skipButton", "variantMode",
  ]

  connect() {
    this.engine = null
    this.adapter = new YourInputMethodAdapter((value) => this.commit(value))
    this.loadAppearance()
    this.start()
  }

  start() {
    const text = this.sourceTarget.value
    if (!text.trim()) return

    const variantMode = this.variantModeTarget.value
    const variants = this.hasVariantsValue ? this.variantsValue : {}
    this.engine = new SessionEngine(text, {
      hard: this.hardTarget.checked,
      zen: this.zenTarget.checked,
      display: (canonical) => {
        if (variantMode !== "scramble") return canonical
        const family = variants[canonical] || [canonical]
        return family[Math.floor(Math.random() * family.length)] || canonical
      },
      equivalents: (token) => {
        if (variantMode === "accept") return variants[token.canonical] || [token.canonical]
        if (variantMode === "scramble") return [token.text]
        return [token.canonical]
      },
    })
    this.reportTarget.hidden = true
    this.inputTarget.disabled = false
    this.inputTarget.value = ""
    this.render()
    this.inputTarget.focus()
  }

  input(event) {
    if (event.isComposing) return
    const value = event.target.value
    event.target.value = ""
    if (!value) return
    this.adapter.handleInput(value)
  }

  commit(value) {
    if (!this.engine?.current) return
    const result = this.engine.submit(value)
    if (result.type === "incorrect") {
      this.stageTarget.classList.remove("is-wrong")
      void this.stageTarget.offsetWidth
      this.stageTarget.classList.add("is-wrong")
      this.statusTarget.textContent = `Try ${result.token.text} again.`
    } else {
      this.statusTarget.textContent = result.type === "complete" ? "Complete." : "Correct."
    }
    this.render()
    if (result.type === "complete") this.finish()
  }

  skip() {
    const result = this.engine?.skip()
    if (!result || result.type === "blocked") return
    this.statusTarget.textContent = `Skipped ${result.token.text}.`
    this.render()
    if (result.type === "complete") this.finish()
  }

  settingsChanged() {
    this.saveAppearance()
    this.applyAppearance()
    this.render()
  }

  restart() {
    this.start()
  }

  practiceDifficult() {
    const difficult = this.engine?.report().difficult || []
    if (difficult.length === 0) return
    this.sourceTarget.value = difficult.map((token) => token.text).join("")
    this.titleTarget.value = `${this.titleTarget.value} — difficult characters`
    this.start()
  }

  finish() {
    const report = this.engine.report()
    this.inputTarget.disabled = true
    this.reportTarget.hidden = false
    this.renderReport(report)
    this.saveHighScore(report)
  }

  render() {
    if (!this.engine) return
    this.applyAppearance()
    this.renderFocus()
    this.renderFullText()

    const zen = this.zenTarget.checked
    this.scoreTarget.hidden = zen
    this.scoreTarget.textContent = `Score ${this.engine.score}`
    this.skipButtonTarget.disabled = this.hardTarget.checked || !this.engine.current

    const full = this.viewModeTarget.value === "full"
    this.trackTarget.parentElement.hidden = full
    this.fullTextTarget.hidden = !full
  }

  renderFocus() {
    const currentIndex = this.engine.currentIndex ?? this.engine.tokens.length
    const windowSize = Math.max(1, Math.min(40, Number(this.windowSizeTarget.value || 7)))
    const anchor = Math.floor(windowSize * 0.35)
    const unit = 1.65
    this.trackTarget.replaceChildren(...this.engine.tokens.map((token) => this.tokenElement(token)))
    this.trackTarget.parentElement.style.setProperty("--transcription-window", windowSize)
    this.trackTarget.style.setProperty("--transcription-offset", `${(anchor - currentIndex) * unit}em`)
    const vertical = this.directionTarget.value === "vertical"
    this.trackTarget.classList.toggle("is-vertical", vertical)
    this.trackTarget.parentElement.classList.toggle("is-vertical", vertical)
  }

  renderFullText() {
    this.fullTextTarget.replaceChildren(...this.engine.tokens.map((token) => this.tokenElement(token)))
    this.fullTextTarget.classList.toggle("is-vertical", this.directionTarget.value === "vertical")
  }

  tokenElement(token) {
    const span = document.createElement("span")
    span.className = `transcription-token is-${token.status}`
    if (!token.playable) span.classList.add("is-display-only")
    span.textContent = token.text
    span.dataset.index = token.index
    return span
  }

  renderReport(report) {
    const seconds = (report.elapsedMs / 1000).toFixed(1)
    const accuracy = report.attempted === 0 ? 0 : Math.round((report.firstTry / report.attempted) * 100)
    const title = this.titleTarget.value.trim() || "Practice text"
    const rows = report.difficult.slice(0, 20).map((token) => {
      const reasons = []
      if (token.skipped) reasons.push("skipped")
      if (token.attempts > 1) reasons.push(`${token.attempts} attempts`)
      if ((token.durationMs || 0) >= 5000) reasons.push(`${(token.durationMs / 1000).toFixed(1)}s pause`)
      return `<li><strong>${escapeHtml(token.text)}</strong> — ${escapeHtml(reasons.join(", "))}</li>`
    }).join("")

    this.reportBodyTarget.innerHTML = `
      <p><strong>${escapeHtml(title)}</strong></p>
      <p>${report.correct} characters · ${accuracy}% first attempt · ${seconds}s · score ${report.score}</p>
      <p>Speed bonus: +${report.speedBonus}. Unsupported characters skipped automatically: ${report.unsupported}.</p>
      ${rows ? `<h3>Characters to review</h3><ul>${rows}</ul>` : "<p>No difficult characters were recorded in this run.</p>"}
    `
  }

  saveHighScore(report) {
    const key = `fanya.transcription.highScore.${fingerprint(this.sourceTarget.value)}`
    const previous = JSON.parse(localStorage.getItem(key) || "null")
    if (!previous || report.score > previous.score) {
      localStorage.setItem(key, JSON.stringify({
        score: report.score,
        title: this.titleTarget.value,
        textHash: fingerprint(this.sourceTarget.value),
        recordedAt: new Date().toISOString(),
      }))
    }
  }

  loadAppearance() {
    const saved = JSON.parse(localStorage.getItem("fanya.transcription.appearance") || "{}")
    if (saved.past) this.pastColorTarget.value = saved.past
    if (saved.future) this.futureColorTarget.value = saved.future
    if (saved.unsupported) this.unsupportedColorTarget.value = saved.unsupported
    if (typeof saved.fade === "boolean") this.fadeTarget.checked = saved.fade
    this.applyAppearance()
  }

  saveAppearance() {
    localStorage.setItem("fanya.transcription.appearance", JSON.stringify({
      past: this.pastColorTarget.value,
      future: this.futureColorTarget.value,
      unsupported: this.unsupportedColorTarget.value,
      fade: this.fadeTarget.checked,
    }))
  }

  applyAppearance() {
    this.element.style.setProperty("--transcription-past", this.pastColorTarget.value)
    this.element.style.setProperty("--transcription-future", this.futureColorTarget.value)
    this.element.style.setProperty("--transcription-unsupported", this.unsupportedColorTarget.value)
    this.element.classList.toggle("transcription-no-fade", !this.fadeTarget.checked)
  }
}

function escapeHtml(value) {
  const div = document.createElement("div")
  div.textContent = value
  return div.innerHTML
}
