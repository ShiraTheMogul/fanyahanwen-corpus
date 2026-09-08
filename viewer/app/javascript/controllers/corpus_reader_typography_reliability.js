import CorpusReaderController from "controllers/corpus_reader_controller"
import {
  applyHanTypography,
  createHanFontSizeControl,
  normaliseHanFontSize,
} from "controllers/han_typography"

const INSTALL_KEY = Symbol.for("fanya.corpusReader.typography.v1")

export function installCorpusReaderTypographyReliability(ControllerClass = CorpusReaderController) {
  const prototype = ControllerClass?.prototype
  if (!prototype || prototype[INSTALL_KEY]) return
  prototype[INSTALL_KEY] = true

  const originalConnect = prototype.connect
  const originalApply = prototype._apply

  prototype.connect = function(...args) {
    const result = originalConnect.apply(this, args)
    this.crInstallFontSizeControl()
    return result
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
    return result
  }
}
