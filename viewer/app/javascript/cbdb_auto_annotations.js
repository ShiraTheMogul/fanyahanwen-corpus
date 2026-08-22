import { t } from "i18n"
import { storeTicketOnDevice } from "controllers/ticket_submission_helpers"

const ENABLED_KEY = "cbdb.auto.annotations.enabled.v1"
const SUPPRESSIONS_KEY = "cbdb.auto.annotations.suppressions.v1"
const AUTO_CLASSES = ["ne-person", "ne-place", "ne-office"]

const FALLBACK_TEXT = {
  "corpus_annotations.toggles.auto_on": "Auto annotations: On",
  "corpus_annotations.toggles.auto_off": "Auto annotations: Off",
  "corpus_annotations.auto.toggle_hint": "Show or hide automatic authority-based person, place, and office annotations.",
  "corpus_annotations.auto.click_hint": "Automatic authority annotation — click for details or to report a mismatch.",
  "corpus_annotations.auto.heading": "Automatic annotation",
  "corpus_annotations.auto.confidence": "Confidence: %{value}",
  "corpus_annotations.auto.candidates": "Possible authority records",
  "corpus_annotations.auto.source": "Authority sources",
  "corpus_annotations.auto.report": "Report incorrect match",
  "corpus_annotations.auto.reporting": "Sending…",
  "corpus_annotations.auto.reported": "Reported. This match is hidden on this device.",
  "corpus_annotations.auto.error": "Could not send ticket: %{message}",
  "corpus_annotations.auto.high": "high",
  "corpus_annotations.auto.possible": "possible",
  "corpus_annotations.actions.close": "Close",
  "corpus_annotations.kinds.person": "Person",
  "corpus_annotations.kinds.place": "Place",
  "corpus_annotations.kinds.office": "Office"
}

function tr(key, variables = {}) {
  const translated = t(key, variables)
  if (translated !== key) return translated
  const template = FALLBACK_TEXT[key] || key
  return template.replace(/%\{([^}]+)\}/g, (match, name) =>
    Object.prototype.hasOwnProperty.call(variables, name) ? String(variables[name]) : match
  )
}

function readBool(key, fallback) {
  try {
    const raw = window.localStorage.getItem(key)
    return raw === null ? fallback : raw === "1"
  } catch (_) {
    return fallback
  }
}

function writeBool(key, value) {
  try { window.localStorage.setItem(key, value ? "1" : "0") } catch (_) {}
}

function loadSuppressions() {
  try {
    const raw = window.localStorage.getItem(SUPPRESSIONS_KEY)
    const parsed = raw ? JSON.parse(raw) : []
    return new Set(Array.isArray(parsed) ? parsed : [])
  } catch (_) {
    return new Set()
  }
}

function saveSuppressions(set) {
  try {
    const values = Array.from(set)
    // This is a device preference, not corpus data. Keep it bounded.
    window.localStorage.setItem(SUPPRESSIONS_KEY, JSON.stringify(values.slice(-5000)))
  } catch (_) {}
}

function typeClass(kind) {
  if (kind === "person") return "ne-person"
  if (kind === "place") return "ne-place"
  if (kind === "office") return "ne-office"
  return null
}

function autoSignature(sourcePath, item) {
  const candidateIds = Array(item.candidates || []).map((candidate) => candidate.id).join(",")
  return [sourcePath, item.start, item.end, item.kind, item.text, candidateIds].join("|")
}

function spanIndex(span) {
  const value = Number(span.getAttribute("data-corpus-idx"))
  return Number.isFinite(value) ? value : null
}

class CbdbAutoAnnotations {
  constructor(reader) {
    this.reader = reader
    this.textflow = reader.querySelector(".corpus-textflow")
    this.toolbar = reader.querySelector(".corpus-toolbar")
    this.path = reader.dataset.corpusAnnotationsPathValue || ""
    this.sourcePath = reader.dataset.corpusAnnotationsSourcePathValue || this.path
    this.autoPath = this.sourcePath && !this.sourcePath.toLowerCase().endsWith(".txt") ? this.sourcePath : this.path
    this.enabled = readBool(ENABLED_KEY, true)
    this.suppressions = loadSuppressions()
    this.items = []
    this.manualItems = []
    this.authority = {}
    this.context = {}
    this.loaded = false
    this.loading = false
    this.reapplyTimer = null
    this.popover = null
  }

  connect() {
    if (!this.textflow || !this.toolbar || !this.path) return
    if (this.reader.classList.contains("is-translation-view")) return

    this.reader.dataset.cbdbAutoAnnotationsReady = "1"
    this.installToggle()
    this.onDocumentClick = this.handleDocumentClick.bind(this)
    document.addEventListener("click", this.onDocumentClick)

    this.onReaderApplied = () => this.scheduleApply()
    window.addEventListener("corpus-reader-applied", this.onReaderApplied)
    window.addEventListener("corpus-view-options", this.onReaderApplied)

    // Manual annotation mode owns the reader while somebody is actively
    // correcting/adding marks. Hide automatic marks during that edit session;
    // when it closes, reapply them around the manual ranges already in the DOM.
    this.annotateModeObserver = new MutationObserver(() => {
      if (this.manualEditMode()) {
        this.clearAutoMarks()
      } else if (this.enabled) {
        this.scheduleApply()
      }
    })
    this.annotateModeObserver.observe(document.documentElement, { attributes: true, attributeFilter: ["class"] })

    if (this.enabled) this.ensureLoaded()
  }

  disconnect() {
    document.removeEventListener("click", this.onDocumentClick)
    window.removeEventListener("corpus-reader-applied", this.onReaderApplied)
    window.removeEventListener("corpus-view-options", this.onReaderApplied)
    if (this.annotateModeObserver) this.annotateModeObserver.disconnect()
    window.clearTimeout(this.reapplyTimer)
    this.closePopover()
    if (this.toggleButton && this.toggleButton.isConnected) this.toggleButton.remove()
    delete this.reader.dataset.cbdbAutoAnnotationsReady
  }

  installToggle() {
    const button = document.createElement("button")
    button.type = "button"
    button.className = "corpus-btn cbdb-auto-toggle"
    button.addEventListener("click", () => this.toggle())
    this.toggleButton = button

    const spacer = this.toolbar.querySelector(".corpus-toolbar-spacer")
    if (spacer) this.toolbar.insertBefore(button, spacer)
    else this.toolbar.appendChild(button)
    this.syncToggle()
  }

  syncToggle() {
    if (!this.toggleButton) return
    this.toggleButton.textContent = this.enabled
      ? tr("corpus_annotations.toggles.auto_on")
      : tr("corpus_annotations.toggles.auto_off")
    this.toggleButton.setAttribute("aria-pressed", this.enabled ? "true" : "false")
    this.toggleButton.title = tr("corpus_annotations.auto.toggle_hint")
  }

  toggle() {
    this.enabled = !this.enabled
    writeBool(ENABLED_KEY, this.enabled)
    this.syncToggle()

    if (this.enabled) this.ensureLoaded()
    else {
      this.clearAutoMarks()
      this.reapplyManualAnnotations()
    }
  }

  async ensureLoaded() {
    if (this.loaded) {
      this.scheduleApply()
      return
    }
    if (this.loading) return

    this.loading = true
    try {
      const url = new URL("/corpus_annotations", window.location.origin)
      url.searchParams.set("path", this.path)
      url.searchParams.set("source_path", this.sourcePath)
      url.searchParams.set("auto_path", this.autoPath)
      url.searchParams.set("auto", "1")

      const response = await fetch(url.toString(), { headers: { "Accept": "application/json" } })
      if (!response.ok) return
      const data = await response.json()
      this.items = Array.isArray(data.auto_items) ? data.auto_items : []
      this.manualItems = Array.isArray(data.items) ? data.items : []
      this.authority = data.auto_authority || {}
      this.context = data.auto_context || {}
      this.loaded = true
      this.scheduleApply()
    } catch (error) {
      console.warn("[authority-auto-annotations] load failed", error)
    } finally {
      this.loading = false
    }
  }

  scheduleApply() {
    window.clearTimeout(this.reapplyTimer)
    this.reapplyTimer = window.setTimeout(() => this.apply(), 0)
  }

  apply() {
    if (!this.enabled || !this.loaded || !this.textflow) return
    if (this.manualEditMode()) {
      this.clearAutoMarks()
      return
    }

    this.clearAutoMarks({ removeTypeClass: true })
    const spans = Array.from(this.textflow.querySelectorAll("span.cch[data-corpus-idx]"))
    if (!spans.length) return

    const spansByIndex = new Map()
    for (const span of spans) {
      const index = spanIndex(span)
      if (index !== null) spansByIndex.set(index, span)
    }

    for (const item of this.items) {
      const cls = typeClass(item.kind)
      if (!cls) continue
      const signature = autoSignature(this.sourcePath, item)
      if (this.suppressions.has(signature)) continue

      const start = Number(item.start)
      const end = Number(item.end)
      if (!Number.isFinite(start) || !Number.isFinite(end) || end <= start) continue

      if (this.overlapsManual(start, end)) continue

      const rangeSpans = []
      let manualConflict = false
      for (let index = start; index < end; index += 1) {
        const span = spansByIndex.get(index)
        if (!span) continue
        // Manual annotations are authoritative. If this range already carries a
        // named-entity class without our marker, do not draw an automatic mark.
        const hasNamedEntity = AUTO_CLASSES.some((name) => span.classList.contains(name))
        if (hasNamedEntity && !span.hasAttribute("data-cbdb-auto-signature")) {
          manualConflict = true
          break
        }
        rangeSpans.push(span)
      }
      if (manualConflict || rangeSpans.length === 0) continue

      rangeSpans.forEach((span) => {
        span.classList.add(cls, "cbdb-auto-annotation")
        if (item.confidence === "possible") {
          span.classList.add("cbdb-auto-possible")
          if (!span.hasAttribute("data-cbdb-auto-old-decoration-thickness")) {
            span.setAttribute("data-cbdb-auto-old-decoration-thickness", span.style.textDecorationThickness || "")
          }
          // Preserve the traditional entity line style (solid/double/wavy), but
          // make an uncertain automatic match visibly lighter than a confident
          // or manually curated one.
          span.style.textDecorationThickness = "1px"
        }
        span.setAttribute("data-cbdb-auto-signature", signature)
        span.setAttribute("data-cbdb-auto-kind", item.kind || "")
        span.setAttribute("data-cbdb-auto-start", String(start))
        span.setAttribute("data-cbdb-auto-end", String(end))
        if (!span.hasAttribute("data-cbdb-auto-old-cursor")) {
          span.setAttribute("data-cbdb-auto-old-cursor", span.style.cursor || "")
        }
        span.style.cursor = "pointer"
        span.setAttribute("data-cbdb-auto-title", span.getAttribute("title") || "")
        span.setAttribute("title", tr("corpus_annotations.auto.click_hint"))
      })
    }
  }

  clearAutoMarks(options = {}) {
    if (!this.textflow) return
    const removeTypeClass = options.removeTypeClass !== false
    const marked = this.textflow.querySelectorAll("span.cch[data-cbdb-auto-signature]")
    marked.forEach((span) => {
      const autoKind = span.getAttribute("data-cbdb-auto-kind") || ""
      const autoClass = typeClass(autoKind)
      const index = spanIndex(span)
      const manualKinds = index === null ? [] : this.manualKindsAt(index)
      if (removeTypeClass && autoClass && !manualKinds.includes(autoKind)) span.classList.remove(autoClass)
      span.classList.remove("cbdb-auto-annotation", "cbdb-auto-possible")
      const oldThickness = span.getAttribute("data-cbdb-auto-old-decoration-thickness")
      span.style.textDecorationThickness = oldThickness || ""
      span.removeAttribute("data-cbdb-auto-old-decoration-thickness")
      span.removeAttribute("data-cbdb-auto-signature")
      span.removeAttribute("data-cbdb-auto-kind")
      span.removeAttribute("data-cbdb-auto-start")
      span.removeAttribute("data-cbdb-auto-end")
      const oldCursor = span.getAttribute("data-cbdb-auto-old-cursor")
      span.style.cursor = oldCursor || ""
      span.removeAttribute("data-cbdb-auto-old-cursor")
      const oldTitle = span.getAttribute("data-cbdb-auto-title")
      if (oldTitle) span.setAttribute("title", oldTitle)
      else span.removeAttribute("title")
      span.removeAttribute("data-cbdb-auto-title")
    })
  }


  manualEditMode() {
    return document.documentElement.classList.contains("cv-annotate-mode")
  }

  overlapsManual(start, end) {
    return this.manualItems.some((item) => {
      const manualStart = Number(item && item.start)
      const manualEnd = Number(item && item.end)
      return Number.isFinite(manualStart) && Number.isFinite(manualEnd) && manualStart < end && start < manualEnd
    })
  }

  manualKindsAt(index) {
    return this.manualItems.filter((item) => {
      const start = Number(item && item.start)
      const end = Number(item && item.end)
      return Number.isFinite(start) && Number.isFinite(end) && start <= index && index < end
    }).map((item) => String(item.kind || ""))
  }

  reapplyManualAnnotations() {
    // The existing annotation controller owns manual ranges. It listens to this
    // event and reconstructs its classes after auto marks are removed.
    window.setTimeout(() => {
      window.dispatchEvent(new CustomEvent("corpus-reader-applied"))
    }, 0)
  }

  handleDocumentClick(event) {
    const target = event.target && event.target.closest
      ? event.target.closest(".cbdb-auto-annotation")
      : null

    if (!target || !this.reader.contains(target)) {
      if (this.popover && !this.popover.contains(event.target)) this.closePopover()
      return
    }

    event.stopPropagation()
    const signature = target.getAttribute("data-cbdb-auto-signature")
    const item = this.items.find((candidate) => autoSignature(this.sourcePath, candidate) === signature)
    if (!item) return
    this.openPopover(item, target)
  }

  openPopover(item, anchor) {
    this.closePopover()

    const popover = document.createElement("div")
    popover.className = "cv-annotate-popover cbdb-auto-popover"
    popover.style.position = "fixed"
    popover.style.zIndex = "10000"

    const visibleCandidates = Array(item.candidates || []).slice(0, 5)
    const candidateLines = visibleCandidates.map((candidate) => {
      const years = this.formatYears(candidate.year_start, candidate.year_end)
      const label = candidate.label || item.text || ""
      const dynasty = candidate.dynasty ? ` · ${candidate.dynasty}` : ""
      const sourceLabel = candidate.source_label || candidate.authority_source || "Authority"
      const derivation = candidate.explicit === false && candidate.derivation
        ? ` · ${candidate.derivation}`
        : ""
      const reference = candidate.source_reference
        ? `<div><small>${this.escapeHtml(candidate.source_reference)}</small></div>`
        : ""
      return `<li>${this.escapeHtml(label)}${dynasty}${years ? ` · ${this.escapeHtml(years)}` : ""} <small>${this.escapeHtml(sourceLabel)} ${this.escapeHtml(String(candidate.id || ""))}${this.escapeHtml(derivation)}</small>${reference}</li>`
    }).join("")

    const sourceRows = []
    const seenSources = new Set()
    visibleCandidates.forEach((candidate) => {
      const label = candidate.source_label || candidate.authority_source || "Authority"
      const url = candidate.source_url || ""
      const key = `${label}|${url}`
      if (seenSources.has(key)) return
      seenSources.add(key)
      sourceRows.push(url
        ? `<a href="${this.escapeHtml(url)}" target="_blank" rel="noopener noreferrer">${this.escapeHtml(label)}</a>`
        : this.escapeHtml(label))
    })
    const sourceLicense = visibleCandidates.some((candidate) => candidate.authority_source === "CBDB")
      ? (this.authority.source_license || "")
      : ""
    popover.innerHTML = `
      <div class="cv-annotate-head"><strong>${this.escapeHtml(tr("corpus_annotations.auto.heading"))}</strong></div>
      <div class="cv-annotate-row"><strong>${this.escapeHtml(item.text || "")}</strong> · ${this.escapeHtml(this.kindLabel(item.kind))}</div>
      <div class="cv-annotate-row">${this.escapeHtml(tr("corpus_annotations.auto.confidence", { value: this.confidenceLabel(item.confidence) }))}</div>
      ${candidateLines ? `<div class="cv-annotate-row"><div>${this.escapeHtml(tr("corpus_annotations.auto.candidates"))}</div><ul>${candidateLines}</ul></div>` : ""}
      <div class="cv-annotate-row"><strong>${this.escapeHtml(tr("corpus_annotations.auto.source"))}:</strong> ${sourceRows.join(" · ")}${sourceLicense ? ` · ${this.escapeHtml(sourceLicense)}` : ""}</div>
      <div class="cv-annotate-row cv-annotate-actions">
        <button type="button" class="cbdb-auto-report primary">${this.escapeHtml(tr("corpus_annotations.auto.report"))}</button>
        <button type="button" class="cbdb-auto-close">${this.escapeHtml(tr("corpus_annotations.actions.close"))}</button>
      </div>
      <div class="cv-hint cbdb-auto-status" aria-live="polite"></div>
    `

    const reportButton = popover.querySelector(".cbdb-auto-report")
    const closeButton = popover.querySelector(".cbdb-auto-close")
    if (reportButton) reportButton.addEventListener("click", () => this.reportIncorrect(item, popover, reportButton))
    if (closeButton) closeButton.addEventListener("click", () => this.closePopover())
    popover.addEventListener("click", (event) => event.stopPropagation())

    document.body.appendChild(popover)
    const anchorRect = anchor.getBoundingClientRect()
    const rect = popover.getBoundingClientRect()
    const pad = 8
    const left = Math.min(Math.max(pad, anchorRect.left), Math.max(pad, window.innerWidth - rect.width - pad))
    const topCandidate = anchorRect.bottom + 6
    const top = topCandidate + rect.height <= window.innerHeight - pad
      ? topCandidate
      : Math.max(pad, anchorRect.top - rect.height - 6)
    popover.style.left = `${left}px`
    popover.style.top = `${top}px`
    this.popover = popover
  }

  async reportIncorrect(item, popover, button) {
    if (button.disabled) return
    button.disabled = true
    const status = popover.querySelector(".cbdb-auto-status")
    if (status) status.textContent = tr("corpus_annotations.auto.reporting")

    const targetRef = `corpus_viewer/${this.sourcePath}#authority-auto-${item.start}-${item.end}`
    const summary = `Automatic authority annotation marked “${item.text}” as ${item.kind}; the reader reports that this match is incorrect.`
    const reasoning = JSON.stringify({
      text: item.text,
      kind: item.kind,
      confidence: item.confidence,
      start: item.start,
      end: item.end,
      source_path: this.sourcePath,
      context: this.context,
      candidates: item.candidates || [],
      authority_source: item.authority_source || null,
      cbdb_release: this.authority.source_filename || null,
      cbdb_sha256: this.authority.source_sha256 || null,
      supplementary_workbook: this.authority.supplementary_filename || null,
      supplementary_sha256: this.authority.supplementary_sha256 || null
    }, null, 2)

    try {
      const form = new FormData()
      form.append("title", "Incorrect automatic authority annotation")
      form.append("summary", summary)
      form.append("reasoning", reasoning)
      form.append("source", "authority_auto_annotation")
      form.append("target_ref", targetRef)
      const evidenceLinks = Array.from(new Set(Array(item.candidates || [])
        .map((candidate) => candidate.source_url)
        .filter((value) => typeof value === "string" && value.length > 0)))
      form.append("evidence_links", JSON.stringify(evidenceLinks))

      const response = await fetch("/api/tickets", {
        method: "POST",
        headers: { "Accept": "application/json" },
        body: form
      })
      const data = await response.json().catch(() => null)
      if (!response.ok || !data || data.ok !== true) {
        const message = data && data.error ? data.error : `HTTP ${response.status}`
        throw new Error(message)
      }

      if (data.ticket_id && data.ticket_key) {
        try {
          storeTicketOnDevice(data.ticket_id, data.ticket_key, {
            title: "Incorrect automatic authority annotation",
            source: "authority_auto_annotation"
          })
        } catch (_) {}
      }

      const signature = autoSignature(this.sourcePath, item)
      this.suppressions.add(signature)
      saveSuppressions(this.suppressions)
      this.scheduleApply()
      if (status) status.textContent = tr("corpus_annotations.auto.reported")
      button.hidden = true
    } catch (error) {
      button.disabled = false
      if (status) status.textContent = tr("corpus_annotations.auto.error", { message: error.message || error })
    }
  }

  closePopover() {
    if (this.popover && this.popover.isConnected) this.popover.remove()
    this.popover = null
  }

  kindLabel(kind) {
    if (kind === "person") return tr("corpus_annotations.kinds.person")
    if (kind === "place") return tr("corpus_annotations.kinds.place")
    if (kind === "office") return tr("corpus_annotations.kinds.office")
    return kind || ""
  }

  confidenceLabel(confidence) {
    return confidence === "high"
      ? tr("corpus_annotations.auto.high")
      : tr("corpus_annotations.auto.possible")
  }

  formatYears(start, end) {
    const first = Number(start)
    const last = Number(end)
    if (!Number.isFinite(first) && !Number.isFinite(last)) return ""
    if (Number.isFinite(first) && Number.isFinite(last) && first !== last) return `${first}–${last}`
    return String(Number.isFinite(first) ? first : last)
  }

  escapeHtml(value) {
    return String(value ?? "")
      .replaceAll("&", "&amp;")
      .replaceAll("<", "&lt;")
      .replaceAll(">", "&gt;")
      .replaceAll('"', "&quot;")
      .replaceAll("'", "&#39;")
  }
}

function connectAll() {
  document.querySelectorAll(".corpus-reader[data-corpus-annotations-path-value]").forEach((reader) => {
    if (reader.dataset.cbdbAutoAnnotationsReady === "1") return
    const instance = new CbdbAutoAnnotations(reader)
    reader.cbdbAutoAnnotations = instance
    instance.connect()
  })
}

function disconnectAll() {
  document.querySelectorAll('.corpus-reader[data-cbdb-auto-annotations-ready="1"]').forEach((reader) => {
    if (reader.cbdbAutoAnnotations) reader.cbdbAutoAnnotations.disconnect()
    delete reader.cbdbAutoAnnotations
  })
}

document.addEventListener("turbo:load", connectAll)
document.addEventListener("turbo:before-cache", disconnectAll)
if (document.readyState !== "loading") window.setTimeout(connectAll, 0)
