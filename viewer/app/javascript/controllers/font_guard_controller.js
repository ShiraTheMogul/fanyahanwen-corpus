import { Controller } from "@hotwired/stimulus"

// Best-effort "does the current selected Han font cover this glyph?" check.
// If not, we force WenJin Mincho for this element and show a short warning.
export default class extends Controller {
  static values = {
    char: String,
  }

  connect() {
    // Wait for fonts to be ready before checking.
    if (document.fonts && document.fonts.ready) {
      document.fonts.ready.then(() => this._check()).catch(() => this._check())
    } else {
      this._check()
    }
  }

  _warnEnabled() {
    const v = document.body?.dataset?.hanFontWarnMissing
    return v === "1" || v === "true"
  }

  _selectedFamily() {
    // Prefer the explicit var, fall back to body dataset.
    const root = document.documentElement
    const css = getComputedStyle(root).getPropertyValue("--han-font-primary").trim()
    const unquoted = css.replace(/^"/, "").replace(/"$/, "")
    return unquoted || (document.body?.dataset?.hanFontFamily || "")
  }

  _fallbackFamily() {
    return "WenJin Mincho"
  }

  _check() {
    if (!this._warnEnabled()) return

    const ch = (this.charValue || "").trim()
    if (!ch) return

    const fam = this._selectedFamily()
    if (!fam || fam.toLowerCase().includes("wenjin")) return

    const run = () => {
      // If the font isn't loaded, check can throw in some browsers; be defensive.
      let ok = true
      try {
        ok = document.fonts && document.fonts.check
          ? document.fonts.check(`16px "${fam}"`, ch)
          : true
      } catch (_) {
        ok = true
      }

      if (ok) return

      // Force fallback for this specific element.
      this.element.style.fontFamily = `"${this._fallbackFamily()}", serif`

      // Show a warning near the headword.
      const msg = `Primary font ${fam} does not include this character; falling back to WenJin Mincho.`
      const existing = this.element.parentElement?.querySelector(".han-font-warning")
      if (existing) {
        existing.textContent = msg
        return
      }

      const note = document.createElement("div")
      note.className = "han-font-warning"
      note.textContent = msg
      this.element.insertAdjacentElement("afterend", note)
    }

    // Try to load the specific glyph first to avoid false negatives.
    if (document.fonts?.load) {
      document.fonts.load(`16px "${fam}"`, ch).then(run).catch(run)
    } else {
      run()
    }
  }

}
