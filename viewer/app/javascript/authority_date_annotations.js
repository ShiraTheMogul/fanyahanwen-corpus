const STYLE_ID = "authority-date-annotations-style"
const MANUAL_CLASSES = ["ne-title", "ne-person", "ne-place", "ne-office", "ne-ambiguous-character"]

function ensureStyle() {
  if (document.getElementById(STYLE_ID)) return
  const style = document.createElement("style")
  style.id = STYLE_ID
  style.textContent = `
    .ne-auto-date {
      cursor: help;
      text-decoration-line: underline;
      text-decoration-style: dashed;
      text-decoration-thickness: 1.5px;
      text-underline-offset: .18em;
      text-decoration-skip-ink: none;
    }
    .corpus-textflow.is-vertical .ne-auto-date { text-underline-position: under; }
  `
  document.head.appendChild(style)
}

function readerSpans(reader) {
  return Array.from(reader.querySelectorAll(".corpus-textflow span.cch[data-corpus-idx]"))
}

function dateItems(reader) {
  const values = reader._authorityAutoPayload?.context?.regnal_dates
  return Array.isArray(values) ? values : []
}

function formatYear(value) {
  const year = Number(value)
  if (!Number.isFinite(year)) return ""
  return year < 0 ? `${Math.abs(year)} BCE` : `${year} CE`
}

function restoreTitle(span) {
  if (span.hasAttribute("data-authority-date-previous-title")) {
    span.setAttribute("title", span.getAttribute("data-authority-date-previous-title") || "")
    span.removeAttribute("data-authority-date-previous-title")
  } else if (span.hasAttribute("data-authority-date-title")) {
    span.removeAttribute("title")
  }
  span.removeAttribute("data-authority-date-title")
}

function clearDates(reader) {
  readerSpans(reader).forEach((span) => {
    if (!span.hasAttribute("data-authority-date-index")) return
    span.classList.remove("ne-auto-date")
    span.removeAttribute("data-authority-date-index")
    restoreTitle(span)
  })
}

function manuallyAnnotated(span) {
  return MANUAL_CLASSES.some((name) => span.classList.contains(name))
}

function applyDates(reader) {
  clearDates(reader)
  const items = dateItems(reader)
  if (!items.length) return

  const byIndex = new Map(readerSpans(reader).map((span) => [Number(span.getAttribute("data-corpus-idx")), span]))
  items.forEach((item, itemIndex) => {
    const start = Number(item.start)
    const end = Number(item.end)
    if (!Number.isFinite(start) || !Number.isFinite(end) || end <= start) return

    const selected = []
    for (let index = start; index < end; index += 1) {
      const span = byIndex.get(index)
      if (!span) return
      selected.push(span)
    }
    if (selected.some(manuallyAnnotated)) return

    const converted = formatYear(item.absolute_year)
    if (!converted) return
    const label = `${item.text || selected.map((span) => span.textContent || "").join("")} → ${converted}`

    selected.forEach((span) => {
      if (span.hasAttribute("title") && !span.hasAttribute("data-authority-date-previous-title")) {
        span.setAttribute("data-authority-date-previous-title", span.getAttribute("title") || "")
      }
      span.classList.add("ne-auto-date")
      span.setAttribute("data-authority-date-index", String(itemIndex))
      span.setAttribute("data-authority-date-title", label)
      span.setAttribute("title", label)
    })
  })
}

function sync(reader) {
  const toggle = reader.querySelector("[data-authority-auto-toggle]")
  const state = toggle?.dataset?.state || ""
  if (["off", "loading", "error", "unavailable"].includes(state)) {
    clearDates(reader)
    return
  }
  applyDates(reader)
}

function bind(reader) {
  if (reader._authorityDateObserver) return

  let queued = false
  const schedule = () => {
    if (queued) return
    queued = true
    window.requestAnimationFrame(() => {
      queued = false
      sync(reader)
    })
  }

  reader._authorityDateObserver = new MutationObserver((mutations) => {
    if (mutations.some((mutation) => mutation.type === "childList" || mutation.attributeName === "data-state")) schedule()
  })
  reader._authorityDateObserver.observe(reader, {
    subtree: true,
    childList: true,
    attributes: true,
    attributeFilter: ["data-state"]
  })
  reader._authorityDateApplied = schedule
  window.addEventListener("corpus-reader-applied", schedule)
  schedule()
}

function unbind(reader) {
  reader._authorityDateObserver?.disconnect()
  reader._authorityDateObserver = null
  if (reader._authorityDateApplied) window.removeEventListener("corpus-reader-applied", reader._authorityDateApplied)
  reader._authorityDateApplied = null
  clearDates(reader)
}

function boot() {
  ensureStyle()
  document.querySelectorAll(".corpus-reader[data-corpus-annotations-path-value]").forEach((reader) => {
    if (!reader.classList.contains("is-translation-view")) bind(reader)
  })
}

function cleanup() {
  document.querySelectorAll(".corpus-reader[data-corpus-annotations-path-value]").forEach(unbind)
}

document.addEventListener("turbo:load", boot)
document.addEventListener("turbo:before-cache", cleanup)
if (document.readyState !== "loading") boot()
