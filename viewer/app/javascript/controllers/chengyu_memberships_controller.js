import { Controller } from "@hotwired/stimulus"

// Client-side display controls for the Dictionary's Chengyu Field Lens.
//
// The server renders the complete membership list once. This controller only
// decides how much of that already-loaded list is visible, so switching between
// 20 / 50 / 100 / Full list never performs another request.
export default class extends Controller {
  static targets = ["controls", "pagination", "previous", "next", "status", "sizeButton", "row"]
  static values = { defaultSize: Number, character: String }

  connect() {
    this.page = 1
    this.pageSize = this.loadPageSize()

    if (this.hasControlsTarget) this.controlsTarget.hidden = false
    this.render()
  }

  setPageSize(event) {
    const raw = event.currentTarget.dataset.size
    this.pageSize = raw === "all" ? "all" : this.validNumericSize(raw)
    this.page = 1
    this.savePageSize()
    this.render()
  }

  previousPage() {
    if (this.page > 1) {
      this.page -= 1
      this.render()
      this.scrollToHeading()
    }
  }

  nextPage() {
    const pages = this.totalPages()
    if (this.page < pages) {
      this.page += 1
      this.render()
      this.scrollToHeading()
    }
  }

  downloadCsv() {
    const headers = [
      "Chengyu",
      "Matching form",
      "Languages",
      "Preferred definition",
      "Corpus search URL",
      "Source contexts",
      "Wiktionary sources"
    ]

    const records = this.rowTargets.map((row) => {
      try {
        return JSON.parse(row.getAttribute("data-chengyu-memberships-record") || "{}")
      } catch (_error) {
        return {}
      }
    })

    const lines = [headers.map((value) => this.csvCell(value)).join(",")]
    records.forEach((record) => {
      const values = [
        record.chengyu,
        record.matching_form,
        this.list(record.languages).join(" | "),
        record.definition,
        this.absoluteUrl(record.corpus_search_url),
        this.list(record.source_contexts)
          .map((entry) => `${entry.label || "Source context"}: ${this.absoluteUrl(entry.url)}`)
          .join(" | "),
        this.list(record.wiktionary_sources)
          .map((entry) => `${entry.site || "Wiktionary"}: ${entry.url || ""}`)
          .join(" | ")
      ]
      lines.push(values.map((value) => this.csvCell(value)).join(","))
    })

    // The UTF-8 BOM makes spreadsheet programs on Windows recognise Han text
    // correctly without asking the user to choose an encoding manually.
    const blob = new Blob(["\uFEFF", lines.join("\r\n")], { type: "text/csv;charset=utf-8" })
    const url = URL.createObjectURL(blob)
    const anchor = document.createElement("a")
    anchor.href = url
    anchor.download = `chengyu-${this.characterValue || "character"}.csv`
    document.body.appendChild(anchor)
    anchor.click()
    anchor.remove()
    URL.revokeObjectURL(url)
  }

  render() {
    const total = this.rowTargets.length
    if (total === 0) return

    const all = this.pageSize === "all"
    const pages = this.totalPages()
    this.page = Math.min(Math.max(this.page, 1), pages)

    const start = all ? 0 : (this.page - 1) * this.pageSize
    const finish = all ? total : Math.min(start + this.pageSize, total)

    this.rowTargets.forEach((row, index) => {
      row.hidden = index < start || index >= finish
    })

    this.sizeButtonTargets.forEach((button) => {
      const size = button.dataset.size === "all" ? "all" : Number.parseInt(button.dataset.size, 10)
      const active = size === this.pageSize
      button.classList.toggle("is-active", active)
      button.setAttribute("aria-pressed", active ? "true" : "false")
    })

    if (this.hasStatusTarget) {
      this.statusTarget.textContent = all
        ? `Showing all ${total.toLocaleString()} Chengyu`
        : `Showing ${(start + 1).toLocaleString()}–${finish.toLocaleString()} of ${total.toLocaleString()} · Page ${this.page.toLocaleString()} of ${pages.toLocaleString()}`
    }

    if (this.hasPaginationTarget) {
      this.paginationTarget.hidden = all || pages <= 1
    }
    if (this.hasPreviousTarget) this.previousTarget.disabled = this.page <= 1
    if (this.hasNextTarget) this.nextTarget.disabled = this.page >= pages
  }

  totalPages() {
    if (this.pageSize === "all") return 1
    return Math.max(1, Math.ceil(this.rowTargets.length / this.pageSize))
  }

  validNumericSize(raw) {
    const parsed = Number.parseInt(raw, 10)
    return [20, 50, 100].includes(parsed) ? parsed : this.defaultNumericSize()
  }

  defaultNumericSize() {
    return [20, 50, 100].includes(this.defaultSizeValue) ? this.defaultSizeValue : 20
  }

  loadPageSize() {
    try {
      const saved = window.localStorage.getItem("dictionary.chengyuPageSize")
      if (saved === "all") return "all"
      if (saved) return this.validNumericSize(saved)
    } catch (_error) {
      // Storage can be unavailable in privacy-restricted browser contexts.
    }
    return this.defaultNumericSize()
  }

  savePageSize() {
    try {
      window.localStorage.setItem("dictionary.chengyuPageSize", String(this.pageSize))
    } catch (_error) {
      // Display controls still work for the current page without persistence.
    }
  }

  list(value) {
    if (Array.isArray(value)) return value
    return value === null || value === undefined || value === "" ? [] : [value]
  }

  absoluteUrl(value) {
    if (!value) return ""
    try {
      return new URL(value, window.location.origin).href
    } catch (_error) {
      return String(value)
    }
  }

  csvCell(value) {
    const text = value === null || value === undefined ? "" : String(value)
    return `"${text.replace(/"/g, '""')}"`
  }

  scrollToHeading() {
    const heading = document.getElementById("dictionary-chengyu")
    if (heading) heading.scrollIntoView({ block: "start" })
  }
}
