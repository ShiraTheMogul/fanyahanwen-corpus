import { Controller } from "@hotwired/stimulus"

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

    this._items = []
    this._dirty = false
    this._judouOn = true
    this._judouUnderlineOn = true

    this._viewEnabled = this._loadBool("corpus.annot.view.v1", true)
    this._notesEnabled = this._loadBool("corpus.annot.notes.v1", false)
    this._annotateEnabled = this._loadBool("corpus.annot.edit.v1", false)

    this._palette = this._loadPalette()

    this._syncButtons()
    this._syncAnnotateModeClass()
    this._bindAnnotateSelection()

    this._onReaderOptionsBound = (ev) => this._onReaderOptions(ev)
    window.addEventListener("corpus-reader-options", this._onReaderOptionsBound)
    window.addEventListener("corpus-view-options", this._onReaderOptionsBound)

    this._onReaderAppliedBound = () => this._applyAll()
    window.addEventListener("corpus-reader-applied", this._onReaderAppliedBound)

    this._loadFromServer()
      .then(() => this._applyAll())
      .catch((e) => console.warn("[corpus-annotations] load failed", e))

    this._isTicketPreviewComposing = false
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
    this._hideTicketPanel()
    this._clearSelectionPreview()
    document.documentElement.classList.remove("cv-annotate-mode")
  }

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

  saveDraft() {
    if (!this._dirty && (!this._items || this._items.length === 0)) return
    this._ensureTicketPanel()
    this._renderTicketPreview()
    this._ticketPanel.hidden = false
  }

  async submitTicket(event) {
    event.preventDefault()
    if (!this._items || this._items.length === 0) {
      this._setTicketStatus("Add at least one annotation before creating a ticket.")
      return
    }

    const title = this._ticketTitleInput ? this._ticketTitleInput.value.trim() : "Annotation edit"
    const summary = this._ticketSummaryInput ? this._ticketSummaryInput.value.trim() : ""
    const reasoning = this._ticketReasoningInput ? this._ticketReasoningInput.value.trim() : ""
    const previewItems = this._buildPreviewItems()

    this._setTicketStatus("Creating ticket…")
    this._setTicketResult("", "")

    try {
      const res = await fetch(this._endpoint(), {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Accept": "application/json",
          "X-CSRF-Token": this._csrfToken()
        },
        body: JSON.stringify({
          path: this.pathValue,
          source: "corpus_viewer",
          title: title || "Annotation edit",
          summary,
          reasoning,
          annotations: { version: 1, items: this._items },
          preview_items: previewItems
        })
      })

      const data = await res.json().catch(() => null)
      if (!res.ok || !data || data.ok !== true) {
        const msg = (data && (data.error || data.detail)) ? (data.error || data.detail) : `HTTP ${res.status}`
        this._setTicketStatus(`Error: ${msg}`)
        return
      }

      this._setTicketStatus("Ticket created. Save the key below.")
      this._setTicketResult(data.ticket_id || (data.ticket && data.ticket.id) || "", data.ticket_key || "")

      if (data.ticket_id && data.ticket_key) {
        try {
          window.localStorage.setItem(`ticket_key:${data.ticket_id}`, data.ticket_key)
          if (this._storeOnDeviceCheckbox && this._storeOnDeviceCheckbox.checked) {
            this._storeTicketOnDevice(data.ticket_id, data.ticket_key, title || "Annotation edit")
          }
        } catch (_) {}
      }

      this._dirty = false
      this._syncButtons()
    } catch (e) {
      this._setTicketStatus(`Error: ${e.message || e}`)
    }
  }

  copyTicketKey(event) {
    event.preventDefault()
    if (!this._ticketKeyValue) return
    navigator.clipboard.writeText(this._ticketKeyValue.textContent || "")
  }

  downloadTicketKey(event) {
    event.preventDefault()
    const id = this._ticketIdValue ? this._ticketIdValue.textContent : ""
    const key = this._ticketKeyValue ? this._ticketKeyValue.textContent : ""
    if (!id || !key) return

    const content = `TICKET ID: ${id}\nTICKET KEY: ${key}\n`
    const blob = new Blob([content], { type: "text/plain;charset=utf-8" })
    const url = URL.createObjectURL(blob)
    const a = document.createElement("a")
    a.href = url
    a.download = `ticket_${id}_key.txt`
    document.body.appendChild(a)
    a.click()
    a.remove()
    URL.revokeObjectURL(url)
  }

  closeTicketPanel(event) {
    if (event) event.preventDefault()
    this._hideTicketPanel()
  }

  _syncAnnotateModeClass() {
    const root = document.documentElement
    if (!root) return
    if (this._annotateEnabled) root.classList.add("cv-annotate-mode")
    else root.classList.remove("cv-annotate-mode")
  }

  _bindAnnotateSelection() {
    if (this._onMouseUpBound) return
    this._onMouseUpBound = (ev) => this._onMouseUp(ev)
    document.addEventListener("mouseup", this._onMouseUpBound)
    this._onEscBound = (ev) => {
      if (!this._annotateEnabled) return
      if (ev.key === "Escape") { this._hideAnnotatePopup(); this._clearSelectionPreview() }
    }
    document.addEventListener("keydown", this._onEscBound)
  }

  _unbindAnnotateSelection() {
    if (this._onMouseUpBound) {
      document.removeEventListener("mouseup", this._onMouseUpBound)
      this._onMouseUpBound = null
    }
    if (this._onEscBound) {
      document.removeEventListener("keydown", this._onEscBound)
      this._onEscBound = null
    }
  }

  _onMouseUp() {
    if (!this._annotateEnabled || !this._contentEl) return
    if (this._isInteractiveField(document.activeElement)) return

    const sel = window.getSelection ? window.getSelection() : null
    if (!sel || sel.rangeCount === 0) return
    const range = sel.getRangeAt(0)
    if (!range) return

    const text = (sel.toString ? sel.toString() : "").trim()
    if (!text) return

    const container = range.commonAncestorContainer
    const node = (container && container.nodeType === 1) ? container : (container ? container.parentElement : null)
    if (!node || !this._contentEl.contains(node)) return

    const r = this._selectionToIdxRange(range)
    if (!r) return

    this._showAnnotatePopup(r, range)
  }

  _selectionToIdxRange(range) {
    const spans = this._spans()
    if (!spans.length) return null

    let minIdx = null
    let maxIdx = null

    for (let i = 0; i < spans.length; i++) {
      const el = spans[i]
      try {
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
    return { start: minIdx, end: maxIdx + 1 }
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
      <div class="cv-annotate-row cv-annotate-selection-preview-row">
        <div class="cv-annotate-selection-preview">${this._escapeHtml(this._textForRange(bounds.start, bounds.end) || "(no text selected)")}</div>
      </div>
      <div class="cv-annotate-row">
        <button type="button" data-kind="title" class="cv-annotate-kind">〖Title〗</button>
        <button type="button" data-kind="person" class="cv-annotate-kind">丨Person</button>
        <button type="button" data-kind="place" class="cv-annotate-kind">‖Place</button>
        <button type="button" data-kind="office" class="cv-annotate-kind">﹏Office</button>
      </div>
      <div class="cv-annotate-row">
        <textarea class="cv-annotate-note" rows="3" placeholder="Note (optional)" aria-label="Annotation note"></textarea>
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
        this._clearSelectionPreview()
        return
      }

      if (t.classList.contains("cv-annotate-kind")) {
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
        this._clearSelectionPreview()

        const sel = window.getSelection ? window.getSelection() : null
        if (sel && sel.removeAllRanges) sel.removeAllRanges()
      }
    }

    const noteBox = pop.querySelector(".cv-annotate-note")
    if (noteBox) {
      noteBox.setAttribute("lang", "zh")
      noteBox.setAttribute("autocapitalize", "off")
      noteBox.setAttribute("autocomplete", "off")
      noteBox.setAttribute("autocorrect", "off")
      noteBox.setAttribute("spellcheck", "false")
      noteBox.addEventListener("compositionstart", () => { this._isPopupComposing = true })
      noteBox.addEventListener("compositionend", () => { this._isPopupComposing = false })
    }

    pop.addEventListener("click", onClick)

    this._onDocClickClose = (ev) => {
      if (this._isPopupComposing) return
      if (!pop.isConnected) return
      if (pop.contains(ev.target)) return
      this._hideAnnotatePopup()
      this._clearSelectionPreview()
    }
    setTimeout(() => document.addEventListener("mousedown", this._onDocClickClose), 0)

    document.body.appendChild(pop)
    this._popupEl = pop
    this._previewSelection(bounds.start, bounds.end)
  }

  _hideAnnotatePopup() {
    if (this._onDocClickClose) {
      document.removeEventListener("mousedown", this._onDocClickClose)
      this._onDocClickClose = null
    }
    if (this._popupEl && this._popupEl.isConnected) this._popupEl.remove()
    this._popupEl = null
  }

  _onReaderOptions(ev) {
    const detail = (ev && ev.detail) ? ev.detail : {}

    const judou = (typeof detail.judouOn === "boolean") ? detail.judouOn
      : (typeof detail.judou === "boolean") ? detail.judou
      : null
    if (judou !== null) this._judouOn = judou

    const ul = (typeof detail.judouUnderlineOn === "boolean") ? detail.judouUnderlineOn
      : (typeof detail.judouUnderline === "boolean") ? detail.judouUnderline
      : null
    if (ul !== null) this._judouUnderlineOn = ul

    this._applyAll()
    this._syncButtons()
  }

  _endpoint() {
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
    this._items = (data && data.items && Array.isArray(data.items)) ? data.items : []
    this._dirty = false
    this._syncButtons()
  }

  _applyAll() {
    if (!this._contentEl) return

    this._clearAllHighlights()
    if (this._judouOn && this._judouUnderlineOn) this._applyHighlights()

    if (this._notesEnabled) this._renderNotesPanel()
    else this._removeNotesPanel()

    if (this._ticketPanel && !this._ticketPanel.hidden) this._renderTicketPreview()
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

  _renderNotesPanel() {
    const anchors = Array.from(this._contentEl.querySelectorAll("span.cch[data-ne-note]"))
    if (!anchors.length) { this._removeNotesPanel(); return }

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
      anchors[i].setAttribute("data-note-marker", marker)

      const li = document.createElement("li")
      li.innerHTML = '<span class="cv-note-marker">' + marker + "</span> " + this._escapeHtml(note)
      list.appendChild(li)
    }
  }

  _removeNotesPanel() {
    const panel = this.element.querySelector(".cv-user-notes")
    if (panel) panel.remove()

    if (!this._contentEl) return
    const anchors = Array.from(this._contentEl.querySelectorAll('span.cch[data-note-marker]'))
    anchors.forEach((el) => el.removeAttribute("data-note-marker"))
  }

  _chineseNumeral(n) {
    const digits = ["零", "一", "二", "三", "四", "五", "六", "七", "八", "九"]
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

  _openColors() {
    this._ensureColorsDialog()
    if (!this._colorsDlg) return

    const presetSel = this._colorsDlg.querySelector("#cv_color_preset")
    const inTitle = this._colorsDlg.querySelector("#cv_color_title")
    const inPerson = this._colorsDlg.querySelector("#cv_color_person")
    const inPlace = this._colorsDlg.querySelector("#cv_color_place")
    const inOffice = this._colorsDlg.querySelector("#cv_color_office")
    const inNote = this._colorsDlg.querySelector("#cv_color_note")

    if (!presetSel || !inTitle || !inPerson || !inPlace || !inOffice || !inNote) return

    inTitle.value = this._palette.title
    inPerson.value = this._palette.person
    inPlace.value = this._palette.place
    inOffice.value = this._palette.office
    inNote.value = this._palette.note
    presetSel.value = "default"

    const form = this._colorsDlg.querySelector("form")
    if (form) {
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
    if (name === "deuteranopia") return { title: "#3b82f6", person: "#f59e0b", place: "#10b981", office: "#ef4444", note: "#3b82f6" }
    if (name === "protanopia") return { title: "#2563eb", person: "#f97316", place: "#14b8a6", office: "#a855f7", note: "#2563eb" }
    if (name === "tritanopia") return { title: "#1d4ed8", person: "#eab308", place: "#22c55e", office: "#f43f5e", note: "#1d4ed8" }
    return { title: "#2b6cb0", person: "#d69e2e", place: "#2f855a", office: "#c53030", note: "#2b6cb0" }
  }

  _syncButtons() {
    const setLabel = (selector, onText, offText, isOn) => {
      const btn = this.element.querySelector(selector)
      if (!btn) return
      btn.textContent = isOn ? onText : offText
      btn.setAttribute("aria-pressed", isOn ? "true" : "false")
    }

    setLabel('[data-action*="corpus-annotations#toggleView"]', "Annotations: On", "Annotations: Off", (this._judouOn && this._viewEnabled))
    setLabel('[data-action*="corpus-annotations#toggleNotes"]', "Notes: On", "Notes: Off", (this._judouOn && this._notesEnabled))
    setLabel('[data-action*="corpus-annotations#toggleAnnotate"]', "Annotate: On", "Annotate: Off", this._annotateEnabled)

    const saveBtn = this.element.querySelector('[data-action*="corpus-annotations#save"]')
    if (saveBtn) {
      saveBtn.hidden = !this._dirty
      saveBtn.textContent = this._dirty ? "Review & submit" : "Review & submit"
    }
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

  _ensureTicketPanel() {
    if (this._ticketPanel && this._ticketPanel.isConnected) return

    const panel = document.createElement("div")
    panel.className = "cv-annotation-ticket-panel"
    panel.hidden = true
    panel.innerHTML = `
      <div class="cv-annotation-ticket-card">
        <div class="cv-annotation-ticket-head">
          <h3 style="margin:0;">Review annotation ticket</h3>
          <button type="button" class="corpus-btn" data-role="close-ticket-panel">Close</button>
        </div>
        <p class="cv-hint">This preview shows the annotation ranges that will be submitted. Creating the ticket does not change the corpus directly.</p>
        <form data-role="annotation-ticket-form">
          <div class="cv-form-row">
            <label>Title</label>
            <input type="text" class="cv-input" value="Annotation edit" data-role="ticket-title" />
          </div>
          <div class="cv-form-row">
            <label>Summary</label>
            <input type="text" class="cv-input" placeholder="What did you annotate?" data-role="ticket-summary" />
          </div>
          <div class="cv-form-row">
            <label>Reasoning</label>
            <textarea class="cv-textarea" rows="3" placeholder="Why should this annotation be kept?" data-role="ticket-reasoning"></textarea>
          </div>
          <div class="cv-form-row">
            <div class="cv-annotation-preview-headline">
              <label>Preview</label>
              <div class="cv-form-actions">
                <button type="button" class="corpus-btn" data-role="add-annotation-item">Add row</button>
              </div>
            </div>
            <div class="cv-annotation-preview-list" data-role="ticket-preview-list"></div>
          </div>
          <div class="cv-form-row">
            <label class="cv-inline-check"><input type="checkbox" data-role="store-on-device" checked /> Store this ticket on this device</label>
          </div>
          <div class="cv-form-actions">
            <button type="submit" class="corpus-btn corpus-btn-primary">Create ticket</button>
            <button type="button" class="corpus-btn" data-role="close-ticket-panel">Close</button>
          </div>
        </form>
        <div class="cv-ticket-result">
          <div class="cv-ticket-status" data-role="ticket-status"></div>
          <div class="cv-ticket-kv">
            <div><strong>Ticket ID:</strong> <span data-role="ticket-id"></span></div>
            <div><strong>Ticket Key:</strong> <code data-role="ticket-key"></code></div>
          </div>
          <div class="cv-form-actions">
            <button type="button" class="corpus-btn" data-role="copy-ticket-key" hidden>Copy key</button>
            <button type="button" class="corpus-btn" data-role="download-ticket-key" hidden>Download txt</button>
            <a class="corpus-btn" data-role="open-ticket-link" hidden>Open ticket</a>
          </div>
        </div>
      </div>
    `

    panel.querySelector('[data-role="annotation-ticket-form"]').addEventListener("submit", (event) => this.submitTicket(event))
    panel.querySelectorAll('[data-role="close-ticket-panel"]').forEach((btn) => {
      btn.addEventListener("click", (event) => this.closeTicketPanel(event))
    })
    panel.querySelector('[data-role="copy-ticket-key"]').addEventListener("click", (event) => this.copyTicketKey(event))
    panel.querySelector('[data-role="download-ticket-key"]').addEventListener("click", (event) => this.downloadTicketKey(event))
    panel.querySelector('[data-role="add-annotation-item"]').addEventListener("click", () => this._addEmptyPreviewItem())
    panel.addEventListener("compositionstart", (event) => this._onCompositionStart(event))
    panel.addEventListener("compositionend", (event) => this._onCompositionEnd(event))
    panel.addEventListener("input", (event) => this._onTicketPreviewEdit(event))
    panel.addEventListener("change", (event) => this._onTicketPreviewEdit(event))
    panel.addEventListener("click", (event) => this._onTicketPreviewClick(event))

    this.element.appendChild(panel)

    this._ticketPanel = panel
    this._ticketTitleInput = panel.querySelector('[data-role="ticket-title"]')
    this._ticketSummaryInput = panel.querySelector('[data-role="ticket-summary"]')
    this._ticketReasoningInput = panel.querySelector('[data-role="ticket-reasoning"]')
    this._ticketPreviewList = panel.querySelector('[data-role="ticket-preview-list"]')
    this._ticketStatusEl = panel.querySelector('[data-role="ticket-status"]')
    this._ticketIdValue = panel.querySelector('[data-role="ticket-id"]')
    this._ticketKeyValue = panel.querySelector('[data-role="ticket-key"]')
    this._copyTicketKeyBtn = panel.querySelector('[data-role="copy-ticket-key"]')
    this._downloadTicketKeyBtn = panel.querySelector('[data-role="download-ticket-key"]')
    this._openTicketLink = panel.querySelector('[data-role="open-ticket-link"]')
    this._storeOnDeviceCheckbox = panel.querySelector('[data-role="store-on-device"]')

    const textInputs = panel.querySelectorAll("textarea, input[type=\"text\"]")
    textInputs.forEach((el) => {
      el.setAttribute("autocapitalize", "off")
      el.setAttribute("autocomplete", "off")
      el.setAttribute("autocorrect", "off")
      el.setAttribute("spellcheck", "false")
    })
  }

  _renderTicketPreview() {
    if (!this._ticketPreviewList) return
    this._ticketPreviewList.textContent = ""

    const items = this._buildPreviewItems()
    if (items.length === 0) {
      const p = document.createElement("p")
      p.className = "cv-muted"
      p.textContent = "No annotations queued yet."
      this._ticketPreviewList.appendChild(p)
      return
    }

    for (let i = 0; i < items.length; i++) {
      const item = items[i]
      const card = document.createElement("div")
      card.className = "cv-annotation-preview-card"

      const row = document.createElement("div")
      row.className = "cv-annotation-preview-row"
      row.dataset.index = String(i)

      const controls = document.createElement("div")
      controls.className = "cv-annotation-preview-controls"
      controls.innerHTML = `
        <label>Kind
          <select data-field="kind">
            ${this._kindOptionsHtml(item.kind)}
          </select>
        </label>
        <label>Start
          <input type="number" min="0" step="1" data-field="start" value="${Number(item.start)}" />
        </label>
        <label>End
          <input type="number" min="1" step="1" data-field="end" value="${Number(item.end)}" />
        </label>
        <button type="button" class="corpus-btn" data-action="delete-item">Delete</button>
      `
      card.appendChild(controls)

      const head = document.createElement("div")
      head.className = "cv-annotation-preview-head"
      head.textContent = `${this._humanKind(item.kind)} · ${item.start}–${Math.max(Number(item.start), Number(item.end) - 1)}`
      card.appendChild(head)

      const text = document.createElement("div")
      text.className = "cv-annotation-preview-text"
      text.textContent = item.text || "(no text preview)"
      card.appendChild(text)

      const noteWrap = document.createElement("label")
      noteWrap.className = "cv-annotation-preview-note-editor"
      noteWrap.innerHTML = `Note <textarea rows="2" data-field="note">${this._escapeHtml(item.note || "")}</textarea>`
      card.appendChild(noteWrap)

      row.appendChild(card)
      this._ticketPreviewList.appendChild(row)
    }
  }


  _kindOptionsHtml(selectedKind) {
    const kinds = ["title", "person", "place", "office"]
    return kinds.map((kind) => `<option value="${kind}"${kind === selectedKind ? " selected" : ""}>${this._humanKind(kind)}</option>`).join("")
  }

  _onCompositionStart(event) {
    if (!this._isInteractiveField(event.target)) return
    this._isTicketPreviewComposing = true
  }

  _onCompositionEnd(event) {
    if (!this._isInteractiveField(event.target)) return
    this._isTicketPreviewComposing = false
    this._onTicketPreviewEdit(event)
  }

  _isInteractiveField(el) {
    if (!el || !el.closest) return false
    return !!el.closest("input, textarea, select, [contenteditable=\"true\"]")
  }

  _onTicketPreviewClick(event) {
    const btn = event.target.closest('[data-action="delete-item"]')
    if (!btn) return
    const row = btn.closest('.cv-annotation-preview-row')
    if (!row) return
    const index = Number(row.dataset.index)
    if (!Number.isFinite(index)) return
    this._items.splice(index, 1)
    this._dirty = true
    this._syncButtons()
    this._applyAll()
  }

  _onTicketPreviewEdit(event) {
    const field = event.target.getAttribute('data-field')
    if (!field) return
    if (event.type === "input" && this._isTicketPreviewComposing) return

    const row = event.target.closest('.cv-annotation-preview-row')
    if (!row) return
    const index = Number(row.dataset.index)
    const item = this._items[index]
    if (!item) return

    if (field === 'kind') item.kind = event.target.value
    if (field === 'note') item.note = String(event.target.value || '')
    if (field === 'start') item.start = this._normalizeIdx(event.target.value, 0)
    if (field === 'end') item.end = this._normalizeIdx(event.target.value, item.start + 1)

    this._normalizeItem(item)
    this._dirty = true
    this._syncButtons()

    if (field === 'note' && event.type === "input") {
      return
    }

    this._applyAll()
  }

  _addEmptyPreviewItem() {
    const start = 0
    const end = 1
    this._items.push({ start: start, end: end, kind: 'person', note: '' })
    this._dirty = true
    this._syncButtons()
    this._applyAll()
    if (this._ticketPanel) this._ticketPanel.hidden = false
  }

  _normalizeIdx(value, fallback) {
    const n = Number(value)
    if (!Number.isFinite(n)) return fallback
    return Math.max(0, Math.floor(n))
  }

  _normalizeItem(item) {
    const max = this._maxCorpusIdxExclusive()
    item.start = this._normalizeIdx(item.start, 0)
    item.end = this._normalizeIdx(item.end, item.start + 1)
    if (item.end <= item.start) item.end = item.start + 1
    if (max > 0) {
      item.start = Math.min(item.start, max - 1)
      item.end = Math.min(Math.max(item.end, item.start + 1), max)
    }
    item.kind = ["title", "person", "place", "office"].includes(item.kind) ? item.kind : "person"
    item.note = String(item.note || '')
  }

  _maxCorpusIdxExclusive() {
    const spans = this._spans()
    let max = 0
    for (let i = 0; i < spans.length; i++) {
      const idx = Number(spans[i].getAttribute('data-corpus-idx'))
      if (Number.isFinite(idx)) max = Math.max(max, idx + 1)
    }
    return max
  }

  _previewSelection(start, end) {
    this._clearSelectionPreview()
    const spans = this._spans()
    for (let i = 0; i < spans.length; i++) {
      const idx = Number(spans[i].getAttribute('data-corpus-idx'))
      if (idx >= Number(start) && idx < Number(end)) spans[i].classList.add('cv-annotate-selection-preview')
    }
  }

  _clearSelectionPreview() {
    const spans = this._spans()
    spans.forEach((el) => el.classList.remove('cv-annotate-selection-preview'))
  }

  _buildPreviewItems() {
    return this._items.map((item) => ({
      start: Number(item.start),
      end: Number(item.end),
      kind: item.kind,
      note: item.note || "",
      text: this._textForRange(item.start, item.end)
    }))
  }

  _textForRange(start, end) {
    const spans = this._spans()
    const chars = []
    for (let i = 0; i < spans.length; i++) {
      const idx = Number(spans[i].getAttribute("data-corpus-idx"))
      if (idx >= Number(start) && idx < Number(end)) chars.push(spans[i].textContent || "")
    }
    return chars.join("")
  }

  _humanKind(kind) {
    if (kind === "title") return "Title"
    if (kind === "person") return "Person"
    if (kind === "place") return "Place"
    if (kind === "office") return "Office"
    return kind || "Annotation"
  }

  _hideTicketPanel() {
    if (this._ticketPanel) this._ticketPanel.hidden = true
  }

  _setTicketStatus(text) {
    if (this._ticketStatusEl) this._ticketStatusEl.textContent = text || ""
  }

  _setTicketResult(id, key) {
    if (this._ticketIdValue) this._ticketIdValue.textContent = id || ""
    if (this._ticketKeyValue) this._ticketKeyValue.textContent = key || ""
    if (this._copyTicketKeyBtn) this._copyTicketKeyBtn.hidden = !(id && key)
    if (this._downloadTicketKeyBtn) this._downloadTicketKeyBtn.hidden = !(id && key)
    if (this._openTicketLink) {
      if (id && key) {
        this._openTicketLink.hidden = false
        this._openTicketLink.href = `/ticket_access?key=${encodeURIComponent(key)}`
        this._openTicketLink.textContent = "Open ticket"
      } else {
        this._openTicketLink.hidden = true
        this._openTicketLink.removeAttribute("href")
      }
    }
  }

  _storeTicketOnDevice(ticketId, ticketKey, title) {
    const key = "cv_ticket_keys_v1"
    let list = []
    try {
      list = JSON.parse(window.localStorage.getItem(key) || "[]")
      if (!Array.isArray(list)) list = []
    } catch (_) {
      list = []
    }

    list = list.filter((t) => t.ticket_id !== ticketId)
    list.unshift({
      ticket_id: ticketId,
      ticket_key: ticketKey,
      title: title || "",
      source: "annotation",
      saved_at: new Date().toISOString(),
    })

    window.localStorage.setItem(key, JSON.stringify(list.slice(0, 25)))
  }

  _csrfToken() {
    const el = document.querySelector('meta[name="csrf-token"]')
    return el ? el.content : ""
  }
}
