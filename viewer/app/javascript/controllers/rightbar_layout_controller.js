import { Controller } from "@hotwired/stimulus"

// Collapsible rightbar for the whole site.
// - Adds/removes a body class.
// - Remembers state in localStorage.
//
// This is intentionally simple and non-invasive: if a page has no rightbar
// content, toggling has no visible effect.
export default class extends Controller {
  static values = {
    storageKey: { type: String, default: "rightbar.collapsed" },
  }

  connect() {
    try {
      const raw = window.localStorage.getItem(this.storageKeyValue)
      const collapsed = raw === "1"
      this._setCollapsed(collapsed)
    } catch (_) {
      // If localStorage is blocked, just default to expanded.
      this._setCollapsed(false)
    }

    // Hide the toggle button if the layout has no rightbar slot.
    const btn = document.querySelector(".rightbar-toggle")
    const aside = document.querySelector("aside.site-rightbar")
    if (btn && !aside) btn.style.display = "none"
  }

  toggle() {
    const collapsed = document.body.classList.toggle("rightbar-collapsed")
    try {
      window.localStorage.setItem(this.storageKeyValue, collapsed ? "1" : "0")
    } catch (_) {
      // noop
    }

    const btn = document.querySelector(".rightbar-toggle")
    if (btn) btn.setAttribute("aria-expanded", collapsed ? "false" : "true")
  }

  _setCollapsed(collapsed) {
    document.body.classList.toggle("rightbar-collapsed", collapsed)
    const btn = document.querySelector(".rightbar-toggle")
    if (btn) btn.setAttribute("aria-expanded", collapsed ? "false" : "true")
  }
}
