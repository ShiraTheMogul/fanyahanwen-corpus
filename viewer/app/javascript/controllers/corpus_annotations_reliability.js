import CorpusAnnotationsController from "controllers/corpus_annotations_controller"
import {
  enhanceCorpusNoteBlocks,
  ensureJiagzhuStyles,
} from "controllers/han_jiagzhu"

const INSTALL_KEY = Symbol.for("fanya.corpusAnnotations.jiagzhu.v3")
const READABILITY_STYLE_ID = "fanya-corpus-jiagzhu-readability"
const VISIBILITY_STORAGE_KEY = "corpus.jiagzhuVisible"
const BASE_CELL_ADVANCE_EM = 0.5
const READABLE_CELL_ADVANCE_EM = 0.62
const READABLE_CELL_INLINE_EM = READABLE_CELL_ADVANCE_EM / BASE_CELL_ADVANCE_EM

function ensureCorpusJiagzhuReadabilityStyles(documentRef = document) {
  ensureJiagzhuStyles(documentRef)
  if (!documentRef?.head || documentRef.getElementById(READABILITY_STYLE_ID)) return

  const style = documentRef.createElement("style")
  style.id = READABILITY_STYLE_ID
  style.textContent = `
    /* Reader-only 夾注 rhythm. In vertical writing the inline axis runs down
       the page, so this is the character-to-character spacing within each
       small annotation column. */
    .corpus-textflow.is-vertical .han-jiagzhu__column {
      letter-spacing: ${READABLE_CELL_INLINE_EM - 1}em;
    }

    /* Corpus source text is normally wrapped in one .cch span per character.
       Give those characters explicit cells so punctuation and Han advance by
       the same amount and the paired 夾注 columns stay in step. */
    .corpus-textflow.is-vertical .han-jiagzhu__column .cch {
      display: inline-block;
      inline-size: ${READABLE_CELL_INLINE_EM}em;
      letter-spacing: 0;
      text-align: center;
    }

    /* Main-text judou are nudged into the gutter. That nudge is too large for
       half-size 夾注 and can visually push punctuation into the neighbouring
       mini-column, so keep punctuation centred inside its own 夾注 cell. */
    .corpus-textflow.is-vertical .han-jiagzhu .cv-judou {
      transform: none !important;
    }

    /* Hiding removes 夾注 from layout completely, allowing the surrounding
       source text to close up without altering or deleting the source markup. */
    .corpus-reader.is-jiagzhu-hidden .han-jiagzhu {
      display: none !important;
    }
  `
  documentRef.head.appendChild(style)
}

function jiagzhuColumnRows(column) {
  if (!column) return 0

  const indexed = Array.from(column.querySelectorAll?.(".cch") || [])
  if (indexed.length > 0) return indexed.length
  return Array.from(column.textContent || "").length
}

function jiagzhuRows(element) {
  if (!element) return 1

  const measuredRows = Math.max(
    jiagzhuColumnRows(element.querySelector?.(".han-jiagzhu__column--first")),
    jiagzhuColumnRows(element.querySelector?.(".han-jiagzhu__column--second"))
  )
  if (measuredRows > 0) {
    element.dataset.hanJiagzhuRows = String(measuredRows)
    return measuredRows
  }

  const labelLength = Array.from(element.getAttribute?.("aria-label") || "").length
  if (labelLength > 0) {
    const rows = Math.max(1, Math.ceil(labelLength / 2))
    element.dataset.hanJiagzhuRows = String(rows)
    return rows
  }

  const storedRows = Number.parseInt(element.dataset?.hanJiagzhuRows || "", 10)
  if (Number.isFinite(storedRows) && storedRows > 0) return storedRows

  const currentAdvance = Number.parseFloat(
    element.style?.getPropertyValue("--han-jiagzhu-inline-size") || ""
  )
  const rows = Number.isFinite(currentAdvance) && currentAdvance > 0
    ? Math.max(1, Math.round(currentAdvance / BASE_CELL_ADVANCE_EM))
    : 1
  element.dataset.hanJiagzhuRows = String(rows)
  return rows
}

function formatEm(value) {
  return `${Number(value.toFixed(4))}em`
}

function applyCorpusJiagzhuReadability(root) {
  if (!root?.querySelectorAll) return 0
  let count = 0

  root.querySelectorAll("[data-han-jiagzhu]").forEach((element) => {
    const rows = jiagzhuRows(element)
    element.style?.setProperty(
      "--han-jiagzhu-inline-size",
      formatEm(rows * READABLE_CELL_ADVANCE_EM)
    )
    count += 1
  })

  return count
}

function readJiagzhuVisibility() {
  try {
    return window.localStorage.getItem(VISIBILITY_STORAGE_KEY) !== "0"
  } catch (_) {
    return true
  }
}

function saveJiagzhuVisibility(visible) {
  try {
    window.localStorage.setItem(VISIBILITY_STORAGE_KEY, visible ? "1" : "0")
  } catch (_) {
    // The reader still works when storage is disabled; the choice just will
    // not persist to the next page load.
  }
}

export function installCorpusAnnotationsReliability(ControllerClass = CorpusAnnotationsController) {
  const prototype = ControllerClass?.prototype
  if (!prototype || prototype[INSTALL_KEY]) return
  prototype[INSTALL_KEY] = true

  const originalConnect = prototype.connect
  const originalApplyAll = prototype._applyAll

  prototype.caJiagzhuVisible = function() {
    if (typeof this._jiagzhuVisible !== "boolean") {
      this._jiagzhuVisible = readJiagzhuVisibility()
    }
    return this._jiagzhuVisible
  }

  prototype.caSyncJiagzhuVisibilityControl = function() {
    const button = this._jiagzhuVisibilityButton
    if (!button?.isConnected) return

    const hasJiagzhu = !!this._contentEl?.querySelector?.("[data-han-jiagzhu]")
    const visible = this.caJiagzhuVisible()
    button.hidden = !hasJiagzhu
    button.textContent = "夾注"
    button.setAttribute("aria-pressed", visible ? "true" : "false")
    button.setAttribute("aria-label", visible ? "Hide 夾注" : "Show 夾注")
    button.title = visible ? "Hide 夾注" : "Show 夾注"
  }

  prototype.caApplyJiagzhuVisibility = function() {
    const visible = this.caJiagzhuVisible()
    this.element?.classList?.toggle("is-jiagzhu-hidden", !visible)
    this.caSyncJiagzhuVisibilityControl()
  }

  prototype.caInstallJiagzhuVisibilityControl = function() {
    const toolbar = this.element?.querySelector?.(".corpus-toolbar")
    if (!toolbar) return

    let button = toolbar.querySelector("[data-corpus-jiagzhu-control]")
    if (!button) {
      button = document.createElement("button")
      button.type = "button"
      button.className = "corpus-btn"
      button.dataset.corpusJiagzhuControl = "true"

      const spacer = toolbar.querySelector(".corpus-toolbar-spacer")
      if (spacer) toolbar.insertBefore(button, spacer)
      else toolbar.appendChild(button)
    }

    button.onclick = () => {
      const visible = !this.caJiagzhuVisible()
      this._jiagzhuVisible = visible
      saveJiagzhuVisibility(visible)
      this.caApplyJiagzhuVisibility()
    }

    this._jiagzhuVisibilityButton = button
    this.caSyncJiagzhuVisibilityControl()
  }

  prototype.caApplyJiagzhuReadability = function() {
    ensureCorpusJiagzhuReadabilityStyles()
    if (this._contentEl) applyCorpusJiagzhuReadability(this._contentEl)
    this.caInstallJiagzhuVisibilityControl()
    this.caApplyJiagzhuVisibility()
  }

  prototype.connect = function(...args) {
    ensureCorpusJiagzhuReadabilityStyles()
    const result = originalConnect.apply(this, args)
    if (this._contentEl) {
      enhanceCorpusNoteBlocks(this._contentEl, { owner: "corpus-source-jiazhu" })
    }
    this.caApplyJiagzhuReadability()
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
    this.caApplyJiagzhuReadability()
    return result
  }
}
