import { Controller } from "@hotwired/stimulus"

// This controller does two things:
// 1) generates coordinate paths for simple reading rules (rows/columns/snakes)
// 2) animates the path on the SVG and prints the extracted text
export default class extends Controller {
  static values = {
    cells: Array,
    width: Number,
    height: Number,
  }

  static targets = [
    "rule",
    "lineLen",
    "speed",
    "output",
    "coupletComma",
    "playBtn",
  ]

  connect() {
    // Build a fast lookup: "x,y" -> char
    this.charAt = new Map()
    this.colorAt = new Map()
    for (const c of this.cellsValue) {
      this.charAt.set(`${c.x},${c.y}`, c.char)
      this.colorAt.set(`${c.x},${c.y}`, c.color || null)
    }

    this.timer = null
    this.stepIndex = 0
    this.currentPath = []

    this.rebuild()
  }

  disconnect() {
    this.pause()
  }

  ruleChanged() {
    this.rebuild()
  }

  rebuild() {
    this.pause()
    this.clearHighlights()
    this.stepIndex = 0

    const rule = this.ruleTarget.value
    this.currentPath = this.buildPath(rule)
    this.renderTextPreview()

    if (this.hasPlayBtnTarget) {
      this.playBtnTarget.textContent = "Play"
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

  // Clockwise traversal of the outer ring (or an inner ring via offset)
  // offset=0 => true perimeter. offset=1 => one cell in from the edge, etc.
  perimeterRing(w, h, offset = 0) {
    const left = 0 + offset
    const top = 0 + offset
    const right = w - 1 - offset
    const bottom = h - 1 - offset

    if (left > right || top > bottom) return []

    const coords = []

    // top row (L->R)
    for (let x = left; x <= right; x++) coords.push([x, top])
    // right col (T+1 -> B)
    for (let y = top + 1; y <= bottom; y++) coords.push([right, y])
    // bottom row (R-1 -> L) if distinct
    if (bottom !== top) {
      for (let x = right - 1; x >= left; x--) coords.push([x, bottom])
    }
    // left col (B-1 -> T+1) if distinct
    if (left !== right) {
      for (let y = bottom - 1; y >= top + 1; y--) coords.push([left, y])
    }

    return coords
  }

  // Cells that sit on a colour boundary (any 4-neighbour differs in colour)
  // Ordered top-to-bottom, left-to-right for deterministic playback.
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

  renderTextPreview() {
    const raw = this.currentPath.map(([x, y]) => this.charAt.get(`${x},${y}`) || "").join("")
    const n = parseInt(this.lineLenTarget.value || "7", 10)
    const coupletComma = this.hasCoupletCommaTarget ? this.coupletCommaTarget.checked : true
    this.outputTarget.textContent = this.segment(raw, n, coupletComma)
  }

  segment(text, n, coupletComma = true) {
    if (!n || n <= 0) return text
    const lines = []
    for (let i = 0; i < text.length; i += n) {
      const line = text.slice(i, i + n)
      if (line) lines.push(line)
    }

    // Render as couplets: line1，line2
    // This keeps punctuation optional: the rightbar can strip it afterwards.
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

  play() {
    if (this.timer) {
      // toggle
      this.pause()
      if (this.hasPlayBtnTarget) this.playBtnTarget.textContent = "Play"
      return
    }

    const delay = Math.max(10, parseInt(this.speedTarget.value || "40", 10))
    if (this.hasPlayBtnTarget) this.playBtnTarget.textContent = "Pause"

    this.timer = setInterval(() => {
      if (this.stepIndex >= this.currentPath.length) {
        this.pause()
        if (this.hasPlayBtnTarget) this.playBtnTarget.textContent = "Play"
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
      rect.classList.add("is-traced")
      rect.classList.add("is-active")
    }
  }

  clearHighlights() {
    const marked = this.element.querySelectorAll(".xuanji-rect.is-active, .xuanji-rect.is-traced")
    marked.forEach((el) => {
      el.classList.remove("is-active")
      el.classList.remove("is-traced")
    })
  }
}
