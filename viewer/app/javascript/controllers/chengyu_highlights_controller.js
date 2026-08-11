import { Controller } from "@hotwired/stimulus"

// Reader-only display preference for exploratory Chengyu usage marking.
// Confirmed source-context marks are always visible; this controller only
// toggles the broader "known form occurs here" aqua layer.
export default class extends Controller {
  static targets = ["toggle"]

  connect() {
    this.enabled = window.localStorage.getItem("corpus.highlightChengyuUsages") === "1"
    this.toggleTarget.checked = this.enabled

    this._onReaderRefresh = () => this.apply()
    window.addEventListener("corpus-reader-refresh", this._onReaderRefresh)
    this.apply()
  }

  disconnect() {
    window.removeEventListener("corpus-reader-refresh", this._onReaderRefresh)
  }

  change() {
    this.enabled = !!this.toggleTarget.checked
    window.localStorage.setItem("corpus.highlightChengyuUsages", this.enabled ? "1" : "0")
    this.apply()
  }

  apply() {
    document.querySelectorAll(".corpus-textflow").forEach((element) => {
      element.classList.toggle("show-chengyu-usages", this.enabled)
    })
  }
}
