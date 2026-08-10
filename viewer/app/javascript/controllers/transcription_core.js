export function graphemes(text) {
  if (typeof Intl !== "undefined" && Intl.Segmenter) {
    const segmenter = new Intl.Segmenter(undefined, { granularity: "grapheme" })
    return Array.from(segmenter.segment(text), (entry) => entry.segment)
  }
  return Array.from(text)
}

export function isPlayableCharacter(token) {
  const codepoints = Array.from(token)
  if (codepoints.length !== 1) return false

  // The practice engine is script-neutral. Letters cover Han/Kana/Hangul,
  // numbers cover Suzhou/counting-rod forms, and symbols cover encoded CJK
  // strokes/components used by IDS data. Punctuation remains display-only.
  return /^[\p{Letter}\p{Number}\p{Symbol}\p{Mark}]$/u.test(token)
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
      supported: () => true,
      equivalents: (token) => [token.canonical],
      display: (canonical) => canonical,
      ...options,
    }
    this.tokens = graphemes(text).map((canonical, index) => {
      const display = this.options.display(canonical)
      return {
      canonical,
      text: display,
      index,
      playable: isPlayableCharacter(canonical),
      supported: !isPlayableCharacter(canonical) || this.options.supported(display),
      status: "future",
      attempts: 0,
      skipped: false,
      startedAt: null,
      completedAt: null,
      durationMs: null,
    }
    })
    this.score = 0
    this.correct = 0
    this.startedAt = performance.now()
    this.completedAt = null
    this.currentIndex = this.findNextPlayable(-1)
    this.markCurrent()
  }

  get current() {
    return this.currentIndex === null ? null : this.tokens[this.currentIndex]
  }

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
    this.currentIndex = this.findNextPlayable(this.currentIndex)
    if (this.currentIndex === null) {
      this.completedAt = performance.now()
    } else {
      this.markCurrent()
    }
  }

  findNextPlayable(afterIndex) {
    for (let index = afterIndex + 1; index < this.tokens.length; index += 1) {
      const token = this.tokens[index]
      if (!token.playable) {
        token.status = "past"
        continue
      }
      if (!token.supported) {
        token.status = "unsupported"
        continue
      }
      return index
    }
    return null
  }

  markCurrent() {
    const token = this.current
    if (!token) return
    token.status = "current"
    token.startedAt = performance.now()
  }

  elapsedMs() {
    return (this.completedAt || performance.now()) - this.startedAt
  }

  report() {
    const attempted = this.tokens.filter((token) => token.playable && token.supported && (token.completedAt || token.attempts > 0))
    const unsupported = this.tokens.filter((token) => token.playable && !token.supported)
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
      unsupported: unsupported.length,
      elapsedMs: this.elapsedMs(),
      difficult,
    }
  }
}

function difficulty(token) {
  return (token.skipped ? 100000 : 0) + (token.attempts * 10000) + (token.durationMs || 0)
}

export class YourInputMethodAdapter {
  constructor(onCommit) {
    this.onCommit = onCommit
  }

  handleInput(value) {
    graphemes(value).forEach((token) => this.onCommit(token))
  }
}

// A deliberately tiny boundary for the browser RIME runtime. The learning
// engine only needs committed characters and a way to ask whether a target is
// representable. The runtime itself remains RIME and can be replaced/upgraded
// without changing SessionEngine or the views.
export class RimeAdapter {
  constructor(runtime, schemaId, onCommit) {
    this.runtime = runtime
    this.schemaId = schemaId
    this.onCommit = onCommit
    this.session = null
  }

  async connect() {
    if (!this.runtime?.createSession) throw new Error("RIME browser runtime is unavailable")
    this.session = await this.runtime.createSession({ schemaId: this.schemaId, onCommit: this.onCommit })
    return this.session
  }

  async supports(character) {
    if (!this.session?.supports) return true
    return this.session.supports(character)
  }

  async key(event) {
    if (!this.session?.key) return false
    return this.session.key(event)
  }

  disconnect() {
    this.session?.destroy?.()
    this.session = null
  }
}
