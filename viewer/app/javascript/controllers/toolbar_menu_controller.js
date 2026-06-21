import { Controller } from "@hotwired/stimulus"

// Small toolbar dropdowns should behave like the viewer's ordinary buttons,
// not like browser-styled <details>/<summary> controls.
export default class extends Controller {
  static targets = ["button", "menu"]

  connect() {
    this._onDocumentClick = this._onDocumentClick.bind(this)
    this._onDocumentKeydown = this._onDocumentKeydown.bind(this)

    document.addEventListener("click", this._onDocumentClick)
    document.addEventListener("keydown", this._onDocumentKeydown)
    this._setOpen(false)
  }

  disconnect() {
    document.removeEventListener("click", this._onDocumentClick)
    document.removeEventListener("keydown", this._onDocumentKeydown)
  }

  toggle(event) {
    event.preventDefault()
    event.stopPropagation()

    const shouldOpen = this.hasMenuTarget && this.menuTarget.hidden
    this._closeOtherMenus()
    this._setOpen(shouldOpen)
  }

  close() {
    this._setOpen(false)
  }

  _setOpen(open) {
    if (this.hasMenuTarget) this.menuTarget.hidden = !open
    if (this.hasButtonTarget) this.buttonTarget.setAttribute("aria-expanded", open ? "true" : "false")
  }

  _closeOtherMenus() {
    for (const menu of document.querySelectorAll('[data-toolbar-menu-target="menu"]:not([hidden])')) {
      if (this.hasMenuTarget && menu === this.menuTarget) continue

      menu.hidden = true
      const owner = menu.closest('[data-controller~="toolbar-menu"]')
      const button = owner?.querySelector('[data-toolbar-menu-target="button"]')
      if (button) button.setAttribute("aria-expanded", "false")
    }
  }

  _onDocumentClick(event) {
    if (!this.element.contains(event.target)) this.close()
  }

  _onDocumentKeydown(event) {
    if (event.key !== "Escape" || !this.hasMenuTarget || this.menuTarget.hidden) return

    this.close()
    if (this.hasButtonTarget) this.buttonTarget.focus()
  }
}
