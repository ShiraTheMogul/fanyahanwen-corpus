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
    "folderChoice",
    "characterMatching",
    "characterHint"
  ]

  static values = {
    maxTerms: { type: Number, default: 10 },
    termPlaceholder: String
  }

  connect() {
    this.applyMode(this.modeTarget.value || "exact")
    this.renumberTerms()
    this.updateCharacterHint()
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

  selectFolder(event) {
    const selected = event.currentTarget
    if (!selected.checked) return

    const path = selected.dataset.corpusFolderPath
    const scope = selected.dataset.corpusFolderScope

    this.folderChoiceTargets.forEach((choice) => {
      if (choice === selected) return
      if (choice.dataset.corpusFolderPath !== path) return
      if (choice.dataset.corpusFolderScope === scope) return

      choice.checked = false
    })
  }

  toggleFolderBranch(event) {
    const button = event.currentTarget
    const node = button.closest("[data-corpus-search-folder-node]")
    const branch = Array.from(node?.children || []).find((child) => {
      return child.hasAttribute("data-corpus-search-folder-children")
    })
    if (!branch) return

    const expanded = button.getAttribute("aria-expanded") === "true"
    button.setAttribute("aria-expanded", expanded ? "false" : "true")
    node?.setAttribute("aria-expanded", expanded ? "false" : "true")
    branch.hidden = expanded
  }


  updateCharacterHint() {
    if (!this.hasCharacterMatchingTarget || !this.hasCharacterHintTarget) return

    const selected = this.characterMatchingTarget.selectedOptions[0]
    this.characterHintTarget.textContent = selected?.dataset.hint || ""
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

  numberedText(template, number) {
    return (template || "").replace("__NUMBER__", number)
  }

  get termRows() {
    return Array.from(this.termListTarget.querySelectorAll("[data-corpus-search-term-row]"))
  }
}
