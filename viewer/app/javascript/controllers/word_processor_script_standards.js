import { normaliseHanFontSize } from "controllers/han_typography"

const INSTALL_KEY = Symbol.for("fanya.wordProcessor.scriptStandards.v1")
const BATCH_LIMIT = 50

export function insertedReplacementFromDiff(oldText, newText, diff) {
  const source = String(newText || "")
  const start = Math.max(0, Number(diff?.newStart) || 0)
  const end = Math.max(start, Number(diff?.newEnd) || start)
  return source.slice(start, end)
}

function uniqueAnnotationBoundaries(annotations, textLength) {
  const values = new Set([0, Math.max(0, Number(textLength) || 0)])
  Array.from(annotations || []).forEach((annotation) => {
    const start = Number(annotation?.start)
    const end = Number(annotation?.end)
    if (Number.isFinite(start)) values.add(Math.max(0, Math.min(start, textLength)))
    if (Number.isFinite(end)) values.add(Math.max(0, Math.min(end, textLength)))
  })
  return Array.from(values).sort((a, b) => a - b)
}

export function installWordProcessorScriptStandards(ControllerClass) {
  const prototype = ControllerClass?.prototype
  if (!prototype || prototype[INSTALL_KEY]) return
  prototype[INSTALL_KEY] = true

  const priorConnect = prototype.connect
  const priorSyncEditorToModel = prototype.syncEditorToModel

  prototype.connect = async function(...args) {
    const result = await priorConnect.apply(this, args)
    this.wpInstallConvertAllButton()
    return result
  }

  prototype.wpScriptMode = function() {
    return String(this.document?.settings?.scriptMode || this.scriptModeTarget?.value || "original")
  }

  prototype.wpScriptModeActive = function() {
    return this.wpScriptMode() !== "original"
  }

  // The original Writer only queued conversion when an edit was a pure
  // insertion (oldStart === oldEnd). System IMEs commonly finalise a Han input
  // as a replacement of their composition range, so those commits bypassed the
  // selected character standard and appeared exactly as the operating-system
  // keyboard produced them. Treat every newly committed replacement segment as
  // eligible for conversion. Deletions still contain no inserted segment and
  // therefore do not trigger a conversion request.
  prototype.syncEditorToModel = function(options = {}) {
    const convertInserted = options?.convertInserted === true
    if (!convertInserted || !this.wpScriptModeActive()) {
      return priorSyncEditorToModel.call(this, options)
    }

    const chapter = this.activeChapter()
    if (!chapter) return priorSyncEditorToModel.call(this, options)

    const oldText = String(chapter.text || "")
    const newText = this.editorPlainText()
    const diff = this.diffText(oldText, newText)
    const inserted = insertedReplacementFromDiff(oldText, newText, diff)

    // Own the conversion decision here. Passing false prevents the older
    // simple-insertion-only branch from racing this wider IME-safe path.
    const result = priorSyncEditorToModel.call(this, { ...options, convertInserted: false })

    if (!inserted || !this.containsHan(inserted)) return result
    const liveChapter = this.document?.chapters?.find((candidate) => String(candidate.id) === String(chapter.id))
    if (!liveChapter) return result

    const start = Math.max(0, Number(diff.newStart) || 0)
    const end = Math.min(String(liveChapter.text || "").length, start + inserted.length)
    const liveInserted = String(liveChapter.text || "").slice(start, end)
    if (!liveInserted || !this.containsHan(liveInserted)) return result

    this.enqueueCommittedInsertion(liveChapter.id, start, end, liveInserted)
    return result
  }

  prototype.wpInstallConvertAllButton = function() {
    if (this.wpConvertAllButton?.isConnected) return
    const selectionButton = this.element?.querySelector?.('[data-action~="word-processor#convertSelectionToScript"]')
    if (!selectionButton?.parentNode) return

    const button = document.createElement("button")
    button.type = "button"
    button.className = "corpus-btn"
    button.dataset.wpConvertAll = "true"
    button.textContent = this.tr?.("convert_all") || "Convert all"
    button.addEventListener("click", () => this.convertAllToScript())
    selectionButton.insertAdjacentElement("afterend", button)
    this.wpConvertAllButton = button
  }

  prototype.wpScriptBatchConvert = async function(texts, mode = this.wpScriptMode()) {
    const values = Array.from(texts || []).map((value) => String(value || ""))
    const output = []
    for (let index = 0; index < values.length; index += BATCH_LIMIT) {
      const chunk = values.slice(index, index + BATCH_LIMIT)
      const data = await this.postJson({ operation: "script_batch", mode, texts: chunk })
      if (!data?.ok || !Array.isArray(data.texts) || data.texts.length !== chunk.length) {
        throw new Error(data?.error || "Character-standard batch conversion failed.")
      }
      output.push(...data.texts.map((value) => String(value || "")))
    }
    return output
  }

  prototype.wpRemapAnnotationsForWholeConversion = async function(chapter, oldText, newText, mode) {
    const annotations = Array.from(chapter.annotations || [])
    if (!annotations.length || oldText.length === newText.length) return annotations

    // Script conversions normally preserve UTF-16 length. For the exceptional
    // one-to-many/phrase case, ask the same converter for every annotation
    // prefix. The converted prefix length gives a stable source boundary and
    // prevents a whole-document replacement from collapsing interior 夾注、批注,
    // ruby, title, place, or other ranges to the document edges.
    const boundaries = uniqueAnnotationBoundaries(annotations, oldText.length)
    const prefixes = boundaries.map((offset) => oldText.slice(0, offset))
    const convertedPrefixes = await this.wpScriptBatchConvert(prefixes, mode)
    const mapped = new Map(boundaries.map((offset, index) => [offset, convertedPrefixes[index].length]))

    return annotations.map((annotation) => {
      const start = Number(annotation?.start)
      const end = Number(annotation?.end)
      if (!Number.isFinite(start) || !Number.isFinite(end)) return annotation
      return {
        ...annotation,
        start: mapped.get(start) ?? start,
        end: mapped.get(end) ?? end,
      }
    })
  }

  prototype.convertAllToScript = async function() {
    const mode = this.wpScriptMode()
    if (mode === "original" || this.wpConvertAllRunning) return

    const chapters = Array.from(this.document?.chapters || [])
    if (!chapters.length) return

    const snapshots = chapters.map((chapter) => ({
      id: chapter.id,
      text: String(chapter.text || ""),
      annotations: Array.from(chapter.annotations || []),
    }))

    this.wpConvertAllRunning = true
    if (this.wpConvertAllButton) this.wpConvertAllButton.disabled = true
    this.setStatus?.(this.tr?.("convert_all_working") || "Applying character standard…")

    const generation = this.wpHistory?.generation ?? null
    const ownsHistory = this.wpBeginHistoryTransaction?.() || false

    try {
      const convertedTexts = await this.wpScriptBatchConvert(snapshots.map((row) => row.text), mode)
      let changed = 0
      let skipped = 0

      for (let index = 0; index < snapshots.length; index += 1) {
        const snapshot = snapshots[index]
        const chapter = chapters.find((candidate) => String(candidate.id) === String(snapshot.id))
        if (!chapter || String(chapter.text || "") !== snapshot.text) {
          skipped += 1
          continue
        }

        const converted = convertedTexts[index]
        if (converted === snapshot.text) continue
        chapter.annotations = await this.wpRemapAnnotationsForWholeConversion(chapter, snapshot.text, converted, mode)
        chapter.text = converted
        changed += 1
      }

      this.wpSemanticPruneInvalid?.()
      const active = this.activeChapter()
      this.renderEditor({ start: active?.text?.length || 0, end: active?.text?.length || 0 })
      this.renderNotes()
      this.renderCounts()
      this.scheduleAutosave()

      const message = skipped > 0
        ? (this.tr?.("convert_all_done_with_skips", { count: changed, skipped }) || `Converted ${changed} chapter(s); skipped ${skipped} changed during conversion.`)
        : (this.tr?.("convert_all_done", { count: changed }) || `Converted ${changed} chapter(s).`)
      this.setStatus?.(message)
    } catch (_error) {
      this.setStatus?.(this.tr?.("conversion_unavailable") || "Character-standard conversion is unavailable.")
    } finally {
      this.wpEndHistoryTransaction?.(ownsHistory, generation)
      this.wpConvertAllRunning = false
      if (this.wpConvertAllButton) this.wpConvertAllButton.disabled = false
      // Reapply the shared metric in case a render replaced toolbar-adjacent UI.
      const size = normaliseHanFontSize(this.document?.settings?.fontSizePx ?? 20)
      if (this.viewboxTarget) this.viewboxTarget.style.setProperty("--han-main-font-size", `${size}px`)
    }
  }
}
