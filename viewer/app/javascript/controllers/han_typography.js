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
const PRIMARY_COVERAGE_PROBE_FALLBACK = "monospace"
const FALLBACK_METRIC_EPSILON_EM = 0.0025
const MIN_FALLBACK_BOUNDARY_GAP_EM = 0.06
const MAX_FALLBACK_BOUNDARY_GAP_EM = 0.30
const FALLBACK_STYLE_ID = "fanya-han-font-fallback-layout"
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

  // Sample across the whole text instead of taking only the opening lines.
  // This matters for sparse historical-script fonts whose covered characters
  // may be scattered throughout a chapter.
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
    const rawAdvance = Number(metrics.width)

    const ascent = Number.isFinite(rawAscent) ? rawAscent / FONT_LAYOUT_PROBE_PX : null
    const descent = Number.isFinite(rawDescent) ? rawDescent / FONT_LAYOUT_PROBE_PX : null
    const left = Number.isFinite(rawLeft) ? rawLeft / FONT_LAYOUT_PROBE_PX : null
    const right = Number.isFinite(rawRight) ? rawRight / FONT_LAYOUT_PROBE_PX : null
    const advance = Number.isFinite(rawAdvance) ? rawAdvance / FONT_LAYOUT_PROBE_PX : null
    const height = Number.isFinite(ascent) && Number.isFinite(descent) && (ascent + descent) > 0
      ? ascent + descent
      : null
    const width = Number.isFinite(left) && Number.isFinite(right) && (left + right) > 0
      ? left + right
      : null

    if (Number.isFinite(height) || Number.isFinite(width) || Number.isFinite(advance)) {
      byCharacter.set(character, { height, width, advance, ascent, descent, left, right })
    }
  }

  return byCharacter.size > 0 ? byCharacter : null
}

const FALLBACK_FINGERPRINT_KEYS = [
  "height",
  "width",
  "advance",
  "ascent",
  "descent",
  "left",
  "right",
]

function metricFingerprintsMatch(leftMetrics, rightMetrics, epsilon = FALLBACK_METRIC_EPSILON_EM) {
  if (!leftMetrics || !rightMetrics) return false
  let compared = 0

  for (const key of FALLBACK_FINGERPRINT_KEYS) {
    const left = Number(leftMetrics[key])
    const right = Number(rightMetrics[key])
    if (!Number.isFinite(left) || !Number.isFinite(right)) continue
    compared += 1
    if (Math.abs(left - right) > epsilon) return false
  }

  return compared >= 4
}

function fallbackCharactersFromMetrics(selected, primaryProbe, characters) {
  const fallback = []

  for (const character of characters) {
    const selectedMetrics = selected?.get?.(character)
    const primaryMetrics = primaryProbe?.get?.(character)
    if (!selectedMetrics || !primaryMetrics) continue

    // The real stack and the probe both begin with the selected primary face.
    // The probe then switches to an intentionally different fallback. If the
    // primary owns this character, both renders still use that same primary
    // face and their metric fingerprints remain equal. If they diverge, the
    // browser had to leave the primary face for this character. This detects
    // fallback runs without knowing the selected font's name or coverage list.
    if (!metricFingerprintsMatch(selectedMetrics, primaryMetrics)) fallback.push(character)
  }

  return fallback
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

function summarisePairedMetrics(selected, reference, sample, fallbackCharacters = []) {
  const selectedHeights = []
  const referenceHeights = []
  const selectedWidths = []
  const referenceWidths = []
  const trackingCandidates = []
  const columnCandidates = []
  const fallbackSet = new Set(fallbackCharacters)

  for (const character of sample) {
    const selectedMetrics = selected?.get?.(character)
    if (!selectedMetrics) continue
    const referenceMetrics = reference?.get?.(character)

    // Geometry correction describes the selected face itself. Characters that
    // already came from WenJin fallback must not dilute those measurements.
    if (fallbackSet.has(character)) continue

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

  // A single malformed outline should not loosen an entire chapter. Two or
  // more matching problem glyphs are enough to establish that the selected
  // font has a repeatable geometry problem. We then use the 75th percentile
  // of only those problem glyphs, so sparse historical-script coverage is
  // still detected without letting one extreme graph dictate the layout.
  const enoughTrackingEvidence = trackingCandidates.length >= 2
  const enoughColumnEvidence = columnCandidates.length >= 2

  const extraTrackingEm = enoughTrackingEvidence
    ? Math.min(
        MAX_AUTO_TRACKING_EM,
        Math.max(0, percentile(trackingCandidates, 0.75) || 0),
      )
    : 0

  const proposedColumnFactor = enoughColumnEvidence
    ? percentile(columnCandidates, 0.75)
    : null
  const columnFactor = Number.isFinite(proposedColumnFactor)
    ? Math.min(
        MAX_COLUMN_FACTOR,
        Math.max(DEFAULT_COLUMN_FACTOR, proposedColumnFactor),
      )
    : DEFAULT_COLUMN_FACTOR

  return {
    heightP95: percentile(selectedHeights, 0.95),
    referenceHeightP95: percentile(referenceHeights, 0.95),
    widthP95: percentile(selectedWidths, 0.95),
    referenceWidthP95: percentile(referenceWidths, 0.95),
    problemHeightGlyphs: trackingCandidates.length,
    problemWidthGlyphs: columnCandidates.length,
    extraTrackingEm,
    columnFactor,
  }
}

function fallbackBoundaryGapEm(summary) {
  const extraTracking = Math.max(0, Number(summary?.extraTrackingEm) || 0)
  if (extraTracking <= 0) return 0

  // The ordinary tracking already separates two glyphs from the same face.
  // A font transition gets half of that correction on the boundary itself,
  // which protects a normal-sized fallback glyph from a neighbouring face
  // whose ink box extends beyond its nominal em.
  return Math.min(
    MAX_FALLBACK_BOUNDARY_GAP_EM,
    Math.max(MIN_FALLBACK_BOUNDARY_GAP_EM, extraTracking * 0.5),
  )
}

function ensureFallbackLayoutStyles(documentRef) {
  if (!documentRef?.head || documentRef.getElementById?.(FALLBACK_STYLE_ID)) return

  const style = documentRef.createElement("style")
  style.id = FALLBACK_STYLE_ID
  style.textContent = `
    .corpus-textflow.is-vertical .cch.han-font-fallback-start {
      margin-inline-start: var(--han-font-fallback-boundary-gap, 0em);
    }

    .corpus-textflow.is-vertical .cch.han-font-fallback-end {
      margin-inline-end: var(--han-font-fallback-boundary-gap, 0em);
    }
  `
  documentRef.head.appendChild(style)
}

function clearFallbackRunLayout(target) {
  target?.style?.removeProperty?.("--han-font-fallback-boundary-gap")
  target?.querySelectorAll?.(
    ".cch.han-font-fallback, .cch.han-font-fallback-start, .cch.han-font-fallback-end",
  )?.forEach?.((element) => {
    element.classList.remove(
      "han-font-fallback",
      "han-font-fallback-start",
      "han-font-fallback-end",
    )
  })
}

function applyFallbackRunLayout(target, metrics) {
  clearFallbackRunLayout(target)

  const fallbackCharacters = new Set(metrics?.fallbackCharacters || [])
  const gap = Number(metrics?.fallbackBoundaryGapEm) || 0
  if (fallbackCharacters.size === 0 || gap <= 0) return

  ensureFallbackLayoutStyles(target?.ownerDocument || document)
  target.style.setProperty("--han-font-fallback-boundary-gap", `${gap}em`)

  const characters = Array.from(target.querySelectorAll?.(".cch") || []).filter((element) => {
    if (element.closest?.(".han-jiagzhu, rt, rp")) return false
    const text = Array.from(element.textContent || "")
    return text.length === 1 && isHanCharacter(text[0])
  })

  const fallbackState = characters.map((element) => {
    const character = Array.from(element.textContent || "")[0]
    return fallbackCharacters.has(character)
  })

  characters.forEach((element, index) => {
    if (!fallbackState[index]) return
    element.classList.add("han-font-fallback")

    if (index === 0 || !fallbackState[index - 1]) {
      element.classList.add("han-font-fallback-start")
    }
    if (index === characters.length - 1 || !fallbackState[index + 1]) {
      element.classList.add("han-font-fallback-end")
    }
  })
}

export async function detectHanFontLayout(target, {
  root = target,
  documentRef = document,
  windowRef = window,
} = {}) {
  const allCharacters = uniqueHanCharacters(root?.textContent || "")
  const sample = allCharacters.length <= FONT_LAYOUT_SAMPLE_LIMIT
    ? allCharacters
    : hanTypographySample(allCharacters.join(""))
  const fontStack = computedFontStack(target, windowRef, documentRef)
  const primaryFamily = firstFontFamily(fontStack)

  const neutral = {
    fontStack,
    primaryFamily,
    sampleSize: sample.length,
    heightP95: null,
    referenceHeightP95: null,
    widthP95: null,
    referenceWidthP95: null,
    problemHeightGlyphs: 0,
    problemWidthGlyphs: 0,
    extraTrackingEm: 0,
    columnFactor: DEFAULT_COLUMN_FACTOR,
    fallbackCharacters: [],
    fallbackBoundaryGapEm: 0,
    adjusted: false,
  }

  if (sample.length === 0 || !fontStack) return neutral

  await Promise.all([
    ensureFontLoaded(documentRef, primaryFamily, sample),
    ensureFontLoaded(documentRef, "WenJin Mincho", sample),
  ])

  const cacheKey = `${fontStack}\u0000${allCharacters.join("")}`
  const cached = fontLayoutCache.get(cacheKey)
  if (cached) return { ...cached, fallbackCharacters: [...(cached.fallbackCharacters || [])] }

  const primaryProbeStack = `${quoteFontFamily(primaryFamily)}, ${PRIMARY_COVERAGE_PROBE_FALLBACK}`
  const selected = canvasCharacterMetrics(documentRef, fontStack, sample)
  if (!selected) return neutral

  const reference = canvasCharacterMetrics(documentRef, REFERENCE_FONT_STACK, sample)
  const primaryProbe = canvasCharacterMetrics(documentRef, primaryProbeStack, sample)
  const sampleFallbackCharacters = fallbackCharactersFromMetrics(
    selected,
    primaryProbe,
    sample,
  )
  const summary = summarisePairedMetrics(
    selected,
    reference,
    sample,
    sampleFallbackCharacters,
  )

  const adjusted =
    summary.extraTrackingEm > 0 ||
    summary.columnFactor > DEFAULT_COLUMN_FACTOR

  let fallbackCharacters = sampleFallbackCharacters
  if (adjusted && allCharacters.length !== sample.length) {
    // Geometry uses a bounded sample, but fallback transitions must be known
    // for every distinct Han character in the rendered chapter. Measuring
    // unique characters keeps this independent of chapter length.
    const selectedAll = canvasCharacterMetrics(documentRef, fontStack, allCharacters)
    const referenceAll = canvasCharacterMetrics(documentRef, REFERENCE_FONT_STACK, allCharacters)
    const primaryProbeAll = canvasCharacterMetrics(documentRef, primaryProbeStack, allCharacters)
    fallbackCharacters = fallbackCharactersFromMetrics(
      selectedAll,
      primaryProbeAll,
      allCharacters,
    )
  }

  const result = {
    ...neutral,
    ...summary,
    fallbackCharacters,
    fallbackBoundaryGapEm: adjusted ? fallbackBoundaryGapEm(summary) : 0,
    adjusted,
  }

  fontLayoutCache.set(cacheKey, result)
  if (fontLayoutCache.size > FONT_LAYOUT_CACHE_LIMIT) {
    const oldestKey = fontLayoutCache.keys().next().value
    if (oldestKey) fontLayoutCache.delete(oldestKey)
  }

  return { ...result, fallbackCharacters: [...fallbackCharacters] }
}

export function applyDetectedHanFontLayout(target, metrics, {
  vertical = false,
  hasRuby = false,
  fontSizePx = DEFAULT_FONT_SIZE_PX,
} = {}) {
  if (!target?.style) return

  if (!vertical) {
    target.style.removeProperty("letter-spacing")
    target.style.removeProperty("--cv-col")
    clearFallbackRunLayout(target)
    return
  }

  const extraTracking = Number(metrics?.extraTrackingEm) || 0
  const baseTracking = hasRuby ? RUBY_VERTICAL_TRACKING_EM : DEFAULT_VERTICAL_TRACKING_EM

  if (extraTracking > 0) {
    target.style.letterSpacing = `${baseTracking + extraTracking}em`
  } else {
    // Let corpusviewer.css retain exact control of the gold-standard case.
    target.style.removeProperty("letter-spacing")
  }

  const columnFactor = Number(metrics?.columnFactor) || DEFAULT_COLUMN_FACTOR
  if (columnFactor > DEFAULT_COLUMN_FACTOR) {
    const size = normaliseHanFontSize(fontSizePx)
    target.style.setProperty("--cv-col", `${size * columnFactor}px`)
  } else {
    target.style.removeProperty("--cv-col")
  }

  applyFallbackRunLayout(target, metrics)
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
