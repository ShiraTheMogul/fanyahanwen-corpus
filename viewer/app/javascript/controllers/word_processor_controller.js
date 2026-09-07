import { Controller } from "@hotwired/stimulus"
import { t } from "i18n"
import { RimeDictionaryAdapter } from "controllers/transcription_core"
import {
  convertPunctuation,
  loadPunctuationState,
  punctuationPresetOptions,
  savePunctuationState,
} from "controllers/han_punctuation"

const AUTOSAVE_KEY = "autosave"
const AUTOSAVE_FALLBACK_KEY = "fanya.wordProcessor.autosave.v1"
const SHORTCUTS_KEY = "fanya.wordProcessor.shortcuts.v1"
const SHELF_KEY = "fanya-word-processor-shelf"
const INPUT_METHOD_KEY = "fanya.wordProcessor.inputMethod.v1"
const PROJECT_VERSION = 2
const MARK_CLASSES = {
  proper_name: "ne-person",
  title: "ne-title",
  place: "ne-place",
  office: "ne-office",
}

const SHORTCUT_ACTIONS = [
  ["repeat", "shortcut_repeat"],
  ["orientation", "shortcut_orientation"],
  ["punctuation", "shortcut_punctuation"],
  ["date", "shortcut_date"],
  ["measurement", "shortcut_measurement"],
  ["save_project", "shortcut_save_project"],
  ["download_txt", "shortcut_download_txt"],
  ["proper_name", "shortcut_proper_name"],
  ["comment", "shortcut_comment"],
]

export default class extends Controller {
  static targets = [
    "rimeSchemas", "functionWords", "dateSystems", "documentTitle", "chapterList", "reader", "viewbox", "editor",
    "orientationButton", "themeButton", "scriptMode", "repeatMark", "autoRepeat", "status", "counts",
    "rimePanel", "rimeSchema", "rimeCode", "rimeCandidates", "pinInput", "pinnedShelf", "recentShelf",
    "functionWordCategory", "functionWordShelf", "numeralSystem", "numeralComposerPanel", "numeralComposerRaw", "numeralCandidates", "openFile",
    "shortcutList", "notesList", "contextMenu", "punctuationDialog", "verticalQuotes", "dateDialog", "dateInput",
    "dateOutput", "dateEra", "dateStatus", "measurementDialog", "idsDialog", "idsExpression", "insertMenu", "hanFont",
    "confirmDialog", "confirmMessage", "confirmButton", "textEntryDialog", "textEntryTitle", "textEntryInput", "textEntrySubmit"
  ]

  static values = {
    convertUrl: String,
    preferencesUrl: String,
    initialScriptMode: String,
  }

  async connect() {
    this.composing = false
    this.savedContextRange = null
    this.pendingScriptConversions = []
    this.scriptConversionQueueRunning = false
    this.rimeCandidateRenderSequence = 0
    this.awaitingShortcutAction = null
    this.rimeAdapter = null
    this.rimeInsertRange = null
    this.numeralComposition = null
    this.numeralCandidateRows = []
    this.numeralCandidateIndex = 0
    this.dateEraRows = []
    this.eraSuggestionSequence = 0
    this.eraSuggestionTimer = null
    this.pendingConfirmation = null
    this.pendingTextEntry = null
    this.gamepadButtons = new Map()
    this.punctuation = loadPunctuationState()
    this.functionWordGroups = this.parseJsonTarget(this.functionWordsTarget, {})
    this.rimeSchemaRows = this.parseJsonTarget(this.rimeSchemasTarget, [])
    this.dateSystemRows = this.parseJsonTarget(this.dateSystemsTarget, [])
    this.shortcuts = this.loadShortcuts()
    this.myShelf = this.normaliseShelf(this.loadShelf())
    this.document = this.defaultDocument()

    this._boundWindowKeydown = (event) => this.windowKeydown(event)
    this._boundWindowPointer = (event) => this.windowPointerDown(event)
    this._boundResize = () => this.positionNumeralComposer()
    this._boundStorage = (event) => {
      if (event.key !== SHELF_KEY) return
      this.myShelf = this.normaliseShelf(this.loadShelf())
      this.document.shelves.pinned = this.myShelf
      this.renderPinnedShelf()
      this.renderShortcutList()
    }
    window.addEventListener("keydown", this._boundWindowKeydown)
    window.addEventListener("pointerdown", this._boundWindowPointer)
    window.addEventListener("storage", this._boundStorage)
    window.addEventListener("resize", this._boundResize)

    this.setupRimeSchemas()
    this.setupFunctionWords()
    this.setupDateSystems()
    this.renderShortcutList()

    const saved = await this.loadAutosave()
    if (saved) this.document = this.normaliseDocument(saved)
    this.mergeProjectShelf()
    this.syncControlsFromDocument()
    this.renderAll()
    this.scrollVerticalToStart()
    this.startGamepadPolling()
  }

  disconnect() {
    window.removeEventListener("keydown", this._boundWindowKeydown)
    window.removeEventListener("pointerdown", this._boundWindowPointer)
    window.removeEventListener("storage", this._boundStorage)
    window.removeEventListener("resize", this._boundResize)
    this.rimeAdapter?.disconnect()
    if (this.gamepadFrame) cancelAnimationFrame(this.gamepadFrame)
    clearTimeout(this.autosaveTimer)
    clearTimeout(this.eraSuggestionTimer)
  }

  tr(key, variables = {}) {
    return t(`word_processor.${key}`, variables)
  }

  defaultDocument() {
    const chapter = this.newChapterObject(this.tr("chapter_number", { number: 1 }))
    return {
      version: PROJECT_VERSION,
      title: "",
      activeChapterId: chapter.id,
      chapters: [chapter],
      settings: {
        vertical: true,
        theme: "bamboo",
        scriptMode: this.initialScriptModeValue || "original",
        repeatMark: "〻",
        autoRepeat: false,
        numeralSystem: "han",
      },
      shelves: { pinned: [], recent: [] },
    }
  }

  newChapterObject(title = this.tr("chapter")) {
    return {
      id: this.uuid("chapter"),
      title,
      text: "",
      annotations: [],
    }
  }

  normaliseDocument(raw) {
    const fallback = this.defaultDocument()
    if (!raw || typeof raw !== "object") return fallback

    const chapters = Array.isArray(raw.chapters) && raw.chapters.length > 0
      ? raw.chapters.map((chapter, index) => ({
          id: chapter.id || this.uuid("chapter"),
          title: String(chapter.title || this.tr("chapter_number", { number: index + 1 })),
          text: String(chapter.text || ""),
          annotations: Array.isArray(chapter.annotations)
            ? chapter.annotations.map((annotation) => this.normaliseAnnotation(annotation)).filter(Boolean)
            : [],
        }))
      : fallback.chapters

    const active = chapters.some((chapter) => chapter.id === raw.activeChapterId)
      ? raw.activeChapterId
      : chapters[0].id

    return {
      version: PROJECT_VERSION,
      title: String(raw.title || ""),
      activeChapterId: active,
      chapters,
      settings: {
        ...fallback.settings,
        ...(raw.settings || {}),
        scriptMode: String(raw.settings?.scriptMode || this.initialScriptModeValue || "original"),
        repeatMark: Number(raw.version || 0) < 2 && raw.settings?.vertical !== false && !raw.settings?.repeatMark
          ? "〻"
          : String(raw.settings?.repeatMark ?? fallback.settings.repeatMark),
      },
      shelves: {
        pinned: this.normaliseShelf(raw.shelves?.pinned),
        recent: Array.isArray(raw.shelves?.recent) ? raw.shelves.recent.map(String).slice(0, 40) : [],
      },
    }
  }

  normaliseAnnotation(annotation) {
    if (!annotation || typeof annotation !== "object") return null
    const start = Math.max(0, Number.parseInt(annotation.start, 10) || 0)
    const end = Math.max(start, Number.parseInt(annotation.end, 10) || start)
    return {
      ...annotation,
      id: annotation.id || this.uuid("annotation"),
      kind: String(annotation.kind || "note"),
      start,
      end,
      note: annotation.note === undefined ? undefined : String(annotation.note),
      reading: annotation.reading === undefined ? undefined : String(annotation.reading),
      region: annotation.region === undefined ? undefined : String(annotation.region),
    }
  }

  uuid(prefix) {
    const body = window.crypto?.randomUUID ? window.crypto.randomUUID() : `${Date.now()}-${Math.random().toString(16).slice(2)}`
    return `${prefix}-${body}`
  }

  parseJsonTarget(target, fallback) {
    try {
      return JSON.parse(target?.textContent || "")
    } catch (_error) {
      return fallback
    }
  }

  activeChapter() {
    return this.document.chapters.find((chapter) => chapter.id === this.document.activeChapterId) || this.document.chapters[0]
  }

  documentTitleChanged() {
    this.document.title = this.documentTitleTarget.value
    this.scheduleAutosave()
  }

  addChapter() {
    this.cancelNumeralComposition({ restoreCaret: false })
    this.syncEditorToModel()
    const chapter = this.newChapterObject(this.tr("chapter_number", { number: this.document.chapters.length + 1 }))
    this.document.chapters.push(chapter)
    this.document.activeChapterId = chapter.id
    this.renderAll()
    this.scheduleAutosave()
  }

  selectChapter(event) {
    const id = event.currentTarget.dataset.chapterId
    if (!id || id === this.document.activeChapterId) return
    this.cancelNumeralComposition({ restoreCaret: false })
    this.syncEditorToModel()
    this.document.activeChapterId = id
    this.chapterListTarget.querySelectorAll(".wp-chapter-row").forEach((row) => {
      const button = row.querySelector(".wp-chapter-select")
      row.classList.toggle("is-active", button?.dataset.chapterId === id)
    })
    this.renderEditor()
    this.renderNotes()
    this.renderCounts()
    this.applyReaderSettings()
    this.scheduleAutosave()
  }

  beginChapterRename(event) {
    event.stopPropagation()
    const id = event.currentTarget.dataset.chapterId
    const chapter = this.document.chapters.find((item) => item.id === id)
    const row = event.currentTarget.closest(".wp-chapter-row")
    if (!chapter || !row || row.querySelector(".wp-chapter-name-input")) return

    const select = row.querySelector(".wp-chapter-select")
    if (!select) return
    const input = document.createElement("input")
    input.type = "text"
    input.className = "wp-chapter-name-input"
    input.value = chapter.title
    input.dataset.chapterId = chapter.id
    input.addEventListener("click", (innerEvent) => innerEvent.stopPropagation())
    input.addEventListener("keydown", (innerEvent) => {
      if (innerEvent.key === "Enter") { innerEvent.preventDefault(); this.commitChapterRename(input) }
      if (innerEvent.key === "Escape") { innerEvent.preventDefault(); this.renderChapterList() }
    })
    input.addEventListener("blur", () => this.commitChapterRename(input), { once: true })
    select.replaceWith(input)
    input.focus()
    input.select()
  }

  commitChapterRename(input) {
    if (!input?.isConnected) return
    const chapter = this.document.chapters.find((item) => item.id === input.dataset.chapterId)
    if (!chapter) return
    const value = String(input.value || "").trim()
    if (value) chapter.title = value
    this.renderChapterList()
    this.scheduleAutosave()
  }

  removeChapter(event) {
    event.stopPropagation()
    const id = event.currentTarget.dataset.chapterId
    if (this.document.chapters.length <= 1) {
      this.setStatus(this.tr("at_least_one_chapter"))
      return
    }
    const chapter = this.document.chapters.find((item) => item.id === id)
    if (!chapter) return

    this.requestConfirmation(this.tr("delete_chapter_confirm", { title: chapter.title }), () => {
      const index = this.document.chapters.findIndex((item) => item.id === id)
      if (index < 0) return
      this.document.chapters.splice(index, 1)
      if (this.document.activeChapterId === id) {
        this.document.activeChapterId = this.document.chapters[Math.min(index, this.document.chapters.length - 1)].id
      }
      this.renderAll()
      this.scheduleAutosave()
    })
  }

  moveChapter(event) {
    event.stopPropagation()
    const id = event.currentTarget.dataset.chapterId
    const direction = event.currentTarget.dataset.direction === "up" ? -1 : 1
    const index = this.document.chapters.findIndex((item) => item.id === id)
    const destination = index + direction
    if (index < 0 || destination < 0 || destination >= this.document.chapters.length) return
    const [chapter] = this.document.chapters.splice(index, 1)
    this.document.chapters.splice(destination, 0, chapter)
    this.renderChapterList()
    this.scheduleAutosave()
  }

  renderAll() {
    this.documentTitleTarget.value = this.document.title || ""
    this.renderChapterList()
    this.renderEditor()
    this.renderPinnedShelf()
    this.renderRecentShelf()
    this.renderFunctionWords()
    this.renderNotes()
    this.renderCounts()
    this.applyReaderSettings()
  }

  renderChapterList() {
    this.chapterListTarget.replaceChildren()
    this.document.chapters.forEach((chapter, index) => {
      const row = document.createElement("div")
      row.className = "wp-chapter-row"
      if (chapter.id === this.document.activeChapterId) row.classList.add("is-active")

      const select = document.createElement("button")
      select.type = "button"
      select.className = "wp-chapter-select"
      select.dataset.chapterId = chapter.id
      select.dataset.action = "click->word-processor#selectChapter dblclick->word-processor#beginChapterRename"
      select.textContent = chapter.title
      row.appendChild(select)

      const controls = document.createElement("span")
      controls.className = "wp-chapter-controls"
      controls.append(
        this.chapterControl("↑", chapter.id, "up", index === 0),
        this.chapterControl("↓", chapter.id, "down", index === this.document.chapters.length - 1),
        this.chapterControl(this.tr("rename"), chapter.id, "rename", false),
        this.chapterControl(this.tr("delete"), chapter.id, "delete", this.document.chapters.length === 1),
      )
      row.appendChild(controls)
      this.chapterListTarget.appendChild(row)
    })
  }

  chapterControl(label, id, kind, disabled) {
    const button = document.createElement("button")
    button.type = "button"
    button.className = "wp-mini-button"
    button.textContent = label
    button.dataset.chapterId = id
    button.disabled = disabled
    if (kind === "up" || kind === "down") {
      button.dataset.direction = kind
      button.dataset.action = "word-processor#moveChapter"
    } else if (kind === "rename") {
      button.dataset.action = "word-processor#beginChapterRename"
    } else {
      button.dataset.action = "word-processor#removeChapter"
    }
    return button
  }

  renderEditor(selection = null) {
    const chapter = this.activeChapter()
    if (!chapter) return

    const text = chapter.text
    const annotations = chapter.annotations
      .map((annotation) => ({ ...annotation, start: Math.min(annotation.start, text.length), end: Math.min(annotation.end, text.length) }))
      .filter((annotation) => annotation.end >= annotation.start)

    const boundaries = new Set([0, text.length])
    annotations.forEach((annotation) => {
      if (annotation.end > annotation.start) {
        boundaries.add(annotation.start)
        boundaries.add(annotation.end)
      }
    })
    const sorted = Array.from(boundaries).sort((a, b) => a - b)
    const fragment = document.createDocumentFragment()

    for (let index = 0; index < sorted.length - 1; index += 1) {
      const start = sorted[index]
      const end = sorted[index + 1]
      if (end <= start) continue
      const segmentText = text.slice(start, end)
      const active = annotations.filter((annotation) => annotation.end > annotation.start && annotation.start <= start && annotation.end >= end)
      fragment.appendChild(this.renderSegment(segmentText, active))
    }

    if (text.length === 0) fragment.appendChild(document.createTextNode(""))
    this.editorTarget.replaceChildren(fragment)
    this.editorTarget.classList.toggle("is-empty", text.length === 0)
    this.restoreSelection(selection || { start: text.length, end: text.length })
  }

  renderSegment(text, annotations) {
    const span = document.createElement("span")
    this.appendStyledText(span, text)

    annotations.forEach((annotation) => {
      const markClass = MARK_CLASSES[annotation.kind]
      if (markClass) span.classList.add(markClass)
      if (["comment", "note", "footnote"].includes(annotation.kind)) span.classList.add("wp-has-note")
    })

    const notes = annotations.map((annotation) => annotation.note).filter(Boolean)
    if (notes.length > 0) span.title = notes.join("\n")

    const gloss = annotations.find((annotation) => annotation.kind === "gloss" && annotation.reading)
    if (!gloss) return span

    const ruby = document.createElement("ruby")
    ruby.className = "ruby-annot wp-gloss"
    ruby.dataset.glossRegion = gloss.region || ""
    ruby.appendChild(span)
    const rt = document.createElement("rt")
    rt.textContent = gloss.reading
    ruby.appendChild(rt)
    return ruby
  }

  appendStyledText(container, text) {
    const punctuation = /[。、，；：？！,.;:?!]/u
    let buffer = ""
    const flush = () => {
      if (!buffer) return
      container.appendChild(document.createTextNode(buffer))
      buffer = ""
    }
    for (const character of text) {
      if (punctuation.test(character)) {
        flush()
        const mark = document.createElement("span")
        mark.className = "cv-judou"
        mark.textContent = character
        container.appendChild(mark)
      } else {
        buffer += character
      }
    }
    flush()
  }

  editorFocus() {
    this.editorTarget.classList.add("has-focus")
  }

  editorBlur() {
    this.editorTarget.classList.remove("has-focus")
  }

  beforeInput(event) {
    const inputType = event.inputType || ""

    // A numeral run behaves like an IME composition: the ASCII digits stay in
    // a small caret-following popup until the user commits a candidate. This
    // keeps every digit key available for 10, 123, 2026, etc.
    if (!this.composing && inputType === "insertText" && /^[0-9]$/.test(event.data || "")) {
      event.preventDefault()
      this.extendNumeralComposition(event.data)
      return
    }

    if (!this.composing && inputType === "deleteContentBackward" && this.numeralComposition) {
      event.preventDefault()
      this.backspaceNumeralComposition()
      return
    }

    if (inputType === "insertParagraph" || inputType === "insertLineBreak") {
      event.preventDefault()
      this.commitNumeralThenInsert("\n", { convert: false })
      return
    }

    // Typing a normal character while a numeral popup is open commits the
    // highlighted number first, then inserts the new character at the resulting
    // caret. This mirrors ordinary IME behaviour.
    if (!this.composing && this.numeralComposition && inputType === "insertText" && event.data) {
      event.preventDefault()
      this.commitNumeralThenInsert(event.data, { convert: true, autoRepeat: true })
    }
  }

  extendNumeralComposition(digit) {
    const chapter = this.activeChapter()
    if (!chapter) return
    const range = this.numeralComposition?.range || this.captureSelectionRange() || { start: chapter.text.length, end: chapter.text.length }
    const raw = `${this.numeralComposition?.raw || ""}${digit}`
    this.numeralComposition = { chapterId: chapter.id, range: { ...range }, raw }
    this.renderNumeralCandidates(raw)
  }

  backspaceNumeralComposition() {
    if (!this.numeralComposition) return false
    const raw = this.numeralComposition.raw.slice(0, -1)
    if (!raw) {
      this.cancelNumeralComposition()
      return true
    }
    this.numeralComposition.raw = raw
    this.renderNumeralCandidates(raw)
    return true
  }

  async commitNumeralThenInsert(text, options = {}) {
    if (this.numeralComposition) await this.commitActiveNumeralCandidate({ focusEditor: false })
    await this.insertTextAtSelection(text, options)
  }

  editorKeydown(event) {
    if (!this.numeralComposition) return

    if (["ArrowRight", "ArrowDown", "Tab"].includes(event.key) && !event.shiftKey) {
      event.preventDefault()
      event.stopPropagation()
      this.moveNumeralCandidate(1)
      return
    }
    if (["ArrowLeft", "ArrowUp"].includes(event.key) || (event.key === "Tab" && event.shiftKey)) {
      event.preventDefault()
      event.stopPropagation()
      this.moveNumeralCandidate(-1)
      return
    }
    if (event.key === "Enter" || event.key === " ") {
      event.preventDefault()
      event.stopPropagation()
      this.commitActiveNumeralCandidate()
      return
    }
    if (event.key === "Escape") {
      event.preventDefault()
      event.stopPropagation()
      this.cancelNumeralComposition()
    }
  }

  paste(event) {
    event.preventDefault()
    const text = event.clipboardData?.getData("text/plain") || ""
    this.insertTextAtSelection(text, { convert: false, autoRepeat: false })
  }

  drop(event) {
    const text = event.dataTransfer?.getData("text/plain") || ""
    if (!text) return
    event.preventDefault()
    this.insertTextAtSelection(text, { convert: false, autoRepeat: false })
  }

  compositionStart() {
    this.composing = true
  }

  compositionEnd() {
    this.composing = false
    this.syncEditorToModel({ convertInserted: true })
  }

  editorInput() {
    if (this.composing) return
    this.syncEditorToModel({ convertInserted: true })
  }

  syncEditorToModel({ convertInserted = false } = {}) {
    const chapter = this.activeChapter()
    if (!chapter) return
    const oldText = chapter.text
    const newText = this.editorPlainText()
    if (newText === oldText) return

    const selection = this.captureSelectionRange()
    const diff = this.diffText(oldText, newText)
    chapter.text = newText
    chapter.annotations = this.adjustAnnotations(chapter.annotations, diff)

    let caret = selection
    const simpleInsertion = diff.oldStart === diff.oldEnd && diff.newEnd > diff.newStart
    const inserted = simpleInsertion ? chapter.text.slice(diff.newStart, diff.newEnd) : ""
    const needsScriptConversion = convertInserted && simpleInsertion && this.containsHan(inserted) && (this.document.settings.scriptMode || "original") !== "original"

    // Native/system IME text is already in the DOM when `input` fires. When a
    // character standard is active, queue conversion so fast typing cannot leave
    // an earlier character unconverted merely because a later request finished first.
    // Auto-repeat waits for that conversion because a historical standard may
    // change the character (and even its UTF-16 length).
    if (needsScriptConversion) {
      this.enqueueCommittedInsertion(chapter.id, diff.newStart, diff.newEnd, inserted)
    } else if (simpleInsertion && this.document.settings.autoRepeat && this.document.settings.repeatMark) {
      const changed = this.applyAutoRepeatToInsertion(chapter, diff.newStart, diff.newEnd)
      if (changed) caret = { start: changed.caret, end: changed.caret }
    }

    this.recordRecent(inserted)
    this.renderEditor(caret)
    this.renderRecentShelf()
    this.renderNotes()
    this.renderCounts()
    this.scheduleAutosave()
  }

  editorPlainText() {
    const clone = this.editorTarget.cloneNode(true)
    clone.querySelectorAll("rt, rp").forEach((element) => element.remove())
    return clone.textContent || ""
  }

  diffText(oldText, newText) {
    let prefix = 0
    const maxPrefix = Math.min(oldText.length, newText.length)
    while (prefix < maxPrefix && oldText[prefix] === newText[prefix]) prefix += 1

    let suffix = 0
    const oldRemaining = oldText.length - prefix
    const newRemaining = newText.length - prefix
    while (suffix < oldRemaining && suffix < newRemaining && oldText[oldText.length - 1 - suffix] === newText[newText.length - 1 - suffix]) suffix += 1

    return {
      oldStart: prefix,
      oldEnd: oldText.length - suffix,
      newStart: prefix,
      newEnd: newText.length - suffix,
    }
  }

  adjustAnnotations(annotations, diff) {
    return annotations.map((annotation) => {
      const start = this.transformOffset(annotation.start, diff, "left")
      const end = this.transformOffset(annotation.end, diff, "right")
      return { ...annotation, start: Math.max(0, start), end: Math.max(Math.max(0, start), end) }
    }).filter((annotation) => {
      if (["comment", "note", "footnote"].includes(annotation.kind)) return true
      return annotation.end > annotation.start
    })
  }

  transformOffset(offset, diff, bias) {
    const oldLength = diff.oldEnd - diff.oldStart
    const newLength = diff.newEnd - diff.newStart
    const delta = newLength - oldLength

    if (oldLength === 0) {
      if (offset < diff.oldStart) return offset
      if (offset > diff.oldStart) return offset + delta
      return bias === "right" ? offset + newLength : offset
    }

    if (offset <= diff.oldStart) return offset
    if (offset >= diff.oldEnd) return offset + delta
    return bias === "right" ? diff.newEnd : diff.newStart
  }

  applyAutoRepeatToInsertion(chapter, start, end) {
    const mark = this.document.settings.repeatMark
    if (!mark) return null
    const before = chapter.text
    const inserted = before.slice(start, end)
    if (!inserted) return null

    const prefix = Array.from(before.slice(0, start))
    while (prefix.length > 0 && prefix[prefix.length - 1] === mark) prefix.pop()
    let previousLogical = prefix.length > 0 ? prefix[prefix.length - 1] : null
    let output = ""
    let changed = false

    for (const character of inserted) {
      if (previousLogical && character === previousLogical && this.isHan(character)) {
        output += mark
        changed = true
      } else {
        output += character
        if (this.isHan(character)) previousLogical = character
      }
    }

    if (!changed) return null
    const oldText = chapter.text
    const newText = oldText.slice(0, start) + output + oldText.slice(end)
    const diff = { oldStart: start, oldEnd: end, newStart: start, newEnd: start + output.length }
    chapter.text = newText
    chapter.annotations = this.adjustAnnotations(chapter.annotations, diff)
    return {
      caret: start + output.length,
      oldStart: start,
      oldEnd: end,
      newEnd: start + output.length,
    }
  }

  enqueueCommittedInsertion(chapterId, start, end, inserted) {
    this.pendingScriptConversions.push({ chapterId, start, end, inserted })
    this.processScriptConversionQueue()
  }

  async processScriptConversionQueue() {
    if (this.scriptConversionQueueRunning) return
    this.scriptConversionQueueRunning = true

    try {
      while (this.pendingScriptConversions.length > 0) {
        const item = this.pendingScriptConversions.shift()
        const chapter = this.document.chapters.find((candidate) => candidate.id === item.chapterId)
        if (!chapter || chapter.text.slice(item.start, item.end) !== item.inserted) continue

        const converted = await this.convertForActiveScript(item.inserted)
        if (chapter.text.slice(item.start, item.end) !== item.inserted) continue

        let liveSelection = chapter.id === this.document.activeChapterId ? this.captureSelectionRange() : null
        let effectiveEnd = item.end
        if (converted !== item.inserted) {
          const oldEnd = item.end
          const replacementDiff = { oldStart: item.start, oldEnd, newStart: item.start, newEnd: item.start + converted.length }
          this.replaceRange(chapter, item.start, item.end, converted, { render: false })
          effectiveEnd = replacementDiff.newEnd
          if (liveSelection) {
            liveSelection = {
              start: this.transformOffset(liveSelection.start, replacementDiff, "left"),
              end: this.transformOffset(liveSelection.end, replacementDiff, "right"),
            }
          }
          this.shiftQueuedConversionOffsets(chapter.id, oldEnd, effectiveEnd - oldEnd)
        }

        let caret = effectiveEnd
        if (this.document.settings.autoRepeat && this.document.settings.repeatMark) {
          const changed = this.applyAutoRepeatToInsertion(chapter, item.start, effectiveEnd)
          if (changed) {
            caret = changed.caret
            const repeatDiff = { oldStart: changed.oldStart, oldEnd: changed.oldEnd, newStart: changed.oldStart, newEnd: changed.newEnd }
            if (liveSelection) {
              liveSelection = {
                start: this.transformOffset(liveSelection.start, repeatDiff, "left"),
                end: this.transformOffset(liveSelection.end, repeatDiff, "right"),
              }
            }
            this.shiftQueuedConversionOffsets(chapter.id, changed.oldEnd, changed.newEnd - changed.oldEnd)
          }
        }

        if (chapter.id === this.document.activeChapterId) {
          this.renderEditor(liveSelection || { start: caret, end: caret })
          this.renderNotes()
          this.renderCounts()
        }
        this.recordRecent(converted)
        this.renderRecentShelf()
        this.scheduleAutosave()
      }
    } finally {
      this.scriptConversionQueueRunning = false
    }
  }

  shiftQueuedConversionOffsets(chapterId, boundary, delta) {
    if (!delta) return
    this.pendingScriptConversions.forEach((item) => {
      if (item.chapterId !== chapterId) return
      if (item.start >= boundary) {
        item.start += delta
        item.end += delta
      }
    })
  }

  replaceRange(chapter, start, end, replacement, { render = true } = {}) {
    const oldText = chapter.text
    const newText = oldText.slice(0, start) + replacement + oldText.slice(end)
    const diff = { oldStart: start, oldEnd: end, newStart: start, newEnd: start + replacement.length }
    chapter.text = newText
    chapter.annotations = this.adjustAnnotations(chapter.annotations, diff)
    if (render) {
      const caret = start + replacement.length
      this.renderEditor({ start: caret, end: caret })
      this.renderNotes()
      this.renderCounts()
    }
  }

  async insertTextAtSelection(text, { convert = true, range = null, autoRepeat = false } = {}) {
    const chapter = this.activeChapter()
    if (!chapter) return
    const selection = range || this.captureSelectionRange() || { start: chapter.text.length, end: chapter.text.length }
    let value = String(text || "")
    if (convert && this.containsHan(value)) value = await this.convertForActiveScript(value)
    this.replaceRange(chapter, selection.start, selection.end, value, { render: false })
    let caret = selection.start + value.length
    if (autoRepeat && selection.start === selection.end && this.document.settings.autoRepeat && this.document.settings.repeatMark) {
      const changed = this.applyAutoRepeatToInsertion(chapter, selection.start, selection.start + value.length)
      if (changed) caret = changed.caret
    }
    this.renderEditor({ start: caret, end: caret })
    this.renderNotes()
    this.renderCounts()
    this.recordRecent(value)
    this.renderRecentShelf()
    this.scheduleAutosave()
  }

  async convertForActiveScript(text) {
    const mode = this.document.settings.scriptMode || "original"
    if (mode === "original" || !this.containsHan(text)) return text

    try {
      const data = await this.postJson({ operation: "script", mode, text })
      return data?.ok ? String(data.text || "") : text
    } catch (_error) {
      this.setStatus(this.tr("conversion_unavailable"))
      return text
    }
  }

  async hanFontChanged() {
    const key = String(this.hanFontTarget.value || "")
    if (!key || !this.hasPreferencesUrlValue) return
    const form = new FormData()
    form.append("han_font", key)
    try {
      const response = await fetch(this.preferencesUrlValue, {
        method: "POST",
        headers: { "Accept": "application/json", "X-CSRF-Token": this.csrfToken() },
        body: form,
        credentials: "same-origin",
      })
      const data = await response.json().catch(() => ({}))
      if (!response.ok || !data.ok) throw new Error(`HTTP ${response.status}`)
      if (data.han_font_stack) {
        document.documentElement.style.setProperty("--han-font-stack", data.han_font_stack)
        document.body.dataset.hanFontStack = data.han_font_stack
      }
      if (data.han_font_primary) {
        document.documentElement.style.setProperty("--han-font-primary", `"${data.han_font_primary}"`)
        document.body.dataset.hanFontPrimary = data.han_font_primary
      }
      if (data.han_font_key) document.body.dataset.hanFontKey = data.han_font_key
      if (data.han_font_family) document.body.dataset.hanFontFamily = data.han_font_family
      window.dispatchEvent(new CustomEvent("han-font-changed", { detail: data }))
      this.setStatus(this.tr("font_updated"))
    } catch (_error) {
      this.setStatus(this.tr("font_update_failed"))
    }
  }

  scriptModeChanged() {
    this.document.settings.scriptMode = this.scriptModeTarget.value || "original"
    this.scheduleAutosave()
    this.renderRimeCandidates(this.rimeAdapter?.candidates || [])
    this.setStatus(this.tr("standard_updated"))
  }

  async convertSelectionToScript() {
    const range = this.captureSelectionRange()
    const chapter = this.activeChapter()
    if (!chapter || !range || range.end <= range.start) {
      this.setStatus(this.tr("select_text_convert"))
      return
    }
    const source = chapter.text.slice(range.start, range.end)
    const converted = await this.convertForActiveScript(source)
    this.replaceRange(chapter, range.start, range.end, converted)
    this.scheduleAutosave()
  }

  toggleOrientation() {
    this.document.settings.vertical = !this.document.settings.vertical
    this.applyReaderSettings()
    if (this.document.settings.vertical) this.scrollVerticalToStart()
    this.scheduleAutosave()
  }

  cycleTheme() {
    const themes = ["light", "bamboo", "dark"]
    const current = themes.indexOf(this.document.settings.theme)
    this.document.settings.theme = themes[(current + 1) % themes.length]
    this.applyReaderSettings()
    this.scheduleAutosave()
  }

  applyReaderSettings() {
    const vertical = this.document.settings.vertical !== false
    const theme = this.document.settings.theme || "bamboo"
    this.viewboxTarget.classList.toggle("is-vertical", vertical)
    this.editorTarget.classList.toggle("is-vertical", vertical)
    this.viewboxTarget.classList.remove("theme-light", "theme-bamboo", "theme-dark")
    this.viewboxTarget.classList.add(`theme-${theme}`)
    this.readerTarget.classList.toggle("reader-theme-dark", theme === "dark")
    this.orientationButtonTarget.textContent = vertical ? this.tr("vertical") : this.tr("horizontal")
    this.orientationButtonTarget.setAttribute("aria-pressed", vertical ? "true" : "false")
    this.themeButtonTarget.textContent = this.tr("theme", { name: this.tr(`theme_${theme}`) })
    if (this.numeralComposition) this.positionNumeralComposer()
  }

  scrollVerticalToStart() {
    if (this.document.settings.vertical === false) return
    window.requestAnimationFrame(() => {
      this.viewboxTarget.scrollLeft = this.viewboxTarget.scrollWidth
    })
  }

  repeatMarkChanged() {
    this.document.settings.repeatMark = this.repeatMarkTarget.value
    this.scheduleAutosave()
  }

  numeralOptionsChanged() {
    this.document.settings.numeralSystem = this.numeralSystemTarget.value || "han"
    if (this.numeralComposition) this.renderNumeralCandidates(this.numeralComposition.raw)
    this.scheduleAutosave()
  }

  autoRepeatChanged() {
    this.document.settings.autoRepeat = this.autoRepeatTarget.checked
    this.scheduleAutosave()
  }

  insertRepeatMark() {
    const mark = this.document.settings.repeatMark
    if (!mark) {
      this.setStatus(this.tr("choose_repeat"))
      return
    }
    this.insertTextAtSelection(mark, { convert: false })
  }

  insertFromButton(event) {
    this.insertTextAtSelection(event.currentTarget.dataset.insert || "", { convert: false })
  }

  insertHanFromButton(event) {
    this.insertTextAtSelection(event.currentTarget.dataset.insert || "", { convert: true })
  }

  pinShelfText(event) {
    event.preventDefault()
    const value = this.pinInputTarget.value.trim()
    if (!value) return
    this.myShelf = [value, ...this.myShelf.filter((entry) => this.shelfEntryText(entry) !== value)].slice(0, 100)
    this.document.shelves.pinned = this.myShelf
    this.saveShelf()
    this.pinInputTarget.value = ""
    this.renderPinnedShelf()
    this.renderShortcutList()
    this.scheduleAutosave()
  }

  removePinned(event) {
    const index = Number.parseInt(event.currentTarget.dataset.index || "-1", 10)
    if (!Number.isFinite(index) || index < 0 || index >= this.myShelf.length) return
    this.myShelf.splice(index, 1)
    this.document.shelves.pinned = this.myShelf
    this.saveShelf()
    this.renderPinnedShelf()
    this.renderShortcutList()
    this.scheduleAutosave()
  }

  renderPinnedShelf() {
    this.pinnedShelfTarget.replaceChildren()
    this.myShelf.forEach((entry, index) => {
      const value = this.shelfEntryText(entry)
      if (!value) return
      const wrapper = document.createElement("span")
      wrapper.className = "wp-shelf-pinned"
      const insert = this.chip(value, "word-processor#insertShelfEntry")
      insert.dataset.index = String(index)
      if (this.shelfEntryUsesCharacterStandard(entry)) insert.title = this.tr("dictionary_shelf_title")
      const remove = document.createElement("button")
      remove.type = "button"
      remove.className = "wp-chip-remove"
      remove.textContent = "×"
      remove.title = this.tr("remove_shelf")
      remove.dataset.index = String(index)
      remove.dataset.action = "word-processor#removePinned"
      wrapper.append(insert, remove)
      this.pinnedShelfTarget.appendChild(wrapper)
    })
  }

  insertShelfEntry(event) {
    const index = Number.parseInt(event.currentTarget.dataset.index || "-1", 10)
    const entry = this.myShelf[index]
    if (!entry) return
    this.insertShelfEntryValue(entry)
  }

  insertShelfEntryValue(entry) {
    const text = this.shelfEntryText(entry)
    if (!text) return
    this.insertTextAtSelection(text, { convert: this.shelfEntryUsesCharacterStandard(entry) })
  }

  loadShelf() {
    try {
      const value = JSON.parse(window.localStorage.getItem(SHELF_KEY) || "[]")
      return Array.isArray(value) ? value : []
    } catch (_error) {
      return []
    }
  }

  normaliseShelf(value) {
    if (!Array.isArray(value)) return []
    return value.filter((entry) => {
      if (typeof entry === "string") return entry.trim().length > 0
      return entry && typeof entry === "object" && typeof entry.text === "string" && entry.text.trim().length > 0
    }).slice(0, 100)
  }

  shelfEntryText(entry) {
    return typeof entry === "string" ? entry : String(entry?.text || "")
  }

  shelfEntryUsesCharacterStandard(entry) {
    return !!entry && typeof entry === "object" && entry.source === "dictionary"
  }

  saveShelf() {
    try { window.localStorage.setItem(SHELF_KEY, JSON.stringify(this.myShelf)) } catch (_error) {}
  }

  mergeProjectShelf() {
    const portable = this.normaliseShelf(this.document.shelves?.pinned)
    const merged = [...this.myShelf]
    portable.forEach((entry) => {
      const text = this.shelfEntryText(entry)
      if (!text) return
      const existing = merged.findIndex((item) => this.shelfEntryText(item) === text)
      if (existing >= 0) {
        // Prefer dictionary-linked identity when either copy has it.
        if (this.shelfEntryUsesCharacterStandard(entry) && !this.shelfEntryUsesCharacterStandard(merged[existing])) merged[existing] = entry
      } else {
        merged.push(entry)
      }
    })
    this.myShelf = merged.slice(0, 100)
    this.document.shelves.pinned = this.myShelf
    this.saveShelf()
  }

  recordRecent(text) {
    const characters = Array.from(String(text || "")).filter((character) => this.isHan(character))
    if (characters.length === 0) return
    const next = [...this.document.shelves.recent]
    characters.forEach((character) => {
      const existing = next.indexOf(character)
      if (existing >= 0) next.splice(existing, 1)
      next.unshift(character)
    })
    this.document.shelves.recent = next.slice(0, 40)
  }

  renderRecentShelf() {
    this.recentShelfTarget.replaceChildren()
    this.document.shelves.recent.forEach((value) => {
      const button = this.chip(value, "word-processor#insertRecent")
      button.dataset.value = value
      this.recentShelfTarget.appendChild(button)
    })
  }

  insertRecent(event) {
    this.insertTextAtSelection(event.currentTarget.dataset.value || "", { convert: false })
  }

  setupFunctionWords() {
    const categories = Object.keys(this.functionWordGroups)
    this.functionWordCategoryTarget.replaceChildren()
    categories.forEach((category) => {
      const option = document.createElement("option")
      option.value = category
      option.textContent = this.functionCategoryLabel(category)
      this.functionWordCategoryTarget.appendChild(option)
    })
  }

  renderFunctionWords() {
    const category = this.functionWordCategoryTarget.value || Object.keys(this.functionWordGroups)[0]
    const rows = this.functionWordGroups[category] || []
    this.functionWordShelfTarget.replaceChildren()
    rows.forEach((row) => {
      const button = this.chip(row.headword, "word-processor#insertFunctionWord")
      button.dataset.value = row.headword
      button.title = row.importance ? this.tr("function_word_importance", { importance: this.functionImportanceLabel(row.importance) }) : this.tr("function_word")
      this.functionWordShelfTarget.appendChild(button)
    })
  }

  insertFunctionWord(event) {
    this.insertTextAtSelection(event.currentTarget.dataset.value || "", { convert: true })
  }

  chip(label, action) {
    const button = document.createElement("button")
    button.type = "button"
    button.className = "wp-chip wp-han-button"
    button.textContent = label
    button.dataset.action = action
    return button
  }

  renderNumeralCandidates(raw) {
    this.numeralComposerRawTarget.textContent = raw
    if (!/^\d+$/.test(raw)) {
      this.cancelNumeralComposition()
      return
    }

    const rows = this.numeralCandidateRowsFor(raw)
    this.numeralCandidateRows = rows
    this.numeralCandidateIndex = Math.min(this.preferredNumeralCandidateIndex(rows), Math.max(0, rows.length - 1))
    this.numeralComposerPanelTarget.hidden = false
    this.renderNumeralCandidateRows()
  }

  numeralCandidateRowsFor(raw) {
    const rows = []
    const add = (text, label, kind = "base") => {
      const value = String(text || "")
      if (!value || rows.some((row) => row.text === value)) return
      rows.push({ text: value, label, kind })
    }

    add(this.hanDigitString(raw, false), this.tr("numeral_candidate_standard_digits"))
    add(this.hanNumberExpression(raw, false), this.tr("numeral_candidate_standard_number"))
    add(this.hanDigitString(raw, true), this.tr("numeral_candidate_financial_digits"))
    add(this.hanNumberExpression(raw, true), this.tr("numeral_candidate_financial_number"))

    if (raw === "2") {
      add("兩", this.tr("numeral_candidate_two_liang"), "variant")
      add("両", this.tr("numeral_candidate_two_japanese"), "variant")
      add("倆", this.tr("numeral_candidate_two_colloquial"), "variant")
      add("弍", this.tr("numeral_candidate_two_variant"), "variant")
      add("弐", this.tr("numeral_candidate_two_japanese_variant"), "variant")
    }
    if (raw === "3") {
      add("仨", this.tr("numeral_candidate_three_colloquial"), "variant")
      add("弎", this.tr("numeral_candidate_three_variant"), "variant")
    }
    if (raw === "20") {
      add("廿", this.tr("numeral_candidate_twenty"), "variant")
      add("廾", this.tr("numeral_candidate_twenty_variant"), "variant")
    }
    if (raw === "30") add("卅", this.tr("numeral_candidate_thirty"), "variant")
    if (raw === "40") add("卌", this.tr("numeral_candidate_forty"), "variant")

    add(this.suzhouNumerals(raw), this.tr("numeral_suzhou"))
    add(this.countingRods(raw), this.tr("numeral_rods"))
    add(raw, this.tr("arabic_numerals"))
    return rows
  }

  preferredNumeralCandidateIndex(rows) {
    const system = this.numeralSystemTarget.value || "han"
    const preferred = this.formatCurrentNumeral(this.numeralComposition?.raw || "")
    const exact = rows.findIndex((row) => row.text === preferred)
    if (exact >= 0) return exact
    if (system === "financial") return Math.max(0, rows.findIndex((row) => row.label === this.tr("numeral_candidate_financial_digits")))
    if (system === "suzhou") return Math.max(0, rows.findIndex((row) => row.label === this.tr("numeral_suzhou")))
    if (system === "rods") return Math.max(0, rows.findIndex((row) => row.label === this.tr("numeral_rods")))
    if (system === "arabic") return Math.max(0, rows.findIndex((row) => row.text === this.numeralComposition?.raw))
    return 0
  }

  moveNumeralCandidate(delta) {
    if (!this.numeralCandidateRows.length) return
    const count = this.numeralCandidateRows.length
    this.numeralCandidateIndex = (this.numeralCandidateIndex + delta + count) % count
    this.refreshNumeralCandidateSelection()
  }

  selectNumeralCandidate(index) {
    if (index < 0 || index >= this.numeralCandidateRows.length) return
    this.numeralCandidateIndex = index
    this.refreshNumeralCandidateSelection()
  }

  refreshNumeralCandidateSelection() {
    Array.from(this.numeralCandidatesTarget.querySelectorAll(".wp-numeral-candidate")).forEach((button, index) => {
      const selected = index === this.numeralCandidateIndex
      button.classList.toggle("is-active", selected)
      button.setAttribute("aria-selected", selected ? "true" : "false")
    })
  }

  async commitActiveNumeralCandidate({ focusEditor = true } = {}) {
    const row = this.numeralCandidateRows[this.numeralCandidateIndex] || this.numeralCandidateRows[0]
    if (!row) {
      this.cancelNumeralComposition()
      return
    }
    await this.commitNumeralCandidate(row.text, { focusEditor })
  }

  async commitNumeralCandidate(value, { focusEditor = true } = {}) {
    const composition = this.numeralComposition
    if (!composition) return
    const range = { ...composition.range }
    this.cancelNumeralComposition({ restoreCaret: false })
    await this.insertTextAtSelection(value, { convert: true, range, autoRepeat: false })
    if (focusEditor) this.editorTarget.focus()
  }

  cancelNumeralComposition({ restoreCaret = true } = {}) {
    const range = this.numeralComposition?.range
    this.numeralComposition = null
    this.numeralCandidateRows = []
    this.numeralCandidateIndex = 0
    this.numeralCandidatesTarget.replaceChildren()
    this.numeralComposerRawTarget.textContent = ""
    this.numeralComposerPanelTarget.hidden = true
    this.numeralComposerPanelTarget.style.visibility = ""
    if (restoreCaret && range) {
      this.editorTarget.focus()
      this.restoreSelection(range)
    }
  }

  async expandNumeralVariants(event) {
    event?.preventDefault()
    const current = this.numeralCandidateRows[this.numeralCandidateIndex]
    if (!current) return
    const button = event?.currentTarget
    if (button) button.disabled = true
    try {
      const data = await this.postJson({ operation: "variants", texts: [current.text] })
      if (!data?.ok || !Array.isArray(data.variants)) return
      data.variants.forEach((variant) => {
        const text = String(variant.text || "")
        if (!text || this.numeralCandidateRows.some((row) => row.text === text)) return
        const label = variant.source === "opencc"
          ? this.tr("opencc_variant")
          : this.tr("character_standard_variant", { standard: this.humanize(variant.mode || "") })
        this.numeralCandidateRows.push({ text, label, kind: "variant" })
      })
      this.renderNumeralCandidateRows()
    } catch (_error) {
      this.setStatus(this.tr("variants_unavailable"))
    } finally {
      if (button) button.disabled = false
    }
  }

  renderNumeralCandidateRows() {
    const rows = [...this.numeralCandidateRows]
    this.numeralCandidatesTarget.replaceChildren()
    rows.forEach((row, index) => {
      const button = document.createElement("button")
      button.type = "button"
      button.className = "wp-candidate wp-numeral-candidate"
      if (index === this.numeralCandidateIndex) button.classList.add("is-active")
      button.dataset.value = row.text
      button.title = row.label
      button.setAttribute("role", "option")
      button.setAttribute("aria-selected", index === this.numeralCandidateIndex ? "true" : "false")
      const glyph = document.createElement("span")
      glyph.className = "wp-candidate-glyph"
      glyph.textContent = row.text
      const label = document.createElement("span")
      label.className = "wp-candidate-label"
      label.textContent = row.label
      button.append(glyph, label)
      button.addEventListener("pointerdown", (pointerEvent) => pointerEvent.preventDefault())
      button.addEventListener("mouseenter", () => this.selectNumeralCandidate(index))
      button.addEventListener("click", () => this.commitNumeralCandidate(row.text))
      this.numeralCandidatesTarget.appendChild(button)
    })
    this.positionNumeralComposer()
  }

  positionNumeralComposer() {
    if (!this.numeralComposition || this.numeralComposerPanelTarget.hidden) return
    const rect = this.caretViewportRect(this.numeralComposition.range)
    if (!rect) return

    const popup = this.numeralComposerPanelTarget
    popup.style.visibility = "hidden"
    popup.style.left = "0px"
    popup.style.top = "0px"
    requestAnimationFrame(() => {
      if (!this.numeralComposition || popup.hidden) return
      const box = popup.getBoundingClientRect()
      const margin = 8
      let left
      let top
      if (this.document.settings.vertical !== false) {
        left = rect.left - box.width - margin
        top = rect.top
        if (left < margin) left = rect.right + margin
      } else {
        left = rect.left
        top = rect.bottom + margin
        if (top + box.height > window.innerHeight - margin) top = rect.top - box.height - margin
      }
      left = Math.max(margin, Math.min(left, window.innerWidth - box.width - margin))
      top = Math.max(margin, Math.min(top, window.innerHeight - box.height - margin))
      popup.style.left = `${Math.round(left)}px`
      popup.style.top = `${Math.round(top)}px`
      popup.style.visibility = "visible"
    })
  }

  caretViewportRect(range) {
    if (!range) return null
    const point = this.pointForOffset(range.start)
    if (!point) return null
    const domRange = document.createRange()
    domRange.setStart(point.node, point.offset)
    domRange.collapse(true)
    const rect = domRange.getClientRects()[0] || domRange.getBoundingClientRect()
    if (rect && (rect.width || rect.height)) return rect

    // Empty contenteditable ranges often report a zero rectangle. A temporary
    // zero-width marker gives us the browser's actual caret position without
    // changing the saved document text.
    const marker = document.createElement("span")
    marker.className = "wp-caret-probe"
    marker.textContent = "\u200b"
    domRange.insertNode(marker)
    const markerRect = marker.getBoundingClientRect()
    marker.remove()
    this.restoreSelection(range)
    return markerRect
  }

  numeralSystemLabel(system) {
    return {
      han: this.tr("numeral_standard"),
      financial: this.tr("financial_han"),
      suzhou: this.tr("numeral_suzhou"),
      rods: this.tr("numeral_rods"),
      arabic: this.tr("arabic_numerals"),
    }[system] || this.tr("numbers")
  }

  formatCurrentNumeral(raw) {
    const system = this.numeralSystemTarget.value
    if (system === "arabic") return raw
    if (system === "han" || system === "financial") {
      return this.hanDigitString(raw, system === "financial")
    }
    if (system === "suzhou") return this.suzhouNumerals(raw)
    return this.countingRods(raw)
  }

  formatArabicNumericRuns(text) {
    return String(text || "").replace(/\d+/g, (raw) => this.formatCurrentNumeral(raw))
  }

  hanDigitString(raw, financial) {
    const ordinary = "〇一二三四五六七八九"
    const banker = "零壹貳參肆伍陸柒捌玖"
    const digits = financial ? banker : ordinary
    return Array.from(raw, (digit) => digits[Number(digit)]).join("")
  }

  hanNumberExpression(raw, financial = false) {
    const normalized = raw.replace(/^0+(?=\d)/, "")
    if (/^0+$/.test(raw)) return financial ? "零" : "〇"
    if (normalized.length > 20) return this.hanDigitString(raw, financial)

    const digits = financial ? ["零", "壹", "貳", "參", "肆", "伍", "陸", "柒", "捌", "玖"] : ["零", "一", "二", "三", "四", "五", "六", "七", "八", "九"]
    const smallUnits = financial ? ["", "拾", "佰", "仟"] : ["", "十", "百", "千"]
    const bigUnits = ["", "萬", "億", "兆", "京"]
    let number = BigInt(normalized)
    const groups = []
    while (number > 0n) {
      groups.push(Number(number % 10000n))
      number /= 10000n
    }

    let output = ""
    let zeroGap = false
    for (let index = groups.length - 1; index >= 0; index -= 1) {
      const group = groups[index]
      if (group === 0) {
        if (output) zeroGap = true
        continue
      }
      if (output && (zeroGap || group < 1000)) output += digits[0]
      output += this.hanFourDigitGroup(group, digits, smallUnits)
      output += bigUnits[index] || ""
      zeroGap = false
    }

    if (!financial && BigInt(normalized) >= 10n && BigInt(normalized) < 20n && output.startsWith("一十")) output = output.slice(1)
    return output
  }

  hanFourDigitGroup(number, digits, units) {
    const places = [1000, 100, 10, 1]
    let output = ""
    let pendingZero = false
    places.forEach((place, index) => {
      const digit = Math.floor(number / place) % 10
      if (digit === 0) {
        if (output && number % place !== 0) pendingZero = true
        return
      }
      if (pendingZero) output += digits[0]
      output += digits[digit] + units[3 - index]
      pendingZero = false
    })
    return output
  }

  suzhouNumerals(raw) {
    const vertical = ["〇", "〡", "〢", "〣", "〤", "〥", "〦", "〧", "〨", "〩"]
    const horizontal = ["〇", "一", "二", "三"]
    let previousStrokeDigit = false
    let useVertical = true
    let output = ""

    for (const digitText of raw) {
      const digit = Number(digitText)
      if (digit >= 1 && digit <= 3) {
        if (!previousStrokeDigit) useVertical = true
        output += useVertical ? vertical[digit] : horizontal[digit]
        useVertical = !useVertical
        previousStrokeDigit = true
      } else {
        output += vertical[digit]
        previousStrokeDigit = false
        useVertical = true
      }
    }
    return output
  }

  countingRods(raw) {
    const characters = Array.from(raw)
    return characters.map((digitText, index) => {
      const digit = Number(digitText)
      if (digit === 0) return "〇"
      const positionFromRight = characters.length - 1 - index
      const base = positionFromRight % 2 === 0 ? 0x1D360 : 0x1D369
      return String.fromCodePoint(base + digit - 1)
    }).join("")
  }

  idsChanged(event) {
    const expression = event.detail?.expression || "?"
    this.idsExpressionTarget.textContent = expression
  }

  insertIdsExpression() {
    const expression = this.idsExpressionTarget.textContent || "?"
    if (!expression || expression === "?") {
      this.setStatus(this.tr("build_ids"))
      return
    }
    this.insertTextAtSelection(expression, { convert: false })
  }

  setupRimeSchemas() {
    const available = new Set(this.rimeSchemaRows.map((schema) => String(schema.schema_id || "")))
    let stored = ""
    try { stored = window.localStorage.getItem(INPUT_METHOD_KEY) || "" } catch (_error) {}
    this.rimeSchemaTarget.value = available.has(stored) ? stored : ""
    this.rimeSchemaChanged()
  }

  rimeSchemaChanged(event = null) {
    this.rememberRimeInsertionPoint()
    const schemaId = String(this.rimeSchemaTarget.value || "")
    const enabled = schemaId.length > 0 && this.rimeSchemaRows.some((schema) => String(schema.schema_id || "") === schemaId)
    try { window.localStorage.setItem(INPUT_METHOD_KEY, enabled ? schemaId : "") } catch (_error) {}
    this.rimePanelTarget.hidden = !enabled

    if (!enabled) {
      this.rimeAdapter?.disconnect()
      this.rimeAdapter = null
      this.rimeCandidatesTarget.replaceChildren()
      this.rimeCodeTarget.value = ""
      return
    }

    this.buildRimeAdapter()
    if (event) this.rimeCodeTarget.focus()
  }

  buildRimeAdapter() {
    this.rimeAdapter?.disconnect()
    this.rimeAdapter = new RimeDictionaryAdapter({
      systemId: this.rimeSchemaTarget.value,
      onCommit: (character) => this.commitRimeCharacter(character),
      onCandidates: (rows) => this.renderRimeCandidates(rows),
    })
    this.rimeAdapter.setRevealCandidates(true)
    this.rimeAdapter.update(this.rimeCodeTarget.value)
  }

  rememberRimeInsertionPoint() {
    const range = this.captureSelectionRange()
    if (range) this.rimeInsertRange = range
  }

  rimeCodeChanged() {
    this.rimeAdapter?.update(this.rimeCodeTarget.value)
  }

  async rimeKeydown(event) {
    if (!this.rimeAdapter) return
    if (/^[1-9]$/.test(event.key) && this.rimeAdapter.candidates.length > 0) {
      event.preventDefault()
      const index = Number(event.key) - 1
      if (this.rimeAdapter.choose(index)) this.clearRimeCode()
      return
    }
    if (event.key === "Enter" || event.key === " ") {
      event.preventDefault()
      const result = await this.rimeAdapter.commitCode(this.rimeCodeTarget.value)
      if (result.committed) this.clearRimeCode()
      else if (result.reason === "ambiguous") this.setStatus(this.tr("candidate_ambiguous"))
      else if (result.reason === "none") this.setStatus(this.tr("no_candidate"))
    }
  }

  async commitRimeCharacter(character) {
    const range = this.rimeInsertRange || this.captureSelectionRange()
    await this.insertTextAtSelection(character, { convert: true, range, autoRepeat: true })
    this.rimeInsertRange = this.captureSelectionRange() || this.rimeInsertRange
    this.clearRimeCode()
    this.rimeCodeTarget.focus()
  }

  clearRimeCode() {
    this.rimeCodeTarget.value = ""
    this.rimeAdapter?.update("")
  }

  async renderRimeCandidates(rows) {
    const visibleRows = rows.slice(0, 9)
    const sequence = ++this.rimeCandidateRenderSequence
    let displayCharacters = visibleRows.map((row) => row.character)
    const mode = this.document.settings.scriptMode || "original"

    if (mode !== "original" && displayCharacters.some((character) => this.containsHan(character))) {
      try {
        const data = await this.postJson({ operation: "script_batch", mode, texts: displayCharacters })
        if (sequence !== this.rimeCandidateRenderSequence) return
        if (data?.ok && Array.isArray(data.texts) && data.texts.length === displayCharacters.length) {
          displayCharacters = data.texts.map(String)
        }
      } catch (_error) {
        // Candidate selection still works if preview conversion is temporarily unavailable.
      }
    }

    if (sequence !== this.rimeCandidateRenderSequence) return
    this.rimeCandidatesTarget.replaceChildren()
    visibleRows.forEach((row, index) => {
      const button = document.createElement("button")
      button.type = "button"
      button.className = "wp-candidate wp-rime-candidate"
      const indexSpan = document.createElement("span")
      indexSpan.className = "wp-candidate-index"
      indexSpan.textContent = String(index + 1)
      const glyph = document.createElement("span")
      glyph.className = "wp-candidate-glyph"
      glyph.textContent = displayCharacters[index] || row.character
      const code = document.createElement("span")
      code.className = "wp-candidate-label"
      code.textContent = row.code || ""
      button.append(indexSpan, glyph, code)
      button.addEventListener("click", () => {
        if (this.rimeAdapter?.choose(index)) this.clearRimeCode()
      })
      this.rimeCandidatesTarget.appendChild(button)
    })
  }

  openPunctuation() {
    this.syncPunctuationInputs()
    this.showDialog(this.punctuationDialogTarget)
  }

  punctuationChanged(event) {
    const name = event.target?.name || ""
    if (name === "wp_punct_preset") {
      const preset = event.target.value
      this.punctuation.preset = preset
      if (preset !== "custom") this.punctuation.options = punctuationPresetOptions(preset)
    } else {
      this.punctuation.preset = "custom"
      const radio = (selector, fallback) => this.element.querySelector(`${selector}:checked`)?.value || fallback
      this.punctuation.options = {
        ...(this.punctuation.options || punctuationPresetOptions("source")),
        quoteFamily: radio('input[name="wp_quote_family"]', "corner"),
        quoteOrder: radio('input[name="wp_quote_order"]', "trad"),
        comma: radio('input[name="wp_comma"]', "keep"),
        semicolon: radio('input[name="wp_semi"]', "keep"),
        colon: radio('input[name="wp_colon"]', "keep"),
        question: radio('input[name="wp_q"]', "keep"),
        exclamation: radio('input[name="wp_ex"]', "keep"),
        verticalQuoteForms: this.verticalQuotesTarget.checked,
      }
      if (event.target === this.verticalQuotesTarget) this.punctuation.userOverrodeVerticalQuotes = true
    }
    savePunctuationState(this.punctuation)
    this.syncPunctuationInputs()
  }

  syncPunctuationInputs() {
    const choose = (name, value) => {
      const input = this.element.querySelector(`input[name="${name}"][value="${CSS.escape(String(value))}"]`)
      if (input) input.checked = true
    }
    choose("wp_punct_preset", this.punctuation.preset || "source")
    const options = this.punctuation.options || punctuationPresetOptions("source")
    choose("wp_quote_family", options.quoteFamily)
    choose("wp_quote_order", options.quoteOrder)
    choose("wp_comma", options.comma)
    choose("wp_semi", options.semicolon)
    choose("wp_colon", options.colon)
    choose("wp_q", options.question)
    choose("wp_ex", options.exclamation)
    this.verticalQuotesTarget.checked = Boolean(options.verticalQuoteForms)
  }

  convertPunctuationInChapter() {
    const chapter = this.activeChapter()
    if (!chapter) return
    const oldText = chapter.text
    const newText = convertPunctuation(oldText, this.punctuation, { vertical: this.document.settings.vertical })
    if (newText === oldText) return
    chapter.annotations = this.reanchorAnnotations(chapter.annotations, oldText, newText)
    chapter.text = newText
    this.renderEditor({ start: newText.length, end: newText.length })
    this.renderNotes()
    this.renderCounts()
    this.scheduleAutosave()
  }

  reanchorAnnotations(annotations, oldText, newText) {
    return annotations.map((annotation) => {
      if (annotation.end <= annotation.start) {
        const prefix = oldText.slice(Math.max(0, annotation.start - 12), annotation.start)
        const match = prefix ? newText.lastIndexOf(prefix) : -1
        const position = match >= 0 ? match + prefix.length : Math.min(annotation.start, newText.length)
        return { ...annotation, start: position, end: position }
      }

      const anchor = oldText.slice(annotation.start, annotation.end)
      const occurrences = []
      let from = 0
      while (anchor && from <= newText.length) {
        const found = newText.indexOf(anchor, from)
        if (found < 0) break
        occurrences.push(found)
        from = found + Math.max(anchor.length, 1)
      }
      if (occurrences.length === 0) return { ...annotation, start: Math.min(annotation.start, newText.length), end: Math.min(annotation.end, newText.length) }
      occurrences.sort((a, b) => Math.abs(a - annotation.start) - Math.abs(b - annotation.start))
      const start = occurrences[0]
      return { ...annotation, start, end: start + anchor.length }
    })
  }

  openDateDialog() {
    this.closeInsertMenu()
    this.showDialog(this.dateDialogTarget)
    if (this.dateInputTarget.value.trim()) this.queueEraSuggestions()
  }

  setupDateSystems() {
    const options = [
      [this.tr("date_chinese_modern"), "chinese_modern"],
      [this.tr("date_sexagenary"), "sexagenary_year"],
      [this.tr("date_erya"), "erya_year"],
      [this.tr("date_gregorian"), "gregorian"],
      [this.tr("date_julian"), "julian"],
      [this.tr("date_hebrew"), "hebrew"],
      [this.tr("date_islamic"), "islamic_tabular"],
      ...this.dateSystemRows.map((row) => [this.dateSystemLabel(row.key, row.label), row.key]),
    ]
    this.dateOutputTarget.replaceChildren()
    options.forEach(([label, value]) => {
      const option = document.createElement("option")
      option.value = value
      option.textContent = label
      this.dateOutputTarget.appendChild(option)
    })
    this.resetEraSelector()
  }

  dateSystemLabel(key, fallback) {
    const translationKeys = {
      minguo: "date_minguo",
      juche: "date_juche",
      buddhist_era_common: "date_buddhist",
      huangdi_2697: "date_huangdi_2697",
      huangdi_2698: "date_huangdi_2698",
      tangyao: "date_tangyao",
      gonghe: "date_gonghe",
      confucius: "date_confucius",
      unity: "date_unity",
    }
    const translationKey = translationKeys[key]
    return translationKey ? this.tr(translationKey) : this.humanize(key || fallback)
  }

  dateInputChanged() {
    this.queueEraSuggestions()
  }

  dateEraChanged() {
    if (this.dateEraTarget.value) this.dateOutputTarget.disabled = true
    else this.dateOutputTarget.disabled = false
  }

  queueEraSuggestions() {
    clearTimeout(this.eraSuggestionTimer)
    const input = this.dateInputTarget.value.trim()
    if (!input) {
      this.resetEraSelector()
      return
    }

    this.resetEraSelector(this.tr("era_loading"), { disabled: true })
    this.eraSuggestionTimer = window.setTimeout(() => this.refreshEraSuggestions(input), 220)
  }

  async refreshEraSuggestions(input) {
    const sequence = ++this.eraSuggestionSequence
    try {
      const data = await this.postJson({ operation: "era_suggestions", input })
      if (sequence !== this.eraSuggestionSequence) return
      if (!data?.ok) {
        this.resetEraSelector(this.tr("era_unavailable"), { disabled: true })
        return
      }
      this.renderEraSuggestions(Array(data.eras))
    } catch (_error) {
      if (sequence !== this.eraSuggestionSequence) return
      this.resetEraSelector(this.tr("era_unavailable"), { disabled: true })
    }
  }

  resetEraSelector(label = this.tr("era_none"), { disabled = true } = {}) {
    this.dateEraRows = []
    this.dateEraTarget.replaceChildren()
    const option = document.createElement("option")
    option.value = ""
    option.textContent = label
    this.dateEraTarget.appendChild(option)
    this.dateEraTarget.disabled = disabled
    this.dateOutputTarget.disabled = false
  }

  renderEraSuggestions(rows) {
    this.dateEraRows = rows.filter((row) => row && row.expression)
    this.dateEraTarget.replaceChildren()

    const none = document.createElement("option")
    none.value = ""
    none.textContent = this.tr("era_none")
    this.dateEraTarget.appendChild(none)

    this.dateEraRows.forEach((row, index) => {
      const option = document.createElement("option")
      option.value = String(index + 1)
      const prefix = row.country ? `${row.country} — ` : ""
      option.textContent = `${prefix}${row.expression}`
      this.dateEraTarget.appendChild(option)
    })

    if (this.dateEraRows.length === 0) {
      none.textContent = this.tr("era_none_found")
      this.dateEraTarget.disabled = true
      return
    }

    this.dateEraTarget.disabled = false
  }

  selectedEraExpression() {
    const index = Number.parseInt(this.dateEraTarget.value || "0", 10) - 1
    if (!Number.isFinite(index) || index < 0) return null
    return this.dateEraRows[index]?.expression || null
  }

  glossLabel(region) {
    const key = { japan: "gloss_japan", korea: "gloss_korea", vietnam: "gloss_vietnam" }[region]
    return key ? this.tr(key) : this.humanize(region)
  }

  async insertTodayLunar() {
    // Leave the input blank so Rails Date.current supplies the site-local date.
    // Using JavaScript's UTC ISO date can be one day wrong around midnight.
    await this.insertDateValue("", "chinese_modern")
  }

  async insertCustomDate() {
    const input = this.dateInputTarget.value.trim()
    if (!input) {
      this.dateStatusTarget.textContent = this.tr("date_enter")
      return
    }

    const eraExpression = this.selectedEraExpression()
    if (eraExpression) {
      await this.insertTextAtSelection(eraExpression, { convert: true })
      this.dateStatusTarget.textContent = this.tr("inserted")
      this.closeDialogs()
      return
    }

    await this.insertDateValue(input, this.dateOutputTarget.value)
  }

  async insertDateValue(input, output) {
    this.dateStatusTarget.textContent = this.tr("converting")
    try {
      const data = await this.postJson({ operation: "date", input, output })
      if (!data?.ok) throw new Error(data?.error || this.tr("date_failed"))
      const formatted = this.formatArabicNumericRuns(data.text)
      await this.insertTextAtSelection(formatted, { convert: true })
      this.dateStatusTarget.textContent = this.tr("inserted")
      this.closeDialogs()
    } catch (error) {
      this.dateStatusTarget.textContent = error.message || String(error)
    }
  }

  openMeasurementDialog() {
    this.closeInsertMenu()
    this.showDialog(this.measurementDialogTarget)
  }

  openIdsDialog() {
    this.closeInsertMenu()
    this.showDialog(this.idsDialogTarget)
  }

  closeInsertMenu() {
    if (this.hasInsertMenuTarget) this.insertMenuTarget.open = false
  }

  async insertMeasurementResult() {
    const result = this.measurementDialogTarget.querySelector(".measurement-converter__result-main strong")?.textContent?.trim()
    if (!result) {
      this.setStatus(this.tr("measurement_first"))
      return
    }
    await this.insertTextAtSelection(result, { convert: true })
    this.closeDialogs()
  }

  requestConfirmation(message, callback) {
    this.pendingConfirmation = callback
    this.confirmMessageTarget.textContent = message
    this.showDialog(this.confirmDialogTarget)
    this.confirmButtonTarget.focus()
  }

  confirmAction() {
    const callback = this.pendingConfirmation
    this.pendingConfirmation = null
    this.confirmDialogTarget.setAttribute("hidden", "")
    if (typeof callback === "function") callback()
  }

  cancelConfirmation() {
    this.pendingConfirmation = null
    this.confirmDialogTarget.setAttribute("hidden", "")
  }

  openTextEntry({ title, value = "", onSubmit }) {
    this.pendingTextEntry = onSubmit
    this.textEntryTitleTarget.textContent = title
    this.textEntryInputTarget.value = value
    this.showDialog(this.textEntryDialogTarget)
    window.requestAnimationFrame(() => {
      this.textEntryInputTarget.focus()
      this.textEntryInputTarget.select()
    })
  }

  submitTextEntry() {
    const callback = this.pendingTextEntry
    const value = this.textEntryInputTarget.value
    this.pendingTextEntry = null
    this.textEntryDialogTarget.setAttribute("hidden", "")
    if (typeof callback === "function") callback(value)
  }

  cancelTextEntry() {
    this.pendingTextEntry = null
    this.textEntryDialogTarget.setAttribute("hidden", "")
  }

  textEntryKeydown(event) {
    if (event.key === "Escape") {
      event.preventDefault()
      this.cancelTextEntry()
      return
    }
    if ((event.ctrlKey || event.metaKey) && event.key === "Enter") {
      event.preventDefault()
      this.submitTextEntry()
    }
  }

  showDialog(element) {
    this.closeContextMenu()
    element.removeAttribute("hidden")
  }

  closeDialogs() {
    [this.punctuationDialogTarget, this.dateDialogTarget, this.measurementDialogTarget, this.idsDialogTarget, this.confirmDialogTarget, this.textEntryDialogTarget]
      .forEach((dialog) => dialog.setAttribute("hidden", ""))
    this.pendingConfirmation = null
    this.pendingTextEntry = null
  }

  dialogBackdrop(event) {
    if (event.target === event.currentTarget) this.closeDialogs()
  }

  contextMenu(event) {
    event.preventDefault()
    const range = this.captureSelectionRange()
    this.savedContextRange = range || { start: 0, end: 0 }
    const menu = this.contextMenuTarget
    menu.style.left = `${event.pageX}px`
    menu.style.top = `${event.pageY}px`
    menu.removeAttribute("hidden")
  }

  windowPointerDown(event) {
    if (!this.contextMenuTarget.hidden && !this.contextMenuTarget.contains(event.target)) this.closeContextMenu()
    if (this.numeralComposition && !this.numeralComposerPanelTarget.contains(event.target) && !this.editorTarget.contains(event.target)) {
      this.commitActiveNumeralCandidate({ focusEditor: false })
    }
  }

  closeContextMenu() {
    this.contextMenuTarget.setAttribute("hidden", "")
  }

  async contextCopy() {
    const range = this.savedContextRange
    const chapter = this.activeChapter()
    if (!range || !chapter || range.end <= range.start) return
    await navigator.clipboard.writeText(chapter.text.slice(range.start, range.end))
    this.closeContextMenu()
  }

  async contextCut() {
    await this.contextCopy()
    const range = this.savedContextRange
    const chapter = this.activeChapter()
    if (range && chapter && range.end > range.start) {
      this.replaceRange(chapter, range.start, range.end, "")
      this.scheduleAutosave()
    }
    this.closeContextMenu()
  }

  async contextPaste() {
    try {
      const text = await navigator.clipboard.readText()
      await this.insertTextAtSelection(text, { convert: false, range: this.savedContextRange, autoRepeat: false })
    } catch (_error) {
      this.setStatus(this.tr("clipboard_fail"))
    }
    this.closeContextMenu()
  }

  contextAddToShelf() {
    const range = this.savedContextRange
    const chapter = this.activeChapter()
    if (!range || !chapter) return
    let value = ""
    if (range.end > range.start) {
      value = chapter.text.slice(range.start, range.end)
    } else {
      const cp = chapter.text.codePointAt(range.start)
      if (cp) value = String.fromCodePoint(cp)
    }
    value = value.trim()
    if (!value) return
    this.myShelf = [value, ...this.myShelf.filter((entry) => this.shelfEntryText(entry) !== value)].slice(0, 100)
    this.document.shelves.pinned = this.myShelf
    this.saveShelf()
    this.renderPinnedShelf()
    this.renderShortcutList()
    this.scheduleAutosave()
    this.setStatus(this.tr("added_to_shelf"))
    this.closeContextMenu()
  }

  applyContextAnnotation(event) {
    const kind = event.currentTarget.dataset.kind
    const range = this.savedContextRange
    if (!MARK_CLASSES[kind] || !range || range.end <= range.start) {
      this.setStatus(this.tr("select_text_mark"))
      return
    }
    this.addAnnotation({ kind, start: range.start, end: range.end })
    this.closeContextMenu()
  }

  removeContextMarks() {
    const range = this.savedContextRange
    const chapter = this.activeChapter()
    if (!range || !chapter) return
    chapter.annotations = chapter.annotations.filter((annotation) => {
      if (!MARK_CLASSES[annotation.kind]) return true
      return annotation.end <= range.start || annotation.start >= range.end
    })
    this.renderEditor(range)
    this.scheduleAutosave()
    this.closeContextMenu()
  }

  addComment() {
    this.openAnnotationEntry("comment", this.tr("comment"))
  }

  addNote() {
    this.openAnnotationEntry("note", this.tr("note"))
  }

  openAnnotationEntry(kind, label) {
    const range = this.savedContextRange || this.captureSelectionRange() || { start: 0, end: 0 }
    this.closeContextMenu()
    this.openTextEntry({
      title: this.tr("annotation_prompt", { label }),
      value: "",
      onSubmit: (value) => {
        if (!value.trim()) return
        this.addAnnotation({ kind, start: range.start, end: range.end, note: value.trim() })
      },
    })
  }

  addGloss(event) {
    const region = event.currentTarget.dataset.region
    const range = this.savedContextRange
    if (!range || range.end <= range.start) {
      this.setStatus(this.tr("select_gloss"))
      return
    }
    this.closeContextMenu()
    this.openTextEntry({
      title: this.tr("gloss_prompt", { label: this.glossLabel(region) }),
      value: "",
      onSubmit: (value) => {
        if (!value.trim()) return
        this.addAnnotation({ kind: "gloss", start: range.start, end: range.end, region, reading: value.trim() })
      },
    })
  }

  addAnnotation(fields) {
    const chapter = this.activeChapter()
    if (!chapter) return
    chapter.annotations.push({ id: this.uuid("annotation"), ...fields })
    this.renderEditor({ start: fields.end, end: fields.end })
    this.renderNotes()
    this.scheduleAutosave()
  }

  renderNotes() {
    const chapter = this.activeChapter()
    this.notesListTarget.replaceChildren()
    const rows = (chapter?.annotations || []).filter((annotation) => annotation.note || annotation.kind === "gloss")
    if (rows.length === 0) {
      const empty = document.createElement("p")
      empty.className = "wp-small wp-muted"
      empty.textContent = this.tr("no_notes")
      this.notesListTarget.appendChild(empty)
      return
    }

    rows.forEach((annotation) => {
      const row = document.createElement("div")
      row.className = "wp-note-row"
      const text = document.createElement("span")
      const body = annotation.kind === "gloss" ? annotation.reading : annotation.note
      text.textContent = `${this.annotationKindLabel(annotation.kind)}: ${body || ""}`
      const edit = document.createElement("button")
      edit.type = "button"
      edit.className = "wp-mini-button"
      edit.textContent = this.tr("edit")
      edit.dataset.annotationId = annotation.id
      edit.dataset.action = "word-processor#editNote"
      const remove = document.createElement("button")
      remove.type = "button"
      remove.className = "wp-mini-button"
      remove.textContent = this.tr("delete")
      remove.dataset.annotationId = annotation.id
      remove.dataset.action = "word-processor#deleteNote"
      row.append(text, edit, remove)
      this.notesListTarget.appendChild(row)
    })
  }

  editNote(event) {
    const chapter = this.activeChapter()
    const annotation = chapter?.annotations.find((item) => item.id === event.currentTarget.dataset.annotationId)
    if (!annotation) return
    const field = annotation.kind === "gloss" ? "reading" : "note"
    this.openTextEntry({
      title: this.tr("edit_prompt"),
      value: annotation[field] || "",
      onSubmit: (value) => {
        annotation[field] = value
        this.renderEditor()
        this.renderNotes()
        this.scheduleAutosave()
      },
    })
  }

  deleteNote(event) {
    const chapter = this.activeChapter()
    if (!chapter) return
    chapter.annotations = chapter.annotations.filter((item) => item.id !== event.currentTarget.dataset.annotationId)
    this.renderEditor()
    this.renderNotes()
    this.scheduleAutosave()
  }

  captureSelectionRange() {
    const selection = window.getSelection()
    if (!selection || selection.rangeCount === 0) return null
    const range = selection.getRangeAt(0)
    if (!this.editorTarget.contains(range.startContainer) || !this.editorTarget.contains(range.endContainer)) return null
    return {
      start: this.offsetForPoint(range.startContainer, range.startOffset),
      end: this.offsetForPoint(range.endContainer, range.endOffset),
    }
  }

  offsetForPoint(node, offset) {
    const range = document.createRange()
    range.selectNodeContents(this.editorTarget)
    range.setEnd(node, offset)
    const clone = range.cloneContents()
    const holder = document.createElement("div")
    holder.appendChild(clone)
    holder.querySelectorAll("rt, rp").forEach((element) => element.remove())
    return (holder.textContent || "").length
  }

  restoreSelection(range) {
    if (!range) return
    const start = this.pointForOffset(range.start)
    const end = this.pointForOffset(range.end)
    if (!start || !end) return
    const selection = window.getSelection()
    if (!selection) return
    const domRange = document.createRange()
    domRange.setStart(start.node, start.offset)
    domRange.setEnd(end.node, end.offset)
    selection.removeAllRanges()
    selection.addRange(domRange)
  }

  pointForOffset(wanted) {
    const walker = document.createTreeWalker(this.editorTarget, NodeFilter.SHOW_TEXT, {
      acceptNode: (node) => node.parentElement?.closest("rt, rp") ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT,
    })
    let consumed = 0
    let last = null
    while (walker.nextNode()) {
      const node = walker.currentNode
      last = node
      const length = (node.nodeValue || "").length
      if (wanted <= consumed + length) return { node, offset: Math.max(0, wanted - consumed) }
      consumed += length
    }
    if (last) return { node: last, offset: (last.nodeValue || "").length }
    const node = document.createTextNode("")
    this.editorTarget.appendChild(node)
    return { node, offset: 0 }
  }

  syncControlsFromDocument() {
    this.scriptModeTarget.value = this.document.settings.scriptMode || this.initialScriptModeValue || "original"
    this.repeatMarkTarget.value = this.document.settings.repeatMark || ""
    this.autoRepeatTarget.checked = Boolean(this.document.settings.autoRepeat)
    this.numeralSystemTarget.value = this.document.settings.numeralSystem || "han"
  }

  renderCounts() {
    const chapter = this.activeChapter()
    const characters = Array.from(chapter?.text || "").length
    const chapterWord = this.document.chapters.length === 1 ? this.tr("chapter_singular") : this.tr("chapter_plural")
    this.countsTarget.textContent = `${characters.toLocaleString()} ${this.tr("characters")} · ${this.document.chapters.length} ${chapterWord}`
  }

  prepareTicket() {
    this.syncEditorToModel()
    const ticket = this.element.querySelector('[data-controller~="corpus-submission-ticket"]')
    if (!ticket) return
    const title = ticket.querySelector('[data-corpus-submission-ticket-target~="workTitle"]')
    const summary = ticket.querySelector('[data-corpus-submission-ticket-target~="summary"]')
    const folder = ticket.querySelector('[data-corpus-submission-ticket-target~="workFolder"]')
    const pages = ticket.querySelector('[data-corpus-submission-ticket-target~="pagesList"]')
    if (title) title.value = this.document.title
    if (summary && !summary.value) summary.value = this.tr("ticket_summary", { title: this.document.title || this.tr("untitled_document") })
    if (folder && !folder.value && this.document.title) folder.value = this.document.title
    if (pages) {
      pages.replaceChildren()
      this.document.chapters.forEach((chapter) => {
        const card = document.createElement("div")
        card.className = "cv-submission-page-card"
        const label = document.createElement("input")
        label.type = "text"
        label.dataset.role = "page-label"
        label.value = chapter.title
        const body = document.createElement("textarea")
        body.dataset.role = "page-body"
        body.value = chapter.text
        body.rows = 8
        card.append(label, body)
        pages.appendChild(card)
      })
    }
    this.setStatus(this.tr("ticket_prepared"))
  }

  newDocument() {
    this.requestConfirmation(this.tr("new_confirm"), () => {
      this.cancelNumeralComposition({ restoreCaret: false })
      this.document = this.defaultDocument()
      this.document.shelves.pinned = this.myShelf
      this.syncControlsFromDocument()
      this.renderAll()
      this.scheduleAutosave()
    })
  }

  async openFile(event) {
    this.cancelNumeralComposition({ restoreCaret: false })
    const file = event.target.files?.[0]
    if (!file) return
    try {
      if (file.name.toLowerCase().endsWith(".docx")) {
        await this.importDocx(file)
      } else {
        const text = await file.text()
        const clean = text.charCodeAt(0) === 0xFEFF ? text.slice(1) : text
        if (file.name.toLowerCase().endsWith(".json")) {
          this.document = this.normaliseDocument(JSON.parse(clean))
          this.mergeProjectShelf()
        } else {
          const chapter = this.newChapterObject(file.name.replace(/\.txt$/i, "") || this.tr("chapter_number", { number: 1 }))
          chapter.text = clean
          this.document = this.defaultDocument()
          this.document.shelves.pinned = this.myShelf
          this.document.title = chapter.title
          this.document.chapters = [chapter]
          this.document.activeChapterId = chapter.id
        }
        this.syncControlsFromDocument()
        this.renderAll()
        this.scheduleAutosave()
      }
      this.setStatus(this.tr("opened_file", { name: file.name }))
    } catch (error) {
      this.setStatus(this.tr("open_file_error", { message: error.message || error }))
    } finally {
      event.target.value = ""
    }
  }

  async importDocx(file) {
    const form = new FormData()
    form.append("operation", "docx_import")
    form.append("file", file)
    const response = await fetch(this.convertUrlValue, {
      method: "POST",
      headers: { "Accept": "application/json", "X-CSRF-Token": this.csrfToken() },
      body: form,
      credentials: "same-origin",
    })
    const data = await response.json().catch(() => ({}))
    if (!response.ok || !data.ok) throw new Error(data.error || this.tr("docx_import_failed", { status: response.status }))

    const imported = data.document || {}
    const base = this.defaultDocument()
    base.shelves.pinned = this.myShelf
    base.title = imported.title || file.name.replace(/\.docx$/i, "")
    base.chapters = Array(imported.chapters || [])
    base.activeChapterId = base.chapters[0]?.id
    this.document = this.normaliseDocument(base)
    this.syncControlsFromDocument()
    this.renderAll()
    this.scheduleAutosave()
  }

  downloadProject() {
    this.syncEditorToModel()
    this.document.shelves.pinned = this.myShelf
    const name = this.safeFilename(this.document.title || "Fanya Word Processor")
    const json = JSON.stringify(this.document, null, 2)
    this.downloadText(`${name}.fanyawp.json`, json)
    this.setStatus(this.tr("project_saved"))
  }

  downloadTxt() {
    this.syncEditorToModel()
    const chapter = this.activeChapter()
    if (!chapter) return
    const name = this.safeFilename(chapter.title || this.document.title || "chapter")
    this.downloadText(`${name}.txt`, chapter.text)
  }

  downloadText(filename, text) {
    const blob = new Blob(["\uFEFF", text], { type: "text/plain;charset=utf-8" })
    const url = URL.createObjectURL(blob)
    const anchor = document.createElement("a")
    anchor.href = url
    anchor.download = filename
    document.body.appendChild(anchor)
    anchor.click()
    anchor.remove()
    URL.revokeObjectURL(url)
  }

  safeFilename(value) {
    return String(value || "document").replace(/[\\/:*?"<>|]/g, "_").trim() || "document"
  }

  loadShortcuts() {
    try {
      const value = JSON.parse(window.localStorage.getItem(SHORTCUTS_KEY) || "{}")
      return value && typeof value === "object" ? value : {}
    } catch (_error) {
      return {}
    }
  }

  saveShortcuts() {
    window.localStorage.setItem(SHORTCUTS_KEY, JSON.stringify(this.shortcuts))
  }

  assignShortcut(action, binding) {
    if (!action || !binding) return
    Object.keys(this.shortcuts).forEach((key) => {
      if (key !== action && this.shortcuts[key] === binding) delete this.shortcuts[key]
    })
    this.shortcuts[action] = binding
  }

  shortcutActionRows() {
    const shelfRows = this.myShelf.map((entry) => {
      const text = this.shelfEntryText(entry)
      return [`shelf:${encodeURIComponent(text)}`, this.tr("shortcut_shelf", { text })]
    })
    const builtIns = SHORTCUT_ACTIONS.map(([action, key]) => [action, this.tr(key)])
    return [...builtIns, ...shelfRows]
  }

  renderShortcutList() {
    this.shortcutListTarget.replaceChildren()
    this.shortcutActionRows().forEach(([action, label]) => {
      const row = document.createElement("div")
      row.className = "wp-shortcut-row"
      const name = document.createElement("span")
      name.textContent = label
      const current = document.createElement("code")
      current.textContent = this.shortcuts[action] || this.tr("not_bound")
      const bind = document.createElement("button")
      bind.type = "button"
      bind.className = "wp-mini-button"
      bind.textContent = this.awaitingShortcutAction === action ? this.tr("press_binding") : this.tr("bind")
      bind.dataset.shortcutAction = action
      bind.dataset.action = "word-processor#bindShortcut"
      row.append(name, current, bind)
      this.shortcutListTarget.appendChild(row)
    })
  }

  bindShortcut(event) {
    this.awaitingShortcutAction = event.currentTarget.dataset.shortcutAction
    this.renderShortcutList()
  }

  clearShortcuts() {
    this.shortcuts = {}
    this.awaitingShortcutAction = null
    this.saveShortcuts()
    this.renderShortcutList()
  }

  windowKeydown(event) {
    if (this.awaitingShortcutAction) {
      event.preventDefault()
      const binding = this.keyboardBinding(event)
      this.assignShortcut(this.awaitingShortcutAction, binding)
      this.awaitingShortcutAction = null
      this.saveShortcuts()
      this.renderShortcutList()
      return
    }

    const binding = this.keyboardBinding(event)
    const action = Object.keys(this.shortcuts).find((key) => this.shortcuts[key] === binding)
    if (!action) return
    event.preventDefault()
    this.runShortcut(action)
  }

  keyboardBinding(event) {
    const parts = []
    if (event.ctrlKey) parts.push("Control")
    if (event.altKey) parts.push("Alt")
    if (event.shiftKey) parts.push("Shift")
    if (event.metaKey) parts.push("Meta")
    parts.push(event.code || event.key)
    return parts.join("+")
  }

  startGamepadPolling() {
    const poll = () => {
      const gamepads = navigator.getGamepads ? Array.from(navigator.getGamepads()).filter(Boolean) : []
      gamepads.forEach((gamepad) => {
        gamepad.buttons.forEach((button, buttonIndex) => {
          const key = `${gamepad.index}:${buttonIndex}`
          const before = this.gamepadButtons.get(key) || false
          const pressed = Boolean(button.pressed)
          if (pressed && !before) this.gamepadPressed(gamepad.index, buttonIndex)
          this.gamepadButtons.set(key, pressed)
        })
      })
      this.gamepadFrame = requestAnimationFrame(poll)
    }
    this.gamepadFrame = requestAnimationFrame(poll)
  }

  gamepadPressed(gamepadIndex, buttonIndex) {
    const binding = `Gamepad${gamepadIndex}:Button${buttonIndex}`
    if (this.awaitingShortcutAction) {
      this.assignShortcut(this.awaitingShortcutAction, binding)
      this.awaitingShortcutAction = null
      this.saveShortcuts()
      this.renderShortcutList()
      return
    }
    const action = Object.keys(this.shortcuts).find((key) => this.shortcuts[key] === binding)
    if (action) this.runShortcut(action)
  }

  runShortcut(action) {
    if (action.startsWith("shelf:")) {
      const wanted = decodeURIComponent(action.slice("shelf:".length))
      const entry = this.myShelf.find((item) => this.shelfEntryText(item) === wanted)
      if (entry) this.insertShelfEntryValue(entry)
      return
    }
    if (action === "repeat") this.insertRepeatMark()
    else if (action === "orientation") this.toggleOrientation()
    else if (action === "punctuation") this.openPunctuation()
    else if (action === "date") this.openDateDialog()
    else if (action === "measurement") this.openMeasurementDialog()
    else if (action === "save_project") this.downloadProject()
    else if (action === "download_txt") this.downloadTxt()
    else if (action === "proper_name") {
      this.savedContextRange = this.captureSelectionRange()
      this.applyContextAnnotation({ currentTarget: { dataset: { kind: "proper_name" } } })
    } else if (action === "comment") {
      this.savedContextRange = this.captureSelectionRange()
      this.addComment()
    }
  }

  async openAutosaveDatabase() {
    if (!window.indexedDB) throw new Error("IndexedDB unavailable")
    return new Promise((resolve, reject) => {
      const request = window.indexedDB.open("fanya-word-processor", 1)
      request.onupgradeneeded = () => {
        const db = request.result
        if (!db.objectStoreNames.contains("projects")) db.createObjectStore("projects")
      }
      request.onsuccess = () => resolve(request.result)
      request.onerror = () => reject(request.error)
    })
  }

  async loadAutosave() {
    try {
      const db = await this.openAutosaveDatabase()
      const value = await new Promise((resolve, reject) => {
        const tx = db.transaction("projects", "readonly")
        const request = tx.objectStore("projects").get(AUTOSAVE_KEY)
        request.onsuccess = () => resolve(request.result || null)
        request.onerror = () => reject(request.error)
      })
      db.close()
      return value
    } catch (_error) {
      try {
        const raw = window.localStorage.getItem(AUTOSAVE_FALLBACK_KEY)
        return raw ? JSON.parse(raw) : null
      } catch (_fallbackError) {
        return null
      }
    }
  }

  scheduleAutosave() {
    clearTimeout(this.autosaveTimer)
    this.autosaveTimer = setTimeout(() => this.saveAutosave(), 350)
  }

  async saveAutosave() {
    this.document.shelves.pinned = this.myShelf
    try {
      const db = await this.openAutosaveDatabase()
      await new Promise((resolve, reject) => {
        const tx = db.transaction("projects", "readwrite")
        tx.objectStore("projects").put(this.document, AUTOSAVE_KEY)
        tx.oncomplete = () => resolve()
        tx.onerror = () => reject(tx.error)
      })
      db.close()
      this.setStatus(this.tr("saved_local"))
    } catch (_error) {
      try {
        window.localStorage.setItem(AUTOSAVE_FALLBACK_KEY, JSON.stringify(this.document))
        this.setStatus(this.tr("saved_fallback"))
      } catch (_fallbackError) {
        this.setStatus(this.tr("autosave_failed"))
      }
    }
  }

  async postJson(payload) {
    const response = await fetch(this.convertUrlValue, {
      method: "POST",
      headers: {
        "Accept": "application/json",
        "Content-Type": "application/json",
        "X-CSRF-Token": this.csrfToken(),
      },
      credentials: "same-origin",
      body: JSON.stringify(payload),
    })
    const data = await response.json().catch(() => ({}))
    if (!response.ok) throw new Error(data.error || this.tr("request_failed", { status: response.status }))
    return data
  }

  csrfToken() {
    return document.querySelector('meta[name="csrf-token"]')?.content || ""
  }

  containsHan(text) {
    try {
      return /\p{Script=Han}/u.test(String(text || ""))
    } catch (_error) {
      return /[\u3400-\u9FFF]/.test(String(text || ""))
    }
  }

  isHan(character) {
    try {
      return /^\p{Script=Han}$/u.test(character)
    } catch (_error) {
      return /^[\u3400-\u9FFF]$/.test(character)
    }
  }

  functionCategoryLabel(category) {
    const key = `function_category_${category}`
    const translated = this.tr(key)
    return translated === `word_processor.${key}` ? this.humanize(category) : translated
  }

  functionImportanceLabel(importance) {
    const key = `function_importance_${importance}`
    const translated = this.tr(key)
    return translated === `word_processor.${key}` ? this.humanize(importance) : translated
  }

  annotationKindLabel(kind) {
    const key = `annotation_kind_${kind}`
    const translated = this.tr(key)
    return translated === `word_processor.${key}` ? this.humanize(kind) : translated
  }

  humanize(value) {
    return String(value || "").replace(/_/g, " ").replace(/\b\w/g, (letter) => letter.toUpperCase())
  }

  setStatus(message) {
    this.statusTarget.textContent = message
  }
}
