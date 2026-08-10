import { Controller } from "@hotwired/stimulus"
import { SessionEngine, YourInputMethodAdapter, RimeDictionaryAdapter, fingerprint } from "controllers/transcription_core"

export default class extends Controller {
  static values = { variants: Object }

  static targets = [
    "source", "title", "stage", "track", "fullText", "input", "score", "status",
    "report", "reportBody", "windowSize", "viewMode", "direction", "hard", "zen",
    "fade", "pastColor", "futureColor", "skipButton", "variantMode",
    "inputMethod", "candidates", "rimeOptions", "showCandidates",
  ]

  connect() {
    this.engine = null
    this.rimeAdapter = null
    this.isComposing = false
    this.lastCompositionCommit = null
    this.adapter = new YourInputMethodAdapter((value) => this.commit(value))
    this.focusWindowStart = null
    this.fullTextRenderedFor = null
    this.fullTextTokenElements = new Map()
    this.lastFullCurrentIndex = null
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
    this.exerciseSignature = `${this.engine.tokens.length}:${fingerprint(this.engine.tokens.map((token) => token.canonical).join(""))}`
    this.reportTarget.hidden = true
    this.focusWindowStart = null
    this.fullTextRenderedFor = null
    this.fullTextTokenElements.clear()
    this.fullTextTarget.replaceChildren()
    this.lastFullCurrentIndex = null
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

    const full = this.viewModeTarget.value === "full"
    this.trackTarget.parentElement.hidden = full
    this.fullTextTarget.hidden = !full

    if (full) this.renderFullText()
    else this.renderFocus()

    const zen = this.zenTarget.checked
    this.scoreTarget.hidden = zen
    this.scoreTarget.textContent = `Score ${this.engine.score}`
    this.skipButtonTarget.disabled = this.hardTarget.checked || !this.engine.current
  }

  // Focus mode is deliberately virtualised.  A 100,000-character corpus text
  // should not create 100,000 DOM nodes on every correct keystroke.  We render
  // only the requested visible window and slide that window through the token
  // array as the learner advances.
  renderFocus() {
    const currentIndex = this.engine.currentIndex ?? this.engine.tokens.length
    const windowSize = Math.max(1, Math.min(40, Number(this.windowSizeTarget.value || 7)))
    const vertical = this.directionTarget.value === "vertical"
    const midpoint = Math.floor(windowSize / 2)
    const startIndex = Math.max(0, currentIndex - midpoint)

    const elements = []
    for (let offset = 0; offset < windowSize; offset += 1) {
      const token = this.engine.tokens[startIndex + offset]
      elements.push(token ? this.tokenElement(token) : this.emptyFocusSlot())
    }

    const previousStart = this.focusWindowStart
    this.focusWindowStart = startIndex
    this.trackTarget.replaceChildren(...elements)
    this.trackTarget.parentElement.style.setProperty("--transcription-window", windowSize)
    this.trackTarget.classList.toggle("is-vertical", vertical)
    this.trackTarget.parentElement.classList.toggle("is-vertical", vertical)
    this.trackTarget.style.transform = "none"

    // Once the midpoint starts moving, give the new virtual window a short
    // one-cell slide.  This keeps the familiar scrolling cue without retaining
    // the entire document in the DOM.
    if (previousStart !== null && startIndex === previousStart + 1) {
      requestAnimationFrame(() => this.animateFocusShift(vertical))
    }
  }

  animateFocusShift(vertical) {
    if (typeof this.trackTarget.animate !== "function") return
    const first = this.trackTarget.firstElementChild
    if (!first) return
    const box = first.getBoundingClientRect()
    const distance = vertical ? box.height : box.width
    if (!distance) return

    const from = vertical ? `translateY(${distance}px)` : `translateX(${distance}px)`
    const to = vertical ? "translateY(0)" : "translateX(0)"
    this.trackTarget.animate([{ transform: from }, { transform: to }], {
      duration: 150,
      easing: "ease-out",
    })
  }

  emptyFocusSlot() {
    const span = document.createElement("span")
    span.className = "transcription-token transcription-token--empty"
    span.setAttribute("aria-hidden", "true")
    return span
  }

  // Full-text mode is necessarily larger, but it is still built only once per
  // exercise.  Subsequent answers update the two affected token nodes instead
  // of replacing the entire document.
  renderFullText() {
    const signature = this.exerciseSignature
    if (this.fullTextRenderedFor !== signature) {
      this.fullTextTokenElements.clear()
      const elements = this.engine.tokens.map((token) => {
        const element = this.tokenElement(token)
        this.fullTextTokenElements.set(token.index, element)
        return element
      })
      this.fullTextTarget.replaceChildren(...elements)
      this.fullTextRenderedFor = signature
      this.lastFullCurrentIndex = null
    }

    const currentIndex = this.engine.currentIndex
    const touched = new Set([this.lastFullCurrentIndex, currentIndex])
    touched.forEach((index) => {
      if (index === null || index === undefined) return
      const token = this.engine.tokens[index]
      const element = this.fullTextTokenElements.get(index)
      if (token && element) this.applyTokenState(element, token)
    })
    this.lastFullCurrentIndex = currentIndex
    this.fullTextTarget.classList.toggle("is-vertical", this.directionTarget.value === "vertical")
  }

  tokenElement(token) {
    const span = document.createElement("span")
    span.className = "transcription-token"
    span.textContent = token.text
    span.dataset.index = token.index
    this.applyTokenState(span, token)
    return span
  }

  applyTokenState(element, token) {
    element.classList.remove("is-past", "is-future", "is-current")
    element.classList.add(`is-${token.status}`)
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
      <p>Speed bonus: +${report.speedBonus}. Punctuation and spacing are removed from the exercise before scoring.</p>
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
    if (typeof saved.fade === "boolean") this.fadeTarget.checked = saved.fade
    this.applyAppearance()
  }

  saveAppearance() {
    localStorage.setItem("fanya.transcription.appearance", JSON.stringify({
      past: this.pastColorTarget.value,
      future: this.futureColorTarget.value,
      fade: this.fadeTarget.checked,
    }))
  }

  applyAppearance() {
    this.element.style.setProperty("--transcription-past", this.pastColorTarget.value)
    this.element.style.setProperty("--transcription-future", this.futureColorTarget.value)
    this.element.classList.toggle("transcription-no-fade", !this.fadeTarget.checked)
  }
}

function escapeHtml(value) {
  const div = document.createElement("div")
  div.textContent = value
  return div.innerHTML
}
