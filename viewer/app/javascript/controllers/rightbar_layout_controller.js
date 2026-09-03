import { Controller } from "@hotwired/stimulus"

const MOBILE_QUERY = "(max-width: 980px)"

// Collapsible rightbar for the whole site.
// - Desktop keeps the existing remembered collapsed/expanded preference.
// - Mobile starts closed on each page load and opens as an overlay sheet.
// - Mobile open/closed state is deliberately not persisted, so a new page never
//   arrives with a large options sheet already covering the reading surface.
export default class extends Controller {
  static values = {
    storageKey: { type: String, default: "rightbar.collapsed" },
  }

  connect() {
    this._button = document.querySelector(".rightbar-toggle")
    this._aside = document.querySelector("aside.site-rightbar")

    if (this._button && !this._aside) this._button.style.display = "none"
    if (!this._aside) return

    this._desktopCollapsed = this._storedDesktopState()
    this._mobileQuery = window.matchMedia(MOBILE_QUERY)

    this._onViewportChange = () => this._applyResponsiveState()
    if (this._mobileQuery.addEventListener) {
      this._mobileQuery.addEventListener("change", this._onViewportChange)
    } else {
      this._mobileQuery.addListener(this._onViewportChange)
    }

    this._onResize = () => this._syncMobileTop()
    window.addEventListener("resize", this._onResize, { passive: true })

    this._onKeydown = (event) => {
      if (event.key !== "Escape" || !this._isMobile() || this._isCollapsed()) return
      event.preventDefault()
      this._setMobileOpen(false, { returnFocus: true })
    }
    window.addEventListener("keydown", this._onKeydown)

    this._ensureMobileBackdrop()
    this._applyResponsiveState()
  }

  disconnect() {
    if (this._mobileQuery && this._onViewportChange) {
      if (this._mobileQuery.removeEventListener) {
        this._mobileQuery.removeEventListener("change", this._onViewportChange)
      } else {
        this._mobileQuery.removeListener(this._onViewportChange)
      }
    }
    window.removeEventListener("resize", this._onResize)
    window.removeEventListener("keydown", this._onKeydown)

    this._backdrop?.remove()
    this._backdrop = null
    document.body.classList.remove("rightbar-mobile-open")
    document.documentElement.style.removeProperty("--rightbar-mobile-top")
  }

  toggle() {
    if (this._isMobile()) {
      this._setMobileOpen(this._isCollapsed())
      return
    }

    const collapsed = document.body.classList.toggle("rightbar-collapsed")
    this._desktopCollapsed = collapsed
    this._storeDesktopState(collapsed)
    this._syncButton(collapsed)
  }

  _storedDesktopState() {
    try {
      return window.localStorage.getItem(this.storageKeyValue) === "1"
    } catch (_) {
      return false
    }
  }

  _storeDesktopState(collapsed) {
    try {
      window.localStorage.setItem(this.storageKeyValue, collapsed ? "1" : "0")
    } catch (_) {}
  }

  _isMobile() {
    return this._mobileQuery?.matches === true
  }

  _isCollapsed() {
    return document.body.classList.contains("rightbar-collapsed")
  }

  _applyResponsiveState() {
    if (this._isMobile()) {
      // Mobile is an explicit click-to-open sheet. Always enter mobile mode
      // closed, even if the desktop rightbar was left expanded.
      this._setMobileOpen(false)
      this._syncMobileTop()
      return
    }

    document.body.classList.remove("rightbar-mobile-open")
    this._setCollapsed(this._desktopCollapsed)
  }

  _setMobileOpen(open, { returnFocus = false } = {}) {
    const collapsed = !open
    this._setCollapsed(collapsed)
    document.body.classList.toggle("rightbar-mobile-open", open)
    this._syncMobileTop()

    if (open) {
      this._aside.setAttribute("tabindex", "-1")
      window.requestAnimationFrame(() => this._aside?.focus({ preventScroll: true }))
    } else {
      this._aside.removeAttribute("tabindex")
      if (returnFocus) this._button?.focus({ preventScroll: true })
    }
  }

  _setCollapsed(collapsed) {
    document.body.classList.toggle("rightbar-collapsed", collapsed)
    this._syncButton(collapsed)
  }

  _syncButton(collapsed) {
    if (this._button) this._button.setAttribute("aria-expanded", collapsed ? "false" : "true")
  }

  _syncMobileTop() {
    if (!this._isMobile()) {
      document.documentElement.style.removeProperty("--rightbar-mobile-top")
      return
    }

    const header = document.querySelector(".site-header")
    const bottom = header ? Math.max(0, Math.ceil(header.getBoundingClientRect().bottom)) : 0
    document.documentElement.style.setProperty("--rightbar-mobile-top", `${bottom}px`)
  }

  _ensureMobileBackdrop() {
    if (this._backdrop?.isConnected) return

    const backdrop = document.createElement("div")
    backdrop.className = "rightbar-mobile-backdrop"
    backdrop.setAttribute("aria-hidden", "true")
    backdrop.addEventListener("click", () => {
      if (!this._isMobile()) return
      this._setMobileOpen(false, { returnFocus: true })
    })

    document.body.appendChild(backdrop)
    this._backdrop = backdrop
  }
}
