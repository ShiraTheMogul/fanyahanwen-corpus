import CorpusAnnotationsController from "controllers/corpus_annotations_controller"
import {
  enhanceCorpusNoteBlocks,
  ensureJiagzhuStyles,
} from "controllers/han_jiagzhu"

const INSTALL_KEY = Symbol.for("fanya.corpusAnnotations.jiagzhu.v2")

export function installCorpusAnnotationsReliability(ControllerClass = CorpusAnnotationsController) {
  const prototype = ControllerClass?.prototype
  if (!prototype || prototype[INSTALL_KEY]) return
  prototype[INSTALL_KEY] = true

  const originalConnect = prototype.connect
  const originalApplyAll = prototype._applyAll

  prototype.connect = function(...args) {
    ensureJiagzhuStyles()
    const result = originalConnect.apply(this, args)
    if (this._contentEl) enhanceCorpusNoteBlocks(this._contentEl, { owner: "corpus-source-jiazhu" })
    return result
  }

  prototype._applyAll = function(...args) {
    const result = originalApplyAll.apply(this, args)
    if (this._contentEl) {
      // Source-text 〈…〉 blocks use the shared 夾注 renderer. User/scholarly
      // annotation notes remain their own metadata/sidebar system and are not
      // reinterpreted as 夾注.
      enhanceCorpusNoteBlocks(this._contentEl, { owner: "corpus-source-jiazhu" })
    }
    return result
  }
}
