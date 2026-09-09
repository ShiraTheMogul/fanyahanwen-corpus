import CorpusReaderController from "controllers/corpus_reader_controller"
import {
  applyDetectedHanFontLayout,
  applyHanTypography,
  createHanFontSizeControl,
  detectHanFontLayout,
  normaliseHanFontSize,
} from "controllers/han_typography"

const INSTALL_KEY = Symbol.for("fanya.corpusReader.typography.v2")

export function installCorpusReaderTypographyReliability(ControllerClass = CorpusReaderController) {
  const prototype = ControllerClass?.prototype
  if (!prototype || prototype[INSTALL_KEY]) return
  prototype[INSTALL_KEY] = true

  const originalConnect = prototype.connect
  const originalDisconnect = prototype.disconnect
  const originalApply = prototype._apply

  prototype.connect = function(...args) {
    const result = originalConnect.apply(this, args)
    this.crInstallFontSizeControl()
    this.crInstallFontLayoutDetection()
    return result
  }

  prototype.disconnect = function(...args) {
    if (this.crOnHanFontChanged) {
      window.removeEventListener("han-font-changed", this.crOnHanFontChanged)
    }
    this.crFontLayoutRunToken = (this.crFontLayoutRunToken || 0) + 1
    return originalDisconnect.apply(this, args)
  }

  prototype.crInstallFontSizeControl = function() {
    if (this.crFontSizeSelect?.isConnected) return
    const toolbar = this.element?.querySelector?.(".corpus-toolbar")
    if (!toolbar) return

    const { wrapper, select } = createHanFontSizeControl({
      value: this._state?.fontSizePx || 20,
      className: "corpus-toolbar-font-size",
      label: "Size",
      onChange: (size) => {
        this._state.fontSizePx = normaliseHanFontSize(size)
        this._saveState()
        this._apply()
        this._broadcast()
      },
    })
    wrapper.dataset.corpusReaderTypographyControl = "font-size"

    const spacer = toolbar.querySelector(".corpus-toolbar-spacer")
    if (spacer) toolbar.insertBefore(wrapper, spacer)
    else toolbar.appendChild(wrapper)
    this.crFontSizeSelect = select
  }

  prototype.crInstallFontLayoutDetection = function() {
    if (this.crOnHanFontChanged) return

    this.crOnHanFontChanged = () => {
      // Never carry a previous font's correction across a live font switch.
      // Clear to the reader's normal spacing while the new face is measured.
      this.crFontLayoutMetrics = null
      this.crApplyDetectedFontLayout()
      this.crScheduleFontLayoutDetection()
    }
    window.addEventListener("han-font-changed", this.crOnHanFontChanged)
    this.crScheduleFontLayoutDetection()
  }

  prototype.crScheduleFontLayoutDetection = function() {
    const token = (this.crFontLayoutRunToken || 0) + 1
    this.crFontLayoutRunToken = token

    const run = async () => {
      if (token !== this.crFontLayoutRunToken) return
      if (!this.contentTarget?.isConnected) return

      const metrics = await detectHanFontLayout(this.contentTarget, {
        root: this.contentTarget,
      })
      if (token !== this.crFontLayoutRunToken) return

      this.crFontLayoutMetrics = metrics
      this.crApplyDetectedFontLayout()
    }

    const schedule = () => {
      if (typeof window.requestAnimationFrame === "function") {
        window.requestAnimationFrame(() => { run().catch(() => {}) })
      } else {
        run().catch(() => {})
      }
    }

    if (document.fonts?.ready) {
      document.fonts.ready.then(schedule).catch(schedule)
    } else {
      schedule()
    }
  }

  prototype.crApplyDetectedFontLayout = function() {
    if (!this.contentTarget?.style) return
    applyDetectedHanFontLayout(this.contentTarget, this.crFontLayoutMetrics, {
      vertical: !!this._state?.vertical,
      hasRuby: !!this.contentTarget.querySelector?.("ruby"),
      fontSizePx: this._state?.fontSizePx || 20,
    })
  }

  prototype._apply = function(...args) {
    const result = originalApply.apply(this, args)
    const size = applyHanTypography(this.viewboxTarget, this._state?.fontSizePx || 20)
    if (this.crFontSizeSelect?.isConnected) {
      if (!Array.from(this.crFontSizeSelect.options).some((option) => Number(option.value) === size)) {
        const option = document.createElement("option")
        option.value = String(size)
        option.textContent = `${size}px`
        this.crFontSizeSelect.appendChild(option)
      }
      this.crFontSizeSelect.value = String(size)
    }

    // Re-apply a known result immediately after the reader rebuilds its DOM,
    // then measure again after fonts settle. Good fonts retain the untouched
    // corpusviewer.css spacing because a neutral result removes inline tweaks.
    this.crApplyDetectedFontLayout?.()
    this.crScheduleFontLayoutDetection?.()
    return result
  }
}
