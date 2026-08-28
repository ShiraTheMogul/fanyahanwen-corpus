import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "mode",
    "modeButton",
    "exactPanel",
    "regexHint",
    "termsPanel",
    "exactInput",
    "multiTermInput",
    "proximityInput",
    "proximityHeading",
    "alternativesHeading",
    "alternativesHint",
    "proximityOptions",
    "termList",
    "termTemplate",
    "addTermButton",
    "folderChoice",
    "characterMatching",
    "characterHint"
  ]

  static values = {
    maxTerms: { type: Number, default: 10 },
    regexMaxLength: { type: Number, default: 1000 },
    termPlaceholder: String
  }

  connect() {
    this.characterMatchingBeforeRegex = null
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
    const selected = ["regex", "proximity", "alternatives"].includes(mode) ? mode : "exact"
    const exact = selected === "exact"
    const regex = selected === "regex"
    const single = exact || regex
    const proximity = selected === "proximity"
    const alternatives = selected === "alternatives"

    this.modeTarget.value = selected
    this.exactPanelTarget.hidden = !single
    if (this.hasRegexHintTarget) this.regexHintTarget.hidden = !regex
    this.termsPanelTarget.hidden = single
    this.proximityHeadingTarget.hidden = !proximity
    this.alternativesHeadingTarget.hidden = !alternatives
    this.alternativesHintTarget.hidden = !alternatives
    this.proximityOptionsTarget.hidden = !proximity

    this.exactInputTargets.forEach((input) => {
      input.disabled = !single
      input.maxLength = regex ? this.regexMaxLengthValue : 80
    })
    this.multiTermInputTargets.forEach((input) => { input.disabled = single })
    this.proximityInputTargets.forEach((input) => { input.disabled = !proximity })

    this.updateCharacterMatchingForMode(regex)

    this.modeButtonTargets.forEach((button) => {
      const active = button.dataset.mode === selected
      button.setAttribute("aria-pressed", active ? "true" : "false")
    })
  }

  updateCharacterMatchingForMode(regex) {
    if (!this.hasCharacterMatchingTarget) return

    const select = this.characterMatchingTarget
    if (regex) {
      if (select.value !== "exact" && this.characterMatchingBeforeRegex === null) {
        this.characterMatchingBeforeRegex = select.value
      }
      select.value = "exact"
      select.disabled = true
    } else {
      select.disabled = false
      if (this.characterMatchingBeforeRegex !== null) {
        select.value = this.characterMatchingBeforeRegex
        this.characterMatchingBeforeRegex = null
      }
    }

    this.updateCharacterHint()
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
