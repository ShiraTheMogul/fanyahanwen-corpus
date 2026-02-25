import { Controller } from "@hotwired/stimulus"

// Rightbar toggles for the corpus viewer.
//
// This controller lives in the <aside> rightbar, while the reader itself
// lives in the main column. Because they are siblings in the layout,
// we communicate via localStorage + a CustomEvent on window.

// This may be bad for speed idk
export default class extends Controller {
  static targets = ["theme", "vertical", "vflow", "fontsize", "strip", "rubyOnDemand", "jpRepeatParticle"]

  connect() {
    this._syncFromStorage()

    // Keep the rightbar checkboxes in sync if the toolbar buttons are used.
    this._onOptions = (ev) => {
      if (!ev?.detail) return
      this._setChecks(ev.detail)
    }
    window.addEventListener("corpus-view-options", this._onOptions)
  }

  disconnect() {
    window.removeEventListener("corpus-view-options", this._onOptions)
  }

  change() {
    const state = {
      theme: this.themeTarget.value,
      vertical: this.verticalTarget.checked,
      vflow: this.vflowTarget.value,
      fontSizePx: (this.fontsizeTarget.value || "").toString(),
      strip: this.stripTarget.checked,
      rubyOnDemand: this.rubyOnDemandTarget.checked,
      jpRepeatParticle: this.hasJpRepeatParticleTarget ? this.jpRepeatParticleTarget.checked : undefined,
    }

    window.localStorage.setItem("corpus.vertical", state.vertical ? "1" : "0")
    window.localStorage.setItem("corpus.verticalFlow", (state.vflow || "rl").toString())
    window.localStorage.setItem("corpus.theme", (state.theme || "bamboo").toString())
    window.localStorage.setItem("corpus.stripPunct", state.strip ? "1" : "0")
    window.localStorage.setItem("corpus.rubyOnDemand", state.rubyOnDemand ? "1" : "0")
    if (typeof state.jpRepeatParticle !== "undefined") {
      window.localStorage.setItem("corpus.jpRepeatParticle", state.jpRepeatParticle ? "1" : "0")
    }
    if (state.fontSizePx !== "") window.localStorage.setItem("corpus.fontSizePx", state.fontSizePx)

    window.dispatchEvent(new CustomEvent("corpus-view-options", { detail: state }))
  }

  _syncFromStorage() {
    const getBool = (k, fallback) => {
      const v = window.localStorage.getItem(k)
      if (v === null || v === undefined || v === "") return fallback
      return v === "1"
    }

    const theme = window.localStorage.getItem("corpus.theme") || "bamboo"
    const vflow = window.localStorage.getItem("corpus.verticalFlow") || "rl"
    const fz = window.localStorage.getItem("corpus.fontSizePx") || "20"

    this._setChecks({
      theme,
      vertical: getBool("corpus.vertical", false),
      vflow,
      fontSizePx: fz,
      strip: getBool("corpus.stripPunct", false),
      rubyOnDemand: getBool("corpus.rubyOnDemand", false),
      jpRepeatParticle: getBool("corpus.jpRepeatParticle", false),
    })
  }

  _setChecks(state) {
    if (typeof state.theme !== "undefined") this.themeTarget.value = (state.theme || "bamboo").toString()
    if (typeof state.vertical !== "undefined") this.verticalTarget.checked = !!state.vertical
    if (typeof state.vflow !== "undefined") this.vflowTarget.value = (state.vflow || "rl").toString()
    if (typeof state.fontSizePx !== "undefined") this.fontsizeTarget.value = (state.fontSizePx || "20").toString()
    if (typeof state.strip !== "undefined") this.stripTarget.checked = !!state.strip
    if (typeof state.rubyOnDemand !== "undefined") this.rubyOnDemandTarget.checked = !!state.rubyOnDemand
    if (this.hasJpRepeatParticleTarget && typeof state.jpRepeatParticle !== "undefined") {
      this.jpRepeatParticleTarget.checked = !!state.jpRepeatParticle
    }

    // UX: vertical flow only matters in vertical mode.
    if (this.hasVflowTarget) this.vflowTarget.disabled = !this.verticalTarget.checked
  }

  setSize(event) {
    const px = parseInt(event?.target?.dataset?.size || "", 10)
    if (!Number.isFinite(px)) return
    this.fontsizeTarget.value = px
    this.change()
  }
}
