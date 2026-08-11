import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "mode", "opponent", "score", "startButton", "forfeitButton", "hintButton",
    "board", "currentCard", "requiredCharacter", "answer", "submitButton", "status",
    "missingPanel", "reportButton", "reportStatus", "alternativesPanel", "alternativesHeading",
    "alternativesExplanation", "alternatives", "chain",
  ]

  static values = {
    startUrl: String,
    turnUrl: String,
    alternativesUrl: String,
  }

  connect() {
    this.resetState()
    this.modeChanged()
    this.renderScore()
  }

  resetState() {
    this.currentFormId = null
    this.usedFamilyIds = []
    this.points = 0
    this.roundActive = false
    this.lastRejectedAnswer = null
  }

  modeChanged() {
    const zen = this.modeTarget.value === "zen"
    this.hintButtonTarget.hidden = !zen
    this.renderScore()
  }

  async start() {
    this.setBusy(true)
    this.hideMissing()
    this.hideAlternatives()
    this.statusTarget.textContent = "Starting a new chain…"

    try {
      const data = await this.postJson(this.startUrlValue, {
        mode: this.modeTarget.value,
        opponent: this.opponentTarget.value,
        used_family_ids: [],
        score: 0,
      })
      if (!data.ok) return this.showError(data.error)

      this.resetState()
      this.currentFormId = data.current_form_id
      this.usedFamilyIds = data.used_family_ids || []
      this.roundActive = !data.round_over
      this.modeTarget.disabled = this.roundActive
      this.opponentTarget.disabled = this.roundActive
      this.boardTarget.hidden = false
      this.forfeitButtonTarget.disabled = !!data.round_over
      this.hintButtonTarget.disabled = !!data.round_over
      this.chainTarget.replaceChildren()
      this.appendChainEntry("Computer", data.computer)
      this.renderCurrent(data.computer)
      this.statusTarget.textContent = data.message || instructionFor(data.computer)
      this.answerTarget.value = ""
      this.answerTarget.disabled = !!data.round_over
      this.submitButtonTarget.disabled = !!data.round_over
      if (data.round_over) this.saveBestScore()
      else this.answerTarget.focus()
      this.renderScore()
    } catch (error) {
      this.showError(error.message)
    } finally {
      this.setBusy(false)
    }
  }

  async submit(event) {
    event.preventDefault()
    if (!this.roundActive || !this.currentFormId) return

    const answer = this.answerTarget.value.trim()
    this.hideMissing()
    this.hideAlternatives()
    this.setTurnBusy(true)

    try {
      const data = await this.postJson(this.turnUrlValue, {
        answer,
        current_form_id: this.currentFormId,
        used_family_ids: this.usedFamilyIds,
        mode: this.modeTarget.value,
        opponent: this.opponentTarget.value,
        score: this.points,
      })

      if (!data.ok) {
        this.lastRejectedAnswer = data.rejected_answer || answer
        if (data.code === "unknown") this.showMissing(this.lastRejectedAnswer)
        this.statusTarget.textContent = data.error || "That answer cannot be played."
        this.answerTarget.focus()
        return
      }

      this.lastRejectedAnswer = null
      this.points += 1
      this.usedFamilyIds = data.used_family_ids || this.usedFamilyIds
      this.appendChainEntry("You", data.user)
      if (data.computer) this.appendChainEntry("Computer", data.computer)
      this.answerTarget.value = ""
      this.renderScore()

      if (data.round_over) {
        this.currentFormId = data.current_form_id
        if (data.computer) this.renderCurrent(data.computer)
        await this.finishRound(data)
        return
      }

      this.currentFormId = data.current_form_id
      this.renderCurrent(data.computer)
      this.statusTarget.textContent = instructionFor(data.computer)
      this.answerTarget.focus()
    } catch (error) {
      this.showError(error.message)
    } finally {
      this.setTurnBusy(false)
    }
  }

  async forfeit() {
    if (!this.roundActive || !this.currentFormId) return

    this.setTurnBusy(true)
    try {
      await this.showAlternatives({
        heading: "You could have continued with",
        explanation: "These are up to five legal continuations from the current junction. They are shown only after you give up the round.",
      })
      this.statusTarget.textContent = "Round forfeited. Review the possible continuations, then start a new round when ready."
      this.endRound()
    } catch (error) {
      this.showError(error.message)
    } finally {
      this.setTurnBusy(false)
    }
  }

  async hint() {
    if (this.modeTarget.value !== "zen" || !this.roundActive || !this.currentFormId) return

    this.setTurnBusy(true)
    try {
      await this.showAlternatives({
        heading: "Zen hint",
        explanation: "Practice mode can reveal up to five possible continuations without ending the round.",
      })
      this.statusTarget.textContent = "Hint shown. You can still type any legal Chengyu; you do not have to use one of these."
      this.answerTarget.focus()
    } catch (error) {
      this.showError(error.message)
    } finally {
      this.setTurnBusy(false)
    }
  }

  answerChanged() {
    this.hideMissing()
    this.reportStatusTarget.textContent = ""
  }

  async reportMissing() {
    const answer = (this.lastRejectedAnswer || this.answerTarget.value || "").trim()
    if (!answer) return

    this.reportButtonTarget.disabled = true
    this.reportStatusTarget.textContent = "Submitting review ticket…"

    try {
      const response = await fetch("/api/tickets", {
        method: "POST",
        credentials: "same-origin",
        headers: { "Content-Type": "application/json", "Accept": "application/json" },
        body: JSON.stringify({
          title: `Missing Chengyu: ${answer}`,
          summary: `Chengyu Jielong rejected ${answer} because it was not present in the imported Chengyu corpus.`,
          reasoning: "Please verify whether this is an attested Chengyu and, if so, add or source it for the Chengyu dataset.",
          source: "chengyu_jielong",
          target_ref: `chengyu/${answer}`,
          evidence_links: [],
        }),
      })
      const data = await response.json()
      if (!response.ok || !data.ok) throw new Error(data.error || `Ticket request failed (${response.status})`)

      this.reportStatusTarget.replaceChildren(
        document.createTextNode("Submitted. Save this Ticket Key: "),
        strongText(data.ticket_key || "(key unavailable)"),
      )
    } catch (error) {
      this.reportStatusTarget.textContent = error.message
      this.reportButtonTarget.disabled = false
    }
  }

  async showAlternatives({ heading, explanation }) {
    const data = await this.postJson(this.alternativesUrlValue, {
      current_form_id: this.currentFormId,
      used_family_ids: this.usedFamilyIds,
      mode: this.modeTarget.value,
      opponent: this.opponentTarget.value,
      score: this.points,
    })
    if (!data.ok) throw new Error(data.error || "Could not load alternatives.")

    this.alternativesHeadingTarget.textContent = heading
    this.alternativesExplanationTarget.textContent = explanation
    this.alternativesTarget.replaceChildren()

    const alternatives = data.alternatives || []
    if (alternatives.length === 0) {
      this.alternativesTarget.appendChild(paragraph("No legal continuation remains from this junction."))
    } else {
      alternatives.forEach((entry) => this.alternativesTarget.appendChild(this.entryCard(entry, { compact: true })))
    }
    this.alternativesPanelTarget.hidden = false
  }

  async finishRound(data) {
    const won = data.outcome === "computer_stuck"
    this.statusTarget.textContent = data.message || (won ? "You completed the chain." : "No legal continuation remains.")
    this.endRound()

    if (!won && data.computer && this.currentFormId) {
      try {
        await this.showAlternatives({
          heading: "The chain ended here",
          explanation: "No legal unused continuation remains from this final character in the current mode.",
        })
      } catch (_error) {
        // The round result itself is already valid; a failed explanatory lookup
        // should not replace it with an error.
      }
    }
  }

  endRound() {
    this.roundActive = false
    this.answerTarget.disabled = true
    this.submitButtonTarget.disabled = true
    this.forfeitButtonTarget.disabled = true
    this.hintButtonTarget.disabled = true
    this.startButtonTarget.disabled = false
    this.modeTarget.disabled = false
    this.opponentTarget.disabled = false
    this.saveBestScore()
    this.renderScore()
  }

  renderCurrent(entry) {
    this.currentCardTarget.replaceChildren(this.entryCard(entry))
    this.requiredCharacterTarget.textContent = entry?.last_character || "—"
  }

  appendChainEntry(owner, entry) {
    if (!entry) return
    const wrapper = document.createElement("article")
    wrapper.className = `chengyu-chain-entry chengyu-chain-entry--${owner === "You" ? "player" : "computer"}`
    const label = document.createElement("div")
    label.className = "chengyu-chain-entry__owner"
    label.textContent = owner
    wrapper.append(label, this.entryCard(entry, { compact: true }))
    this.chainTarget.appendChild(wrapper)
  }

  entryCard(entry, { compact = false } = {}) {
    const card = document.createElement("div")
    card.className = `chengyu-entry-card${compact ? " chengyu-entry-card--compact" : ""}`

    const head = document.createElement("div")
    head.className = "chengyu-entry-card__head"
    const word = document.createElement("strong")
    word.className = "chengyu-entry-card__word"
    word.textContent = entry?.text || entry?.display_form || ""
    head.appendChild(word)

    if (entry?.forms?.length > 1) {
      const forms = document.createElement("span")
      forms.className = "chengyu-entry-card__forms"
      forms.textContent = entry.forms.filter((form) => form !== entry.text).slice(0, 4).join(" · ")
      if (forms.textContent) head.appendChild(forms)
    }
    card.appendChild(head)

    if (entry?.languages?.length) {
      const languages = document.createElement("div")
      languages.className = "chengyu-entry-card__languages"
      entry.languages.forEach((language) => languages.appendChild(badge(language)))
      card.appendChild(languages)
    }

    if (entry?.readings?.length) {
      const readings = document.createElement("dl")
      readings.className = "chengyu-entry-card__readings"
      entry.readings.slice(0, compact ? 3 : 6).forEach((reading) => {
        const dt = document.createElement("dt")
        dt.textContent = [reading.language, reading.system].filter(Boolean).join(" · ")
        const dd = document.createElement("dd")
        dd.textContent = reading.reading || ""
        readings.append(dt, dd)
      })
      card.appendChild(readings)
    }

    if (entry?.senses?.length) {
      const sense = document.createElement("p")
      sense.className = "chengyu-entry-card__sense"
      sense.textContent = entry.senses[0].text || ""
      card.appendChild(sense)
    }

    if (!compact && entry?.etymologies?.length) {
      const details = document.createElement("details")
      details.className = "chengyu-entry-card__etymology"
      const summary = document.createElement("summary")
      summary.textContent = "Etymology / origin notes"
      details.appendChild(summary)
      entry.etymologies.slice(0, 2).forEach((row) => {
        const p = paragraph(row.text || "")
        details.appendChild(p)
      })
      card.appendChild(details)
    }

    const studyLinks = document.createElement("div")
    studyLinks.className = "chengyu-entry-card__study-links"

    if (entry?.corpus_search_url) {
      const searchLink = document.createElement("a")
      searchLink.href = entry.corpus_search_url
      searchLink.target = "_blank"
      searchLink.rel = "noopener"
      searchLink.textContent = "Search corpus"
      studyLinks.appendChild(searchLink)
    }

    if (entry?.corpus_contexts?.length) {
      entry.corpus_contexts.slice(0, compact ? 2 : 4).forEach((context) => {
        if (!context?.url) return
        const link = document.createElement("a")
        link.href = context.url
        link.target = "_blank"
        link.rel = "noopener"
        link.textContent = `Source context — ${context.label || context.matched_text || "corpus"}`
        studyLinks.appendChild(link)
      })
    }

    if (studyLinks.childElementCount) card.appendChild(studyLinks)

    if (entry?.sources?.length) {
      const sources = document.createElement("div")
      sources.className = "chengyu-entry-card__sources"
      entry.sources.slice(0, compact ? 3 : 6).forEach((source) => {
        if (!source.url) return
        const link = document.createElement("a")
        link.href = source.url
        link.target = "_blank"
        link.rel = "noopener"
        link.textContent = source.site || source.page_title || "Wiktionary"
        sources.appendChild(link)
      })
      if (sources.childElementCount) card.appendChild(sources)
    }

    return card
  }

  showMissing(answer) {
    this.missingPanelTarget.hidden = false
    this.reportStatusTarget.textContent = `Rejected spelling: ${answer}`
    this.reportButtonTarget.disabled = false
  }

  hideMissing() {
    this.missingPanelTarget.hidden = true
    this.reportStatusTarget.textContent = ""
  }

  hideAlternatives() {
    this.alternativesPanelTarget.hidden = true
    this.alternativesTarget.replaceChildren()
  }

  renderScore() {
    if (this.modeTarget.value === "zen") {
      this.scoreTarget.textContent = "禪 Zen practice · no score"
      return
    }
    const best = Number(localStorage.getItem(this.bestScoreKey()) || 0)
    this.scoreTarget.textContent = `Score ${this.points} · Best ${Math.max(best, this.points)}`
  }

  saveBestScore() {
    if (this.modeTarget.value === "zen") return
    const key = this.bestScoreKey()
    const best = Number(localStorage.getItem(key) || 0)
    if (this.points > best) localStorage.setItem(key, String(this.points))
  }

  bestScoreKey() {
    return `fanya.chengyu-jielong.best.${this.modeTarget.value}`
  }

  setBusy(busy) {
    this.startButtonTarget.disabled = busy || this.roundActive
  }

  setTurnBusy(busy) {
    this.submitButtonTarget.disabled = busy || !this.roundActive
    this.forfeitButtonTarget.disabled = busy || !this.roundActive
    this.hintButtonTarget.disabled = busy || !this.roundActive
    this.answerTarget.disabled = busy || !this.roundActive
  }

  showError(message) {
    this.statusTarget.textContent = message || "Something went wrong."
  }

  async postJson(url, payload) {
    const response = await fetch(url, {
      method: "POST",
      credentials: "same-origin",
      headers: {
        "Content-Type": "application/json",
        "Accept": "application/json",
        "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || "",
      },
      body: JSON.stringify(payload),
    })
    const data = await response.json().catch(() => ({ ok: false, error: `Request failed (${response.status})` }))
    if (!response.ok && response.status >= 500) throw new Error(data.error || `Request failed (${response.status})`)
    return data
  }
}

function instructionFor(entry) {
  const last = entry?.last_character || "the final character"
  return `Your turn: type a Chengyu beginning with ${last}.`
}

function badge(text) {
  const span = document.createElement("span")
  span.className = "chengyu-language-badge"
  span.textContent = text
  return span
}

function paragraph(text) {
  const p = document.createElement("p")
  p.textContent = text
  return p
}

function strongText(text) {
  const strong = document.createElement("strong")
  strong.textContent = text
  return strong
}
