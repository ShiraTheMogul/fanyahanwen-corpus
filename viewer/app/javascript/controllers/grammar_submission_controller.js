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
    "previewEntryKind", "previewEntryHeadword", "previewEntryTitle", "previewEntryParent",
    "previewEntryLabel", "downloadTemplate", "entryKind", "entryHeadword", "entryTitle",
    "entryParent", "entryLabel", "entryId", "idStatus", "functionParentField",
    "functionLabelField"
  ]

  static values = {
    entryId: String,
    unlisted: Boolean,
    existingIds: Array,
    templates: Object,
    publishedLocales: Array,
    sourceLocale: String,
    submittingMessage: String,
    successMessage: String,
    errorPrefix: String,
    changeLanguageWarning: String,
    idAvailableMessage: String,
    idCollisionMessage: String,
    idIncompleteMessage: String,
  }

  connect() {
    this.loadedLocale = this.localeTarget.value
    this.loadedMarkdown = this.rawMarkdownTarget.value
    this.loadedTemplateKind = this.hasEntryKindTarget ? this.entryKindTarget.value : null
    this._updateLocaleState(this.loadedLocale)
    if (this.unlistedValue) this.entryDetailsChanged()
  }

  async localeChanged() {
    if (this.unlistedValue) return

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

  entryDetailsChanged() {
    if (!this.unlistedValue) return

    const kind = this.entryKindTarget.value
    const isFunction = kind === "function"
    if (this.hasFunctionParentFieldTarget) this.functionParentFieldTarget.hidden = !isFunction
    if (this.hasFunctionLabelFieldTarget) this.functionLabelFieldTarget.hidden = !isFunction

    const previousTemplate = this.templatesValue[this.loadedTemplateKind] || ""
    const nextTemplate = this.templatesValue[kind] || ""
    if (kind !== this.loadedTemplateKind && this.rawMarkdownTarget.value === previousTemplate) {
      this.rawMarkdownTarget.value = nextTemplate
      this.loadedMarkdown = nextTemplate
    }
    this.loadedTemplateKind = kind

    const candidate = this._generatedEntryId()
    this.entryIdTarget.value = candidate
    const collision = candidate && this.existingIdsValue.includes(candidate)

    if (!candidate) {
      this.idStatusTarget.textContent = ""
    } else if (collision) {
      this.idStatusTarget.textContent = this.idCollisionMessageValue
    } else {
      this.idStatusTarget.textContent = `${this.idAvailableMessageValue}: ${candidate}`
    }

    this.submitTarget.disabled = !candidate || collision
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
    if (this.unlistedValue && !this._unlistedEntryValid()) {
      this._setStatus(`${this.errorPrefixValue}: ${this._unlistedEntryError()}`)
      return
    }

    this.previewEntryIdTarget.value = this._currentEntryId()
    this.previewLocaleTarget.value = this.localeTarget.value
    this.previewMarkdownTarget.value = this.rawMarkdownTarget.value
    if (this.unlistedValue) this._copyUnlistedPreviewFields()
    this.previewFormTarget.requestSubmit()
  }

  async submit(event) {
    event.preventDefault()

    if (!this.licenceTarget.checked) {
      this._setStatus(`${this.errorPrefixValue}: CC BY agreement is required`)
      return
    }
    if (this.unlistedValue && !this._unlistedEntryValid()) {
      this._setStatus(`${this.errorPrefixValue}: ${this._unlistedEntryError()}`)
      return
    }

    this.submitTarget.disabled = true
    this._setStatus(this.submittingMessageValue)
    this._setTicket("", "")

    try {
      const form = new FormData()
      form.append("kind", "grammar_entry_submission")
      form.append("source", "grammar_wiki")
      form.append("entry_id", this._currentEntryId())
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
      if (this.unlistedValue) this._appendUnlistedFields(form)
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
        entry_id: this._currentEntryId(),
      })
    } catch (error) {
      this._setStatus(`${this.errorPrefixValue}: ${error.message || error}`)
    } finally {
      this.submitTarget.disabled = this.unlistedValue && !this._unlistedEntryValid()
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

  _appendUnlistedFields(form) {
    form.append("unlisted_entry", "1")
    form.append("entry_kind", this.entryKindTarget.value)
    form.append("entry_headword", this.entryHeadwordTarget.value)
    form.append("entry_title", this.entryTitleTarget.value)
    form.append("entry_parent_id", this.entryParentTarget.value)
    form.append("entry_label", this.entryLabelTarget.value)
  }

  _copyUnlistedPreviewFields() {
    this.previewEntryKindTarget.value = this.entryKindTarget.value
    this.previewEntryHeadwordTarget.value = this.entryHeadwordTarget.value
    this.previewEntryTitleTarget.value = this.entryTitleTarget.value
    this.previewEntryParentTarget.value = this.entryParentTarget.value
    this.previewEntryLabelTarget.value = this.entryLabelTarget.value
  }

  _generatedEntryId() {
    const kind = this.entryKindTarget.value
    const headword = this.entryHeadwordTarget.value.trim()
    if (!headword) return ""

    if (kind === "function") {
      const parent = this.entryParentTarget.value.trim()
      const label = this.entryLabelTarget.value.trim()
      if (!parent || !label) return ""
      return `${parent}-${this._normaliseAscii(label) || this._tokenise(headword)}`
    }

    const prefixes = {
      function_word: "fw",
      pattern: "pattern",
      binome: "binome",
      comparison: "comparison",
      concept: "concept",
    }
    const token = this._tokenise(headword)
    return `${prefixes[kind] || kind}-${token || "entry"}`
  }

  _tokenise(value) {
    const tokens = value.match(/\p{Script=Han}|[A-Za-z0-9]+/gu) || []
    return tokens.map((token) => {
      if (/^\p{Script=Han}$/u.test(token)) return `u${token.codePointAt(0).toString(16)}`
      return this._normaliseAscii(token)
    }).filter(Boolean).join("-")
  }

  _normaliseAscii(value) {
    return value.toLowerCase()
      .replace(/[^\x00-\x7F]/g, " ")
      .replace(/[^a-z0-9]+/g, "-")
      .replace(/^-+|-+$/g, "")
  }

  _unlistedEntryValid() {
    const candidate = this._generatedEntryId()
    return Boolean(candidate) && !this.existingIdsValue.includes(candidate)
  }

  _unlistedEntryError() {
    const candidate = this._generatedEntryId()
    return candidate && this.existingIdsValue.includes(candidate)
      ? this.idCollisionMessageValue
      : this.idIncompleteMessageValue
  }

  _currentEntryId() {
    return this.unlistedValue ? this.entryIdTarget.value : this.entryIdValue
  }

  _ticketTitle() {
    const action = this.submissionActionTarget.value
    const labels = {
      create: "Grammar article",
      edit: "Grammar article edit",
      translate: "Grammar article translation",
    }
    return `${labels[action] || "Grammar submission"} — ${this._currentEntryId()}`
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
