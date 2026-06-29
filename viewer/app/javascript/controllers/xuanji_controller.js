import { Controller } from "@hotwired/stimulus"
import { t } from "i18n"

// Xuanji Tu controller
//
// Responsibilities:
// 1) Build coordinate paths for reading rules (rows/cols/snakes/Kang helpers)
// 2) Manual selection (click + drag), stored as an ordered path
// 3) Animate a path on the SVG
// 4) Extract text into the embedded corpus-reader (optional phoneticization)
export default class extends Controller {
  static values = {
    cells: Array,
    width: Number,
    height: Number,
    variant: String,
  }

  static targets = [
    "rule",
    "lineLen",
    "speed",
    "output",
    "coupletComma",
    "playBtn",
    "clearManualBtn",
    "showPhon",
    "readingSystem",
  ]

  connect() {
    // Build a fast lookup: "x,y" -> char / color
    this.charAt = new Map()
    this.colorAt = new Map()
    for (const c of this.cellsValue) {
      this.charAt.set(`${c.x},${c.y}`, c.char)
      this.colorAt.set(`${c.x},${c.y}`, c.color || null)
    }

    this.timer = null
    this.stepIndex = 0
    this.currentPath = []

    this.manualPath = this._loadManualPath()
    this._pointerDown = false
    this._lastDragKey = null

    this.rebuild()
  }

  disconnect() {
    this.pause()
  }

  // --- UI hooks ---------------------------------------------------------

  ruleChanged() {
    this.rebuild()
  }

  phonSettingsChanged() {
    // Only re-render; no need to rebuild the path.
    this.renderTextPreview()
  }

  clearManual() {
    this.manualPath = []
    this._saveManualPath()
    this._renderManualHighlights()

    if (this.ruleTarget.value === "manual") {
      this.rebuild()
    }
  }

  // --- Manual selection (pointer events on the SVG) ---------------------

  pointerDown(event) {
    if (!event) return
    if (this.ruleTarget.value !== "manual") return

    const hit = this._cellFromEvent(event)
    if (!hit) return

    this._pointerDown = true
    this._lastDragKey = null

    // Capture so pointerMove continues even if we leave the SVG.
    event.target?.setPointerCapture?.(event.pointerId)

    this._toggleManualAt(hit.x, hit.y)
  }

  pointerMove(event) {
    if (!this._pointerDown) return
    if (this.ruleTarget.value !== "manual") return

    const hit = this._cellFromEvent(event)
    if (!hit) return

    const key = `${hit.x},${hit.y}`
    if (key === this._lastDragKey) return
    this._lastDragKey = key

    // Drag selection is "path-respecting":
    // - If we hit a new cell, append it.
    // - If we drag back onto an existing cell, truncate back to it.
    this._appendOrTruncateTo(hit.x, hit.y)
  }

  pointerUp(_event) {
    this._pointerDown = false
    this._lastDragKey = null
  }

  // --- Core rebuild / render -------------------------------------------

  rebuild() {
    this.pause()
    this.clearHighlights()
    this.stepIndex = 0

    const rule = this.ruleTarget.value
    if (rule === "manual") {
      this.currentPath = [...this.manualPath]
      this._renderManualHighlights(true)
    } else {
      this.currentPath = this.buildPath(rule)
      this._renderManualHighlights(false)
    }

    this.renderTextPreview()

    if (this.hasPlayBtnTarget) {
      this.playBtnTarget.textContent = t("fun.xuanji.play")
    }
  }

  buildPath(rule) {
    const w = this.widthValue
    const h = this.heightValue

    switch (rule) {
      case "rows_lr":
        return this.rowsLR(w, h)
      case "rows_rl":
        return this.rowsLR(w, h).reverse()
      case "cols_tb":
        return this.colsTB(w, h)
      case "cols_bt":
        return this.colsTB(w, h).reverse()
      case "snake_rows":
        return this.snakeRows(w, h)
      case "snake_cols":
        return this.snakeCols(w, h)
      case "kang_perimeter":
        return this.perimeterRing(w, h, 0)
      case "kang_boundary":
        return this.boundaryCells(w, h)
      default:
        return this.rowsLR(w, h)
    }
  }

  renderTextPreview() {
    const raw = this.currentPath.map(([x, y]) => this.charAt.get(`${x},${y}`) || "").join("")
    const n = parseInt(this.lineLenTarget.value || "7", 10)
    const coupletComma = this.hasCoupletCommaTarget ? this.coupletCommaTarget.checked : true

    const segmented = this.segment(raw, n, coupletComma)

    const wantsPhon = this.hasShowPhonTarget && this.showPhonTarget.checked
    if (!wantsPhon) {
      this.outputTarget.textContent = segmented
      this._notifyReaderRefresh()
      return
    }

    // Render text immediately, then fetch phoneticization.
    this.outputTarget.textContent = segmented
    this._notifyReaderRefresh()

    this._fetchPhoneticization(segmented).catch(() => {
      // If something fails, keep the Han output.
    })
  }

  // --- Output shaping ---------------------------------------------------

  segment(text, n, coupletComma = true) {
    if (!n || n <= 0) return text

    const lines = []
    for (let i = 0; i < text.length; i += n) {
      const line = text.slice(i, i + n)
      if (line) lines.push(line)
    }

    // Render as couplets: line1，line2
    const out = []
    for (let i = 0; i < lines.length; i += 2) {
      const a = lines[i]
      const b = lines[i + 1]
      if (b) {
        out.push(coupletComma ? `${a}，${b}` : `${a}\n${b}`)
      } else {
        out.push(a)
      }
    }

    return out.join("\n")
  }

  async _fetchPhoneticization(segmentedText) {
    const system = this.hasReadingSystemTarget ? (this.readingSystemTarget.value || "mandarin") : "mandarin"
    const lines = segmentedText.split("\n")

    const token = document.querySelector('meta[name="csrf-token"]')?.getAttribute("content")

    const res = await fetch("/fun/xuanji/phoneticize", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Accept": "application/json",
        ...(token ? { "X-CSRF-Token": token } : {}),
      },
      credentials: "same-origin",
      body: JSON.stringify({ lines, system }),
    })

    if (!res.ok) return
    const data = await res.json()
    if (!data || data.ok !== true) return

    const phonLines = Array.isArray(data.lines) ? data.lines : []

    // Build HTML so punctuation stripping can ignore the phoneticization lines.
    const esc = (s) => (s || "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")

    const parts = []
    for (let i = 0; i < lines.length; i++) {
      const han = lines[i] || ""
      const phon = phonLines[i] || ""
      parts.push(`<span class="xuanji-han">${esc(han)}</span>`)
      parts.push("\n")
      parts.push(`<span class="xuanji-phon">${esc(phon)}</span>`)
      if (i < lines.length - 1) parts.push("\n")
    }

    // Only apply if the user still wants it.
    if (!(this.hasShowPhonTarget && this.showPhonTarget.checked)) return

    this.outputTarget.innerHTML = parts.join("")
    this._notifyReaderRefresh()
  }

  _notifyReaderRefresh() {
    // Tell corpus-reader to refresh its cached baseline, then re-apply any current
    // options (punct stripping, vertical mode, etc.).
    window.dispatchEvent(new CustomEvent("corpus-reader-refresh"))
  }

  // --- Animation --------------------------------------------------------

  play() {
    if (this.timer) {
      this.pause()
      if (this.hasPlayBtnTarget) this.playBtnTarget.textContent = t("fun.xuanji.play")
      return
    }

    const delay = Math.max(10, parseInt(this.speedTarget.value || "40", 10))
    if (this.hasPlayBtnTarget) this.playBtnTarget.textContent = t("fun.xuanji.pause")

    this.timer = setInterval(() => {
      if (this.stepIndex >= this.currentPath.length) {
        this.pause()
        if (this.hasPlayBtnTarget) this.playBtnTarget.textContent = t("fun.xuanji.play")
        return
      }
      this.highlightAt(this.stepIndex)
      this.stepIndex += 1
    }, delay)
  }

  pause() {
    if (this.timer) {
      clearInterval(this.timer)
      this.timer = null
    }
  }

  step() {
    this.pause()
    if (this.stepIndex >= this.currentPath.length) return
    this.highlightAt(this.stepIndex)
    this.stepIndex += 1
  }

  reset() {
    this.pause()
    this.clearHighlights()
    this.stepIndex = 0
  }

  highlightAt(i) {
    const [x, y] = this.currentPath[i]

    // Remove the current cursor highlight (keep traced path)
    const prev = this.element.querySelectorAll(".xuanji-rect.is-active")
    prev.forEach((el) => el.classList.remove("is-active"))

    const rect = document.getElementById(`xuanji-rect-${x}-${y}`)
    if (rect) {
      rect.classList.add("is-active")

      // In manual mode, the blue selection overlay is the main guide.
      // Avoid painting the whole path yellow on top of it.
      if (this.ruleTarget.value !== "manual") {
        rect.classList.add("is-traced")
      }
    }
  }

  clearHighlights() {
    const marked = this.element.querySelectorAll(".xuanji-rect.is-active, .xuanji-rect.is-traced")
    marked.forEach((el) => {
      el.classList.remove("is-active")
      el.classList.remove("is-traced")
    })
  }

  // --- Rule helpers -----------------------------------------------------

  perimeterRing(w, h, offset = 0) {
    const left = 0 + offset
    const top = 0 + offset
    const right = w - 1 - offset
    const bottom = h - 1 - offset

    if (left > right || top > bottom) return []

    const coords = []

    for (let x = left; x <= right; x++) coords.push([x, top])
    for (let y = top + 1; y <= bottom; y++) coords.push([right, y])
    if (bottom !== top) {
      for (let x = right - 1; x >= left; x--) coords.push([x, bottom])
    }
    if (left !== right) {
      for (let y = bottom - 1; y >= top + 1; y--) coords.push([left, y])
    }

    return coords
  }

  boundaryCells(w, h) {
    const isInside = (x, y) => x >= 0 && x < w && y >= 0 && y < h

    const boundary = []
    for (let y = 0; y < h; y++) {
      for (let x = 0; x < w; x++) {
        const key = `${x},${y}`
        const c0 = this.colorAt.get(key)
        if (!c0) continue

        const neigh = [
          [x - 1, y],
          [x + 1, y],
          [x, y - 1],
          [x, y + 1],
        ]

        let differs = false
        for (const [nx, ny] of neigh) {
          if (!isInside(nx, ny)) continue
          const c1 = this.colorAt.get(`${nx},${ny}`)
          if (c1 && c1 !== c0) {
            differs = true
            break
          }
        }

        if (differs) boundary.push([x, y])
      }
    }

    return boundary
  }

  rowsLR(w, h) {
    const coords = []
    for (let y = 0; y < h; y++) {
      for (let x = 0; x < w; x++) {
        coords.push([x, y])
      }
    }
    return coords
  }

  colsTB(w, h) {
    const coords = []
    for (let x = 0; x < w; x++) {
      for (let y = 0; y < h; y++) {
        coords.push([x, y])
      }
    }
    return coords
  }

  snakeRows(w, h) {
    const coords = []
    for (let y = 0; y < h; y++) {
      if (y % 2 === 0) {
        for (let x = 0; x < w; x++) coords.push([x, y])
      } else {
        for (let x = w - 1; x >= 0; x--) coords.push([x, y])
      }
    }
    return coords
  }

  snakeCols(w, h) {
    const coords = []
    for (let x = 0; x < w; x++) {
      if (x % 2 === 0) {
        for (let y = 0; y < h; y++) coords.push([x, y])
      } else {
        for (let y = h - 1; y >= 0; y--) coords.push([x, y])
      }
    }
    return coords
  }

  // --- Manual path storage + highlighting -------------------------------

  _manualStorageKey() {
    const v = (this.variantValue || "trad").toString()
    return `xuanji.manualPath.${v}`
  }

  _loadManualPath() {
    try {
      const raw = window.localStorage.getItem(this._manualStorageKey())
      if (!raw) return []
      const arr = JSON.parse(raw)
      if (!Array.isArray(arr)) return []

      const w = this.widthValue
      const h = this.heightValue

      const out = []
      for (const pair of arr) {
        if (!Array.isArray(pair) || pair.length !== 2) continue
        const x = parseInt(pair[0], 10)
        const y = parseInt(pair[1], 10)
        if (!Number.isFinite(x) || !Number.isFinite(y)) continue
        if (x < 0 || x >= w || y < 0 || y >= h) continue
        out.push([x, y])
      }
      return out
    } catch (_e) {
      return []
    }
  }

  _saveManualPath() {
    try {
      window.localStorage.setItem(this._manualStorageKey(), JSON.stringify(this.manualPath))
    } catch (_e) {
      // ignore
    }
  }

  _renderManualHighlights(enabled = true) {
    // Clear existing manual marks.
    const marked = this.element.querySelectorAll(".xuanji-rect.is-manual")
    marked.forEach((el) => el.classList.remove("is-manual"))

    if (!enabled) return

    for (const [x, y] of this.manualPath) {
      const rect = document.getElementById(`xuanji-rect-${x}-${y}`)
      if (rect) rect.classList.add("is-manual")
    }
  }

  _toggleManualAt(x, y) {
    const key = `${x},${y}`
    const idx = this.manualPath.findIndex(([ax, ay]) => `${ax},${ay}` === key)

    // Click behaviour:
    // - If it's the last cell: deselect (pop)
    // - If it's earlier in the path: truncate back to it
    // - If it's new: append
    if (idx === -1) {
      this.manualPath.push([x, y])
    } else if (idx === this.manualPath.length - 1) {
      this.manualPath.pop()
    } else {
      this.manualPath = this.manualPath.slice(0, idx + 1)
    }

    this._saveManualPath()
    this._renderManualHighlights(true)

    this.currentPath = [...this.manualPath]
    this.renderTextPreview()
  }

  _appendOrTruncateTo(x, y) {
    const key = `${x},${y}`
    const idx = this.manualPath.findIndex(([ax, ay]) => `${ax},${ay}` === key)

    if (idx === -1) {
      this.manualPath.push([x, y])
    } else {
      this.manualPath = this.manualPath.slice(0, idx + 1)
    }

    this._saveManualPath()
    this._renderManualHighlights(true)

    this.currentPath = [...this.manualPath]
    this.renderTextPreview()
  }

  _cellFromEvent(event) {
    // Use composedPath/target first, then fall back to elementFromPoint.
    const tryFrom = (el) => el?.closest?.(".xuanji-cell") || null

    let cell = tryFrom(event.target)
    if (!cell && typeof event.clientX === "number" && typeof event.clientY === "number") {
      const el = document.elementFromPoint(event.clientX, event.clientY)
      cell = tryFrom(el)
    }

    if (!cell) return null
    const x = parseInt(cell.dataset.x || "", 10)
    const y = parseInt(cell.dataset.y || "", 10)
    if (!Number.isFinite(x) || !Number.isFinite(y)) return null

    return { x, y }
  }
}
