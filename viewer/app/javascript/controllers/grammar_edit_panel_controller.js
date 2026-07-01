import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["panel"]

  connect() {
    if (!this.hasPanelTarget) return
    if (window.location.hash === `#${this.panelTarget.id}`) this.panelTarget.open = true
  }

  open(event) {
    event.preventDefault()
    if (!this.hasPanelTarget) return
    this.panelTarget.open = true
    window.history.replaceState(null, "", `#${this.panelTarget.id}`)
    this.panelTarget.scrollIntoView({ behavior: "smooth", block: "start" })
  }
}
