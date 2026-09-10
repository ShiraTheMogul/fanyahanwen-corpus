const DEFAULT_FONT_SIZE_PX = 20
const MIN_FONT_SIZE_PX = 12
const MAX_FONT_SIZE_PX = 48
const FONT_LAYOUT_PROBE_PX = 100
const FONT_LAYOUT_SAMPLE_LIMIT = 384
const DEFAULT_VERTICAL_TRACKING_EM = 0.02
const RUBY_VERTICAL_TRACKING_EM = 0.03
const AUTO_TRACKING_TRIGGER_EM = 0.08
const AUTO_TRACKING_SAFETY_EM = 0.04
const MAX_AUTO_TRACKING_EM = 0.75
const DEFAULT_COLUMN_FACTOR = 1.8
const AUTO_COLUMN_TRIGGER_EM = 1.65
const AUTO_COLUMN_RELATIVE_TRIGGER_EM = 0.10
const AUTO_COLUMN_SAFETY_EM = 0.15
const MAX_COLUMN_FACTOR = 3.0
const REFERENCE_FONT_STACK = '"WenJin Mincho", serif'
const VERTICAL_GLYPH_STYLE_ID = "fanya-han-font-vertical-glyph-spacing"
const GLYPH_VERTICAL_POSITION_TRIGGER_EM = 0.025
const GLYPH_VERTICAL_SAFETY_EM = 0.05
const MIN_GLYPH_SIDE_EXTRA_EM = 0.015
const MAX_GLYPH_SIDE_EXTRA_EM = 1.25
// Contenteditable Writer text cannot safely be wrapped character-by-character.
// For that surface we derive one conservative vertical rhythm from the same
// measured glyph geometry and reserve a small top/bottom writing margin.
const CONTINUOUS_TRACKING_TRIGGER_EM = 0.075
const CONTINUOUS_TRACKING_SAFETY_EM = 0.075
const MAX_CONTINUOUS_TRACKING_EM = 0.85
const MIN_CONTINUOUS_EDGE_PADDING_EM = 0.22
const MAX_CONTINUOUS_EDGE_PADDING_EM = 0.70
const FONT_LAYOUT_CACHE_LIMIT = 24
const fontLayoutCache = new Map()

export const HAN_FONT_SIZE_PRESETS = [14, 16, 18, 20, 22, 24, 28, 32, 36]

export function normaliseHanFontSize(value, fallback = DEFAULT_FONT_SIZE_PX) {
  const number = Number.parseInt(value, 10)
  const base = Number.isFinite(number) ? number : Number.parseInt(fallback, 10)
  const resolved = Number.isFinite(base) ? base : DEFAULT_FONT_SIZE_PX
  return Math.max(MIN_FONT_SIZE_PX, Math.min(MAX_FONT_SIZE_PX, resolved))
}

export function applyHanTypography(target, value) {
  if (!target?.style) return normaliseHanFontSize(value)
  const size = normaliseHanFontSize(value)
  const column = size * DEFAULT_COLUMN_FACTOR
  target.style.setProperty("--cv-font-size", `${size}px`)
  target.style.setProperty("--han-main-font-size", `${size}px`)
  target.style.setProperty("--han-column-advance", `${column}px`)
  target.style.setProperty("--han-jiagzhu-font-size", `${size * 0.5}px`)
  return size
}

function isHanCharacter(character) {
  try {
    return /^\p{Script=Han}$/u.test(character)
  } catch (_) {
    return /^[\u3400-\u9fff]$/.test(character)
  }
}

function uniqueHanCharacters(text) {
  const seen = new Set()
  const unique = []

  for (const character of Array.from(text || "")) {
    if (!isHanCharacter(character) || seen.has(character)) continue
    seen.add(character)
    unique.push(character)
  }
  return unique
}

export function hanTypographySample(text, limit = FONT_LAYOUT_SAMPLE_LIMIT) {
  const unique = uniqueHanCharacters(text)
  if (unique.length <= limit) return unique

  const sampled = []
  const step = unique.length / limit
  for (let index = 0; index < limit; index += 1) {
    sampled.push(unique[Math.floor(index * step)])
  }
  return sampled
}

function percentile(values, amount) {
  const sorted = values.filter(Number.isFinite).sort((a, b) => a - b)
  if (sorted.length === 0) return null
  const position = Math.max(0, Math.min(sorted.length - 1, Math.ceil(amount * sorted.length) - 1))
  return sorted[position]
}

function firstFontFamily(fontStack) {
  const text = (fontStack || "").trim()
  if (!text) return ""

  const doubleQuoted = text.match(/^"([^"]+)"/)
  if (doubleQuoted) return doubleQuoted[1]
  const singleQuoted = text.match(/^'([^']+)'/)
  if (singleQuoted) return singleQuoted[1]
  return text.split(",", 1)[0].trim()
}

function quoteFontFamily(family) {
  return `"${String(family || "").replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`
}

function computedFontStack(target, windowRef, documentRef) {
  try {
    const stack = windowRef?.getComputedStyle?.(target)?.fontFamily?.trim()
    if (stack) return stack
  } catch (_) {}

  try {
    return windowRef?.getComputedStyle?.(documentRef?.documentElement)
      ?.getPropertyValue?.("--han-font-stack")
      ?.trim?.() || ""
  } catch (_) {
    return ""
  }
}

async function ensureFontLoaded(documentRef, family, sample) {
  const fontSet = documentRef?.fonts
  if (!fontSet?.load || !family || sample.length === 0) return

  try {
    await fontSet.load(
      `${FONT_LAYOUT_PROBE_PX}px ${quoteFontFamily(family)}`,
      sample.join(""),
    )
  } catch (_) {}
}

function canvasCharacterMetrics(documentRef, fontStack, sample) {
  const canvas = documentRef?.createElement?.("canvas")
  const context = canvas?.getContext?.("2d")
  if (!context || typeof context.measureText !== "function") return null

  context.font = `${FONT_LAYOUT_PROBE_PX}px ${fontStack}`
  const byCharacter = new Map()

  for (const character of sample) {
    const metrics = context.measureText(character)
    const rawAscent = Number(metrics.actualBoundingBoxAscent)
    const rawDescent = Number(metrics.actualBoundingBoxDescent)
    const rawLeft = Number(metrics.actualBoundingBoxLeft)
    const rawRight = Number(metrics.actualBoundingBoxRight)

    const ascent = Number.isFinite(rawAscent) ? rawAscent / FONT_LAYOUT_PROBE_PX : null
    const descent = Number.isFinite(rawDescent) ? rawDescent / FONT_LAYOUT_PROBE_PX : null
    const left = Number.isFinite(rawLeft) ? rawLeft / FONT_LAYOUT_PROBE_PX : null
    const right = Number.isFinite(rawRight) ? rawRight / FONT_LAYOUT_PROBE_PX : null
    const height = Number.isFinite(ascent) && Number.isFinite(descent) && (ascent + descent) > 0
      ? ascent + descent
      : null
    const width = Number.isFinite(left) && Number.isFinite(right) && (left + right) > 0
      ? left + right
      : null

    // Canvas is only a fallback for browsers where SVG getBBox is unavailable.
    // Treat the horizontal ascent/descent as an approximate vertical envelope
    // so the caller can still distinguish before/after overhang.
    const top = Number.isFinite(ascent) ? -ascent : null
    const bottom = Number.isFinite(descent) ? descent : null

    if (Number.isFinite(height) || Number.isFinite(width)) {
      byCharacter.set(character, { height, width, top, bottom })
    }
  }

  return byCharacter.size > 0 ? byCharacter : null
}

function verticalSvgCharacterMetrics(documentRef, fontStack, characters) {
  const body = documentRef?.body
  if (!body || !documentRef?.createElementNS) return null

  const namespace = "http://www.w3.org/2000/svg"
  const svg = documentRef.createElementNS(namespace, "svg")
  const text = documentRef.createElementNS(namespace, "text")

  svg.setAttribute("aria-hidden", "true")
  svg.setAttribute("width", "1")
  svg.setAttribute("height", "1")
  svg.style.position = "fixed"
  svg.style.left = "-10000px"
  svg.style.top = "-10000px"
  svg.style.overflow = "visible"
  svg.style.opacity = "0"
  svg.style.pointerEvents = "none"

  text.setAttribute("x", "0")
  text.setAttribute("y", "0")
  text.style.fontFamily = fontStack
  text.style.fontSize = `${FONT_LAYOUT_PROBE_PX}px`
  text.style.fontWeight = "400"
  text.style.fontStyle = "normal"
  text.style.fontKerning = "none"
  text.style.writingMode = "vertical-rl"
  text.style.textOrientation = "mixed"

  svg.appendChild(text)
  body.appendChild(svg)

  const byCharacter = new Map()
  try {
    for (const character of characters) {
      text.textContent = character
      let box = null
      try {
        box = text.getBBox()
      } catch (_) {
        box = null
      }

      const rawX = Number(box?.x)
      const rawY = Number(box?.y)
      const rawWidth = Number(box?.width)
      const rawHeight = Number(box?.height)
      const x = Number.isFinite(rawX) ? rawX / FONT_LAYOUT_PROBE_PX : null
      const y = Number.isFinite(rawY) ? rawY / FONT_LAYOUT_PROBE_PX : null
      const width = Number.isFinite(rawWidth) && rawWidth > 0
        ? rawWidth / FONT_LAYOUT_PROBE_PX
        : null
      const height = Number.isFinite(rawHeight) && rawHeight > 0
        ? rawHeight / FONT_LAYOUT_PROBE_PX
        : null
      const top = Number.isFinite(y) ? y : null
      const bottom = Number.isFinite(y) && Number.isFinite(height) ? y + height : null
      const left = Number.isFinite(x) ? x : null
      const right = Number.isFinite(x) && Number.isFinite(width) ? x + width : null

      if (Number.isFinite(height) || Number.isFinite(width)) {
        byCharacter.set(character, { height, width, top, bottom, left, right })
      }
    }
  } finally {
    svg.remove()
  }

  return byCharacter.size > 0 ? byCharacter : null
}

function measuredCharacterMetrics(documentRef, fontStack, characters) {
  return verticalSvgCharacterMetrics(documentRef, fontStack, characters) ||
    canvasCharacterMetrics(documentRef, fontStack, characters)
}

function summarisePairedMetrics(selected, reference, sample) {
  const selectedHeights = []
  const referenceHeights = []
  const selectedWidths = []
  const referenceWidths = []
  const trackingCandidates = []
  const columnCandidates = []
  const verticalPositionCandidates = []

  for (const character of sample) {
    const selectedMetrics = selected?.get?.(character)
    if (!selectedMetrics) continue
    const referenceMetrics = reference?.get?.(character)

    const selectedHeight = Number(selectedMetrics.height)
    const referenceHeight = Number(referenceMetrics?.height)
    if (Number.isFinite(selectedHeight)) selectedHeights.push(selectedHeight)
    if (Number.isFinite(referenceHeight)) referenceHeights.push(referenceHeight)

    if (Number.isFinite(selectedHeight)) {
      const absoluteOverflow = selectedHeight - 1.0
      const relativeOverflow = Number.isFinite(referenceHeight)
        ? selectedHeight - referenceHeight
        : absoluteOverflow

      if (
        absoluteOverflow > AUTO_TRACKING_TRIGGER_EM &&
        relativeOverflow > AUTO_TRACKING_TRIGGER_EM
      ) {
        trackingCandidates.push(absoluteOverflow + AUTO_TRACKING_SAFETY_EM)
      }
    }

    const selectedTop = Number(selectedMetrics.top)
    const selectedBottom = Number(selectedMetrics.bottom)
    const referenceTop = Number(referenceMetrics?.top)
    const referenceBottom = Number(referenceMetrics?.bottom)
    if (
      Number.isFinite(selectedTop) &&
      Number.isFinite(selectedBottom) &&
      Number.isFinite(referenceTop) &&
      Number.isFinite(referenceBottom)
    ) {
      const beforeOverflow = referenceTop - selectedTop
      const afterOverflow = selectedBottom - referenceBottom
      const positionalOverflow = Math.max(beforeOverflow, afterOverflow, 0)
      if (positionalOverflow > GLYPH_VERTICAL_POSITION_TRIGGER_EM) {
        verticalPositionCandidates.push(positionalOverflow)
      }
    }

    const selectedWidth = Number(selectedMetrics.width)
    const referenceWidth = Number(referenceMetrics?.width)
    if (Number.isFinite(selectedWidth)) selectedWidths.push(selectedWidth)
    if (Number.isFinite(referenceWidth)) referenceWidths.push(referenceWidth)

    if (Number.isFinite(selectedWidth)) {
      const relativeWidthOverflow = Number.isFinite(referenceWidth)
        ? selectedWidth - referenceWidth
        : selectedWidth - 1.0

      if (
        selectedWidth > AUTO_COLUMN_TRIGGER_EM &&
        relativeWidthOverflow > AUTO_COLUMN_RELATIVE_TRIGGER_EM
      ) {
        columnCandidates.push(selectedWidth + AUTO_COLUMN_SAFETY_EM)
      }
    }
  }

  const heightP95 = percentile(selectedHeights, 0.95)
  const heightP99 = percentile(selectedHeights, 0.99)
  const referenceHeightP95 = percentile(referenceHeights, 0.95)
  const referenceHeightP99 = percentile(referenceHeights, 0.99)
  const positionP95 = percentile(verticalPositionCandidates, 0.95)

  const extraTrackingEm = trackingCandidates.length >= 2
    ? Math.min(
        MAX_AUTO_TRACKING_EM,
        Math.max(0, percentile(trackingCandidates, 0.75) || 0),
      )
    : 0

  // Writer uses uninterrupted text nodes so per-character layout padding would
  // interfere with caret/selection behaviour. Estimate a safe shared character
  // advance from the high end of the *actual vertical* ink measurements.
  // P99 catches isolated large OBI graphs in ordinary chapter-sized samples;
  // WenJin/Shanggu remain neutral because their measurements stay close to the
  // one-em reference envelope.
  const absoluteHeightRisk = Number.isFinite(heightP99) ? Math.max(0, heightP99 - 1.0) : 0
  const relativeHeightRisk = Number.isFinite(heightP99) && Number.isFinite(referenceHeightP99)
    ? Math.max(0, heightP99 - referenceHeightP99)
    : absoluteHeightRisk
  const positionRisk = Number.isFinite(positionP95) ? Math.max(0, positionP95) : 0
  const continuousRisk = Math.max(absoluteHeightRisk, relativeHeightRisk, positionRisk)
  const continuousTrackingEm = continuousRisk > CONTINUOUS_TRACKING_TRIGGER_EM
    ? Math.min(
        MAX_CONTINUOUS_TRACKING_EM,
        Math.max(0, continuousRisk + CONTINUOUS_TRACKING_SAFETY_EM),
      )
    : 0
  const continuousEdgePaddingEm = continuousTrackingEm > 0
    ? Math.min(
        MAX_CONTINUOUS_EDGE_PADDING_EM,
        Math.max(MIN_CONTINUOUS_EDGE_PADDING_EM, continuousTrackingEm * 0.65 + 0.10),
      )
    : 0

  const proposedColumnFactor = columnCandidates.length >= 2
    ? percentile(columnCandidates, 0.75)
    : null
  const columnFactor = Number.isFinite(proposedColumnFactor)
    ? Math.min(
        MAX_COLUMN_FACTOR,
        Math.max(DEFAULT_COLUMN_FACTOR, proposedColumnFactor),
      )
    : DEFAULT_COLUMN_FACTOR

  return {
    heightP95,
    heightP99,
    referenceHeightP95,
    referenceHeightP99,
    verticalPositionP95: positionP95,
    widthP95: percentile(selectedWidths, 0.95),
    referenceWidthP95: percentile(referenceWidths, 0.95),
    problemHeightGlyphs: trackingCandidates.length,
    problemVerticalPositionGlyphs: verticalPositionCandidates.length,
    problemWidthGlyphs: columnCandidates.length,
    extraTrackingEm,
    continuousTrackingEm,
    continuousEdgePaddingEm,
    columnFactor,
  }
}

function uniqueLayoutCharacters(root) {
  const seen = new Set()
  const output = []
  const spans = Array.from(root?.querySelectorAll?.(".cch") || [])

  if (spans.length > 0) {
    for (const element of spans) {
      if (element.hidden || element.hasAttribute?.("hidden")) continue
      if (element.classList?.contains?.("corpus-source-comment")) continue
      if (element.closest?.(".han-jiagzhu, rt, rp")) continue

      const chars = Array.from(element.textContent || "")
      if (chars.length !== 1 || /\s/u.test(chars[0]) || seen.has(chars[0])) continue
      seen.add(chars[0])
      output.push(chars[0])
    }
    return output
  }

  for (const character of Array.from(root?.textContent || "")) {
    if (/\s/u.test(character) || seen.has(character)) continue
    seen.add(character)
    output.push(character)
  }
  return output
}

function glyphVerticalPadding(selectedMetrics, referenceMetrics, characters) {
  const output = {}

  for (const character of characters) {
    const selected = selectedMetrics?.get?.(character)
    if (!selected) continue
    const reference = referenceMetrics?.get?.(character)

    const selectedTop = Number(selected.top)
    const selectedBottom = Number(selected.bottom)
    const referenceTop = Number(reference?.top)
    const referenceBottom = Number(reference?.bottom)

    let startExtra = 0
    let endExtra = 0

    if (
      Number.isFinite(selectedTop) &&
      Number.isFinite(selectedBottom) &&
      Number.isFinite(referenceTop) &&
      Number.isFinite(referenceBottom)
    ) {
      // Compare the rendered ink envelope with the same character in WenJin.
      // This is deliberately directional. A glyph such as 有 can overhang
      // mainly above its ordinary cell; giving it equal padding on both sides
      // leaves too much space below while still letting the top escape.
      startExtra = Math.max(0, referenceTop - selectedTop)
      endExtra = Math.max(0, selectedBottom - referenceBottom)
    } else {
      // Rare characters may be absent from the reference face too. Fall back
      // to total ink height and split the unknown overhang conservatively.
      const height = Number(selected.height)
      if (Number.isFinite(height) && height > 1.0) {
        const half = Math.max(0, height - 1.0) / 2
        startExtra = half
        endExtra = half
      }
    }

    const resolveSide = (value) => {
      if (!Number.isFinite(value) || value < MIN_GLYPH_SIDE_EXTRA_EM) return 0
      return Math.min(MAX_GLYPH_SIDE_EXTRA_EM, value + GLYPH_VERTICAL_SAFETY_EM)
    }

    const start = resolveSide(startExtra)
    const end = resolveSide(endExtra)
    if (start <= 0 && end <= 0) continue

    output[character] = {
      start: Number(start.toFixed(4)),
      end: Number(end.toFixed(4)),
    }
  }

  return output
}

function ensureVerticalGlyphStyles(documentRef) {
  if (!documentRef?.head || documentRef.getElementById?.(VERTICAL_GLYPH_STYLE_ID)) return

  const style = documentRef.createElement("style")
  style.id = VERTICAL_GLYPH_STYLE_ID
  style.textContent = `
    /* Some historical-script fonts draw beyond the ordinary one-em vertical
       character box. Add measured breathing room to the character that owns
       that ink. The span stays inline, preserving punctuation, ruby and normal
       browser fallback behaviour. Start/end padding are independent so a
       glyph whose ink rises above its cell can be moved inward without adding
       an equally large gap underneath. */
    .corpus-textflow.is-vertical .cch.han-font-vertical-glyph-space {
      padding-inline-start: var(--han-font-glyph-space-start, 0em);
      padding-inline-end: var(--han-font-glyph-space-end, 0em);
    }
  `
  documentRef.head.appendChild(style)
}

function clearVerticalGlyphLayout(target) {
  target?.querySelectorAll?.(".cch.han-font-vertical-glyph-space")?.forEach?.((element) => {
    element.classList.remove("han-font-vertical-glyph-space")
    element.style?.removeProperty?.("--han-font-glyph-space-start")
    element.style?.removeProperty?.("--han-font-glyph-space-end")
  })
}

function applyVerticalGlyphLayout(target, metrics) {
  clearVerticalGlyphLayout(target)
  if (!metrics?.adjusted) return

  const spacing = metrics?.characterVerticalSpacing || {}
  if (Object.keys(spacing).length === 0) return

  ensureVerticalGlyphStyles(target?.ownerDocument || document)

  Array.from(target.querySelectorAll?.(".cch") || []).forEach((element) => {
    if (element.hidden || element.hasAttribute?.("hidden")) return
    if (element.classList?.contains?.("corpus-source-comment")) return
    if (element.closest?.(".han-jiagzhu, rt, rp")) return

    const chars = Array.from(element.textContent || "")
    if (chars.length !== 1 || /\s/u.test(chars[0])) return

    const characterSpacing = spacing[chars[0]] || {}
    const start = Number(characterSpacing.start) || 0
    const end = Number(characterSpacing.end) || 0
    if (start <= 0 && end <= 0) return

    element.classList.add("han-font-vertical-glyph-space")
    element.style.setProperty("--han-font-glyph-space-start", `${start}em`)
    element.style.setProperty("--han-font-glyph-space-end", `${end}em`)
  })
}

export async function detectHanFontLayout(target, {
  root = target,
  documentRef = document,
  windowRef = window,
  continuous = false,
} = {}) {
  const layoutCharacters = uniqueLayoutCharacters(root)
  const allHanCharacters = layoutCharacters.filter(isHanCharacter)
  const sample = allHanCharacters.length <= FONT_LAYOUT_SAMPLE_LIMIT
    ? allHanCharacters
    : hanTypographySample(allHanCharacters.join(""))
  const fontStack = computedFontStack(target, windowRef, documentRef)
  const primaryFamily = firstFontFamily(fontStack)

  const neutral = {
    fontStack,
    primaryFamily,
    sampleSize: sample.length,
    heightP95: null,
    heightP99: null,
    referenceHeightP95: null,
    referenceHeightP99: null,
    verticalPositionP95: null,
    widthP95: null,
    referenceWidthP95: null,
    problemHeightGlyphs: 0,
    problemVerticalPositionGlyphs: 0,
    problemWidthGlyphs: 0,
    extraTrackingEm: 0,
    continuousTrackingEm: 0,
    continuousEdgePaddingEm: 0,
    columnFactor: DEFAULT_COLUMN_FACTOR,
    characterVerticalSpacing: {},
    adjusted: false,
  }

  if (sample.length === 0 || !fontStack) return neutral

  await Promise.all([
    ensureFontLoaded(documentRef, primaryFamily, sample),
    ensureFontLoaded(documentRef, "WenJin Mincho", sample),
  ])

  const cacheKey = `${continuous ? "continuous" : "indexed"}\u0000${fontStack}\u0000${layoutCharacters.join("")}`
  const cached = fontLayoutCache.get(cacheKey)
  if (cached) return { ...cached, characterVerticalSpacing: { ...(cached.characterVerticalSpacing || {}) } }

  // SVG writing-mode measurement sees the glyph after vertical shaping and
  // after CSS font fallback. Canvas is retained only as a browser fallback.
  const selectedSample = measuredCharacterMetrics(documentRef, fontStack, sample)
  if (!selectedSample) return neutral

  const reference = measuredCharacterMetrics(documentRef, REFERENCE_FONT_STACK, sample)
  const summary = summarisePairedMetrics(selectedSample, reference, sample)
  const adjusted =
    summary.problemHeightGlyphs > 0 ||
    summary.problemVerticalPositionGlyphs > 0 ||
    summary.extraTrackingEm > 0 ||
    summary.continuousTrackingEm > 0 ||
    summary.columnFactor > DEFAULT_COLUMN_FACTOR

  let characterVerticalSpacing = {}
  // The Corpus Reader can spend the extra work on exact per-glyph envelopes
  // because its source is already indexed into .cch spans. Writer requests
  // continuous mode and uses only the bounded 384-character sample above.
  if (adjusted && !continuous) {
    await Promise.all([
      ensureFontLoaded(documentRef, primaryFamily, layoutCharacters),
      ensureFontLoaded(documentRef, "WenJin Mincho", layoutCharacters),
    ])
    const [allMetrics, allReferenceMetrics] = [
      measuredCharacterMetrics(documentRef, fontStack, layoutCharacters),
      measuredCharacterMetrics(documentRef, REFERENCE_FONT_STACK, layoutCharacters),
    ]
    characterVerticalSpacing = glyphVerticalPadding(
      allMetrics,
      allReferenceMetrics,
      layoutCharacters,
    )
  }

  const result = {
    ...neutral,
    ...summary,
    characterVerticalSpacing,
    adjusted,
  }

  fontLayoutCache.set(cacheKey, result)
  if (fontLayoutCache.size > FONT_LAYOUT_CACHE_LIMIT) {
    const oldestKey = fontLayoutCache.keys().next().value
    if (oldestKey) fontLayoutCache.delete(oldestKey)
  }

  return { ...result, characterVerticalSpacing: { ...characterVerticalSpacing } }
}

export function applyDetectedHanFontLayout(target, metrics, {
  vertical = false,
  hasRuby = false,
  fontSizePx = DEFAULT_FONT_SIZE_PX,
  continuous = false,
} = {}) {
  if (!target?.style) return

  const clearContinuousLayout = () => {
    target.style.removeProperty("padding-inline-start")
    target.style.removeProperty("padding-inline-end")
  }

  if (!vertical) {
    target.style.removeProperty("letter-spacing")
    target.style.removeProperty("--cv-col")
    clearContinuousLayout()
    clearVerticalGlyphLayout(target)
    return
  }

  const columnFactor = Number(metrics?.columnFactor) || DEFAULT_COLUMN_FACTOR
  if (columnFactor > DEFAULT_COLUMN_FACTOR) {
    const size = normaliseHanFontSize(fontSizePx)
    target.style.setProperty("--cv-col", `${size * columnFactor}px`)
  } else {
    target.style.removeProperty("--cv-col")
  }

  if (continuous) {
    // Contenteditable Writer text deliberately remains ordinary text nodes so
    // browser selection, IME composition and annotation offsets remain stable.
    // Give an abnormal font one measured rhythm across the flow instead of
    // inserting presentation wrappers into the document.
    clearVerticalGlyphLayout(target)
    const extraTracking = Number(metrics?.continuousTrackingEm) || 0
    const edgePadding = Number(metrics?.continuousEdgePaddingEm) || 0
    const baseTracking = hasRuby ? RUBY_VERTICAL_TRACKING_EM : DEFAULT_VERTICAL_TRACKING_EM

    if (metrics?.adjusted && extraTracking > 0) {
      target.style.letterSpacing = `${baseTracking + extraTracking}em`
      target.style.setProperty("padding-inline-start", `${edgePadding}em`)
      target.style.setProperty("padding-inline-end", `${edgePadding}em`)
    } else {
      target.style.removeProperty("letter-spacing")
      clearContinuousLayout()
    }
    return
  }

  // Corpus Reader text has indexed .cch spans, so it can use the more precise
  // per-glyph directional envelope correction without affecting editable text.
  target.style.removeProperty("letter-spacing")
  clearContinuousLayout()
  applyVerticalGlyphLayout(target, metrics)
}

export function createHanFontSizeControl({
  documentRef = document,
  value = DEFAULT_FONT_SIZE_PX,
  onChange = null,
  className = "",
  label = "Size",
} = {}) {
  const wrapper = documentRef.createElement("label")
  wrapper.className = ["han-font-size-control", className].filter(Boolean).join(" ")

  const caption = documentRef.createElement("span")
  caption.className = "han-font-size-control__label"
  caption.textContent = label

  const select = documentRef.createElement("select")
  select.className = "han-font-size-control__select"
  select.setAttribute("aria-label", "Font size")

  const current = normaliseHanFontSize(value)
  const values = new Set([...HAN_FONT_SIZE_PRESETS, current])
  Array.from(values).sort((a, b) => a - b).forEach((size) => {
    const option = documentRef.createElement("option")
    option.value = String(size)
    option.textContent = `${size}px`
    option.selected = size === current
    select.appendChild(option)
  })

  select.addEventListener("change", () => {
    const size = normaliseHanFontSize(select.value)
    select.value = String(size)
    if (typeof onChange === "function") onChange(size)
  })

  wrapper.append(caption, select)
  return { wrapper, select }
}
