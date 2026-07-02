import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["button"]
  static values = { url: String, successLabel: String }

  async copy() {
    const value = this.urlValue || window.location.href

    try {
      await navigator.clipboard.writeText(value)
    } catch (_error) {
      const textarea = document.createElement("textarea")
      textarea.value = value
      textarea.setAttribute("readonly", "")
      textarea.style.position = "fixed"
      textarea.style.opacity = "0"
      document.body.appendChild(textarea)
      textarea.select()
      document.execCommand("copy")
      textarea.remove()
    }

    if (!this.hasButtonTarget) return

    const original = this.buttonTarget.textContent
    this.buttonTarget.textContent = this.successLabelValue || original
    window.setTimeout(() => { this.buttonTarget.textContent = original }, 1600)
  }
}
