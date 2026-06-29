import { Controller } from "@hotwired/stimulus"
import { t } from "i18n"

// Client-side view controls for the corpus reader. Client-side is used as it allows for instant changes. This makes the site run a bit faster!
//
// Features:
// - Vertical layout toggle (writing-mode: vertical-rl)
// - Three colours; bamboo yellow, white, and black.
// - Punctuation stripping (DOM-safe: only touches text nodes)
//
// State is stored in localStorage so it persists across page loads.
export default class extends Controller {
    static targets = ["viewbox", "content", "verticalBtn", "themeBtn", "punctBtn", "punctColorBtn", "judouBtn", "judouMenuBtn", "punctPresetBtn", "punctMenuBtn", "judouMenu", "punctOverlay", "punctPanel", "punctOkBtn", "punctCloseBtn", "verticalQuoteFormsChk"]
    static values = { translationMode: Boolean, translationId: String }


  connect() {
    this._onExternalOptions = (ev) => {
      if (!ev?.detail) return
      this._setState(ev.detail)
      this._syncPunctButtons()
      const nxt = (ev.detail?.punctPreset || ev.detail?.punct?.preset || "").toString()
      if (nxt === "custom") this._setPunctOpen(true)
      this._apply()
    }
    window.addEventListener("corpus-view-options", this._onExternalOptions)

    // Some pages (e.g., Xuanji Tu) replace the reader content dynamically.
    // When that happens, refresh the baseline so option toggles never revert
    // to a stale cached version.
    this._onRefreshBaseline = () => {
      this.refreshBaseline()
    }
    window.addEventListener("corpus-reader-refresh", this._onRefreshBaseline)

    this._originalHTML = this.contentTarget.innerHTML
    this._strippedHTML = null
    this._state = this._loadState()
    this._punct = this._loadPunct()
    this._justToggledOrientation = false

    this._onScroll = () => { this._saveScrollLeft() }
    this.viewboxTarget.addEventListener("scroll", this._onScroll, { passive: true })

    this._onWheel = (ev) => {
      if (!this._state.vertical) return
      // In vertical writing-mode we want mousewheel to advance columns.
      // Translate vertical wheel delta into horizontal scroll.
      const box = this.viewboxTarget
      if (!box) return
      if (Math.abs(ev.deltaY) < 0.01) return
      ev.preventDefault()
      box.scrollLeft += ev.deltaY
      this._saveScrollLeft()
    }
    this.viewboxTarget.addEventListener("wheel", this._onWheel, { passive: false })

    this._onKeydown = (e) => { if (e.key === "Escape" && this._isPunctOpen()) { e.preventDefault(); this.closePunctMenu() } }
    window.addEventListener("keydown", this._onKeydown)

    this._apply()
  }

  disconnect() {
    window.removeEventListener("corpus-view-options", this._onExternalOptions)
    window.removeEventListener("corpus-reader-refresh", this._onRefreshBaseline)
    if (this._onScroll) this.viewboxTarget.removeEventListener("scroll", this._onScroll)
    if (this._onWheel) this.viewboxTarget.removeEventListener("wheel", this._onWheel)
    if (this._onKeydown) window.removeEventListener("keydown", this._onKeydown)
  }

  // ---- punctuation presets + options (display-only) ----
  // Stored separately from core layout state so we can evolve the UI without breaking older saves.

  _loadPunct() {
    const getStr = (k, fallback) => {
      const v = window.localStorage.getItem(k)
      if (v === null || v === undefined || v === "") return fallback
      return v.toString()
    }
    const getBool = (k, fallback) => {
      const v = window.localStorage.getItem(k)
      if (v === null || v === undefined || v === "") return fallback
      return v === "1"
    }

    return {
      preset: getStr("corpus.punctPreset", "modern_trad"),
      userOverrodeVerticalQuotes: getBool("corpus.punctUserOverrodeVQ", false),
      options: {
        quoteFamily: getStr("corpus.quoteFamily", "corner"),     // corner | speech_curly | speech_fullwidth | off
        quoteOrder: getStr("corpus.quoteOrder", "trad"),         // trad | simp
        verticalQuoteForms: getBool("corpus.verticalQuoteForms", false),
        semicolon: getStr("corpus.punctSemi", "keep"),           // keep | collapse
        colon: getStr("corpus.punctColon", "keep"),
        question: getStr("corpus.punctQ", "keep"),
        exclamation: getStr("corpus.punctEx", "keep"),
        comma: getStr("corpus.punctComma", "keep"),              // keep | dunhao
      }
    }
  }

  _savePunct() {
    const p = (this._punct?.preset || "source").toString()
    window.localStorage.setItem("corpus.punctPreset", p)
    window.localStorage.setItem("corpus.punctUserOverrodeVQ", this._punct?.userOverrodeVerticalQuotes ? "1" : "0")
    const o = this._punct?.options || {}
    window.localStorage.setItem("corpus.quoteFamily", (o.quoteFamily || "corner").toString())
    window.localStorage.setItem("corpus.quoteOrder", (o.quoteOrder || "trad").toString())
    window.localStorage.setItem("corpus.verticalQuoteForms", o.verticalQuoteForms ? "1" : "0")
    window.localStorage.setItem("corpus.punctSemi", (o.semicolon || "keep").toString())
    window.localStorage.setItem("corpus.punctColon", (o.colon || "keep").toString())
    window.localStorage.setItem("corpus.punctQ", (o.question || "keep").toString())
    window.localStorage.setItem("corpus.punctEx", (o.exclamation || "keep").toString())
    window.localStorage.setItem("corpus.punctComma", (o.comma || "keep").toString())
  }

  _presetOptions(preset) {
    const o = {
      quoteFamily: "corner",
      quoteOrder: "trad",
      verticalQuoteForms: false,
      semicolon: "keep",
      colon: "keep",
      question: "keep",
      exclamation: "keep",
      comma: "keep",
    }

    if (preset === "source") return o
    if (preset === "strip") return o

    if (preset === "modern_trad") {
      o.quoteFamily = "corner"
      o.quoteOrder = "trad"
      return o
    }

    if (preset === "modern_prc") {
      // PRC: horizontal prefers speech marks, vertical prefers corner brackets.
      o.quoteFamily = "speech_curly"
      o.quoteOrder = "simp"
      return o
    }

    if (preset === "pure") {
      o.quoteFamily = "corner"
      o.quoteOrder = "trad"
      o.comma = "dunhao"
      o.semicolon = "collapse"
      o.colon = "collapse"
      o.question = "collapse"
      o.exclamation = "collapse"
      return o
    }

    return o
  }

  _syncPunctButtons() {
    if (!this.hasPunctPresetBtnTarget) return
    const p = (this._punct?.preset || "source").toString()
    const label = {
      source: t("corpus_reader.punctuation.source"),
      modern_trad: t("corpus_reader.punctuation.modern_traditional"),
      modern_prc: t("corpus_reader.punctuation.modern_prc"),
      pure: t("corpus_reader.punctuation.pure"),
      strip: t("corpus_reader.punctuation.strip"),
      custom: t("corpus_reader.punctuation.custom"),
    }[p] || t("corpus_reader.punctuation.label")
    this.punctPresetBtnTarget.textContent = label
  }

  _isPunctOpen() {
    return this.hasPunctOverlayTarget && !this.punctOverlayTarget.hasAttribute("hidden")
  }

  _setPunctOpen(open) {
    if (!this.hasPunctOverlayTarget) return
    if (open) {
      this.punctOverlayTarget.removeAttribute("hidden")
      this._syncPunctMenuInputs()
    } else {
      this.punctOverlayTarget.setAttribute("hidden", "")
    }
  }

  _syncPunctMenuInputs() {
    const setRadio = (name, value) => {
      const el = this.element.querySelector(`input[name="${name}"][value="${value}"]`)
      if (el) el.checked = true
    }

    setRadio("cv_preset", this._punct?.preset || "source")
    const o = this._punct?.options || this._presetOptions("source")
    setRadio("cv_quote_family", o.quoteFamily)
    setRadio("cv_quote_order", o.quoteOrder)
    setRadio("cv_semi", o.semicolon)
    setRadio("cv_colon", o.colon)
    setRadio("cv_q", o.question)
    setRadio("cv_ex", o.exclamation)
    setRadio("cv_comma", o.comma)

    setRadio("cv_repeat_mark", (this._state?.jpRepeatMark || "none").toString())

    if (this.hasVerticalQuoteFormsChkTarget) {
      this.verticalQuoteFormsChkTarget.checked = !!o.verticalQuoteForms
    }
  }

  _ensureVerticalQuoteDefaultOnce() {
    if (!this._state?.vertical) return
    if (this._punct?.userOverrodeVerticalQuotes) return
    if (!this._punct?.options?.verticalQuoteForms) {
      this._punct.options = { ...this._punct.options, verticalQuoteForms: true }
      this._savePunct()
    }
  }

  _convertPunctuationHTML(html, preset) {
    const parser = new DOMParser()
    const doc = parser.parseFromString(`<div>${html}</div>`, "text/html")
    const root = doc.body.firstElementChild

    let opts = this._punct?.options || this._presetOptions("source")
    if (preset !== "custom") opts = this._presetOptions(preset)

    if (preset === "modern_prc" && this._state?.vertical) {
      opts = { ...opts, quoteFamily: "corner" }
    }

    if (this._state?.vertical) {
      this._ensureVerticalQuoteDefaultOnce()
      opts = { ...opts, verticalQuoteForms: this._punct?.options?.verticalQuoteForms }
    }

    const qc = new QuoteConverter(opts)

    const walker = doc.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
      acceptNode: (n) => {
        const p = n.parentElement
        if (!p) return NodeFilter.FILTER_REJECT
        if (p.closest("rt, rp")) return NodeFilter.FILTER_REJECT
        return NodeFilter.FILTER_ACCEPT
      }
    })

    while (walker.nextNode()) {
      const n = walker.currentNode
      let t = n.nodeValue || ""
      t = convertPuncText(t, opts)
      t = qc.convert(t)
      n.nodeValue = t
    }

    return root.innerHTML
  }

  // ---- punctuation UI actions ----

  cyclePunctPreset() {
    const order = ["source", "modern_trad", "modern_prc", "pure", "strip", "custom"]
    const cur = (this._punct?.preset || "source").toString()
    const idx = order.indexOf(cur)
    const nxt = order[(idx + 1) % order.length]

    this._punct.preset = nxt
    if (nxt !== "custom") this._punct.options = this._presetOptions(nxt)

    // keep legacy strip state in sync (rightbar may still toggle it)
    this._state.strip = (nxt === "strip")

    this._saveState()
    this._savePunct()
    this._syncPunctButtons()
    this._apply()
    this._broadcast()
  }

  togglePunctMenu() { this._setPunctOpen(!this._isPunctOpen()) }
  closePunctMenu() { this._setPunctOpen(false) }
  okPunctMenu() { this._setPunctOpen(false) }

  onPunctOverlayClick(e) {
    if (e.target === this.punctOverlayTarget) this.closePunctMenu()
  }

  setPunctPresetRadio(e) {
    const v = e?.target?.value || "source"
    this._punct.preset = v
    if (v !== "custom") this._punct.options = this._presetOptions(v)
    this._state.strip = (v === "strip")

    this._saveState()
    this._savePunct()
    this._syncPunctButtons()
    this._apply()
    this._broadcast()
  }

  setPunctOptionRadio() {
    this._punct.preset = "custom"
    const pick = (name) => {
      const el = this.element.querySelector(`input[name="${name}"]:checked`)
      return el ? el.value : null
    }

    const o = { ...(this._punct.options || this._presetOptions("source")) }
    const fam = pick("cv_quote_family"); if (fam) o.quoteFamily = fam
    const ord = pick("cv_quote_order"); if (ord) o.quoteOrder = ord
    const semi = pick("cv_semi"); if (semi) o.semicolon = semi
    const colon = pick("cv_colon"); if (colon) o.colon = colon
    const q = pick("cv_q"); if (q) o.question = q
    const ex = pick("cv_ex"); if (ex) o.exclamation = ex
    const comma = pick("cv_comma"); if (comma) o.comma = comma

    this._punct.options = o
    this._state.strip = false

    this._saveState()
    this._savePunct()
    this._syncPunctButtons()
    this._apply()
    this._broadcast()
  }

  toggleVerticalQuoteForms() {
    this._punct.preset = "custom"
    this._punct.userOverrodeVerticalQuotes = true
    this._punct.options = { ...(this._punct.options || {}), verticalQuoteForms: !!this.verticalQuoteFormsChkTarget.checked }
    this._savePunct()
    this._syncPunctButtons()
    this._apply()
    this._broadcast()
  }



  toggleVertical() {
    this._state.vertical = !this._state.vertical
    this._saveState()
    this._justToggledOrientation = true
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

  toggleJudou() {
    this._state.judouOn = !this._state.judouOn
    this._saveState()
    this._apply()
    this._broadcast()
  }

  toggleJudouMenu() {
    if (!this.hasJudouMenuTarget) return
    const isHidden = this.judouMenuTarget.hasAttribute("hidden")
    if (isHidden) {
      this.judouMenuTarget.removeAttribute("hidden")
    } else {
      this.judouMenuTarget.setAttribute("hidden", "")
    }
  }

  closeJudouMenu() {
    if (!this.hasJudouMenuTarget) return
    this.judouMenuTarget.setAttribute("hidden", "")
  }

  setJudouOption(ev) {
    const t = ev && ev.target ? ev.target : null
    if (!t) return
    const key = t.getAttribute("data-judou-key")
    const checked = !!t.checked
    if (key === "punct") {
      this._state.judouPunctOn = checked
    } else if (key === "underline") {
      this._state.judouUnderlineOn = checked
    } else {
      return
    }
    this._saveState()
    this._apply()
    this._broadcast()
  }

  cyclePunctColor() {
    const order = ["red", "black", "white", "blue", "yellow"]
    const cur = (this._state.punctColor || "red").toString()
    const idx = order.indexOf(cur)
    this._state.punctColor = order[(idx + 1) % order.length]
    this._saveState()
    this._apply()
    this._broadcast()
  }


  // ---- Punctuation presets + options (display-only) ----
  // "Strip" is identical to the rightbar option.

  cyclePunctPreset() {
    const order = ["source", "modern_trad", "modern_prc", "pure", "strip", "custom"]
    const cur = (this._punct.preset || "source").toString()
    const idx = order.indexOf(cur)
    const nxt = order[(idx + 1) % order.length]

    this._punct.preset = nxt
    if (nxt !== "custom") this._punct.options = this._presetOptions(nxt)

    this._state.strip = (nxt === "strip")
    this._saveState()
    this._savePunct()

    this._syncPunctButtons()
      this._apply()
    this._broadcast()
  }

  togglePunctMenu() {
    this._setPunctOpen(!this._isPunctOpen())
  }

  closePunctMenu() { this._setPunctOpen(false) }
  okPunctMenu() { this._setPunctOpen(false) }

  onPunctOverlayClick(e) {
    if (e.target === this.punctOverlayTarget) this.closePunctMenu()
  }

  setPunctPresetRadio(e) {
    const v = e?.target?.value || "source"
    this._punct.preset = v
    if (v !== "custom") this._punct.options = this._presetOptions(v)

    this._state.strip = (v === "strip")
    this._saveState()
    this._savePunct()

    this._syncPunctButtons()
      this._apply()
    this._broadcast()
  }

  setPunctOptionRadio() {
    this._punct.preset = "custom"
    const pick = (name) => {
      const el = this.element.querySelector(`input[name="${name}"]:checked`)
      return el ? el.value : null
    }
    const o = { ...this._punct.options }

    const fam = pick("cv_quote_family"); if (fam) o.quoteFamily = fam
    const ord = pick("cv_quote_order"); if (ord) o.quoteOrder = ord

    const semi = pick("cv_semi"); if (semi) o.semicolon = semi
    const colon = pick("cv_colon"); if (colon) o.colon = colon
    const q = pick("cv_q"); if (q) o.question = q
    const ex = pick("cv_ex"); if (ex) o.exclamation = ex
    const comma = pick("cv_comma"); if (comma) o.comma = comma

    this._punct.options = o
    this._state.strip = false
    this._saveState()
    this._savePunct()

    this._syncPunctButtons()
      this._apply()
    this._broadcast()
  }

  toggleVerticalQuoteForms() {
    this._punct.preset = "custom"
    this._punct.userOverrodeVerticalQuotes = true
    this._punct.options = { ...this._punct.options, verticalQuoteForms: !!this.verticalQuoteFormsChkTarget.checked }
    this._savePunct()

    this._syncPunctButtons()
      this._apply()
    this._broadcast()
  }


  togglePunct() {
    // Legacy: rightbar may still call this.
    const nowStrip = !this._state.strip
    this._state.strip = nowStrip
    this._punct.preset = nowStrip ? "strip" : "source"
    if (this._punct.preset !== "custom") this._punct.options = this._presetOptions(this._punct.preset)
    this._saveState()
    this._savePunct()
    this._syncPunctButtons()
      this._apply()
    this._broadcast()
  }

  refreshBaseline() {
    // Update the cached baseline HTML to whatever is currently rendered.
    // This keeps punctuation stripping and other options consistent after
    // pages replace content (e.g., Xuanji output re-render).
    this._originalHTML = this.contentTarget.innerHTML
    this._strippedHTML = null
    this._apply()
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

  // Repetition mark (display-only).
  // Back-compat: if the old boolean toggle exists, treat it as the Japanese iteration mark.
  const rawMark = getStr("corpus.jpRepeatMark", "")
  const allowed = new Set(["none", "kanji", "vertical", "zhou"])
  let jpRepeatMark = allowed.has(rawMark) ? rawMark : "none"
  if (jpRepeatMark === "none" && getBool("corpus.jpRepeatParticle", false)) jpRepeatMark = "kanji"

  const orientationKey = this._orientationStorageKey()

  return {
    vertical: getBool(orientationKey, this.hasTranslationModeValue && this.translationModeValue ? false : true),
    vflow: getStr("corpus.verticalFlow", "rl"),
    theme: getStr("corpus.theme", "bamboo"),
    strip: getBool("corpus.stripPunct", false),
    jpRepeatMark,
    fontSizePx: getInt("corpus.fontSizePx", 20),
    rubyOnDemand: getBool("corpus.rubyOnDemand", false),
    judouOn: getBool("corpus.judouOn", true),
    judouPunctOn: getBool("corpus.judouPunctOn", true),
    judouUnderlineOn: getBool("corpus.judouUnderlineOn", true),
    punctColor: getStr("corpus.punctColor", "red"),
  }
}

  _orientationStorageKey() {
    if (this.hasTranslationModeValue && this.translationModeValue) {
      const id = this.hasTranslationIdValue ? this.translationIdValue.toString().trim() : ""
      return id ? `corpus.translation.vertical.${id}` : "corpus.translation.vertical"
    }
    return "corpus.vertical"
  }

  _saveState() {
  window.localStorage.setItem(this._orientationStorageKey(), this._state.vertical ? "1" : "0")
  if (this.hasTranslationModeValue && this.translationModeValue) return
  window.localStorage.setItem("corpus.verticalFlow", (this._state.vflow || "rl").toString())
  window.localStorage.setItem("corpus.theme", (this._state.theme || "bamboo").toString())
  window.localStorage.setItem("corpus.stripPunct", this._state.strip ? "1" : "0")
  window.localStorage.setItem("corpus.jpRepeatMark", (this._state.jpRepeatMark || "none").toString())
  window.localStorage.setItem("corpus.fontSizePx", (this._state.fontSizePx || 20).toString())
  window.localStorage.setItem("corpus.rubyOnDemand", this._state.rubyOnDemand ? "1" : "0")

  window.localStorage.setItem("corpus.judouOn", this._state.judouOn ? "1" : "0")
  window.localStorage.setItem("corpus.judouPunctOn", this._state.judouPunctOn ? "1" : "0")
  window.localStorage.setItem("corpus.judouUnderlineOn", this._state.judouUnderlineOn ? "1" : "0")
  window.localStorage.setItem("corpus.punctColor", (this._state.punctColor || "red").toString())
}

  _setState(next) {
    if (typeof next.vertical !== "undefined") this._state.vertical = !!next.vertical
    if (typeof next.vflow !== "undefined") this._state.vflow = (next.vflow || "rl").toString()
    if (typeof next.theme !== "undefined") this._state.theme = (next.theme || "bamboo").toString()
    if (typeof next.strip !== "undefined") this._state.strip = !!next.strip
    if (typeof next.jpRepeatMark !== "undefined") {
      const v = (next.jpRepeatMark || "none").toString()
      const allowed = new Set(["none", "kanji", "vertical", "zhou"])
      this._state.jpRepeatMark = allowed.has(v) ? v : "none"
    }
    if (typeof next.fontSizePx !== "undefined") {
      const n = parseInt(next.fontSizePx, 10)
      if (Number.isFinite(n)) this._state.fontSizePx = n
    }
    if (typeof next.rubyOnDemand !== "undefined") this._state.rubyOnDemand = !!next.rubyOnDemand
    this._saveState()
  }

  _broadcast() {
    // Global broadcast (listeners may include annotations controller).
    window.dispatchEvent(new CustomEvent("corpus-view-options", { detail: { ...this._state } }))

    // Local bubble for any nested listeners.
    this.element.dispatchEvent(new CustomEvent("corpus-reader-options", {
      detail: {
        judouOn: !!this._state.judouOn,
        judouPunctOn: !!this._state.judouPunctOn,
        judouUnderlineOn: !!this._state.judouUnderlineOn,
        punctPreset: this._punctPreset
      },
      bubbles: true
    }))
  }
  _captureScrollState() {
    // Preserve reading position across re-renders (changing punctuation, ruby spacing, etc.)
    const el = this.viewboxTarget
    const maxX = Math.max(1, el.scrollWidth - el.clientWidth)
    const maxY = Math.max(1, el.scrollHeight - el.clientHeight)
    return {
      x: el.scrollLeft,
      y: el.scrollTop,
      rx: el.scrollLeft / maxX,
      ry: el.scrollTop / maxY,
      vertical: !!this._state.vertical,
      vflow: (this._state.vflow || "rl").toString(),
    }
  }

  _restoreScrollState(s) {
    if (!s) return
    const el = this.viewboxTarget
    const maxX = Math.max(0, el.scrollWidth - el.clientWidth)
    const maxY = Math.max(0, el.scrollHeight - el.clientHeight)

    // Prefer ratio restore (handles layout width/height changes). Fall back to absolute.
    const nx = Number.isFinite(s.rx) ? Math.round(s.rx * maxX) : (Number.isFinite(s.x) ? s.x : 0)
    const ny = Number.isFinite(s.ry) ? Math.round(s.ry * maxY) : (Number.isFinite(s.y) ? s.y : 0)

    el.scrollLeft = Math.max(0, Math.min(maxX, nx))
    el.scrollTop  = Math.max(0, Math.min(maxY, ny))
  }


  _apply() {
    const { vertical, vflow, theme, strip, fontSizePx } = this._state
    const translationMode = this.hasTranslationModeValue && this.translationModeValue

    const scrollState = this._captureScrollState()

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
    this.contentTarget.classList.toggle("judou-on", !translationMode && vertical && !!this._state.judouOn && !!this._state.judouPunctOn)
    this.contentTarget.classList.toggle("judou-underline-on", !translationMode && vertical && !!this._state.judouOn && !!this._state.judouUnderlineOn)

    // Buttons are optional targets.
    if (this.hasVerticalBtnTarget) {
      this.verticalBtnTarget.setAttribute("aria-pressed", vertical ? "true" : "false")
      if (translationMode) this.verticalBtnTarget.textContent = vertical ? t("corpus_reader.orientation.vertical") : t("corpus_reader.orientation.horizontal")
    }
    if (this.hasThemeBtnTarget) {
      this.themeBtnTarget.setAttribute("aria-pressed", "true")
      const themeName = (theme || "bamboo").toString()
      const label = (themeName === "light") ? t("corpus_reader.themes.light") : (themeName === "dark") ? t("corpus_reader.themes.dark") : t("corpus_reader.themes.bamboo")
      this.themeBtnTarget.textContent = t("corpus_reader.theme", { label })
    }
    if (this.hasPunctBtnTarget) this.punctBtnTarget.setAttribute("aria-pressed", strip ? "true" : "false")
    if (this.hasJudouBtnTarget) {
      this.judouBtnTarget.setAttribute("aria-pressed", this._state.judouOn ? "true" : "false")
      this.judouBtnTarget.textContent = this._state.judouOn ? t("corpus_reader.judou.on") : t("corpus_reader.judou.off")
    }

    // Sync Judou submenu checkboxes (punctuation vs underlining)
    if (this.hasJudouMenuTarget) {
      const punctChk = this.judouMenuTarget.querySelector('input[data-judou-opt="punct"]')
      const ulChk = this.judouMenuTarget.querySelector('input[data-judou-opt="underline"]')
      if (punctChk) punctChk.checked = !!this._state.judouPunctOn
      if (ulChk) ulChk.checked = !!this._state.judouUnderlineOn
    }
    if (this.hasPunctColorBtnTarget) {
      const c = (this._state.punctColor || "red").toString()
      const colorLabel = t(`corpus_reader.colors.${c}`)
      this.punctColorBtnTarget.textContent = t("corpus_reader.dot_color", { color: colorLabel })
    }

    // Punctuation rendering:
    // - "Source" = untouched
    // - "Strip" = get rid of punctuation
    // - Others = display-only conversion of punctuation + quotes
    const preset = translationMode ? "source" : (this._punct?.preset || "source").toString()

    if (!translationMode && (strip || preset === "strip")) {
      this.contentTarget.innerHTML = this._getStrippedHTML()
    } else if (preset === "source") {
      this.contentTarget.innerHTML = this._originalHTML
    } else {
      this.contentTarget.innerHTML = this._convertPunctuationHTML(this._originalHTML, preset)
    }

    if (!translationMode) {
      this._applyRepeatMark()
      this._applyJudouColor()
      this._applyJudouWrappers()
    }

    this._updateRubySpacing()

    // Restore reading position after re-render.
    window.requestAnimationFrame(() => {
      this._restoreScrollState(scrollState)

      // Only do the "jump to edge" behavior when the user actually toggled orientation/flow.
      if (this._justToggledOrientation && vertical) {
        const wantRight = (vflow !== "lr")
        this.viewboxTarget.scrollLeft = wantRight ? this.viewboxTarget.scrollWidth : 0
      }
      this._justToggledOrientation = false
      window.dispatchEvent(new CustomEvent("corpus-reader-applied"))
    })

  }


setRepeatMarkRadio(e) {
  const v = (e?.target?.value || "none").toString()
  const allowed = new Set(["none", "kanji", "vertical", "zhou"])
  this._state.jpRepeatMark = allowed.has(v) ? v : "none"
  this._saveState()
  this._apply()
  this._broadcast()
}

_repeatMarkChar() {
  const v = (this._state?.jpRepeatMark || "none").toString()
  if (v === "kanji") return "々"
  if (v === "vertical") return "〻"
  if (v === "zhou") return "㆓" // this is technically the kanbun character, but it actually ends up looking good and working well compared to the standard 二, so I like it.
  return null
}

_applyRepeatMark() {
  // Display-only: replace consecutive identical Han characters with an iteration mark.
  // - none: do nothing
  // - kanji: 々
  // - vertical: 〻
  // - zhou: ㆓
  // In horizontal mode (non-vertical), the mark is rendered as a subscript via CSS.

  const markChar = this._repeatMarkChar()
  if (!markChar) return

  const root = this.contentTarget
  if (!root) return

  const isVertical = !!this._state?.vertical

  const makeMarkEl = () => {
    const s = document.createElement("span")
    s.className = isVertical ? "jp-repeat-mark" : "jp-repeat-mark jp-repeat-sub"
    s.textContent = markChar
    return s
  }

  const isHan = (ch) => {
    try {
      return /^\p{Script=Han}$/u.test(ch)
    } catch (_e) {
      // Very old browsers: fall back to a conservative CJK range.
      return /^[\u3400-\u9FFF]$/.test(ch)
    }
  }

  // Walk all text nodes outside ruby <rt>/<rp>.
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
    acceptNode: (n) => {
      const p = n.parentElement
      if (!p) return NodeFilter.FILTER_REJECT
      if (p.closest("rt, rp")) return NodeFilter.FILTER_REJECT
      return NodeFilter.FILTER_ACCEPT
    }
  })

  const nodes = []
  while (walker.nextNode()) nodes.push(walker.currentNode)

  let prevHan = null

  for (const node of nodes) {
    const txt = node.nodeValue || ""
    if (txt.length === 0) continue

    // If the node is exactly one Han character, we can do the cross-node boundary logic.
    if (txt.length === 1 && isHan(txt)) {
      if (prevHan && txt === prevHan) {
        node.parentNode.replaceChild(makeMarkEl(), node)
        // Keep prevHan unchanged: AAAA => A + mark + mark + mark (predictable).
      } else {
        prevHan = txt
      }
      continue
    }

    // Multi-character node: do in-node run replacement.
    // Example: 人人人 => 人 + mark + mark
    const frag = document.createDocumentFragment()
    let i = 0
    let sawAny = false

    while (i < txt.length) {
      const ch = txt[i]
      if (isHan(ch)) {
        // Count run length of identical Han characters.
        let j = i + 1
        while (j < txt.length && txt[j] === ch) j++
        const runLen = j - i

        frag.appendChild(document.createTextNode(ch))
        for (let k = 1; k < runLen; k++) frag.appendChild(makeMarkEl())

        sawAny = sawAny || (runLen > 1)
        prevHan = ch
        i = j
        continue
      }

      // Non-Han: copy as-is and reset boundary tracking.
      frag.appendChild(document.createTextNode(ch))
      prevHan = null
      i++
    }

    if (sawAny) {
      node.parentNode.replaceChild(frag, node)
    } else {
      // Still reset boundary when a node isn't a single Han character.
      prevHan = null
    }
  }
}

  

  
  // === Scroll persistence per page ===
  _scrollKey() { return `corpus.scrollLeft:${window.location.pathname}` }
  _maxScrollLeft() {
    const maxLeft = this.viewboxTarget.scrollWidth - this.viewboxTarget.clientWidth
    return (maxLeft > 0) ? maxLeft : 0
  }
  _saveScrollLeft() {
    try { sessionStorage.setItem(this._scrollKey(), String(this.viewboxTarget.scrollLeft)) } catch (_) {}
  }
  _restoreScrollLeft() {
    try {
      const v = sessionStorage.getItem(this._scrollKey())
      if (v === null) return false
      const n = Number(v)
      if (!Number.isFinite(n)) return false
      this.viewboxTarget.scrollLeft = n
      return true
    } catch (_) { return false }
  }

  // === Judou wrapping + colour ===
  _applyJudouColor() {
    const cur = (this._state.punctColor || "red").toString()
    const map = { red:"#b00000", black:"#111111", white:"#f3f3f3", blue:"#1b4fd6", yellow:"#c9a100" }
    this.viewboxTarget.style.setProperty("--cv-judou-color", map[cur] || map.red)
  }

  _wrapJudouInNode(node) {
    const re = /[。、，；：？！,.;:?!]/g
    const txt = node.nodeValue
    if (!txt || !re.test(txt)) return
    re.lastIndex = 0
    const frag = document.createDocumentFragment()
    let last = 0
    for (const m of txt.matchAll(re)) {
      const i = m.index
      if (i > last) frag.appendChild(document.createTextNode(txt.slice(last, i)))
      const span = document.createElement("span")
      span.className = "cv-judou"
      span.textContent = m[0]
      frag.appendChild(span)
      last = i + m[0].length
    }
    if (last < txt.length) frag.appendChild(document.createTextNode(txt.slice(last)))
    node.parentNode.replaceChild(frag, node)
  }

  _applyJudouWrappers() {
    // Wrap punctuation in spans so CSS can position/style it in vertical mode.
    const root = this.contentTarget
    if (!root) return
    // Avoid double-wrapping: if we already have cv-judou spans, assume wrapped.
    if (root.querySelector(".cv-judou")) return
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
      acceptNode: (n) => {
        const p = n.parentElement
        if (!p) return NodeFilter.FILTER_REJECT
        if (p.closest("rt, rp")) return NodeFilter.FILTER_REJECT
        return NodeFilter.FILTER_ACCEPT
      }
    })
    const nodes = []
    while (walker.nextNode()) nodes.push(walker.currentNode)
    nodes.forEach(n => this._wrapJudouInNode(n))
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
    if (this.hasTranslationModeValue && this.translationModeValue) return
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
      if (p && p.closest && (p.closest("rt, rp") || p.closest(".xuanji-phon"))) continue
      node.nodeValue = (node.nodeValue || "").replace(PUNCT_RE, "")
    }
  }
}


// ---- Punctuation / quotation conversion helpers ----
function convertStrong(full, mode) { return (mode === "collapse") ? "。" : full }

function convertPuncText(text, opts) {
  let t = text

  // commas
  if (opts.comma === "dunhao") {
    t = t.replace(/,/g, "、").replace(/，/g, "、")
  } else {
    t = t.replace(/,/g, "，")
  }

  // periods (non-decimal)
  t = t.replace(/(?<!\d)\.(?!\d)/g, "。")

  // semicolon / colon / question / exclamation
  t = t.replace(/;/g, convertStrong("；", opts.semicolon)).replace(/；/g, convertStrong("；", opts.semicolon))
  t = t.replace(/:/g, convertStrong("：", opts.colon)).replace(/：/g, convertStrong("：", opts.colon))
  t = t.replace(/\?/g, convertStrong("？", opts.question)).replace(/？/g, convertStrong("？", opts.question))
  t = t.replace(/!/g, convertStrong("！", opts.exclamation)).replace(/！/g, convertStrong("！", opts.exclamation))

  return t
}

class QuoteConverter {
  constructor(opts) {
    this.opts = opts || {}
    // Stack stores the nesting kinds we opened: "outer" or "inner"
    this.stack = []
  }

  _isQuoteChar(ch) {
    return (
      ch === '"' || ch === "'" ||
      ch === "「" || ch === "」" || ch === "『" || ch === "』" ||
      ch === "﹁" || ch === "﹂" || ch === "﹃" || ch === "﹄" ||
      ch === "“" || ch === "”" || ch === "‘" || ch === "’" ||
      ch === "＂" || ch === "＇"
    )
  }

  _isOpenish(ch) {
    return (ch === "「" || ch === "『" || ch === "﹁" || ch === "﹃" || ch === "“" || ch === "‘")
  }

  _isCloseish(ch) {
    return (ch === "」" || ch === "』" || ch === "﹂" || ch === "﹄" || ch === "”" || ch === "’")
  }

  glyphs() {
    const fam = (this.opts.quoteFamily || "corner").toString()
    if (fam === "off") return null

    const order = (this.opts.quoteOrder || "trad").toString()

    // Corner brackets:
    // A = 「」 (or ﹁﹂), B = 『』 (or ﹃﹄)
    let A_open = "「", A_close = "」"
    let B_open = "『", B_close = "』"
    if (fam === "corner" && !!this.opts.verticalQuoteForms) {
      A_open = "﹁"; A_close = "﹂"
      B_open = "﹃"; B_close = "﹄"
    }

    if (fam === "speech_curly") {
      // Latin speech marks: outer=“”, inner=‘’
      const outO = "“", outC = "”", inO = "‘", inC = "’"
      // "simp" ordering means outer uses single quotes, inner uses double quotes
      if (order === "simp") return { outerOpen: inO, outerClose: inC, innerOpen: outO, innerClose: outC }
      return { outerOpen: outO, outerClose: outC, innerOpen: inO, innerClose: inC }
    }

    if (fam === "speech_fullwidth") {
      // Chinese fullwidth speech marks: outer=＂＂, inner=＇＇
      const outO = "＂", outC = "＂", inO = "＇", inC = "＇"
      if (order === "simp") return { outerOpen: inO, outerClose: inC, innerOpen: outO, innerClose: outC }
      return { outerOpen: outO, outerClose: outC, innerOpen: inO, innerClose: inC }
    }

    // corner family ordering
    if (order === "simp") {
      // Simplified ordering: outer=『』, inner=「」
      return { outerOpen: B_open, outerClose: B_close, innerOpen: A_open, innerClose: A_close }
    }
    // Traditional: outer=「」, inner=『』
    return { outerOpen: A_open, outerClose: A_close, innerOpen: B_open, innerClose: B_close }
  }

  convert(text) {
    const g = this.glyphs()
    if (!g) return text

    let out = ""
    for (const ch of text) {
      if (!this._isQuoteChar(ch)) { out += ch; continue }

      // Determine whether this is an open or close based on the source char when possible.
      const isOpen = this._isOpenish(ch)
      const isClose = this._isCloseish(ch)

      if (isOpen) {
        const kind = (this.stack.length === 0) ? "outer" : "inner"
        this.stack.push(kind)
        out += (kind === "outer") ? g.outerOpen : g.innerOpen
        continue
      }

      if (isClose) {
        const kind = this.stack.pop() || ((this.stack.length === 0) ? "outer" : "inner")
        out += (kind === "outer") ? g.outerClose : g.innerClose
        continue
      }

      // Neutral quotes (", ', ＂, ＇): toggle heuristically.
      // If we are inside outer but not yet inside inner, assume open inner first.
      if (this.stack.length === 1 && this.stack[0] === "outer") {
        this.stack.push("inner")
        out += g.innerOpen
        continue
      }

      if (this.stack.length > 0) {
        const kind = this.stack.pop()
        out += (kind === "outer") ? g.outerClose : g.innerClose
      } else {
        this.stack.push("outer")
        out += g.outerOpen
      }
    }
    return out
  }
}
