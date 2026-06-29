import { Controller } from "@hotwired/stimulus"
import { t } from "i18n"
import {
  appendMaterialMetadata,
  appendSubmissionExtras,
  downloadTicketKey,
  materialMetadataFrom,
  maybeStoreTicketOnDevice,
} from "controllers/ticket_submission_helpers"

const MATERIAL_TYPES = ["translation", "gallery_image", "exemplar_manuscript", "variant_text"]

export default class extends Controller {
  static targets = [
    "panel", "status", "ticketId", "ticketKey", "downloadKeyBtn", "copyKeyBtn",
    "storeOnDevice", "materialType", "materialTitle", "summary", "reasoning",
    "translationFields", "mediaFields", "variantFields", "languageSearch", "languageCode",
    "languageList", "translatorName", "bodyText", "relatedPath", "materialLinks", "materialFiles",
    "evidenceLinks", "uploads", "contactName", "contactEmail", "contactNotes",
    "materialNote", "references", "aiAssisted", "aiDetails", "authorProvided", "authorProvidedRow"
  ]

  static values = {
    source: String,
    basePath: String,
  }

  connect() {
    this._languages = null
    this.materialTypeChanged()
  }

  toggle() {
    if (!this.hasPanelTarget) return
    this.panelTarget.classList.toggle("hidden")
    if (!this.panelTarget.classList.contains("hidden")) this.materialTypeChanged()
  }

  openForType(event) {
    event?.preventDefault()

    const requestedType = String(event?.params?.materialType || "translation")
    const materialType = MATERIAL_TYPES.includes(requestedType) ? requestedType : "translation"

    if (this.hasMaterialTypeTarget) this.materialTypeTarget.value = materialType
    this.materialTypeChanged()

    if (!this.hasPanelTarget) return
    this.panelTarget.classList.remove("hidden")

    requestAnimationFrame(() => this._focusForType(materialType))
  }

  materialTypeChanged() {
    const type = this.hasMaterialTypeTarget ? this.materialTypeTarget.value : "translation"
    if (this.hasTranslationFieldsTarget) this.translationFieldsTarget.hidden = type !== "translation"
    if (this.hasMediaFieldsTarget) this.mediaFieldsTarget.hidden = !["gallery_image", "exemplar_manuscript"].includes(type)
    if (this.hasVariantFieldsTarget) this.variantFieldsTarget.hidden = type !== "variant_text"
    if (this.hasAuthorProvidedRowTarget) this.authorProvidedRowTarget.hidden = type !== "translation"
    if (type !== "translation" && this.hasAuthorProvidedTarget) this.authorProvidedTarget.checked = false
  }

  async loadLanguages() {
    if (this._languages) return

    try {
      const response = await fetch("/iso_639_3.json", { headers: { "Accept": "application/json" } })
      if (!response.ok) throw new Error(`HTTP ${response.status}`)
      this._languages = await response.json()
      this._renderLanguageOptions()
    } catch (error) {
      this._setStatus(t("companion_material.status.iso_load_error", { message: error.message || error }))
    }
  }

  languageChanged() {
    if (!this.hasLanguageSearchTarget || !this.hasLanguageCodeTarget) return
    const value = this.languageSearchTarget.value.trim()
    const bracketMatch = value.match(/\[([a-z]{3})\]\s*$/i)
    const directCode = value.match(/^[a-z]{3}$/i)
    const code = bracketMatch ? bracketMatch[1].toLowerCase() : (directCode ? directCode[0].toLowerCase() : "")
    this.languageCodeTarget.value = code
  }

  async submit(event) {
    event.preventDefault()

    const materialType = this.hasMaterialTypeTarget ? this.materialTypeTarget.value : ""
    if (!MATERIAL_TYPES.includes(materialType)) {
      this._setStatus(t("companion_material.status.invalid_type"))
      return
    }

    const metadata = materialMetadataFrom(this)
    if (!metadata.material_note) {
      this._setStatus(t("companion_material.status.material_note_required"))
      return
    }
    if (metadata.provenance.length === 0) {
      this._setStatus(t("companion_material.status.provenance_required"))
      return
    }
    if (metadata.ai_assisted && !metadata.ai_details) {
      this._setStatus(t("companion_material.status.ai_details_required"))
      return
    }

    this.languageChanged()
    if (materialType === "translation") {
      if (!this.hasLanguageCodeTarget || !this.languageCodeTarget.value) {
        this._setStatus(t("companion_material.status.language_required"))
        return
      }
      if (!this.hasBodyTextTarget || !this.bodyTextTarget.value.trim()) {
        this._setStatus(t("companion_material.status.translation_required"))
        return
      }
    }

    const form = new FormData()
    form.append("kind", "companion_material_submission")
    form.append("source", this.sourceValue || "corpus_viewer")
    form.append("base_path", this.basePathValue || "")
    form.append("material_type", materialType)
    form.append("material_title", this.hasMaterialTitleTarget ? this.materialTitleTarget.value : "")
    form.append("title", this._ticketTitle(materialType))
    form.append("summary", this.hasSummaryTarget ? this.summaryTarget.value : "")
    form.append("reasoning", this.hasReasoningTarget ? this.reasoningTarget.value : "")
    form.append("material_links", JSON.stringify(this._linesFrom(this.hasMaterialLinksTarget ? this.materialLinksTarget.value : "")))
    form.append("related_path", this.hasRelatedPathTarget ? this.relatedPathTarget.value : "")
    form.append("language_code", this.hasLanguageCodeTarget ? this.languageCodeTarget.value : "")
    form.append("translator_name", this.hasTranslatorNameTarget ? this.translatorNameTarget.value : "")
    form.append("body_text", this.hasBodyTextTarget ? this.bodyTextTarget.value : "")

    appendMaterialMetadata(form, this)
    appendSubmissionExtras(form, this)

    if (this.hasMaterialFilesTarget) {
      for (const file of Array.from(this.materialFilesTarget.files || [])) {
        form.append("material_files[]", file)
      }
    }

    this._setStatus(t("companion_material.status.submitting"))
    this._setTicket("", "")

    try {
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
        this._setStatus(t("companion_material.status.error", { message }))
        return
      }

      const ticketId = data.ticket_id || data.ticket?.id || ""
      const ticketKey = data.ticket_key || ""
      this._setStatus(t("companion_material.status.created"))
      this._setTicket(ticketId, ticketKey)

      maybeStoreTicketOnDevice(this, ticketId, ticketKey, {
        title: this._ticketTitle(materialType),
        source: materialType,
      })
    } catch (error) {
      this._setStatus(t("companion_material.status.error", { message: error.message || error }))
    }
  }

  copyKey(event) {
    event.preventDefault()
    const key = this.hasTicketKeyTarget ? this.ticketKeyTarget.textContent : ""
    if (!key) return

    navigator.clipboard.writeText(key).then(() => {
      if (!this.hasCopyKeyBtnTarget) return
      const oldText = this.copyKeyBtnTarget.textContent
      this.copyKeyBtnTarget.textContent = t("companion_material.actions.copied")
      setTimeout(() => { this.copyKeyBtnTarget.textContent = oldText }, 1000)
    })
  }

  downloadKey(event) {
    event.preventDefault()
    downloadTicketKey(
      this.hasTicketIdTarget ? this.ticketIdTarget.textContent : "",
      this.hasTicketKeyTarget ? this.ticketKeyTarget.textContent : ""
    )
  }

  _renderLanguageOptions() {
    if (!this.hasLanguageListTarget || !Array.isArray(this._languages)) return
    const fragment = document.createDocumentFragment()

    for (const language of this._languages) {
      const option = document.createElement("option")
      option.value = `${language.name} [${language.code}]`
      fragment.appendChild(option)
    }

    this.languageListTarget.replaceChildren(fragment)
  }

  _focusForType(materialType) {
    const target = {
      translation: this.hasLanguageSearchTarget ? this.languageSearchTarget : null,
      gallery_image: this.hasMaterialFilesTarget ? this.materialFilesTarget : null,
      exemplar_manuscript: this.hasMaterialFilesTarget ? this.materialFilesTarget : null,
      variant_text: this.hasRelatedPathTarget ? this.relatedPathTarget : null,
    }[materialType]

    if (target && typeof target.focus === "function") target.focus()
  }

  _ticketTitle(materialType) {
    const labels = {
      translation: t("companion_material.titles.translation"),
      gallery_image: t("companion_material.titles.gallery_image"),
      exemplar_manuscript: t("companion_material.titles.exemplar_manuscript"),
      variant_text: t("companion_material.titles.variant_text"),
    }
    return labels[materialType] || t("companion_material.titles.default")
  }

  _linesFrom(value) {
    return String(value || "").split(/\r?\n/).map((line) => line.trim()).filter(Boolean)
  }

  _csrfToken() {
    const element = document.querySelector('meta[name="csrf-token"]')
    return element ? element.content : ""
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
