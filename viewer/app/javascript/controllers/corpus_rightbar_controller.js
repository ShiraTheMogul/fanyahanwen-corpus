import { Controller } from "@hotwired/stimulus"

// Reader-only controls for the Corpus Viewer.
//
// The rightbar owns reading/display settings. The toolbar is left for
// maintenance and contribution actions. Existing reader actions are proxied
// where useful so the underlying reader/annotation controllers remain the
// single source of behaviour.
export default class extends Controller {
  static targets = [
    "theme",
    "vertical",
    "vflow",
    "fontsize",
    "rubyOnDemand",
    "punctStatus",
    "punctOpen",
    "autoAnnotations",
    "autoAnnotationStatus",
    "autoAnnotationMessage",
    "annotationColors",
    "notes",
  ]

  connect() {
    this._syncFromStorage()
    this._hideReadingToolbarControls()
    this._installJudouControl()
    this._syncToolbarProxies()

    this._onOptions = (event) => {
      if (event?.detail) this._setChecks(event.detail)
      this._installJudouControl()
      this._syncToolbarProxies()
    }
    window.addEventListener("corpus-view-options", this._onOptions)

    this._toolbar = document.querySelector(".corpus-toolbar")
    if (this._toolbar) {
      this._toolbarObserver = new MutationObserver(() => {
        this._hideReadingToolbarControls()
        this._syncToolbarProxies()
      })
      this._toolbarObserver.observe(this._toolbar, {
        subtree: true,
        childList: true,
        characterData: true,
        attributes: true,
        attributeFilter: ["aria-pressed", "disabled", "title"],
      })
    }

    // Some toolbar controls (notably automatic annotations) are populated
    // asynchronously. Sync again after the current frame so their status is
    // reflected in the rightbar as soon as it appears.
    window.requestAnimationFrame(() => {
      this._hideReadingToolbarControls()
      this._installJudouControl()
      this._syncToolbarProxies()
    })
  }

  disconnect() {
    window.removeEventListener("corpus-view-options", this._onOptions)
    if (this._toolbarObserver) this._toolbarObserver.disconnect()
    this._toolbarObserver = null
  }

  change() {
    const state = {}

    if (this.hasThemeTarget) state.theme = this.themeTarget.value
    if (this.hasVerticalTarget) state.vertical = this.verticalTarget.checked
    if (this.hasVflowTarget) state.vflow = this.vflowTarget.value
    if (this.hasFontsizeTarget) state.fontSizePx = (this.fontsizeTarget.value || "").toString()
    if (this.hasRubyOnDemandTarget) state.rubyOnDemand = this.rubyOnDemandTarget.checked

    if (typeof state.theme !== "undefined") {
      window.localStorage.setItem("corpus.theme", (state.theme || "bamboo").toString())
    }
    if (typeof state.vertical !== "undefined") {
      window.localStorage.setItem("corpus.vertical", state.vertical ? "1" : "0")
    }
    if (typeof state.vflow !== "undefined") {
      window.localStorage.setItem("corpus.verticalFlow", (state.vflow || "rl").toString())
    }
    if (typeof state.rubyOnDemand !== "undefined") {
      window.localStorage.setItem("corpus.rubyOnDemand", state.rubyOnDemand ? "1" : "0")
    }
    if (state.fontSizePx) {
      window.localStorage.setItem("corpus.fontSizePx", state.fontSizePx)
    }

    this._setChecks(state)
    window.dispatchEvent(new CustomEvent("corpus-view-options", { detail: state }))
  }

  setSize(event) {
    const px = parseInt(event?.currentTarget?.dataset?.size || "", 10)
    if (!Number.isFinite(px) || !this.hasFontsizeTarget) return

    this.fontsizeTarget.value = px
    this.change()
  }

  openPunctuation(event) {
    event?.preventDefault()
    const button = this._toolbarControl("corpus-reader#togglePunctMenu")
    if (!button) return

    button.click()
    this._installJudouControl()
    this._syncToolbarProxies()
  }

  toggleAutoAnnotations(event) {
    event?.preventDefault()
    const button = this._autoAnnotationButton()
    if (!button || button.disabled) {
      this._syncToolbarProxies()
      return
    }

    button.click()
    window.requestAnimationFrame(() => this._syncToolbarProxies())
  }

  toggleNotes(event) {
    this._setToolbarPressed(
      "corpus-annotations#toggleNotes",
      !!event?.currentTarget?.checked,
    )
  }

  openAnnotationColors(event) {
    event?.preventDefault()
    this._toolbarControl("corpus-annotations#openColorSettings")?.click()
  }

  _syncFromStorage() {
    const getBool = (key, fallback) => {
      const value = window.localStorage.getItem(key)
      if (value === null || value === undefined || value === "") return fallback
      return value === "1"
    }

    this._setChecks({
      theme: window.localStorage.getItem("corpus.theme") || "bamboo",
      vertical: getBool("corpus.vertical", false),
      vflow: window.localStorage.getItem("corpus.verticalFlow") || "rl",
      fontSizePx: window.localStorage.getItem("corpus.fontSizePx") || "20",
      rubyOnDemand: getBool("corpus.rubyOnDemand", false),
    })
  }

  _setChecks(state) {
    if (this.hasThemeTarget && typeof state.theme !== "undefined") {
      this.themeTarget.value = (state.theme || "bamboo").toString()
    }
    if (this.hasVerticalTarget && typeof state.vertical !== "undefined") {
      this.verticalTarget.checked = !!state.vertical
    }
    if (this.hasVflowTarget && typeof state.vflow !== "undefined") {
      this.vflowTarget.value = (state.vflow || "rl").toString()
    }
    if (this.hasFontsizeTarget && typeof state.fontSizePx !== "undefined") {
      this.fontsizeTarget.value = (state.fontSizePx || "20").toString()
    }
    if (this.hasRubyOnDemandTarget && typeof state.rubyOnDemand !== "undefined") {
      this.rubyOnDemandTarget.checked = !!state.rubyOnDemand
    }

    if (this.hasVflowTarget && this.hasVerticalTarget) {
      this.vflowTarget.disabled = !this.verticalTarget.checked
    }
  }

  _toolbarControl(action) {
    return document.querySelector(`.corpus-reader [data-action*="${action}"]`)
  }

  _autoAnnotationButton() {
    const toolbar = document.querySelector(".corpus-toolbar")
    if (!toolbar) return null

    const controls = Array.from(toolbar.querySelectorAll("button, [role='button']"))

    // Prefer an explicit controller/data marker if the local viewer provides
    // one. This keeps the rightbar compatible with the automatic annotation
    // implementation without coupling it to a particular controller name.
    const explicit = controls.find((control) => {
      const attrs = Array.from(control.attributes || [])
        .map((attr) => `${attr.name}=${attr.value}`.toLowerCase())
        .join(" ")
      return attrs.includes("annot") && attrs.includes("auto")
    })
    if (explicit) return explicit

    // Current automatic annotation control reports its state in the button
    // label (for example "Annotations: error"). Keep this fallback narrow so
    // it cannot be confused with "Annotation systems" or manual annotation
    // editing controls.
    return controls.find((control) => /^annotations\s*:/i.test((control.textContent || "").trim())) || null
  }

  _hideReadingToolbarControls() {
    const actions = [
      "corpus-reader#toggleVertical",
      "corpus-reader#cycleTheme",
      "corpus-reader#cyclePunctPreset",
      "corpus-reader#togglePunctMenu",
      "corpus-reader#toggleJudou",
      "corpus-annotations#toggleNotes",
      "corpus-annotations#openColorSettings",
    ]

    actions.forEach((action) => {
      const button = this._toolbarControl(action)
      if (button) button.hidden = true
    })

    const autoAnnotations = this._autoAnnotationButton()
    if (autoAnnotations) autoAnnotations.hidden = true
  }

  _pressed(button) {
    return !!button && button.getAttribute("aria-pressed") === "true"
  }

  _setToolbarPressed(action, wanted) {
    this._setButtonPressed(this._toolbarControl(action), wanted)
  }

  _setButtonPressed(button, wanted) {
    if (!button) {
      this._syncToolbarProxies()
      return
    }

    if (this._pressed(button) !== wanted) button.click()
    window.requestAnimationFrame(() => this._syncToolbarProxies())
  }

  _syncToolbarProxies() {
    const punctPreset = this._toolbarControl("corpus-reader#cyclePunctPreset")
    const punctMenu = this._toolbarControl("corpus-reader#togglePunctMenu")
    if (this.hasPunctStatusTarget) {
      this.punctStatusTarget.textContent = punctPreset?.textContent?.trim() || "—"
    }
    if (this.hasPunctOpenTarget) this.punctOpenTarget.disabled = !punctMenu

    this._syncAutoAnnotationProxy()

    const colorsButton = this._toolbarControl("corpus-annotations#openColorSettings")
    if (this.hasAnnotationColorsTarget) this.annotationColorsTarget.disabled = !colorsButton

    const notesButton = this._toolbarControl("corpus-annotations#toggleNotes")
    if (this.hasNotesTarget) {
      this.notesTarget.checked = this._pressed(notesButton)
      this.notesTarget.disabled = !notesButton
    }

    this._syncJudouControl()
  }

  _syncAutoAnnotationProxy() {
    const button = this._autoAnnotationButton()
    const label = button?.textContent?.trim() || ""

    if (this.hasAutoAnnotationsTarget) {
      this.autoAnnotationsTarget.disabled = !button || !!button.disabled
    }

    if (this.hasAutoAnnotationStatusTarget) {
      this.autoAnnotationStatusTarget.textContent = label || "—"
    }

    if (!this.hasAutoAnnotationMessageTarget) return

    const error = /\berror\b/i.test(label)
    if (!error) {
      this.autoAnnotationMessageTarget.hidden = true
      this.autoAnnotationMessageTarget.textContent = ""
      return
    }

    const nearby = button?.nextElementSibling
    const nearbyText = nearby && !nearby.matches("button, a") ? (nearby.textContent || "").trim() : ""
    const title = (button?.getAttribute("title") || "").trim()
    const detail = nearbyText || title

    this.autoAnnotationMessageTarget.textContent = detail || this.element.dataset.autoAnnotationError || "Automatic annotations could not be loaded. Manual corpus annotations are stored separately and remain available."
    this.autoAnnotationMessageTarget.hidden = false
  }

  _installJudouControl() {
    const grid = document.querySelector(".corpus-punct-grid")
    if (!grid) return

    const existing = grid.querySelector("[data-corpus-rightbar-judou]")
    if (existing) {
      this._judouInput = existing.querySelector("input[type=checkbox]")
      this._syncJudouControl()
      return
    }

    const fieldset = document.createElement("fieldset")
    fieldset.className = "corpus-fieldset corpus-judou-fieldset"
    fieldset.dataset.corpusRightbarJudou = "true"

    const legend = document.createElement("legend")
    legend.textContent = this.element.dataset.judouHeading || "Judou"
    fieldset.appendChild(legend)

    const label = document.createElement("label")
    const checkbox = document.createElement("input")
    checkbox.type = "checkbox"
    checkbox.id = "cv_judou_punctuation"
    checkbox.addEventListener("change", () => {
      this._setToolbarPressed("corpus-reader#toggleJudou", checkbox.checked)
    })
    label.appendChild(checkbox)
    label.appendChild(document.createTextNode(` ${this.element.dataset.judouToggleLabel || "Enable Judou display"}`))
    fieldset.appendChild(label)

    const hintText = this.element.dataset.judouHint || ""
    if (hintText) {
      const hint = document.createElement("div")
      hint.className = "corpus-judou-fieldset__hint"
      hint.textContent = hintText
      fieldset.appendChild(hint)
    }

    const presetBox = grid.querySelector(".preset-box")
    if (presetBox) presetBox.insertAdjacentElement("afterend", fieldset)
    else grid.prepend(fieldset)

    this._judouInput = checkbox
    this._syncJudouControl()
  }

  _syncJudouControl() {
    if (!this._judouInput) return
    const button = this._toolbarControl("corpus-reader#toggleJudou")
    this._judouInput.checked = this._pressed(button)
    this._judouInput.disabled = !button
  }
}
