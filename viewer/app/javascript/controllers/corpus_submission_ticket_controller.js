import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "panel", "status", "ticketId", "ticketKey", "copyKeyBtn", "storeOnDevice",
    "parentPath", "workFolder", "title", "summary", "nation", "workTitle", "author", "textType",
    "sourceCitation", "url", "contextDetails", "pageMode", "singleFields", "multiFields",
    "fileName", "pageTitle", "body", "uploads", "pagesList"
  ]

  static values = {
    source: String,
    parentPath: String,
    lockParentPath: Boolean
  }

  connect() {
    if (this.hasParentPathTarget && this.parentPathValue) {
      this.parentPathTarget.value = this.parentPathValue
      if (this.lockParentPathValue) this.parentPathTarget.setAttribute("readonly", "readonly")
    }
    this.togglePageMode()
    if (this.hasPagesListTarget && this.pagesListTarget.children.length === 0) {
      this.addPage()
    }
  }

  toggle() {
    if (!this.hasPanelTarget) return
    this.panelTarget.classList.toggle("hidden")
  }

  togglePageMode() {
    const mode = this.hasPageModeTarget ? this.pageModeTarget.value : "single"
    if (this.hasSingleFieldsTarget) this.singleFieldsTarget.hidden = mode !== "single"
    if (this.hasMultiFieldsTarget) this.multiFieldsTarget.hidden = mode !== "multi"
  }

  addPage(event) {
    if (event) event.preventDefault()
    if (!this.hasPagesListTarget) return

    const index = this.pagesListTarget.children.length + 1
    const row = document.createElement("div")
    row.className = "cv-submission-page-card"
    row.innerHTML = `
      <div class="cv-form-row">
        <label>Page label</label>
        <input type="text" class="cv-input" data-role="page-label" value="卷${String(index).padStart(3, "0")}" />
      </div>
      <div class="cv-form-row">
        <label>Page text</label>
        <textarea class="cv-textarea cv-mono" rows="10" data-role="page-body"></textarea>
      </div>
      <div class="cv-form-actions">
        <button type="button" class="corpus-btn" data-action="corpus-submission-ticket#removePage">Remove page</button>
      </div>
    `
    this.pagesListTarget.appendChild(row)
  }

  removePage(event) {
    event.preventDefault()
    const card = event.target.closest(".cv-submission-page-card")
    if (card) card.remove()
    if (this.hasPagesListTarget && this.pagesListTarget.children.length === 0) {
      this.addPage()
    }
  }

  async submit(event) {
    event.preventDefault()
    this._setStatus("Submitting ticket…")
    this._setTicket("", "")

    const form = new FormData()
    form.append("kind", "corpus_submission")
    form.append("source", this.sourceValue || "corpus_submission")
    form.append("parent_path", this.hasParentPathTarget ? this.parentPathTarget.value.trim() : "")
    form.append("work_folder", this.hasWorkFolderTarget ? this.workFolderTarget.value.trim() : "")
    form.append("title", this.hasTitleTarget ? this.titleTarget.value : "")
    form.append("summary", this.hasSummaryTarget ? this.summaryTarget.value : "")
    form.append("nation", this.hasNationTarget ? this.nationTarget.value : "")
    form.append("work_title", this.hasWorkTitleTarget ? this.workTitleTarget.value : "")
    form.append("author", this.hasAuthorTarget ? this.authorTarget.value : "")
    form.append("text_type", this.hasTextTypeTarget ? this.textTypeTarget.value : "source")
    form.append("source_citation", this.hasSourceCitationTarget ? this.sourceCitationTarget.value : "")
    form.append("url", this.hasUrlTarget ? this.urlTarget.value : "")
    form.append("context_details", this.hasContextDetailsTarget ? this.contextDetailsTarget.value : "")

    const pageMode = this.hasPageModeTarget ? this.pageModeTarget.value : "single"
    form.append("page_mode", pageMode)

    if (pageMode === "multi") {
      const pages = Array.from(this.pagesListTarget.querySelectorAll(".cv-submission-page-card")).map((card) => ({
        label: (card.querySelector('[data-role="page-label"]')?.value || "").trim(),
        body: card.querySelector('[data-role="page-body"]')?.value || ""
      }))
      form.append("pages", JSON.stringify(pages))
    } else {
      form.append("file_name", this.hasFileNameTarget ? this.fileNameTarget.value.trim() : "")
      form.append("page_title", this.hasPageTitleTarget ? this.pageTitleTarget.value.trim() : "")
      form.append("body", this.hasBodyTarget ? this.bodyTarget.value : "")
    }

    if (this.hasUploadsTarget) {
      for (const file of Array.from(this.uploadsTarget.files || [])) {
        form.append("evidence_files[]", file)
      }
    }

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

      this._setStatus("Ticket created ✅ (save the key below)")
      this._setTicket(data.ticket_id || (data.ticket && data.ticket.id) || "", data.ticket_key || "")

      if (data.ticket_id && data.ticket_key) {
        try {
          window.localStorage.setItem(`ticket_key:${data.ticket_id}`, data.ticket_key)
          if (this.hasStoreOnDeviceTarget && this.storeOnDeviceTarget.checked) {
            this._storeTicketOnDevice(data.ticket_id, data.ticket_key)
          }
        } catch (_e) {}
      }
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

  _storeTicketOnDevice(ticketId, ticketKey) {
    const key = "cv_ticket_keys_v1"
    let list = []
    try {
      list = JSON.parse(window.localStorage.getItem(key) || "[]")
      if (!Array.isArray(list)) list = []
    } catch (_e) {
      list = []
    }
    list = list.filter((t) => t.ticket_id !== ticketId)
    list.unshift({ ticket_id: ticketId, ticket_key: ticketKey, saved_at: new Date().toISOString() })
    window.localStorage.setItem(key, JSON.stringify(list.slice(0, 25)))
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
  }
}
