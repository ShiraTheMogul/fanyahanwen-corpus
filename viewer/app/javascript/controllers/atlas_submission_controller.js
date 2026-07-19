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
    "downloadKeyBtn", "previewForm", "previewEntryId", "previewLocale", "previewMarkdown",
    "downloadTemplate"
  ]

  static values = {
    entryId: String,
    publishedLocales: Array,
    sourceLocale: String,
    submittingMessage: String,
    successMessage: String,
    errorPrefix: String,
    changeLanguageWarning: String,
    snippets: Object,
  }

  connect() {
    this.loadedLocale = this.localeTarget.value
    this.loadedMarkdown = this.rawMarkdownTarget.value
    this._updateLocaleState(this.loadedLocale)
  }

  async localeChanged() {
    const locale = this.localeTarget.value
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
      const response = await fetch(this._templateUrl(locale), { headers: { "Accept": "text/markdown" } })
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
    this.submissionActionTarget.value = action

    const labels = {
      create: this.actionLabelTarget.dataset.createLabel || "Create article",
      edit: this.actionLabelTarget.dataset.editLabel || "Suggest an edit",
      translate: this.actionLabelTarget.dataset.translateLabel || "Submit a translation",
    }
    this.actionLabelTarget.value = labels[action]

    const requiredRole = action === "create" ? "author" : (action === "translate" ? "translator" : "contributor")
    this.creditRoleTarget.value = requiredRole
    Array.from(this.creditRoleTarget.options).forEach((option) => {
      option.hidden = ![requiredRole, "anonymous"].includes(option.value)
    })

    this.downloadTemplateTarget.href = this._templateUrl(locale)
  }

  _templateUrl(locale) {
    return `/atlas/${encodeURIComponent(this.entryIdValue)}/template?locale=${encodeURIComponent(locale)}`
  }

  insertCorpusQuote() { this._insertAtCursor(this.snippetsValue.quote || "") }
  insertExactSearch() { this._insertCorpusSearch(this.snippetsValue.exact_search || "") }
  insertAlternativesSearch() { this._insertCorpusSearch(this.snippetsValue.alternatives_search || "") }
  insertProximitySearch() { this._insertCorpusSearch(this.snippetsValue.proximity_search || "") }

  _insertAtCursor(snippet) {
    if (!snippet) return
    const textarea = this.rawMarkdownTarget
    const start = textarea.selectionStart ?? textarea.value.length
    const end = textarea.selectionEnd ?? start
    const before = textarea.value.slice(0, start)
    const after = textarea.value.slice(end)
    const prefix = before.length && !before.endsWith("\n") ? "\n" : ""
    const suffix = after.length && !after.startsWith("\n") ? "\n" : ""
    textarea.setRangeText(`${prefix}${snippet}\n${suffix}`, start, end, "end")
    textarea.focus()
  }

  _insertCorpusSearch(itemSnippet) {
    if (!itemSnippet) return
    const textarea = this.rawMarkdownTarget
    const newline = textarea.value.includes("\r\n") ? "\r\n" : "\n"
    const normalizedItem = itemSnippet.replace(/\n/g, newline)
    const text = textarea.value

    if (!text.match(/^---\r?\n/)) {
      textarea.value = `---${newline}corpus_searches:${newline}${normalizedItem}${newline}---${newline}${newline}${text}`
      textarea.focus()
      return
    }

    const lines = text.split(/\r?\n/)
    const closingIndex = lines.findIndex((line, index) => index > 0 && line.trim() === "---")
    if (closingIndex < 0) {
      this._insertAtCursor(`corpus_searches:${newline}${normalizedItem}`)
      return
    }

    const keyIndex = lines.slice(1, closingIndex).findIndex((line) => /^corpus_searches:\s*(?:\[\])?\s*$/.test(line))
    if (keyIndex < 0) {
      lines.splice(closingIndex, 0, "corpus_searches:", ...normalizedItem.split(newline))
    } else {
      const absoluteKeyIndex = keyIndex + 1
      if (/^corpus_searches:\s*\[\]\s*$/.test(lines[absoluteKeyIndex])) lines[absoluteKeyIndex] = "corpus_searches:"
      let insertionIndex = absoluteKeyIndex + 1
      while (insertionIndex < closingIndex) {
        const line = lines[insertionIndex]
        if (line.length && !/^\s/.test(line) && !/^#/.test(line)) break
        insertionIndex += 1
      }
      lines.splice(insertionIndex, 0, ...normalizedItem.split(newline))
    }

    textarea.value = lines.join(newline)
    textarea.focus()
  }

  preview(event) {
    event.preventDefault()
    this.previewEntryIdTarget.value = this.entryIdValue
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
      form.append("kind", "atlas_article_submission")
      form.append("source", "historical_atlas")
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
        headers: { "Accept": "application/json", "X-CSRF-Token": this._csrfToken() },
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
        source: "historical_atlas",
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
    if (value) navigator.clipboard.writeText(value)
  }

  downloadKey(event) {
    event.preventDefault()
    downloadTicketKey(this.ticketIdTarget.textContent || "", this.ticketKeyTarget.textContent || "")
  }

  _ticketTitle() {
    const labels = {
      create: "Atlas article",
      edit: "Atlas article edit",
      translate: "Atlas article translation",
    }
    const action = this.submissionActionTarget.value
    return `${labels[action] || "Atlas submission"} — ${this.entryIdValue}`
  }

  _csrfToken() { return document.querySelector('meta[name="csrf-token"]')?.content || "" }
  _setStatus(value) { if (this.hasStatusTarget) this.statusTarget.textContent = value }

  _setTicket(id, key) {
    this.ticketIdTarget.textContent = id
    this.ticketKeyTarget.textContent = key
    this.ticketResultTarget.hidden = !(id && key)
    this.copyKeyBtnTarget.hidden = !(id && key)
    this.downloadKeyBtnTarget.hidden = !(id && key)
  }
}
