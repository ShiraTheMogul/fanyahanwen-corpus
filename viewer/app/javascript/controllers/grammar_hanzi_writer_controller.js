import { Controller } from "@hotwired/stimulus"

const HANZI_WRITER_URL = "https://cdn.jsdelivr.net/npm/hanzi-writer@3/dist/hanzi-writer.min.js"

function loadHanziWriter() {
  if (window.HanziWriter?.create) return Promise.resolve(window.HanziWriter)
  if (window.fanyaHanziWriterPromise) return window.fanyaHanziWriterPromise

  window.fanyaHanziWriterPromise = new Promise((resolve, reject) => {
    const existing = document.querySelector('script[data-fanya-hanzi-writer="true"]')
    const script = existing || document.createElement("script")

    const loaded = () => {
      if (window.HanziWriter?.create) resolve(window.HanziWriter)
      else reject(new Error("HanziWriter loaded without its public API"))
    }
    const failed = () => reject(new Error("HanziWriter could not be loaded"))

    script.addEventListener("load", loaded, { once: true })
    script.addEventListener("error", failed, { once: true })

    if (!existing) {
      script.src = HANZI_WRITER_URL
      script.dataset.fanyaHanziWriter = "true"
      document.head.appendChild(script)
    }
  })

  return window.fanyaHanziWriterPromise
}

export default class extends Controller {
  static targets = ["canvas", "fallback"]
  static values = { glyph: String }

  connect() {
    this.disconnected = false
    this.render()
  }

  disconnect() {
    this.disconnected = true
  }

  async render() {
    try {
      const HanziWriter = await loadHanziWriter()
      if (this.disconnected) return

      this.writer = HanziWriter.create(this.canvasTarget, this.glyphValue, {
        width: 132,
        height: 132,
        padding: 8,
        onLoadCharDataError: () => this.showFallback(),
      })

      this.hideFallback()
      const animation = this.writer.loopCharacterAnimation()
      if (animation?.catch) animation.catch(() => this.showFallback())
    } catch (_error) {
      if (!this.disconnected) this.showFallback()
    }
  }

  showFallback() {
    this.canvasTarget.hidden = true
    this.fallbackTarget.hidden = false
  }

  hideFallback() {
    this.canvasTarget.hidden = false
    this.fallbackTarget.hidden = true
  }
}
