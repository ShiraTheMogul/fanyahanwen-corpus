import {
  createJiagzhuContainer,
  ensureJiagzhuStyles,
  updateJiagzhuColumnsFromSource,
} from "controllers/han_jiagzhu"

const INSTALL_KEY = Symbol.for("fanya.wordProcessor.semanticAnnotations.v1")
const SOURCE_SELECTOR = "[data-wp-source-annotation]"
const NON_SOURCE_SELECTOR = "rt, rp, [data-wp-nondocument]"
const SEMANTIC_KINDS = new Set(["jiazhu", "pizhu"])
const OPEN = "〈"
const CLOSE = "〉"

const STYLE_ID = "fanya-word-processor-semantic-annotations-styles"

function ensureSemanticStyles(documentRef = document) {
  if (!documentRef?.head || documentRef.getElementById(STYLE_ID)) return
  const style = documentRef.createElement("style")
  style.id = STYLE_ID
  style.textContent = `
    .wp-source-annotation {
      position: relative;
      box-sizing: border-box;
      font-family: inherit;
      font-weight: inherit;
      font-style: inherit;
    }

    .wp-source-pizhu,
    .wp-pizhu-display {
      color: #b00000;
    }

    .wp-source-pizhu {
      display: inline;
      white-space: pre-wrap;
      cursor: text;
    }

    .wp-semantic-editor {
      display: none;
      position: absolute;
      z-index: 12;
      min-width: 5em;
      max-width: 28em;
      padding: 0.22em 0.36em;
      border: 1px solid currentColor;
      border-radius: 0.2em;
      outline: none;
      background: var(--site-surface, Canvas);
      color: inherit;
      font-family: inherit;
      font-size: max(12px, calc(var(--han-main-font-size, 20px) * 0.72));
      line-height: 1.3;
      letter-spacing: 0;
      white-space: pre;
      writing-mode: horizontal-tb !important;
      text-orientation: mixed;
      caret-color: currentColor;
      user-select: text;
    }

    .wp-source-pizhu .wp-semantic-editor {
      color: #b00000;
    }

    .wp-semantic-editor-pizhu {
      color: #b00000;
    }

    .wp-source-annotation.is-editing > .wp-semantic-editor {
      display: inline-block;
    }

    .wp-editor.is-vertical .wp-source-annotation > .wp-semantic-editor {
      left: 50%;
      top: 50%;
      transform: translate(-50%, -50%);
      transform-origin: center;
    }

    .wp-editor:not(.is-vertical) .wp-source-annotation > .wp-semantic-editor {
      left: 0;
      top: 100%;
    }

    .wp-semantic-remove {
      display: none;
      position: absolute;
      z-index: 13;
      width: 1.15rem;
      height: 1.15rem;
      padding: 0;
      border: 1px solid currentColor;
      border-radius: 50%;
      background: var(--site-surface, Canvas);
      color: inherit;
      font: inherit;
      font-size: 0.72rem;
      line-height: 1;
      cursor: pointer;
    }

    .wp-source-annotation.is-editing > .wp-semantic-remove {
      display: inline-grid;
      place-items: center;
    }

    .wp-editor.is-vertical .wp-source-annotation > .wp-semantic-remove {
      right: -0.55rem;
      top: -0.65rem;
    }

    .wp-editor:not(.is-vertical) .wp-source-annotation > .wp-semantic-remove {
      left: -0.55rem;
      top: 0.55rem;
    }
  `
  documentRef.head.appendChild(style)
}

function clamp(value, min, max) {
  return Math.max(min, Math.min(max, Number(value) || 0))
}

function isSemantic(annotation) {
  return !!annotation && SEMANTIC_KINDS.has(String(annotation.kind || ""))
}

function semanticRange(annotation, textLength) {
  const start = clamp(annotation?.start, 0, textLength)
  const end = clamp(annotation?.end, start, textLength)
  return { start, end }
}

function validSemanticSource(text, annotation) {
  const { start, end } = semanticRange(annotation, String(text || "").length)
  if (end - start < 2) return false
  const raw = String(text || "").slice(start, end)
  return raw.startsWith(OPEN) && raw.endsWith(CLOSE)
}

export function insertBoundaryTextModel(text, annotations, at, value) {
  const source = String(text || "")
  const position = clamp(at, 0, source.length)
  const inserted = String(value || "")
  if (!inserted) return { text: source, annotations: Array.from(annotations || []) }
  const delta = inserted.length
  const mapped = Array.from(annotations || []).map((annotation) => {
    const start = Number(annotation?.start)
    const end = Number(annotation?.end)
    if (!Number.isFinite(start) || !Number.isFinite(end)) return annotation
    if (start >= position) return { ...annotation, start: start + delta, end: end + delta }
    if (end > position) return { ...annotation, end: end + delta }
    return annotation
  })
  return {
    text: source.slice(0, position) + inserted + source.slice(position),
    annotations: mapped,
  }
}

function annotationRaw(text, annotation) {
  const { start, end } = semanticRange(annotation, String(text || "").length)
  return String(text || "").slice(start, end)
}

function annotationInner(text, annotation) {
  const raw = annotationRaw(text, annotation)
  return raw.startsWith(OPEN) && raw.endsWith(CLOSE) ? raw.slice(OPEN.length, -CLOSE.length) : raw
}

function serializedFragmentText(root) {
  if (!root) return ""
  const clone = root.cloneNode(true)
  clone.querySelectorAll(SOURCE_SELECTOR).forEach((element) => {
    element.replaceWith(clone.ownerDocument.createTextNode(element.dataset.wpSourceText || ""))
  })
  clone.querySelectorAll(NON_SOURCE_SELECTOR).forEach((element) => element.remove())
  return clone.textContent || ""
}

function sourceLengthOfNode(node) {
  if (!node) return 0
  if (node.nodeType === Node.TEXT_NODE) return (node.nodeValue || "").length
  if (node.nodeType !== Node.ELEMENT_NODE) return 0
  if (node.matches?.(SOURCE_SELECTOR)) return String(node.dataset.wpSourceText || "").length
  if (node.matches?.(NON_SOURCE_SELECTOR) || node.closest?.(SOURCE_SELECTOR)) return 0
  return Array.from(node.childNodes || []).reduce((sum, child) => sum + sourceLengthOfNode(child), 0)
}

function topLevelChildUnder(root, node) {
  let current = node
  while (current?.parentNode && current.parentNode !== root) current = current.parentNode
  return current
}

function pointBefore(node) {
  return { node: node.parentNode, offset: Array.prototype.indexOf.call(node.parentNode.childNodes, node) }
}

function pointAfter(node) {
  return { node: node.parentNode, offset: Array.prototype.indexOf.call(node.parentNode.childNodes, node) + 1 }
}

function pointForSourceOffset(root, wanted) {
  const target = Math.max(0, Number(wanted) || 0)
  let consumed = 0
  let lastText = null

  const visit = (node) => {
    if (!node) return null
    if (node.nodeType === Node.TEXT_NODE) {
      const length = (node.nodeValue || "").length
      lastText = node
      if (target <= consumed + length) {
        const point = { node, offset: Math.max(0, target - consumed) }
        consumed += length
        return point
      }
      consumed += length
      return null
    }
    if (node.nodeType !== Node.ELEMENT_NODE) return null
    if (node.matches?.(SOURCE_SELECTOR)) {
      const length = String(node.dataset.wpSourceText || "").length
      if (target <= consumed) return pointBefore(node)
      if (target >= consumed + length) {
        consumed += length
        return target === consumed ? pointAfter(node) : null
      }
      // The main caret never lives inside the presentation object. An offset
      // within its source-backed range is resolved to the nearest boundary;
      // clicking the object itself opens its horizontal editor.
      const local = target - consumed
      const point = local <= length / 2 ? pointBefore(node) : pointAfter(node)
      consumed += length
      return point
    }
    if (node.matches?.(NON_SOURCE_SELECTOR) || node.closest?.(SOURCE_SELECTOR)) return null
    for (const child of Array.from(node.childNodes || [])) {
      const point = visit(child)
      if (point) return point
    }
    return null
  }

  for (const child of Array.from(root.childNodes || [])) {
    const point = visit(child)
    if (point) return point
  }

  if (lastText) return { node: lastText, offset: (lastText.nodeValue || "").length }
  return { node: root, offset: root.childNodes.length }
}

function sourceOffsetForPoint(root, node, offset) {
  try {
    const range = root.ownerDocument.createRange()
    range.selectNodeContents(root)
    range.setEnd(node, offset)
    const holder = root.ownerDocument.createElement("div")
    holder.appendChild(range.cloneContents())
    return serializedFragmentText(holder).length
  } catch (_error) {
    return 0
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

function editableSelectionOffsets(element) {
  const selection = element?.ownerDocument?.defaultView?.getSelection?.() || window.getSelection?.()
  if (!selection || selection.rangeCount === 0) return null
  const range = selection.getRangeAt(0)
  if (!element.contains(range.startContainer) || !element.contains(range.endContainer)) return null
  const measure = (container, offset) => {
    const prefix = element.ownerDocument.createRange()
    prefix.selectNodeContents(element)
    prefix.setEnd(container, offset)
    const holder = element.ownerDocument.createElement("div")
    holder.appendChild(prefix.cloneContents())
    return holder.textContent.length
  }
  const a = measure(range.startContainer, range.startOffset)
  const b = measure(range.endContainer, range.endOffset)
  return { start: Math.min(a, b), end: Math.max(a, b) }
}

function commonDiff(oldValue, newValue) {
  let prefix = 0
  const maxPrefix = Math.min(oldValue.length, newValue.length)
  while (prefix < maxPrefix && oldValue[prefix] === newValue[prefix]) prefix += 1

  let suffix = 0
  const oldRemaining = oldValue.length - prefix
  const newRemaining = newValue.length - prefix
  while (suffix < oldRemaining && suffix < newRemaining && oldValue[oldValue.length - 1 - suffix] === newValue[newValue.length - 1 - suffix]) suffix += 1

  return {
    oldStart: prefix,
    oldEnd: oldValue.length - suffix,
    newStart: prefix,
    newEnd: newValue.length - suffix,
  }
}

function nestedPizhuRows(chapter, parent) {
  const innerStart = Number(parent.start) + 1
  const innerEnd = Number(parent.end) - 1
  return (chapter.annotations || [])
    .filter((annotation) => annotation.kind === "pizhu"
      && Number(annotation.start) >= innerStart
      && Number(annotation.end) <= innerEnd)
    .map((annotation) => ({
      id: annotation.id,
      start: Number(annotation.start) - innerStart,
      end: Number(annotation.end) - innerStart,
    }))
}

function styleSemanticEditor(editor, chapter, annotation) {
  const inner = annotationInner(chapter.text, annotation)
  editor.replaceChildren()

  if (annotation.kind !== "jiazhu") {
    editor.appendChild(editor.ownerDocument.createTextNode(inner))
    return
  }

  const rows = nestedPizhuRows(chapter, annotation).sort((a, b) => a.start - b.start)
  let cursor = 0
  rows.forEach((row) => {
    const start = clamp(row.start, cursor, inner.length)
    const end = clamp(row.end, start, inner.length)
    if (start > cursor) editor.appendChild(editor.ownerDocument.createTextNode(inner.slice(cursor, start)))
    if (end > start) {
      const span = editor.ownerDocument.createElement("span")
      span.className = "wp-semantic-editor-pizhu"
      span.dataset.pizhuId = String(row.id || "")
      span.textContent = inner.slice(start, end)
      editor.appendChild(span)
    }
    cursor = end
  })
  if (cursor < inner.length) editor.appendChild(editor.ownerDocument.createTextNode(inner.slice(cursor)))
}

function semanticIdFromElement(element) {
  return element?.dataset?.wpSourceAnnotationId || ""
}

export function installWordProcessorSemanticAnnotations(ControllerClass) {
  const prototype = ControllerClass?.prototype
  if (!prototype || prototype[INSTALL_KEY]) return
  prototype[INSTALL_KEY] = true

  ensureJiagzhuStyles()
  ensureSemanticStyles()

  const priorConnect = prototype.connect
  const priorRenderEditor = prototype.renderEditor
  const priorRenderNotes = prototype.renderNotes
  const priorEditorPlainText = prototype.editorPlainText
  const priorOffsetForPoint = prototype.offsetForPoint
  const priorPointForOffset = prototype.pointForOffset
  const priorContextMenu = prototype.contextMenu
  const priorEditorKeydown = prototype.editorKeydown
  const priorDeleteNote = prototype.deleteNote
  const priorEditNote = prototype.editNote
  const priorSyncEditorToModel = prototype.syncEditorToModel

  prototype.connect = async function(...args) {
    const result = await priorConnect.apply(this, args)
    this.wpSemanticNormaliseDocument()
    if (this.wpHistory && typeof this.wpCaptureHistorySnapshot === "function") {
      this.wpHistory.undo = []
      this.wpHistory.redo = []
      this.wpHistory.baseline = this.wpCaptureHistorySnapshot()
      this.wpUpdateHistoryButtons?.()
    }
    this.renderEditor({ start: this.activeChapter()?.text?.length || 0, end: this.activeChapter()?.text?.length || 0 })
    this.renderNotes()
    this.scheduleAutosave?.()
    return result
  }

  prototype.wpSemanticNormaliseDocument = function() {
    if (!this.document?.chapters) return
    this.document.chapters.forEach((chapter) => {
      chapter.annotations ||= []
      this.wpSemanticMigrateLegacyChapter(chapter)
      this.wpSemanticPruneInvalid(chapter)
    })
  }

  prototype.wpSemanticMigrateLegacyChapter = function(chapter) {
    const legacy = (chapter.annotations || []).filter((annotation) =>
      ["note", "comment"].includes(String(annotation.kind || ""))
    )
    if (!legacy.length) return

    const childrenByParent = new Map()
    legacy.filter((annotation) => annotation.parentAnnotationId).forEach((annotation) => {
      const key = String(annotation.parentAnnotationId)
      const rows = childrenByParent.get(key) || []
      rows.push(annotation)
      childrenByParent.set(key, rows)
    })

    const roots = legacy.filter((annotation) => !annotation.parentAnnotationId)
      .map((annotation) => ({ ...annotation, anchor: clamp(annotation.anchor ?? annotation.end ?? annotation.start, 0, chapter.text.length) }))
      .sort((a, b) => b.anchor - a.anchor)

    const legacyIds = new Set(legacy.map((annotation) => String(annotation.id)))
    chapter.annotations = (chapter.annotations || []).filter((annotation) => !legacyIds.has(String(annotation.id)))

    roots.forEach((annotation) => {
      const baseInner = String(annotation.note || "")
      const children = (childrenByParent.get(String(annotation.id)) || [])
        .map((child) => ({ ...child, at: clamp(child.innerEnd ?? child.innerStart, 0, baseInner.length) }))
        .sort((a, b) => a.at - b.at)

      let inner = ""
      let cursor = 0
      const childRanges = []
      children.forEach((child) => {
        const at = Math.max(cursor, child.at)
        inner += baseInner.slice(cursor, at)
        const childStart = inner.length
        const childRaw = `${OPEN}${String(child.note || "")}${CLOSE}`
        inner += childRaw
        childRanges.push({
          id: child.id || this.uuid("annotation"),
          start: childStart,
          end: childStart + childRaw.length,
        })
        cursor = at
      })
      inner += baseInner.slice(cursor)

      const raw = `${OPEN}${inner}${CLOSE}`
      const at = clamp(annotation.anchor, 0, chapter.text.length)
      this.wpSemanticInsertBoundaryText(chapter, at, raw)
      const rootId = annotation.id || this.uuid("annotation")
      chapter.annotations.push({
        id: rootId,
        kind: annotation.kind === "note" ? "jiazhu" : "pizhu",
        start: at,
        end: at + raw.length,
      })
      if (annotation.kind === "note") {
        childRanges.forEach((child) => {
          chapter.annotations.push({
            id: child.id,
            kind: "pizhu",
            start: at + 1 + child.start,
            end: at + 1 + child.end,
          })
        })
      }
    })
  }

  prototype.wpSemanticPruneInvalid = function(chapter = this.activeChapter()) {
    if (!chapter) return
    chapter.annotations = (chapter.annotations || []).filter((annotation) => !isSemantic(annotation) || validSemanticSource(chapter.text, annotation))
  }

  prototype.wpSemanticAnnotationById = function(annotationId) {
    const chapter = this.activeChapter()
    if (!chapter) return null
    return (chapter.annotations || []).find((annotation) => String(annotation.id) === String(annotationId)) || null
  }

  prototype.wpSemanticInsertBoundaryText = function(chapter, at, value) {
    const result = insertBoundaryTextModel(chapter.text, chapter.annotations, at, value)
    chapter.text = result.text
    chapter.annotations = result.annotations
  }

  prototype.wpSemanticWrapRange = function(kind, range) {
    const chapter = this.activeChapter()
    if (!chapter || !SEMANTIC_KINDS.has(kind)) return null
    const start = clamp(range?.start, 0, chapter.text.length)
    const end = clamp(range?.end, start, chapter.text.length)

    // Insert the closing delimiter first, then the opening delimiter. Boundary
    // insertion uses right affinity: ranges ending exactly at the insertion
    // point stay before it, while ranges beginning there move with the text
    // that follows. This makes wrapping selected text preserve nested metadata.
    this.wpSemanticInsertBoundaryText(chapter, end, CLOSE)
    this.wpSemanticInsertBoundaryText(chapter, start, OPEN)

    const annotation = {
      id: this.uuid("annotation"),
      kind,
      start,
      end: end + 2,
    }
    chapter.annotations.push(annotation)
    this.wpSemanticPruneInvalid(chapter)
    this.scheduleAutosave()
    return annotation
  }

  prototype.wpSemanticRemove = function(annotationId, { focus = true } = {}) {
    const chapter = this.activeChapter()
    const annotation = this.wpSemanticAnnotationById(annotationId)
    if (!chapter || !annotation || !isSemantic(annotation)) return false
    const { start, end } = semanticRange(annotation, chapter.text.length)
    this.wpSemanticActive = null
    this.replaceRange(chapter, start, end, "", { render: false })
    chapter.annotations = (chapter.annotations || []).filter((item) => String(item.id) !== String(annotationId))
    this.wpSemanticPruneInvalid(chapter)
    this.renderEditor({ start, end: start })
    this.renderNotes()
    this.scheduleAutosave()
    if (focus) this.editorTarget.focus({ preventScroll: true })
    return true
  }

  prototype.wpSemanticUpdateInner = function(annotationId, newInner) {
    const chapter = this.activeChapter()
    const annotation = this.wpSemanticAnnotationById(annotationId)
    if (!chapter || !annotation || !isSemantic(annotation) || !validSemanticSource(chapter.text, annotation)) return false
    const oldInner = annotationInner(chapter.text, annotation)
    const next = String(newInner || "").replace(/[\r\n]+/g, "")
    if (oldInner === next) return true

    const local = commonDiff(oldInner, next)
    const absoluteStart = Number(annotation.start) + 1 + local.oldStart
    const absoluteEnd = Number(annotation.start) + 1 + local.oldEnd
    const replacement = next.slice(local.newStart, local.newEnd)
    this.replaceRange(chapter, absoluteStart, absoluteEnd, replacement, { render: false })
    this.wpSemanticPruneInvalid(chapter)
    this.renderNotes()
    this.scheduleAutosave()
    return true
  }

  prototype.wpSemanticOpen = function(annotationId, where = "end") {
    const annotation = this.wpSemanticAnnotationById(annotationId)
    if (!annotation || !isSemantic(annotation)) return false
    this.wpSemanticActive = { annotationId: String(annotationId), kind: annotation.kind }
    this.renderEditor({ start: Number(annotation.end), end: Number(annotation.end) })
    const outer = this.editorTarget.querySelector(`${SOURCE_SELECTOR}[data-wp-source-annotation-id="${CSS.escape(String(annotationId))}"]`)
    const editor = outer?.querySelector?.(".wp-semantic-editor")
    if (!outer || !editor) return false
    outer.classList.add("is-editing")
    editor.focus({ preventScroll: true })
    setEditableCaret(editor, where)
    return true
  }

  prototype.wpSemanticClose = function({ caret = "after", annotationId = null } = {}) {
    const activeId = annotationId || this.wpSemanticActive?.annotationId
    const annotation = this.wpSemanticAnnotationById(activeId)
    if (!annotation) {
      this.wpSemanticActive = null
      return false
    }
    const target = caret === "before" ? Number(annotation.start) : Number(annotation.end)
    this.wpSemanticActive = null
    this.renderEditor({ start: target, end: target })
    this.editorTarget.focus({ preventScroll: true })
    return true
  }

  prototype.wpSemanticCreateEditor = function(annotation, outer) {
    const chapter = this.activeChapter()
    const editor = document.createElement("span")
    editor.className = "wp-semantic-editor"
    editor.contentEditable = "true"
    editor.setAttribute("role", "textbox")
    editor.setAttribute("aria-multiline", "false")
    editor.setAttribute("aria-label", annotation.kind === "jiazhu" ? "Edit 夾注" : "Edit 批注")
    editor.spellcheck = false
    styleSemanticEditor(editor, chapter, annotation)

    const remove = document.createElement("button")
    remove.type = "button"
    remove.className = "wp-semantic-remove"
    remove.textContent = "×"
    remove.setAttribute("aria-label", annotation.kind === "jiazhu" ? "Remove 夾注" : "Remove 批注")

    const activate = () => {
      this.wpSemanticActive = { annotationId: String(annotation.id), kind: annotation.kind }
      outer.classList.add("is-editing")
    }

    editor.addEventListener("focus", activate)
    editor.addEventListener("input", () => {
      this.wpSemanticUpdateInner(annotation.id, editor.textContent || "")
      const live = this.wpSemanticAnnotationById(annotation.id)
      if (!live) return
      outer.dataset.wpSourceText = annotationRaw(chapter.text, live)
      outer.dataset.wpSourceStart = String(live.start)
      outer.dataset.wpSourceEnd = String(live.end)
      if (live.kind === "jiazhu") {
        updateJiagzhuColumnsFromSource(outer, annotationInner(chapter.text, live), {
          marks: nestedPizhuRows(chapter, live),
        })
      } else {
        const display = outer.querySelector(".wp-pizhu-display")
        if (display) display.textContent = annotationRaw(chapter.text, live)
      }
    })
    editor.addEventListener("keydown", (event) => {
      const offsets = editableSelectionOffsets(editor) || { start: 0, end: 0 }
      const length = (editor.textContent || "").length
      const vertical = this.document.settings.vertical !== false
      const forwardKey = vertical ? "ArrowDown" : "ArrowRight"
      const backwardKey = vertical ? "ArrowUp" : "ArrowLeft"

      if (event.key === "Enter") {
        event.preventDefault()
        event.stopPropagation()
        const live = this.wpSemanticAnnotationById(annotation.id)
        if (!live) return
        this.wpSemanticActive = null
        this.renderEditor({ start: Number(live.end), end: Number(live.end) })
        this.insertTextAtSelection("\n", { convert: false, range: { start: Number(live.end), end: Number(live.end) } })
        return
      }

      if (event.key === forwardKey && offsets.end === length && offsets.start === offsets.end) {
        event.preventDefault()
        event.stopPropagation()
        this.wpSemanticClose({ caret: "after", annotationId: annotation.id })
        return
      }
      if (event.key === backwardKey && offsets.start === 0 && offsets.start === offsets.end) {
        event.preventDefault()
        event.stopPropagation()
        this.wpSemanticClose({ caret: "before", annotationId: annotation.id })
        return
      }
      if (event.key === "Backspace" && offsets.start === 0 && offsets.end === 0 && length === 0) {
        event.preventDefault()
        event.stopPropagation()
        this.wpSemanticRemove(annotation.id)
      }
    })
    editor.addEventListener("contextmenu", (event) => {
      if (annotation.kind !== "jiazhu") return
      event.preventDefault()
      event.stopPropagation()
      const offsets = editableSelectionOffsets(editor) || { start: 0, end: 0 }
      this.wpSemanticNestedContext = {
        parentAnnotationId: annotation.id,
        start: offsets.start,
        end: offsets.end,
      }
      this.savedContextRange = { start: Number(annotation.start) + 1 + offsets.start, end: Number(annotation.start) + 1 + offsets.end }
      const menu = this.contextMenuTarget
      menu.style.left = `${event.pageX}px`
      menu.style.top = `${event.pageY}px`
      menu.removeAttribute("hidden")
    })
    editor.addEventListener("blur", () => {
      window.requestAnimationFrame(() => {
        if (outer.contains(document.activeElement)) return
        this.wpSemanticActive = null
        outer.classList.remove("is-editing")
      })
    })

    remove.addEventListener("pointerdown", (event) => {
      event.preventDefault()
      event.stopPropagation()
    })
    remove.addEventListener("click", (event) => {
      event.preventDefault()
      event.stopPropagation()
      this.wpSemanticRemove(annotation.id)
    })

    return { editor, remove }
  }

  prototype.wpSemanticJiagzhuElement = function(annotation) {
    const chapter = this.activeChapter()
    const raw = annotationRaw(chapter.text, annotation)
    const inner = annotationInner(chapter.text, annotation)
    const { outer } = createJiagzhuContainer({
      owner: "word-processor-source",
      annotationId: annotation.id,
      contentEditable: false,
      ariaLabel: raw,
    })
    outer.classList.add("wp-source-annotation", "wp-source-jiazhu")
    outer.dataset.wpSourceAnnotation = "jiazhu"
    outer.dataset.wpSourceAnnotationId = String(annotation.id)
    outer.dataset.wpSourceText = raw
    outer.dataset.wpSourceStart = String(annotation.start)
    outer.dataset.wpSourceEnd = String(annotation.end)
    updateJiagzhuColumnsFromSource(outer, inner, { marks: nestedPizhuRows(chapter, annotation) })

    const { editor, remove } = this.wpSemanticCreateEditor(annotation, outer)
    outer.append(editor, remove)
    outer.addEventListener("click", (event) => {
      if (event.target.closest(".wp-semantic-editor, .wp-semantic-remove")) return
      event.preventDefault()
      event.stopPropagation()
      this.wpSemanticOpen(annotation.id, "end")
    })
    outer.addEventListener("contextmenu", (event) => {
      if (event.target.closest(".wp-semantic-editor")) return
      event.preventDefault()
      event.stopPropagation()
      this.wpSemanticOpen(annotation.id, "end")
    })
    if (String(this.wpSemanticActive?.annotationId || "") === String(annotation.id)) outer.classList.add("is-editing")
    return outer
  }

  prototype.wpSemanticPizhuElement = function(annotation) {
    const chapter = this.activeChapter()
    const raw = annotationRaw(chapter.text, annotation)
    const outer = document.createElement("span")
    outer.className = "wp-source-annotation wp-source-pizhu"
    outer.dataset.wpSourceAnnotation = "pizhu"
    outer.dataset.wpSourceAnnotationId = String(annotation.id)
    outer.dataset.wpSourceText = raw
    outer.dataset.wpSourceStart = String(annotation.start)
    outer.dataset.wpSourceEnd = String(annotation.end)
    outer.contentEditable = "false"

    const display = document.createElement("span")
    display.className = "wp-pizhu-display"
    display.textContent = raw
    outer.appendChild(display)

    const { editor, remove } = this.wpSemanticCreateEditor(annotation, outer)
    outer.append(editor, remove)
    outer.addEventListener("click", (event) => {
      if (event.target.closest(".wp-semantic-editor, .wp-semantic-remove")) return
      event.preventDefault()
      event.stopPropagation()
      this.wpSemanticOpen(annotation.id, "end")
    })
    outer.addEventListener("contextmenu", (event) => {
      if (event.target.closest(".wp-semantic-editor")) return
      event.preventDefault()
      event.stopPropagation()
      this.wpSemanticOpen(annotation.id, "end")
    })
    if (String(this.wpSemanticActive?.annotationId || "") === String(annotation.id)) outer.classList.add("is-editing")
    return outer
  }

  prototype.wpSemanticReplaceDomRange = function(annotation, element) {
    const startPoint = pointForSourceOffset(this.editorTarget, Number(annotation.start))
    const endPoint = pointForSourceOffset(this.editorTarget, Number(annotation.end))
    if (!startPoint?.node || !endPoint?.node) return false
    try {
      const range = document.createRange()
      range.setStart(startPoint.node, startPoint.offset)
      range.setEnd(endPoint.node, endPoint.offset)
      range.deleteContents()
      range.insertNode(element)
      return true
    } catch (_error) {
      return false
    }
  }

  prototype.wpSemanticRender = function() {
    const chapter = this.activeChapter()
    if (!chapter) return
    this.wpSemanticPruneInvalid(chapter)

    const semantic = (chapter.annotations || []).filter((annotation) => isSemantic(annotation) && validSemanticSource(chapter.text, annotation))
    const jiazhu = semantic.filter((annotation) => annotation.kind === "jiazhu")
    const topLevel = semantic.filter((annotation) => !jiazhu.some((parent) =>
      String(parent.id) !== String(annotation.id)
      && Number(annotation.start) >= Number(parent.start) + 1
      && Number(annotation.end) <= Number(parent.end) - 1
    ))

    topLevel.sort((a, b) => Number(b.start) - Number(a.start) || Number(b.end) - Number(a.end)).forEach((annotation) => {
      const element = annotation.kind === "jiazhu"
        ? this.wpSemanticJiagzhuElement(annotation)
        : this.wpSemanticPizhuElement(annotation)
      this.wpSemanticReplaceDomRange(annotation, element)
    })
  }

  prototype.renderEditor = function(selection = null) {
    const result = priorRenderEditor.call(this, selection)
    this.wpSemanticRender()
    const chapter = this.activeChapter()
    const requested = selection || { start: chapter?.text?.length || 0, end: chapter?.text?.length || 0 }
    this.restoreSelection(requested)
    if (this.wpSemanticActive?.annotationId) {
      const active = this.wpSemanticAnnotationById(this.wpSemanticActive.annotationId)
      const outer = active ? this.editorTarget.querySelector(`${SOURCE_SELECTOR}[data-wp-source-annotation-id="${CSS.escape(String(active.id))}"]`) : null
      const editor = outer?.querySelector?.(".wp-semantic-editor")
      if (outer && editor && document.activeElement === this.editorTarget) {
        outer.classList.add("is-editing")
      }
    }
    return result
  }

  prototype.editorPlainText = function() {
    try {
      return serializedFragmentText(this.editorTarget)
    } catch (_error) {
      return priorEditorPlainText.call(this)
    }
  }

  prototype.offsetForPoint = function(node, offset) {
    if (this.editorTarget?.contains(node) || node === this.editorTarget) return sourceOffsetForPoint(this.editorTarget, node, offset)
    return priorOffsetForPoint.call(this, node, offset)
  }

  prototype.pointForOffset = function(wanted) {
    if (this.editorTarget) return pointForSourceOffset(this.editorTarget, wanted)
    return priorPointForOffset.call(this, wanted)
  }

  prototype.wpSemanticAdd = function(kind) {
    const chapter = this.activeChapter()
    if (!chapter) return

    let range = this.savedContextRange || this.captureSelectionRange() || { start: chapter.text.length, end: chapter.text.length }
    let nestedParentId = null
    if (kind === "pizhu" && this.wpSemanticNestedContext) {
      const parent = this.wpSemanticAnnotationById(this.wpSemanticNestedContext.parentAnnotationId)
      if (parent?.kind === "jiazhu") {
        nestedParentId = String(parent.id)
        range = {
          start: Number(parent.start) + 1 + Number(this.wpSemanticNestedContext.start || 0),
          end: Number(parent.start) + 1 + Number(this.wpSemanticNestedContext.end || 0),
        }
      }
    }

    this.closeContextMenu()
    this.savedContextRange = null
    this.wpSemanticNestedContext = null
    // A selected passage is the anchor/context for the annotation. The 〈…〉
    // itself is inserted after that passage, matching forms such as
    // 東〈徳紅切…〉 and 作「五常」〈案…〉.
    const insertionPoint = Math.max(Number(range.start) || 0, Number(range.end) || 0)
    const annotation = this.wpSemanticWrapRange(kind, { start: insertionPoint, end: insertionPoint })
    if (!annotation) return
    this.renderEditor({ start: Number(annotation.end), end: Number(annotation.end) })
    this.renderNotes()
    window.requestAnimationFrame(() => {
      if (nestedParentId) this.wpSemanticOpen(nestedParentId, "end")
      else this.wpSemanticOpen(annotation.id, "end")
    })
  }

  prototype.addNote = function() {
    this.wpSemanticAdd("jiazhu")
  }

  prototype.addComment = function() {
    this.wpSemanticAdd("pizhu")
  }

  prototype.contextMenu = function(event) {
    const semanticEditor = event.target?.closest?.(".wp-semantic-editor")
    if (!semanticEditor) {
      this.wpSemanticNestedContext = null
      return priorContextMenu.call(this, event)
    }

    const outer = semanticEditor.closest(SOURCE_SELECTOR)
    const annotation = this.wpSemanticAnnotationById(semanticIdFromElement(outer))
    if (!annotation || annotation.kind !== "jiazhu") return priorContextMenu.call(this, event)

    event.preventDefault()
    event.stopPropagation()
    const offsets = editableSelectionOffsets(semanticEditor) || { start: 0, end: 0 }
    this.wpSemanticNestedContext = { parentAnnotationId: annotation.id, start: offsets.start, end: offsets.end }
    this.savedContextRange = {
      start: Number(annotation.start) + 1 + offsets.start,
      end: Number(annotation.start) + 1 + offsets.end,
    }
    const menu = this.contextMenuTarget
    menu.style.left = `${event.pageX}px`
    menu.style.top = `${event.pageY}px`
    menu.removeAttribute("hidden")
  }

  prototype.syncEditorToModel = function(...args) {
    const result = priorSyncEditorToModel.apply(this, args)
    this.wpSemanticPruneInvalid()
    this.renderNotes()
    return result
  }

  prototype.editorKeydown = function(event) {
    if (event.target?.closest?.(".wp-semantic-editor")) return
    if (!this.numeralComposition) {
      const range = this.captureSelectionRange()
      if (range && range.start === range.end) {
        const chapter = this.activeChapter()
        const semantic = (chapter?.annotations || []).filter((annotation) => isSemantic(annotation))
        if (event.key === "Backspace") {
          const previous = semantic.find((annotation) => Number(annotation.end) === Number(range.start))
          if (previous) {
            event.preventDefault()
            event.stopPropagation()
            this.wpSemanticOpen(previous.id, "end")
            return
          }
        }
        const vertical = this.document.settings.vertical !== false
        const forwardKey = vertical ? "ArrowDown" : "ArrowRight"
        if (event.key === forwardKey) {
          const next = semantic.find((annotation) => Number(annotation.start) === Number(range.start))
          if (next) {
            event.preventDefault()
            event.stopPropagation()
            this.wpSemanticOpen(next.id, "start")
            return
          }
        }
      }
    }
    return priorEditorKeydown.call(this, event)
  }

  prototype.renderNotes = function() {
    const result = priorRenderNotes.call(this)
    const chapter = this.activeChapter()
    if (!chapter || !this.hasNotesListTarget) return result

    // Remove legacy rows for point-based Note/Comment objects. Semantic 夾注
    // and 批注 are represented by real text ranges and get explicit rows here.
    this.notesListTarget.querySelectorAll("[data-wp-semantic-note-row]").forEach((row) => row.remove())
    const rows = (chapter.annotations || []).filter((annotation) => isSemantic(annotation) && validSemanticSource(chapter.text, annotation))
    rows.forEach((annotation) => {
      const row = document.createElement("div")
      row.className = "wp-note-row"
      row.dataset.wpSemanticNoteRow = "true"
      const label = document.createElement("span")
      label.textContent = `${annotation.kind === "jiazhu" ? "夾注" : "批注"}: ${annotationInner(chapter.text, annotation).slice(0, 24)}`
      const edit = document.createElement("button")
      edit.type = "button"
      edit.className = "wp-mini-button"
      edit.textContent = "Edit"
      edit.addEventListener("click", () => this.wpSemanticOpen(annotation.id, "end"))
      const remove = document.createElement("button")
      remove.type = "button"
      remove.className = "wp-mini-button"
      remove.textContent = "Remove"
      remove.addEventListener("click", () => this.wpSemanticRemove(annotation.id))
      row.append(label, edit, remove)
      this.notesListTarget.appendChild(row)
    })
    return result
  }

  prototype.editNote = function(event) {
    const annotationId = event?.currentTarget?.dataset?.annotationId
    const annotation = this.wpSemanticAnnotationById(annotationId)
    if (annotation && isSemantic(annotation)) return this.wpSemanticOpen(annotation.id, "end")
    return priorEditNote.call(this, event)
  }

  prototype.deleteNote = function(event) {
    const annotationId = event?.currentTarget?.dataset?.annotationId
    const annotation = this.wpSemanticAnnotationById(annotationId)
    if (annotation && isSemantic(annotation)) return this.wpSemanticRemove(annotation.id)
    return priorDeleteNote.call(this, event)
  }
}

export {
  annotationInner,
  commonDiff,
  pointForSourceOffset,
  serializedFragmentText,
  sourceOffsetForPoint,
  validSemanticSource,
}
