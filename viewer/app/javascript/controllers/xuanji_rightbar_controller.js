import { Controller } from "@hotwired/stimulus"

// Rightbar toggles specific to the Xuanji Tu page.
//
// We intentionally keep this minimal:
// - The Xuanji output is rendered inside a <div data-controller="corpus-reader">.
// - corpus-reader already supports punctuation stripping via the shared state key:
//     localStorage["corpus.stripPunct"]
//   and via the window event:
//     "corpus-view-options"
//
// This controller simply lets the user toggle that option from the Xuanji rightbar
// without pulling in the full corpus viewer rightbar UI.
export default class extends Controller {
  static targets = ["strip"]

  connect() {
    this._syncFromStorage()

    this._onOptions = (ev) => {
      if (!ev?.detail) return
      if (typeof ev.detail.strip !== "undefined") {
        this.stripTarget.checked = !!ev.detail.strip
      }
    }
    window.addEventListener("corpus-view-options", this._onOptions)
  }

  disconnect() {
    window.removeEventListener("corpus-view-options", this._onOptions)
  }

  change() {
    const strip = !!this.stripTarget.checked
    window.localStorage.setItem("corpus.stripPunct", strip ? "1" : "0")

    // Notify any corpus-reader instances on the page.
    window.dispatchEvent(new CustomEvent("corpus-view-options", { detail: { strip } }))
  }

  _syncFromStorage() {
    const v = window.localStorage.getItem("corpus.stripPunct")
    this.stripTarget.checked = (v === "1")
  }
}
