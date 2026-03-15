import { Controller } from "@hotwired/stimulus"

const TRADITIONS = ["kanbun", "hanmun", "hanvan"]

export default class extends Controller {
  static targets = [
    "panel", "status", "ticketId", "ticketKey", "copyKeyBtn", "downloadKeyBtn", "openTicketLink",
    "storeOnDevice", "tradition", "summary", "reasoning", "derived", "sourceSeed",
    "kanbunSeed", "hanmunSeed", "hanvanSeed", "aiNotice"
  ]

  static values = {
    source: String,
    targetPath: String,
  }

  connect() {
    this._lastDefault = ""
    this.applyTraditionDefaults()
  }

  toggle() {
    if (!this.hasPanelTarget) return
    this.panelTarget.classList.toggle("hidden")
    if (!this.panelTarget.classList.contains("hidden")) {
      this.applyTraditionDefaults()
      this._syncAiNotice()
    }
  }

  traditionChanged() {
    this.applyTraditionDefaults(true)
    this._syncAiNotice()
  }

  applyTraditionDefaults(forceReplace = false) {
    if (!this.hasDerivedTarget || !this.hasTraditionTarget) return

    const nextDefault = this._defaultBodyFor(this.traditionTarget.value)
    const currentValue = this.derivedTarget.value || ""

    if (forceReplace || !currentValue || currentValue === this._lastDefault) {
      this.derivedTarget.value = nextDefault
    }

    this._lastDefault = nextDefault
  }

  insertSymbol(event) {
    event.preventDefault()
    if (!this.hasDerivedTarget) return

    const symbol = event.currentTarget.dataset.symbol || ""
    const el = this.derivedTarget
    const start = el.selectionStart || 0
    const end = el.selectionEnd || 0
    const before = el.value.slice(0, start)
    const after = el.value.slice(end)

    el.value = `${before}${symbol}${after}`
    el.focus()
    const nextPos = start + symbol.length
    el.setSelectionRange(nextPos, nextPos)
  }

  async submit(event) {
    event.preventDefault()

    const tradition = this.hasTraditionTarget ? this.traditionTarget.value : "kanbun"
    if (!TRADITIONS.includes(tradition)) {
      this._setStatus("Error: invalid tradition.")
      return
    }

    const bodyText = this.hasDerivedTarget ? this.derivedTarget.value : ""
    if (!bodyText.trim()) {
      this._setStatus("Error: derived text is empty.")
      return
    }

    const titleMap = {
      kanbun: "Create 漢文: Kanbun",
      hanmun: "Create 漢文: Hanmun",
      hanvan: "Create 漢文: Hanvan",
    }

    const payload = {
      kind: "derived_tradition_submission",
      source: this.sourceValue || "corpus_viewer",
      base_path: this.targetPathValue || "",
      tradition,
      title: titleMap[tradition] || "Create 漢文",
      summary: this.hasSummaryTarget ? this.summaryTarget.value : "",
      reasoning: this.hasReasoningTarget ? this.reasoningTarget.value : "",
      body_text: bodyText,
      generation_mode: "manual",
    }

    this._setStatus("Submitting ticket…")
    this._setTicket("", "")

    try {
      const resp = await fetch("/api/tickets", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Accept": "application/json",
          "X-CSRF-Token": this._csrfToken(),
        },
        body: JSON.stringify(payload),
      })

      const data = await resp.json().catch(() => null)
      if (!resp.ok || !data || data.ok !== true) {
        const msg = (data && (data.error || data.detail)) ? (data.error || data.detail) : `HTTP ${resp.status}`
        this._setStatus(`Error: ${msg}`)
        return
      }

      const ticketId = data.ticket_id || data.ticket?.id || ""
      const ticketKey = data.ticket_key || ""
      this._setStatus("Ticket created ✅ (save the key below)")
      this._setTicket(ticketId, ticketKey)

      if (ticketId && ticketKey) {
        try {
          window.localStorage.setItem(`ticket_key:${ticketId}`, ticketKey)
          if (this.hasStoreOnDeviceTarget && this.storeOnDeviceTarget.checked) {
            this._storeTicketOnDevice(ticketId, ticketKey)
          }
        } catch (_e) {}
      }
    } catch (e) {
      this._setStatus(`Error: ${e.message || e}`)
    }
  }

  copyKey(event) {
    event.preventDefault()
    if (!this.hasTicketKeyTarget) return
    const key = this.ticketKeyTarget.textContent || ""
    if (!key) return
    navigator.clipboard.writeText(key).then(() => {
      if (this.hasCopyKeyBtnTarget) {
        const before = this.copyKeyBtnTarget.textContent
        this.copyKeyBtnTarget.textContent = "Copied!"
        setTimeout(() => (this.copyKeyBtnTarget.textContent = before), 1000)
      }
    })
  }

  downloadKey(event) {
    event.preventDefault()
    const id = this.hasTicketIdTarget ? (this.ticketIdTarget.textContent || "") : ""
    const key = this.hasTicketKeyTarget ? (this.ticketKeyTarget.textContent || "") : ""
    if (!id || !key) return

    const target = this.targetPathValue || ""
    const tradition = this.hasTraditionTarget ? this.traditionTarget.value : ""
    const content = `TICKET ID: ${id}\nTICKET KEY: ${key}\nSOURCE PAGE: ${target}\nTRADITION: ${tradition}\n`
    const blob = new Blob([content], { type: "text/plain;charset=utf-8" })
    const url = URL.createObjectURL(blob)
    const a = document.createElement("a")
    a.href = url
    a.download = `ticket_${id}_key.txt`
    document.body.appendChild(a)
    a.click()
    a.remove()
    URL.revokeObjectURL(url)
  }

  _defaultBodyFor(tradition) {
    const seedTarget = this._seedTargetFor(tradition)
    const seedValue = seedTarget ? seedTarget.value : ""
    if (seedValue && seedValue.trim()) return seedValue
    return this.hasSourceSeedTarget ? this.sourceSeedTarget.value : ""
  }

  _seedTargetFor(tradition) {
    switch (tradition) {
      case "kanbun":
        return this.hasKanbunSeedTarget ? this.kanbunSeedTarget : null
      case "hanmun":
        return this.hasHanmunSeedTarget ? this.hanmunSeedTarget : null
      case "hanvan":
        return this.hasHanvanSeedTarget ? this.hanvanSeedTarget : null
      default:
        return null
    }
  }

  _syncAiNotice() {
    if (!this.hasAiNoticeTarget || !this.hasTraditionTarget) return
    this.aiNoticeTarget.hidden = this.traditionTarget.value === "kanbun"
  }

  _storeTicketOnDevice(ticketId, ticketKey) {
    const key = "cv_ticket_keys_v1"
    let list = []
    try {
      list = JSON.parse(window.localStorage.getItem(key) || "[]")
      if (!Array.isArray(list)) list = []
    } catch (_e) {
      list = []
    }

    list = list.filter((t) => t.ticket_id !== ticketId)
    list.unshift({ ticket_id: ticketId, ticket_key: ticketKey, saved_at: new Date().toISOString() })
    window.localStorage.setItem(key, JSON.stringify(list.slice(0, 25)))
  }

  _csrfToken() {
    const el = document.querySelector('meta[name="csrf-token"]')
    return el ? el.content : ""
  }

  _setStatus(text) {
    if (this.hasStatusTarget) this.statusTarget.textContent = text
  }

  _setTicket(id, key) {
    if (this.hasTicketIdTarget) this.ticketIdTarget.textContent = id || ""
    if (this.hasTicketKeyTarget) this.ticketKeyTarget.textContent = key || ""

    if (this.hasDownloadKeyBtnTarget) {
      this.downloadKeyBtnTarget.hidden = !(id && key)
    }

    if (this.hasOpenTicketLinkTarget) {
      if (id && key) {
        this.openTicketLinkTarget.hidden = false
        this.openTicketLinkTarget.href = `/ticket_access?key=${encodeURIComponent(key)}`
      } else {
        this.openTicketLinkTarget.hidden = true
        this.openTicketLinkTarget.removeAttribute("href")
      }
    }
  }
}
