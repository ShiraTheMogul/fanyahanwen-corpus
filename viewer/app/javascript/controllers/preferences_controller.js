import { Controller } from "@hotwired/stimulus"

// Handles the rightbar "Apply" without forcing a full reload when the only
// change is font-related. For other preference changes (ruby/conversion/etc.)
// we still reload so server-rendered content updates.
export default class extends Controller {
  static values = {
    currentMandarinScheme: String,
    currentCantoneseScheme: String,
    currentRubyEnabled: String,
    currentRubySource: String,
    currentRubyOrientation: String,
    currentRubySide: String,
    currentRubyToken: String,
    currentScriptMode: String,
    currentHanFont: String,
    currentHanFontScope: String,
    currentHanFontWarnMissing: String,
  }

  submit(event) {
    event.preventDefault()

    const form = this.element
    const fd = new FormData(form)

    const next = this._snapshotFromForm(form)
    const curr = this._snapshotFromValues()

    const needsReload = this._needsReload(curr, next)

    const csrf = document.querySelector('meta[name="csrf-token"]')?.getAttribute("content")

    fetch(form.action, {
      method: (form.method || "post").toUpperCase(),
      headers: {
        Accept: "application/json",
        ...(csrf ? { "X-CSRF-Token": csrf } : {}),
      },
      body: fd,
      credentials: "same-origin",
    })
      .then(async (res) => {
        if (!res.ok) throw new Error(`Preferences update failed (${res.status})`)
        return res.json()
      })
      .then((data) => {
        if (!data?.ok) return

				// Apply font changes instantly.
				if (data.han_font_stack) {
					document.documentElement.style.setProperty("--han-font-stack", data.han_font_stack)
					document.body.dataset.hanFontStack = data.han_font_stack
				}
				if (data.han_font_primary) {
					document.documentElement.style.setProperty("--han-font-primary", `"${data.han_font_primary}"`)
					document.body.dataset.hanFontPrimary = data.han_font_primary
				}

        // Scope class on <body>
        if (data.han_font_scope) {
          document.body.classList.remove("han-font-scope-all", "han-font-scope-headwords")
          document.body.classList.add(`han-font-scope-${data.han_font_scope}`)
          document.body.dataset.hanFontScope = data.han_font_scope
        }

        // For tooltip/headword warning logic.
        if (data.han_font_key) document.body.dataset.hanFontKey = data.han_font_key
        if (data.han_font_family) document.body.dataset.hanFontFamily = data.han_font_family
        if (typeof data.han_font_warn_missing !== "undefined") {
          document.body.dataset.hanFontWarnMissing = data.han_font_warn_missing ? "1" : "0"
        }

        // Let any glyph-guard widgets re-check against the new font.
        window.dispatchEvent(new CustomEvent("han-font-changed", { detail: data }))

        // Update our "current" snapshot so the next submit compares correctly.
        this._setValuesFromSnapshot(next)

        // Optional UI note.
        const msg = document.getElementById("han-font-message")
        if (msg) {
          msg.textContent = data.notice || ""
          msg.style.display = msg.textContent ? "block" : "none"
        }

        if (needsReload) {
          // Let the page re-render ruby / conversion / etc.
          window.location.href = fd.get("return_to") || window.location.href
        }
      })
      .catch((err) => {
        console.error(err)
      })
  }

  autosubmit() {
    // Debounced autosubmit for end users: changing an option applies it without
    // needing to click "Apply". Font-only changes stay client-side; server
    // dependent changes will reload (see _needsReload).
    clearTimeout(this._autosubmitTimer)
    this._autosubmitTimer = setTimeout(() => {
      // requestSubmit triggers our submit handler.
      if (this.element?.requestSubmit) this.element.requestSubmit()
    }, 200)
  }

  _needsReload(curr, next) {
    // Some preferences change server-rendered HTML (ruby wrapping, script conversion).
    // If the change does not affect the current view, we can avoid a reload.

    const forceServerKeys = [
      "mandarin_scheme",
      "cantonese_scheme",
      "script_mode",
      // "Show all ruby" toggles whether the page is pre-wrapped in <ruby>.
      "ruby_enabled",
    ]

    if (forceServerKeys.some((k) => (curr[k] || "") !== (next[k] || ""))) return true

    const showAllNext = (next.ruby_enabled || "0") === "1"

    // Ruby sub-options only need a reload when "Show all ruby" is ON,
    // because that's when the page is actually pre-wrapped in ruby markup.
    if (showAllNext) {
      const rubyKeys = ["ruby_source", "ruby_orientation", "ruby_side", "ruby_token"]
      if (rubyKeys.some((k) => (curr[k] || "") !== (next[k] || ""))) return true
    }

    return false
  }

  _snapshotFromValues() {
    return {
      mandarin_scheme: this.currentMandarinSchemeValue || "",
      cantonese_scheme: this.currentCantoneseSchemeValue || "",
      ruby_enabled: this.currentRubyEnabledValue || "0",
      ruby_source: this.currentRubySourceValue || "",
      ruby_orientation: this.currentRubyOrientationValue || "",
      ruby_side: this.currentRubySideValue || "",
      ruby_token: this.currentRubyTokenValue || "",
      script_mode: this.currentScriptModeValue || "",
      han_font: this.currentHanFontValue || "",
      han_font_scope: this.currentHanFontScopeValue || "all",
      han_font_warn_missing: this.currentHanFontWarnMissingValue || "1",
    }
  }

  _snapshotFromForm(form) {
    const get = (name) => {
      const el = form.querySelector(`[name="${CSS.escape(name)}"]`)
      if (!el) return ""

      if (el.type === "checkbox") {
        return el.checked ? "1" : "0"
      }

      return (el.value || "").toString()
    }

    return {
      mandarin_scheme: get("mandarin_scheme"),
      cantonese_scheme: get("cantonese_scheme"),
      ruby_enabled: get("ruby_enabled"),
      ruby_source: get("ruby_source"),
      ruby_orientation: get("ruby_orientation"),
      ruby_side: get("ruby_side"),
      ruby_token: get("ruby_token"),
      script_mode: get("script_mode"),
      han_font: get("han_font"),
      han_font_scope: get("han_font_scope"),
      han_font_warn_missing: get("han_font_warn_missing"),
    }
  }

  _setValuesFromSnapshot(s) {
    this.currentMandarinSchemeValue = s.mandarin_scheme
    this.currentCantoneseSchemeValue = s.cantonese_scheme
    this.currentRubyEnabledValue = s.ruby_enabled
    this.currentRubySourceValue = s.ruby_source
    this.currentRubyOrientationValue = s.ruby_orientation
    this.currentRubySideValue = s.ruby_side
    this.currentRubyTokenValue = s.ruby_token
    this.currentScriptModeValue = s.script_mode
    this.currentHanFontValue = s.han_font
    this.currentHanFontScopeValue = s.han_font_scope
    this.currentHanFontWarnMissingValue = s.han_font_warn_missing
  }
}
