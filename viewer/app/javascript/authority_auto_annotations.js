const STORAGE_KEY = "corpus.authority.auto_annotations.v1"
const SUPPRESSION_PREFIX = "corpus.authority.suppressed.v1:"
const STYLE_ID = "authority-auto-annotations-style"

function enabledByDefault() {
  try {
    const value = window.localStorage.getItem(STORAGE_KEY)
    return value === null ? true : value === "1"
  } catch (_) {
    return true
  }
}

function storeEnabled(value) {
  try { window.localStorage.setItem(STORAGE_KEY, value ? "1" : "0") } catch (_) {}
}

function suppressionStorageKey(reader) {
  const sourcePath = readerPath(reader, "data-corpus-annotations-source-path-value") || readerPath(reader, "data-corpus-annotations-path-value")
  return `${SUPPRESSION_PREFIX}${sourcePath}`
}

function itemSuppressionId(item) {
  return [Number(item.start), Number(item.end), String(item.kind || ""), String(item.text || "")].join(":")
}

function loadSuppressions(reader) {
  try {
    const raw = window.localStorage.getItem(suppressionStorageKey(reader))
    const values = raw ? JSON.parse(raw) : []
    return new Set(Array.isArray(values) ? values.map(String) : [])
  } catch (_) {
    return new Set()
  }
}

function suppressionSet(reader) {
  if (!(reader._authorityAutoSuppressions instanceof Set)) reader._authorityAutoSuppressions = loadSuppressions(reader)
  return reader._authorityAutoSuppressions
}

function saveSuppressions(reader) {
  try {
    const values = Array.from(suppressionSet(reader)).sort()
    if (values.length) window.localStorage.setItem(suppressionStorageKey(reader), JSON.stringify(values))
    else window.localStorage.removeItem(suppressionStorageKey(reader))
  } catch (_) {}
}

function suppressedLocally(reader, item) {
  return suppressionSet(reader).has(itemSuppressionId(item))
}

function suppressLocally(reader, item) {
  suppressionSet(reader).add(itemSuppressionId(item))
  saveSuppressions(reader)
  reapplyCached(reader)
  syncToggle(reader)
}

function clearLocalSuppressions(reader) {
  suppressionSet(reader).clear()
  saveSuppressions(reader)
  reapplyCached(reader)
  syncToggle(reader)
}

function escapeHtml(value) {
  return String(value == null ? "" : value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#039;")
}

function ensureStyle() {
  if (document.getElementById(STYLE_ID)) return
  const style = document.createElement("style")
  style.id = STYLE_ID
  style.textContent = `
    .ne-auto-authority { cursor: help; text-underline-offset: 0.14em; }
    .ne-auto-person { text-decoration-line: underline; text-decoration-style: solid; text-decoration-color: var(--ne-person, currentColor); }
    .ne-auto-place { text-decoration-line: underline; text-decoration-style: double; text-decoration-color: var(--ne-place, currentColor); }
    .ne-auto-office { text-decoration-line: underline; text-decoration-style: dotted; text-decoration-color: var(--ne-office, currentColor); }
    .ne-auto-possible { text-decoration-thickness: 1px; opacity: 0.94; }
    .authority-auto-popover { position: fixed; z-index: 10020; max-width: min(34rem, calc(100vw - 24px)); max-height: min(30rem, calc(100vh - 24px)); overflow: auto; padding: .8rem; border: 1px solid currentColor; border-radius: .4rem; background: var(--body-bg, Canvas); color: var(--body-fg, CanvasText); box-shadow: 0 .35rem 1.25rem rgba(0,0,0,.25); }
    .authority-auto-popover ul { margin: .5rem 0; padding-left: 1.25rem; }
    .authority-auto-popover small { opacity: .78; }
    .authority-auto-actions { display: flex; gap: .5rem; flex-wrap: wrap; margin-top: .65rem; }
    .authority-auto-status { margin-top: .5rem; font-size: .9em; }
  `
  document.head.appendChild(style)
}

function readerPath(reader, name) {
  const raw = reader.getAttribute(name)
  return raw == null ? "" : String(raw)
}

function spans(reader) {
  return Array.from(reader.querySelectorAll(".corpus-textflow span.cch[data-corpus-idx]"))
}

const MANUAL_CLASSES = ["ne-title", "ne-person", "ne-place", "ne-office", "ne-ambiguous-character"]

function removeAutoMarks(reader) {
  spans(reader).forEach((span) => {
    span.classList.remove("ne-auto-authority", "ne-auto-person", "ne-auto-place", "ne-auto-office", "ne-auto-possible")
    span.removeAttribute("data-authority-auto-index")
  })
}

function clearAuto(reader) {
  removeAutoMarks(reader)
  reader._authorityAutoItems = []
}

function manuallyAnnotated(span) {
  return MANUAL_CLASSES.some((className) => span.classList.contains(className))
}

function closePopover() {
  const old = document.querySelector(".authority-auto-popover")
  if (old) old.remove()
}

function formatYears(start, end) {
  const fmt = (year) => {
    const n = Number(year)
    if (!Number.isFinite(n)) return ""
    return n < 0 ? `${Math.abs(n)} BCE` : `${n} CE`
  }
  if (start == null && end == null) return ""
  if (start == null || end == null || Number(start) === Number(end)) return fmt(start == null ? end : start)
  return `${fmt(start)}–${fmt(end)}`
}

function candidateLine(candidate) {
  const label = candidate.label || candidate.local_label || candidate.romanized || candidate.id || "Authority record"
  const years = formatYears(candidate.year_start, candidate.year_end)
  const source = candidate.source_label || candidate.authority_source || "Authority"
  const derivation = candidate.explicit === false && candidate.derivation ? ` · ${candidate.derivation}` : ""
  const reference = candidate.source_reference ? `<div><small>${escapeHtml(candidate.source_reference)}</small></div>` : ""
  return `<li><strong>${escapeHtml(label)}</strong>${years ? ` · ${escapeHtml(years)}` : ""}<div><small>${escapeHtml(source)}${candidate.id ? ` · ${escapeHtml(candidate.id)}` : ""}${escapeHtml(derivation)}</small></div>${reference}</li>`
}

async function reportIncorrect(reader, item, statusEl) {
  const sourcePath = readerPath(reader, "data-corpus-annotations-source-path-value") || readerPath(reader, "data-corpus-annotations-path-value")
  const candidateUrls = Array.from(new Set((item.candidates || []).map((candidate) => candidate.source_url).filter(Boolean)))
  const form = new FormData()
  form.append("title", "Incorrect automatic authority annotation")
  form.append("summary", `Automatic authority annotation marked “${item.text}” as ${item.kind}; this match is incorrect.`)
  form.append("reasoning", JSON.stringify({
    text: item.text,
    kind: item.kind,
    start: item.start,
    end: item.end,
    confidence: item.confidence,
    authority_source: item.authority_source,
    candidates: item.candidates || []
  }))
  form.append("source", "authority_auto_annotation")
  form.append("target_ref", `corpus_viewer/${sourcePath}#authority-auto-${item.start}-${item.end}`)
  form.append("evidence_links", JSON.stringify(candidateUrls))

  statusEl.textContent = "Sending report…"
  try {
    const response = await fetch("/api/tickets", { method: "POST", headers: { "Accept": "application/json" }, body: form })
    const data = await response.json().catch(() => null)
    if (!response.ok || !data || data.ok !== true) throw new Error((data && data.error) || `HTTP ${response.status}`)
    const key = data.ticket_key ? ` Key: ${data.ticket_key}` : ""
    statusEl.textContent = `Report sent: ${data.ticket_id || "ticket created"}.${key}`
  } catch (error) {
    statusEl.textContent = `Could not send report: ${error.message || error}`
  }
}

function showPopover(reader, item, anchor) {
  closePopover()
  const popover = document.createElement("div")
  popover.className = "authority-auto-popover"
  const candidates = Array(item.candidates || [])
  popover.innerHTML = `
    <div><strong>${escapeHtml(item.text)}</strong> · ${escapeHtml(item.kind)} · ${escapeHtml(item.confidence || "possible")}</div>
    <ul>${candidates.slice(0, 8).map(candidateLine).join("")}</ul>
    <div class="authority-auto-actions">
      <button type="button" class="corpus-btn" data-authority-hide>Hide this match locally</button>
      <button type="button" class="corpus-btn" data-authority-report>Report incorrect</button>
      <button type="button" class="corpus-btn" data-authority-close>Close</button>
    </div>
    <div class="authority-auto-status" aria-live="polite"></div>
  `
  document.body.appendChild(popover)

  const rect = anchor.getBoundingClientRect()
  const popRect = popover.getBoundingClientRect()
  const left = Math.min(Math.max(8, rect.left), Math.max(8, window.innerWidth - popRect.width - 8))
  const topBelow = rect.bottom + 8
  const top = topBelow + popRect.height <= window.innerHeight - 8
    ? topBelow
    : Math.max(8, rect.top - popRect.height - 8)
  popover.style.left = `${left}px`
  popover.style.top = `${top}px`

  const status = popover.querySelector(".authority-auto-status")
  popover.querySelector("[data-authority-close]")?.addEventListener("click", closePopover)
  popover.querySelector("[data-authority-hide]")?.addEventListener("click", () => {
    suppressLocally(reader, item)
    closePopover()
  })
  popover.querySelector("[data-authority-report]")?.addEventListener("click", () => reportIncorrect(reader, item, status))
}

function applyItems(reader, items, { remember = true } = {}) {
  removeAutoMarks(reader)
  if (remember) reader._authorityAutoItems = Array(items)
  const activeItems = Array(reader._authorityAutoItems || [])
  const byIndex = new Map(spans(reader).map((span) => [Number(span.getAttribute("data-corpus-idx")), span]))

  activeItems.forEach((item, itemIndex) => {
    const start = Number(item.start)
    const end = Number(item.end)
    if (!Number.isFinite(start) || !Number.isFinite(end) || end <= start) return
    if (suppressedLocally(reader, item)) return

    // Manual annotations are authoritative. Suppress the complete automatic
    // entity when any graph in its range already belongs to a manual mark.
    const itemSpans = []
    for (let index = start; index < end; index += 1) {
      const span = byIndex.get(index)
      if (span) itemSpans.push(span)
    }
    if (!itemSpans.length || itemSpans.some(manuallyAnnotated)) return

    itemSpans.forEach((span) => {
      span.classList.add("ne-auto-authority", `ne-auto-${item.kind}`)
      if (item.confidence !== "high") span.classList.add("ne-auto-possible")
      span.setAttribute("data-authority-auto-index", String(itemIndex))
    })
  })
}

function reapplyCached(reader) {
  if (reader._authorityAutoEnabled !== true) return
  if (!Array.isArray(reader._authorityAutoItems)) return
  applyItems(reader, reader._authorityAutoItems, { remember: false })
}

async function loadAuto(reader) {
  const path = readerPath(reader, "data-corpus-annotations-path-value")
  if (!path) return
  const sourcePath = readerPath(reader, "data-corpus-annotations-source-path-value") || path
  const url = new URL("/corpus_annotations", window.location.origin)
  url.searchParams.set("auto", "1")
  url.searchParams.set("path", path)
  url.searchParams.set("source_path", sourcePath)

  const requestId = Number(reader._authorityAutoRequestId || 0) + 1
  reader._authorityAutoRequestId = requestId
  const response = await fetch(url.toString(), { headers: { "Accept": "application/json" } })
  if (!response.ok) throw new Error(`HTTP ${response.status}`)
  const data = await response.json()
  if (reader._authorityAutoRequestId !== requestId || reader._authorityAutoEnabled !== true) return

  reader._authorityAutoPayload = data
  applyItems(reader, Array(data.items || []))
}

function bindClicks(reader) {
  if (reader.dataset.authorityAutoClickBound === "1") return
  reader.dataset.authorityAutoClickBound = "1"
  reader._authorityAutoClickHandler = (event) => {
    const span = event.target && event.target.closest ? event.target.closest("span.cch[data-authority-auto-index]") : null
    if (!span || !reader.contains(span)) return
    const index = Number(span.getAttribute("data-authority-auto-index"))
    const item = reader._authorityAutoItems && reader._authorityAutoItems[index]
    if (!item) return
    event.preventDefault()
    showPopover(reader, item, span)
  }
  reader.addEventListener("click", reader._authorityAutoClickHandler)
}

function unbindClicks(reader) {
  if (reader._authorityAutoClickHandler) {
    reader.removeEventListener("click", reader._authorityAutoClickHandler)
    reader._authorityAutoClickHandler = null
  }
  delete reader.dataset.authorityAutoClickBound
}

function bindReaderLifecycle(reader) {
  if (reader.dataset.authorityAutoLifecycleBound === "1") return
  reader.dataset.authorityAutoLifecycleBound = "1"

  // corpus-reader can rebuild the character spans when orientation/ruby/view
  // settings change. Reapply cached authority marks after the other reader
  // controllers have had a chance to restore their manual annotations.
  reader._authorityAutoReaderApplied = () => {
    window.requestAnimationFrame(() => reapplyCached(reader))
  }
  window.addEventListener("corpus-reader-applied", reader._authorityAutoReaderApplied)

  // Manual annotation loading is asynchronous and does not emit a dedicated
  // completion event. Observe only class mutations and remove an automatic mark
  // as soon as the same character receives a manual entity class.
  reader._authorityAutoObserver = new MutationObserver((mutations) => {
    let needsReapply = false
    for (const mutation of mutations) {
      const target = mutation.target
      if (!(target instanceof Element) || !target.matches("span.cch[data-corpus-idx]")) continue
      if (manuallyAnnotated(target) && target.classList.contains("ne-auto-authority")) {
        needsReapply = true
        break
      }
    }
    if (needsReapply) window.requestAnimationFrame(() => reapplyCached(reader))
  })
  reader._authorityAutoObserver.observe(reader, { subtree: true, attributes: true, attributeFilter: ["class"] })
}

function unbindReaderLifecycle(reader) {
  if (reader._authorityAutoReaderApplied) {
    window.removeEventListener("corpus-reader-applied", reader._authorityAutoReaderApplied)
    reader._authorityAutoReaderApplied = null
  }
  if (reader._authorityAutoObserver) {
    reader._authorityAutoObserver.disconnect()
    reader._authorityAutoObserver = null
  }
  delete reader.dataset.authorityAutoLifecycleBound
}

function syncToggle(reader) {
  const button = reader.querySelector("[data-authority-auto-toggle]")
  if (!button) return
  const enabled = reader._authorityAutoEnabled === true
  const hidden = suppressionSet(reader).size
  button.textContent = enabled ? `Auto names: on${hidden ? ` (${hidden} hidden)` : ""}` : `Auto names: off${hidden ? ` (${hidden} hidden)` : ""}`
  button.setAttribute("aria-pressed", enabled ? "true" : "false")
  button.title = hidden
    ? `Show or hide automatic historical annotations. Shift-click to restore ${hidden} locally hidden match${hidden === 1 ? "" : "es"}.`
    : "Show or hide automatic historical person, place and office annotations"
}

function addToggle(reader) {
  const toolbar = reader.querySelector(".corpus-toolbar")
  if (!toolbar || toolbar.querySelector("[data-authority-auto-toggle]")) return
  const button = document.createElement("button")
  button.type = "button"
  button.className = "corpus-btn"
  button.setAttribute("data-authority-auto-toggle", "1")
  button.title = "Show or hide automatic historical person, place and office annotations"

  reader._authorityAutoSuppressions = loadSuppressions(reader)
  let enabled = enabledByDefault()
  reader._authorityAutoEnabled = enabled
  toolbar.appendChild(button)
  syncToggle(reader)

  button.addEventListener("click", async (event) => {
    if (event.shiftKey && suppressionSet(reader).size > 0) {
      event.preventDefault()
      clearLocalSuppressions(reader)
      return
    }

    enabled = !enabled
    reader._authorityAutoEnabled = enabled
    reader._authorityAutoRequestId = Number(reader._authorityAutoRequestId || 0) + 1
    storeEnabled(enabled)
    syncToggle(reader)
    closePopover()
    if (!enabled) {
      clearAuto(reader)
      return
    }
    try { await loadAuto(reader) } catch (error) { console.warn("[authority-auto-annotations] load failed", error) }
  })

  if (enabled) {
    loadAuto(reader).catch((error) => console.warn("[authority-auto-annotations] load failed", error))
  }
}

function boot() {
  ensureStyle()
  document.querySelectorAll(".corpus-reader[data-corpus-annotations-path-value]").forEach((reader) => {
    if (reader.classList.contains("is-translation-view")) return
    bindClicks(reader)
    bindReaderLifecycle(reader)
    addToggle(reader)
  })
}

function cleanupBeforeCache() {
  closePopover()
  document.querySelectorAll(".corpus-reader[data-corpus-annotations-path-value]").forEach((reader) => {
    unbindReaderLifecycle(reader)
    clearAuto(reader)
    reader._authorityAutoEnabled = false
    reader._authorityAutoRequestId = Number(reader._authorityAutoRequestId || 0) + 1
    delete reader.dataset.authorityAutoClickBound
    delete reader._authorityAutoSuppressions
    reader.querySelector("[data-authority-auto-toggle]")?.remove()
  })
}

document.addEventListener("turbo:load", boot)
document.addEventListener("turbo:before-cache", cleanupBeforeCache)
if (document.readyState !== "loading") boot()
