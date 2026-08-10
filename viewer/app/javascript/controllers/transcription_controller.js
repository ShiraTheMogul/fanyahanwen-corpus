import { Controller } from "@hotwired/stimulus"
import { SessionEngine, YourInputMethodAdapter, RimeDictionaryAdapter, fingerprint } from "controllers/transcription_core"

export default class extends Controller {
  static values = { variants: Object }

  static targets = [
    "source", "title", "stage", "track", "fullText", "input", "score", "status",
    "report", "reportBody", "windowSize", "viewMode", "direction", "hard", "zen",
    "fade", "pastColor", "futureColor", "unsupportedColor", "skipButton", "variantMode",
    "inputMethod", "candidates", "rimeOptions", "showCandidates",
  ]

  connect() {
    this.engine = null
    this.rimeAdapter = null
    this.isComposing = false
    this.lastCompositionCommit = null
    this.adapter = new YourInputMethodAdapter((value) => this.commit(value))
    this.restoreCorpusHandoff()
    this.loadAppearance()
    this.start()
  }

  disconnect() {
    this.rimeAdapter?.disconnect()
  }

  restoreCorpusHandoff() {
    const raw = sessionStorage.getItem("fanya.transcription.handoff")
    if (!raw) return
    try {
      const handoff = JSON.parse(raw)
      if (handoff.text) this.sourceTarget.value = handoff.text
      if (handoff.title) this.titleTarget.value = handoff.title
    } finally {
      sessionStorage.removeItem("fanya.transcription.handoff")
    }
  }

  start() {
    const text = this.sourceTarget.value
    if (!text.trim()) return

    const variantMode = this.variantModeTarget.value
    const variants = this.hasVariantsValue ? this.variantsValue : {}
    this.engine = new SessionEngine(text, {
      hard: this.hardTarget.checked,
      zen: this.zenTarget.checked,
      supported: () => true,
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
    this.clearCandidates()
    this.render()
    this.inputTarget.focus()
  }

  compositionStart() {
    this.isComposing = true
  }

  compositionEnd(event) {
    this.isComposing = false
    if (this.rimeAdapter) return

    const value = event.target.value
    event.target.value = ""
    if (!value) return

    this.lastCompositionCommit = value
    this.adapter.handleInput(value)
    window.setTimeout(() => {
      if (this.lastCompositionCommit === value) this.lastCompositionCommit = null
    }, 0)
  }

  input(event) {
    if (this.rimeAdapter) {
      this.rimeAdapter.update(event.target.value)
      return
    }

    if (event.isComposing || this.isComposing) return

    const value = event.target.value
    event.target.value = ""
    if (!value) return

    // Some browsers emit a final `input` after `compositionend`; do not score
    // the same committed IME text twice.
    if (this.lastCompositionCommit && value === this.lastCompositionCommit) {
      this.lastCompositionCommit = null
      return
    }

    this.lastCompositionCommit = null
    this.adapter.handleInput(value)
  }

  async keydown(event) {
    if (!this.rimeAdapter) return

    if (event.key === "Enter" || event.key === " ") {
      event.preventDefault()
      const result = await this.rimeAdapter.commitCode(this.inputTarget.value)
      if (result.committed) {
        this.afterRimeCommit()
      } else if (result.reason === "ambiguous") {
        this.statusTarget.textContent = `${result.count} characters use that exact code. Turn on “Reveal candidates” to choose one.`
      } else if (result.reason === "none") {
        this.statusTarget.textContent = "No character uses that exact code in the imported dictionary."
      }
      return
    }

    if (/^[1-9]$/.test(event.key) && this.showCandidatesTarget.checked) {
      const index = Number(event.key) - 1
      if (this.rimeAdapter.candidates[index]) {
        event.preventDefault()
        if (this.rimeAdapter.choose(index)) this.afterRimeCommit()
      }
      return
    }

    if (event.key === "Escape") {
      event.preventDefault()
      this.inputTarget.value = ""
      this.clearCandidates()
    }
  }

  inputMethodChanged() {
    this.rimeAdapter?.disconnect()
    this.rimeAdapter = null
    this.inputTarget.value = ""
    this.clearCandidates()
    this.rimeOptionsTarget.hidden = true
    this.showCandidatesTarget.checked = false

    const value = this.inputMethodTarget.value
    if (value.startsWith("rime-data:")) {
      const systemId = value.slice("rime-data:".length)
      this.rimeAdapter = new RimeDictionaryAdapter({
        systemId,
        onCommit: (character) => this.commit(character),
        onCandidates: (rows, query, error) => this.renderCandidates(rows, query, error),
      })
      this.rimeOptionsTarget.hidden = false
      this.statusTarget.textContent = "Code helper active. ASCII codes are never scored; only the Han character you commit is checked. Candidate answers stay hidden unless you reveal them."
    } else {
      this.statusTarget.textContent = "Using your browser/system input method."
    }
    this.inputTarget.focus()
  }

  revealCandidatesChanged() {
    if (!this.rimeAdapter) return
    this.rimeAdapter.setRevealCandidates(this.showCandidatesTarget.checked)
    this.clearCandidates()
    if (this.showCandidatesTarget.checked) {
      this.rimeAdapter.update(this.inputTarget.value)
      this.statusTarget.textContent = "Candidate list revealed. Space/Enter chooses candidate 1; number keys choose 1–9."
    } else {
      this.statusTarget.textContent = "Candidate list hidden. Space/Enter auto-commits only a unique exact code."
    }
  }

  candidateChosen(event) {
    if (!this.rimeAdapter || !this.showCandidatesTarget.checked) return
    const index = Number(event.currentTarget.dataset.index || 0)
    if (this.rimeAdapter.choose(index)) this.afterRimeCommit()
  }

  afterRimeCommit() {
    this.inputTarget.value = ""
    this.clearCandidates()
    this.inputTarget.focus()
  }

  renderCandidates(rows, query, error) {
    this.candidatesTarget.replaceChildren()
    if (error) {
      this.candidatesTarget.textContent = `Could not look up “${query}”.`
      return
    }

    rows.forEach((row, index) => {
      const button = document.createElement("button")
      button.type = "button"
      button.className = "transcription-candidate"
      button.dataset.index = index
      button.dataset.action = "transcription#candidateChosen"
      button.innerHTML = `<span class="transcription-candidate-number">${index + 1}</span><span class="transcription-candidate-glyph"></span><code></code>`
      button.querySelector(".transcription-candidate-glyph").textContent = row.character
      button.querySelector("code").textContent = row.code
      this.candidatesTarget.append(button)
    })
  }

  clearCandidates() {
    if (this.hasCandidatesTarget) this.candidatesTarget.replaceChildren()
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

  restart() { this.start() }

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
    const vertical = this.directionTarget.value === "vertical"

    this.trackTarget.replaceChildren(...this.engine.tokens.map((token) => this.tokenElement(token)))
    this.trackTarget.parentElement.style.setProperty("--transcription-window", windowSize)
    this.trackTarget.classList.toggle("is-vertical", vertical)
    this.trackTarget.parentElement.classList.toggle("is-vertical", vertical)

    requestAnimationFrame(() => this.positionFocus(currentIndex, windowSize, vertical))
  }

  positionFocus(currentIndex, windowSize, vertical) {
    const children = Array.from(this.trackTarget.children)
    if (children.length === 0) return

    // Keep the text still while the cursor is in the first half-window. From
    // the midpoint onward, the cursor stays in the middle of the viewport.
    // Near the end this intentionally leaves empty future-space on the right:
    // the cursor does not drift away from the user's visual anchor.
    const midpoint = Math.floor(windowSize / 2)
    const focusIndex = Math.min(currentIndex, children.length - 1)
    const startIndex = Math.max(0, focusIndex - midpoint)
    const first = children[0].getBoundingClientRect()
    const step = vertical ? first.height : first.width
    const offset = -(startIndex * step)

    this.trackTarget.style.transform = vertical
      ? `translateY(${offset}px)`
      : `translateX(${offset}px)`
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
