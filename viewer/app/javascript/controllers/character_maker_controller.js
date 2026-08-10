import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { searchUrl: String }
  static targets = ["status", "matches"]

  connect() {
    this.timer = null
    this.abortController = null
    this.expression = "?"
  }

  disconnect() {
    window.clearTimeout(this.timer)
    this.abortController?.abort()
  }

  constructorChanged(event) {
    this.expression = event.detail.expression || "?"
    window.clearTimeout(this.timer)
    this.timer = window.setTimeout(() => this.lookup(), 140)
  }

  async lookup() {
    const expression = this.expression
    this.abortController?.abort()
    this.matchesTarget.replaceChildren()

    if (!expression || expression === "?") {
      this.statusTarget.textContent = "Start adding an IDS operator or component."
      return
    }

    const incomplete = expression.includes("?")
    this.statusTarget.textContent = incomplete
      ? "Showing structural possibilities while you fill the remaining slots."
      : "Looking for an exact encoded character."

    let rows = await this.fetchResults(expression, incomplete ? "fuzzy" : "exact")
    if (!incomplete && rows.length === 0) {
      this.statusTarget.textContent = "No exact encoded match. Here are the closest imported structures."
      rows = await this.fetchResults(expression, "fuzzy")
    }

    if (rows.length === 0) {
      this.statusTarget.textContent = incomplete
        ? "No imported structures match this partial construction yet."
        : "No imported character matches this structure."
      return
    }

    if (!incomplete && rows.some((row) => row.normalized_expression === expression)) {
      this.statusTarget.textContent = "Exact imported match."
    }

    this.matchesTarget.replaceChildren(...rows.slice(0, 12).map((row) => this.matchCard(row)))
  }

  async fetchResults(expression, mode) {
    this.abortController?.abort()
    this.abortController = new AbortController()
    const url = new URL(this.searchUrlValue || "/characters/structure.json", window.location.origin)
    url.searchParams.set("q", expression)
    url.searchParams.set("mode", mode)
    url.searchParams.set("limit", "12")
    url.searchParams.set("include", "definition")

    try {
      const response = await fetch(url, {
        headers: { Accept: "application/json" },
        signal: this.abortController.signal,
      })
      if (!response.ok) throw new Error(`structure lookup failed (${response.status})`)
      return await response.json()
    } catch (error) {
      if (error.name === "AbortError") return []
      this.statusTarget.textContent = "The structure lookup failed. Try again."
      return []
    }
  }

  matchCard(row) {
    const article = document.createElement("article")
    article.className = "character-maker-match"

    const link = document.createElement("a")
    link.className = "character-maker-match__glyph"
    link.href = `/characters/${encodeURIComponent(row.codepoint)}`
    link.textContent = row.character

    const details = document.createElement("div")
    const expression = document.createElement("code")
    expression.textContent = row.expression
    details.append(expression)

    const meta = document.createElement("div")
    meta.className = "muted"
    const score = typeof row.score === "number" ? ` · ${Math.round(row.score * 100)}% structural match` : ""
    meta.textContent = `${row.codepoint}${score}`
    details.append(meta)

    if (row.definition) {
      const definition = document.createElement("p")
      definition.className = "character-maker-match__definition"
      definition.textContent = row.definition
      details.append(definition)
    }

    article.append(link, details)
    return article
  }
}
