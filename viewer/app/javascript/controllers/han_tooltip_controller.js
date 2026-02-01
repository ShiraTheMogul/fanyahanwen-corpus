import { Controller } from "@hotwired/stimulus"

const HAN_RANGES = [
  [0x3400, 0x4DBF],   // Ext A
  [0x4E00, 0x9FFF],   // Unified
  [0xF900, 0xFAFF],   // Compatibility
  [0x2F800, 0x2FA1F], // Supplement
  [0x20000, 0x2A6DF], // Ext B
  [0x2A700, 0x2B73F], // Ext C
  [0x2B740, 0x2B81D], // Ext D
  [0x2B820, 0x2CEAD], // Ext E
  [0x2CEB0, 0x2EBEF], // Ext F
  [0x31350, 0x323AF], // Ext H
  [0x2EBF0, 0x2EE5D], // Ext I
  [0x323B0, 0x33479], // Ext J
]

function isHanCodePoint(cp) {
  return HAN_RANGES.some(([a, b]) => cp >= a && cp <= b)
}

function escapeHTML(s) {
  return String(s)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;")
}

function isLowSurrogate(code) {
  return code >= 0xDC00 && code <= 0xDFFF
}

function isHighSurrogate(code) {
  return code >= 0xD800 && code <= 0xDBFF
}

function rectContains(rect, x, y) {
  return x >= rect.left && x <= rect.right && y >= rect.top && y <= rect.bottom
}

function candidateAtTextOffset(textNode, i, x, y) {
  const text = textNode.nodeValue || ""
  if (!text) return null

  let idx = Math.max(0, Math.min(i, text.length - 1))

  // If we're sitting on a low surrogate, step back to the high surrogate.
  const c0 = text.charCodeAt(idx)
  if (isLowSurrogate(c0) && idx > 0) idx -= 1

  const cp = text.codePointAt(idx)
  if (!cp || !isHanCodePoint(cp)) return null

  const ch = String.fromCodePoint(cp)
  const len = cp > 0xFFFF ? 2 : 1

  // Verify the candidate is actually *under the pointer* using a Range box.
  try {
    const range = document.createRange()
    range.setStart(textNode, idx)
    range.setEnd(textNode, Math.min(text.length, idx + len))

    const rects = range.getClientRects()
    if (rects && rects.length) {
      // Any rect containing the click counts.
      for (const r of rects) {
        if (rectContains(r, x, y)) return { ch, cp }
      }
      return null
    }

    // If we don't get rects (rare), fall back to accepting.
    return { ch, cp }
  } catch {
    return { ch, cp }
  }
}

function resolveTextNodeNear(node, offset) {
  if (!node) return { node: null, offset: null }

  if (node.nodeType === Node.TEXT_NODE) return { node, offset }

  if (node.nodeType !== Node.ELEMENT_NODE) return { node: null, offset: null }

  const el = node
  const kids = Array.from(el.childNodes || [])
  const i = Math.max(0, Math.min(typeof offset === "number" ? offset : 0, kids.length))

  const tryNode = (n) => {
    if (!n) return null
    if (n.nodeType === Node.TEXT_NODE) return n
    // Descend to first text node.
    const w = document.createTreeWalker(n, NodeFilter.SHOW_TEXT)
    return w.nextNode()
  }

  // 1) Prefer the child at offset.
  const direct = tryNode(kids[i])
  if (direct) return { node: direct, offset: 0 }

  // 2) Try the previous child.
  const prev = tryNode(kids[i - 1])
  if (prev) return { node: prev, offset: (prev.nodeValue || "").length }

  // 3) Walk siblings outward.
  for (let d = 1; d <= 6; d++) {
    const left = tryNode(kids[i - d])
    if (left) return { node: left, offset: (left.nodeValue || "").length }
    const right = tryNode(kids[i + d])
    if (right) return { node: right, offset: 0 }
  }

  return { node: null, offset: null }
}

function pickHanAtPoint(event) {
  const x = event.clientX
  const y = event.clientY

  let node = null
  let offset = null

  if (document.caretPositionFromPoint) {
    const pos = document.caretPositionFromPoint(x, y)
    node = pos?.offsetNode || null
    offset = typeof pos?.offset === "number" ? pos.offset : null
  } else if (document.caretRangeFromPoint) {
    const range = document.caretRangeFromPoint(x, y)
    node = range?.startContainer || null
    offset = typeof range?.startOffset === "number" ? range.startOffset : null
  }

  const resolved = resolveTextNodeNear(node, offset)
  const tnode = resolved.node
  const toff = resolved.offset

  if (tnode && tnode.nodeType === Node.TEXT_NODE && typeof toff === "number") {
    // Try the caret position, then the previous character.
    const a = candidateAtTextOffset(tnode, toff, x, y)
    if (a) return a

    // If the caret is between chars, the previous one is often the right answer.
    const b = candidateAtTextOffset(tnode, Math.max(0, toff - 1), x, y)
    if (b) return b

    // One more left for safety (handles surrogate alignment edge cases).
    const c = candidateAtTextOffset(tnode, Math.max(0, toff - 2), x, y)
    if (c) return c
  }

  // No precise hit → no tooltip (avoids the "random first character" issue).
  return null
}

function getHanFontPrimaryFamily() {
  const v = getComputedStyle(document.documentElement)
    .getPropertyValue("--han-font-primary")
    .trim()
  return v.replace(/^"|"$/g, "")
}

function warnMissingEnabled() {
  const v = document.body?.dataset?.hanFontWarnMissing
  return v === "1" || v === "true"
}

export default class extends Controller {
  static values = { delay: { type: Number, default: 140 } }

  connect() {
    this._cache = new Map() // chr -> preview payload
    this._tooltipEl = null
    this._pinned = false
    this._clickTimer = null

    this._onDocClick = (e) => {
      if (!this._tooltipEl) return
      if (this._pinned) return
      if (this._tooltipEl.contains(e.target)) return
      this.hide()
    }

    this._onKeyDown = (e) => {
      if (!this._tooltipEl) return

      if (e.key === "Escape") {
        this._pinned = false
        this.hide()
        return
      }

      if (e.key === "p" || e.key === "P") {
        this._togglePin()
        return
      }

      const tabs = Array.from(this._tooltipEl.querySelectorAll("[data-tab]"))
      if (tabs.length === 0) return
      const active = tabs.findIndex(t => t.classList.contains("is-active"))

      if (e.key === "ArrowRight") {
        e.preventDefault()
        tabs[(active + 1) % tabs.length].click()
      } else if (e.key === "ArrowLeft") {
        e.preventDefault()
        tabs[(active - 1 + tabs.length) % tabs.length].click()
      } else if (e.key === "Enter") {
        e.preventDefault()
        const ch = this._tooltipEl.getAttribute("data-char")
        if (ch) window.location.href = `/characters/${encodeURIComponent(ch)}`
      }
    }

    this._onWheel = () => {
      if (!this._tooltipEl) return
      if (this._pinned) return
      this.hide()
    }

    // Some parts of the reader UI may stop bubbling dblclick events (e.g. to avoid
    // accidental navigation during selection). We *want* dblclick to open the
    // character page, so we listen in capture phase as a safety net.
    this._onDblClickCapture = (e) => {
      if (document.documentElement.classList.contains("cv-annotate-mode")) return
      // Don't hijack dblclicks inside the tooltip itself.
      if (e.target?.closest?.(".han-tooltip")) return
      if (e.target?.closest?.("a, button, input, textarea, select, [contenteditable='true']")) return

      const picked = pickHanAtPoint(e)
      if (!picked) return

      clearTimeout(this._clickTimer)
      this.hide()
      window.location.href = `/characters/${encodeURIComponent(picked.ch)}`
    }

    document.addEventListener("click", this._onDocClick)
    document.addEventListener("keydown", this._onKeyDown)
    document.addEventListener("wheel", this._onWheel, { passive: true })
    document.addEventListener("dblclick", this._onDblClickCapture, true)
  }

  disconnect() {
    document.removeEventListener("click", this._onDocClick)
    document.removeEventListener("keydown", this._onKeyDown)
    document.removeEventListener("wheel", this._onWheel)
    document.removeEventListener("dblclick", this._onDblClickCapture, true)
    this.hide()
  }

  click(event) {
    if (document.documentElement.classList.contains("cv-annotate-mode")) return
    if (this._pinned) return
    if (event.target.closest("a, button, input, textarea, select, [contenteditable='true']")) return

    const picked = pickHanAtPoint(event)
    if (!picked) return

    clearTimeout(this._clickTimer)
    this._clickTimer = setTimeout(() => {
      this.show(picked.ch, event.clientX, event.clientY)
    }, this.delayValue)
  }

  dblclick(event) {
    if (document.documentElement.classList.contains("cv-annotate-mode")) return
    if (document.documentElement.classList.contains("cv-annotate-mode")) return
    const picked = pickHanAtPoint(event)
    if (!picked) return

    clearTimeout(this._clickTimer)
    this.hide()
    window.location.href = `/characters/${encodeURIComponent(picked.ch)}`
  }

  async show(ch, x, y) {
    const cached = this._cache.get(ch)
    if (cached) {
      this._render(cached, ch, x, y)
      return
    }

    const res = await fetch(`/characters/${encodeURIComponent(ch)}/preview`, {
      headers: { Accept: "application/json" },
      credentials: "same-origin",
    })
    if (!res.ok) return

    const data = await res.json()
    if (!data?.found) return

    this._cache.set(ch, data)
    this._render(data, ch, x, y)
  }

  hide() {
    if (this._tooltipEl) {
      this._tooltipEl.remove()
      this._tooltipEl = null
    }
  }

  _togglePin() {
    this._pinned = !this._pinned
    const pin = this._tooltipEl?.querySelector("[data-pin]")
    if (pin) pin.classList.toggle("is-active", this._pinned)
  }

  _render(data, ch, x, y) {
    this.hide()
    this._pinned = false

    const el = document.createElement("div")
    el.className = "han-tooltip"
    el.setAttribute("data-char", ch)
    el.innerHTML = this._html(data)

    document.body.appendChild(el)
    this._tooltipEl = el

    el.querySelector("[data-close]")?.addEventListener("click", (e) => {
      e.preventDefault()
      e.stopPropagation()
      this._pinned = false
      this.hide()
    })

    el.querySelector("[data-open]")?.addEventListener("click", (e) => {
      e.preventDefault()
      e.stopPropagation()
      window.location.href = `/characters/${encodeURIComponent(ch)}`
    })

    el.querySelector("[data-pin]")?.addEventListener("click", (e) => {
      e.preventDefault()
      e.stopPropagation()
      this._togglePin()
    })

    el.querySelectorAll("[data-tab]").forEach(btn => {
      btn.addEventListener("click", (e) => {
        e.preventDefault()
        const key = btn.getAttribute("data-tab")
        el.querySelectorAll("[data-tab]").forEach(b => b.classList.toggle("is-active", b === btn))
        el.querySelectorAll("[data-panel]").forEach(p => p.classList.toggle("is-active", p.getAttribute("data-panel") === key))
      })
    })
    el.querySelector("[data-tab]")?.click()

    this._maybeWarnMissingGlyph(ch, el)

    // position near cursor and clamp
    const pad = 12
    el.style.left = "0px"
    el.style.top = "0px"
    const r = el.getBoundingClientRect()
    let left = x + pad
    let top = y + pad
    if (left + r.width > window.innerWidth - 8) left = window.innerWidth - r.width - 8
    if (top + r.height > window.innerHeight - 8) top = window.innerHeight - r.height - 8
    el.style.left = `${Math.max(8, left)}px`
    el.style.top = `${Math.max(8, top)}px`
  }

  _maybeWarnMissingGlyph(ch, el) {
    if (!warnMissingEnabled()) return

    const fam = getHanFontPrimaryFamily()
    if (!fam) return
    // If the selected font *is* WenJin, there is nothing meaningful to warn about.
    if (fam.toLowerCase().includes("wenjin")) return

    const checkNow = () => {
      try {
        const ok = document.fonts && document.fonts.check && document.fonts.check(`16px "${fam}"`, ch)
        if (ok) return

        const msg = `Primary font ${fam} does not include ${ch}; falling back to WenJin Mincho.`
        const warn = el.querySelector("[data-missing-glyph]")
        if (warn) {
          warn.textContent = msg
          warn.style.display = "block"
        }

        const glyph = el.querySelector(".han-tooltip-char")
        if (glyph) glyph.style.fontFamily = '"WenJin Mincho", serif'
      } catch {
        // ignore
      }
    }

    const run = () => {
      // Try to load the specific glyph first to avoid false negatives.
      if (document.fonts?.load) {
        document.fonts.load(`16px "${fam}"`, ch).then(checkNow).catch(checkNow)
      } else {
        checkNow()
      }
    }

    if (document.fonts?.ready) {
      document.fonts.ready.then(run).catch(run)
    } else {
      run()
    }
  }



  _html(data) {
    const ced = Array.isArray(data.dictionaries?.cedict) ? data.dictionaries.cedict : []
    const unihan = data.dictionaries?.unihan || ""
    const kangxi = data.dictionaries?.kangxi || ""
    // Tooltip reading is independent of whether ruby is enabled in the reader.
    const reading = data.ruby?.reading || ""

    return `
      <div class="han-tooltip-head">
        <div class="han-tooltip-char">${escapeHTML(data.chr)}</div>
        <div class="han-tooltip-meta">
          <div>${escapeHTML(data.uplus || "")}${data.block ? " · " + escapeHTML(data.block) : ""}</div>
          ${reading ? `<div class="han-tooltip-reading muted">${escapeHTML(reading)}</div>` : ``}
          <div class="han-tooltip-warning muted" data-missing-glyph style="display:none;"></div>
          <div class="han-tooltip-actions">
            <button class="han-tooltip-btn" data-open title="Open entry">↗</button>
            <button class="han-tooltip-btn" data-pin title="Pin">📌</button>
            <button class="han-tooltip-btn" data-close title="Close">×</button>
          </div>
        </div>
      </div>

      <div class="han-tooltip-tabs">
        <button class="han-tooltip-tab" data-tab="cedict">CEDICT</button>
        <button class="han-tooltip-tab" data-tab="unihan">Unihan</button>
        <button class="han-tooltip-tab" data-tab="kangxi">Kangxi</button>
      </div>

      <div class="han-tooltip-panels">
        <div class="han-tooltip-panel" data-panel="cedict">
          ${ced.length ? `<ol>${ced.map(d => `<li>${escapeHTML(d)}</li>`).join("")}</ol>` : `<div class="muted">No CC-CEDICT defs.</div>`}
        </div>
        <div class="han-tooltip-panel" data-panel="unihan">
          ${unihan ? `<div>${escapeHTML(unihan)}</div>` : `<div class="muted">No Unihan definition.</div>`}
        </div>
        <div class="han-tooltip-panel" data-panel="kangxi">
          ${kangxi ? `<div>${escapeHTML(kangxi)}</div>` : `<div class="muted">No Kangxi gloss.</div>`}
        </div>
      </div>

      <div class="han-tooltip-foot muted">
        Click: preview · Double-click: open · Scroll: hide · ←/→ tabs · P pin · Esc close · Enter open
      </div>
    `
  }
}
