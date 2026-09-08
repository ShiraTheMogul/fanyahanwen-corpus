const DEFAULT_FONT_SIZE_PX = 20
const MIN_FONT_SIZE_PX = 12
const MAX_FONT_SIZE_PX = 48
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
  const column = size * 1.8
  target.style.setProperty("--cv-font-size", `${size}px`)
  target.style.setProperty("--han-main-font-size", `${size}px`)
  target.style.setProperty("--han-column-advance", `${column}px`)
  target.style.setProperty("--han-jiagzhu-font-size", `${size * 0.5}px`)
  return size
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
