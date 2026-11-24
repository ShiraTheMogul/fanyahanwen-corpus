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
    "rhyme",
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

      // Each reading has its own line length and it is not a preference.
      // 黄伯思's account of the lost colours is 因以别三五七言之異 — the five
      // colours existed to mark where the lines broke. 第四圖 read in sevens is
      // nothing; in sixes it is his 三言十二句 and in threes his 三言六句. So
      // choosing a reading sets the length it wants, and the box stays editable
      // afterwards for anyone who wants to try another.
      const figure = KANG_FIGURES[rule]
      if (figure && this.hasLineLenTarget) {
        this.lineLenTarget.value = String(figure.lineLength)
      }
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
      default: {
        // 康萬民's eight figures, and the readings he quotes poems for. These
        // were offered by the server and accepted by the URL but had no case
        // here, so every one fell through to the plain row reading below — the
        // dropdown said 第三圖 and the reader gave you rows of seven. They were
        // also missing from the dropdown altogether, so the only way to reach
        // one was to edit ?rule= by hand.
        //
        // See KANG_FIGURES at the foot of this file.
        const figure = KANG_FIGURES[rule]
        if (figure) return figure.build()
        return this.rowsLR(w, h)
      }
    }
  }

  renderTextPreview() {
    const raw = this.currentPath.map(([x, y]) => this.charAt.get(`${x},${y}`) || "").join("")
    const n = parseInt(this.lineLenTarget.value || "7", 10)
    const coupletComma = this.hasCoupletCommaTarget ? this.coupletCommaTarget.checked : true

    const segmented = this.segment(raw, n, coupletComma)

    // Whether the reading rhymes is not decoration — it is 康萬民's own test
    // for whether a path through the grid is a poem. Asked on every change,
    // and quietly ignored if the request fails.
    this._fetchRhyme(segmented).catch(() => {})

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

  /**
   * Ask the server whether the even-numbered lines rhyme, and under whose
   * rhyme book.
   *
   * The even ones, because that is where a quatrain rhymes: of the nine poems
   * quoted in the 讀法, five rhyme under 廣韻 if every line's final has to
   * match, and all nine do if only the even ones must. 讀法六's
   * 寒歳識凋松｜貞物知終始｜顔䘮改華容｜仁賢别行士 shows it plainly — 始 and 士
   * are both 止攝上聲 while 松 and 容 are 通攝平聲.
   *
   * Several rhyme books, because no single one accounts for all his poems, and
   * that is the whole of what he says about 起宗: a reader holding one misses
   * poems a reader holding another finds.
   */
  async _fetchRhyme(segmentedText) {
    if (!this.hasRhymeTarget) return

    // `segment` may have joined lines into couplets with a comma; the rhyme is
    // per LINE, so split those back apart.
    const lines = segmentedText
      .split(/[\n，]/)
      .map((l) => l.trim())
      .filter((l) => l.length > 0)

    if (lines.length < 2) {
      this.rhymeTarget.textContent = ""
      return
    }

    const token = document.querySelector('meta[name="csrf-token"]')?.getAttribute("content")
    const res = await fetch("/fun/xuanji/rhyme", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Accept: "application/json",
        ...(token ? { "X-CSRF-Token": token } : {}),
      },
      credentials: "same-origin",
      body: JSON.stringify({ lines }),
    })
    if (!res.ok) return
    const data = await res.json()
    if (!data || data.ok !== true) return

    this._renderRhyme(data)
  }

  // The labels here are literal rather than `t(...)` because these keys are not
  // in the locale files, and `t` answers a missing key with the key itself —
  // which would put "fun.xuanji.rhyme.finals" on the page. 韻腳 is the term for
  // the rhyming finals and 不載 is what a rhyme book says when it does not list
  // a character.
  _renderRhyme(data) {
    const esc = (s) => String(s ?? "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    const parts = []

    parts.push(`<div class="xuanji-rhyme-finals">`)
    parts.push(`<span class="xuanji-rhyme-label">${"韻腳"}</span> `)
    parts.push(`<span lang="zh-Hant">${esc((data.finals || []).join(""))}</span>`)
    parts.push(`</div>`)

    const rows = (data.standards || []).map((s) => {
      const state = s.rhymes === true ? "is-rhyming" : s.rhymes === false ? "is-not" : "is-unknown"
      const mark = s.rhymes === true ? "叶" : s.rhymes === false ? "·" : "?"
      const shared = (s.shared || []).join(" / ")
      const unknown = (s.unknown || []).length
        ? ` <span class="xuanji-rhyme-gap">${"不載"} ${esc(s.unknown.join(""))}</span>`
        : ""
      return `<li class="xuanji-rhyme-row ${state}">`
        + `<span class="xuanji-rhyme-mark">${mark}</span>`
        + `<span class="xuanji-rhyme-book" lang="zh-Hant">${esc(s.han)}</span>`
        + `<span class="xuanji-rhyme-class" lang="zh-Hant">${esc(shared)}</span>`
        + unknown
        + `</li>`
    })

    parts.push(`<ul class="xuanji-rhyme-list">${rows.join("")}</ul>`)
    this.rhymeTarget.innerHTML = parts.join("")
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

// === 康萬民's eight figures of the 璇璣圖 ==================================
//
// Recovered from 《璇璣圖詩采式》 and checked against the poems quoted in
// 《璇璣圖詩讀法》. Appended to xuanji_controller.js because `buildPath` had no
// case for any of the eight `kang_*` rules the server already offers, so
// choosing one fell through to `default: return this.rowsLR(w, h)` and quietly
// read the grid left to right instead.
//
// WHY 29 MATTERS
// --------------
// The grid is 29 x 29 = 841 characters, which is what Kang says in his 凡例:
// 是圖縱横八寸共計八百四十一言. Everything else follows from 29 = 1 + 4x7.
// Draw lines on rows and columns 1, 8, 15, 22 and 29 and the square falls into
// bands of 6, 13 and 6 in each direction, which is exactly what the 采式 then
// describes: 縱横皆六字 for the corners, 縱六字横十三字 for the sides.
//
// (晉書 says 840, and the transmitted grid has 840 too, because one cell is a
// NOTE rather than a character: 「絃」字少最後一點, "the character 絃, short of
// its final dot" — a glyph with no codepoint, described instead of printed.
// Restore that cell and the square closes. See ImportPlaintext.)
//
// THE FIVE COLOURS ARE FIVE REGIONS
// ---------------------------------
// The coloured figures tile the square exactly — every one of the 841 cells
// belongs to one colour and no cell to two:
//
//     朱 216   rows and columns 1, 8, 22, 29        第一圖 + 第二圖
//     墨 144   four 6x6 corner blocks               第四圖
//     青 312   four 13x6 and 6x13 edge blocks       第五圖
//     紫  80   four blocks of the central square    第六圖
//     黄  89   four 4x4 blocks and the 5x5 centre   第七圖
//              ---
//              841
//
// which is what 黄伯思 was describing when he wrote 其圖本五色相宣因以别三五七言
// 之異　後人流傳不復施采故迷其句讀 — the five colours told you where the lines
// broke, and once copies stopped applying them the parse was lost. The colour
// IS the 句讀. That is also why each figure below carries its own line length:
// reading 第四圖's 36 cells in sevens produces nothing, and in threes or sixes
// produces Kang's poems.
//
// 第三圖 IS RULED, NOT COLOURED
// -----------------------------
// 第三圖 is the lattice on rows and columns 1, 8, 15, 22, 29 plus both
// diagonals, and it crosses everything — row 15 runs through the middle of the
// central square. Kang hit this and said what to do:
//
//     但餘圖有於此圖借字有礙　今推縱横初行八行紅書　余以紅線界畫即準之　讀者審焉
//
// So the red CHARACTERS are rows and columns 1 and 8 (and 22 and 29 by the
// square's symmetry), and 第三圖 is ruled over the top in red line. Drawing it
// as cell colour is what makes it fight with the other figures.

const KANG_SIZE = 29

// The three bands the red lines leave: 6, 13, 6. 1-based and inclusive,
// because that is how the 采式 counts and it keeps these readable against it.
const KANG_BANDS = [
  [2, 7],
  [9, 21],
  [23, 28],
]

// The 采式 counts (row, column) from 1. This controller uses [x, y] from 0.
// One conversion, in one place.
const kangCell = (row, col) => [col - 1, row - 1]

/** A rectangle's cells, 1-based inclusive bounds, in a stated reading order. */
function kangRect(r0, r1, c0, c1, order) {
  const out = []
  const height = r1 - r0 + 1
  const width = c1 - c0 + 1

  if (order === "row") {
    for (let y = 0; y < height; y++) {
      for (let x = 0; x < width; x++) out.push(kangCell(r0 + y, c0 + x))
    }
  } else if (order === "col") {
    for (let x = 0; x < width; x++) {
      for (let y = 0; y < height; y++) out.push(kangCell(r0 + y, c0 + x))
    }
  } else if (order === "snake-col") {
    // 反覆讀 — down the first column, up the second, down the third. This is
    // the order 讀法四 and 讀法七 use, and it is what reproduces their poems.
    for (let x = 0; x < width; x++) {
      for (let i = 0; i < height; i++) {
        const y = x % 2 === 0 ? i : height - 1 - i
        out.push(kangCell(r0 + y, c0 + x))
      }
    }
  } else if (order === "snake-row") {
    for (let y = 0; y < height; y++) {
      for (let i = 0; i < width; i++) {
        const x = y % 2 === 0 ? i : width - 1 - i
        out.push(kangCell(r0 + y, c0 + x))
      }
    }
  }
  return out
}

/** A square ring, clockwise from its top-left corner. Each corner once. */
function kangRing(top, size) {
  const r0 = top
  const c0 = top
  const r1 = top + size - 1
  const c1 = top + size - 1
  const out = []
  for (let c = c0; c < c1; c++) out.push(kangCell(r0, c))
  for (let r = r0; r < r1; r++) out.push(kangCell(r, c1))
  for (let c = c1; c > c0; c--) out.push(kangCell(r1, c))
  for (let r = r1; r > r0; r--) out.push(kangCell(r, c0))
  return out
}

/** `n` cells from (row, col) stepping by (dr, dc). */
function kangRun(row, col, dr, dc, n) {
  const out = []
  for (let i = 0; i < n; i++) out.push(kangCell(row + dr * i, col + dc * i))
  return out
}

// --- the figures -----------------------------------------------------------

/**
 * 第一圖 — 四圍, the outer ring, plus the eight spokes.
 *
 * The 采式 paints twelve runs red for this figure: the four sides of the
 * square, and eight runs of eight cells each joining the corners of 第二圖's
 * ring out to the edge (真志之蒼欽, 欽所之荒心, 倫桑之西林, 林光之生民,
 * 春方之榮身, 身鄉之王秦, 純貞之當麟, 麟龍之皇人).
 *
 * The READING, though, is the ring: 讀法一 divides it into four segments of 28
 * and reads each cyclically in sevens, which is 40 poems. So the ring comes
 * first, and the spokes follow it so the whole figure can still be seen.
 */
function kangFirst() {
  const ring = kangRing(1, KANG_SIZE)
  const spokes = []
  for (const col of [8, 22]) {
    spokes.push(...kangRun(1, col, 1, 0, 8))
    spokes.push(...kangRun(KANG_SIZE, col, -1, 0, 8))
  }
  for (const row of [8, 22]) {
    spokes.push(...kangRun(row, 1, 0, 1, 8))
    spokes.push(...kangRun(row, KANG_SIZE, 0, -1, 8))
  }
  return [...ring, ...kangDedupe(spokes, ring)]
}

/**
 * 第二圖 — the ring on rows and columns 8 and 22.
 *
 * 自八行第八字 — "from the eighth character of the eighth row", which is 欽 at
 * (8,8). Four sides of fifteen cells, 56 distinct, read cyclically in sevens:
 * 56 / 7 = 8 line-starts, and 讀法二 closes at 右第二圖共詩八首.
 */
function kangSecond() {
  return kangRing(8, 15)
}

/**
 * 第三圖 — the lattice and both diagonals. RULED, not coloured; see the note
 * at the top of this block.
 *
 * Traced here as the five rows, then the five columns, then the two diagonals.
 * That order is this reader's choice and not Kang's: 讀法三 works by retreating
 * one character at a time along each line and is the largest of the eight
 * figures by a wide margin, so there is no single path to trace.
 */
function kangThird() {
  const out = []
  for (const row of [1, 8, 15, 22, 29]) out.push(...kangRun(row, 1, 0, 1, KANG_SIZE))
  for (const col of [1, 8, 15, 22, 29]) out.push(...kangRun(1, col, 1, 0, KANG_SIZE))
  out.push(...kangRun(1, 1, 1, 1, KANG_SIZE))
  out.push(...kangRun(KANG_SIZE, 1, -1, 1, KANG_SIZE))
  return kangDedupe(out, [])
}

/**
 * 附增第三圖 — Kang's own extra figure, and he says plainly that nobody had
 * drawn it before: 此圖自唐以來至起宗俱未拈出.
 *
 * The middle row, the middle column, and both diagonals — the four lines
 * through the centre, which is why its readings all pivot on 詩興感遠殊浮沈.
 */
function kangThirdPlus() {
  const out = [
    ...kangRun(15, 1, 0, 1, KANG_SIZE),
    ...kangRun(1, 15, 1, 0, KANG_SIZE),
    ...kangRun(1, 1, 1, 1, KANG_SIZE),
    ...kangRun(KANG_SIZE, 1, -1, 1, KANG_SIZE),
  ]
  return kangDedupe(out, [])
}

/**
 * 第四圖 — 四隅, 縱横皆六字: the four 6x6 corner blocks, in black.
 *
 * Read 反覆 down and up the columns. Checked: the north-west block gives
 * 嗟歎懐所離經｜遐曠路傷中情｜家無君房幃清｜華飭容朗鏡明｜葩紛光珠曜英｜多思感誰為榮
 * which is 讀法四's 三言十二句 exactly. Its 三言六句 is the same path 分讀 —
 * three characters of each six, alternating head and tail.
 */
function kangFourth() {
  const out = []
  for (const [r0, r1] of [KANG_BANDS[0], KANG_BANDS[2]]) {
    for (const [c0, c1] of [KANG_BANDS[0], KANG_BANDS[2]]) {
      out.push(...kangRect(r0, r1, c0, c1, "snake-col"))
    }
  }
  return out
}

/**
 * 第五圖 — the four edge blocks, in blue.
 *
 * 正面 is thirteen rows by six columns; 兩旁 is six by thirteen. The 采式 calls
 * the first 縱六字横十三字, which reads at first glance like six rows by
 * thirteen columns and resolves to nothing: 縱 counts the vertical lines and
 * 横 the horizontal ones, so it is six COLUMNS by thirteen ROWS.
 *
 * This is the figure Kang singles out for 借字 — 第五圖内借字羅互分讀, reading
 * across the two blocks and borrowing a character between them. That part is
 * not implemented here; what this traces is the four blocks themselves.
 */
function kangFifth() {
  const [small1, mid, small2] = KANG_BANDS
  return [
    ...kangRect(small1[0], small1[1], mid[0], mid[1], "row"),
    ...kangRect(mid[0], mid[1], small1[0], small1[1], "col"),
    ...kangRect(mid[0], mid[1], small2[0], small2[1], "col"),
    ...kangRect(small2[0], small2[1], mid[0], mid[1], "row"),
  ]
}

/**
 * 第六圖 — the four blocks of the central square, in purple. 五言 throughout.
 *
 * The line length is what decides the reading order here, and it is a neat
 * demonstration of the whole principle. 中方正面 is five rows by four columns
 * and 中方兩旁 four rows by five, so to get lines of five the first is read
 * down its columns and the second along its rows.
 *
 * Checked both ways: 寒歳識凋松｜貞物知終始｜顔䘮改華容｜仁賢别行士 along the
 * rows, and 龍虎繁文藻｜榮曜華彫旂｜容飭觀壯麗｜充顔曜綉衣 down the columns.
 */
function kangSixth() {
  // bands are not needed here: the central square's blocks are given outright.
  return [
    ...kangRect(9, 12, 13, 17, "row"),        // 中方兩旁, north
    ...kangRect(13, 17, 9, 12, "snake-col"),  // 中方正面, west
    ...kangRect(13, 17, 18, 21, "snake-col"), // 中方正面, east
    ...kangRect(18, 21, 13, 17, "row"),       // 中方兩旁, south
  ]
}

/**
 * 第七圖 — the four 4x4 blocks of the central square, the central cross, and
 * the 3x3 centre, in yellow.
 *
 * The 4x4 blocks are read 反覆 like 第四圖's: 思感自寧｜孜孜傷情｜時在君側｜
 * 夢想勞形 is 讀法七's 四言四句.
 *
 * The nine at the centre are the thing worth looking at. 空中心璇璣圖始平蘇氏
 * 詩心九字, says the 采式, and they are:
 *
 *       璇 璣 圖
 *       始 心 詩
 *       平 蘇 氏
 *
 * Read round the eight from the top left: 璇璣圖詩氏蘇平始 — 璇璣圖詩 one way
 * and 始平蘇氏 the other, about 心 alone in the middle. The title of the poem
 * and the name of the woman who wove it, wrapped round the character for the
 * heart, at the dead centre of all 841.
 */
function kangSeventh() {
  const out = []
  for (const [r0, r1] of [[9, 12], [18, 21]]) {
    for (const [c0, c1] of [[9, 12], [18, 21]]) {
      out.push(...kangRect(r0, r1, c0, c1, "snake-col"))
    }
  }
  out.push(...kangRect(13, 17, 13, 17, "row"))
  return out
}

/** Keep the first occurrence of each cell, dropping anything already in `seen`. */
function kangDedupe(cells, seen) {
  const have = new Set(seen.map(([x, y]) => `${x},${y}`))
  const out = []
  for (const [x, y] of cells) {
    const key = `${x},${y}`
    if (have.has(key)) continue
    have.add(key)
    out.push([x, y])
  }
  return out
}

/**
 * The eight figures, and the line length each one wants.
 *
 * The length is not decoration. 黄伯思's point is that the colours existed to
 * mark where the lines broke, so a figure read at the wrong length produces
 * character salad — which is what the reader did for every one of these before
 * this block existed, since it read them all as rows of seven.
 */
const KANG_FIGURES = {
  // `region: true` marks the eight figures themselves — the cell sets that
  // carry a colour and that tile the square. Everything added below is a
  // READING: one way through part of a region, which is not a region.
  kang_first_red:       { build: kangFirst,      lineLength: 7, han: "第一圖",    colour: "朱",   region: true },
  kang_second_red:      { build: kangSecond,     lineLength: 7, han: "第二圖",    colour: "朱",   region: true },
  kang_third_red:       { build: kangThird,      lineLength: 7, han: "第三圖",    colour: "朱線", region: true },
  kang_third_plus_red:  { build: kangThirdPlus,  lineLength: 7, han: "附增第三圖", colour: "朱線", region: true },
  kang_fourth_black:    { build: kangFourth,     lineLength: 6, han: "第四圖",    colour: "墨",   region: true },
  kang_fifth_blue:      { build: kangFifth,      lineLength: 6, han: "第五圖",    colour: "青",   region: true },
  kang_sixth_purple:    { build: kangSixth,      lineLength: 5, han: "第六圖",    colour: "紫",   region: true },
  kang_seventh_yellow:  { build: kangSeventh,    lineLength: 4, han: "第七圖",    colour: "黄",   region: true },
}

// `kang_fourth_perimeter` was the name the server already used for 第四圖, and
// it is wrong twice over: the figure is 四隅, the four CORNERS, and it is not a
// perimeter of anything. Kept as an alias so existing links do not break.
KANG_FIGURES.kang_fourth_perimeter = { ...KANG_FIGURES.kang_fourth_black, region: false }

// --- the reading families --------------------------------------------------
//
// A figure is a set of cells; a READING is one way through it, and Kang names
// several per figure. The ones below are the readings whose poems he quotes, so
// each is checked against his own text rather than inferred.
//
// 分讀 — "read divided". Cut the path into lines of `length` and keep only
// `take` characters of each, the head of one line and the tail of the next,
// alternately. This is how a 6x6 block yields both 三言十二句 and 三言六句 from
// a single path, and it is a large part of why the counts run into thousands.
function kangSplitRead(cells, length, take) {
  const out = []
  for (let i = 0; i < cells.length; i += length) {
    const line = cells.slice(i, i + length)
    if (line.length < length) break
    const head = ((i / length) | 0) % 2 === 0
    out.push(...(head ? line.slice(0, take) : line.slice(length - take)))
  }
  return out
}

/** 第四圖 分讀 — three of each six: 讀法四's 三言六句. */
function kangFourthSplit() {
  const out = []
  for (const [r0, r1] of [KANG_BANDS[0], KANG_BANDS[2]]) {
    for (const [c0, c1] of [KANG_BANDS[0], KANG_BANDS[2]]) {
      out.push(...kangSplitRead(kangRect(r0, r1, c0, c1, "snake-col"), 6, 3))
    }
  }
  return out
}

// 第五圖's four blocks, as (rows, columns) with the middle line each straddles.
//
// 借字 — "borrowing a character" — is the trick Kang singles out: 第五圖内借字
// 羅互分讀. Each of these blocks is THIRTEEN cells deep across its reading
// direction, so it has a middle line with six on either side. Six is a 六言
// line; seven, counting the middle, fits nothing. So the reading starts one
// line into the FAR half and comes back through the middle — eight cells, which
// is two 四言 lines.
//
// That is 自中行各借一字互用分讀四言成句: from the middle line, each borrowing
// one character, used alternately, read as four-character lines. Checked
// against 讀法五: 邵南周風興自后妃｜衞鄭楚樊厲節中闈｜… is column 2 then column
// 3 of the western block, each read from row 16 up to row 9.
const KANG_FIFTH_BLOCKS = [
  // [rowStart, rowEnd, colStart, colEnd, alongRows]
  // alongRows true  — the thirteen runs across the COLUMNS, so lines are rows
  // alongRows false — the thirteen runs down the ROWS, so lines are columns
  [9, 21, 2, 7, false],    // 正面 west   妃闈 … 㽔悲
  [9, 21, 23, 28, false],  // 正面 east   移陂 … 貲辭
  [2, 7, 9, 21, true],     // 兩旁 north  庭闈 … 防萌
  [23, 28, 9, 21, true],   // 兩旁 south  身我 … 惟新
]

/**
 * 第五圖 — one line per cross-line, `depth` cells each, starting `start` lines
 * from the middle and working outward through it.
 *
 * `start` of 1 means "one line into the far half", which is the borrowing.
 * `start` of 0 starts at the middle itself.
 */
function kangFifthRuns(depth, start) {
  const out = []
  for (const [r0, r1, c0, c1, alongRows] of KANG_FIFTH_BLOCKS) {
    const midRow = (r0 + r1) >> 1
    const midCol = (c0 + c1) >> 1
    if (alongRows) {
      // Thirteen columns; each line is a row read from one side of the middle
      // column back through it.
      for (let r = r0; r <= r1; r++) {
        for (let i = 0; i < depth; i++) {
          out.push(kangCell(r, midCol + start - i))
        }
      }
    } else {
      for (let c = c0; c <= c1; c++) {
        for (let i = 0; i < depth; i++) {
          out.push(kangCell(midRow + start - i, c))
        }
      }
    }
  }
  return out
}

/** 第五圖 借字 — eight per line: 讀法五's 四言十二句. */
function kangFifthBorrowed() {
  return kangFifthRuns(8, 1)
}

/** 第五圖 — six per line, the near half alone: 讀法五's 六言六句. */
function kangFifthSix() {
  return kangFifthRuns(6, -1)
}

/**
 * 第五圖 左右分讀 — the near half then the far half of each line, which is
 * 讀法五's 六言十二句: 周風興自后妃｜邵伯窈窕淑姿｜楚樊厲節中闈｜衞女河廣思歸｜…
 */
function kangFifthBothHalves() {
  const out = []
  for (const [r0, r1, c0, c1, alongRows] of KANG_FIFTH_BLOCKS) {
    const midRow = (r0 + r1) >> 1
    const midCol = (c0 + c1) >> 1
    if (alongRows) {
      for (let r = r0; r <= r1; r++) {
        for (let i = 1; i <= 6; i++) out.push(kangCell(r, midCol - i))
        for (let i = 1; i <= 6; i++) out.push(kangCell(r, midCol + i))
      }
    } else {
      for (let c = c0; c <= c1; c++) {
        for (let i = 1; i <= 6; i++) out.push(kangCell(midRow - i, c))
        for (let i = 1; i <= 6; i++) out.push(kangCell(midRow + i, c))
      }
    }
  }
  return out
}

/** 新増讀法五 各取兩邊四字 — four per line: 四言六句. */
// --- 第五圖's remaining readings, composed from its two halves --------------
//
// A 第五圖 block is thirteen deep across the reading direction — 13 = 6 + 1 + 6,
// the middle line being the hinge — and six lines wide. So every line of a block
// yields two 六言 lines:
//
//     N   the NEAR half, read from the middle outward: mid-1 … mid-6
//     F   the FAR half,  read from the middle outward: mid+1 … mid+6
//
// Twelve slots per block, N1 F1 N2 F2 … N6 F6, and every reading in the chapter
// is an ORDER over those twelve plus a choice of how many characters to take.
//
// 兩邊四字 ("four characters from each side") takes the OUTER four of a half,
// which is `slice(2)` — the same cells kangFifthFour already reaches by starting
// three in from the middle.
//
// The orders, read off the poems Kang prints:
//
//   讀法五 六言十二句 (邵伯 first)   F1 N1 N2 F2 F3 N3 N4 F4 F5 N5 N6 F6
//   新増 四言十二句                 N1 F1 N2 F2 N3 F3 N4 F4 N5 F5 N6 F6
//   新増 四言十二句 (河廣 third)     N1 F1 F2 N2 N3 F3 F4 N4 N5 F5 F6 N6
//   新増 四言六句 左右遞退           N1 F2 N3 F4 N5 F6
//   新増 六言六句 左右遞退           N1 F2 N3 F4 N5 F6, six characters
//
// The first and third are the same boustrophedon — pairs swapping — with N and F
// exchanged, which is what 左右分讀 and 羅互 name. The last two are 左右遞退:
// alternate sides, advancing a line each time, so each side recedes by one.
//
// 4 原讀 groups x 4 poems = 16 per 段 and 5 新増 groups x 4 = 20 per 段, which are
// the chapter's 每段各得詩十六首 and 每段各増詩二十首.
function kangFifthHalves() {
  const blocks = []
  for (const [r0, r1, c0, c1, alongRows] of KANG_FIFTH_BLOCKS) {
    const midRow = (r0 + r1) >> 1
    const midCol = (c0 + c1) >> 1
    const slots = []
    const span = alongRows ? [r0, r1] : [c0, c1]
    for (let k = span[0]; k <= span[1]; k += 1) {
      const near = []
      const far = []
      for (let i = 1; i <= 6; i += 1) {
        near.push(alongRows ? kangCell(k, midCol - i) : kangCell(midRow - i, k))
        far.push(alongRows ? kangCell(k, midCol + i) : kangCell(midRow + i, k))
      }
      slots.push(near, far)
    }
    blocks.push(slots)
  }
  return blocks
}

/** `order` indexes the twelve slots; `take` is 6, or 4 for 兩邊四字. */
function kangFifthCompose(order, take) {
  const out = []
  for (const slots of kangFifthHalves()) {
    for (const i of order) out.push(...slots[i].slice(6 - take))
  }
  return out
}

const KANG_FIFTH_ORDERS = {
  interleave:   [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11],
  swapFirst:    [1, 0, 2, 3, 5, 4, 6, 7, 9, 8, 10, 11],
  swapSecond:   [0, 1, 3, 2, 4, 5, 7, 6, 8, 9, 11, 10],
  alternate:    [0, 3, 4, 7, 8, 11],
}

Object.assign(KANG_FIGURES, {
  kang_fifth_both_alt:  { build: () => kangFifthCompose(KANG_FIFTH_ORDERS.swapFirst, 6),
                          lineLength: 6, han: "第五圖 左右分讀 邵伯起 — 六言十二句", colour: "青" },
  kang_fifth_four12:    { build: () => kangFifthCompose(KANG_FIFTH_ORDERS.interleave, 4),
                          lineLength: 4, han: "第五圖 兩邊四字 — 四言十二句", colour: "青" },
  kang_fifth_four12_alt:{ build: () => kangFifthCompose(KANG_FIFTH_ORDERS.swapSecond, 4),
                          lineLength: 4, han: "第五圖 兩邊四字羅互 — 四言十二句", colour: "青" },
  kang_fifth_four6_alt: { build: () => kangFifthCompose(KANG_FIFTH_ORDERS.alternate, 4),
                          lineLength: 4, han: "第五圖 兩邊分讀左右遞退 — 四言六句", colour: "青" },
  kang_fifth_six_alt:   { build: () => kangFifthCompose(KANG_FIFTH_ORDERS.alternate, 6),
                          lineLength: 6, han: "第五圖 兩邊分讀左右遞退 — 六言六句", colour: "青" },
})

function kangFifthFour() {
  return kangFifthRuns(4, -3)
}

Object.assign(KANG_FIGURES, {
  kang_fourth_split:    { build: kangFourthSplit,     lineLength: 3, han: "第四圖 分讀",     colour: "墨" },
  kang_fifth_borrowed:  { build: kangFifthBorrowed,   lineLength: 4, han: "第五圖 借字",     colour: "青" },
  kang_fifth_six:       { build: kangFifthSix,        lineLength: 6, han: "第五圖 六言",     colour: "青" },
  kang_fifth_both:      { build: kangFifthBothHalves, lineLength: 6, han: "第五圖 左右分讀", colour: "青" },
  kang_fifth_four:      { build: kangFifthFour,       lineLength: 4, han: "第五圖 兩邊四字", colour: "青" },
})

// --- 讀法三, the figure that holds nineteen poems in twenty -----------------
//
// 第三圖 is the lattice, and it carries 3,518 of 起宗's 3,752 poems and 3,788 of
// Kang's 4,206. Everything else in the 讀法 is a block or a ring with a handful
// of readings; this one figure is almost the whole count. It works differently
// from the others and the difference is one cell.
//
// WHERE THE LINES BREAK: THE PHASE IS NOT THE ONE 讀法一 USES
// -----------------------------------------------------------
// The lattice lines sit on rows and columns 1, 8, 15, 22, 29, and 29 = 1 + 4x7,
// so a lattice line splits into four seven-character lines in exactly two ways:
//
//   cut A   1-7  8-14  15-21  22-28    starts ON the intersection
//   cut B   2-8  9-15  16-22  23-29    ENDS on the intersection
//
// 讀法一 uses cut A: 仁智懷德聖虞唐 is columns 1 to 7, and its rhyme is 唐章皇湘.
// **第三圖 uses cut B.** Kang labels each of its twenty groups by the first two
// characters of where it starts, and all twenty start at column or row 2, 9, 16
// or 23 — one past an intersection, never on one. 智懷 is (1,2). 傷慘 is (2,1).
// 嗟中 is (2,2). Not one of them starts at 1, 8, 15 or 22.
//
// And the rhyme settles it. Cut B on row 1 gives finals 眞臣倫津, which is the
// rhyme 讀法三之一 quotes. Cut A would give 唐章皇湘, which is a different poem
// in a different chapter. Same row, one cell of phase, two poems.
//
// WHY THAT MATTERS MORE THAN IT SOUNDS
// ------------------------------------
// Cut B puts every line-final on an intersection, so every rhyme in 第三圖 is
// one of twenty-five cells. Those twenty-five are:
//
//          1    8   15   22   29
//    1     仁   眞   臣   倫   津
//    8     心   欽   㴱   林   民
//   15     音   殷   心   沈   身
//   22     秦   身   神   麟   人
//   29     琴   春   新   純   親
//
// Seventeen 臻攝 (-n: 真諄文欣) and eight 深攝 (-m: 侵). Nothing else. Not one
// 仄聲-only cell among the twenty-five. 蘇若蘭 did not weave a square and leave
// it to 起宗 to find poems in it — **she put the rhymes on the lattice**, and
// the lattice is where the 采式 tells you to read. A reading that follows the
// red rulings rhymes because it was built to.
//
// Which is 黄伯思's 其圖本五色相宣　因以别三五七言之異 one level down. The colour
// tells you the line length; the line length is seven because seven is the
// spacing that lands every line-end on a rhyme.
//
// THE FIVE SPINES
// ---------------
// Each of 讀法三's five sub-readings is one walk along the lattice, and its four
// groups are a sliding window of four segments along that walk. 讀法三之一:
//
//   智懷…湘津   1,1 → 1,8 → 1,15 → 1,22 → 1,29
//   妙顯…梁民        1,8 → 1,15 → 1,22 → 1,29 → 8,29
//   賢惟…長身             1,15 → 1,22 → 1,29 → 8,29 → 15,29
//   匹離…房人                  1,22 → 1,29 → 8,29 → 15,29 → 22,29
//
// Four windows, each shifted one segment on, each overlapping the last by three
// lines. The end anchor is the test: given the start and four segments, where
// the walk finishes is forced, and all twenty land on the pair Kang names.
//
// The routes below are those resolved walks, not a re-derivation of them.
const KANG_THIRD_SPINES = {
  kang_third_one:   { han: "讀法三之一 首行轉右邊",
                      nodes: [[1,1],[1,8],[1,15],[1,22],[1,29],[8,29],[15,29],[22,29]] },
  kang_third_two:   { han: "讀法三之二 首列轉下邊",
                      nodes: [[1,1],[8,1],[15,1],[22,1],[29,1],[29,8],[29,15],[29,22]] },
  kang_third_three: { han: "讀法三之三 八行轉右邊",
                      nodes: [[8,1],[8,8],[8,15],[8,22],[8,29],[15,29],[22,29],[29,29]] },
  kang_third_four:  { han: "讀法三之四 中行轉右邊",
                      nodes: [[15,1],[15,8],[15,15],[15,22],[15,29],[22,29],[29,29],[29,22]] },
  kang_third_five:  { han: "讀法三之五 斜行轉下邊",
                      nodes: [[1,1],[8,8],[15,15],[22,22],[29,29],[29,22],[29,15],[29,8]] },
}

// The seven cells APPROACHING `b` from `a` — cut B. Seven of them, and the last
// one is b itself, which is the intersection the rhyme falls on.
//
// Stripped down, the whole of cut B is this: walk one step at a time from a
// towards b, and emit every cell you land on INCLUDING b but not a. Cut A would
// be the same loop emitting a and stopping one short of b.
function kangThirdSegment(a, b) {
  const dr = Math.sign(b[0] - a[0])
  const dc = Math.sign(b[1] - a[1])
  const out = []
  // kangCell takes 1-based (row, col) and returns 0-based [x, y], which is the
  // convention every other builder here uses. Writing the pair out by hand
  // instead put every cell one row and one column out.
  for (let i = 1; i <= 7; i += 1) out.push(kangCell(a[0] + dr * i, a[1] + dc * i))
  return out
}

// One spine, read straight through: every segment of the walk, in order.
// A spine of eight nodes is seven segments, so 49 cells — seven lines of seven.
function kangThirdSpine(key) {
  const spine = KANG_THIRD_SPINES[key]
  const out = []
  for (let i = 0; i + 1 < spine.nodes.length; i += 1) {
    out.push(...kangThirdSegment(spine.nodes[i], spine.nodes[i + 1]))
  }
  return out
}

// One window: four consecutive segments starting at segment `from`, which is
// one quatrain — 28 cells, four seven-character lines, four rhymes, all of them
// on the lattice. `from` is 0-based, so 0..3 are the four groups Kang lists.
function kangThirdWindow(key, from) {
  return kangThirdSpine(key).slice(from * 7, from * 7 + 28)
}

Object.assign(KANG_FIGURES, Object.fromEntries(
  Object.entries(KANG_THIRD_SPINES).flatMap(([key, spine]) => [
    [key, { build: () => kangThirdSpine(key), lineLength: 7, han: spine.han, colour: "朱線" }],
    ...[0, 1, 2, 3].map(i => [
      `${key}_w${i + 1}`,
      { build: () => kangThirdWindow(key, i), lineLength: 7,
        han: `${spine.han} 第${"一二三四"[i]}段起`, colour: "朱線" },
    ]),
  ])
))

// --- 第一圖 and 第二圖: the two rings, read in sevens ------------------------
//
// 采式 gives 第一圖 as 四圍 plus eight spokes, and 第二圖 as the inner 四圍 alone.
// Both rings are a whole number of seven-character lines, because that is what
// 29 and 15 were chosen to make:
//
//     outer ring  4 x 28 = 112 cells = 16 lines of seven
//     inner ring  4 x 14 =  56 cells =  8 lines of seven
//
// The poems are four-line windows sliding round the ring, and the ring closes,
// so the windows are CYCLIC — window 16 of the outer ring is lines 16, 1, 2, 3.
// That is the same 遞退一句成章 as 讀法三, on a loop instead of a spine.
//
// WHAT CONFIRMS THIS AND IS NOT CIRCULAR
// --------------------------------------
// 第二圖 claims 右第二圖共詩八首 — eight poems. The inner ring is eight lines, so
// the cyclic windows number exactly eight, with no rule needed to pick them.
// 康萬民 prints one of the eight in full and names the other seven by their
// opening and closing lines, and ALL EIGHT land on their window (test_dieci.mjs
// asserts each). Nothing was tuned: the ring order comes from kangRing, which
// was written for the 采式 colouring months before any of this.
//
// 第一圖 claims forty, in four 段 of ten, so the sixteen ring windows are part
// of it rather than all of it — the rest use the spokes. Of 讀法一's ten printed
// poems, four are ring windows 1-4 and three are the corner circuit below, and
// all seven match character for character. The remaining three are printed as a
// single line each and need the same unsolved inference 讀法三's 遞退 does.
function kangRingRead(top, size, from, lines) {
  const ring = kangRing(top, size)
  const out = []
  for (let i = 0; i < lines * 7; i += 1) out.push(ring[(from * 7 + i) % ring.length])
  return out
}

// 讀法一's second, third and fourth poems are not on the ring at all. They run
// the circuit of the top-left 8x8 block ANTICLOCKWISE from 真 at (1,8): down
// column 8, west along row 8, up column 1, east along row 1. Twenty-eight
// cells, four lines of seven, and it closes, so it shifts like the ring does.
//
//     真志篤終誓穹蒼 / 欽所感想忘淫荒 / 心憂增慕懷慘傷 / 仁智懷德聖虞唐
//
// Two of its four legs are halves of a spoke and one is the first line of the
// outer ring, which is why 采式 draws 第一圖 as 四圍 AND spokes: the figure is
// the union, and its readings cross between them.
// A corner circuit: the 8x8 block in one corner of the square, run round its
// edge. Four legs of seven, 28 cells, four seven-character lines, and it closes.
//
//   ro, co   the OUTER row and column — an edge of the square (1 or 29)
//   ri, ci   the INNER row and column — a lattice line (8 or 22)
//
// ALL FOUR CORNERS RUN CLOCKWISE, and that is measured rather than assumed.
// 讀法一 attests two of them: 第二/三/四首 give the 左上 circuit from 真 at (1,8),
// and 第八首 and 第十首 give the 右上 one's first two lines (民生推逝電流光 then
// 林西昭景薄榆桑, which are row 8 read WEST from (8,29) and column 22 read NORTH
// from (8,22) — adjacent cells, so consecutive lines of one path). A shoelace
// sum over both attested paths comes out at +98 for each: same sign, same
// handedness. There is no mirror here.
//
// I had reasoned the opposite — that the corners were mirror images and so
// alternated handedness — and the arithmetic says no. The leg ORDER has to
// differ between corners precisely so that the direction does not: on the main
// diagonal (左上, 右下) dr and dc share a sign, on the anti-diagonal (右上, 左下)
// they do not, and flipping the leg order on the anti-diagonal is what keeps all
// four turning the same way.
function kangCornerCircuit(ro, co, ri, ci) {
  const dr = ri > ro ? 1 : -1
  const dc = ci > co ? 1 : -1
  const out = []
  if (dr * dc > 0) {
    // 左上 and 右下: inner column first, then inner row back toward the outer column.
    for (let i = 0; i < 7; i += 1) out.push(kangCell(ro + dr * i, ci))
    for (let i = 0; i < 7; i += 1) out.push(kangCell(ri, ci - dc * i))
    for (let i = 0; i < 7; i += 1) out.push(kangCell(ri - dr * i, co))
    for (let i = 0; i < 7; i += 1) out.push(kangCell(ro, co + dc * i))
  } else {
    // 右上 and 左下: inner ROW first, from the outer column inward.
    for (let i = 0; i < 7; i += 1) out.push(kangCell(ri, co + dc * i))
    for (let i = 0; i < 7; i += 1) out.push(kangCell(ri - dr * i, ci))
    // ci - dc*i, NOT ci + dc*i. With the plus sign this leg runs along the
    // outer row AWAY from the block — for 右上 it went (1,22) westward to (1,16),
    // six columns outside the 8x8 block — and the four legs then do not join up
    // at all. It still produced the two lines 讀法一 attests, because those come
    // from legs 1 and 2, so the text check passed while the path was broken.
    // The bounds assertion in test_dieci.mjs is what caught it.
    for (let i = 0; i < 7; i += 1) out.push(kangCell(ro, ci - dc * i))
    for (let i = 0; i < 7; i += 1) out.push(kangCell(ro + dr * i, co))
  }
  return out
}

// The 左上 one, kept as its own name because existing links use it.
function kangFirstCircuit() {
  return kangCornerCircuit(1, 1, 8, 8)
}

function kangFirstCircuitShift(k) {
  return kangShiftCells(kangFirstCircuit(), k)
}

function kangShiftCells(cells, k) {
  const out = []
  for (let i = 0; i < cells.length; i += 1) out.push(cells[(k + i) % cells.length])
  return out
}

// The four corners. 康萬民 prints the 左上 one at three shifts and the 右上 one at
// shift 0, so only shift 0 is offered for the three non-左上 corners: the circuit
// admits all twenty-eight, and offering unattested ones would make the viewer
// claim more than the text does. The 左上 shifts keep their existing names.
// 讀法一 names its four 段 by their first and last characters:
//
//     自仁字起 … 津河之柔剛十首　親所之蘭芳十首　琴親之慘傷十首
//     〈三段讀法俱同前各得詩十首〉　右第一圖共詩四十首
//
// Those are the four QUARTERS of the outer ring, four lines each, sixteen in
// all — and the anchors check out exactly: 段2 runs 津河隔塞殊山梁 to
// 人賤為女有柔剛 (lines 5-8), 段3 親所懷想思誰望 to 春陽熙茂凋蘭芳 (9-12), 段4
// 琴清流楚激絃商 to 心憂增慕懷慘傷 (13-16). So the 四十首 is 四段每段十首 over the
// ring's four quarters, not forty independent paths.
// A 段 is ring window 1, 5, 9 or 13 — the SAME reading, not an extra one. Giving
// it its own key would have put one path in the dropdown twice under two names,
// which is how a later reader ends up counting it twice. So this is a label
// table: window 1 is also 第一段, window 5 also 第二段, and so on.
const KANG_FIRST_SEGMENT_OF = {
  1:  "第一段 仁智起",
  5:  "第二段 津河之柔剛",
  9:  "第三段 親所之蘭芳",
  13: "第四段 琴清之慘傷",
}

// The four corner circuits. 康萬民 prints the 左上 one at three shifts — 真字起,
// 志字起 and 欽字起, which are shifts 0, 1 and 7 — and the 右上 one's first two
// lines (第八首, 第十首).
//
// Five of the twelve shifts are attested, not three. 左上 has 0, 1 and 7 from
// 第二/三/四首. 右上 has 0 from 第八首 (民生推逝電流光) and 7 from 第十首, whose
// second printed line 林西昭景薄榆桑 is exactly what shift 7 starts on. So the
// 0/1/7 triple is 康萬民's choice in two different corners.
//
// 右下 and 左下 rest on symmetry alone: the four circuits are one path in four
// corners — identical shoelace, identical enclosed area — so the same three
// choices apply. That is an argument rather than a citation, so those six carry
// 推 in their label and the five he prints do not.
const KANG_CORNERS = {
  kang_first_circuit_tr: { box: [1, 29, 8, 22],  han: "第一圖 右上 八字迴環 民字起" },
  kang_first_circuit_br: { box: [29, 29, 22, 22], han: "第一圖 右下 八字迴環 純字起" },
  kang_first_circuit_bl: { box: [29, 1, 22, 8],  han: "第一圖 左下 八字迴環 秦字起" },
}

// shift 0 is each corner's own 起 character; 1 and 7 mirror 左上's other two.
const KANG_CORNER_SHIFTS = [
  ["", 0], ["_s1", 1], ["_s7", 7],
]

KANG_FIGURES.kang_first_ring = {
  build: () => kangRingRead(1, KANG_SIZE, 0, 16), lineLength: 7,
  han: "第一圖 四圍", colour: "朱",
}
KANG_FIGURES.kang_second_ring = {
  build: () => kangRingRead(8, 15, 0, 8), lineLength: 7,
  han: "第二圖 四圍", colour: "朱",
}

// The windows. Sixteen for the outer ring, eight for the inner — one per line,
// which is what makes 第二圖's count fall out without a selection rule.
Object.assign(KANG_FIGURES, Object.fromEntries([
  ...Array.from({ length: 16 }, (_, i) => [
    `kang_first_ring_w${i + 1}`,
    { build: () => kangRingRead(1, KANG_SIZE, i, 4), lineLength: 7,
      han: KANG_FIRST_SEGMENT_OF[i + 1]
        ? `第一圖 四圍 第${i + 1}首 (${KANG_FIRST_SEGMENT_OF[i + 1]})`
        : `第一圖 四圍 第${i + 1}首`,
      colour: "朱" },
  ]),
  ...Array.from({ length: 8 }, (_, i) => [
    `kang_second_ring_w${i + 1}`,
    { build: () => kangRingRead(8, 15, i, 4), lineLength: 7,
      han: `第二圖 第${i + 1}首`, colour: "朱" },
  ]),
]))

// Only the three shifts he actually prints. The circuit admits all twenty-eight,
// but twenty-five of them are not attested anywhere in the book, and listing
// them would make the viewer claim more than the text does.
KANG_FIGURES.kang_first_circuit = {
  build: () => kangFirstCircuitShift(0), lineLength: 7,
  han: "第一圖 八字迴環 真字起", colour: "朱線",
}
KANG_FIGURES.kang_first_circuit_s1 = {
  build: () => kangFirstCircuitShift(1), lineLength: 7,
  han: "第一圖 八字迴環 志字起", colour: "朱線",
}
KANG_FIGURES.kang_first_circuit_s7 = {
  build: () => kangFirstCircuitShift(7), lineLength: 7,
  han: "第一圖 八字迴環 欽字起", colour: "朱線",
}

Object.assign(KANG_FIGURES, Object.fromEntries(
  Object.entries(KANG_CORNERS).flatMap(([key, c]) =>
    KANG_CORNER_SHIFTS.map(([suffix, k]) => [
      `${key}${suffix}`,
      { build: () => kangShiftCells(kangCornerCircuit(...c.box), k),
        lineLength: 7,
        han: suffix === "" ? c.han : `${c.han.replace(/ [^ ]+起$/, "")} 第${k + 1}字起 推`,
        colour: "朱線" },
    ])
  )
))

// --- 遞退: 讀法三's actual reading, reconstructed from his worked 段 ----------
//
//     讀法三之一　自初行退一字成句句七言每首四句**以下遞退一句成章**
//                 … 以上一段得詩二十二首
//
// 遞退一句成章 — "retreating one line at a time to make a stanza". A 段 is a
// SEQUENCE of seven-character lines, and the poems are four-line windows sliding
// along it. 康萬民 prints each poem as its NEW material only — the first in full,
// the rest as the one, two or three lines not in the poem before — so the
// sequence can be read straight off the page.
//
// 之一's 段 is thirty-two lines giving twenty-two poems, and 88 原讀 ÷ 4 段 = 22,
// which is what the group claims. 之二's 段 prints the same twenty-two entries
// with the same line counts over completely different characters, so the
// traversal is geometric and the two are transposes of one another — which is
// also why their twelve count-numbers in the 新増 tables are byte-identical.
//
// THE TWO THINGS THAT CONFIRM THIS AND ARE NOT CIRCULAR
// -----------------------------------------------------
//   * All sixty-four lines of the two sequences locate in the square, and every
//     one of them ENDS on a lattice crossing. Not one ends anywhere else.
//   * All twenty-two poems of each 段 rhyme on every line under 臻深通押 — 22 of
//     22, in both chapters. Under 洪武正韻 it is 9 of 22.
//
// WHAT IS NOT SOLVED — AND THE DEAD ENDS, SO NOBODY RETREADS THEM
// ----------------------------------------------------------------
// The window does NOT advance by one every time. 之一 takes 22 of the 29
// available windows and 之五 takes 59 of 79, and the skipped positions are the
// same in 之一 and 之二 (3, 7, 8, 12, 20, 24, 27) over different characters, so
// the rule is geometric rather than a judgement on particular words. What the
// rule IS remains unknown. Tested against both traces and rejected:
//
//   rhyme                     all 29 and all 79 windows rhyme under 通押 — the
//                             lattice is one rhyme class, so it cannot select
//   複韻 (repeated rhyme),      6 of 7 skipped have one in 之一, but so do 11 of
//   which the 凡例 raises       the 22 kept; 3 of 20 and 4 of 59 in 之五
//   repeated end CELL         same shape: 5/7 skipped, 11/22 kept
//   repeated LINE             never happens, in any of the 108 windows
//   repeated start cell       never happens
//   spans N lattice lines     kept and skipped occur at every N from 1 to 4
//   two lines on one line     15/22 kept, 6/7 skipped
//   a direction reversal      2/22 kept, 1/7 skipped
//   straddles a line change   all 7 skipped do — and so do 21 of the 22 kept
//   a "jump" (next line not   57 of 81 joints jump in 之五; every positional
//   adjacent to the last end) variant tried (at joint s, s+1, s+2, all three,
//                             none, 2-or-more, exactly one) splits both ways
//   lines printed are repeats 之一 prints 32 lines of which 29 are distinct, so
//   of earlier ones           the sequence genuinely revisits lines
//
// Nor does 新増's 十六首 reproduce. The best candidate is the same window run
// over the REVERSED sequence (遞句退成囘文), keeping those that are new and rhyme:
// that gives 16 for 之一, which is his figure, and 18 for 之二, which is not. So
// that is a coincidence rather than the rule.
//
// All three worked 段 in the book are now encoded here — 之三 and 之四 have none,
// because both say 原讀無詩法只有章法故畧其圖不録. So the evidence inside this text
// is exhausted; the rule would have to come from another 璇璣圖 commentary.
//
// The sequences below are therefore the reading as far as it is established:
// the lines are right, the poems are right, and the selection rule is open.
// Each entry is [row, col, dRow, dCol] 1-based — the line's first cell and the
// direction it runs, seven cells, ending on the crossing.
const KANG_DIECI = {
  one: [
    [ 1,  2,  0,  1], //  1  智懐徳聖虞唐真
    [ 1,  9,  0,  1], //  2  妙顯華重榮章臣
    [ 1, 16,  0,  1], //  3  賢惟聖配英皇倫
    [ 1, 23,  0,  1], //  4  匹離飄浮江湘津
    [ 2, 22,  1,  0], //  5  桑榆薄景昭西林
    [ 2, 15,  1,  0], //  6  奸因女嬖至微深
    [ 8, 16,  0,  1], //  7  淵重涯經網羅林
    [ 9, 15,  1,  0], //  8  識知改别明璣心
    [ 8, 14,  0, -1], //  9  峨嵯峻巖幽岑欽
    [ 2,  8,  1,  0], // 10  志篤終誓穹蒼欽
    [ 8,  9,  0,  1], // 11  岑幽巖峻嵯峨深
    [ 7, 15, -1,  0], // 12  微至嬖女因奸臣
    [ 8, 16,  0,  1], // 13  淵重涯經網羅林
    [ 9, 15,  1,  0], // 14  識知改别明璣心
    [ 9,  9,  1,  1], // 15  思傷君夢詩璇心
    [14, 15, -1,  0], // 16  璣明别改知識深
    [14, 16, -1,  1], // 17  圖怨念為懐如林
    [15, 16,  0,  1], // 18  詩興感逺殊浮沈
    [16, 16,  1,  1], // 19  氏辭懐感戚知麟
    [16, 15,  1,  0], // 20  蘇作興感昭恨神
    [16, 14,  1, -1], // 21  平端寃是何懐身
    [15, 14,  0, -1], // 22  始終曜觀華繁殷
    [ 9,  8,  1,  0], // 23  何如將情纒憂殷
    [15,  9,  0,  1], // 24  繁華觀曜終始心
    [16,  8,  1,  0], // 25  多患生艱惟苦身
    [15,  7,  0, -1], // 26  徴流商歌鄭南音
    [ 8,  7,  0, -1], // 27  所感想㤀淫荒心
    [ 9,  1,  1,  0], // 28  堂空惟思詠和音
    [ 7,  1, -1,  0], // 29  憂増慕懐慘傷仁
    [ 7,  7, -1, -1], // 30  多曜容君中嗟仁
    [ 2,  1,  1,  0], // 31  傷慘懐慕増憂心
    [ 1,  2,  0,  1], // 32  智懐徳聖虞唐真
  ],
  two: [
    [ 2,  1,  1,  0], //  1  傷慘懐慕増憂心
    [ 9,  1,  1,  0], //  2  堂空惟思詠和音
    [16,  1,  1,  0], //  3  藏摧悲聲發曲秦
    [23,  1,  1,  0], //  4  商弦激楚流清琴
    [22,  2,  0,  1], //  5  王懐土眷舊郷身
    [15,  2,  0,  1], //  6  南鄭歌商流徴殷
    [16,  8,  1,  0], //  7  多患生艱惟苦身
    [15,  9,  0,  1], //  8  繁華觀曜終始心
    [14,  8, -1,  0], //  9  憂纒情將如何欽
    [ 8,  2,  0,  1], // 10  荒淫㤀想感所欽
    [ 9,  8,  1,  0], // 11  何如將情纒憂殷
    [15,  7,  0, -1], // 12  徴流商歌鄭南音
    [16,  8,  1,  0], // 13  多患生艱惟苦身
    [15,  9,  0,  1], // 14  繁華觀曜終始心
    [ 9,  9,  1,  1], // 15  思傷君夣詩璇心
    [15, 14,  0, -1], // 16  始終曜觀華繁殷
    [16, 14,  1, -1], // 17  平端寃是何懐身
    [16, 15,  1,  0], // 18  蘇作興感昭恨神
    [16, 16,  1,  1], // 19  氏辭懐感戚知麟
    [15, 16,  0,  1], // 20  詩興感逺殊浮沈
    [14, 16, -1,  1], // 21  圖怨念為懐如林
    [14, 15, -1,  0], // 22  璣明别改知識深
    [ 8,  9,  0,  1], // 23  岑幽巖峻嵯峨深
    [ 9, 15,  1,  0], // 24  識知改别明璣心
    [ 8, 16,  0,  1], // 25  淵重涯經網羅林
    [ 7, 15, -1,  0], // 26  微至嬖女因奸臣
    [ 7,  8, -1,  0], // 27  蒼穹誓終篤志真
    [ 1,  9,  0,  1], // 28  妙顯華重榮章臣
    [ 1,  7,  0, -1], // 29  唐虞聖徳懐智仁
    [ 7,  7, -1, -1], // 30  多曜容君中嗟仁
    [ 1,  2,  0,  1], // 31  智懐徳聖虞唐真
    [ 2,  1,  1,  0], // 32  傷慘懐慕増憂心
  ],
  five: [
    [ 2,  2,  1,  1], //  1  嗟中君容曜多欽
    [ 9,  9,  1,  1], //  2  思傷君夢詩璇心
    [16, 16,  1,  1], //  3  氏辭懷感戚知麟
    [23, 23,  1,  1], //  4  神輕粲散哀春親
    [22, 23,  0,  1], //  5  龍昭德懷聖皇人
    [23, 22,  1,  0], //  6  當所專一志貞純
    [21, 22, -1,  0], //  7  沙流頽逝異浮沈
    [22, 21,  0, -1], //  8  鳳離遠曠幽遐神
    [15, 16,  0,  1], //  9  詩興感遠殊浮沈
    [15, 23,  0,  1], // 10  時盛意麗哀遺身
    [14, 22, -1,  0], // 11  華英翳曜潛陽林
    [16, 22,  1,  0], // 12  浮異逝頽流沙麟
    [16, 15,  1,  0], // 13  蘇作興感昭恨神
    [23, 15,  1,  0], // 14  辜罪天離聞舊新
    [22, 16,  0,  1], // 15  遐幽曠遠離鳳麟
    [22, 14,  0, -1], // 16  精少悴愁兼加身
    [14, 16, -1,  1], // 17  圖怨念為懷如林
    [ 7, 23, -1,  1], // 18  滋謙遠貞自基津
    [ 7, 22, -1,  0], // 19  西昭景薄榆桑倫
    [ 8, 23,  0,  1], // 20  光流電逝推生民
    [ 8, 21,  0, -1], // 21  羅網經涯重淵深
    [ 9, 22,  1,  0], // 22  陽潛曜翳英華沈
    [16, 14,  1, -1], // 23  平端寃是何懷身
    [23,  7,  1, -1], // 24  傷好水燕桃廊琴
    [23,  8,  1,  0], // 25  榮君仁離殊方春
    [22,  7,  0, -1], // 26  鄉舊眷土懷王秦
    [22,  9,  0,  1], // 27  加兼愁悴少精神
    [21,  8, -1,  0], // 28  苦惟艱生患多殷
    [14, 15, -1,  0], // 29  璣明別改知識深
    [ 7, 15, -1,  0], // 30  微至嬖女因奸臣
    [ 8, 16,  0,  1], // 31  淵重涯經網羅林
    [15, 14,  0, -1], // 32  始終曜觀華繁殷
    [16,  8,  1,  0], // 33  多患生艱惟苦身
    [15,  7,  0, -1], // 34  徵流商歌鄭南音
    [ 8,  9,  0,  1], // 35  岑幽巖峻嵯峨深
    [ 8, 16,  0,  1], // 36  淵重涯經網羅林
    [ 8, 23,  0,  1], // 37  光流電逝推生民
    [ 7, 23, -1,  1], // 38  滋謙遠貞自基津
    [ 9, 22,  1,  0], // 39  陽潛曜翳英華沈
    [ 7, 22, -1,  0], // 40  西昭景薄榆桑倫
    [ 9, 21,  1, -1], // 41  如懷為念怨圖心
    [ 7, 15, -1,  0], // 42  微至嬖女因奸臣
    [ 1, 14,  0, -1], // 43  章榮重華顯妙真
    [ 1, 16,  0,  1], // 44  賢惟聖配英皇倫
    [ 9, 15,  1,  0], // 45  識知改別明璣心
    [16, 15,  1,  0], // 46  蘇作興感昭恨神
    [16, 16,  1,  1], // 47  氏辭懷感戚知麟
    [16, 14,  1, -1], // 48  平端寃是何懷身
    [15, 16,  0,  1], // 49  詩興感遠殊浮沈
    [15, 14,  0, -1], // 50  始終曜觀華繁殷
    [14, 16, -1,  1], // 51  圖怨念為懷如林
    [14, 14, -1, -1], // 52  璇詩夢君傷思欽
    [ 9,  8,  1,  0], // 53  何如將情纒憂殷
    [16,  8,  1,  0], // 54  多患生艱惟苦身
    [23,  8,  1,  0], // 55  榮君仁離殊方春
    [22,  9,  0,  1], // 56  加兼愁悴少精神
    [23,  7,  1, -1], // 57  傷好水燕桃廊琴
    [21,  9, -1,  1], // 58  懷何是寃端平心
    [22,  7,  0, -1], // 59  鄉舊眷土懷王秦
    [15,  9,  0,  1], // 60  繁華觀曜終始心
    [15, 16,  0,  1], // 61  詩興感遠殊浮沈
    [14, 16, -1,  1], // 62  圖怨念為懷如林
    [16, 16,  1,  1], // 63  氏辭懷感戚知麟
    [14, 15, -1,  0], // 64  璣明別改知識深
    [16, 15,  1,  0], // 65  蘇作興感昭恨神
    [16, 14,  1, -1], // 66  平端寃是何懷身
    [15,  7,  0, -1], // 67  徵流商歌鄭南音
    [16,  1,  1,  0], // 68  藏摧悲聲發曲秦
    [14,  1, -1,  0], // 69  和詠思惟空堂心
    [ 7,  8, -1,  0], // 70  蒼穹誓終篤志真
    [ 1,  7,  0, -1], // 71  唐虞聖德懷智仁
    [ 2,  1,  1,  0], // 72  傷慘懷慕增憂心
    [ 1,  9,  0,  1], // 73  妙顯華重榮章臣
    [ 1, 16,  0,  1], // 74  賢惟聖配英皇倫
    [ 2, 15,  1,  0], // 75  奸因女嬖至微深
    [ 8,  7,  0, -1], // 76  所感想忘淫荒心
    [ 9,  1,  1,  0], // 77  堂空惟思詠和音
    [16,  1,  1,  0], // 78  藏摧悲聲發曲秦
    [15,  2,  0,  1], // 79  南鄭歌商流徵殷
    [ 7,  1, -1,  0], // 80  憂增慕懷慘傷仁
    [ 1,  2,  0,  1], // 81  智懷德聖虞唐真
    [ 2,  2,  1,  1], // 82  嗟中君容曜多欽
  ],
}

// The 28 cells of poem `n` (1-based) of a 段: four consecutive lines of the
// sequence, starting at the window the text's own advances put it at.
//
// Stripped down: a window is `lines.slice(start - 1, start + 3)`, and `STARTS`
// is where each of the twenty-two windows begins. Advancing by one each time
// would give twenty-nine poems; he takes twenty-two.
const KANG_DIECI_STARTS =
  [1, 2, 4, 5, 6, 9, 10, 11, 13, 14, 15, 16, 17, 18, 19, 21, 22, 23, 25, 26, 28, 29]

// 讀法三之五's 段 is the long trace: eighty-two lines giving FIFTY-NINE poems,
// and 236 原讀 ÷ 4 段 = 59, so it is accounted for exactly like the other two.
// It is also the last one available — 讀法三之三 and 之四 both say
// 原讀無詩法只有章法故畧其圖不録, so 起宗 left those two with no worked example at
// all. Three traces in the whole book, and these are all three.
//
// Eighty-two of eighty-two lines locate in the square and every one ends on a
// lattice crossing, which with 之一 and 之二 makes 146 lines and 146 crossings.
const KANG_DIECI_STARTS_FIVE = [1,2,3,4,5,7,8,9,11,12,13,15,16,17,18,19,21,22,23,24,25,27,28,30,31,34,35,36,37,38,40,41,43,44,45,46,47,48,49,52,53,54,55,56,58,59,60,61,62,63,65,66,69,71,72,75,76,78,79]

function kangDieciLine(spec) {
  const [row, col, dr, dc] = spec
  const out = []
  for (let i = 0; i < 7; i += 1) out.push(kangCell(row + dr * i, col + dc * i))
  return out
}

/** The whole 段 traced in order — thirty-two lines, 224 cells. */
function kangDieciSegment(key) {
  return KANG_DIECI[key].flatMap(kangDieciLine)
}

/** One poem: four consecutive lines of the sequence. `n` is 1-based, 1..22. */
function kangDieciPoem(key, n) {
  // 之五 has its own window positions, because its 段 is eighty-two lines where
  // 之一 and 之二 are thirty-two.
  const table = key === "five" ? KANG_DIECI_STARTS_FIVE : KANG_DIECI_STARTS
  const start = table[n - 1]
  const lines = KANG_DIECI[key].slice(start - 1, start + 3)
  return lines.flatMap(kangDieciLine)
}

/** Every poem of a 段, for a view that wants to step through them. */
function kangDieciPoems(key) {
  const table = key === "five" ? KANG_DIECI_STARTS_FIVE : KANG_DIECI_STARTS
  return table.map((_, i) => kangDieciPoem(key, i + 1))
}

Object.assign(KANG_FIGURES, {
  kang_dieci_one:      { build: () => kangDieciSegment("one"), lineLength: 7,
                         han: "讀法三之一 遞退全段 — 三十二句", colour: "朱線" },
  kang_dieci_one_p1:   { build: () => kangDieciPoem("one", 1), lineLength: 7,
                         han: "讀法三之一 第一首 智懷…湘津", colour: "朱線" },
  kang_dieci_two:      { build: () => kangDieciSegment("two"), lineLength: 7,
                         han: "讀法三之二 遞退全段 — 三十二句", colour: "朱線" },
  kang_dieci_two_p1:   { build: () => kangDieciPoem("two", 1), lineLength: 7,
                         han: "讀法三之二 第一首 傷慘…清琴", colour: "朱線" },
  kang_dieci_five:     { build: () => kangDieciSegment("five"), lineLength: 7,
                         han: "讀法三之五 遞退全段 — 八十二句", colour: "朱線" },
  kang_dieci_five_p1:  { build: () => kangDieciPoem("five", 1), lineLength: 7,
                         han: "讀法三之五 第一首 嗟中…春親", colour: "朱線" },
})

// --- 附増第三圖: the eight rays from the centre ------------------------------
//
// 自正中行音南之遺身　横中行臣奸之舊新　斜行仁嗟之春親　琴廊之基津
//
// The middle row, the middle column and both diagonals, which is eight rays out
// of (15,15) — 心, the cell 璇璣圖詩 and 始平蘇氏 are wrapped around. Fourteen
// cells each, and each ray gives three seven-character lines:
//
//   inner, outward     詩興感遠殊浮沈      cells 1-7 from the centre
//   outer, outward     時盛意麗哀遺身      cells 8-14
//   outer, back        遺哀意麗盛時沈      cells 13-7, 退一字 again
//
// All 140 poems of this figure are named in the text by their first two and last
// two characters, and all 140 resolve: 90 pinned to a single quatrain by the two
// anchors plus the rotation, 50 to a pair differing only in the order of the
// middle two lines, which 倒換 is the name of. Four anchors are copying slips the
// geometry corrects — 佞因 for 奸因, 嗟仁 for 嗟中 as a START only, 徵深 for 徵殷,
// 微殷 for 微深.
const KANG_FUZENG_RAYS = [
  ["E", 0, 1], ["SE", 1, 1], ["S", 1, 0], ["SW", 1, -1],
  ["W", 0, -1], ["NW", -1, -1], ["N", -1, 0], ["NE", -1, 1],
]

function kangFuzengRay(dr, dc, kind) {
  const cells = []
  for (let i = 1; i <= 14; i += 1) cells.push([15 + dr * i, 15 + dc * i])
  const pick = kind === "inner" ? cells.slice(0, 7)
    : kind === "outer" ? cells.slice(7, 14)
    : cells.slice(6, 13).reverse()          // 退一字, coming back
  return pick.map(([r, c]) => kangCell(r, c))
}

/** All eight rays, inner then outer — the figure itself, 112 cells. */
function kangFuzengFigure() {
  const out = []
  for (const [, dr, dc] of KANG_FUZENG_RAYS) {
    out.push(...kangFuzengRay(dr, dc, "inner"), ...kangFuzengRay(dr, dc, "outer"))
  }
  return kangDedupe(out, [])
}

/** The three poems Kang works through, one per 讀法 of this figure. */
const KANG_FUZENG_WORKED = {
  // 讀法一: one line from each of four rays — 詩興／始終／蘇作／璣明
  kang_fuzeng_first:  [["E", "inner"], ["W", "inner"], ["S", "inner"], ["N", "inner"]],
  // 讀法二: 兩分 — both halves of two rays
  kang_fuzeng_second: [["E", "inner"], ["E", "outer"], ["W", "inner"], ["W", "outer"]],
  // 讀法三: the 退一字 lines coming back
  kang_fuzeng_third:  [["W", "back"], ["SW", "back"], ["S", "back"], ["SE", "back"]],
}

function kangFuzengWorked(key) {
  const byName = Object.fromEntries(KANG_FUZENG_RAYS.map(([n, dr, dc]) => [n, [dr, dc]]))
  return KANG_FUZENG_WORKED[key].flatMap(([ray, kind]) => {
    const [dr, dc] = byName[ray]
    return kangFuzengRay(dr, dc, kind)
  })
}

Object.assign(KANG_FIGURES, {
  kang_fuzeng_rays:   { build: kangFuzengFigure, lineLength: 7,
                        han: "附増第三圖 八靣 — 七言", colour: "朱線", region: false },
  kang_fuzeng_first:  { build: () => kangFuzengWorked("kang_fuzeng_first"),
                        lineLength: 7, han: "附増第三圖 讀法一 詩興…識深", colour: "朱線" },
  kang_fuzeng_second: { build: () => kangFuzengWorked("kang_fuzeng_second"),
                        lineLength: 7, han: "附増第三圖 讀法二 詩興…南音", colour: "朱線" },
  kang_fuzeng_third:  { build: () => kangFuzengWorked("kang_fuzeng_third"),
                        lineLength: 7, han: "附増第三圖 讀法三 南鄭…神麟", colour: "朱線" },
})

// --- 從外讀入 / 從内讀出 / 從下句間逓讀 -------------------------------------
//
// 新増讀法六　自寒歲五言從外讀入從内讀出
// 新増讀法七　自寧自作四言從外讀入從内讀出又於中央空方四方一段囘環互搭讀
//
// Three line-order transforms, and the text works all three so they can be read
// off rather than guessed. 第六圖's 寒歲 段 is 寒歲識凋松／貞物知終始／顔喪改華容
// ／仁賢別行士, and the 新増 readings it prints are
//
//   從外讀入     寒歲識凋松 仁賢別行士 顔喪改華容 貞物知終始     lines 1 4 3 2
//   從内讀出     貞物知終始 顔喪改華容 仁賢別行士 寒歲識凋松     lines 2 3 4 1
//
// and 第七圖's 寧自 段 prints the same two plus a third:
//
//   從外讀入     寧自感思 夢想勞形 側君在時 孜孜傷情             lines 1 4 3 2
//   從内讀出     孜孜傷情 側君在時 夢想勞形 寧自感思             lines 2 3 4 1
//   從下句間逓讀  孜孜傷情 寧自感思 夢想勞形 側君在時             lines 2 1 4 3
//
// Same three permutations on two different figures, so they are the transforms
// and not a local accident.
//
// This also corrects something: the enumerator in the research scripts built
// "outside in" for four lines as 1 4 2 3, pairing the ends and working inward.
// The text pairs the ends and then continues BACKWARD — 1 4 3 2. Mine was an
// invented expectation and his own worked poems caught it.
// --- 第四圖's 反覆 and 分讀 families, completed -----------------------------
//
// 讀法四　自嗟字起**反覆讀亦可分讀**
//
// The 段 is a 6x6 corner block read 反覆 down the columns, which gives twelve
// 三言 lines. Every reading of this figure is then a SELECTION of those lines
// plus a set of flips — 反覆 meaning the line is read backwards.
//
//     all twelve, no flips          嗟歎懐 所離經 遐曠路 … 多思感 誰為榮
//     all twelve, odd lines flipped 懐歎嗟 所離經 路曠遐 … 感思多 誰為榮
//     分讀, no flips                嗟歎懐 傷中情 家無君 朗鏡明 葩紛光 誰為榮
//     分讀, alternating flips       懐歎嗟 傷中情 君無家 朗鏡明 光紛葩 誰為榮
//     odd lines only, alternating   嗟歎懐 路曠遐 家無君 容飭華 葩紛光 感思多
//     odd lines only, all flipped   懐歎嗟 路曠遐 君無家 容飭華 光紛葩 感思多
//
// 分讀 takes the head of one six and the tail of the next, alternately, which is
// lines 1, 4, 5, 8, 9, 12 — the same thing kangSplitRead does and the reason a
// 6x6 block yields both 三言十二句 and 三言六句.
//
// AN EMENDATION THE GEOMETRY FORCES
// ---------------------------------
// The last of those six is printed in 新増讀法四 as
//
//     懐歎嗟路曠遐**家無君**容飭華光紛葩感思多
//
// but every other line of it is reversed and 家無君 is not. The regular pattern
// gives 君無家, which is the reverse of line 5 exactly as the other five lines
// are reverses of theirs. So 家無君 is a transposition slip for 君無家 — the same
// genus as 春芳 for 春方 in 第一圖's 采式, 徵深 for 徵殷 and 佞因 for 奸因 in
// 附増第三圖. The builder below produces the regular reading; the test asserts
// the emended text and names the difference.
const KANG_FOURTH_SELECT = {
  all:   [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11],
  split: [0, 3, 4, 7, 8, 11],
  odd:   [0, 2, 4, 6, 8, 10],
}

/** Twelve 三言 lines per corner block, selected and flipped. */
function kangFourthLines(select, flips) {
  const out = []
  for (const [r0, r1] of [KANG_BANDS[0], KANG_BANDS[2]]) {
    for (const [c0, c1] of [KANG_BANDS[0], KANG_BANDS[2]]) {
      const cells = kangRect(r0, r1, c0, c1, "snake-col")
      const lines = []
      for (let i = 0; i + 3 <= cells.length; i += 3) lines.push(cells.slice(i, i + 3))
      select.forEach((li, k) => {
        const line = lines[li]
        out.push(...(flips[k] ? line.slice().reverse() : line))
      })
    }
  }
  return out
}

const ALT_FROM_TRUE = [true, false, true, false, true, false]
const ALT_FROM_FALSE = [false, true, false, true, false, true]

Object.assign(KANG_FIGURES, {
  kang_fourth_black_alt: {
    build: () => kangFourthLines(KANG_FOURTH_SELECT.all,
                                 [0,1,2,3,4,5,6,7,8,9,10,11].map(i => i % 2 === 0)),
    lineLength: 3, han: "第四圖 四隅 反覆 懐歎起 — 三言十二句", colour: "墨" },
  kang_fourth_split_alt: {
    build: () => kangFourthLines(KANG_FOURTH_SELECT.split, ALT_FROM_TRUE),
    lineLength: 3, han: "第四圖 分讀 懐歎起 — 三言六句", colour: "墨" },
  kang_fourth_odd: {
    build: () => kangFourthLines(KANG_FOURTH_SELECT.odd, ALT_FROM_FALSE),
    lineLength: 3, han: "第四圖 間一句 嗟歎起 — 三言六句", colour: "墨" },
  kang_fourth_odd_rev: {
    build: () => kangFourthLines(KANG_FOURTH_SELECT.odd, [true, true, true, true, true, true]),
    lineLength: 3, han: "第四圖 間一句反覆 懐歎起 — 三言六句", colour: "墨" },
})

// --- 借字 on 第四圖: the one thing Kang says 起宗 missed --------------------
//
// The 采式 singles it out:
//
//     此圖内借字成言亦如第五圖　乃起宗獨於此中不相假借何也
//     余推而廣之所得益多　實取象於第五圖云
//
// "This figure's 借字 makes words just as in 第五圖; yet 起宗 alone did not borrow
// here — why? I extended it and gained more, taking 第五圖 as the model." So these
// four readings are Kang's own innovation rather than 起宗's, and he prints all
// four, which means the rule can be derived rather than guessed.
//
// THE RULE
// --------
// 第四圖's 段 reads as twelve 三言 lines (6x6 cells, 反覆 down the columns):
//
//     嗟歎懐 所離經 遐曠路 傷中情 家無君 房幃清
//     華飭容 朗鏡明 葩紛光 珠曜英 多思感 誰為榮
//
// 借n字 pairs those lines and takes n+3 characters SPANNING each join:
//
//     forward   the last n of the earlier line, then all of the later
//               (1,2) with n=1 → 懐 + 所離經 = 懐所離經
//     reversed  all of the earlier line, then the first n of the later,
//               read backwards
//               (3,4) with n=1 → reverse(遐曠路 + 傷) = 傷路曠遐
//
// 互用 ("used mutually") alternates the two kinds pair by pair; 間一句
// ("skipping a line") takes every pair forward. n = 1 gives 四言六句 and n = 2
// gives 五言六句, which is 借一字作四言借二字作五言 exactly as the 讀法 states.
//
// All four of his printed poems reproduce from this, character for character:
//
//     借一字 互用    懐所離經 傷路曠遐 君房幃清 朗容飭華 光珠曜英 誰感思多
//     借一字 間一句  懐所離經 路傷中情 君房幃清 容朗鏡明 光珠曜英 感誰為榮
//     借二字 互用    歎懐所離經 中傷路曠遐 無君房幃清 鏡朗容飭華 紛光珠曜英 為誰感思多
//     借二字 間一句  歎懐所離經 曠路傷中情 無君房幃清 飭容朗鏡明 紛光珠曜英 思感誰為榮
//
// 7 reading-groups of four poems each is 28, which is the 每段各増詩二十八首 the
// chapter claims, and 4 x 28 = 112, which is its 新増 total.
//
// Stripped right down, the whole of 借字 is this: walk the lines in pairs, and
// for each pair emit `a.slice(-n).concat(b)` or `a.concat(b.slice(0, n)).reverse()`.
function kangBorrow(cells, base, n, alternate) {
  const lines = []
  for (let i = 0; i + base <= cells.length; i += base) {
    lines.push(cells.slice(i, i + base))
  }
  const out = []
  for (let k = 0; k + 1 < lines.length; k += 2) {
    const a = lines[k]
    const b = lines[k + 1]
    if (alternate && ((k / 2) | 0) % 2 === 1) {
      out.push(...a.concat(b.slice(0, n)).reverse())
    } else {
      out.push(...a.slice(base - n).concat(b))
    }
  }
  return out
}

/** 第四圖's four corner blocks, each borrowed across its own joins. */
function kangFourthBorrow(n, alternate) {
  const out = []
  for (const [r0, r1] of [KANG_BANDS[0], KANG_BANDS[2]]) {
    for (const [c0, c1] of [KANG_BANDS[0], KANG_BANDS[2]]) {
      out.push(...kangBorrow(kangRect(r0, r1, c0, c1, "snake-col"), 3, n, alternate))
    }
  }
  return out
}

Object.assign(KANG_FIGURES, {
  kang_fourth_borrow1:     { build: () => kangFourthBorrow(1, true), lineLength: 4,
                             han: "第四圖 借一字互用 — 四言六句", colour: "墨" },
  kang_fourth_borrow1_alt: { build: () => kangFourthBorrow(1, false), lineLength: 4,
                             han: "第四圖 借一字間一句 — 四言六句", colour: "墨" },
  kang_fourth_borrow2:     { build: () => kangFourthBorrow(2, true), lineLength: 5,
                             han: "第四圖 借二字互用 — 五言六句", colour: "墨" },
  kang_fourth_borrow2_alt: { build: () => kangFourthBorrow(2, false), lineLength: 5,
                             han: "第四圖 借二字間一句 — 五言六句", colour: "墨" },
})

const KANG_LINE_ORDERS = {
  順:        [0, 1, 2, 3],
  從外讀入:   [0, 3, 2, 1],
  從内讀出:   [1, 2, 3, 0],
  從下句間逓讀: [1, 0, 3, 2],
}

/**
 * Take the first `n` lines of `cells`, optionally reverse some of them, then put
 * them in a new order.
 *
 * Stripped down, for anyone reading this later:
 *   lines  = cut the cell list into chunks of `len`
 *   flips  = booleans, one per line; true means read that line backwards
 *   order  = the positions to emit, so [0,3,2,1] means first, fourth, third, second
 *
 * 反覆 is `flips`; 從外讀入 and the rest are `order`. 第七圖's 新増 needs both,
 * because its base is already the 反覆 reading 寧自感思／孜孜傷情／側君在時／夢想勞形.
 */
function kangTransform(cells, len, lineCount, flips, order) {
  const lines = []
  for (let i = 0; i < lineCount; i += 1) {
    const line = cells.slice(i * len, (i + 1) * len)
    lines.push(flips[i] ? line.slice().reverse() : line)
  }
  return order.flatMap(i => lines[i])
}

const KANG_SIXTH_FLIPS = [false, false, false, false]
// 第七圖's 新増 works from the 反覆 reading, which reverses the odd-numbered lines.
const KANG_SEVENTH_FLIPS = [true, false, true, false]

function kangOrdered(figure, len, flips, orderName) {
  return () => kangTransform(KANG_FIGURES[figure].build(), len, 4, flips,
                             KANG_LINE_ORDERS[orderName])
}

Object.assign(KANG_FIGURES, {
  kang_sixth_outin:   { build: kangOrdered("kang_sixth_purple", 5, KANG_SIXTH_FLIPS, "從外讀入"),
                        lineLength: 5, han: "第六圖 從外讀入 — 五言四句", colour: "紫" },
  kang_sixth_inout:   { build: kangOrdered("kang_sixth_purple", 5, KANG_SIXTH_FLIPS, "從内讀出"),
                        lineLength: 5, han: "第六圖 從内讀出 — 五言四句", colour: "紫" },
  kang_seventh_outin: { build: kangOrdered("kang_seventh_yellow", 4, KANG_SEVENTH_FLIPS, "從外讀入"),
                        lineLength: 4, han: "第七圖 從外讀入 — 四言四句", colour: "黄" },
  kang_seventh_inout: { build: kangOrdered("kang_seventh_yellow", 4, KANG_SEVENTH_FLIPS, "從内讀出"),
                        lineLength: 4, han: "第七圖 從内讀出 — 四言四句", colour: "黄" },
  kang_seventh_inter: { build: kangOrdered("kang_seventh_yellow", 4, KANG_SEVENTH_FLIPS, "從下句間逓讀"),
                        lineLength: 4, han: "第七圖 從下句間逓讀 — 四言四句", colour: "黄" },
})

// The lines 第三圖 is RULED on, for a view to draw as borders rather than as
// cell colour — Kang's 紅線界畫. Rows and columns, 1-based, plus both diagonals.
const KANG_RULED_LINES = [1, 8, 15, 22, 29]
