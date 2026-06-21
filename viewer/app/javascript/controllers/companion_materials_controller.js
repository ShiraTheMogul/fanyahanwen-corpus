import { Controller } from "@hotwired/stimulus"

const STORAGE_KEY = "cv_hide_ai_companion_materials_v1"

export default class extends Controller {
  static targets = ["hideAi", "material"]
  static values = { sourceUrl: String, activeAi: Boolean }

  connect() {
    if (this.hasHideAiTarget) {
      try {
        this.hideAiTarget.checked = window.localStorage.getItem(STORAGE_KEY) === "1"
      } catch (_error) {
        this.hideAiTarget.checked = false
      }
    }
    this._apply()
  }

  toggleAi() {
    const hide = this.hasHideAiTarget && this.hideAiTarget.checked
    try {
      window.localStorage.setItem(STORAGE_KEY, hide ? "1" : "0")
    } catch (_error) {}
    this._apply()
  }

  _apply() {
    const hide = this.hasHideAiTarget && this.hideAiTarget.checked
    let activeAiMaterial = this.hasActiveAiValue && this.activeAiValue

    for (const material of this.materialTargets) {
      const isAiAssisted = material.dataset.aiAssisted === "true"
      material.hidden = hide && isAiAssisted
      if (hide && isAiAssisted && material.dataset.active === "true") activeAiMaterial = true
    }

    if (activeAiMaterial && this.hasSourceUrlValue && window.location.href !== this.sourceUrlValue) {
      window.location.replace(this.sourceUrlValue)
    }
  }
}
