import { Controller } from "@hotwired/stimulus"
import { t } from "i18n"
import { storeTicketOnDevice } from "controllers/ticket_submission_helpers"

export default class extends Controller {
  static shouldLoad() { return true }

  static get targets() {
    return ["annotateBtn", "saveBtn"]
  }

  static get values() {
    return {
      path: String,
      sourcePath: String,
      url: String,
      translationMode: Boolean
    }
  }

  connect() {
    this._contentEl = this.element.querySelector(".corpus-textflow")
    if (!this._contentEl) return

    this._items = []
    this._dirty = false
    this._judouOn = true
    this._judouUnderlineOn = true

    this._translationMode = this.hasTranslationModeValue && this.translationModeValue
    this._viewEnabled = this._loadBool("corpus.annot.view.v1", true)
    this._notesEnabled = this._loadBool("corpus.annot.notes.v1", false)
    this._annotateEnabled = this._translationMode ? false : this._loadBool("corpus.annot.edit.v1", false)

    this._palette = this._loadPalette()

    this._syncButtons()
    this._syncAnnotateModeClass()
    if (!this._translationMode) this._bindAnnotateSelection()

    this._onReaderOptionsBound = (ev) => this._onReaderOptions(ev)
    window.addEventListener("corpus-reader-options", this._onReaderOptionsBound)
    window.addEventListener("corpus-view-options", this._onReaderOptionsBound)

    this._onReaderAppliedBound = () => this._applyAll()
    window.addEventListener("corpus-reader-applied", this._onReaderAppliedBound)

    const loadPromise = this._translationMode ? Promise.resolve() : this._loadFromServer()
    loadPromise
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
    this._showTicketPanel()
  }

  async submitTicket(event) {
    event.preventDefault()
    if (!this._items || this._items.length === 0) {
      this._setTicketStatus(t("corpus_annotations.status.add_one"))
      return
    }

    const title = this._ticketTitleInput ? this._ticketTitleInput.value.trim() : t("corpus_annotations.ticket.default_title")
    const summary = this._ticketSummaryInput ? this._ticketSummaryInput.value.trim() : ""
    const reasoning = this._ticketReasoningInput ? this._ticketReasoningInput.value.trim() : ""
    const materialNote = this._ticketMaterialNoteInput ? this._ticketMaterialNoteInput.value.trim() : ""
    const provenance = this._ticketProvenanceInputs
      ? Array.from(this._ticketProvenanceInputs).filter((input) => input.checked).map((input) => input.value)
      : []
    const references = this._ticketReferencesInput ? this._ticketReferencesInput.value.trim() : ""
    const aiAssisted = !!(this._ticketAiAssistedInput && this._ticketAiAssistedInput.checked)
    const aiDetails = this._ticketAiDetailsInput ? this._ticketAiDetailsInput.value.trim() : ""
    const previewItems = this._buildPreviewItems()

    if (!materialNote) {
      this._setTicketStatus(t("corpus_annotations.status.material_note_required"))
      return
    }
    if (provenance.length === 0) {
      this._setTicketStatus(t("corpus_annotations.status.provenance_required"))
      return
    }
    if (aiAssisted && !aiDetails) {
      this._setTicketStatus(t("corpus_annotations.status.ai_details_required"))
      return
    }
    if (this._items.some((item) => item.kind === "ambiguous_character" && !String(item.note || "").trim())) {
      this._setTicketStatus(t("corpus_annotations.status.ambiguous_note_required"))
      return
    }

    this._setTicketStatus(t("corpus_annotations.status.creating"))
    this._setTicketResult("", "")

    try {
      const form = new FormData()
      form.append("path", this.pathValue)
      form.append("source_path", this.hasSourcePathValue ? this.sourcePathValue : this.pathValue)
      form.append("source", "corpus_viewer")
      form.append("title", title || t("corpus_annotations.ticket.default_title"))
      form.append("summary", summary)
      form.append("reasoning", reasoning)
      form.append("annotations", JSON.stringify({ version: 1, items: this._items }))
      form.append("preview_items", JSON.stringify(previewItems))
      form.append("material_note", materialNote)
      form.append("provenance", JSON.stringify(provenance))
      form.append("references", references)
      form.append("ai_assisted", aiAssisted ? "1" : "0")
      form.append("ai_details", aiDetails)
      form.append("evidence_links", JSON.stringify(this._ticketEvidenceLinks()))

      const contact = this._ticketContact()
      if (contact) {
        form.append("contact[name]", contact.name || "")
        form.append("contact[email]", contact.email || "")
        form.append("contact[notes]", contact.notes || "")
      }

      if (this._ticketEvidenceFilesInput) {
        for (const file of Array.from(this._ticketEvidenceFilesInput.files || [])) {
          form.append("evidence_files[]", file)
        }
      }

      const res = await fetch(this._endpoint(), {
        method: "POST",
        headers: {
          "Accept": "application/json",
          "X-CSRF-Token": this._csrfToken()
        },
        body: form
      })

      const data = await res.json().catch(() => null)
      if (!res.ok || !data || data.ok !== true) {
        const msg = (data && (data.error || data.detail)) ? (data.error || data.detail) : `HTTP ${res.status}`
        this._setTicketStatus(t("corpus_annotations.status.error", { message: msg }))
        return
      }

      this._setTicketStatus(t("corpus_annotations.status.created"))
      this._setTicketResult(data.ticket_id || (data.ticket && data.ticket.id) || "", data.ticket_key || "")

      if (data.ticket_id && data.ticket_key && this._storeOnDeviceCheckbox && this._storeOnDeviceCheckbox.checked) {
        try {
          storeTicketOnDevice(data.ticket_id, data.ticket_key, {
            title: title || t("corpus_annotations.ticket.default_title"),
            source: "annotation",
          })
        } catch (_error) {}
      }

      this._dirty = false
      this._syncButtons()
    } catch (e) {
      this._setTicketStatus(t("corpus_annotations.status.error", { message: e.message || e }))
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

    const content = `${t("corpus_annotations.ticket.ticket_id")} ${id}\n${t("corpus_annotations.ticket.ticket_key")} ${key}\n`
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
      if (ev.key !== "Escape") return
      if (this._ticketPanel && !this._ticketPanel.classList.contains("hidden")) {
        ev.preventDefault()
        this._hideTicketPanel()
        return
      }
      if (!this._annotateEnabled) return
      this._hideAnnotatePopup()
      this._clearSelectionPreview()
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

  _onMouseUp(event) {
    if (!this._annotateEnabled || !this._contentEl) return
    if (this._isInteractiveField(document.activeElement)) return

    const target = event && event.target ? event.target : null
    if (target && target.closest) {
      if (target.closest(".cv-annotate-popover") || target.closest(".cv-annotation-ticket-panel") || target.closest(".cv-text-edit-panel")) return
    }

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
    pop.style.zIndex = "9999"

    pop.innerHTML = `
      <div class="cv-annotate-head cv-annotate-drag-handle">
        <strong>${t("corpus_annotations.popup.heading")}</strong>
      </div>
      <div class="cv-annotate-row cv-annotate-selection-preview-row">
        <div class="cv-annotate-selection-preview">${this._escapeHtml(this._textForRange(bounds.start, bounds.end) || t("corpus_annotations.popup.no_text_selected"))}</div>
      </div>
      <div class="cv-annotate-row">
        <button type="button" data-kind="title" class="cv-annotate-kind">〖${t("corpus_annotations.kinds.title")}〗</button>
        <button type="button" data-kind="person" class="cv-annotate-kind">丨${t("corpus_annotations.kinds.person")}</button>
        <button type="button" data-kind="place" class="cv-annotate-kind">‖${t("corpus_annotations.kinds.place")}</button>
        <button type="button" data-kind="office" class="cv-annotate-kind">﹏${t("corpus_annotations.kinds.office")}</button>
        <button type="button" data-kind="ambiguous_character" class="cv-annotate-kind">? ${t("corpus_annotations.kinds.ambiguous_short")}</button>
      </div>
      <div class="cv-annotate-row">
        <textarea class="cv-annotate-note" rows="3" placeholder="${t("corpus_annotations.popup.note_placeholder")}" aria-label="${t("corpus_annotations.popup.note_aria")}"></textarea>
      </div>
      <div class="cv-annotate-row cv-annotate-actions">
        <button type="button" class="cv-annotate-cancel">${t("corpus_annotations.actions.cancel")}</button>
        <button type="button" class="cv-annotate-apply primary">${t("corpus_annotations.actions.apply")}</button>
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
        if (kind === "ambiguous_character" && !note) {
          if (noteEl) {
            noteEl.setCustomValidity(t("corpus_annotations.popup.ambiguous_explanation_required"))
            noteEl.reportValidity()
            noteEl.setCustomValidity("")
          }
          return
        }

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

    pop.addEventListener("mousedown", (ev) => ev.stopPropagation())
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
    this._positionPopover(pop, x, y)
    this._positionFloatingElement(pop, x, y, this._floatingStorageKey("annotate-popup"), { preferAbove: true })
    this._enableFloatingDrag(pop, ".cv-annotate-drag-handle", this._floatingStorageKey("annotate-popup"))
    this._popupEl = pop
    this._previewSelection(bounds.start, bounds.end)
  }


  _positionPopover(pop, desiredLeft, desiredTop) {
    if (!pop) return

    const pad = 8
    pop.style.left = pad + "px"
    pop.style.top = pad + "px"

    const rect = pop.getBoundingClientRect()
    const minLeft = window.scrollX + pad
    const maxLeft = window.scrollX + window.innerWidth - rect.width - pad
    const minTop = window.scrollY + pad
    const maxTop = window.scrollY + window.innerHeight - rect.height - pad

    let left = Number(desiredLeft || minLeft)
    let top = Number(desiredTop || minTop)

    if (top > maxTop) {
      top = rect.height && desiredTop ? Math.max(minTop, desiredTop - rect.height - 18) : maxTop
    }

    if (maxLeft >= minLeft) {
      left = Math.min(Math.max(minLeft, left), maxLeft)
    } else {
      left = minLeft
    }

    if (maxTop >= minTop) {
      top = Math.min(Math.max(minTop, top), maxTop)
    } else {
      top = minTop
    }

    pop.style.left = left + "px"
    pop.style.top = top + "px"
  }

  _floatingStorageKey(name) {
    return `corpus.floating.${name}.v1`
  }

  _positionFloatingElement(el, preferredLeft, preferredTop, storageKey, options = {}) {
    if (!el) return
    const saved = this._loadFloatingPosition(storageKey)
    if (saved) {
      el.style.left = `${saved.left}px`
      el.style.top = `${saved.top}px`
      this._clampFloatingElement(el)
      return
    }

    el.style.left = "8px"
    el.style.top = "8px"
    const rect = el.getBoundingClientRect()
    let left = Number(preferredLeft || 8)
    let top = Number(preferredTop || 8)
    const pad = 8
    if (options.preferAbove && top + rect.height > window.innerHeight - pad) {
      top = Math.max(pad, top - rect.height - 18)
    }
    left = Math.min(Math.max(pad, left), Math.max(pad, window.innerWidth - rect.width - pad))
    top = Math.min(Math.max(pad, top), Math.max(pad, window.innerHeight - rect.height - pad))
    el.style.left = `${left}px`
    el.style.top = `${top}px`
  }

  _clampFloatingElement(el) {
    if (!el) return
    const pad = 8
    const rect = el.getBoundingClientRect()
    let left = parseFloat(el.style.left || "0")
    let top = parseFloat(el.style.top || "0")
    if (!Number.isFinite(left)) left = pad
    if (!Number.isFinite(top)) top = pad
    left = Math.min(Math.max(pad, left), Math.max(pad, window.innerWidth - rect.width - pad))
    top = Math.min(Math.max(pad, top), Math.max(pad, window.innerHeight - rect.height - pad))
    el.style.left = `${left}px`
    el.style.top = `${top}px`
  }

  _loadFloatingPosition(storageKey) {
    try {
      const raw = window.localStorage.getItem(storageKey)
      if (!raw) return null
      const obj = JSON.parse(raw)
      const left = Number(obj && obj.left)
      const top = Number(obj && obj.top)
      if (!Number.isFinite(left) || !Number.isFinite(top)) return null
      return { left, top }
    } catch (_) {
      return null
    }
  }

  _saveFloatingPosition(storageKey, el) {
    if (!storageKey || !el) return
    try {
      window.localStorage.setItem(storageKey, JSON.stringify({
        left: parseFloat(el.style.left || "0") || 0,
        top: parseFloat(el.style.top || "0") || 0
      }))
    } catch (_) {}
  }

  _enableFloatingDrag(el, handleSelector, storageKey) {
    const handle = el ? el.querySelector(handleSelector) : null
    if (!handle || handle.dataset.dragBound === "1") return
    handle.dataset.dragBound = "1"

    let dragging = false
    let offsetX = 0
    let offsetY = 0

    const onMove = (event) => {
      if (!dragging) return
      el.style.left = `${event.clientX - offsetX}px`
      el.style.top = `${event.clientY - offsetY}px`
      this._clampFloatingElement(el)
    }

    const onUp = () => {
      if (!dragging) return
      dragging = false
      document.removeEventListener("mousemove", onMove)
      document.removeEventListener("mouseup", onUp)
      this._saveFloatingPosition(storageKey, el)
    }

    handle.addEventListener("mousedown", (event) => {
      if (event.button !== 0) return
      if (event.target && event.target.closest && event.target.closest("button, a, input, textarea, select")) return
      const rect = el.getBoundingClientRect()
      dragging = true
      offsetX = event.clientX - rect.left
      offsetY = event.clientY - rect.top
      event.preventDefault()
      document.addEventListener("mousemove", onMove)
      document.addEventListener("mouseup", onUp)
    })
  }

  _suspendUiForTicketPanel() {
    this._hideAnnotatePopup()
    this._clearSelectionPreview()
    const notesPanel = this.element.querySelector(".cv-user-notes")
    if (notesPanel && notesPanel.style.display !== "none") {
      this._hiddenNotesPanel = notesPanel
      notesPanel.style.display = "none"
    }
  }

  _restoreUiAfterTicketPanel() {
    if (this._hiddenNotesPanel && this._hiddenNotesPanel.isConnected) {
      this._hiddenNotesPanel.style.display = ""
    }
    this._hiddenNotesPanel = null
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
    if (!this._translationMode && this._judouOn && this._judouUnderlineOn) this._applyHighlights()
    this._applyInlineFootnotes()

    if (this._notesEnabled) this._renderNotesPanel()
    else this._removeNotesPanel()

    if (this._ticketPanel && !this._ticketPanel.hidden) this._renderTicketPreview()
  }


  _applyInlineFootnotes() {
    if (!this._translationMode || !this._contentEl) return

    const hidden = !this._notesEnabled
    const blocks = Array.from(this._contentEl.querySelectorAll(".corpus-note-block"))
    blocks.forEach((block) => block.classList.toggle("notes-collapsed", hidden))
  }

  _spans() {
    return Array.from(this._contentEl.querySelectorAll("span.cch[data-corpus-idx]"))
  }

  _clearAllHighlights() {
    const spans = this._spans()
    for (let i = 0; i < spans.length; i++) {
      const el = spans[i]
      el.classList.remove("ne-title", "ne-person", "ne-place", "ne-office", "ne-ambiguous-character", "ne-auto-title", "ne-note-anchor")
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
    if (kind === "ambiguous_character") return "ne-ambiguous-character"
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
          <div class="corpus-colors-title">${t("corpus_annotations.colors.heading")}</div>
          <button type="button" class="corpus-colors-close" data-action="click->corpus-annotations#closeColorSettings">×</button>
        </div>

        <div class="corpus-colors-row">
          <label>${t("corpus_annotations.colors.preset")}</label>
          <select id="cv_color_preset">
            <option value="default">${t("corpus_annotations.colors.presets.default")}</option>
            <option value="deuteranopia">${t("corpus_annotations.colors.presets.deuteranopia")}</option>
            <option value="protanopia">${t("corpus_annotations.colors.presets.protanopia")}</option>
            <option value="tritanopia">${t("corpus_annotations.colors.presets.tritanopia")}</option>
          </select>
        </div>

        <div class="corpus-colors-row"><label>${t("corpus_annotations.kinds.title")}</label><input id="cv_color_title" type="color" /></div>
        <div class="corpus-colors-row"><label>${t("corpus_annotations.kinds.person")}</label><input id="cv_color_person" type="color" /></div>
        <div class="corpus-colors-row"><label>${t("corpus_annotations.kinds.place")}</label><input id="cv_color_place" type="color" /></div>
        <div class="corpus-colors-row"><label>${t("corpus_annotations.kinds.office")}</label><input id="cv_color_office" type="color" /></div>
        <div class="corpus-colors-row"><label>${t("corpus_annotations.colors.note_marker")}</label><input id="cv_color_note" type="color" /></div>

        <div class="corpus-colors-actions">
          <button value="cancel" type="button" data-action="click->corpus-annotations#closeColorSettings">${t("corpus_annotations.actions.cancel")}</button>
          <button value="apply" type="submit" class="primary">${t("corpus_annotations.actions.apply")}</button>
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

    setLabel('[data-action*="corpus-annotations#toggleView"]', t("corpus_annotations.toggles.annotations_on"), t("corpus_annotations.toggles.annotations_off"), (this._judouOn && this._viewEnabled))
    const notesOn = this._translationMode ? this._notesEnabled : (this._judouOn && this._notesEnabled)
    const notesOnText = this._translationMode ? t("corpus_annotations.toggles.footnotes_on") : t("corpus_annotations.toggles.notes_on")
    const notesOffText = this._translationMode ? t("corpus_annotations.toggles.footnotes_off") : t("corpus_annotations.toggles.notes_off")
    setLabel('[data-action*="corpus-annotations#toggleNotes"]', notesOnText, notesOffText, notesOn)
    setLabel('[data-action*="corpus-annotations#toggleAnnotate"]', t("corpus_annotations.toggles.annotate_on"), t("corpus_annotations.toggles.annotate_off"), this._annotateEnabled)

    const saveBtn = this.element.querySelector('[data-action*="corpus-annotations#save"]')
    if (saveBtn) {
      saveBtn.hidden = !this._dirty
      saveBtn.textContent = t("corpus_annotations.actions.review_submit")
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
    panel.className = "cv-text-edit-panel cv-annotation-ticket-panel hidden"
    panel.hidden = true
    panel.innerHTML = `
      <div class="cv-annotation-ticket-card">
        <div class="cv-annotation-ticket-head">
          <h3 style="margin:0;">${t("corpus_annotations.ticket.heading")}</h3>
          <button type="button" class="corpus-btn" data-role="close-ticket-panel">${t("corpus_annotations.actions.close")}</button>
        </div>
        <p class="cv-hint">${t("corpus_annotations.ticket.explanation")}</p>
        <form data-role="annotation-ticket-form">
          <div class="cv-form-row">
            <label>${t("corpus_annotations.ticket.title")}</label>
            <input type="text" class="cv-input" value="${t("corpus_annotations.ticket.default_title")}" data-role="ticket-title" />
          </div>
          <div class="cv-form-row">
            <label>${t("corpus_annotations.ticket.summary")}</label>
            <input type="text" class="cv-input" placeholder="${t("corpus_annotations.ticket.summary_placeholder")}" data-role="ticket-summary" />
          </div>
          <div class="cv-form-row">
            <label>${t("corpus_annotations.ticket.reasoning")}</label>
            <textarea class="cv-textarea" rows="3" placeholder="${t("corpus_annotations.ticket.reasoning_placeholder")}" data-role="ticket-reasoning"></textarea>
          </div>
          <div class="cv-form-row">
            <label>${t("corpus_annotations.ticket.material_note")}</label>
            <textarea class="cv-textarea" rows="3" required placeholder="${t("corpus_annotations.ticket.material_note_placeholder")}" data-role="ticket-material-note"></textarea>
          </div>
          <fieldset class="cv-form-row cv-material-provenance">
            <legend>${t("corpus_annotations.ticket.provenance")}</legend>
            <div class="cv-hint">${t("corpus_annotations.ticket.provenance_hint")}</div>
            <label><input type="checkbox" value="user_made" data-role="ticket-provenance" /> ${t("corpus_annotations.ticket.user_made")}</label>
            <label><input type="checkbox" value="public_domain" data-role="ticket-provenance" /> ${t("corpus_annotations.ticket.public_domain")}</label>
            <label><input type="checkbox" value="historical_source" data-role="ticket-provenance" /> ${t("corpus_annotations.ticket.historical_source")}</label>
          </fieldset>
          <div class="cv-form-row">
            <label>${t("corpus_annotations.ticket.references")}</label>
            <textarea class="cv-textarea" rows="3" placeholder="${t("corpus_annotations.ticket.references_placeholder")}" data-role="ticket-references"></textarea>
          </div>
          <details class="cv-form-row">
            <summary>${t("corpus_annotations.ticket.ai_disclosure")}</summary>
            <label><input type="checkbox" data-role="ticket-ai-assisted" /> ${t("corpus_annotations.ticket.ai_assisted")}</label>
            <label>${t("corpus_annotations.ticket.ai_what")}</label>
            <textarea class="cv-textarea" rows="2" placeholder="${t("corpus_annotations.ticket.ai_placeholder")}" data-role="ticket-ai-details"></textarea>
          </details>
          <div class="cv-form-row">
            <div class="cv-annotation-preview-headline">
              <label>${t("corpus_annotations.ticket.preview")}</label>
              <div class="cv-form-actions">
                <button type="button" class="corpus-btn" data-role="add-annotation-item">${t("corpus_annotations.actions.add_row")}</button>
              </div>
            </div>
            <div class="cv-annotation-preview-list" data-role="ticket-preview-list"></div>
          </div>
          <div class="cv-form-row">
            <label>${t("corpus_annotations.ticket.evidence_links")}</label>
            <textarea rows="3" data-role="ticket-evidence-links" placeholder="${t("corpus_annotations.ticket.evidence_links_placeholder")}"></textarea>
          </div>
          <div class="cv-form-row">
            <label>${t("corpus_annotations.ticket.evidence_files")}</label>
            <input type="file" multiple accept="application/pdf,text/plain,image/png,image/jpeg" data-role="ticket-evidence-files" />
            <div class="cv-hint">${t("corpus_annotations.ticket.evidence_files_hint")}</div>
          </div>
          <details class="cv-form-row">
            <summary>${t("corpus_annotations.ticket.contact_details")}</summary>
            <p class="cv-hint">${t("corpus_annotations.ticket.contact_hint")}</p>
            <label>${t("corpus_annotations.ticket.name")} <input type="text" data-role="ticket-contact-name" autocomplete="name" /></label>
            <label>${t("corpus_annotations.ticket.email")} <input type="email" data-role="ticket-contact-email" autocomplete="email" /></label>
            <label>${t("corpus_annotations.ticket.contact_note")} <textarea rows="2" data-role="ticket-contact-notes"></textarea></label>
          </details>
          <div class="cv-form-row">
            <label class="cv-inline-check"><input type="checkbox" data-role="store-on-device" /> ${t("corpus_annotations.ticket.store_on_device")}</label>
            <div class="cv-hint">${t("corpus_annotations.ticket.unchecked_default")}</div>
          </div>
          <div class="cv-form-actions">
            <button type="submit" class="corpus-btn corpus-btn-primary">${t("corpus_annotations.actions.create_ticket")}</button>
            <button type="button" class="corpus-btn" data-role="close-ticket-panel">${t("corpus_annotations.actions.close")}</button>
          </div>
        </form>
        <div class="cv-ticket-result">
          <div class="cv-ticket-status" data-role="ticket-status"></div>
          <div class="cv-ticket-kv">
            <div><strong>${t("corpus_annotations.ticket.ticket_id")}</strong> <span data-role="ticket-id"></span></div>
            <div><strong>${t("corpus_annotations.ticket.ticket_key")}</strong> <code data-role="ticket-key"></code></div>
          </div>
          <div class="cv-form-actions">
            <button type="button" class="corpus-btn" data-role="copy-ticket-key" hidden>${t("corpus_annotations.actions.copy_key")}</button>
            <button type="button" class="corpus-btn" data-role="download-ticket-key" hidden>${t("corpus_annotations.actions.download_txt")}</button>
            <a class="corpus-btn" data-role="open-ticket-link" hidden>${t("corpus_annotations.actions.open_ticket")}</a>
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
    this._ticketMaterialNoteInput = panel.querySelector('[data-role="ticket-material-note"]')
    this._ticketProvenanceInputs = panel.querySelectorAll('[data-role="ticket-provenance"]')
    this._ticketReferencesInput = panel.querySelector('[data-role="ticket-references"]')
    this._ticketAiAssistedInput = panel.querySelector('[data-role="ticket-ai-assisted"]')
    this._ticketAiDetailsInput = panel.querySelector('[data-role="ticket-ai-details"]')
    this._ticketPreviewList = panel.querySelector('[data-role="ticket-preview-list"]')
    this._ticketStatusEl = panel.querySelector('[data-role="ticket-status"]')
    this._ticketIdValue = panel.querySelector('[data-role="ticket-id"]')
    this._ticketKeyValue = panel.querySelector('[data-role="ticket-key"]')
    this._copyTicketKeyBtn = panel.querySelector('[data-role="copy-ticket-key"]')
    this._downloadTicketKeyBtn = panel.querySelector('[data-role="download-ticket-key"]')
    this._openTicketLink = panel.querySelector('[data-role="open-ticket-link"]')
    this._storeOnDeviceCheckbox = panel.querySelector('[data-role="store-on-device"]')
    this._ticketEvidenceLinksInput = panel.querySelector('[data-role="ticket-evidence-links"]')
    this._ticketEvidenceFilesInput = panel.querySelector('[data-role="ticket-evidence-files"]')
    this._ticketContactNameInput = panel.querySelector('[data-role="ticket-contact-name"]')
    this._ticketContactEmailInput = panel.querySelector('[data-role="ticket-contact-email"]')
    this._ticketContactNotesInput = panel.querySelector('[data-role="ticket-contact-notes"]')

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
      p.textContent = t("corpus_annotations.preview.none")
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
        <label>${t("corpus_annotations.preview.kind")}
          <select data-field="kind">
            ${this._kindOptionsHtml(item.kind)}
          </select>
        </label>
        <label>${t("corpus_annotations.preview.start")}
          <input type="number" min="0" step="1" data-field="start" value="${Number(item.start)}" />
        </label>
        <label>${t("corpus_annotations.preview.end")}
          <input type="number" min="1" step="1" data-field="end" value="${Number(item.end)}" />
        </label>
        <button type="button" class="corpus-btn" data-action="delete-item">${t("corpus_annotations.actions.delete")}</button>
      `
      card.appendChild(controls)

      const head = document.createElement("div")
      head.className = "cv-annotation-preview-head"
      head.textContent = `${this._humanKind(item.kind)} · ${item.start}–${Math.max(Number(item.start), Number(item.end) - 1)}`
      card.appendChild(head)

      const text = document.createElement("div")
      text.className = "cv-annotation-preview-text"
      text.textContent = item.text || t("corpus_annotations.preview.no_text")
      card.appendChild(text)

      const noteWrap = document.createElement("label")
      noteWrap.className = "cv-annotation-preview-note-editor"
      noteWrap.innerHTML = `${t("corpus_annotations.preview.note")} <textarea rows="2" data-field="note">${this._escapeHtml(item.note || "")}</textarea>`
      card.appendChild(noteWrap)

      row.appendChild(card)
      this._ticketPreviewList.appendChild(row)
    }
  }


  _kindOptionsHtml(selectedKind) {
    const kinds = ["title", "person", "place", "office", "ambiguous_character"]
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
    if (this._ticketPanel) this._showTicketPanel()
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
    item.kind = ["title", "person", "place", "office", "ambiguous_character"].includes(item.kind) ? item.kind : "person"
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
    if (kind === "title") return t("corpus_annotations.kinds.title")
    if (kind === "person") return t("corpus_annotations.kinds.person")
    if (kind === "place") return t("corpus_annotations.kinds.place")
    if (kind === "office") return t("corpus_annotations.kinds.office")
    if (kind === "ambiguous_character") return t("corpus_annotations.kinds.ambiguous")
    return kind || t("corpus_annotations.kinds.annotation")
  }

  _showTicketPanel() {
    if (!this._ticketPanel) return
    this._suspendUiForTicketPanel()
    this._ticketPanel.hidden = false
    this._ticketPanel.classList.remove("hidden")
    this._positionFloatingElement(this._ticketPanel, window.innerWidth * 0.08, window.innerHeight * 0.06, this._floatingStorageKey("annotation-ticket-panel"), { preferAbove: false })
  }

  _hideTicketPanel() {
    if (!this._ticketPanel) return
    this._ticketPanel.hidden = true
    this._ticketPanel.classList.add("hidden")
    this._restoreUiAfterTicketPanel()
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
        this._openTicketLink.textContent = t("corpus_annotations.actions.open_ticket")
      } else {
        this._openTicketLink.hidden = true
        this._openTicketLink.removeAttribute("href")
      }
    }
  }

  _ticketEvidenceLinks() {
    const value = this._ticketEvidenceLinksInput ? this._ticketEvidenceLinksInput.value : ""
    return value.split(/\r?\n/).map((link) => link.trim()).filter((link) => link.length > 0)
  }

  _ticketContact() {
    const contact = {
      name: this._ticketContactNameInput ? this._ticketContactNameInput.value.trim() : "",
      email: this._ticketContactEmailInput ? this._ticketContactEmailInput.value.trim() : "",
      notes: this._ticketContactNotesInput ? this._ticketContactNotesInput.value.trim() : "",
    }
    return Object.values(contact).some((value) => value.length > 0) ? contact : null
  }

  _csrfToken() {
    const el = document.querySelector('meta[name="csrf-token"]')
    return el ? el.content : ""
  }
}
