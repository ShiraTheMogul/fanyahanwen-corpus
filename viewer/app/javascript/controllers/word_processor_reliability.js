import {
  createJiagzhuContainer,
  ensureJiagzhuStyles,
  insertAtTextOffset,
  renderJiagzhuAtOffsets,
  updateJiagzhuColumns,
} from "controllers/han_jiagzhu"
import {
  applyHanTypography,
  createHanFontSizeControl,
  normaliseHanFontSize,
} from "controllers/han_typography"

const INSTALL_KEY = Symbol.for("fanya.wordProcessor.reliability.v1")
const HISTORY_LIMIT = 60
const STYLE_ID = "fanya-word-processor-reliability-styles"
const NON_DOCUMENT_SELECTOR = "rt, rp, [data-wp-nondocument], [data-han-jiagzhu], [data-wp-inline-comment]"
const COUNTING_ROD_MIN = 0x1D360
const COUNTING_ROD_MAX = 0x1D371

function fatalException(error) {
  return error && ["AbortError"].includes(error.name)
}

export function isCountingRodRun(value) {
  const characters = Array.from(String(value || ""))
  let hasRod = false
  const valid = characters.length > 0 && characters.every((character) => {
    if (character === "〇") return true
    const codepoint = character.codePointAt(0)
    const rod = codepoint >= COUNTING_ROD_MIN && codepoint <= COUNTING_ROD_MAX
    if (rod) hasRod = true
    return rod
  })
  return valid && hasRod
}

function isCountingRodCharacter(character) {
  const codepoint = String(character || "").codePointAt(0)
  return Number.isFinite(codepoint) && codepoint >= COUNTING_ROD_MIN && codepoint <= COUNTING_ROD_MAX
}

function installStyles() {
  if (document.getElementById(STYLE_ID)) return
  const style = document.createElement("style")
  style.id = STYLE_ID
  style.textContent = `
    /* A trailing newline needs a DOM endpoint so the caret can occupy the
       genuinely empty final line. Keep that endpoint at zero advance: giving
       it a physical width enlarges a vertical line box and pulls the entire
       column away from the right-hand writing margin. */
    .wp-editor .wp-terminal-line {
      display: inline;
      opacity: 0;
      pointer-events: none;
      user-select: none;
      font-size: inherit;
      line-height: inherit;
    }

    .wp-editor.is-vertical .wp-vertical-wave {
      display: inline-block;
      writing-mode: horizontal-tb;
      text-orientation: mixed;
      transform: rotate(90deg);
      transform-origin: center;
    }

    /* Horizontal numeral runs get a one-character *layout slot*. The visible
       run is centred over that slot at its natural width. text-combine-upright
       compresses long runs to one em and, on some Chromium builds, can also
       widen the vertical line box before compression; both behaviours produce
       the squeezed numerals / displaced right margin seen in Writer. */
    .wp-horizontal-numeral,
    .wp-horizontal-numeral__run {
      font-family: inherit;
      font-weight: inherit;
      font-style: inherit;
    }

    .wp-editor.is-vertical .wp-horizontal-numeral {
      display: inline-block;
      position: relative;
      box-sizing: border-box;
      inline-size: 1em;
      block-size: 1em;
      min-inline-size: 1em;
      min-block-size: 1em;
      vertical-align: middle;
      overflow: visible;
      text-combine-upright: none;
      -webkit-text-combine: none;
    }

    .wp-editor.is-vertical .wp-horizontal-numeral__run {
      position: absolute;
      left: 50%;
      top: 50%;
      transform: translate(-50%, -50%);
      transform-origin: center;
      writing-mode: horizontal-tb;
      text-orientation: mixed;
      text-combine-upright: none;
      -webkit-text-combine: none;
      white-space: nowrap;
      line-height: 1;
      font-size: 0.92em;
      letter-spacing: 0.035em;
    }

    .wp-editor.is-vertical .wp-horizontal-numeral--arabic .wp-horizontal-numeral__run {
      font-variant-numeric: tabular-nums;
    }

    /* Editorial comments retain the old in-text convention: visible angle
       brackets in the reading flow, with the comment itself in red. They are
       annotation UI and never enter the chapter text. */
    .wp-inline-comment {
      display: inline;
      position: relative;
      color: #b00000;
      font-family: inherit;
      font-size: 0.78em;
      line-height: 1;
      white-space: pre-wrap;
      cursor: text;
    }

    .wp-inline-comment__display {
      color: inherit;
    }

    .wp-inline-comment__editor {
      display: none;
      position: absolute;
      z-index: 6;
      min-width: 4em;
      max-width: 24em;
      padding: 0.18em 0.3em;
      border: 1px solid currentColor;
      border-radius: 0.2em;
      outline: none;
      background: var(--site-surface, Canvas);
      color: #b00000;
      font-family: inherit;
      font-size: 0.95em;
      line-height: 1.25;
      letter-spacing: 0;
      white-space: pre;
      writing-mode: horizontal-tb;
      text-orientation: mixed;
      caret-color: currentColor;
      user-select: text;
    }

    .wp-inline-comment.is-editing .wp-inline-comment__editor {
      display: inline-block;
    }

    .wp-editor.is-vertical .wp-inline-comment__editor {
      right: 0;
      top: 50%;
      transform: translateY(-50%);
    }

    .wp-editor:not(.is-vertical) .wp-inline-comment__editor {
      left: 0;
      top: 100%;
    }

    .wp-inline-comment__remove {
      display: none;
      position: absolute;
      z-index: 7;
      width: 1.15rem;
      height: 1.15rem;
      padding: 0;
      border: 1px solid currentColor;
      border-radius: 50%;
      background: var(--site-surface, Canvas);
      color: #b00000;
      font: inherit;
      font-size: 0.72rem;
      line-height: 1;
      cursor: pointer;
    }

    .wp-inline-comment.is-editing .wp-inline-comment__remove {
      display: inline-grid;
      place-items: center;
    }

    .wp-editor.is-vertical .wp-inline-comment__remove {
      right: -0.55rem;
      top: -0.65rem;
    }

    .wp-editor:not(.is-vertical) .wp-inline-comment__remove {
      left: -0.55rem;
      top: 0.55rem;
    }

    .wp-jiagzhu-inline-comment {
      display: inline-flex;
      align-items: baseline;
      color: #b00000;
      font: inherit;
      line-height: inherit;
      white-space: nowrap;
      vertical-align: baseline;
    }

    .wp-jiagzhu-inline-comment__editor {
      display: inline-block;
      min-width: 0.6em;
      outline: none;
      color: inherit;
      font: inherit;
      line-height: inherit;
      white-space: pre;
      caret-color: currentColor;
    }

    .wp-jiagzhu-inline-comment__remove {
      display: none;
      margin-left: 0.12em;
      padding: 0 0.15em;
      border: 0;
      background: transparent;
      color: inherit;
      font: inherit;
      line-height: 1;
      cursor: pointer;
    }

    .wp-jiagzhu-inline-comment:focus-within .wp-jiagzhu-inline-comment__remove {
      display: inline-block;
    }

    .han-font-size-control {
      display: grid;
      gap: 0.15rem;
      min-width: 5.5rem;
      font-size: 0.9rem;
    }

    .han-font-size-control__select {
      width: 100%;
      box-sizing: border-box;
    }

    .wp-history-button {
      min-width: 2.35rem;
      font-size: 1rem;
      line-height: 1;
    }
  `
  document.head.appendChild(style)
}

function serializeDocument(documentValue) {
  return JSON.stringify(documentValue)
}

function indexOfNode(node) {
  if (!node?.parentNode) return 0
  return Array.prototype.indexOf.call(node.parentNode.childNodes, node)
}

function isMainEditorTarget(controller, target) {
  if (!target || !controller.editorTarget) return false
  return target === controller.editorTarget || controller.editorTarget.contains(target)
}

function textLengthWithout(root, excludeSelector = null) {
  if (!root) return 0
  const holder = root.cloneNode(true)
  if (excludeSelector) holder.querySelectorAll?.(excludeSelector).forEach((node) => node.remove())
  return (holder.textContent || "").length
}

function editableCaretOffset(element, excludeSelector = null) {
  const selection = element?.ownerDocument?.defaultView?.getSelection?.() || window.getSelection?.()
  if (!selection || selection.rangeCount === 0 || !selection.isCollapsed) return null
  const range = selection.getRangeAt(0)
  if (!element.contains(range.startContainer)) return null
  const prefix = range.cloneRange()
  prefix.selectNodeContents(element)
  prefix.setEnd(range.startContainer, range.startOffset)
  const holder = element.ownerDocument.createElement("span")
  holder.appendChild(prefix.cloneContents())
  if (excludeSelector) holder.querySelectorAll(excludeSelector).forEach((node) => node.remove())
  return (holder.textContent || "").length
}

function editableSelectionOffsets(element, excludeSelector = null) {
  const selection = element?.ownerDocument?.defaultView?.getSelection?.() || window.getSelection?.()
  if (!selection || selection.rangeCount === 0) return null
  const range = selection.getRangeAt(0)
  if (!element.contains(range.startContainer) || !element.contains(range.endContainer)) return null
  const prefix = element.ownerDocument.createRange()
  prefix.selectNodeContents(element)
  prefix.setEnd(range.startContainer, range.startOffset)
  const startHolder = element.ownerDocument.createElement("span")
  startHolder.appendChild(prefix.cloneContents())
  if (excludeSelector) startHolder.querySelectorAll(excludeSelector).forEach((node) => node.remove())
  const start = (startHolder.textContent || "").length

  const through = element.ownerDocument.createRange()
  through.selectNodeContents(element)
  through.setEnd(range.endContainer, range.endOffset)
  const endHolder = element.ownerDocument.createElement("span")
  endHolder.appendChild(through.cloneContents())
  if (excludeSelector) endHolder.querySelectorAll(excludeSelector).forEach((node) => node.remove())
  const end = (endHolder.textContent || "").length
  return { start: Math.min(start, end), end: Math.max(start, end) }
}

function setEditableCaretAtOffset(element, wanted, excludeSelector = null) {
  if (!element) return
  const target = Math.max(0, Number(wanted) || 0)
  const walker = element.ownerDocument.createTreeWalker(element, NodeFilter.SHOW_TEXT, {
    acceptNode: (node) => excludeSelector && node.parentElement?.closest(excludeSelector)
      ? NodeFilter.FILTER_REJECT
      : NodeFilter.FILTER_ACCEPT,
  })
  let consumed = 0
  let last = null
  while (walker.nextNode()) {
    const node = walker.currentNode
    last = node
    const length = (node.nodeValue || "").length
    if (target <= consumed + length) {
      const range = element.ownerDocument.createRange()
      range.setStart(node, Math.max(0, target - consumed))
      range.collapse(true)
      const selection = element.ownerDocument.defaultView?.getSelection?.() || window.getSelection?.()
      selection?.removeAllRanges()
      selection?.addRange(range)
      return
    }
    consumed += length
  }
  if (last) {
    const range = element.ownerDocument.createRange()
    range.setStart(last, (last.nodeValue || "").length)
    range.collapse(true)
    const selection = element.ownerDocument.defaultView?.getSelection?.() || window.getSelection?.()
    selection?.removeAllRanges()
    selection?.addRange(range)
  } else {
    setEditableCaret(element, "end")
  }
}

function setEditableCaret(element, where = "end") {
  if (!element) return
  const selection = element.ownerDocument?.defaultView?.getSelection?.() || window.getSelection?.()
  if (!selection) return
  const range = element.ownerDocument.createRange()
  range.selectNodeContents(element)
  range.collapse(where !== "end")
  selection.removeAllRanges()
  selection.addRange(range)
}

function insertPlainTextAtCaret(element, value) {
  const documentRef = element?.ownerDocument || document
  const selection = documentRef.defaultView?.getSelection?.() || window.getSelection?.()
  if (!selection || selection.rangeCount === 0) return
  const range = selection.getRangeAt(0)
  if (!element.contains(range.commonAncestorContainer)) return
  range.deleteContents()
  const textNode = documentRef.createTextNode(String(value || ""))
  range.insertNode(textNode)
  range.setStartAfter(textNode)
  range.collapse(true)
  selection.removeAllRanges()
  selection.addRange(range)
}

export function installWordProcessorReliability(ControllerClass) {
  const prototype = ControllerClass?.prototype
  if (!prototype || prototype[INSTALL_KEY]) return
  prototype[INSTALL_KEY] = true

  installStyles()
  ensureJiagzhuStyles()

  const originalConnect = prototype.connect
  const originalDefaultDocument = prototype.defaultDocument
  const originalApplyReaderSettings = prototype.applyReaderSettings
  const originalRenderEditor = prototype.renderEditor
  const originalAppendStyledText = prototype.appendStyledText
  const originalOffsetForPoint = prototype.offsetForPoint
  const originalPointForOffset = prototype.pointForOffset
  const originalInsertTextAtSelection = prototype.insertTextAtSelection
  const originalProcessScriptConversionQueue = prototype.processScriptConversionQueue
  const originalScheduleAutosave = prototype.scheduleAutosave
  const originalWindowKeydown = prototype.windowKeydown
  const originalEditorKeydown = prototype.editorKeydown
  const originalEditNote = prototype.editNote
  const originalSyncEditorToModel = prototype.syncEditorToModel
  const originalContextMenu = prototype.contextMenu
  const originalDeleteNote = prototype.deleteNote

  prototype.defaultDocument = function(...args) {
    const documentValue = originalDefaultDocument.apply(this, args)
    documentValue.settings ||= {}
    const shared = window.localStorage?.getItem?.("corpus.fontSizePx")
    documentValue.settings.fontSizePx = normaliseHanFontSize(documentValue.settings.fontSizePx ?? shared ?? 20)
    return documentValue
  }

  prototype.applyReaderSettings = function(...args) {
    const result = originalApplyReaderSettings.apply(this, args)
    const size = normaliseHanFontSize(this.document?.settings?.fontSizePx ?? 20)
    if (this.document?.settings) this.document.settings.fontSizePx = size
    applyHanTypography(this.viewboxTarget, size)
    if (this.wpFontSizeSelect?.isConnected) {
      if (!Array.from(this.wpFontSizeSelect.options).some((option) => Number(option.value) === size)) {
        const option = document.createElement("option")
        option.value = String(size)
        option.textContent = `${size}px`
        this.wpFontSizeSelect.appendChild(option)
      }
      this.wpFontSizeSelect.value = String(size)
    }
    return result
  }

  prototype.connect = async function(...args) {
    await originalConnect.apply(this, args)
    this.wpInstallFontSizeControl()
    this.applyReaderSettings()
    this.wpInitializeHistory()
    this.wpInstallHistoryButtons()
  }

  prototype.wpInstallFontSizeControl = function() {
    if (this.wpFontSizeSelect?.isConnected) return
    const fontField = this.element?.querySelector?.(".wp-font-field")
    const toolbar = this.element?.querySelector?.(".wp-toolbar")
    if (!toolbar) return

    const { wrapper, select } = createHanFontSizeControl({
      value: this.document?.settings?.fontSizePx || 20,
      className: "wp-toolbar-field wp-font-size-field",
      label: "Size",
      onChange: (size) => {
        const resolved = normaliseHanFontSize(size)
        this.document.settings.fontSizePx = resolved
        try { window.localStorage.setItem("corpus.fontSizePx", String(resolved)) } catch (_error) {}
        this.applyReaderSettings()
        this.scheduleAutosave()
      },
    })
    wrapper.dataset.wpTypographyControl = "font-size"
    if (fontField?.parentNode) fontField.parentNode.insertBefore(wrapper, fontField.nextSibling)
    else toolbar.appendChild(wrapper)
    this.wpFontSizeSelect = select
  }

  prototype.wpCaptureHistorySnapshot = function() {
    const selection = this.captureSelectionRange()
    return {
      serialized: serializeDocument(this.document),
      selection: selection ? { ...selection } : null,
      activeChapterId: this.document?.activeChapterId || null,
    }
  }

  prototype.wpInitializeHistory = function() {
    this.wpHistory = {
      undo: [],
      redo: [],
      baseline: this.wpCaptureHistorySnapshot(),
      restoring: false,
      transactionDepth: 0,
      generation: 0,
    }
    this.wpUpdateHistoryButtons()
  }

  prototype.wpRecordHistoryState = function() {
    const history = this.wpHistory
    if (!history || history.restoring || history.transactionDepth > 0) return

    const current = this.wpCaptureHistorySnapshot()
    const previous = history.baseline
    if (!previous) {
      history.baseline = current
      return
    }

    if (previous.serialized === current.serialized) {
      previous.selection = current.selection
      previous.activeChapterId = current.activeChapterId
      return
    }

    history.undo.push(previous)
    if (history.undo.length > HISTORY_LIMIT) history.undo.splice(0, history.undo.length - HISTORY_LIMIT)
    history.redo = []
    history.baseline = current
    this.wpUpdateHistoryButtons()
  }

  prototype.wpBeginHistoryTransaction = function() {
    const history = this.wpHistory
    if (!history || history.restoring) return false
    const owns = history.transactionDepth === 0
    history.transactionDepth += 1
    return owns
  }

  prototype.wpEndHistoryTransaction = function(owns, generation = null) {
    const history = this.wpHistory
    if (!history || history.restoring) return
    history.transactionDepth = Math.max(0, history.transactionDepth - 1)
    if (!owns || history.transactionDepth !== 0) return
    if (generation !== null && generation !== history.generation) return
    this.wpRecordHistoryState()
  }

  prototype.scheduleAutosave = function(...args) {
    this.wpRecordHistoryState()
    return originalScheduleAutosave.apply(this, args)
  }

  prototype.wpInstallHistoryButtons = function() {
    const group = this.element.querySelector(".wp-view-group") || this.element.querySelector(".wp-toolbar")
    if (!group || group.querySelector("[data-wp-history='undo']")) return

    const undo = document.createElement("button")
    undo.type = "button"
    undo.className = "corpus-btn wp-history-button"
    undo.dataset.wpHistory = "undo"
    undo.textContent = "↶"
    undo.title = "Undo (Ctrl/Cmd+Z)"
    undo.setAttribute("aria-label", "Undo")
    undo.addEventListener("click", () => this.wpUndo())

    const redo = document.createElement("button")
    redo.type = "button"
    redo.className = "corpus-btn wp-history-button"
    redo.dataset.wpHistory = "redo"
    redo.textContent = "↷"
    redo.title = "Redo (Ctrl/Cmd+Shift+Z or Ctrl+Y)"
    redo.setAttribute("aria-label", "Redo")
    redo.addEventListener("click", () => this.wpRedo())

    group.append(undo, redo)
    this.wpUpdateHistoryButtons()
  }

  prototype.wpUpdateHistoryButtons = function() {
    if (!this.element) return
    const undo = this.element.querySelector("[data-wp-history='undo']")
    const redo = this.element.querySelector("[data-wp-history='redo']")
    if (undo) undo.disabled = !(this.wpHistory?.undo?.length > 0)
    if (redo) redo.disabled = !(this.wpHistory?.redo?.length > 0)
  }

  prototype.wpRestoreHistorySnapshot = function(snapshot) {
    const history = this.wpHistory
    if (!history || !snapshot) return

    history.restoring = true
    history.generation += 1
    this.pendingScriptConversions = []
    this.cancelNumeralComposition({ restoreCaret: false })

    try {
      this.document = this.normaliseDocument(JSON.parse(snapshot.serialized))
      if (snapshot.activeChapterId && this.document.chapters.some((chapter) => chapter.id === snapshot.activeChapterId)) {
        this.document.activeChapterId = snapshot.activeChapterId
      }
      this.syncControlsFromDocument()
      this.renderAll()
      history.baseline = this.wpCaptureHistorySnapshot()
      originalScheduleAutosave.call(this)

      window.requestAnimationFrame(() => {
        this.editorTarget.focus()
        if (snapshot.selection) this.restoreSelection(snapshot.selection)
        history.baseline = this.wpCaptureHistorySnapshot()
      })
    } finally {
      history.restoring = false
      this.wpUpdateHistoryButtons()
    }
  }

  prototype.wpUndo = function() {
    const history = this.wpHistory
    if (!history || history.undo.length === 0) return

    const current = this.wpCaptureHistorySnapshot()
    let target = null
    while (history.undo.length > 0 && !target) {
      const candidate = history.undo.pop()
      if (candidate.serialized !== current.serialized) target = candidate
    }
    if (!target) {
      this.wpUpdateHistoryButtons()
      return
    }

    history.redo.push(current)
    if (history.redo.length > HISTORY_LIMIT) history.redo.splice(0, history.redo.length - HISTORY_LIMIT)
    this.wpRestoreHistorySnapshot(target)
  }

  prototype.wpRedo = function() {
    const history = this.wpHistory
    if (!history || history.redo.length === 0) return

    const current = this.wpCaptureHistorySnapshot()
    let target = null
    while (history.redo.length > 0 && !target) {
      const candidate = history.redo.pop()
      if (candidate.serialized !== current.serialized) target = candidate
    }
    if (!target) {
      this.wpUpdateHistoryButtons()
      return
    }

    history.undo.push(current)
    if (history.undo.length > HISTORY_LIMIT) history.undo.splice(0, history.undo.length - HISTORY_LIMIT)
    this.wpRestoreHistorySnapshot(target)
  }

  prototype.windowKeydown = function(event) {
    const modifier = event.ctrlKey || event.metaKey
    const key = String(event.key || "").toLowerCase()
    const externalEditable = event.target?.closest?.("input, textarea, select, [contenteditable='true']")

    if (modifier && !event.altKey && (!externalEditable || isMainEditorTarget(this, event.target))) {
      if (key === "z") {
        event.preventDefault()
        event.stopPropagation()
        if (event.shiftKey) this.wpRedo()
        else this.wpUndo()
        return
      }
      if (key === "y" && !event.shiftKey) {
        event.preventDefault()
        event.stopPropagation()
        this.wpRedo()
        return
      }
    }

    return originalWindowKeydown.call(this, event)
  }

  prototype.processScriptConversionQueue = async function(...args) {
    // Only the outer queue owns the transaction. Additional keystrokes enqueue
    // work while the first request is in flight and should undo as one authored
    // action rather than exposing transient pre-conversion text.
    if (this.scriptConversionQueueRunning) return originalProcessScriptConversionQueue.apply(this, args)
    const generation = this.wpHistory?.generation ?? null
    const owns = this.wpBeginHistoryTransaction()
    try {
      return await originalProcessScriptConversionQueue.apply(this, args)
    } finally {
      this.wpEndHistoryTransaction(owns, generation)
    }
  }

  prototype.wpAnnotationById = function(annotationId) {
    const chapter = this.activeChapter()
    if (!chapter) return null
    return (chapter.annotations || []).find((annotation) => String(annotation.id) === String(annotationId)) || null
  }

  prototype.wpNestedCommentsFor = function(parentAnnotationId) {
    const chapter = this.activeChapter()
    if (!chapter) return []
    return (chapter.annotations || [])
      .filter((annotation) => annotation.kind === "comment" && String(annotation.parentAnnotationId || "") === String(parentAnnotationId))
      .sort((a, b) => (Number(a.innerEnd) || 0) - (Number(b.innerEnd) || 0))
  }

  prototype.wpNestedCommentLayoutRows = function(parentAnnotationId) {
    return this.wpNestedCommentsFor(parentAnnotationId).map((annotation) => ({
      id: annotation.id,
      note: String(annotation.note || ""),
      anchor: Math.max(0, Number(annotation.innerEnd) || 0),
    }))
  }

  prototype.wpReconcileNestedComments = function(parentAnnotation, editor) {
    if (!parentAnnotation || !editor) return false
    const chapter = this.activeChapter()
    if (!chapter) return false
    const children = this.wpNestedCommentsFor(parentAnnotation.id)
    if (children.length === 0) return false
    const present = new Set(Array.from(editor.querySelectorAll("[data-wp-nested-comment]")).map((element) => String(element.dataset.wpNestedCommentId || "")))
    const removed = new Set(children.filter((child) => !present.has(String(child.id))).map((child) => String(child.id)))
    if (removed.size === 0) return false
    chapter.annotations = (chapter.annotations || []).filter((annotation) => !removed.has(String(annotation.id)))
    this.renderNotes()
    return true
  }

  prototype.wpCreateNestedCommentElement = function(parentAnnotation, annotation, parentEditor) {
    const outer = document.createElement("span")
    outer.className = "wp-jiagzhu-inline-comment"
    outer.dataset.wpNestedComment = "true"
    outer.dataset.wpNestedCommentId = String(annotation.id)
    outer.dataset.wpNestedCommentParentId = String(parentAnnotation.id)
    outer.contentEditable = "false"

    const open = document.createElement("span")
    open.textContent = "〈"
    open.setAttribute("aria-hidden", "true")

    const editor = document.createElement("span")
    editor.className = "wp-jiagzhu-inline-comment__editor"
    editor.contentEditable = "true"
    editor.spellcheck = false
    editor.setAttribute("role", "textbox")
    editor.setAttribute("aria-label", "Edit comment within 夾注")
    editor.textContent = String(annotation.note || "")

    const close = document.createElement("span")
    close.textContent = "〉"
    close.setAttribute("aria-hidden", "true")

    const remove = document.createElement("button")
    remove.type = "button"
    remove.className = "wp-jiagzhu-inline-comment__remove"
    remove.textContent = "×"
    remove.setAttribute("aria-label", "Remove comment")

    const save = () => {
      const live = this.wpAnnotationById(annotation.id)
      if (!live) return
      live.note = String(editor.textContent || "").replace(/[\r\n]+/g, "")
      const jiagzhuOuter = parentEditor.closest("[data-han-jiagzhu]")
      if (jiagzhuOuter) updateJiagzhuColumns(jiagzhuOuter, String(parentAnnotation.note || ""), { comments: this.wpNestedCommentLayoutRows(parentAnnotation.id) })
      this.renderNotes()
      originalScheduleAutosave.call(this)
    }

    editor.addEventListener("keydown", (event) => {
      event.stopPropagation()
      const value = String(editor.textContent || "")
      const caret = editableCaretOffset(editor)
      if (event.key === "Enter") {
        event.preventDefault()
        parentEditor.focus({ preventScroll: true })
        setEditableCaretAtOffset(parentEditor, Number(annotation.innerEnd) || 0, "[data-wp-nested-comment]")
        return
      }
      if ((event.key === "Backspace" || event.key === "Delete") && value.length === 0 && caret === 0) {
        event.preventDefault()
        const anchor = Math.max(0, Number(annotation.innerEnd) || 0)
        this.wpDeleteNestedComment(annotation.id, outer, parentEditor)
        window.requestAnimationFrame(() => {
          parentEditor.focus({ preventScroll: true })
          setEditableCaretAtOffset(parentEditor, anchor, "[data-wp-nested-comment]")
        })
      }
    })
    editor.addEventListener("beforeinput", (event) => {
      event.stopPropagation()
      if (event.inputType === "insertParagraph" || event.inputType === "insertLineBreak") event.preventDefault()
    })
    editor.addEventListener("input", (event) => { event.stopPropagation(); save() })
    editor.addEventListener("paste", (event) => {
      event.preventDefault()
      event.stopPropagation()
      insertPlainTextAtCaret(editor, String(event.clipboardData?.getData("text/plain") || "").replace(/[\r\n]+/g, " "))
      save()
    })
    editor.addEventListener("blur", () => {
      window.requestAnimationFrame(() => {
        const live = this.wpAnnotationById(annotation.id)
        if (live && !String(live.note || "").trim()) this.wpDeleteNestedComment(annotation.id, outer, parentEditor)
        const jiagzhuOuter = parentEditor.closest("[data-han-jiagzhu]")
        if (jiagzhuOuter && !jiagzhuOuter.contains(document.activeElement)) this.wpFinishInlineAnnotationEdit(parentEditor)
      })
    })
    remove.addEventListener("pointerdown", (event) => { event.preventDefault(); event.stopPropagation() })
    remove.addEventListener("click", (event) => {
      event.preventDefault()
      event.stopPropagation()
      const anchor = Math.max(0, Number(annotation.innerEnd) || 0)
      this.wpDeleteNestedComment(annotation.id, outer, parentEditor)
      window.requestAnimationFrame(() => {
        parentEditor.focus({ preventScroll: true })
        setEditableCaretAtOffset(parentEditor, anchor, "[data-wp-nested-comment]")
      })
    })

    outer.append(open, editor, close, remove)
    return outer
  }

  prototype.wpRenderNestedCommentsInEditor = function(parentAnnotation, editor) {
    if (!parentAnnotation || !editor) return
    const current = editableSelectionOffsets(editor, "[data-wp-nested-comment]")
    editor.querySelectorAll("[data-wp-nested-comment]").forEach((element) => element.remove())
    this.wpNestedCommentsFor(parentAnnotation.id).forEach((annotation) => {
      const anchor = Math.max(0, Math.min(Number(annotation.innerEnd) || 0, String(parentAnnotation.note || "").length))
      const element = this.wpCreateNestedCommentElement(parentAnnotation, annotation, editor)
      insertAtTextOffset(editor, anchor, element, { excludeSelector: "[data-wp-nested-comment]" })
    })
    if (current) setEditableCaretAtOffset(editor, current.end, "[data-wp-nested-comment]")
  }

  prototype.wpDeleteNestedComment = function(annotationId, outer = null, parentEditor = null) {
    const chapter = this.activeChapter()
    if (!chapter) return
    const annotation = this.wpAnnotationById(annotationId)
    if (!annotation || !annotation.parentAnnotationId) return
    chapter.annotations = (chapter.annotations || []).filter((item) => String(item.id) !== String(annotationId) && String(item.parentAnnotationId || "") !== String(annotationId))
    outer?.remove()
    const parent = this.wpAnnotationById(annotation.parentAnnotationId)
    const jiagzhuOuter = parentEditor?.closest?.("[data-han-jiagzhu]")
    if (parent && jiagzhuOuter) updateJiagzhuColumns(jiagzhuOuter, String(parent.note || ""), { comments: this.wpNestedCommentLayoutRows(parent.id) })
    this.renderNotes()
    this.scheduleAutosave()
  }

  prototype.wpAddNestedComment = function(context) {
    const chapter = this.activeChapter()
    const parent = this.wpAnnotationById(context?.parentAnnotationId)
    if (!chapter || !parent || parent.kind !== "note") return false
    const start = Math.max(0, Math.min(Number(context.start) || 0, String(parent.note || "").length))
    const end = Math.max(start, Math.min(Number(context.end) || start, String(parent.note || "").length))
    const annotation = {
      id: this.uuid("annotation"),
      kind: "comment",
      start: Number(parent.end) || 0,
      end: Number(parent.end) || 0,
      parentAnnotationId: parent.id,
      innerStart: start,
      innerEnd: end,
      note: "",
    }
    chapter.annotations.push(annotation)
    this.closeContextMenu()
    this.wpNestedContext = null
    this.wpActiveInlineAnnotationId = String(parent.id)
    this.wpActiveInlineAnnotationKind = "note"
    this.renderEditor({ start: parent.end, end: parent.end })
    this.renderNotes()
    originalScheduleAutosave.call(this)
    window.requestAnimationFrame(() => {
      const outer = Array.from(this.editorTarget.querySelectorAll('[data-han-jiagzhu-owner="word-processor"]')).find((element) => String(element.dataset.hanJiagzhuAnnotationId) === String(parent.id))
      const parentEditor = outer?.querySelector(".han-jiagzhu__editor")
      if (!outer || !parentEditor) return
      this.wpStartInlineAnnotationEdit("note", parent.id, parentEditor, outer)
      this.wpRenderNestedCommentsInEditor(parent, parentEditor)
      const nested = Array.from(parentEditor.querySelectorAll("[data-wp-nested-comment]")).find((element) => String(element.dataset.wpNestedCommentId) === String(annotation.id))
      const nestedEditor = nested?.querySelector(".wp-jiagzhu-inline-comment__editor")
      if (nestedEditor) {
        nestedEditor.focus({ preventScroll: true })
        setEditableCaret(nestedEditor, "end")
      }
    })
    return true
  }

  prototype.wpStartInlineAnnotationEdit = function(kind, annotationId, editor, outer) {
    if (!editor || !outer) return
    outer.classList.add("is-editing")
    this.wpActiveInlineAnnotationId = String(annotationId)
    this.wpActiveInlineAnnotationKind = String(kind)

    const current = this.wpInlineAnnotationEdit
    if (current?.editor === editor) return
    if (current?.editor && current.editor !== editor) this.wpFinishInlineAnnotationEdit(current.editor, { focusMain: false })

    const generation = this.wpHistory?.generation ?? null
    const owns = this.wpBeginHistoryTransaction()
    this.wpInlineAnnotationEdit = { kind, annotationId: String(annotationId), editor, outer, owns, generation }
    if (kind === "note") {
      const annotation = this.wpAnnotationById(annotationId)
      if (annotation) this.wpRenderNestedCommentsInEditor(annotation, editor)
    }
  }

  prototype.wpInlineAnnotationValue = function(editor) {
    if (!editor) return ""
    const clone = editor.cloneNode(true)
    clone.querySelectorAll("[data-wp-nested-comment]").forEach((element) => element.remove())
    return String(clone.textContent || "").replace(/[\r\n]+/g, "")
  }

  prototype.wpUpdateInlineAnnotation = function(editor) {
    const outer = editor?.closest?.("[data-han-jiagzhu], [data-wp-inline-comment]")
    const annotationId = outer?.dataset.hanJiagzhuAnnotationId || outer?.dataset.wpInlineCommentAnnotationId
    if (!outer || !annotationId) return
    const annotation = this.wpAnnotationById(annotationId)
    if (!annotation) return

    if (annotation.kind === "note") this.wpReconcileNestedComments(annotation, editor)
    const value = this.wpInlineAnnotationValue(editor)
    if (annotation.kind === "note") {
      const oldValue = String(annotation.note || "")
      if (oldValue !== value) {
        const diff = this.diffText(oldValue, value)
        this.wpNestedCommentsFor(annotation.id).forEach((child) => {
          child.innerStart = Math.max(0, this.transformOffset(Number(child.innerStart) || 0, diff, "left"))
          child.innerEnd = Math.max(child.innerStart, this.transformOffset(Number(child.innerEnd) || 0, diff, "right"))
        })
      }
    }
    annotation.note = value
    if (annotation.kind === "note") {
      updateJiagzhuColumns(outer, value, { comments: this.wpNestedCommentLayoutRows(annotation.id) })
    } else if (annotation.kind === "comment") {
      const display = outer.querySelector(".wp-inline-comment__display")
      if (display) display.textContent = `〈${value}〉`
      outer.setAttribute("aria-label", value)
    }
    originalScheduleAutosave.call(this)
  }

  prototype.wpFinishInlineAnnotationEdit = function(editor, { focusMain = false, side = "after" } = {}) {
    const active = this.wpInlineAnnotationEdit
    if (!active || active.editor !== editor) return
    const outer = active.outer
    const annotation = this.wpAnnotationById(active.annotationId)
    const anchor = Number(outer?.dataset.hanJiagzhuAnchor ?? outer?.dataset.wpInlineCommentAnchor ?? annotation?.end ?? 0)
    const value = this.wpInlineAnnotationValue(editor)

    if (annotation) annotation.note = value
    if (outer) outer.classList.remove("is-editing")
    this.wpInlineAnnotationEdit = null
    this.wpActiveInlineAnnotationId = null
    this.wpActiveInlineAnnotationKind = null

    if (annotation && value.trim().length === 0) {
      const chapter = this.activeChapter()
      chapter.annotations = (chapter.annotations || []).filter((item) => String(item.id) !== String(annotation.id) && String(item.parentAnnotationId || "") !== String(annotation.id))
      outer?.remove()
    } else if (annotation?.kind === "note") {
      updateJiagzhuColumns(outer, value, { comments: this.wpNestedCommentLayoutRows(annotation.id) })
    } else if (annotation?.kind === "comment") {
      const display = outer?.querySelector?.(".wp-inline-comment__display")
      if (display) display.textContent = `〈${value}〉`
    }

    this.renderNotes()
    this.wpEndHistoryTransaction(active.owns, active.generation)
    originalScheduleAutosave.call(this)

    if (focusMain) {
      window.requestAnimationFrame(() => this.wpPlaceMainCaretAtAnnotationBoundary(outer, anchor, side))
    }
  }

  prototype.wpPlaceMainCaretAtAnnotationBoundary = function(outer, anchor, side = "after") {
    this.editorTarget.focus({ preventScroll: true })
    const selection = window.getSelection?.()
    if (selection && outer?.isConnected) {
      const range = document.createRange()
      if (side === "before") range.setStartBefore(outer)
      else range.setStartAfter(outer)
      range.collapse(true)
      selection.removeAllRanges()
      selection.addRange(range)
    } else {
      this.restoreSelection({ start: anchor, end: anchor })
    }

    const vertical = this.document.settings.vertical !== false
    const skipKey = side === "after" ? (vertical ? "ArrowDown" : "ArrowRight") : (vertical ? "ArrowUp" : "ArrowLeft")
    this.wpSkipJiagzhuNavigation = { anchor, key: skipKey }
  }

  prototype.wpDeleteInlineAnnotation = function(annotationId, outer = null, { focusMain = true } = {}) {
    const annotation = this.wpAnnotationById(annotationId)
    if (!annotation) return
    const chapter = this.activeChapter()
    const anchor = Math.max(0, Number(annotation.end) || 0)
    const active = this.wpInlineAnnotationEdit

    if (active && String(active.annotationId) === String(annotationId)) {
      active.editor.textContent = ""
      annotation.note = ""
      this.wpFinishInlineAnnotationEdit(active.editor, { focusMain, side: "after" })
      return
    }

    chapter.annotations = (chapter.annotations || []).filter((item) => String(item.id) !== String(annotationId))
    outer?.remove()
    this.renderNotes()
    this.scheduleAutosave()
    if (focusMain) window.requestAnimationFrame(() => this.restoreSelection({ start: anchor, end: anchor }))
  }

  prototype.wpInlineAnnotationKeydown = function(event, editor, kind, outer) {
    // Keep every editing keystroke inside the embedded editor. In particular,
    // Backspace must never fall through to the page/browser when the caret is
    // beside a zero-width annotation object.
    event.stopPropagation()

    const value = this.wpInlineAnnotationValue(editor)
    const caret = editableCaretOffset(editor, kind === "note" ? "[data-wp-nested-comment]" : null)
    const length = value.length
    const vertical = this.document.settings.vertical !== false
    const forwardKey = vertical ? "ArrowDown" : "ArrowRight"
    const backwardKey = vertical ? "ArrowUp" : "ArrowLeft"

    if (event.key === forwardKey && caret === length) {
      event.preventDefault()
      this.wpFinishInlineAnnotationEdit(editor, { focusMain: true, side: "after" })
      return
    }
    if (event.key === backwardKey && caret === 0) {
      event.preventDefault()
      this.wpFinishInlineAnnotationEdit(editor, { focusMain: true, side: "before" })
      return
    }
    if ((event.key === "Backspace" || event.key === "Delete") && caret === 0 && length === 0) {
      event.preventDefault()
      const annotationId = outer.dataset.hanJiagzhuAnnotationId || outer.dataset.wpInlineCommentAnnotationId
      this.wpDeleteInlineAnnotation(annotationId, outer, { focusMain: true })
      return
    }
    if (event.key === "Enter") {
      event.preventDefault()
      this.wpFinishInlineAnnotationEdit(editor, { focusMain: true, side: "after" })
      return
    }
    if (event.key === "Escape") {
      event.preventDefault()
      this.wpFinishInlineAnnotationEdit(editor, { focusMain: true, side: "after" })
    }
  }

  prototype.wpWireInlineEditor = function({ kind, annotationId, outer, editor, removeButton }) {
    const begin = (where = "end") => {
      this.wpStartInlineAnnotationEdit(kind, annotationId, editor, outer)
      editor.focus({ preventScroll: true })
      setEditableCaret(editor, where)
    }

    outer.addEventListener("pointerdown", (event) => {
      if (editor.contains(event.target) || removeButton.contains(event.target)) return
      event.preventDefault()
      event.stopPropagation()
    })
    outer.addEventListener("click", (event) => {
      if (editor.contains(event.target) || removeButton.contains(event.target)) return
      event.preventDefault()
      event.stopPropagation()
      begin("end")
    })
    outer.addEventListener("contextmenu", (event) => {
      // Right-click *inside* the horizontal 夾注 editor belongs to the main
      // Writer context menu so a nested red comment can be inserted at that
      // inner caret/selection. Right-clicking the displayed 夾注 itself still
      // enters editing directly.
      if (editor.contains(event.target)) return
      event.preventDefault()
      event.stopPropagation()
      begin("end")
    })

    editor.addEventListener("focus", () => this.wpStartInlineAnnotationEdit(kind, annotationId, editor, outer))
    editor.addEventListener("keydown", (event) => this.wpInlineAnnotationKeydown(event, editor, kind, outer))
    editor.addEventListener("beforeinput", (event) => {
      event.stopPropagation()
      if (event.inputType === "insertParagraph" || event.inputType === "insertLineBreak") event.preventDefault()
    })
    editor.addEventListener("input", (event) => {
      event.stopPropagation()
      this.wpUpdateInlineAnnotation(editor)
    })
    editor.addEventListener("paste", (event) => {
      event.preventDefault()
      event.stopPropagation()
      const text = String(event.clipboardData?.getData("text/plain") || "").replace(/[\r\n]+/g, " ")
      insertPlainTextAtCaret(editor, text)
      this.wpUpdateInlineAnnotation(editor)
    })
    editor.addEventListener("blur", () => {
      window.requestAnimationFrame(() => {
        if (document.activeElement === editor || outer.contains(document.activeElement)) return
        this.wpFinishInlineAnnotationEdit(editor)
      })
    })

    removeButton.addEventListener("pointerdown", (event) => {
      event.preventDefault()
      event.stopPropagation()
    })
    removeButton.addEventListener("click", (event) => {
      event.preventDefault()
      event.stopPropagation()
      this.wpDeleteInlineAnnotation(annotationId, outer, { focusMain: true })
    })

    return { begin }
  }

  prototype.wpCreateWriterJiagzhuElement = function(entry) {
    const { outer, first, second } = createJiagzhuContainer({
      owner: "word-processor",
      anchor: entry.anchor,
      annotationId: entry.annotationId,
      contentEditable: false,
      ariaLabel: entry.note,
    })
    outer.classList.add("han-jiagzhu--editable")
    const parentAnnotation = this.wpAnnotationById(entry.annotationId)
    const layout = updateJiagzhuColumns(outer, entry.note, { comments: this.wpNestedCommentLayoutRows(entry.annotationId) })
    if (!layout) {
      first.textContent = ""
      second.textContent = ""
    }

    const editor = document.createElement("span")
    editor.className = "han-jiagzhu__editor"
    editor.contentEditable = "true"
    editor.setAttribute("role", "textbox")
    editor.setAttribute("aria-label", "Edit 夾注")
    editor.setAttribute("aria-multiline", "false")
    editor.spellcheck = false
    editor.textContent = entry.note
    if (parentAnnotation) this.wpRenderNestedCommentsInEditor(parentAnnotation, editor)

    const removeButton = document.createElement("button")
    removeButton.type = "button"
    removeButton.className = "han-jiagzhu__remove"
    removeButton.textContent = "×"
    removeButton.setAttribute("aria-label", "Remove 夾注")
    removeButton.title = "Remove 夾注"

    outer.append(editor, removeButton)
    this.wpWireInlineEditor({ kind: "note", annotationId: entry.annotationId, outer, editor, removeButton })
    if (String(this.wpActiveInlineAnnotationId || "") === String(entry.annotationId)) outer.classList.add("is-editing")
    return outer
  }

  prototype.wpCreateInlineCommentElement = function(entry) {
    const outer = document.createElement("span")
    outer.className = "wp-inline-comment"
    outer.dataset.wpInlineComment = "true"
    outer.dataset.wpInlineCommentAnchor = String(entry.anchor)
    outer.dataset.wpInlineCommentAnnotationId = String(entry.annotationId)
    outer.contentEditable = "false"
    outer.setAttribute("role", "note")
    outer.setAttribute("aria-label", entry.note)

    const display = document.createElement("span")
    display.className = "wp-inline-comment__display"
    display.textContent = `〈${entry.note}〉`

    const editor = document.createElement("span")
    editor.className = "wp-inline-comment__editor"
    editor.contentEditable = "true"
    editor.setAttribute("role", "textbox")
    editor.setAttribute("aria-label", "Edit comment")
    editor.setAttribute("aria-multiline", "false")
    editor.spellcheck = false
    editor.textContent = entry.note

    const removeButton = document.createElement("button")
    removeButton.type = "button"
    removeButton.className = "wp-inline-comment__remove"
    removeButton.textContent = "×"
    removeButton.setAttribute("aria-label", "Remove comment")
    removeButton.title = "Remove comment"

    outer.append(display, editor, removeButton)
    this.wpWireInlineEditor({ kind: "comment", annotationId: entry.annotationId, outer, editor, removeButton })
    if (String(this.wpActiveInlineAnnotationId || "") === String(entry.annotationId)) outer.classList.add("is-editing")
    return outer
  }

  prototype.wpRenderInlineComments = function(chapter) {
    this.editorTarget.querySelectorAll("[data-wp-inline-comment]").forEach((element) => element.remove())
    const comments = (chapter.annotations || [])
      .filter((annotation) => annotation.kind === "comment" && !annotation.parentAnnotationId && (String(annotation.note || "").trim() || String(this.wpActiveInlineAnnotationId || "") === String(annotation.id)))
      .map((annotation) => ({
        note: String(annotation.note || ""),
        anchor: Math.max(0, Math.min(Number(annotation.end) || 0, chapter.text.length)),
        annotationId: annotation.id,
      }))
      .sort((a, b) => a.anchor - b.anchor)

    comments.forEach((entry) => {
      const element = this.wpCreateInlineCommentElement(entry)
      insertAtTextOffset(this.editorTarget, entry.anchor, element, { excludeSelector: NON_DOCUMENT_SELECTOR })
    })
  }

  prototype.wpFocusJiagzhu = function(element, where = "end") {
    if (!element) return false
    const editor = element.querySelector(".han-jiagzhu__editor")
    if (!editor) return false
    this.wpStartInlineAnnotationEdit("note", element.dataset.hanJiagzhuAnnotationId, editor, element)
    editor.focus({ preventScroll: true })
    setEditableCaret(editor, where)
    return true
  }

  prototype.wpJiagzhuAtAnchor = function(anchor, which = "first") {
    const rows = Array.from(this.editorTarget.querySelectorAll('[data-han-jiagzhu-owner="word-processor"]'))
      .filter((element) => Number(element.dataset.hanJiagzhuAnchor) === Number(anchor))
    if (rows.length === 0) return null
    return which === "last" ? rows[rows.length - 1] : rows[0]
  }

  prototype.wpAddInlineAnnotation = function(kind) {
    const chapter = this.activeChapter()
    if (!chapter) return
    const range = this.savedContextRange || this.captureSelectionRange() || { start: chapter.text.length, end: chapter.text.length }
    const start = Math.max(0, Math.min(Number(range.start) || 0, chapter.text.length))
    const end = Math.max(start, Math.min(Number(range.end) || start, chapter.text.length))
    const annotation = { id: this.uuid("annotation"), kind, start, end, note: "" }

    this.closeContextMenu()
    this.savedContextRange = null
    chapter.annotations.push(annotation)
    this.wpActiveInlineAnnotationId = annotation.id
    this.wpActiveInlineAnnotationKind = kind
    this.renderEditor({ start: end, end })
    this.renderNotes()
    originalScheduleAutosave.call(this)

    window.requestAnimationFrame(() => {
      const selector = kind === "note" ? '[data-han-jiagzhu-owner="word-processor"]' : "[data-wp-inline-comment]"
      const outer = Array.from(this.editorTarget.querySelectorAll(selector)).find((element) => {
        const id = element.dataset.hanJiagzhuAnnotationId || element.dataset.wpInlineCommentAnnotationId
        return String(id) === String(annotation.id)
      })
      if (!outer) return
      const editor = outer.querySelector(kind === "note" ? ".han-jiagzhu__editor" : ".wp-inline-comment__editor")
      if (!editor) return
      this.wpStartInlineAnnotationEdit(kind, annotation.id, editor, outer)
      editor.focus({ preventScroll: true })
      setEditableCaret(editor, "end")
    })
  }

  prototype.contextMenu = function(event) {
    const jiagzhuEditor = event.target?.closest?.(".han-jiagzhu__editor")
    const nestedCommentEditor = event.target?.closest?.(".wp-jiagzhu-inline-comment__editor")
    if (!jiagzhuEditor || nestedCommentEditor) {
      this.wpNestedContext = null
      return originalContextMenu.call(this, event)
    }

    const outer = jiagzhuEditor.closest("[data-han-jiagzhu]")
    const parentId = outer?.dataset.hanJiagzhuAnnotationId
    const parent = this.wpAnnotationById(parentId)
    if (!parent) return originalContextMenu.call(this, event)

    event.preventDefault()
    event.stopPropagation()
    const offsets = editableSelectionOffsets(jiagzhuEditor, "[data-wp-nested-comment]") || {
      start: editableCaretOffset(jiagzhuEditor, "[data-wp-nested-comment]") || 0,
      end: editableCaretOffset(jiagzhuEditor, "[data-wp-nested-comment]") || 0,
    }
    this.wpNestedContext = { parentAnnotationId: parent.id, start: offsets.start, end: offsets.end }
    this.savedContextRange = { start: Number(parent.end) || 0, end: Number(parent.end) || 0 }
    const menu = this.contextMenuTarget
    menu.style.left = `${event.pageX}px`
    menu.style.top = `${event.pageY}px`
    menu.removeAttribute("hidden")
  }

  // Right-click insertion edits annotations directly in the text. No native
  // browser prompt/alert/confirm is used for either 夾注 or editorial comments.
  prototype.addNote = function() {
    this.wpAddInlineAnnotation("note")
  }

  prototype.addComment = function() {
    if (this.wpNestedContext && !this.contextMenuTarget.hidden && this.wpAddNestedComment(this.wpNestedContext)) return

    const active = this.wpInlineAnnotationEdit
    if (active?.kind === "note" && active.editor?.isConnected) {
      const selection = window.getSelection?.()
      if (selection?.rangeCount && active.editor.contains(selection.getRangeAt(0).commonAncestorContainer)) {
        const offsets = editableSelectionOffsets(active.editor, "[data-wp-nested-comment]") || {
          start: editableCaretOffset(active.editor, "[data-wp-nested-comment]") || 0,
          end: editableCaretOffset(active.editor, "[data-wp-nested-comment]") || 0,
        }
        this.wpNestedContext = { parentAnnotationId: active.annotationId, start: offsets.start, end: offsets.end }
        if (this.wpAddNestedComment(this.wpNestedContext)) return
      }
    }

    this.wpNestedContext = null
    this.wpAddInlineAnnotation("comment")
  }

  prototype.editNote = function(event) {
    const annotationId = event?.currentTarget?.dataset?.annotationId
    const annotation = this.wpAnnotationById(annotationId)
    if (!annotation || !["note", "comment"].includes(annotation.kind)) {
      return originalEditNote.call(this, event)
    }

    if (annotation.parentAnnotationId) {
      const parent = this.wpAnnotationById(annotation.parentAnnotationId)
      if (!parent) return
      this.wpActiveInlineAnnotationId = String(parent.id)
      this.wpActiveInlineAnnotationKind = "note"
      this.renderEditor({ start: parent.end, end: parent.end })
      window.requestAnimationFrame(() => {
        const outer = Array.from(this.editorTarget.querySelectorAll('[data-han-jiagzhu-owner="word-processor"]')).find((element) => String(element.dataset.hanJiagzhuAnnotationId) === String(parent.id))
        const parentEditor = outer?.querySelector(".han-jiagzhu__editor")
        if (!outer || !parentEditor) return
        this.wpStartInlineAnnotationEdit("note", parent.id, parentEditor, outer)
        this.wpRenderNestedCommentsInEditor(parent, parentEditor)
        const nested = Array.from(parentEditor.querySelectorAll("[data-wp-nested-comment]")).find((element) => String(element.dataset.wpNestedCommentId) === String(annotation.id))
        const nestedEditor = nested?.querySelector(".wp-jiagzhu-inline-comment__editor")
        nestedEditor?.focus({ preventScroll: true })
        if (nestedEditor) setEditableCaret(nestedEditor, "end")
      })
      return
    }

    this.wpActiveInlineAnnotationId = String(annotation.id)
    this.wpActiveInlineAnnotationKind = annotation.kind
    this.renderEditor({ start: annotation.end, end: annotation.end })
    window.requestAnimationFrame(() => {
      const selector = annotation.kind === "note" ? '[data-han-jiagzhu-owner="word-processor"]' : "[data-wp-inline-comment]"
      const outer = Array.from(this.editorTarget.querySelectorAll(selector)).find((element) => {
        const id = element.dataset.hanJiagzhuAnnotationId || element.dataset.wpInlineCommentAnnotationId
        return String(id) === String(annotation.id)
      })
      const editor = outer?.querySelector(annotation.kind === "note" ? ".han-jiagzhu__editor" : ".wp-inline-comment__editor")
      if (!outer || !editor) return
      this.wpStartInlineAnnotationEdit(annotation.kind, annotation.id, editor, outer)
      editor.focus({ preventScroll: true })
      setEditableCaret(editor, "end")
    })
  }

  prototype.wpReconcileDeletedInlineAnnotations = function() {
    const chapter = this.activeChapter()
    if (!chapter || !this.editorTarget) return false
    const removed = new Set()
    ;(chapter.annotations || []).forEach((annotation) => {
      if (annotation.parentAnnotationId || !["note", "comment"].includes(annotation.kind)) return
      if (!String(annotation.note || "").trim()) return
      const selector = annotation.kind === "note"
        ? `[data-han-jiagzhu-annotation-id="${CSS.escape(String(annotation.id))}"]`
        : `[data-wp-inline-comment-annotation-id="${CSS.escape(String(annotation.id))}"]`
      if (!this.editorTarget.querySelector(selector)) removed.add(String(annotation.id))
    })
    if (removed.size === 0) return false
    chapter.annotations = (chapter.annotations || []).filter((annotation) => !removed.has(String(annotation.id)) && !removed.has(String(annotation.parentAnnotationId || "")))
    if (removed.has(String(this.wpActiveInlineAnnotationId || ""))) {
      this.wpActiveInlineAnnotationId = null
      this.wpActiveInlineAnnotationKind = null
      this.wpInlineAnnotationEdit = null
    }
    this.renderNotes()
    this.scheduleAutosave()
    return true
  }

  prototype.syncEditorToModel = function(...args) {
    this.wpReconcileDeletedInlineAnnotations()
    return originalSyncEditorToModel.apply(this, args)
  }

  prototype.deleteNote = function(event) {
    const annotationId = event?.currentTarget?.dataset?.annotationId
    const annotation = this.wpAnnotationById(annotationId)
    if (!annotation) return originalDeleteNote.call(this, event)
    const chapter = this.activeChapter()
    chapter.annotations = (chapter.annotations || []).filter((item) => String(item.id) !== String(annotationId) && String(item.parentAnnotationId || "") !== String(annotationId))
    if (String(this.wpActiveInlineAnnotationId || "") === String(annotationId)) {
      this.wpActiveInlineAnnotationId = null
      this.wpActiveInlineAnnotationKind = null
      this.wpInlineAnnotationEdit = null
    }
    this.renderEditor({ start: Number(annotation.end) || 0, end: Number(annotation.end) || 0 })
    this.renderNotes()
    this.scheduleAutosave()
  }

  prototype.editorKeydown = function(event) {
    if (event.target?.closest?.(".han-jiagzhu__editor, .wp-inline-comment__editor")) return

    if (!this.numeralComposition) {
      const range = this.captureSelectionRange()
      if (range && range.start === range.end) {
        const anchor = range.start
        if (event.key === "Backspace") {
          const note = this.wpJiagzhuAtAnchor(anchor, "last")
          if (note) {
            event.preventDefault()
            event.stopPropagation()
            this.wpFocusJiagzhu(note, "end")
            return
          }
        }

        const vertical = this.document.settings.vertical !== false
        const forwardKey = vertical ? "ArrowDown" : "ArrowRight"
        if (event.key === forwardKey) {
          if (this.wpSkipJiagzhuNavigation?.anchor === anchor && this.wpSkipJiagzhuNavigation?.key === event.key) {
            this.wpSkipJiagzhuNavigation = null
          } else {
            const note = this.wpJiagzhuAtAnchor(anchor, "first")
            if (note) {
              event.preventDefault()
              event.stopPropagation()
              this.wpFocusJiagzhu(note, "start")
              return
            }
          }
        }
      }
    }

    return originalEditorKeydown.call(this, event)
  }

  prototype.renderEditor = function(selection = null) {
    const result = originalRenderEditor.call(this, selection)
    const chapter = this.activeChapter()
    if (!chapter) return result

    const noteRows = (chapter.annotations || [])
      .filter((annotation) => annotation.kind === "note" && (String(annotation.note || "").trim() || String(this.wpActiveInlineAnnotationId || "") === String(annotation.id)))
      .map((annotation) => ({
        note: String(annotation.note || ""),
        anchor: Math.max(0, Math.min(Number(annotation.end) || 0, chapter.text.length)),
        annotationId: annotation.id,
      }))

    renderJiagzhuAtOffsets(this.editorTarget, noteRows, {
      owner: "word-processor",
      excludeSelector: NON_DOCUMENT_SELECTOR,
      includeEmpty: true,
      elementFactory: (entry) => this.wpCreateWriterJiagzhuElement(entry),
    })
    this.wpRenderInlineComments(chapter)

    if (chapter.text.endsWith("\n")) {
      const marker = document.createElement("span")
      marker.className = "wp-terminal-line"
      marker.dataset.wpNondocument = "terminal-line"
      marker.contentEditable = "false"
      marker.setAttribute("aria-hidden", "true")
      marker.textContent = "\u200b"
      this.editorTarget.appendChild(marker)
    }

    // Shared 夾注 and the terminal-line marker are presentation-only. Reapply
    // the source-space selection after inserting them so the caret cannot jump.
    this.restoreSelection(selection || { start: chapter.text.length, end: chapter.text.length })
    return result
  }

  prototype.appendStyledText = function(container, text) {
    const characters = Array.from(String(text || ""))
    let buffer = ""
    const flush = () => {
      if (!buffer) return
      originalAppendStyledText.call(this, container, buffer)
      buffer = ""
    }
    const appendHorizontal = (value, kind = "generic") => {
      // The outer span is exactly one vertical character cell so the run cannot
      // change the column width. The inner span keeps the glyphs at natural
      // horizontal width and is centred over that cell.
      const slot = document.createElement("span")
      slot.className = `wp-horizontal-numeral wp-horizontal-numeral--${kind}`
      const run = document.createElement("span")
      run.className = "wp-horizontal-numeral__run"
      run.textContent = value
      slot.appendChild(run)
      container.appendChild(slot)
    }

    for (let index = 0; index < characters.length; index += 1) {
      const character = characters[index]

      if (character === "〜" || character === "～") {
        flush()
        const wave = document.createElement("span")
        wave.className = "wp-vertical-wave"
        wave.textContent = character
        container.appendChild(wave)
        continue
      }

      if (/^[0-9]$/.test(character)) {
        flush()
        let run = character
        while (index + 1 < characters.length && /^[0-9]$/.test(characters[index + 1])) {
          index += 1
          run += characters[index]
        }
        appendHorizontal(run, "arabic")
        continue
      }

      const beginsRodRun = isCountingRodCharacter(character)
        || (character === "〇" && isCountingRodCharacter(characters[index + 1]))
      if (beginsRodRun) {
        flush()
        let run = character
        while (index + 1 < characters.length) {
          const next = characters[index + 1]
          if (!isCountingRodCharacter(next) && next !== "〇") break
          index += 1
          run += characters[index]
        }
        if (isCountingRodRun(run)) appendHorizontal(run, "rods")
        else buffer += run
        continue
      }

      buffer += character
    }
    flush()
  }

  prototype.editorPlainText = function() {
    const clone = this.editorTarget.cloneNode(true)
    clone.querySelectorAll(NON_DOCUMENT_SELECTOR).forEach((element) => element.remove())
    return clone.textContent || ""
  }

  prototype.offsetForPoint = function(node, offset) {
    try {
      const range = document.createRange()
      range.selectNodeContents(this.editorTarget)
      range.setEnd(node, offset)
      const clone = range.cloneContents()
      const holder = document.createElement("div")
      holder.appendChild(clone)
      holder.querySelectorAll(NON_DOCUMENT_SELECTOR).forEach((element) => element.remove())
      return (holder.textContent || "").length
    } catch (error) {
      if (fatalException(error)) throw error
      return originalOffsetForPoint.call(this, node, offset)
    }
  }

  prototype.pointForOffset = function(wanted) {
    const numericWanted = Math.max(0, Number(wanted) || 0)

    const anchoredNotes = Array.from(this.editorTarget.querySelectorAll("[data-han-jiagzhu-anchor]"))
      .filter((element) => Number(element.dataset.hanJiagzhuAnchor) === numericWanted)
    if (anchoredNotes.length > 0) {
      const last = anchoredNotes[anchoredNotes.length - 1]
      return { node: last.parentNode, offset: indexOfNode(last) + 1 }
    }

    const chapter = this.activeChapter()
    const terminal = this.editorTarget.querySelector(".wp-terminal-line[data-wp-nondocument]")
    if (terminal && chapter?.text?.endsWith("\n") && numericWanted >= chapter.text.length) {
      const anchorText = terminal.firstChild
      if (anchorText?.nodeType === Node.TEXT_NODE) return { node: anchorText, offset: 0 }
      return { node: terminal.parentNode, offset: indexOfNode(terminal) }
    }

    const walker = document.createTreeWalker(this.editorTarget, NodeFilter.SHOW_TEXT, {
      acceptNode: (node) => node.parentElement?.closest(NON_DOCUMENT_SELECTOR)
        ? NodeFilter.FILTER_REJECT
        : NodeFilter.FILTER_ACCEPT,
    })
    let consumed = 0
    let last = null
    while (walker.nextNode()) {
      const node = walker.currentNode
      last = node
      const length = (node.nodeValue || "").length
      if (numericWanted <= consumed + length) {
        return { node, offset: Math.max(0, numericWanted - consumed) }
      }
      consumed += length
    }

    if (last) return { node: last, offset: (last.nodeValue || "").length }
    return originalPointForOffset.call(this, numericWanted)
  }

  prototype.insertTextAtSelection = async function(text, options = {}) {
    const generation = this.wpHistory?.generation ?? null
    const owns = this.wpBeginHistoryTransaction()
    try {
      return await originalInsertTextAtSelection.call(this, text, options)
    } finally {
      this.wpEndHistoryTransaction(owns, generation)
    }
  }

}
