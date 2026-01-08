import { Controller } from "@hotwired/stimulus"

// Remembers which pronunciation sub-sections the user has expanded/collapsed.
// Uses cookies (same-origin, no server changes required).
export default class extends Controller {
  connect() {
    this._details = Array.from(this.element.querySelectorAll("details[data-pref-key]"))
    this._details.forEach((d) => this._applyInitialState(d))
    this._details.forEach((d) => d.addEventListener("toggle", () => this._persist(d)))
  }

  _applyInitialState(details) {
    const key = details.dataset.prefKey
    const defaultOpen = (details.dataset.defaultOpen || "0") === "1"
    const v = this._getCookie(key)

    if (v === null) {
      details.open = defaultOpen
      return
    }

    details.open = v === "1"
  }

  _persist(details) {
    const key = details.dataset.prefKey
    this._setCookie(key, details.open ? "1" : "0", 3650) // ~10 years
  }

  _getCookie(name) {
    const cookies = document.cookie ? document.cookie.split(";") : []
    for (const c of cookies) {
      const [k, ...rest] = c.split("=")
      if (!k) continue
      if (k.trim() === name) return decodeURIComponent(rest.join("=").trim())
    }
    return null
  }

  _setCookie(name, value, days) {
    const maxAge = Math.floor(days * 24 * 60 * 60)
    document.cookie = `${name}=${encodeURIComponent(value)}; Max-Age=${maxAge}; Path=/; SameSite=Lax`
  }
}
