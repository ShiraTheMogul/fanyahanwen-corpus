import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["trigger", "panel"]

  connect() {
    this.setExpanded(false)
  }

  toggle() {
    this.setExpanded(!this.element.classList.contains("is-expanded"))
  }

  setExpanded(expanded) {
    this.element.classList.toggle("is-expanded", expanded)
    this.triggerTarget.setAttribute("aria-expanded", expanded ? "true" : "false")
    this.panelTarget.setAttribute("aria-hidden", expanded ? "false" : "true")
    this.panelTarget.inert = !expanded
  }
}
