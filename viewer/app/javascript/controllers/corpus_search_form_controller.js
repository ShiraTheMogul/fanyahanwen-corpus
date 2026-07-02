import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["mode", "modeButton", "exactPanel", "proximityPanel", "exactInput", "proximityInput"]

  connect() {
    this.applyMode(this.modeTarget.value || "exact")
  }

  selectMode(event) {
    this.applyMode(event.currentTarget.dataset.mode || "exact")
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
}
