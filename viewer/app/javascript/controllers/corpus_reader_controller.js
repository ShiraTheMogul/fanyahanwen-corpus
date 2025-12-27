import { Controller } from "@hotwired/stimulus"

// Client-side view controls for the corpus reader. Client-side is used as it allows for instant changes. This makes the site run a bit faster!
//
// Features:
// - Vertical layout toggle (writing-mode: vertical-rl)
// - Three colours; bamboo yellow, white, and black.
// - Punctuation stripping (DOM-safe: only touches text nodes)
//
// State is stored in localStorage so it persists across page loads.
export default class extends Controller {
  static targets = ["viewbox", "content", "verticalBtn", "themeBtn", "punctBtn"]

  connect() {
    this._onExternalOptions = (ev) => {
      if (!ev?.detail) return
      this._setState(ev.detail)
      this._apply()
    }
    window.addEventListener("corpus-view-options", this._onExternalOptions)

    this._originalHTML = this.contentTarget.innerHTML
    this._strippedHTML = null
    this._state = this._loadState()
    this._apply()
  }

  disconnect() {
    window.removeEventListener("corpus-view-options", this._onExternalOptions)
  }

  toggleVertical() {
    this._state.vertical = !this._state.vertical
    this._saveState()
    this._apply()
    this._broadcast()
  }

  cycleTheme() {
    const order = ["light", "bamboo", "dark"]
    const idx = order.indexOf(this._state.theme)
    this._state.theme = order[(idx + 1) % order.length]
    this._saveState()
    this._apply()
    this._broadcast()
  }

  togglePunct() {
    this._state.strip = !this._state.strip
    this._saveState()
    this._apply()
    this._broadcast()
  }

  // ---- internals ----

  _loadState() {
    const getBool = (k, fallback) => {
      const v = window.localStorage.getItem(k)
      if (v === null || v === undefined || v === "") return fallback
      return v === "1"
    }

    const getStr = (k, fallback) => {
      const v = window.localStorage.getItem(k)
      if (v === null || v === undefined || v === "") return fallback
      return v.toString()
    }

    const getInt = (k, fallback) => {
      const v = window.localStorage.getItem(k)
      const n = parseInt(v || "", 10)
      return Number.isFinite(n) ? n : fallback
    }

    return {
      vertical: getBool("corpus.vertical", false),
      vflow: getStr("corpus.verticalFlow", "rl"),
      theme: getStr("corpus.theme", "bamboo"),
      strip: getBool("corpus.stripPunct", false),
      fontSizePx: getInt("corpus.fontSizePx", 20),
      rubyOnDemand: getBool("corpus.rubyOnDemand", false),
    }
  }

  _saveState() {
    window.localStorage.setItem("corpus.vertical", this._state.vertical ? "1" : "0")
    window.localStorage.setItem("corpus.verticalFlow", (this._state.vflow || "rl").toString())
    window.localStorage.setItem("corpus.theme", (this._state.theme || "bamboo").toString())
    window.localStorage.setItem("corpus.stripPunct", this._state.strip ? "1" : "0")
    window.localStorage.setItem("corpus.fontSizePx", (this._state.fontSizePx || 20).toString())
    window.localStorage.setItem("corpus.rubyOnDemand", this._state.rubyOnDemand ? "1" : "0")
  }

  _setState(next) {
    if (typeof next.vertical !== "undefined") this._state.vertical = !!next.vertical
    if (typeof next.vflow !== "undefined") this._state.vflow = (next.vflow || "rl").toString()
    if (typeof next.theme !== "undefined") this._state.theme = (next.theme || "bamboo").toString()
    if (typeof next.strip !== "undefined") this._state.strip = !!next.strip
    if (typeof next.fontSizePx !== "undefined") {
      const n = parseInt(next.fontSizePx, 10)
      if (Number.isFinite(n)) this._state.fontSizePx = n
    }
    if (typeof next.rubyOnDemand !== "undefined") this._state.rubyOnDemand = !!next.rubyOnDemand
    this._saveState()
  }

  _broadcast() {
    // Notify the rightbar controller (and any other listeners) of state changes.
    window.dispatchEvent(new CustomEvent("corpus-view-options", { detail: { ...this._state } }))
  }

  _apply() {
    const { vertical, vflow, theme, strip, fontSizePx } = this._state

    // Layout classes on the scroll box.
    this.viewboxTarget.classList.toggle("is-vertical", vertical)
    this.viewboxTarget.classList.toggle("is-vflow-lr", vertical && (vflow === "lr"))
    this.viewboxTarget.classList.remove("theme-light", "theme-bamboo", "theme-dark")
    this.viewboxTarget.classList.add(`theme-${(theme || "bamboo")}`)

    // Font size via CSS variable.
    if (Number.isFinite(fontSizePx)) {
      this.viewboxTarget.style.setProperty("--cv-font-size", `${fontSizePx}px`)
    }

    // Orientation class on the content.
    this.contentTarget.classList.toggle("is-vertical", vertical)
    this.contentTarget.classList.toggle("is-vflow-lr", vertical && (vflow === "lr"))

    // Buttons are optional targets (defensive in case the toolbar is removed).
    if (this.hasVerticalBtnTarget) this.verticalBtnTarget.setAttribute("aria-pressed", vertical ? "true" : "false")
    if (this.hasThemeBtnTarget) {
      this.themeBtnTarget.setAttribute("aria-pressed", "true")
      const t = (theme || "bamboo").toString()
      const label = (t === "light") ? "White" : (t === "dark") ? "Dark" : "Bamboo"
      this.themeBtnTarget.textContent = `Theme: ${label}`
    }
    if (this.hasPunctBtnTarget) this.punctBtnTarget.setAttribute("aria-pressed", strip ? "true" : "false")

    // Punctuation stripping (cached)
    this.contentTarget.innerHTML = strip ? this._getStrippedHTML() : this._originalHTML


    this._updateRubySpacing()
    // When switching to vertical layout, ensure the "first" column is visible.
    // For the standard right-to-left vertical flow, that means scrolling to the far right.
    if (vertical) {
      const wantRight = (vflow !== "lr")
      window.requestAnimationFrame(() => {
        this.viewboxTarget.scrollLeft = wantRight ? this.viewboxTarget.scrollWidth : 0
      })
    }
  }

  

  
  _updateRubySpacing() {
    // When ruby is present, give the reader a little extra line spacing so
    // readings never collide with line breaks. Works for both full ruby and
    // on-demand ruby.
    const hasRuby = !!this.contentTarget.querySelector("ruby")
    this.contentTarget.classList.toggle("has-ruby", hasRuby)
    this.viewboxTarget.classList.toggle("has-ruby", hasRuby)
  }

// Right-click → toggle ruby for the clicked character (on-demand mode).
  // This avoids pre-wrapping the whole text (fast) while still letting learners reveal readings.
  onContextMenu(event) {
    if (!this._state?.rubyOnDemand) return
    if (!event) return
    // Only handle the actual context menu event (right click / long press).
    event.preventDefault()

    const picked = this._pickHanAtPoint(event)
    if (!picked) return

    // If we're already on an on-demand ruby, unwrap it.
    const rubyEl = event.target?.closest?.("ruby.ruby-ondemand")
    if (rubyEl) {
      const base = this._rubyBaseText(rubyEl)
      rubyEl.replaceWith(document.createTextNode(base))
      this._updateRubySpacing()
      return
    }

    // Don't mess with server-rendered ruby (full ruby mode).
    if (event.target?.closest?.("ruby")) return

    this._toggleOnDemandRuby(picked).catch(() => {})
  }

  async _toggleOnDemandRuby(picked) {
    const { node, idx, len, ch } = picked
    if (!node || typeof idx !== "number" || !len || !ch) return

    // Safety: never inject ruby inside <rt>/<rp>. 
	// For some reason this was a bug like three times when making this it scarred me for life!!!
    const parentEl = node.parentElement
    if (parentEl && parentEl.closest && parentEl.closest("rt, rp")) return

    const reading = await this._rubyReadingFor(ch)
    if (!reading) return

    const full = node.nodeValue || ""
    const before = full.slice(0, idx)
    const after = full.slice(idx + len)

    const ruby = document.createElement("ruby")
    ruby.className = "ruby-annot ruby-ondemand"
    ruby.setAttribute("data-ondemand", "1")
    ruby.appendChild(document.createTextNode(ch))

    const rt = document.createElement("rt")
    rt.appendChild(document.createTextNode(reading))
    ruby.appendChild(rt)

    const p = node.parentNode
    if (!p) return
    if (before) p.insertBefore(document.createTextNode(before), node)
    p.insertBefore(ruby, node)
    if (after) p.insertBefore(document.createTextNode(after), node)
    p.removeChild(node)
    this._updateRubySpacing()
  }

  _rubyBaseText(rubyEl) {
    // Find the base glyph text inside <ruby>, ignoring <rt>/<rp>.
    for (const child of Array.from(rubyEl.childNodes || [])) {
      if (child.nodeType === Node.ELEMENT_NODE) {
        const tag = child.tagName
        if (tag === "RT" || tag === "RP") continue
      }
      const t = child.textContent || ""
      if (t) return t
    }
    // Fallback: strip readings from textContent.
    return (rubyEl.textContent || "").split(/\s+/)[0] || ""
  }

  async _rubyReadingFor(ch) {
    this._rubyCache ||= new Map()
    const cached = this._rubyCache.get(ch)
    if (cached) return cached

    // LocalStorage cache across sessions (best-effort; capped via a small key list).
    const storeKey = `corpus.rubyCache.${ch}`
    const v = window.localStorage.getItem(storeKey)
    if (v) {
      this._rubyCache.set(ch, v)
      return v
    }

    const res = await fetch(`/characters/${encodeURIComponent(ch)}/preview?force_ruby=1`, {
      headers: { Accept: "application/json" },
      credentials: "same-origin",
    })
    if (!res.ok) return null
    const data = await res.json()
    const reading = data?.ruby?.reading
    if (!reading) return null

    this._rubyCache.set(ch, reading)
    try {
      window.localStorage.setItem(storeKey, reading)
      this._rememberRubyCacheKey(storeKey)
    } catch {
      // ignore storage failures
    }
    return reading
  }

  _rememberRubyCacheKey(storeKey) {
    // Maintain a tiny FIFO list so we can prune older cache keys.
    const listKey = "corpus.rubyCache.keys"
    let keys = []
    try {
      keys = JSON.parse(window.localStorage.getItem(listKey) || "[]")
      if (!Array.isArray(keys)) keys = []
    } catch {
      keys = []
    }

    if (!keys.includes(storeKey)) keys.push(storeKey)

    const MAX = 800
    while (keys.length > MAX) {
      const k = keys.shift()
      if (k) window.localStorage.removeItem(k)
    }
    window.localStorage.setItem(listKey, JSON.stringify(keys))
  }

  _pickHanAtPoint(event) {
    const x = event.clientX
    const y = event.clientY

    let node = null
    let offset = null

    if (document.caretPositionFromPoint) {
      const pos = document.caretPositionFromPoint(x, y)
      node = pos?.offsetNode || null
      offset = typeof pos?.offset === "number" ? pos.offset : null
    } else if (document.caretRangeFromPoint) {
      const range = document.caretRangeFromPoint(x, y)
      node = range?.startContainer || null
      offset = typeof range?.startOffset === "number" ? range.startOffset : null
    }

    if (!node || node.nodeType !== Node.TEXT_NODE || typeof offset !== "number") return null
    const text = node.nodeValue || ""
    if (!text) return null

    const idx0 = Math.max(0, Math.min(offset, text.length - 1))
    // Handle surrogate pairs.
    const code = text.charCodeAt(idx0)
    let idx = idx0
    if (code >= 0xDC00 && code <= 0xDFFF && idx > 0) idx -= 1

    const cp = text.codePointAt(idx)
    if (!cp) return null
    const ch = String.fromCodePoint(cp)
    const len = cp > 0xFFFF ? 2 : 1

    // Only Han.
    if (!(/\p{Script=Han}/u.test(ch))) return null

    return { ch, node, idx, len }
  }
_getStrippedHTML() {
    if (this._strippedHTML) return this._strippedHTML

    const tmp = document.createElement("div")
    tmp.innerHTML = this._originalHTML
    this._stripPunctuation(tmp)

    this._strippedHTML = tmp.innerHTML
    return this._strippedHTML
  }

  _stripPunctuation(root) {
    // Covers ASCII + common CJK punctuation + fullwidth variants.
    const PUNCT_RE = /[\u2000-\u206F\u2E00-\u2E7F\u3000-\u303F\uFE10-\uFE1F\uFE30-\uFE4F\uFF00-\uFF65!"#$%&'()*+,\-.\/:;<=>?@[\\\]^_`{|}~]/g

    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT)
    let node
    while ((node = walker.nextNode())) {
      // Never strip punctuation inside ruby readings.
	  // This protects reconstructed pronunciations, Wade-Giles, etc, where you'll see asterisks and apostrophes. Maybe there's a topolect that uses ! for a glottal or something. 
      const p = node.parentElement
      if (p && p.closest && p.closest("rt, rp")) continue
      node.nodeValue = (node.nodeValue || "").replace(PUNCT_RE, "")
    }
  }
}
