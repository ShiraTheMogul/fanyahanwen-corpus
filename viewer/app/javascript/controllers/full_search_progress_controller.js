import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "title", "query", "status", "bar", "counts", "details", "download", "cancel",
    "handle", "panel", "minimized", "miniLabel"
  ]
  static values = {
    currentSearch: Object,
    pollInterval: { type: Number, default: 8000 }
  }

  connect() {
    this.storageKey = "fyhwc.fullSearches"
    this.dragging = false
    this.loadSearches()

    if (this.hasCurrentSearchValue && this.currentSearchValue.id) {
      this.upsertSearch(this.currentSearchValue)
    }

    this.activeSearch = this.searches.find((search) => !search.removed)
    if (this.activeSearch) {
      this.show(this.activeSearch)
      this.schedulePoll(500)
    }

    this.handleTarget.addEventListener("pointerdown", this.startDrag)
  }

  disconnect() {
    this.clearTimer()
    this.handleTarget.removeEventListener("pointerdown", this.startDrag)
    window.removeEventListener("pointermove", this.drag)
    window.removeEventListener("pointerup", this.endDrag)
  }

  // The close button deliberately minimizes instead of deleting the record.
  // Full searches can run for a long time, and a completed search should remain
  // easy to restore for download without requiring an account or browser history.
  dismiss() {
    if (!this.activeSearch) return
    this.activeSearch.minimized = true
    this.saveSearches()
    this.render(this.activeSearch)
  }

  restore() {
    if (!this.activeSearch) return
    this.activeSearch.minimized = false
    this.saveSearches()
    this.render(this.activeSearch)
  }

  async cancel() {
    if (!this.activeSearch || !this.activeSearch.cancel_url) return
    this.cancelTarget.disabled = true

    try {
      const response = await fetch(this.activeSearch.cancel_url, {
        method: "POST",
        headers: {
          "Accept": "application/json",
          "X-CSRF-Token": this.csrfToken()
        }
      })
      if (response.ok) {
        this.updateFromStatus(await response.json())
      }
    } finally {
      this.cancelTarget.disabled = false
    }
  }

  async poll() {
    if (!this.activeSearch || !this.activeSearch.status_url) return

    try {
      const response = await fetch(this.activeSearch.status_url, { headers: { "Accept": "application/json" } })
      if (response.ok) {
        this.updateFromStatus(await response.json())
      }
    } catch (_error) {
      // Polling is deliberately quiet. The status page remains the source of truth.
    } finally {
      if (this.activeSearch && !["complete", "failed", "cancelled"].includes(this.activeSearch.status)) {
        this.schedulePoll(this.pollIntervalValue)
      }
    }
  }

  updateFromStatus(payload) {
    const previous = this.searches.find((search) => search.id === payload.id) || this.activeSearch || {}
    const wasTerminal = ["complete", "failed", "cancelled"].includes(previous.status)
    this.upsertSearch({ ...previous, ...payload })
    this.activeSearch = this.searches.find((search) => search.id === payload.id)
    this.render(this.activeSearch)
    this.renderPreparedPage(payload)

    const isTerminal = ["complete", "failed", "cancelled"].includes(payload.status)
    const preparedPage = document.querySelector("[data-prepared-search-id]")
    if (!wasTerminal && isTerminal && preparedPage?.dataset.preparedSearchId === payload.id) {
      window.location.reload()
    }
  }

  show(search) {
    this.element.hidden = false
    this.render(search)
  }

  render(search) {
    if (!search) return

    this.element.hidden = false
    this.element.classList.toggle("is-minimized", Boolean(search.minimized))
    this.panelTarget.hidden = Boolean(search.minimized)
    this.minimizedTarget.hidden = !search.minimized

    this.queryTarget.textContent = search.query || ""
    const statusText = search.worker_waiting
      ? "Queued · waiting for a background worker"
      : `${search.status_label || search.status || ""} · ${search.stage_label || search.stage || ""}`
    this.statusTarget.textContent = statusText
    this.barTarget.value = Number(search.percent || 0)
    this.countsTarget.textContent = `${Number(search.files_scanned || 0).toLocaleString()} / ${Number(search.files_total || 0).toLocaleString()} files · ${Number(search.hits_found || 0).toLocaleString()} hits`
    this.detailsTarget.href = this.detailsUrl(search)
    this.miniLabelTarget.textContent = this.miniLabel(search)

    if (search.complete && search.download_url) {
      this.downloadTarget.hidden = false
      this.downloadTarget.href = search.download_url
      this.cancelTarget.hidden = true
    } else if (search.cancelled || search.failed) {
      this.downloadTarget.hidden = true
      this.cancelTarget.hidden = true
    } else {
      this.downloadTarget.hidden = true
      this.cancelTarget.hidden = false
    }
  }

  renderPreparedPage(search) {
    document.querySelectorAll("[data-prepared-status]").forEach((element) => {
      element.textContent = search.status_label || search.status || ""
    })
    document.querySelectorAll("[data-prepared-stage]").forEach((element) => {
      element.textContent = search.worker_waiting
        ? "Waiting for background worker"
        : (search.stage_label || search.stage || "")
    })
    document.querySelectorAll("[data-prepared-files]").forEach((element) => {
      element.textContent = `${Number(search.files_scanned || 0).toLocaleString()} / ${Number(search.files_total || 0).toLocaleString()}`
    })
    document.querySelectorAll("[data-prepared-hits]").forEach((element) => {
      element.textContent = Number(search.hits_found || 0).toLocaleString()
    })
    document.querySelectorAll("[data-worker-waiting]").forEach((element) => {
      element.hidden = !search.worker_waiting
    })
  }

  miniLabel(search) {
    const status = search.status_label || search.status || ""
    const percent = Number(search.percent || 0)
    const hits = Number(search.hits_found || 0)
    if (search.complete) return `Full search complete · ${hits.toLocaleString()} hits`
    if (search.failed) return "Full search failed"
    if (search.cancelled) return "Full search cancelled"
    return `Full search · ${status} · ${percent.toFixed(0)}%`
  }

  detailsUrl(search) {
    if (!search.id || !search.key) return "#"
    return `/corpus/search/prepared/${encodeURIComponent(search.id)}?key=${encodeURIComponent(search.key)}`
  }

  upsertSearch(search) {
    this.searches = this.searches.filter((existing) => existing.id !== search.id)
    this.searches.unshift(search)
    this.searches = this.searches.slice(0, 5)
    this.saveSearches()
  }

  loadSearches() {
    try {
      this.searches = JSON.parse(window.localStorage.getItem(this.storageKey) || "[]")
      this.searches.forEach((search) => {
        if (search.dismissed && search.minimized === undefined) search.minimized = true
      })
    } catch (_error) {
      this.searches = []
    }
  }

  saveSearches() {
    window.localStorage.setItem(this.storageKey, JSON.stringify(this.searches))
  }

  schedulePoll(delay) {
    this.clearTimer()
    this.timer = window.setTimeout(() => this.poll(), delay)
  }

  clearTimer() {
    if (this.timer) window.clearTimeout(this.timer)
    this.timer = null
  }

  csrfToken() {
    const meta = document.querySelector('meta[name="csrf-token"]')
    return meta ? meta.content : ""
  }

  startDrag = (event) => {
    if (event.target.closest("button, a")) return
    this.dragging = true
    this.startX = event.clientX
    this.startY = event.clientY
    const rect = this.element.getBoundingClientRect()
    this.startLeft = rect.left
    this.startTop = rect.top
    this.element.style.right = "auto"
    this.element.style.bottom = "auto"
    this.element.style.left = `${rect.left}px`
    this.element.style.top = `${rect.top}px`
    window.addEventListener("pointermove", this.drag)
    window.addEventListener("pointerup", this.endDrag)
  }

  drag = (event) => {
    if (!this.dragging) return
    const left = Math.max(0, Math.min(window.innerWidth - this.element.offsetWidth, this.startLeft + event.clientX - this.startX))
    const top = Math.max(0, Math.min(window.innerHeight - this.element.offsetHeight, this.startTop + event.clientY - this.startY))
    this.element.style.left = `${left}px`
    this.element.style.top = `${top}px`
  }

  endDrag = () => {
    this.dragging = false
    window.removeEventListener("pointermove", this.drag)
    window.removeEventListener("pointerup", this.endDrag)
  }
}
