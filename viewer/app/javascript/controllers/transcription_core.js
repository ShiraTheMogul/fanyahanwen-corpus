export function graphemes(text) {
  if (typeof Intl !== "undefined" && Intl.Segmenter) {
    const segmenter = new Intl.Segmenter(undefined, { granularity: "grapheme" })
    return Array.from(segmenter.segment(text), (entry) => entry.segment)
  }
  return Array.from(text)
}

// Transcription uses the same practical idea as the Corpus Viewer's
// "no punctuation" display: punctuation and spacing are not exercise tokens at
// all.  Everything else is left to the learner's input method.  In particular,
// the browser/system IME is never second-guessed by a database support check.
export function isPracticeToken(token) {
  const value = token.toString()
  if (!value) return false
  if (/^[\p{Punctuation}\p{Separator}\p{Control}]+$/u.test(value)) return false
  if (/^\s+$/u.test(value)) return false
  return true
}

export function practiceGraphemes(text) {
  return graphemes(text).filter((token) => isPracticeToken(token))
}

export function stripPracticePunctuation(text) {
  return practiceGraphemes(text).join("")
}

export function fingerprint(text) {
  let hash = 2166136261
  for (const character of text) {
    hash ^= character.codePointAt(0)
    hash = Math.imul(hash, 16777619)
  }
  return (hash >>> 0).toString(16).padStart(8, "0")
}

export class SessionEngine {
  constructor(text, options = {}) {
    this.options = {
      hard: false,
      zen: false,
      variantMode: "canonical",
      equivalents: (token) => [token.canonical],
      display: (canonical) => canonical,
      ...options,
    }

    // Do the expensive segmentation exactly once.  The previous implementation
    // retained punctuation/spacing and then asked every render whether each
    // token was playable/supported.  Long texts do not need that work.
    this.tokens = practiceGraphemes(text).map((canonical, index) => ({
      canonical,
      text: this.options.display(canonical),
      index,
      status: "future",
      attempts: 0,
      skipped: false,
      startedAt: null,
      completedAt: null,
      durationMs: null,
    }))

    this.score = 0
    this.correct = 0
    this.startedAt = performance.now()
    this.completedAt = null
    this.currentIndex = this.tokens.length > 0 ? 0 : null
    this.markCurrent()
  }

  get current() { return this.currentIndex === null ? null : this.tokens[this.currentIndex] }

  submit(value) {
    const token = this.current
    if (!token) return { type: "complete" }
    token.attempts += 1
    const accepted = this.options.equivalents(token)
    if (!accepted.includes(value)) return { type: "incorrect", token }

    token.status = "past"
    token.completedAt = performance.now()
    token.durationMs = token.completedAt - token.startedAt
    this.score += 1
    this.correct += 1
    this.advance()
    return { type: this.current ? "correct" : "complete", token }
  }

  skip() {
    const token = this.current
    if (!token || this.options.hard) return { type: "blocked" }
    token.status = "past"
    token.skipped = true
    token.completedAt = performance.now()
    token.durationMs = token.completedAt - token.startedAt
    this.score -= 10
    this.advance()
    return { type: this.current ? "skipped" : "complete", token }
  }

  advance() {
    const next = this.currentIndex === null ? null : this.currentIndex + 1
    this.currentIndex = next !== null && next < this.tokens.length ? next : null
    if (this.currentIndex === null) this.completedAt = performance.now()
    else this.markCurrent()
  }

  markCurrent() {
    const token = this.current
    if (!token) return
    token.status = "current"
    token.startedAt = performance.now()
  }

  elapsedMs() { return (this.completedAt || performance.now()) - this.startedAt }

  report() {
    const attempted = this.tokens.filter((token) => token.completedAt || token.attempts > 0)
    const elapsedMinutes = Math.max(this.elapsedMs() / 60000, 1 / 60)
    const speedBonus = Math.floor((this.correct / elapsedMinutes) / 20)
    const firstTry = attempted.filter((token) => !token.skipped && token.attempts === 1).length
    const difficult = [...attempted]
      .filter((token) => token.skipped || token.attempts > 1 || token.durationMs >= 5000)
      .sort((a, b) => difficulty(b) - difficulty(a))

    return {
      score: this.score + speedBonus,
      baseScore: this.score,
      speedBonus,
      correct: this.correct,
      firstTry,
      attempted: attempted.length,
      elapsedMs: this.elapsedMs(),
      difficult,
    }
  }
}

function difficulty(token) {
  return (token.skipped ? 100000 : 0) + (token.attempts * 10000) + (token.durationMs || 0)
}

export class YourInputMethodAdapter {
  constructor(onCommit) { this.onCommit = onCommit }

  // Spaces/punctuation are controls for many IMEs and are never answers in the
  // exercise.  Ignore them if a browser happens to expose them as committed
  // input; compare every other committed grapheme directly with the target.
  handleInput(value) {
    practiceGraphemes(value).forEach((token) => this.onCommit(token))
  }
}

// Browser-side helper backed by the RIME dictionaries already imported into
// CharacterInputCode. This is deliberately not labelled as librime: Latin key
// sequences are only a way to choose a Han character, and the transcription
// engine scores the committed Han character, never the ASCII code itself.
export class RimeDictionaryAdapter {
  constructor({ systemId, endpoint = "/characters/input_codes.json", onCommit, onCandidates }) {
    this.systemId = systemId
    this.endpoint = endpoint
    this.onCommit = onCommit
    this.onCandidates = onCandidates
    this.candidates = []
    this.abortController = null
    this.cache = new Map()
    this.timer = null
    this.revealCandidates = false
  }

  setRevealCandidates(value) {
    this.revealCandidates = Boolean(value)
    if (!this.revealCandidates) {
      window.clearTimeout(this.timer)
      this.candidates = []
      this.onCandidates([])
    }
  }

  update(code) {
    const query = code.trim()
    if (!query || !this.revealCandidates) {
      this.candidates = []
      this.onCandidates([])
      return
    }

    window.clearTimeout(this.timer)
    this.timer = window.setTimeout(async () => {
      const rows = await this.lookup(query, "prefix")
      this.candidates = rows
      this.onCandidates(rows, query)
    }, 100)
  }

  async commitCode(code) {
    const query = code.trim()
    if (!query) return { committed: false, reason: "empty" }

    if (this.revealCandidates && this.candidates.length > 0) {
      return { committed: this.choose(0), reason: "candidate" }
    }

    const rows = await this.lookup(query, "exact")
    this.candidates = rows

    if (rows.length === 1) {
      this.onCommit(rows[0].character)
      return { committed: true, reason: "unique" }
    }

    if (rows.length > 1) {
      return { committed: false, reason: "ambiguous", count: rows.length }
    }

    return { committed: false, reason: "none" }
  }

  async lookup(query, match = "prefix") {
    const cacheKey = `${match}:${query}`
    if (this.cache.has(cacheKey)) return this.cache.get(cacheKey)

    this.abortController?.abort()
    this.abortController = new AbortController()
    const url = new URL(this.endpoint, window.location.origin)
    url.searchParams.set("system_id", this.systemId)
    url.searchParams.set("q", query)
    url.searchParams.set("match", match)
    url.searchParams.set("limit", "12")

    try {
      const response = await fetch(url, {
        headers: { Accept: "application/json" },
        signal: this.abortController.signal,
      })
      if (!response.ok) throw new Error(`candidate lookup failed (${response.status})`)
      const rows = await response.json()
      this.cache.set(cacheKey, rows)
      return rows
    } catch (error) {
      if (error.name === "AbortError") return []
      this.candidates = []
      this.onCandidates([], query, error)
      return []
    }
  }

  choose(index = 0) {
    const candidate = this.candidates[index]
    if (!candidate?.character) return false
    this.onCommit(candidate.character)
    return true
  }

  disconnect() {
    window.clearTimeout(this.timer)
    this.abortController?.abort()
    this.abortController = null
    this.candidates = []
  }
}
