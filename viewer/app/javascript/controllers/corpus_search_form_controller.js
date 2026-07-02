import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "mode",
    "modeButton",
    "exactPanel",
    "proximityPanel",
    "exactInput",
    "proximityInput",
    "termList",
    "termTemplate",
    "addTermButton",
    "folderList",
    "folderTemplate"
  ]

  static values = {
    maxTerms: { type: Number, default: 10 },
    termPlaceholder: String,
    folderPathLabel: String
  }

  connect() {
    this.applyMode(this.modeTarget.value || "exact")
    this.renumberTerms()
    this.renumberFolders()
  }

  selectMode(event) {
    this.applyMode(event.currentTarget.dataset.mode || "exact")
  }

  addTerm() {
    if (this.termRows.length >= this.maxTermsValue) return

    this.termListTarget.append(this.termTemplateTarget.content.cloneNode(true))
    this.renumberTerms()
    this.applyMode(this.modeTarget.value)

    const lastInput = this.termRows.at(-1)?.querySelector("[data-corpus-search-term-input]")
    lastInput?.focus()
  }

  removeTerm(event) {
    if (this.termRows.length <= 2) return

    event.currentTarget.closest("[data-corpus-search-term-row]")?.remove()
    this.renumberTerms()
  }

  addFolder() {
    this.folderListTarget.append(this.folderTemplateTarget.content.cloneNode(true))
    this.renumberFolders()

    const lastInput = this.folderRows.at(-1)?.querySelector("[data-corpus-search-folder-path]")
    lastInput?.focus()
  }

  removeFolder(event) {
    const row = event.currentTarget.closest("[data-corpus-search-folder-row]")
    row?.remove()

    if (this.folderRows.length === 0) {
      this.folderListTarget.append(this.folderTemplateTarget.content.cloneNode(true))
    }

    this.renumberFolders()
  }

  applyMode(mode) {
    const selected = mode === "proximity" ? "proximity" : "exact"
    this.modeTarget.value = selected

    this.exactPanelTarget.hidden = selected !== "exact"
    this.proximityPanelTarget.hidden = selected !== "proximity"

    this.exactInputTargets.forEach((input) => { input.disabled = selected !== "exact" })
    this.proximityInputTargets.forEach((input) => { input.disabled = selected !== "proximity" })

    this.modeButtonTargets.forEach((button) => {
      const active = button.dataset.mode === selected
      button.setAttribute("aria-pressed", active ? "true" : "false")
    })
  }

  renumberTerms() {
    const rows = this.termRows

    rows.forEach((row, index) => {
      const number = index + 1
      const numberElement = row.querySelector(".corpus-search-term-number")
      const input = row.querySelector("[data-corpus-search-term-input]")
      const removeButton = row.querySelector("[data-action~='corpus-search-form#removeTerm']")

      if (numberElement) numberElement.textContent = number
      if (input) input.placeholder = this.numberedText(this.termPlaceholderValue, number)
      if (removeButton) removeButton.hidden = rows.length <= 2
    })

    if (this.hasAddTermButtonTarget) {
      this.addTermButtonTarget.disabled = rows.length >= this.maxTermsValue
    }
  }

  renumberFolders() {
    this.folderRows.forEach((row, index) => {
      const pathInput = row.querySelector("[data-corpus-search-folder-path]")
      const excludeInput = row.querySelector("[data-corpus-search-folder-exclude]")
      const hiddenLabel = row.querySelector(".corpus-search-visually-hidden")
      const number = index + 1

      if (pathInput) pathInput.name = `folder_rules[${index}][path]`
      if (excludeInput) excludeInput.name = `folder_rules[${index}][exclude]`
      if (hiddenLabel) hiddenLabel.textContent = this.numberedText(this.folderPathLabelValue, number)
    })
  }

  numberedText(template, number) {
    return (template || "").replace("__NUMBER__", number)
  }

  get termRows() {
    return Array.from(this.termListTarget.querySelectorAll("[data-corpus-search-term-row]"))
  }

  get folderRows() {
    return Array.from(this.folderListTarget.querySelectorAll("[data-corpus-search-folder-row]"))
  }
}
