import { Controller } from "@hotwired/stimulus"
import { appendSubmissionExtras, downloadTicketKey, maybeStoreTicketOnDevice } from "controllers/ticket_submission_helpers"
import { t } from "i18n"

export default class extends Controller {
  static targets = [
    "panel", "status", "ticketId", "ticketKey", "copyKeyBtn", "downloadKeyBtn", "storeOnDevice",
    "parentPath", "workFolder", "title", "summary", "nation", "workTitle", "author", "dateLabel", "period", "polity", "region", "categories", "textType",
    "sourceCitation", "url", "contextDetails", "pageMode", "singleFields", "multiFields",
    "fileName", "pageTitle", "body", "uploads", "pagesList",
    "evidenceLinks", "contactName", "contactEmail", "contactNotes"
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
        <label>${t("corpus_submission.page_label")}</label>
        <input type="text" class="cv-input" data-role="page-label" value="${t("corpus_submission.default_page_label", { number: String(index).padStart(3, "0") })}" />
      </div>
      <div class="cv-form-row">
        <label>${t("corpus_submission.page_text")}</label>
        <textarea class="cv-textarea cv-mono" rows="10" data-role="page-body"></textarea>
      </div>
      <div class="cv-form-actions">
        <button type="button" class="corpus-btn" data-action="corpus-submission-ticket#removePage">${t("corpus_submission.remove_page")}</button>
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
    this._setStatus(t("corpus_submission.submitting"))
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
    form.append("date_label", this.hasDateLabelTarget ? this.dateLabelTarget.value : "")
    form.append("period", this.hasPeriodTarget ? this.periodTarget.value : "")
    form.append("polity", this.hasPolityTarget ? this.polityTarget.value : "")
    form.append("region", this.hasRegionTarget ? this.regionTarget.value : "")
    form.append("categories", this.hasCategoriesTarget ? this.categoriesTarget.value : "")
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

    appendSubmissionExtras(form, this)

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
        this._setStatus(t("corpus_submission.error", { message: msg }))
        return
      }

      this._setStatus(t("corpus_submission.created"))
      this._setTicket(data.ticket_id || (data.ticket && data.ticket.id) || "", data.ticket_key || "")

      try {
        maybeStoreTicketOnDevice(this, data.ticket_id, data.ticket_key, {
          title: this.hasTitleTarget ? this.titleTarget.value : "",
          source: "corpus_submission",
        })
      } catch (_error) {}
    } catch (e) {
      this._setStatus(t("corpus_submission.error", { message: e.message || e }))
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
        this.copyKeyBtnTarget.textContent = t("corpus_submission.copied")
        setTimeout(() => (this.copyKeyBtnTarget.textContent = before), 1000)
      }
    })
  }

  downloadKey(event) {
    event.preventDefault()
    const id = this.hasTicketIdTarget ? this.ticketIdTarget.textContent : ""
    const key = this.hasTicketKeyTarget ? this.ticketKeyTarget.textContent : ""
    downloadTicketKey(id, key)
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
    if (this.hasDownloadKeyBtnTarget) this.downloadKeyBtnTarget.hidden = !(id && key)
  }
}
