import { Controller } from "@hotwired/stimulus"
import { appendMaterialMetadata, appendSubmissionExtras, materialMetadataFrom, maybeStoreTicketOnDevice } from "controllers/ticket_submission_helpers"

const ANNOTATION_SYSTEMS = ["kanbun", "hanmun", "hanvan"]

export default class extends Controller {
  static targets = [
    "panel", "status", "ticketId", "ticketKey", "copyKeyBtn", "downloadKeyBtn", "openTicketLink",
    "storeOnDevice", "annotationSystem", "summary", "reasoning", "annotationText", "sourceSeed",
    "evidenceLinks", "contactName", "contactEmail", "contactNotes", "uploads",
    "kanbunSeed", "hanmunSeed", "hanvanSeed", "aiNotice",
    "materialNote", "references", "aiAssisted", "aiDetails"
  ]

  static values = {
    source: String,
    targetPath: String,
  }

  connect() {
    this._lastDefault = ""
    this.applyAnnotationSystemDefaults()
  }

  toggle() {
    if (!this.hasPanelTarget) return
    this.panelTarget.classList.toggle("hidden")
    if (!this.panelTarget.classList.contains("hidden")) {
      this.applyAnnotationSystemDefaults()
      this._syncAiNotice()
    }
  }

  annotationSystemChanged() {
    this.applyAnnotationSystemDefaults(true)
    this._syncAiNotice()
  }

  applyAnnotationSystemDefaults(forceReplace = false) {
    if (!this.hasAnnotationTextTarget || !this.hasAnnotationSystemTarget) return

    const nextDefault = this._defaultBodyFor(this.annotationSystemTarget.value)
    const currentValue = this.annotationTextTarget.value || ""

    if (forceReplace || !currentValue || currentValue === this._lastDefault) {
      this.annotationTextTarget.value = nextDefault
    }

    this._lastDefault = nextDefault
  }

  insertSymbol(event) {
    event.preventDefault()
    if (!this.hasAnnotationTextTarget) return

    const symbol = event.currentTarget.dataset.symbol || ""
    const el = this.annotationTextTarget
    const start = el.selectionStart || 0
    const end = el.selectionEnd || 0
    const before = el.value.slice(0, start)
    const after = el.value.slice(end)

    el.value = `${before}${symbol}${after}`
    el.focus()
    const nextPos = start + symbol.length
    el.setSelectionRange(nextPos, nextPos)
  }

  async submit(event) {
    event.preventDefault()

    const annotationSystem = this.hasAnnotationSystemTarget ? this.annotationSystemTarget.value : "kanbun"
    if (!ANNOTATION_SYSTEMS.includes(annotationSystem)) {
      this._setStatus("Error: invalid annotation system.")
      return
    }

    const bodyText = this.hasAnnotationTextTarget ? this.annotationTextTarget.value : ""
    if (!bodyText.trim()) {
      this._setStatus("Error: annotation-system text is empty.")
      return
    }

    const materialMetadata = materialMetadataFrom(this)
    if (!materialMetadata.material_note) {
      this._setStatus("Error: material note is required.")
      return
    }
    if (materialMetadata.provenance.length === 0) {
      this._setStatus("Error: choose at least one provenance label.")
      return
    }
    if (materialMetadata.ai_assisted && !materialMetadata.ai_details) {
      this._setStatus("Error: describe the AI assistance.")
      return
    }

    const titleMap = {
      kanbun: "Kanbun annotation-system submission",
      hanmun: "Hanmun annotation-system submission",
      hanvan: "Hanvan annotation-system submission",
    }

    const form = new FormData()
    form.append("kind", "annotation_system_submission")
    form.append("source", this.sourceValue || "corpus_viewer")
    form.append("base_path", this.targetPathValue || "")
    form.append("annotation_system", annotationSystem)
    form.append("title", titleMap[annotationSystem] || "Annotation-system submission")
    form.append("summary", this.hasSummaryTarget ? this.summaryTarget.value : "")
    form.append("reasoning", this.hasReasoningTarget ? this.reasoningTarget.value : "")
    form.append("body_text", bodyText)
    form.append("generation_mode", materialMetadata.ai_assisted ? "ai_assisted" : "manual")
    appendMaterialMetadata(form, this)
    appendSubmissionExtras(form, this)

    this._setStatus("Submitting ticket…")
    this._setTicket("", "")

    try {
      const resp = await fetch("/api/tickets", {
        method: "POST",
        headers: {
          "Accept": "application/json",
          "X-CSRF-Token": this._csrfToken(),
        },
        body: form,
      })

      const data = await resp.json().catch(() => null)
      if (!resp.ok || !data || data.ok !== true) {
        const msg = (data && (data.error || data.detail)) ? (data.error || data.detail) : `HTTP ${resp.status}`
        this._setStatus(`Error: ${msg}`)
        return
      }

      const ticketId = data.ticket_id || data.ticket?.id || ""
      const ticketKey = data.ticket_key || ""
      this._setStatus("Ticket created ✅ (save the key below)")
      this._setTicket(ticketId, ticketKey)

      try {
        maybeStoreTicketOnDevice(this, ticketId, ticketKey, {
          title: titleMap[annotationSystem] || "Annotation-system submission",
          source: annotationSystem,
        })
      } catch (_error) {}
    } catch (e) {
      this._setStatus(`Error: ${e.message || e}`)
    }
  }

  copyKey(event) {
    event.preventDefault()
    if (!this.hasTicketKeyTarget) return
    const key = this.ticketKeyTarget.textContent || ""
    if (!key) return
    navigator.clipboard.writeText(key).then(() => {
      if (this.hasCopyKeyBtnTarget) {
        const before = this.copyKeyBtnTarget.textContent
        this.copyKeyBtnTarget.textContent = "Copied!"
        setTimeout(() => (this.copyKeyBtnTarget.textContent = before), 1000)
      }
    })
  }

  downloadKey(event) {
    event.preventDefault()
    const id = this.hasTicketIdTarget ? (this.ticketIdTarget.textContent || "") : ""
    const key = this.hasTicketKeyTarget ? (this.ticketKeyTarget.textContent || "") : ""
    if (!id || !key) return

    const target = this.targetPathValue || ""
    const annotationSystem = this.hasAnnotationSystemTarget ? this.annotationSystemTarget.value : ""
    const content = `TICKET ID: ${id}\nTICKET KEY: ${key}\nSOURCE PAGE: ${target}\nANNOTATION SYSTEM: ${annotationSystem}\n`
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

  _defaultBodyFor(annotationSystem) {
    const seedTarget = this._seedTargetFor(annotationSystem)
    const seedValue = seedTarget ? seedTarget.value : ""
    if (seedValue && seedValue.trim()) return seedValue
    return this.hasSourceSeedTarget ? this.sourceSeedTarget.value : ""
  }

  _seedTargetFor(annotationSystem) {
    switch (annotationSystem) {
      case "kanbun":
        return this.hasKanbunSeedTarget ? this.kanbunSeedTarget : null
      case "hanmun":
        return this.hasHanmunSeedTarget ? this.hanmunSeedTarget : null
      case "hanvan":
        return this.hasHanvanSeedTarget ? this.hanvanSeedTarget : null
      default:
        return null
    }
  }

  _syncAiNotice() {
    if (!this.hasAiNoticeTarget || !this.hasAnnotationSystemTarget) return
    this.aiNoticeTarget.hidden = this.annotationSystemTarget.value === "kanbun"
  }

  _csrfToken() {
    const el = document.querySelector('meta[name="csrf-token"]')
    return el ? el.content : ""
  }

  _setStatus(text) {
    if (this.hasStatusTarget) this.statusTarget.textContent = text
  }

  _setTicket(id, key) {
    if (this.hasTicketIdTarget) this.ticketIdTarget.textContent = id || ""
    if (this.hasTicketKeyTarget) this.ticketKeyTarget.textContent = key || ""

    if (this.hasDownloadKeyBtnTarget) {
      this.downloadKeyBtnTarget.hidden = !(id && key)
    }

    if (this.hasOpenTicketLinkTarget) {
      if (id && key) {
        this.openTicketLinkTarget.hidden = false
        this.openTicketLinkTarget.href = `/ticket_access?key=${encodeURIComponent(key)}`
      } else {
        this.openTicketLinkTarget.hidden = true
        this.openTicketLinkTarget.removeAttribute("href")
      }
    }
  }
}
