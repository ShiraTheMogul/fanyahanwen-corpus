import { Controller } from "@hotwired/stimulus"
import {
  appendSubmissionExtras,
  downloadTicketKey,
  maybeStoreTicketOnDevice,
} from "controllers/ticket_submission_helpers"

export default class extends Controller {
  static targets = [
    "locale", "submissionAction", "actionLabel", "publicName", "orcid", "creditRole",
    "rawMarkdown", "summary", "reasoning", "evidenceLinks", "uploads",
    "contactName", "contactEmail", "contactNotes", "licence", "storeOnDevice",
    "submit", "status", "ticketResult", "ticketId", "ticketKey", "copyKeyBtn",
    "downloadKeyBtn", "previewForm", "previewLocale", "previewMarkdown", "downloadTemplate"
  ]

  static values = {
    entryId: String,
    publishedLocales: Array,
    sourceLocale: String,
    submittingMessage: String,
    successMessage: String,
    errorPrefix: String,
    changeLanguageWarning: String,
  }

  connect() {
    this.loadedLocale = this.localeTarget.value
    this.loadedMarkdown = this.rawMarkdownTarget.value
    this._updateLocaleState(this.loadedLocale)
  }

  async localeChanged() {
    const locale = this.hasLocaleTarget ? this.localeTarget.value : this.sourceLocaleValue
    const previousLocale = this.loadedLocale
    const changedText = this.rawMarkdownTarget.value !== this.loadedMarkdown

    if (locale !== previousLocale && changedText) {
      const proceed = window.confirm(this.changeLanguageWarningValue)
      if (!proceed) {
        this.localeTarget.value = previousLocale
        this._updateLocaleState(previousLocale)
        return
      }
    }

    this._updateLocaleState(locale)
    if (locale === previousLocale) return

    try {
      const response = await fetch(this._templateUrl(locale), {
        headers: { "Accept": "text/markdown" },
      })
      if (!response.ok) throw new Error(`HTTP ${response.status}`)

      const markdown = await response.text()
      this.rawMarkdownTarget.value = markdown
      this.loadedLocale = locale
      this.loadedMarkdown = markdown
      this.previewLocaleTarget.value = locale
    } catch (error) {
      this.localeTarget.value = previousLocale
      this._updateLocaleState(previousLocale)
      this._setStatus(`${this.errorPrefixValue}: ${error.message || error}`)
    }
  }

  _updateLocaleState(locale) {
    const exists = this.publishedLocalesValue.includes(locale)
    const action = exists ? "edit" : (locale === this.sourceLocaleValue ? "create" : "translate")

    if (this.hasSubmissionActionTarget) this.submissionActionTarget.value = action
    if (this.hasActionLabelTarget) {
      const labels = {
        create: this.actionLabelTarget.dataset.createLabel || "Create article",
        edit: this.actionLabelTarget.dataset.editLabel || "Suggest an edit",
        translate: this.actionLabelTarget.dataset.translateLabel || "Submit a translation",
      }
      this.actionLabelTarget.value = labels[action]
    }

    if (this.hasCreditRoleTarget) {
      const requiredRole = action === "create" ? "author" : (action === "translate" ? "translator" : "contributor")
      this.creditRoleTarget.value = requiredRole
      Array.from(this.creditRoleTarget.options).forEach((option) => {
        option.hidden = ![requiredRole, "anonymous"].includes(option.value)
      })
    }

    if (this.hasDownloadTemplateTarget) this.downloadTemplateTarget.href = this._templateUrl(locale)
  }

  _templateUrl(locale) {
    return `/grammar/${encodeURIComponent(this.entryIdValue)}/template?locale=${encodeURIComponent(locale)}`
  }

  preview(event) {
    event.preventDefault()
    if (!this.hasPreviewFormTarget) return

    this.previewLocaleTarget.value = this.localeTarget.value
    this.previewMarkdownTarget.value = this.rawMarkdownTarget.value
    this.previewFormTarget.requestSubmit()
  }

  async submit(event) {
    event.preventDefault()

    if (!this.licenceTarget.checked) {
      this._setStatus(`${this.errorPrefixValue}: CC BY agreement is required`)
      return
    }

    this.submitTarget.disabled = true
    this._setStatus(this.submittingMessageValue)
    this._setTicket("", "")

    try {
      const form = new FormData()
      form.append("kind", "grammar_entry_submission")
      form.append("source", "grammar_wiki")
      form.append("entry_id", this.entryIdValue)
      form.append("submission_action", this.submissionActionTarget.value)
      form.append("locale", this.localeTarget.value)
      form.append("raw_markdown", this.rawMarkdownTarget.value)
      form.append("public_name", this.publicNameTarget.value)
      form.append("orcid", this.orcidTarget.value)
      form.append("credit_role", this.creditRoleTarget.value)
      form.append("licence_agreed", this.licenceTarget.checked ? "1" : "0")
      form.append("title", this._ticketTitle())
      form.append("summary", this.summaryTarget.value)
      form.append("reasoning", this.reasoningTarget.value)
      appendSubmissionExtras(form, this)

      const response = await fetch("/api/tickets", {
        method: "POST",
        headers: {
          "Accept": "application/json",
          "X-CSRF-Token": this._csrfToken(),
        },
        body: form,
      })

      const data = await response.json().catch(() => null)
      if (!response.ok || !data || data.ok !== true) {
        const message = data && data.error ? data.error : `HTTP ${response.status}`
        this._setStatus(`${this.errorPrefixValue}: ${message}`)
        return
      }

      const ticketId = data.ticket_id || data.ticket?.id || ""
      const ticketKey = data.ticket_key || ""
      this._setStatus(this.successMessageValue)
      this._setTicket(ticketId, ticketKey)

      maybeStoreTicketOnDevice(this, ticketId, ticketKey, {
        title: this._ticketTitle(),
        source: "grammar_wiki",
        entry_id: this.entryIdValue,
      })
    } catch (error) {
      this._setStatus(`${this.errorPrefixValue}: ${error.message || error}`)
    } finally {
      this.submitTarget.disabled = false
    }
  }

  copyKey(event) {
    event.preventDefault()
    const value = this.ticketKeyTarget.textContent || ""
    if (!value) return

    navigator.clipboard.writeText(value)
  }

  downloadKey(event) {
    event.preventDefault()
    downloadTicketKey(
      this.ticketIdTarget.textContent || "",
      this.ticketKeyTarget.textContent || ""
    )
  }

  _ticketTitle() {
    const action = this.submissionActionTarget.value
    const labels = {
      create: "Grammar article",
      edit: "Grammar article edit",
      translate: "Grammar article translation",
    }
    return `${labels[action] || "Grammar submission"} — ${this.entryIdValue}`
  }

  _csrfToken() {
    return document.querySelector('meta[name="csrf-token"]')?.content || ""
  }

  _setStatus(value) {
    if (this.hasStatusTarget) this.statusTarget.textContent = value
  }

  _setTicket(id, key) {
    this.ticketIdTarget.textContent = id
    this.ticketKeyTarget.textContent = key
    this.ticketResultTarget.hidden = !(id && key)
    this.copyKeyBtnTarget.hidden = !(id && key)
    this.downloadKeyBtnTarget.hidden = !(id && key)
  }
}
