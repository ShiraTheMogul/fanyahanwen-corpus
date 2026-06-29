import { Controller } from "@hotwired/stimulus"
import { t } from "i18n"

// Click-to-move + highlighting for the Xiangqi board.
// Client-side logic only handles UI. All legality comes from the server.

export default class extends Controller {
  static targets = ["prettyWrap", "pretty", "overlay", "gridWrap", "moveForm", "moveInput", "hint"]
  static values = { theme: String, side: String }

  connect() {
    this._selected = null
    this._legal = new Map() // key "x,y" -> { capture: boolean }

    // Build overlay squares for the pretty board so it is clickable.
    this._ensureOverlaySquares()

    // Apply theme from server/session and mark palace squares.
    this._applyTheme(this.themeValue || "colour")
    this._applyPalaceMarks()
    this._syncOverlayGeometry()

    this._onResize = () => this._syncOverlayGeometry()
    window.addEventListener("resize", this._onResize)
  }

  disconnect() {
    window.removeEventListener("resize", this._onResize)
  }

  pickTheme(ev) {
    const theme = ev.currentTarget?.dataset?.theme
    if (!theme) return
    this.themeValue = theme
    this._applyTheme(theme)
    this._persistTheme(theme)
  }

  copy(ev) {
    const text = ev.currentTarget?.dataset?.copyText || ""
    if (!text) return
    this._copyToClipboard(text)
  }

  async _copyToClipboard(text) {
    try {
      await navigator.clipboard.writeText(text)
      this._setHint(t("fun.xiangqi.copied"))
      window.setTimeout(() => this._setHint(""), 800)
    } catch (_) {
      // Fallback: place text in the move input for manual copy.
      if (this.hasMoveInputTarget) {
        this.moveInputTarget.value = text
        this.moveInputTarget.focus()
        this.moveInputTarget.select()
        this._setHint(t("fun.xiangqi.clipboard_blocked"))
      }
    }
  }

  _persistTheme(theme) {
    try {
      const tokenEl = document.querySelector('meta[name="csrf-token"]')
      const token = tokenEl ? tokenEl.getAttribute("content") : ""
      fetch("/xiangqi/theme", {
        method: "POST",
        headers: {
          "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
          "X-CSRF-Token": token,
          "X-Requested-With": "XMLHttpRequest",
        },
        body: `theme=${encodeURIComponent(theme)}`,
        credentials: "same-origin",
      }).catch(() => {})
    } catch (_) {}
  }

  _applyTheme(theme) {
    // Toolbar active state
    this.element.querySelectorAll("[data-theme]").forEach((btn) => {
      btn.classList.toggle("is-active", btn.dataset.theme === theme)
    })

    // Swap views
    if (this.hasPrettyWrapTarget) this.prettyWrapTarget.classList.toggle("is-hidden", theme === "grid")
    if (this.hasGridWrapTarget) this.gridWrapTarget.classList.toggle("is-hidden", theme !== "grid")

    // Swap pretty font
    if (this.hasPrettyTarget) {
      this.prettyTarget.classList.toggle("theme-colour", theme === "colour")
      this.prettyTarget.classList.toggle("theme-mono", theme === "mono")
    }

    // Clear selection when theme changes to avoid confusion.
    this._clearSelection()
    this._syncOverlayGeometry()
  }

  // Works for BOTH overlay squares (pretty) and grid buttons (fallback).
  squareClick(ev) {
    const el = ev.currentTarget
    const x = parseInt(el.dataset.x, 10)
    const y = parseInt(el.dataset.y, 10)
    if (!Number.isFinite(x) || !Number.isFinite(y)) return

    // If we have a selection and the clicked square is legal: play it.
    if (this._selected) {
      const key = this._key(x, y)
      if (this._legal.has(key)) {
        this._submitMove(this._selected.x, this._selected.y, x, y)
        return
      }

      // Clicking the selected square toggles off.
      if (this._selected.x === x && this._selected.y === y) {
        this._clearSelection()
        return
      }
    }

    // Otherwise: attempt to select.
    this._selectSquare(x, y)
  }

  async _selectSquare(x, y) {
    this._clearSelection()

    try {
      const url = `/xiangqi/legal_moves?fx=${encodeURIComponent(x)}&fy=${encodeURIComponent(y)}`
      const res = await fetch(url, { headers: { "Accept": "application/json" } })
      const data = await res.json()

      if (!data?.ok) {
        this._setHint(data?.error || t("fun.xiangqi.not_selectable"))
        return
      }

      this._selected = { x: data.fx, y: data.fy }
      this._setHint(t("fun.xiangqi.selected_piece", { piece: data.piece }))

      for (const m of (data.moves || [])) {
        this._legal.set(this._key(m.tx, m.ty), { capture: !!m.capture })
      }

      this._renderHighlights()
    } catch (_) {
      this._setHint(t("fun.xiangqi.legal_moves_failed"))
    }
  }

  _submitMove(fx, fy, tx, ty) {
    const files = ["a","b","c","d","e","f","g","h","i"]
    const mv = `${files[fx]}${fy}${files[tx]}${ty}`

    if (this.hasMoveInputTarget) this.moveInputTarget.value = mv
    if (this.hasMoveFormTarget) this.moveFormTarget.requestSubmit()
  }

  _clearSelection() {
    this._selected = null
    this._legal.clear()
    this._renderHighlights()
  }

  _renderHighlights() {
    // Overlay squares + grid buttons both have data-x/y.
    this.element.querySelectorAll("[data-x][data-y]").forEach((el) => {
      const x = parseInt(el.dataset.x, 10)
      const y = parseInt(el.dataset.y, 10)
      if (!Number.isFinite(x) || !Number.isFinite(y)) return

      el.classList.toggle("is-selected", !!this._selected && this._selected.x === x && this._selected.y === y)

      const meta = this._legal.get(this._key(x, y))
      el.classList.toggle("is-legal", !!meta)
      el.classList.toggle("is-capture", !!meta && !!meta.capture)
    })
  }

  _applyPalaceMarks() {
    const inPalace = (x, y) => {
      if (x < 3 || x > 5) return false
      return (y >= 0 && y <= 2) || (y >= 7 && y <= 9)
    }

    this.element.querySelectorAll("[data-x][data-y]").forEach((el) => {
      const x = parseInt(el.dataset.x, 10)
      const y = parseInt(el.dataset.y, 10)
      if (!Number.isFinite(x) || !Number.isFinite(y)) return
      el.classList.toggle("is-palace", inPalace(x, y))
    })
  }

  _ensureOverlaySquares() {
    if (!this.hasOverlayTarget) return
    const overlay = this.overlayTarget

    // If already built, do nothing.
    if (overlay.querySelectorAll("[data-x][data-y]").length === 90) return

    overlay.innerHTML = ""
    for (let y = 9; y >= 0; y--) {
      for (let x = 0; x <= 8; x++) {
        const b = document.createElement("button")
        b.type = "button"
        b.className = "xq-square"
        b.dataset.x = String(x)
        b.dataset.y = String(y)
        b.setAttribute("aria-label", t("fun.xiangqi.square_aria", { x, y }))
        b.dataset.action = "click->xiangqi-board#squareClick"
        overlay.appendChild(b)
      }
    }
  }

  _syncOverlayGeometry() {
    if (!this.hasOverlayTarget || !this.hasPrettyTarget) return

    const overlay = this.overlayTarget
    const pre = this.prettyTarget

    const r = pre.getBoundingClientRect()
    const cs = window.getComputedStyle(pre)

    const padL = parseFloat(cs.paddingLeft) || 0
    const padR = parseFloat(cs.paddingRight) || 0
    const padT = parseFloat(cs.paddingTop) || 0
    const padB = parseFloat(cs.paddingBottom) || 0

    const borL = parseFloat(cs.borderLeftWidth) || 0
    const borR = parseFloat(cs.borderRightWidth) || 0
    const borT = parseFloat(cs.borderTopWidth) || 0
    const borB = parseFloat(cs.borderBottomWidth) || 0

    const contentW = Math.max(0, r.width - padL - padR - borL - borR)
    const contentH = Math.max(0, r.height - padT - padB - borT - borB)

    // Pretty board is 11 chars wide × 12 lines high.
    const charW = contentW / 11.0
    const charH = contentH / 12.0

    overlay.style.left = `${borL + padL + charW}px`
    const yAdjust = 4 // nudge down (glyph baseline / font metrics)
    overlay.style.top = `${borT + padT + charH + yAdjust}px`
    overlay.style.width = `${charW * 9}px`
    overlay.style.height = `${charH * 10}px`
  }

  _key(x, y) { return `${x},${y}` }

  _setHint(msg) {
    if (!this.hasHintTarget) return
    this.hintTarget.textContent = msg
  }
}
