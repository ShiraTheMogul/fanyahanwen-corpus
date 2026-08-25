import { Controller } from "@hotwired/stimulus"

// Handles reader/dictionary preferences without forcing a full reload when the
// changed preference can be applied in the browser. Server-rendered changes
// (ruby wrapping and script conversion) still reload the current page.
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

        if (data.han_font_scope) {
          document.body.classList.remove("han-font-scope-all", "han-font-scope-headwords")
          document.body.classList.add(`han-font-scope-${data.han_font_scope}`)
          document.body.dataset.hanFontScope = data.han_font_scope
        }

        if (data.han_font_key) document.body.dataset.hanFontKey = data.han_font_key
        if (data.han_font_family) document.body.dataset.hanFontFamily = data.han_font_family
        if (typeof data.han_font_warn_missing !== "undefined") {
          document.body.dataset.hanFontWarnMissing = data.han_font_warn_missing ? "1" : "0"
        }

        window.dispatchEvent(new CustomEvent("han-font-changed", { detail: data }))

        this._setValuesFromSnapshot(next)

        const msg = document.getElementById("han-font-message")
        if (msg) {
          msg.textContent = data.notice || ""
          msg.style.display = msg.textContent ? "block" : "none"
        }

        if (needsReload) {
          window.location.href = fd.get("return_to") || window.location.href
        }
      })
      .catch((err) => {
        console.error(err)
      })
  }

  autosubmit() {
    clearTimeout(this._autosubmitTimer)
    this._autosubmitTimer = setTimeout(() => {
      if (this.element?.requestSubmit) this.element.requestSubmit()
    }, 200)
  }

  _needsReload(curr, next) {
    const forceServerKeys = [
      "mandarin_scheme",
      "cantonese_scheme",
      "script_mode",
      "ruby_enabled",
    ]

    if (forceServerKeys.some((key) => (curr[key] || "") !== (next[key] || ""))) return true

    const showAllNext = (next.ruby_enabled || "0") === "1"

    if (showAllNext) {
      const rubyKeys = ["ruby_source", "ruby_orientation", "ruby_side", "ruby_token"]
      if (rubyKeys.some((key) => (curr[key] || "") !== (next[key] || ""))) return true
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
      const selector = `[name="${CSS.escape(name)}"]`
      const elements = Array.from(form.querySelectorAll(selector))
      if (elements.length === 0) return ""

      // Rails check_box helpers emit a hidden "0" input immediately before the
      // checkbox. Looking up only the first matching element therefore reads
      // the hidden field forever. Prefer the real checkbox when one exists.
      const checkbox = elements.find((element) => element.type === "checkbox")
      if (checkbox) return checkbox.checked ? "1" : "0"

      const element = elements.find((candidate) => candidate.type !== "hidden") || elements[elements.length - 1]
      return (element?.value || "").toString()
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

  _setValuesFromSnapshot(snapshot) {
    this.currentMandarinSchemeValue = snapshot.mandarin_scheme
    this.currentCantoneseSchemeValue = snapshot.cantonese_scheme
    this.currentRubyEnabledValue = snapshot.ruby_enabled
    this.currentRubySourceValue = snapshot.ruby_source
    this.currentRubyOrientationValue = snapshot.ruby_orientation
    this.currentRubySideValue = snapshot.ruby_side
    this.currentRubyTokenValue = snapshot.ruby_token
    this.currentScriptModeValue = snapshot.script_mode
    this.currentHanFontValue = snapshot.han_font
    this.currentHanFontScopeValue = snapshot.han_font_scope
    this.currentHanFontWarnMissingValue = snapshot.han_font_warn_missing
  }
}
