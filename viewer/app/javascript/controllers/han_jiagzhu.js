const STYLE_ID = "fanya-han-jiagzhu-styles"
const JIAGZHU_SELECTOR = "[data-han-jiagzhu]"

export function jiagzhuLayout(value) {
  const original = Array.from(String(value || ""))
  const padded = [...original]
  if (padded.length % 2 === 1) padded.push("\u3000")
  const half = padded.length / 2
  return {
    original: original.join(""),
    padded: padded.join(""),
    first: padded.slice(0, half).join(""),
    second: padded.slice(half).join(""),
    paddedOdd: original.length % 2 === 1,
  }
}

function codePointAnchor(value, utf16Anchor) {
  const source = String(value || "")
  const bounded = Math.max(0, Math.min(Number(utf16Anchor) || 0, source.length))
  return Array.from(source.slice(0, bounded)).length
}

export function jiagzhuTokenLayout(value, comments = []) {
  const source = Array.from(String(value || ""))
  const rows = Array.from(comments || [])
    .filter((row) => String(row?.note || "").length > 0)
    .map((row) => ({
      id: String(row?.id || ""),
      note: String(row.note || ""),
      anchor: codePointAnchor(value, row?.anchor),
    }))
    .sort((a, b) => a.anchor - b.anchor)

  const tokens = []
  for (let offset = 0; offset <= source.length; offset += 1) {
    rows.filter((row) => row.anchor === offset).forEach((row) => {
      Array.from(`〈${row.note}〉`).forEach((character) => {
        tokens.push({ character, kind: "comment", commentId: row.id })
      })
    })
    if (offset < source.length) tokens.push({ character: source[offset], kind: "text" })
  }

  const visibleLength = tokens.length
  if (tokens.length % 2 === 1) tokens.push({ character: "\u3000", kind: "padding" })
  const half = tokens.length / 2
  return {
    source: source.join(""),
    visible: tokens.filter((token) => token.kind !== "padding").map((token) => token.character).join(""),
    visibleLength,
    first: tokens.slice(0, half),
    second: tokens.slice(half),
    paddedOdd: visibleLength % 2 === 1,
  }
}


export function jiagzhuSourceTokenLayout(value, marks = []) {
  const source = String(value || "")
  const tokens = []
  let utf16Offset = 0
  const rows = Array.from(marks || []).map((mark) => ({
    id: String(mark?.id || ""),
    start: Math.max(0, Number(mark?.start) || 0),
    end: Math.max(0, Number(mark?.end) || 0),
  }))

  for (const character of Array.from(source)) {
    const length = character.length
    const matching = rows.find((row) => utf16Offset >= row.start && utf16Offset < row.end)
    tokens.push({
      character,
      kind: matching ? "comment" : "text",
      commentId: matching?.id || "",
    })
    utf16Offset += length
  }

  const visibleLength = tokens.length
  if (tokens.length % 2 === 1) tokens.push({ character: "\u3000", kind: "padding" })
  const half = tokens.length / 2
  return {
    source,
    visible: source,
    visibleLength,
    first: tokens.slice(0, half),
    second: tokens.slice(half),
    paddedOdd: visibleLength % 2 === 1,
  }
}

export function ensureJiagzhuStyles(documentRef = document) {
  if (!documentRef?.head || documentRef.getElementById(STYLE_ID)) return
  const style = documentRef.createElement("style")
  style.id = STYLE_ID
  style.textContent = `
    .han-jiagzhu {
      display: inline-flex;
      box-sizing: border-box;
      margin: 0;
      padding: 0;
      border: 0;
      font-family: inherit;
      font-weight: inherit;
      font-style: inherit;
      line-height: 1;
      vertical-align: baseline;
      white-space: normal;
      writing-mode: horizontal-tb;
      flex-direction: column;
      align-items: flex-start;
      justify-content: center;
    }

    .han-jiagzhu__column {
      box-sizing: border-box;
      margin: 0;
      padding: 0;
      border: 0;
      font-size: 0.5em;
      line-height: 1;
      letter-spacing: 0;
      white-space: pre;
      writing-mode: horizontal-tb;
      text-orientation: mixed;
    }

    .is-vertical .han-jiagzhu {
      /* Browser-tested atomic character frame: the outer box occupies exactly
         one main-glyph width, so its centreline is identical to surrounding
         Han. The two half-size columns are absolutely placed inside that frame
         and therefore cannot widen or displace the parent vertical line. */
      display: inline-block;
      position: relative;
      writing-mode: vertical-rl;
      text-orientation: upright;
      inline-size: var(--han-jiagzhu-inline-size, 0.5em);
      block-size: 1em;
      min-block-size: 1em;
      max-block-size: 1em;
      margin: 0;
      padding: 0;
      vertical-align: baseline;
      overflow: visible;
    }

    .is-vertical .han-jiagzhu__column {
      position: absolute;
      top: 0;
      height: 100%;
      width: 1em;
      writing-mode: vertical-rl;
      text-orientation: upright;
      line-height: 1;
    }

    .is-vertical .han-jiagzhu__column--first {
      right: 0;
      left: auto;
    }

    .is-vertical .han-jiagzhu__column--second {
      left: 0;
      right: auto;
    }

    .is-vertical.is-vflow-lr .han-jiagzhu__column--first {
      left: 0;
      right: auto;
    }

    .is-vertical.is-vflow-lr .han-jiagzhu__column--second {
      right: 0;
      left: auto;
    }

    .han-jiagzhu__comment {
      color: #b00000;
      font: inherit;
      line-height: inherit;
      white-space: pre;
    }

    .corpus-note-block.is-han-jiagzhu-source {
      font-size: inherit !important;
      line-height: inherit !important;
      column-count: initial !important;
      column-gap: normal !important;
      display: inline !important;
      white-space: normal;
    }

    .corpus-note-block.is-han-jiagzhu-source {
      position: relative;
    }

    /* Keep the serialized 〈〉 in the DOM/source for copying while removing
       their visual advance from the facsimile-like 夾注 presentation. */
    .corpus-note-block.is-han-jiagzhu-source .corpus-note-block {
      display: inline !important;
      font-size: inherit !important;
      line-height: inherit !important;
      column-count: initial !important;
      column-gap: normal !important;
      white-space: normal !important;
    }

    .corpus-note-block.is-han-jiagzhu-source > .note-bracket {
      position: absolute !important;
      inline-size: 1px !important;
      block-size: 1px !important;
      overflow: hidden !important;
      clip-path: inset(50%) !important;
      white-space: nowrap !important;
      margin: 0 !important;
      padding: 0 !important;
      border: 0 !important;
    }

    .han-jiagzhu__padding {
      user-select: none;
      pointer-events: none;
    }

    .han-jiagzhu--editable {
      position: relative;
      cursor: text;
    }

    .han-jiagzhu__editor {
      display: none;
      position: absolute;
      z-index: 6;
      box-sizing: border-box;
      min-width: 4em;
      max-width: 24em;
      padding: 0.18em 0.3em;
      border: 1px solid currentColor;
      border-radius: 0.2em;
      outline: none;
      background: var(--site-surface, Canvas);
      color: inherit;
      font-family: inherit;
      font-size: max(12px, calc(var(--han-main-font-size, 20px) * 0.72));
      font-weight: inherit;
      font-style: inherit;
      line-height: 1.25;
      letter-spacing: 0;
      white-space: pre;
      writing-mode: horizontal-tb;
      text-orientation: mixed;
      caret-color: currentColor;
      user-select: text;
    }

    .han-jiagzhu--editable.is-editing .han-jiagzhu__editor {
      display: inline-block;
    }

    .is-vertical .han-jiagzhu--editable .han-jiagzhu__editor {
      left: 50%;
      right: auto;
      top: 50%;
      transform: translate(-50%, -50%);
      transform-origin: center;
    }

    .wp-editor:not(.is-vertical) .han-jiagzhu--editable .han-jiagzhu__editor {
      left: 0;
      top: 100%;
    }

    .han-jiagzhu__remove {
      display: none;
      position: absolute;
      z-index: 7;
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

    .han-jiagzhu--editable.is-editing .han-jiagzhu__remove {
      display: inline-grid;
      place-items: center;
    }

    .is-vertical .han-jiagzhu--editable .han-jiagzhu__remove {
      right: -0.55rem;
      top: -0.65rem;
    }

    .wp-editor:not(.is-vertical) .han-jiagzhu--editable .han-jiagzhu__remove {
      left: -0.55rem;
      top: 0.55rem;
    }
  `
  documentRef.head.appendChild(style)
}

export function createJiagzhuContainer({
  documentRef = document,
  owner = "shared",
  anchor = null,
  annotationId = null,
  contentEditable = false,
  ariaLabel = "",
} = {}) {
  ensureJiagzhuStyles(documentRef)
  const outer = documentRef.createElement("span")
  outer.className = "han-jiagzhu"
  outer.dataset.hanJiagzhu = "true"
  outer.dataset.hanJiagzhuOwner = String(owner || "shared")
  if (anchor !== null && anchor !== undefined) outer.dataset.hanJiagzhuAnchor = String(anchor)
  if (annotationId !== null && annotationId !== undefined) outer.dataset.hanJiagzhuAnnotationId = String(annotationId)
  outer.contentEditable = contentEditable ? "true" : "false"
  outer.setAttribute("role", "note")
  if (ariaLabel) outer.setAttribute("aria-label", String(ariaLabel))

  const first = documentRef.createElement("span")
  first.className = "han-jiagzhu__column han-jiagzhu__column--first"
  first.setAttribute("aria-hidden", "true")

  const second = documentRef.createElement("span")
  second.className = "han-jiagzhu__column han-jiagzhu__column--second"
  second.setAttribute("aria-hidden", "true")

  outer.append(first, second)
  return { outer, first, second }
}

function appendJiagzhuTokens(target, tokens) {
  if (!target) return
  target.replaceChildren()
  let activeComment = null
  let activeCommentId = null

  const flushComment = () => {
    activeComment = null
    activeCommentId = null
  }

  Array.from(tokens || []).forEach((token) => {
    if (token.kind === "comment") {
      if (!activeComment || activeCommentId !== token.commentId) {
        activeComment = target.ownerDocument.createElement("span")
        activeComment.className = "han-jiagzhu__comment"
        activeComment.dataset.hanJiagzhuCommentId = String(token.commentId || "")
        activeComment.setAttribute("aria-hidden", "true")
        target.appendChild(activeComment)
        activeCommentId = token.commentId
      }
      activeComment.appendChild(target.ownerDocument.createTextNode(token.character))
      return
    }

    flushComment()
    if (token.kind === "padding") {
      const padding = target.ownerDocument.createElement("span")
      padding.className = "han-jiagzhu__padding"
      padding.dataset.hanJiagzhuPadding = "true"
      padding.textContent = token.character
      padding.setAttribute("aria-hidden", "true")
      target.appendChild(padding)
      return
    }
    target.appendChild(target.ownerDocument.createTextNode(token.character))
  })
}

export function updateJiagzhuColumns(element, value, { comments = [] } = {}) {
  if (!element) return null
  const layout = jiagzhuTokenLayout(value, comments)
  const first = element.querySelector?.(".han-jiagzhu__column--first")
  const second = element.querySelector?.(".han-jiagzhu__column--second")
  appendJiagzhuTokens(first, layout.first)
  appendJiagzhuTokens(second, layout.second)
  const rows = Math.max(1, layout.first.length)
  element.style?.setProperty("--han-jiagzhu-inline-size", `${rows * 0.5}em`)
  element.setAttribute?.("aria-label", layout.visible)
  return layout
}


export function updateJiagzhuColumnsFromSource(element, value, { marks = [] } = {}) {
  if (!element) return null
  const layout = jiagzhuSourceTokenLayout(value, marks)
  const first = element.querySelector?.(".han-jiagzhu__column--first")
  const second = element.querySelector?.(".han-jiagzhu__column--second")
  appendJiagzhuTokens(first, layout.first)
  appendJiagzhuTokens(second, layout.second)
  const rows = Math.max(1, layout.first.length)
  element.style?.setProperty("--han-jiagzhu-inline-size", `${rows * 0.5}em`)
  element.setAttribute?.("aria-label", layout.visible)
  return layout
}

export function createJiagzhuElement(value, options = {}) {
  const layout = jiagzhuLayout(value)
  const container = createJiagzhuContainer({ ...options, ariaLabel: layout.original })
  container.first.textContent = layout.first
  container.second.textContent = layout.second
  container.outer.style.setProperty("--han-jiagzhu-inline-size", `${Math.max(1, Array.from(layout.first).length) * 0.5}em`)
  return container.outer
}

export function removeJiagzhu(root, owner = null) {
  if (!root?.querySelectorAll) return
  root.querySelectorAll(JIAGZHU_SELECTOR).forEach((element) => {
    if (owner === null || element.dataset.hanJiagzhuOwner === String(owner)) element.remove()
  })
}

export function insertAtTextOffset(root, wanted, node, {
  excludeSelector = "rt, rp, [data-han-jiagzhu]",
} = {}) {
  if (!root || !node) return false
  const target = Math.max(0, Number(wanted) || 0)
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
    acceptNode: (textNode) => textNode.parentElement?.closest(excludeSelector)
      ? NodeFilter.FILTER_REJECT
      : NodeFilter.FILTER_ACCEPT,
  })

  let consumed = 0
  let last = null
  while (walker.nextNode()) {
    const textNode = walker.currentNode
    last = textNode
    const length = (textNode.nodeValue || "").length
    if (target <= consumed + length) {
      const localOffset = Math.max(0, target - consumed)
      let topLevel = textNode
      while (topLevel.parentNode && topLevel.parentNode !== root) topLevel = topLevel.parentNode

      if (localOffset === 0 && topLevel.parentNode === root) {
        root.insertBefore(node, topLevel)
      } else if (localOffset === length && topLevel.parentNode === root) {
        root.insertBefore(node, topLevel.nextSibling)
      } else {
        const range = document.createRange()
        range.setStart(textNode, localOffset)
        range.collapse(true)
        range.insertNode(node)
      }
      return true
    }
    consumed += length
  }

  if (last?.parentNode) {
    last.parentNode.insertBefore(node, last.nextSibling)
    return true
  }
  root.appendChild(node)
  return true
}

export function renderJiagzhuAtOffsets(root, rows, {
  owner = "shared",
  excludeSelector = "rt, rp, [data-han-jiagzhu]",
  includeEmpty = false,
  elementFactory = null,
} = {}) {
  if (!root) return
  removeJiagzhu(root, owner)
  const grouped = new Map()
  Array.from(rows || []).forEach((row) => {
    const note = String(row?.note ?? "")
    if (!includeEmpty && !note.trim()) return
    const anchor = Math.max(0, Number(row?.anchor) || 0)
    const group = grouped.get(anchor) || []
    group.push({ ...row, note, anchor })
    grouped.set(anchor, group)
  })

  Array.from(grouped.entries()).sort((a, b) => a[0] - b[0]).forEach(([anchor, entries]) => {
    const fragment = document.createDocumentFragment()
    entries.forEach((entry) => {
      const element = typeof elementFactory === "function"
        ? elementFactory(entry)
        : createJiagzhuElement(entry.note, {
            owner,
            anchor,
            annotationId: entry.annotationId,
            contentEditable: false,
          })
      if (element) fragment.appendChild(element)
    })
    insertAtTextOffset(root, anchor, fragment, { excludeSelector })
  })
}

function sourceUnitWeight(node) {
  if (!node) return 0
  if (node.nodeType === Node.TEXT_NODE) return Array.from(node.nodeValue || "").length
  if (node.nodeType !== Node.ELEMENT_NODE) return 0
  if (node.matches?.(".note-bracket")) return 0
  const indexed = node.matches?.(".cch")
    ? [node]
    : Array.from(node.querySelectorAll?.(".cch") || [])
  // Direct delimiters are excluded by the caller. Delimiters nested inside the
  // 夾注 are real serialized characters (for example an embedded 批注) and
  // therefore count toward the two-column balance.
  return Math.max(indexed.length, 1)
}

function sourceUnitText(node) {
  if (!node) return ""
  if (node.nodeType === Node.TEXT_NODE) return node.nodeValue || ""
  if (node.nodeType !== Node.ELEMENT_NODE || node.matches?.(".note-bracket")) return ""
  const indexed = node.matches?.(".cch")
    ? [node]
    : Array.from(node.querySelectorAll?.(".cch") || [])
  if (indexed.length === 0) return node.textContent || ""
  return indexed.map((span) => span.textContent || "").join("")
}

export function corpusInsertionBoundary(anchor, root) {
  if (!anchor) return null
  const ruby = typeof anchor.closest === "function" ? anchor.closest("ruby") : null
  if (ruby && (!root?.contains || root.contains(ruby))) return ruby
  return anchor
}

export function enhanceCorpusNoteBlock(block, { owner = "corpus-source-note" } = {}) {
  if (!block || block.dataset.hanJiagzhuSourceEnhanced === "true") return false
  const documentRef = block.ownerDocument || document
  ensureJiagzhuStyles(documentRef)

  const units = Array.from(block.childNodes).filter((node) => {
    if (node.nodeType === Node.TEXT_NODE) return (node.nodeValue || "").length > 0
    if (node.nodeType !== Node.ELEMENT_NODE) return false
    return !node.matches?.(".note-bracket")
  })
  if (units.length === 0) return false

  const sourceLength = units.reduce((sum, node) => sum + sourceUnitWeight(node), 0)
  if (sourceLength <= 0) return false
  const paddedLength = sourceLength + (sourceLength % 2)
  const targetFirst = paddedLength / 2
  const rawLabel = units.map((node) => sourceUnitText(node)).join("")
  const { outer, first, second } = createJiagzhuContainer({
    documentRef,
    owner,
    ariaLabel: rawLabel,
    contentEditable: false,
  })
  outer.dataset.hanJiagzhuSourceBlock = "true"
  outer.style.setProperty("--han-jiagzhu-inline-size", `${Math.max(1, targetFirst) * 0.5}em`)

  let consumed = 0
  units.forEach((node) => {
    const weight = sourceUnitWeight(node)
    const target = consumed < targetFirst ? first : second
    target.appendChild(node)
    consumed += weight
  })

  if (sourceLength % 2 === 1) {
    const padding = documentRef.createElement("span")
    padding.className = "han-jiagzhu__padding"
    padding.dataset.hanJiagzhuPadding = "true"
    padding.textContent = "\u3000"
    padding.setAttribute("aria-hidden", "true")
    second.appendChild(padding)
  }

  const closingBracket = Array.from(block.children).find((child) => child.matches?.(".note-bracket") && child !== block.firstElementChild)
  if (closingBracket) block.insertBefore(outer, closingBracket)
  else block.appendChild(outer)

  block.classList.add("is-han-jiagzhu-source")
  block.dataset.hanJiagzhuSourceEnhanced = "true"
  return true
}

export function enhanceCorpusNoteBlocks(root, options = {}) {
  if (!root?.querySelectorAll) return 0
  let count = 0
  const selector = ".corpus-note-block.corpus-note-angle, .corpus-note-block[data-note-kind=\"angle\"]"
  Array.from(root.querySelectorAll(selector))
    .filter((block) => !block.parentElement?.closest?.(selector))
    .forEach((block) => {
      if (enhanceCorpusNoteBlock(block, options)) count += 1
    })
  return count
}

export function renderJiagzhuAfterCorpusSpans(root, items, { owner = "corpus-annotations" } = {}) {
  if (!root) return
  removeJiagzhu(root, owner)
  const groups = new Map()
  Array.from(items || []).forEach((item, index) => {
    const note = String(item?.note || "").trim()
    const end = Number(item?.end)
    if (!note || !Number.isFinite(end) || end <= 0) return
    const anchorIndex = end - 1
    const group = groups.get(anchorIndex) || []
    group.push({ note, index, annotationId: item?.id ?? index })
    groups.set(anchorIndex, group)
  })

  groups.forEach((entries, anchorIndex) => {
    const anchor = root.querySelector(`span.cch[data-corpus-idx="${CSS.escape(String(anchorIndex))}"]`)
    if (!anchor) return
    const fragment = document.createDocumentFragment()
    entries.forEach((entry) => fragment.appendChild(createJiagzhuElement(entry.note, {
      owner,
      anchor: anchorIndex + 1,
      annotationId: entry.annotationId,
      contentEditable: false,
    })))
    const insertionBoundary = corpusInsertionBoundary(anchor, root)
    insertionBoundary.after(fragment)
  })
}
