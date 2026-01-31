import { Controller } from "@hotwired/stimulus"

// User-contributed named-entity annotations for the corpus reader.
//
// How it works (high-level):
// 1) Server renders each original character as:
//      <span class="cch" data-corpus-idx="123">字</span>
//    (even when ruby <rt> exists)
// 2) When the user selects some text, we find the first/last cch spans in the
//    selection and treat that as a [start, end) character range.
// 3) We store ranges in JSON next to the corpus file and reload/re-apply later.
//
// Kinds:
// - title  (blue)
// - person (yellow)
// - place  (green)
// - office (red)
//
// Colours are controlled with CSS variables so users can override them (and use
// colourblind presets). This controller stores palette + options in localStorage.
export default class extends Controller {
  static shouldLoad() { return true }

  static targets = ["annotateBtn"]
  static values = {
    path: String,
    url: String
  }

  connect() {
    // Find the corpus textflow node; it already exists in the corpus-reader controller.
    this._contentEl = this.element.querySelector(".corpus-textflow")
    if (!this._contentEl) return

    this._items = []
    this._palette = this._loadPalette()
    this._titleMode = this._loadTitleMode()

    this._annotateEnabled = this._loadAnnotateEnabled()
    this._syncAnnotateBtn()

    this._applyPaletteToRoot()
    this._ensureUI()
    this._wireEvents()

    this._loadFromServer().then(() => {
      this._applyAllHighlights()
      this._applyAutoTitles()
    })
  }

  disconnect() {
    this._unwireEvents()
    this._hideMenu()
  }

  // ---------- annotate mode toggle ----------

  toggleAnnotate() {
    this._annotateEnabled = !this._annotateEnabled
    try { localStorage.setItem("corpus.annotate.enabled", this._annotateEnabled ? "1" : "0") } catch (_) {}
    this._syncAnnotateBtn()
    if (!this._annotateEnabled) this._hideMenu()
  }

  _loadAnnotateEnabled() {
    try {
      const v = localStorage.getItem("corpus.annotate.enabled")
      if (v === "1") return true
      if (v === "0") return false
    } catch (_) {}
    return false
  }

  _syncAnnotateBtn() {
    if (!this.hasAnnotateBtnTarget) return
    const on = !!this._annotateEnabled
    this.annotateBtnTarget.textContent = on ? "Annotate: On" : "Annotate: Off"
    this.annotateBtnTarget.setAttribute("aria-pressed", on ? "true" : "false")
  }


  // ---------- events ----------

  _wireEvents() {
    this._onMouseUp = (ev) => {
      // Small delay so window.getSelection() stabilizes.
      window.setTimeout(() => this._maybeOpenMenu(ev), 0)
    }
    this._contentEl.addEventListener("mouseup", this._onMouseUp)

    this._onKeyDown = (ev) => {
      if (ev.key === "Escape") this._hideMenu()
    }
    document.addEventListener("keydown", this._onKeyDown)
  }

  _unwireEvents() {
    if (this._onMouseUp) this._contentEl.removeEventListener("mouseup", this._onMouseUp)
    if (this._onKeyDown) document.removeEventListener("keydown", this._onKeyDown)
  }

  // ---------- loading / saving ----------

  async _loadFromServer() {
    const base = (this.urlValue || "/corpus_annotations").replace(/\/+$/, "")
    const url = `${base}?path=${encodeURIComponent(this.pathValue || "")}`
    try {
      const res = await fetch(url, { headers: { "Accept": "application/json" } })
      if (!res.ok) return
      const data = await res.json()
      this._items = Array.isArray(data?.items) ? data.items : []
    } catch (_) {
      // ignore: offline / no route yet
    }
  }

  async _saveToServer() {
    const base = (this.urlValue || "/corpus_annotations").replace(/\/+$/, "")
    const url = `${base}?path=${encodeURIComponent(this.pathValue || "")}`

    const token = document.querySelector("meta[name='csrf-token']")?.getAttribute("content") || ""

    const payload = { annotations: { version: 1, items: this._items } }

    const res = await fetch(url, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Accept": "application/json",
        "X-CSRF-Token": token
      },
      body: JSON.stringify(payload)
    })
    return res.ok
  }

  // ---------- selection -> range ----------

  _maybeOpenMenu(ev) {
    if (!this._annotateEnabled) { this._hideMenu(); return }

    const sel = window.getSelection()
    if (!sel || sel.isCollapsed) {
      this._hideMenu()
      return
    }

    const range = sel.getRangeAt(0)
    if (!range) return

    // Ensure the selection is within the corpus content.
    const common = range.commonAncestorContainer
    if (!this._contentEl.contains(common.nodeType === 1 ? common : common.parentElement)) return

    const bounds = range.getBoundingClientRect()
    if (!bounds || (bounds.width === 0 && bounds.height === 0)) return

    const [start, end] = this._selectionToCorpusRange(range)
    if (start == null || end == null || end <= start) return

    this._openMenuAt(bounds.left + window.scrollX, bounds.bottom + window.scrollY, start, end)
  }

  _selectionToCorpusRange(range) {
    const spans = this._contentEl.querySelectorAll("span.cch[data-corpus-idx]")
    if (!spans.length) return [null, null]

    // Collect all selected cch spans by intersecting the selection range with each span.
    // This is O(n) but fine for typical selection sizes; plus spans are cheap nodes.
    let min = null
    let max = null

    for (const sp of spans) {
      if (!range.intersectsNode(sp)) continue
      const idx = parseInt(sp.dataset.corpusIdx, 10)
      if (Number.isNaN(idx)) continue
      if (min == null || idx < min) min = idx
      if (max == null || idx > max) max = idx
    }

    if (min == null || max == null) return [null, null]
    return [min, max + 1] // convert to [start, end)
  }

  // ---------- applying highlights ----------

  _clearAllSpanClasses() {
    const spans = this._contentEl.querySelectorAll("span.cch")
    spans.forEach(sp => {
      sp.classList.remove("ne-title", "ne-person", "ne-place", "ne-office", "ne-title-auto")
    })
  }

  _applyAllHighlights() {
    this._clearAllSpanClasses()
    for (const it of this._items) {
      this._applyItem(it)
    }
  }

  _applyItem(it) {
    const kind = (it?.kind || "").toString()
    const start = parseInt(it?.start, 10)
    const end = parseInt(it?.end, 10)
    if (!Number.isFinite(start) || !Number.isFinite(end) || end <= start) return

    const cls = this._kindToClass(kind)
    if (!cls) return

    const spans = this._contentEl.querySelectorAll("span.cch[data-corpus-idx]")
    for (const sp of spans) {
      const idx = parseInt(sp.dataset.corpusIdx, 10)
      if (idx >= start && idx < end) sp.classList.add(cls)
    }
  }

  _kindToClass(kind) {
    switch (kind) {
      case "title": return "ne-title"
      case "person": return "ne-person"
      case "place": return "ne-place"
      case "office": return "ne-office"
      default: return null
    }
  }

  // ---------- auto-title highlighting by brackets ----------

  _applyAutoTitles() {
    // Remove only auto class, keep user annotations.
    this._contentEl.querySelectorAll("span.cch.ne-title-auto").forEach(sp => sp.classList.remove("ne-title-auto"))
    if (this._titleMode === "off") return

    const map = new Map()
    // Build an array of chars by idx.
    this._contentEl.querySelectorAll("span.cch[data-corpus-idx]").forEach(sp => {
      const idx = parseInt(sp.dataset.corpusIdx, 10)
      if (!Number.isNaN(idx)) map.set(idx, sp)
    })

    const getChar = (idx) => map.get(idx)?.textContent || ""
    const maxIdx = Math.max(...map.keys())

    const pairs = []
    if (this._titleMode === "square" || this._titleMode === "both") {
      pairs.push(["〖", "〗"])
      pairs.push(["【", "】"])
    }
    if (this._titleMode === "angle" || this._titleMode === "both") {
      pairs.push(["《", "》"])
    }

    // Scan left-to-right by index. (Treat each char as unit.)
    for (const [open, close] of pairs) {
      let i = 0
      while (i <= maxIdx) {
        if (getChar(i) !== open) { i += 1; continue }
        let j = i + 1
        while (j <= maxIdx && getChar(j) !== close) j += 1
        if (j <= maxIdx && getChar(j) === close) {
          for (let k = i; k <= j; k += 1) {
            const sp = map.get(k)
            if (sp) sp.classList.add("ne-title-auto")
          }
          i = j + 1
        } else {
          i += 1
        }
      }
    }
  }

  // ---------- UI ----------

  _ensureUI() {
    if (this._menuEl) return

    const menu = document.createElement("div")
    menu.className = "corpus-annot-menu"
    menu.innerHTML = `
      <div class="corpus-annot-row">
        <button type="button" data-kind="title">Title</button>
        <button type="button" data-kind="person">Person</button>
        <button type="button" data-kind="place">Place</button>
        <button type="button" data-kind="office">Office</button>
        <button type="button" data-kind="clear" class="danger">Clear</button>
      </div>
      <div class="corpus-annot-row">
        <label class="corpus-annot-label">Note</label>
        <input type="text" class="corpus-annot-note" placeholder="optional" />
      </div>
      <div class="corpus-annot-row">
        <button type="button" data-action="save" class="primary">Save</button>
        <button type="button" data-action="cancel">Cancel</button>
      </div>
      <hr />
      <div class="corpus-annot-row">
        <label class="corpus-annot-label">Auto titles</label>
        <select class="corpus-annot-select" data-action="titleMode">
          <option value="both">〖〗/【】 + 《》</option>
          <option value="square">〖〗/【】 only</option>
          <option value="angle">《》 only</option>
          <option value="off">Off</option>
        </select>
      </div>
      <div class="corpus-annot-row">
        <button type="button" data-action="colors">Colours…</button>
      </div>
    `
    document.body.appendChild(menu)
    this._menuEl = menu

    // Palette dialog
    const dlg = document.createElement("dialog")
    dlg.className = "corpus-annot-colors"
    dlg.innerHTML = `
      <form method="dialog">
        <h3>Entity colours</h3>
        <div class="corpus-annot-grid">
          <label>Title <input type="color" name="title" /></label>
          <label>Person <input type="color" name="person" /></label>
          <label>Place <input type="color" name="place" /></label>
          <label>Office <input type="color" name="office" /></label>
        </div>
        <div class="corpus-annot-row">
          <label class="corpus-annot-label">Preset</label>
          <select name="preset">
            <option value="default">Default</option>
            <option value="deuteranopia">Deuteranopia</option>
            <option value="protanopia">Protanopia</option>
            <option value="tritanopia">Tritanopia</option>
          </select>
        </div>
        <div class="corpus-annot-row">
          <button value="apply" class="primary">Apply</button>
          <button value="close">Close</button>
        </div>
      </form>
    `
    document.body.appendChild(dlg)
    this._colorsDlg = dlg
  }

  _openMenuAt(x, y, start, end) {
    this._activeRange = { start, end }

    // Prefill: if an item already exists matching this range, load its note.
    const existing = this._items.find(it => it.start === start && it.end === end)
    this._menuEl.querySelector(".corpus-annot-note").value = existing?.note || ""

    // Title mode select
    const sel = this._menuEl.querySelector("select[data-action='titleMode']")
    sel.value = this._titleMode

    // Position + show
    this._menuEl.style.left = `${Math.max(8, x)}px`
    this._menuEl.style.top = `${Math.max(8, y + 6)}px`
    this._menuEl.style.display = "block"

    // Button handlers (set once)
    if (!this._menuWired) {
      this._menuEl.addEventListener("click", (ev) => {
        const btn = ev.target.closest("button")
        if (!btn) return
        const kind = btn.dataset.kind
        const act = btn.dataset.action

        if (kind) this._chooseKind(kind)
        if (act === "save") this._saveActive()
        if (act === "cancel") this._hideMenu()
        if (act === "colors") this._openColors()
      })

      this._menuEl.querySelector("select[data-action='titleMode']").addEventListener("change", (ev) => {
        this._titleMode = ev.target.value
        this._saveTitleMode(this._titleMode)
        this._applyAutoTitles()
      })

      this._menuWired = true
    }
  }

  _hideMenu() {
    if (this._menuEl) this._menuEl.style.display = "none"
    this._activeRange = null
  }

  _chooseKind(kind) {
    if (!this._activeRange) return
    this._activeKind = kind
    // Light UI feedback (pressed state)
    this._menuEl.querySelectorAll("button[data-kind]").forEach(b => b.classList.toggle("selected", b.dataset.kind === kind))
  }

  async _saveActive() {
    if (!this._activeRange) return
    const { start, end } = this._activeRange
    const note = this._menuEl.querySelector(".corpus-annot-note").value || ""

    const kind = this._activeKind || "person"

    // Remove any existing item that overlaps exactly.
    this._items = this._items.filter(it => !(it.start === start && it.end === end))

    if (kind !== "clear") {
      this._items.push({ start, end, kind, note: note.trim() || undefined })
    }

    this._applyAllHighlights()
    this._applyAutoTitles()

    await this._saveToServer()
    this._hideMenu()
    window.getSelection()?.removeAllRanges()
  }

  _openColors() {
    if (!this._colorsDlg) return

    // Fill current palette
    this._colorsDlg.querySelector("input[name='title']").value = this._palette.title
    this._colorsDlg.querySelector("input[name='person']").value = this._palette.person
    this._colorsDlg.querySelector("input[name='place']").value = this._palette.place
    this._colorsDlg.querySelector("input[name='office']").value = this._palette.office
    this._colorsDlg.querySelector("select[name='preset']").value = "default"

    const form = this._colorsDlg.querySelector("form")
    const onClose = () => {
      form.removeEventListener("close", onClose)
    }

    form.addEventListener("submit", (ev) => {
      // Apply either preset or custom colours.
      const preset = this._colorsDlg.querySelector("select[name='preset']").value
      if (preset && preset !== "default") {
        this._palette = this._presetPalette(preset)
      } else {
        this._palette = {
          title: this._colorsDlg.querySelector("input[name='title']").value,
          person: this._colorsDlg.querySelector("input[name='person']").value,
          place: this._colorsDlg.querySelector("input[name='place']").value,
          office: this._colorsDlg.querySelector("input[name='office']").value
        }
      }
      this._savePalette(this._palette)
      this._applyPaletteToRoot()
    }, { once: true })

    this._colorsDlg.showModal()
  }

  // ---------- palette persistence ----------

  _paletteKey() { return "corpus.annot.palette.v1" }
  _titleModeKey() { return "corpus.annot.titlemode.v1" }

  _loadPalette() {
    try {
      const raw = localStorage.getItem(this._paletteKey())
      if (!raw) return this._presetPalette("default")
      const obj = JSON.parse(raw)
      if (!obj) return this._presetPalette("default")
      return {
        title: obj.title || "#2b6cb0",
        person: obj.person || "#d69e2e",
        place: obj.place || "#2f855a",
        office: obj.office || "#c53030"
      }
    } catch (_) {
      return this._presetPalette("default")
    }
  }

  _savePalette(pal) {
    try { localStorage.setItem(this._paletteKey(), JSON.stringify(pal)) } catch (_) {}
  }

  _loadTitleMode() {
    try { return localStorage.getItem(this._titleModeKey()) || "both" } catch (_) { return "both" }
  }

  _saveTitleMode(mode) {
    try { localStorage.setItem(this._titleModeKey(), mode) } catch (_) {}
  }

  _presetPalette(name) {
    // These are intentionally high-contrast and not purely red/green.
    // They are *heuristics*; users can override with the colour picker.
    switch (name) {
      case "deuteranopia":
        return { title: "#1f77b4", person: "#ff7f0e", place: "#9467bd", office: "#2ca02c" }
      case "protanopia":
        return { title: "#1f77b4", person: "#ff7f0e", place: "#8c564b", office: "#2ca02c" }
      case "tritanopia":
        return { title: "#e377c2", person: "#7f7f7f", place: "#17becf", office: "#bcbd22" }
      default:
        return { title: "#2b6cb0", person: "#d69e2e", place: "#2f855a", office: "#c53030" }
    }
  }

  _applyPaletteToRoot() {
    const root = document.documentElement
    root.style.setProperty("--ne-title", this._palette.title)
    root.style.setProperty("--ne-person", this._palette.person)
    root.style.setProperty("--ne-place", this._palette.place)
    root.style.setProperty("--ne-office", this._palette.office)
  }
}