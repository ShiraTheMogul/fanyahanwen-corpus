import { Controller } from "@hotwired/stimulus"

const SHELF_KEY = "fanya-word-processor-shelf"

// Adds a dictionary character to the Word Processor's local shelf. Dictionary
// entries are tagged so the Writer can pass them through the active character
// standard at insertion time. Manually pinned Writer text remains literal.
export default class extends Controller {
  static targets = ["status"]
  static values = { text: String, codepoint: String, successMessage: String, errorMessage: String }

  add(event) {
    event?.preventDefault()
    const text = (this.textValue || "").trim()
    if (!text) return

    let shelf = []
    try {
      const parsed = JSON.parse(window.localStorage.getItem(SHELF_KEY) || "[]")
      shelf = Array.isArray(parsed) ? parsed : []
    } catch (_error) {
      shelf = []
    }

    const entry = {
      text,
      source: "dictionary",
      codepoint: (this.codepointValue || "").trim(),
    }

    const sameEntry = (item) => {
      if (typeof item === "string") return false
      return item && item.source === "dictionary" && item.text === text
    }
    shelf = [entry, ...shelf.filter((item) => !sameEntry(item))].slice(0, 100)

    try {
      window.localStorage.setItem(SHELF_KEY, JSON.stringify(shelf))
      if (this.hasStatusTarget) this.statusTarget.textContent = this.successMessageValue || "Added to Word Processor shelf."
    } catch (_error) {
      if (this.hasStatusTarget) this.statusTarget.textContent = this.errorMessageValue || "Could not save the shelf on this device."
    }
  }
}
