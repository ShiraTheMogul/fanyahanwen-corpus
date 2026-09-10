import {
  applyDetectedHanFontLayout,
  detectHanFontLayout,
} from "controllers/han_typography"

const INSTALL_KEY = Symbol.for("fanya.wordProcessor.typography.v1")

export function installWordProcessorTypographyReliability(ControllerClass) {
  const prototype = ControllerClass?.prototype
  if (!prototype || prototype[INSTALL_KEY]) return
  prototype[INSTALL_KEY] = true

  const priorConnect = prototype.connect
  const priorDisconnect = prototype.disconnect
  const priorApplyReaderSettings = prototype.applyReaderSettings
  const priorRenderEditor = prototype.renderEditor

  prototype.wpTypographyInstall = function() {
    if (this.wpTypographyFontChanged) return

    this.wpTypographyFontChanged = () => {
      // Do not leave the previous face's correction visible while the new font
      // is loading. Return to the ordinary Writer rhythm, then measure again.
      this.wpTypographyMetrics = null
      this.wpTypographyApply()
      this.wpTypographySchedule()
    }
    window.addEventListener("han-font-changed", this.wpTypographyFontChanged)
  }

  prototype.wpTypographyApply = function() {
    if (!this.editorTarget?.style) return

    const vertical = this.document?.settings?.vertical !== false
    const configuredSize = Number(this.document?.settings?.fontSizePx)
    let computedSize = null
    try {
      computedSize = Number.parseFloat(window.getComputedStyle(this.editorTarget).fontSize)
    } catch (_) {}
    const fontSizePx = Number.isFinite(computedSize)
      ? computedSize
      : (Number.isFinite(configuredSize) ? configuredSize : 20)

    applyDetectedHanFontLayout(this.editorTarget, this.wpTypographyMetrics, {
      vertical,
      hasRuby: !!this.editorTarget.querySelector?.("ruby"),
      fontSizePx,
      continuous: true,
    })
  }

  prototype.wpTypographySchedule = function() {
    const token = (this.wpTypographyRunToken || 0) + 1
    this.wpTypographyRunToken = token
    if (this.wpTypographyTimer) window.clearTimeout(this.wpTypographyTimer)

    const run = async () => {
      if (token !== this.wpTypographyRunToken) return
      if (!this.editorTarget?.isConnected) return
      if (!(this.editorTarget.textContent || "").trim()) {
        this.wpTypographyMetrics = null
        this.wpTypographyApply()
        return
      }

      const metrics = await detectHanFontLayout(this.editorTarget, {
        root: this.editorTarget,
        continuous: true,
      })
      if (token !== this.wpTypographyRunToken) return

      this.wpTypographyMetrics = metrics
      this.wpTypographyApply()
    }

    const schedule = () => {
      if (token !== this.wpTypographyRunToken) return
      if (typeof window.requestAnimationFrame === "function") {
        window.requestAnimationFrame(() => { run().catch(() => {}) })
      } else {
        run().catch(() => {})
      }
    }

    // Rendering can happen repeatedly while a user types or while a script
    // conversion finishes. Debounce the expensive SVG probe so a burst of
    // edits produces one measurement, while the token above invalidates any
    // older asynchronous result.
    this.wpTypographyTimer = window.setTimeout(() => {
      this.wpTypographyTimer = null
      if (document.fonts?.ready) {
        document.fonts.ready.then(schedule).catch(schedule)
      } else {
        schedule()
      }
    }, 80)
  }

  prototype.connect = async function(...args) {
    const result = await priorConnect.apply(this, args)
    this.wpTypographyInstall()
    this.wpTypographyApply()
    this.wpTypographySchedule()
    return result
  }

  prototype.disconnect = function(...args) {
    if (this.wpTypographyFontChanged) {
      window.removeEventListener("han-font-changed", this.wpTypographyFontChanged)
      this.wpTypographyFontChanged = null
    }
    this.wpTypographyRunToken = (this.wpTypographyRunToken || 0) + 1
    if (this.wpTypographyTimer) {
      window.clearTimeout(this.wpTypographyTimer)
      this.wpTypographyTimer = null
    }
    return typeof priorDisconnect === "function" ? priorDisconnect.apply(this, args) : undefined
  }

  prototype.applyReaderSettings = function(...args) {
    const result = priorApplyReaderSettings.apply(this, args)
    this.wpTypographyApply?.()
    this.wpTypographySchedule?.()
    return result
  }

  prototype.renderEditor = function(...args) {
    const result = priorRenderEditor.apply(this, args)
    this.wpTypographyApply?.()
    this.wpTypographySchedule?.()
    return result
  }
}
