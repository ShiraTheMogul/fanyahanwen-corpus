import { Controller } from "@hotwired/stimulus"

// corpus-annotations: user-contributed named-entity annotations for corpus viewer.
//
// IMPORTANT COMPATIBILITY NOTES
// - Avoid optional chaining (?.), nullish coalescing (??), and class field syntax,
//   because some asset pipelines/minifiers choke on them.
// - Keep Stimulus action method names stable: toggleView, toggleNotes, openColorSettings, etc.

export default class extends Controller {
  static shouldLoad() { return true }

  static get targets() {
    return ["annotateBtn", "saveBtn"]
  }

  static get values() {
    return {
      path: String,
      url: String
    }
  }

  connect() {
    this._contentEl = this.element.querySelector(".corpus-textflow")
    if (!this._contentEl) return

    // state
    this._items = []
    this._dirty = false
    this._judouOn = true

    // view toggles
    this._viewEnabled = this._loadBool("corpus.annot.view.v1", true)
    this._notesEnabled = this._loadBool("corpus.annot.notes.v1", false)
    this._annotateEnabled = this._loadBool("corpus.annot.edit.v1", false)

    // palette
    this._palette = this._loadPalette()

    // hook buttons (label reflects state)
    this._syncButtons()

    this._syncAnnotateModeClass()
    this._bindAnnotateSelection()

    // listen for reader option changes (judou on/off)
    this._onReaderOptionsBound = (ev) => this._onReaderOptions(ev)
    window.addEventListener("corpus-reader-options", this._onReaderOptionsBound)
    window.addEventListener("corpus-view-options", this._onReaderOptionsBound)

    // re-apply after reader re-renders text DOM
    this._onReaderAppliedBound = () => this._applyAll()
    window.addEventListener("corpus-reader-applied", this._onReaderAppliedBound)

    // load saved annotations
    this._loadFromServer()
      .then(() => this._applyAll())
      .catch((e) => console.warn("[corpus-annotations] load failed", e))

    // apply palette to root
    this._applyPaletteToRoot()
  }

  disconnect() {
    if (this._onReaderOptionsBound) {
      window.removeEventListener("corpus-reader-options", this._onReaderOptionsBound)
      window.removeEventListener("corpus-view-options", this._onReaderOptionsBound)
    }
    if (this._onReaderAppliedBound) {
      window.removeEventListener("corpus-reader-applied", this._onReaderAppliedBound)
    }
  
    this._hideAnnotatePopup()
    this._unbindAnnotateSelection()
    // ensure class removed
    document.documentElement.classList.remove("cv-annotate-mode")
  }

  // ---------------- Stimulus action entrypoints ----------------

  toggleView() {
    this._viewEnabled = !this._viewEnabled
    this._storeBool("corpus.annot.view.v1", this._viewEnabled)
    this._syncButtons()
    this._applyAll()
  }

  toggleNotes() {
    this._notesEnabled = !this._notesEnabled
    this._storeBool("corpus.annot.notes.v1", this._notesEnabled)
    this._syncButtons()
    this._applyAll()
  }

  toggleAnnotate() {
    this._annotateEnabled = !this._annotateEnabled
    this._storeBool("corpus.annot.edit.v1", this._annotateEnabled)
    this._syncAnnotateModeClass()
    this._syncButtons()
  }

  openColorSettings() {
    this._openColors()
  }

  closeColorSettings() {
    if (this._colorsDlg && this._colorsDlg.open) this._colorsDlg.close()
  }

  
// ---------------- Annotate mode (interactive selection) ----------------

_syncAnnotateModeClass() {
  // Annotate mode disables dictionary tooltip interactions via han_tooltip_controller.
  const root = document.documentElement
  if (!root) return
  if (this._annotateEnabled) {
    root.classList.add("cv-annotate-mode")
  } else {
    root.classList.remove("cv-annotate-mode")
  }
}

_bindAnnotateSelection() {
  if (this._onMouseUpBound) return
  this._onMouseUpBound = (ev) => this._onMouseUp(ev)
  document.addEventListener("mouseup", this._onMouseUpBound)
  document.addEventListener("keydown", (ev) => {
    if (!this._annotateEnabled) return
    if (ev.key === "Escape") this._hideAnnotatePopup()
  })
}

_unbindAnnotateSelection() {
  if (!this._onMouseUpBound) return
  document.removeEventListener("mouseup", this._onMouseUpBound)
  this._onMouseUpBound = null
}

_onMouseUp(ev) {
  if (!this._annotateEnabled) return
  if (!this._contentEl) return

  // Only act if selection touches the corpus textflow.
  const sel = window.getSelection ? window.getSelection() : null
  if (!sel || sel.rangeCount === 0) return
  const range = sel.getRangeAt(0)
  if (!range) return

  // Ignore empty selection.
  const text = (sel.toString ? sel.toString() : "").trim()
  if (!text) return

  // Ensure selection is inside corpus textflow.
  const container = range.commonAncestorContainer
  const node = (container && container.nodeType === 1) ? container : (container ? container.parentElement : null)
  if (!node) return
  if (!this._contentEl.contains(node)) return

  const r = this._selectionToIdxRange(range)
  if (!r) return

  this._showAnnotatePopup(r, range)
}

_selectionToIdxRange(range) {
  // Convert DOM Range -> corpus idx span bounds.
  const spans = this._spans()
  if (!spans.length) return null

  let minIdx = null
  let maxIdx = null

  for (let i = 0; i < spans.length; i++) {
    const el = spans[i]
    try {
      // intersectsNode exists on Range in all modern browsers.
      if (!range.intersectsNode(el)) continue
    } catch (_) {
      continue
    }
    const idx = Number(el.getAttribute("data-corpus-idx"))
    if (Number.isNaN(idx)) continue
    if (minIdx === null || idx < minIdx) minIdx = idx
    if (maxIdx === null || idx > maxIdx) maxIdx = idx
  }

  if (minIdx === null || maxIdx === null) return null
  return { start: minIdx, end: maxIdx }
}

_showAnnotatePopup(bounds, range) {
  this._hideAnnotatePopup()

  const rect = range.getBoundingClientRect ? range.getBoundingClientRect() : null
  const x = rect ? (rect.left + window.scrollX) : 20
  const y = rect ? (rect.bottom + window.scrollY + 6) : 20

  const pop = document.createElement("div")
  pop.className = "cv-annotate-popover"
  pop.style.position = "absolute"
  pop.style.left = Math.max(8, x) + "px"
  pop.style.top = Math.max(8, y) + "px"
  pop.style.zIndex = "9999"

  pop.innerHTML = `
    <div class="cv-annotate-row">
      <button type="button" data-kind="title"  class="cv-annotate-kind">〖Title〗</button>
      <button type="button" data-kind="person" class="cv-annotate-kind">丨Person</button>
      <button type="button" data-kind="place"  class="cv-annotate-kind">‖Place</button>
      <button type="button" data-kind="office" class="cv-annotate-kind">﹏Office</button>
    </div>
    <div class="cv-annotate-row">
      <textarea class="cv-annotate-note" rows="2" placeholder="Note (optional)"></textarea>
    </div>
    <div class="cv-annotate-row cv-annotate-actions">
      <button type="button" class="cv-annotate-cancel">Cancel</button>
      <button type="button" class="cv-annotate-apply primary">Apply</button>
    </div>
  `

  const onClick = (ev) => {
    const t = ev.target
    if (!t) return

    if (t.classList.contains("cv-annotate-cancel")) {
      this._hideAnnotatePopup()
      return
    }

    if (t.classList.contains("cv-annotate-kind")) {
      // highlight selected kind button
      const btns = pop.querySelectorAll(".cv-annotate-kind")
      btns.forEach((b) => b.classList.remove("active"))
      t.classList.add("active")
      return
    }

    if (t.classList.contains("cv-annotate-apply")) {
      const active = pop.querySelector(".cv-annotate-kind.active")
      const kind = active ? active.getAttribute("data-kind") : null
      if (!kind) return

      const noteEl = pop.querySelector(".cv-annotate-note")
      const note = noteEl ? String(noteEl.value || "").trim() : ""

      this._items.push({ start: bounds.start, end: bounds.end, kind: kind, note: note })
      this._dirty = true
      this._syncButtons()
      this._applyAll()
      this._hideAnnotatePopup()

      // clear selection
      const sel = window.getSelection ? window.getSelection() : null
      if (sel && sel.removeAllRanges) sel.removeAllRanges()
    }
  }

  pop.addEventListener("click", onClick)

  // Click outside closes.
  this._onDocClickClose = (ev) => {
    if (!pop.isConnected) return
    if (pop.contains(ev.target)) return
    this._hideAnnotatePopup()
  }
  setTimeout(() => document.addEventListener("mousedown", this._onDocClickClose), 0)

  document.body.appendChild(pop)
  this._popupEl = pop
}

_hideAnnotatePopup() {
  if (this._onDocClickClose) {
    document.removeEventListener("mousedown", this._onDocClickClose)
    this._onDocClickClose = null
  }
  if (this._popupEl && this._popupEl.isConnected) {
    this._popupEl.remove()
  }
  this._popupEl = null
}

// ---------------- Reader option integration ----------------

  _onReaderOptions(ev) {
    const detail = (ev && ev.detail) ? ev.detail : {}
    // accept both judouOn and judou
    const judou = (typeof detail.judouOn === "boolean") ? detail.judouOn
                : (typeof detail.judou === "boolean") ? detail.judou
                : null
    if (judou === null) return

    this._judouOn = judou

    // Hard rule: these underlines are judou-derived, so follow judou master switch.
    // Judou OFF => hide; Judou ON => show (if view enabled).
    this._applyAll()
    this._syncButtons()
  }

  // ---------------- Persistence ----------------

  _endpoint() {
    // Prefer explicit urlValue; fallback to /corpus_annotations
    const url = (this.hasUrlValue && this.urlValue) ? this.urlValue : "/corpus_annotations"
    const path = (this.hasPathValue && this.pathValue) ? this.pathValue : null
    if (!path) return null
    const u = new URL(url, window.location.origin)
    u.searchParams.set("path", path)
    return u.toString()
  }

  async _loadFromServer() {
    const ep = this._endpoint()
    if (!ep) return
    const res = await fetch(ep, { headers: { "Accept": "application/json" } })
    if (!res.ok) return
    const data = await res.json()
    const items = (data && data.items && Array.isArray(data.items)) ? data.items : []
    this._items = items
    this._dirty = false
    this._syncButtons()
  }

  async save() {
    const ep = this._endpoint()
    if (!ep) return
    const payload = { version: 1, items: this._items }
    const res = await fetch(ep, {
      method: "POST",
      headers: { "Content-Type": "application/json", "Accept": "application/json" },
      body: JSON.stringify(payload)
    })
    if (!res.ok) {
      console.warn("[corpus-annotations] save failed", res.status)
      return
    }
    this._dirty = false
    this._syncButtons()
  }

  // ---------------- Rendering ----------------

  _applyAll() {
    if (!this._contentEl) return

    // If judou is off, hide everything (master switch).
    if (!this._judouOn) {
      this._clearAllHighlights()
      this._removeNotesPanel()
      return
    }

    // Judou is on.
    this._clearAllHighlights()

    if (this._viewEnabled) {
      this._applyHighlights()
    }

    if (this._notesEnabled) {
      this._renderNotesPanel()
    } else {
      this._removeNotesPanel()
    }
  }

  _spans() {
    return Array.from(this._contentEl.querySelectorAll("span.cch[data-corpus-idx]"))
  }

  _clearAllHighlights() {
    const spans = this._spans()
    for (let i = 0; i < spans.length; i++) {
      const el = spans[i]
      el.classList.remove("ne-title", "ne-person", "ne-place", "ne-office", "ne-auto-title", "ne-note-anchor")
      el.removeAttribute("data-ne-note")
    }
  }

  _applyHighlights() {
    // Apply underline classes for saved items.
    // Expected item shape: { start, end, kind, note? }
    const spans = this._spans()
    if (!spans.length) return

    for (let k = 0; k < this._items.length; k++) {
      const it = this._items[k]
      if (!it) continue
      const start = Number(it.start)
      const end = Number(it.end)
      if (!Number.isFinite(start) || !Number.isFinite(end) || end <= start) continue

      const cls = this._kindToClass(it.kind)
      if (!cls) continue

      for (let i = 0; i < spans.length; i++) {
        const idx = Number(spans[i].getAttribute("data-corpus-idx"))
        if (idx >= start && idx < end) spans[i].classList.add(cls)
      }

      // If it has a user note, mark the first char with an anchor marker.
      if (it.note && typeof it.note === "string" && it.note.trim() !== "") {
        const anchor = this._findSpanByIdx(start)
        if (anchor) {
          anchor.classList.add("ne-note-anchor")
          anchor.setAttribute("data-ne-note", it.note)
        }
      }
    }
  }

  _findSpanByIdx(idx) {
    const spans = this._spans()
    for (let i = 0; i < spans.length; i++) {
      const n = Number(spans[i].getAttribute("data-corpus-idx"))
      if (n === idx) return spans[i]
    }
    return null
  }

  _kindToClass(kind) {
    if (kind === "title") return "ne-title"
    if (kind === "person") return "ne-person"
    if (kind === "place") return "ne-place"
    if (kind === "office") return "ne-office"
    return null
  }

  // ---------------- Notes panel (user-added annotation notes) ----------------

  _renderNotesPanel() {
    // Collect anchors (spans with data-ne-note)
    const anchors = Array.from(this._contentEl.querySelectorAll("span.cch[data-ne-note]"))
    if (!anchors.length) { this._removeNotesPanel(); return }

    // Ensure panel exists
    let panel = this.element.querySelector(".cv-user-notes")
    if (!panel) {
      panel = document.createElement("div")
      panel.className = "cv-user-notes"
      panel.innerHTML = '<div class="cv-user-notes-title">注</div><ol class="cv-user-notes-list"></ol>'
      this.element.appendChild(panel)
    }

    const list = panel.querySelector(".cv-user-notes-list")
    if (!list) return
    list.innerHTML = ""

    for (let i = 0; i < anchors.length; i++) {
      const note = anchors[i].getAttribute("data-ne-note") || ""
      const marker = this._chineseNumeral(i + 1)
      // mark anchor with marker
      anchors[i].setAttribute("data-note-marker", marker)

      const li = document.createElement("li")
      li.innerHTML = '<span class="cv-note-marker">' + marker + "</span> " + this._escapeHtml(note)
      list.appendChild(li)
    }
  }

  _removeNotesPanel() {
  const panel = this.element.querySelector(".cv-user-notes")
  if (panel) panel.remove()

  // Remove numeric markers from anchored characters.
  if (!this._contentEl) return
  const anchors = Array.from(this._contentEl.querySelectorAll('span.cch[data-note-marker]'))
  anchors.forEach((el) => el.removeAttribute("data-note-marker"))
}

_chineseNumeral(n) {
    // 1-99 is enough for now.
    const digits = ["零","一","二","三","四","五","六","七","八","九"]
    if (n < 10) return digits[n]
    if (n === 10) return "十"
    if (n < 20) return "十" + digits[n % 10]
    const tens = Math.floor(n / 10)
    const ones = n % 10
    return digits[tens] + "十" + (ones === 0 ? "" : digits[ones])
  }

  _escapeHtml(s) {
    return String(s)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&#039;")
  }

  // ---------------- Colour settings ----------------

  _openColors() {
    this._ensureColorsDialog()
    if (!this._colorsDlg) return

    const presetSel = this._colorsDlg.querySelector("#cv_color_preset")
    const inTitle  = this._colorsDlg.querySelector("#cv_color_title")
    const inPerson = this._colorsDlg.querySelector("#cv_color_person")
    const inPlace  = this._colorsDlg.querySelector("#cv_color_place")
    const inOffice = this._colorsDlg.querySelector("#cv_color_office")
    const inNote   = this._colorsDlg.querySelector("#cv_color_note")

    if (!presetSel || !inTitle || !inPerson || !inPlace || !inOffice || !inNote) return

    inTitle.value  = this._palette.title
    inPerson.value = this._palette.person
    inPlace.value  = this._palette.place
    inOffice.value = this._palette.office
    inNote.value   = this._palette.note
    presetSel.value = "default"

    const form = this._colorsDlg.querySelector("form")
    if (form) {
      // Replace the form node to drop old listeners (simple + robust).
      const clone = form.cloneNode(true)
      form.parentNode.replaceChild(clone, form)

      clone.addEventListener("submit", () => {
        const preset = presetSel.value
        if (preset && preset !== "default") {
          this._palette = this._presetPalette(preset)
        } else {
          this._palette = {
            title: inTitle.value,
            person: inPerson.value,
            place: inPlace.value,
            office: inOffice.value,
            note: inNote.value
          }
        }
        this._savePalette(this._palette)
        this._applyPaletteToRoot()
        this._applyAll()
      })
    }

    this._colorsDlg.showModal()
  }

  _ensureColorsDialog() {
    if (this._colorsDlg && this._colorsDlg.isConnected) return
    const existing = this.element.querySelector("dialog.corpus-colors-dialog")
    if (existing) { this._colorsDlg = existing; return }

    const dlg = document.createElement("dialog")
    dlg.className = "corpus-colors-dialog"
    dlg.innerHTML = `
      <form method="dialog" class="corpus-colors-form">
        <div class="corpus-colors-header">
          <div class="corpus-colors-title">Colour settings</div>
          <button type="button" class="corpus-colors-close" data-action="click->corpus-annotations#closeColorSettings">×</button>
        </div>

        <div class="corpus-colors-row">
          <label>Preset</label>
          <select id="cv_color_preset">
            <option value="default">Default</option>
            <option value="deuteranopia">Deuteranopia</option>
            <option value="protanopia">Protanopia</option>
            <option value="tritanopia">Tritanopia</option>
          </select>
        </div>

        <div class="corpus-colors-row"><label>Title</label><input id="cv_color_title" type="color" /></div>
        <div class="corpus-colors-row"><label>Person</label><input id="cv_color_person" type="color" /></div>
        <div class="corpus-colors-row"><label>Place</label><input id="cv_color_place" type="color" /></div>
        <div class="corpus-colors-row"><label>Office</label><input id="cv_color_office" type="color" /></div>
        <div class="corpus-colors-row"><label>Note marker</label><input id="cv_color_note" type="color" /></div>

        <div class="corpus-colors-actions">
          <button value="cancel" type="button" data-action="click->corpus-annotations#closeColorSettings">Cancel</button>
          <button value="apply" type="submit" class="primary">Apply</button>
        </div>
      </form>
    `
    this.element.appendChild(dlg)
    this._colorsDlg = dlg
  }

  _applyPaletteToRoot() {
    // Use CSS variables on the reader root element.
    const root = this._contentEl
    if (!root) return
    root.style.setProperty("--ne-title", this._palette.title)
    root.style.setProperty("--ne-person", this._palette.person)
    root.style.setProperty("--ne-place", this._palette.place)
    root.style.setProperty("--ne-office", this._palette.office)
    root.style.setProperty("--ne-note", this._palette.note)
  }

  _paletteKey() { return "corpus.annot.palette.v2" }

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
        office: obj.office || "#c53030",
        note: obj.note || "#2b6cb0"
      }
    } catch (_) {
      return this._presetPalette("default")
    }
  }

  _savePalette(pal) {
    try { localStorage.setItem(this._paletteKey(), JSON.stringify(pal)) } catch (_) {}
  }

  _presetPalette(name) {
    if (name === "deuteranopia") {
      return { title:"#3b82f6", person:"#f59e0b", place:"#10b981", office:"#ef4444", note:"#3b82f6" }
    }
    if (name === "protanopia") {
      return { title:"#2563eb", person:"#f97316", place:"#14b8a6", office:"#a855f7", note:"#2563eb" }
    }
    if (name === "tritanopia") {
      return { title:"#1d4ed8", person:"#eab308", place:"#22c55e", office:"#f43f5e", note:"#1d4ed8" }
    }
    return { title:"#2b6cb0", person:"#d69e2e", place:"#2f855a", office:"#c53030", note:"#2b6cb0" }
  }

  // ---------------- UI helpers ----------------

  _syncButtons() {
    // Reflect state in any toolbar buttons that exist.
    const setLabel = (selector, onText, offText, isOn) => {
      const btn = this.element.querySelector(selector)
      if (!btn) return
      btn.textContent = isOn ? onText : offText
      btn.setAttribute("aria-pressed", isOn ? "true" : "false")
    }

    // These selectors are robust: match data-action strings used in your ERB.
    setLabel('[data-action*="corpus-annotations#toggleView"]', "Annotations: On", "Annotations: Off", (this._judouOn && this._viewEnabled))
    setLabel('[data-action*="corpus-annotations#toggleNotes"]', "Notes: On", "Notes: Off", (this._judouOn && this._notesEnabled))
    setLabel('[data-action*="corpus-annotations#toggleAnnotate"]', "Annotate: On", "Annotate: Off", this._annotateEnabled)

    // Save button only if dirty
    const saveBtn = this.element.querySelector('[data-action*="corpus-annotations#save"]')
    if (saveBtn) saveBtn.style.display = this._dirty ? "" : "none"
  }

  _loadBool(key, fallback) {
    try {
      const raw = localStorage.getItem(key)
      if (raw === null || raw === undefined) return fallback
      return raw === "1"
    } catch (_) { return fallback }
  }

  _storeBool(key, v) {
    try { localStorage.setItem(key, v ? "1" : "0") } catch (_) {}
  }
}
