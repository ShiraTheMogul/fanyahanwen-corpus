import { t } from "i18n"

const STORAGE_KEY = "corpus.authority.auto_annotations.v1"
const SUPPRESSION_PREFIX = "corpus.authority.suppressed.v1:"
const STYLE_ID = "authority-auto-annotations-style"
const MANUAL_CLASSES = ["ne-title", "ne-person", "ne-place", "ne-office", "ne-ambiguous-character"]

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

function readerPath(reader, attribute) {
  return String(reader.getAttribute(attribute) || "")
}

function sourcePath(reader) {
  return readerPath(reader, "data-corpus-annotations-source-path-value") || readerPath(reader, "data-corpus-annotations-path-value")
}

function suppressionStorageKey(reader) {
  return `${SUPPRESSION_PREFIX}${sourcePath(reader)}`
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

function ensureStyle() {
  if (document.getElementById(STYLE_ID)) return
  const style = document.createElement("style")
  style.id = STYLE_ID
  style.textContent = `
    .ne-auto-authority { cursor: help; text-underline-offset: .14em; }
    .ne-auto-person { text-decoration-line: underline; text-decoration-style: solid; text-decoration-color: var(--ne-person, currentColor); }
    .ne-auto-place { text-decoration-line: underline; text-decoration-style: double; text-decoration-color: var(--ne-place, currentColor); }
    .ne-auto-office { text-decoration-line: underline; text-decoration-style: dotted; text-decoration-color: var(--ne-office, currentColor); }
    .ne-auto-possible { text-decoration-thickness: 1px; opacity: .94; }
    .authority-auto-popover { position: fixed; z-index: 10020; max-width: min(36rem, calc(100vw - 24px)); max-height: min(32rem, calc(100vh - 24px)); overflow: auto; padding: .8rem; border: 1px solid currentColor; border-radius: .45rem; background: var(--body-bg, Canvas); color: var(--body-fg, CanvasText); box-shadow: 0 .35rem 1.25rem rgba(0,0,0,.25); }
    .authority-auto-popover ul { margin: .5rem 0; padding-left: 1.25rem; }
    .authority-auto-popover small { opacity: .78; }
    .authority-auto-actions { display:flex; gap:.5rem; flex-wrap:wrap; margin-top:.65rem; }
    .authority-auto-status { margin-top:.5rem; font-size:.9em; }
    .authority-auto-toggle[data-state="error"], .authority-auto-toggle[data-state="unavailable"] { border-style: dashed; }
  `
  document.head.appendChild(style)
}

function escapeHtml(value) {
  return String(value == null ? "" : value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#039;")
}

function spans(reader) {
  return Array.from(reader.querySelectorAll(".corpus-textflow span.cch[data-corpus-idx]"))
}

function manuallyAnnotated(span) {
  return MANUAL_CLASSES.some((name) => span.classList.contains(name))
}

function removeAutoMarks(reader) {
  spans(reader).forEach((span) => {
    span.classList.remove("ne-auto-authority", "ne-auto-person", "ne-auto-place", "ne-auto-office", "ne-auto-possible")
    span.removeAttribute("data-authority-auto-index")
  })
}

function clearAuto(reader, { forget = false } = {}) {
  removeAutoMarks(reader)
  if (forget) {
    reader._authorityAutoItems = []
    reader._authorityAutoPayload = null
  }
}

function applyItems(reader, items, { remember = true } = {}) {
  removeAutoMarks(reader)
  if (remember) reader._authorityAutoItems = Array(items)
  const current = Array(reader._authorityAutoItems || [])
  const byIndex = new Map(spans(reader).map((span) => [Number(span.getAttribute("data-corpus-idx")), span]))

  current.forEach((item, itemIndex) => {
    const start = Number(item.start)
    const end = Number(item.end)
    if (!Number.isFinite(start) || !Number.isFinite(end) || end <= start) return
    if (suppressedLocally(reader, item)) return

    const itemSpans = []
    for (let index = start; index < end; index += 1) {
      const span = byIndex.get(index)
      if (span) itemSpans.push(span)
    }
    if (!itemSpans.length || itemSpans.some(manuallyAnnotated)) return

    const kind = ["person", "place", "office"].includes(String(item.kind)) ? String(item.kind) : "person"
    itemSpans.forEach((span) => {
      span.classList.add("ne-auto-authority", `ne-auto-${kind}`)
      if (item.confidence !== "high") span.classList.add("ne-auto-possible")
      span.setAttribute("data-authority-auto-index", String(itemIndex))
    })
  })
}

function setButtonState(reader, state, detail = "") {
  const button = reader.querySelector("[data-authority-auto-toggle]")
  if (!button) return

  const hidden = suppressionSet(reader).size
  const count = Array(reader._authorityAutoItems || []).length
  const key = {
    off: "authority_auto.off",
    loading: "authority_auto.loading",
    ready: "authority_auto.ready",
    empty: "authority_auto.empty",
    unavailable: "authority_auto.unavailable",
    error: "authority_auto.error"
  }[state] || "authority_auto.ready"

  const hiddenSuffix = hidden ? t("authority_auto.hidden_suffix", { count: hidden }) : ""
  button.textContent = `${t(key, { count })}${hiddenSuffix}`
  button.dataset.state = state
  button.setAttribute("aria-pressed", reader._authorityAutoEnabled === true ? "true" : "false")
  button.title = detail || t("authority_auto.title")
}

function authorityAvailable(payload) {
  const authority = payload && payload.authority && typeof payload.authority === "object" ? payload.authority : {}
  const cbdbLookupReady = authority.cbdb_lookup_available === true
  return cbdbLookupReady || authority.historical_available === true
}

function authorityUnavailableReason(payload) {
  const authority = payload && payload.authority && typeof payload.authority === "object" ? payload.authority : {}
  if (authority.cbdb_available === true && authority.cbdb_lookup_available !== true && authority.historical_available !== true) {
    return t("authority_auto.cbdb_index_missing")
  }
  return t("authority_auto.indexes_missing")
}

async function loadAuto(reader) {
  const target = readerPath(reader, "data-corpus-annotations-path-value")
  if (!target) {
    setButtonState(reader, "unavailable", t("authority_auto.no_target"))
    return
  }

  const requestId = Number(reader._authorityAutoRequestId || 0) + 1
  reader._authorityAutoRequestId = requestId
  setButtonState(reader, "loading", t("authority_auto.loading_detail"))

  const url = new URL("/corpus_annotations", window.location.origin)
  url.searchParams.set("auto", "1")
  url.searchParams.set("path", target)
  url.searchParams.set("source_path", sourcePath(reader))

  try {
    const response = await fetch(url.toString(), { headers: { "Accept": "application/json" } })
    const data = await response.json().catch(() => null)
    if (reader._authorityAutoRequestId !== requestId || reader._authorityAutoEnabled !== true) return

    if (!response.ok || !data) {
      throw new Error((data && data.error) || `HTTP ${response.status}`)
    }

    reader._authorityAutoPayload = data
    const items = Array(data.items || [])
    applyItems(reader, items)

    if (!authorityAvailable(data)) {
      setButtonState(reader, "unavailable", authorityUnavailableReason(data))
    } else if (items.length === 0) {
      setButtonState(reader, "empty", t(data.cached ? "authority_auto.no_matches_cached" : "authority_auto.no_matches"))
    } else {
      setButtonState(reader, "ready", t(items.length === 1 ? (data.cached ? "authority_auto.match_one_cached" : "authority_auto.match_one") : (data.cached ? "authority_auto.matches_cached" : "authority_auto.matches"), { count: items.length }))
    }
  } catch (error) {
    if (reader._authorityAutoRequestId !== requestId || reader._authorityAutoEnabled !== true) return
    clearAuto(reader, { forget: true })
    setButtonState(reader, "error", t("authority_auto.failed", { message: error.message || error }))
    console.warn("[authority-auto-annotations] load failed", error)
  }
}

function reapplyCached(reader) {
  if (reader._authorityAutoEnabled !== true || !Array.isArray(reader._authorityAutoItems)) return
  applyItems(reader, reader._authorityAutoItems, { remember: false })
}

function closePopover() {
  document.querySelector(".authority-auto-popover")?.remove()
}

function formatYears(start, end) {
  const fmt = (year) => {
    const n = Number(year)
    if (!Number.isFinite(n)) return ""
    return n < 0
      ? t("authority_auto.year_bce", { year: Math.abs(n) })
      : t("authority_auto.year_ce", { year: n })
  }
  if (start == null && end == null) return ""
  if (start == null || end == null || Number(start) === Number(end)) return fmt(start == null ? end : start)
  return `${fmt(start)}–${fmt(end)}`
}

function authorUrl(candidate) {
  if (!candidate || candidate.kind !== "person") return ""
  const source = String(candidate.authority_source || "")
  const id = String(candidate.id || "")
  if (!source || !id) return ""
  return `/authors/${encodeURIComponent(source)}/${encodeURIComponent(id)}`
}

function candidateLine(candidate) {
  const label = candidate.label || candidate.local_label || candidate.romanized || candidate.id || t("authority_auto.authority_record")
  const years = formatYears(candidate.year_start, candidate.year_end)
  const source = candidate.source_label || candidate.authority_source || t("authority_auto.authority")
  const derivation = candidate.explicit === false && candidate.derivation ? ` · ${candidate.derivation}` : ""
  const reference = candidate.source_reference ? `<div><small>${escapeHtml(candidate.source_reference)}</small></div>` : ""
  const href = authorUrl(candidate)
  const shown = href ? `<a href="${escapeHtml(href)}"><strong>${escapeHtml(label)}</strong></a>` : `<strong>${escapeHtml(label)}</strong>`
  return `<li>${shown}${years ? ` · ${escapeHtml(years)}` : ""}<div><small>${escapeHtml(source)}${candidate.id ? ` · ${escapeHtml(candidate.id)}` : ""}${escapeHtml(derivation)}</small></div>${reference}</li>`
}

async function reportIncorrect(reader, item, statusEl) {
  const candidateUrls = Array.from(new Set(
    (item.candidates || [])
      .map((candidate) => String(candidate.source_url || ""))
      .filter((url) => /^https?:\/\//i.test(url))
  ))
  const form = new FormData()
  form.append("title", t("authority_auto.report_title"))
  form.append("summary", t("authority_auto.report_summary", { text: item.text, kind: item.kind }))
  form.append("reasoning", JSON.stringify({
    text: item.text, kind: item.kind, start: item.start, end: item.end,
    confidence: item.confidence, authority_source: item.authority_source,
    candidates: item.candidates || []
  }))
  form.append("source", "authority_auto_annotation")
  form.append("target_ref", `corpus_viewer/${sourcePath(reader)}#authority-auto-${item.start}-${item.end}`)
  form.append("evidence_links", JSON.stringify(candidateUrls))

  statusEl.textContent = t("authority_auto.sending")
  try {
    const response = await fetch("/api/tickets", { method: "POST", headers: { "Accept": "application/json" }, body: form })
    const data = await response.json().catch(() => null)
    if (!response.ok || !data || data.ok !== true) throw new Error((data && data.error) || `HTTP ${response.status}`)
    statusEl.textContent = data.ticket_key ? t("authority_auto.sent_with_key", { id: data.ticket_id || t("authority_auto.ticket_created"), key: data.ticket_key }) : t("authority_auto.sent", { id: data.ticket_id || t("authority_auto.ticket_created") })
  } catch (error) {
    statusEl.textContent = t("authority_auto.send_failed", { message: error.message || error })
  }
}

function showPopover(reader, item, anchor) {
  closePopover()
  const popover = document.createElement("div")
  popover.className = "authority-auto-popover"
  const candidates = Array(item.candidates || [])
  const kindKey = ["person", "place", "office"].includes(String(item.kind)) ? `authority_auto.kind_${item.kind}` : "authority_auto.kind_person"
  popover.innerHTML = `
    <div><strong>${escapeHtml(item.text)}</strong> · ${escapeHtml(t(kindKey))} · ${escapeHtml(item.confidence || t("authority_auto.possible"))}</div>
    <ul>${candidates.slice(0, 8).map(candidateLine).join("")}</ul>
    <div class="authority-auto-actions">
      <button type="button" class="corpus-btn" data-authority-hide>${escapeHtml(t("authority_auto.hide"))}</button>
      <button type="button" class="corpus-btn" data-authority-report>${escapeHtml(t("authority_auto.report"))}</button>
      <button type="button" class="corpus-btn" data-authority-close>${escapeHtml(t("authority_auto.close"))}</button>
    </div>
    <div class="authority-auto-status" aria-live="polite"></div>`
  document.body.appendChild(popover)

  const rect = anchor.getBoundingClientRect()
  const popRect = popover.getBoundingClientRect()
  popover.style.left = `${Math.min(Math.max(8, rect.left), Math.max(8, window.innerWidth - popRect.width - 8))}px`
  const below = rect.bottom + 8
  popover.style.top = `${below + popRect.height <= window.innerHeight - 8 ? below : Math.max(8, rect.top - popRect.height - 8)}px`

  const status = popover.querySelector(".authority-auto-status")
  popover.querySelector("[data-authority-close]")?.addEventListener("click", closePopover)
  popover.querySelector("[data-authority-hide]")?.addEventListener("click", () => {
    suppressionSet(reader).add(itemSuppressionId(item))
    saveSuppressions(reader)
    reapplyCached(reader)
    setButtonState(reader, Array(reader._authorityAutoItems || []).length ? "ready" : "empty")
    closePopover()
  })
  popover.querySelector("[data-authority-report]")?.addEventListener("click", () => reportIncorrect(reader, item, status))
}

function bindClicks(reader) {
  if (reader._authorityAutoClickHandler) return
  reader._authorityAutoClickHandler = (event) => {
    const span = event.target?.closest?.("span.cch[data-authority-auto-index]")
    if (!span || !reader.contains(span)) return
    const item = reader._authorityAutoItems?.[Number(span.getAttribute("data-authority-auto-index"))]
    if (!item) return
    event.preventDefault()
    showPopover(reader, item, span)
  }
  reader.addEventListener("click", reader._authorityAutoClickHandler)
}

function unbindClicks(reader) {
  if (!reader._authorityAutoClickHandler) return
  reader.removeEventListener("click", reader._authorityAutoClickHandler)
  reader._authorityAutoClickHandler = null
}

function bindLifecycle(reader) {
  if (reader._authorityAutoReaderApplied) return
  reader._authorityAutoReaderApplied = () => window.requestAnimationFrame(() => reapplyCached(reader))
  window.addEventListener("corpus-reader-applied", reader._authorityAutoReaderApplied)

  reader._authorityAutoObserver = new MutationObserver((mutations) => {
    if (mutations.some((mutation) => mutation.target instanceof Element && manuallyAnnotated(mutation.target) && mutation.target.classList.contains("ne-auto-authority"))) {
      window.requestAnimationFrame(() => reapplyCached(reader))
    }
  })
  reader._authorityAutoObserver.observe(reader, { subtree: true, attributes: true, attributeFilter: ["class"] })
}

function unbindLifecycle(reader) {
  if (reader._authorityAutoReaderApplied) window.removeEventListener("corpus-reader-applied", reader._authorityAutoReaderApplied)
  reader._authorityAutoReaderApplied = null
  reader._authorityAutoObserver?.disconnect()
  reader._authorityAutoObserver = null
}

function addToggle(reader) {
  const toolbar = reader.querySelector(".corpus-toolbar")
  if (!toolbar || toolbar.querySelector("[data-authority-auto-toggle]")) return

  const button = document.createElement("button")
  button.type = "button"
  button.className = "corpus-btn authority-auto-toggle"
  button.setAttribute("data-authority-auto-toggle", "1")
  toolbar.appendChild(button)

  reader._authorityAutoSuppressions = loadSuppressions(reader)
  reader._authorityAutoEnabled = enabledByDefault()
  setButtonState(reader, reader._authorityAutoEnabled ? "loading" : "off")

  button.addEventListener("click", async (event) => {
    if (event.shiftKey && suppressionSet(reader).size) {
      suppressionSet(reader).clear()
      saveSuppressions(reader)
      reapplyCached(reader)
      setButtonState(reader, Array(reader._authorityAutoItems || []).length ? "ready" : "empty")
      return
    }

    reader._authorityAutoEnabled = !reader._authorityAutoEnabled
    reader._authorityAutoRequestId = Number(reader._authorityAutoRequestId || 0) + 1
    storeEnabled(reader._authorityAutoEnabled)
    closePopover()
    if (!reader._authorityAutoEnabled) {
      clearAuto(reader)
      setButtonState(reader, "off", t("authority_auto.disabled"))
    } else {
      await loadAuto(reader)
    }
  })

  if (reader._authorityAutoEnabled) loadAuto(reader)
}

function boot() {
  ensureStyle()
  document.querySelectorAll(".corpus-reader[data-corpus-annotations-path-value]").forEach((reader) => {
    if (reader.classList.contains("is-translation-view")) return
    bindClicks(reader)
    bindLifecycle(reader)
    addToggle(reader)
  })
}

function cleanupBeforeCache() {
  closePopover()
  document.querySelectorAll(".corpus-reader[data-corpus-annotations-path-value]").forEach((reader) => {
    reader._authorityAutoRequestId = Number(reader._authorityAutoRequestId || 0) + 1
    unbindClicks(reader)
    unbindLifecycle(reader)
    clearAuto(reader, { forget: true })
    reader._authorityAutoEnabled = false
    delete reader._authorityAutoSuppressions
    reader.querySelector("[data-authority-auto-toggle]")?.remove()
  })
}

document.addEventListener("turbo:load", boot)
document.addEventListener("turbo:before-cache", cleanupBeforeCache)
if (document.readyState !== "loading") boot()
