import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "ticketKeyInput",
    "status",
    "ticketPanel",
    "ticketSummary",
    "messages",
    "messageBody",
    "evidence",
    "rawJsonLink",
    "savedTickets",
  ]

  connect() {
    this.currentTicketId = null
    this.currentTicketKey = null
    this._migrateLegacyKeys()

    const params = new URLSearchParams(window.location.search)
    const id = (params.get("id") || "").trim()
    const key = (params.get("key") || "").trim()

    if (key && this.hasTicketKeyInputTarget) {
      this.ticketKeyInputTarget.value = key
    }

    this.refreshSavedTickets()

    if (key) {
      if (id) {
        this.loadTicket(id, key)
      } else {
        this.loadByKey(key)
      }
    }
  }

  async loadFromForm(event) {
    event.preventDefault()
    const key = this.ticketKeyInputTarget.value.trim()
    await this.loadByKey(key)
  }

  async loadByKey(key) {
    if (!key) {
      this._setStatus("Enter your Ticket Key.")
      return
    }

    this._setStatus("Finding ticket…")
    this.ticketPanelTarget.hidden = true

    const res = await fetch("/api/tickets/resolve_key", {
      method: "POST",
      headers: {
        "Accept": "application/json",
        "Content-Type": "application/json",
        "X-CSRF-Token": this._csrfToken(),
      },
      credentials: "same-origin",
      body: JSON.stringify({ ticket_key: key }),
    })

    const text = await res.text()
    let data = null
    try {
      data = JSON.parse(text)
    } catch (_e) {}

    if (!res.ok || !data || data.ok !== true) {
      const msg = data?.error || text || `HTTP ${res.status}`
      this._setStatus(`Error: ${msg}`)
      return
    }

    this.currentTicketId = data.ticket_id || data.ticket?.id || null
    this.currentTicketKey = key

    this._renderTicket(data.ticket || {})
    this._rememberResolvedTicket(this.currentTicketId, key)
    this._setStatus("Ticket loaded.")
    this.ticketPanelTarget.hidden = false

    const url = new URL(window.location.href)
    url.searchParams.delete("id")
    url.searchParams.set("key", key)
    window.history.replaceState({}, "", url)

    if (this.hasRawJsonLinkTarget && this.currentTicketId) {
      this.rawJsonLinkTarget.hidden = false
      this.rawJsonLinkTarget.href = `/api/tickets/${encodeURIComponent(this.currentTicketId)}?ticket_key=${encodeURIComponent(this.currentTicketKey)}`
    }
  }

  async loadTicket(id, key) {
    if (!key) {
      this._setStatus("Enter your Ticket Key.")
      return
    }

    if (!id) {
      await this.loadByKey(key)
      return
    }

    this._setStatus("Loading ticket…")
    this.ticketPanelTarget.hidden = true

    const res = await fetch(`/api/tickets/${encodeURIComponent(id)}?ticket_key=${encodeURIComponent(key)}`, {
      method: "GET",
      headers: { "Accept": "application/json" },
      credentials: "same-origin",
    })

    const text = await res.text()
    let data = null
    try {
      data = JSON.parse(text)
    } catch (_e) {}

    if (!res.ok || !data || data.ok !== true) {
      const msg = data?.error || text || `HTTP ${res.status}`
      this._setStatus(`Error: ${msg}`)
      return
    }

    this.currentTicketId = data.ticket_id || data.ticket?.id || id
    this.currentTicketKey = key

    this._renderTicket(data.ticket || {})
    this._rememberResolvedTicket(this.currentTicketId, key)
    this._setStatus("Ticket loaded.")
    this.ticketPanelTarget.hidden = false

    if (this.hasRawJsonLinkTarget) {
      this.rawJsonLinkTarget.hidden = false
      this.rawJsonLinkTarget.href = `/api/tickets/${encodeURIComponent(this.currentTicketId)}?ticket_key=${encodeURIComponent(this.currentTicketKey)}`
    }
  }

  async postMessage(event) {
    event.preventDefault()
    if (!this.currentTicketId || !this.currentTicketKey) {
      this._setStatus("Open a ticket first.")
      return
    }

    const body = this.messageBodyTarget.value.trim()
    if (!body) {
      this._setStatus("Message is empty.")
      return
    }

    this._setStatus("Sending message…")
    const res = await fetch(`/api/tickets/${encodeURIComponent(this.currentTicketId)}/messages?ticket_key=${encodeURIComponent(this.currentTicketKey)}`, {
      method: "POST",
      headers: {
        "Accept": "application/json",
        "Content-Type": "application/json",
        "X-CSRF-Token": this._csrfToken(),
      },
      credentials: "same-origin",
      body: JSON.stringify({ body }),
    })

    const text = await res.text()
    let data = null
    try {
      data = JSON.parse(text)
    } catch (_e) {}

    if (!res.ok || !data || data.ok !== true) {
      const msg = data?.error || text || `HTTP ${res.status}`
      this._setStatus(`Error: ${msg}`)
      return
    }

    this.messageBodyTarget.value = ""
    this._setStatus("Message sent.")
    await this.loadTicket(this.currentTicketId, this.currentTicketKey)
  }

  refreshSavedTickets() {
    const list = this._readSavedTickets()
    const container = this.savedTicketsTarget
    container.textContent = ""

    if (list.length === 0) {
      const p = document.createElement("p")
      p.className = "cv-muted"
      p.textContent = "No locally stored tickets."
      container.appendChild(p)
      return
    }

    const ul = document.createElement("ul")
    ul.className = "cv-ticket-list"

    for (const t of list) {
      const li = document.createElement("li")

      if (t.ticket_key) {
        const code = document.createElement("code")
        code.textContent = t.ticket_key
        li.appendChild(code)
        li.appendChild(document.createTextNode(" "))
      }

      const useBtn = document.createElement("button")
      useBtn.type = "button"
      useBtn.textContent = "Open"
      useBtn.addEventListener("click", () => {
        this.ticketKeyInputTarget.value = t.ticket_key
        const url = new URL(window.location.href)
        url.searchParams.delete("id")
        url.searchParams.set("key", t.ticket_key)
        window.history.replaceState({}, "", url)
        if (t.ticket_id) {
          this.loadTicket(t.ticket_id, t.ticket_key)
        } else {
          this.loadByKey(t.ticket_key)
        }
      })
      li.appendChild(useBtn)
      li.appendChild(document.createTextNode(" "))

      const txtBtn = document.createElement("button")
      txtBtn.type = "button"
      txtBtn.textContent = "Download key"
      txtBtn.addEventListener("click", () => this._downloadTicketTxt(t.ticket_id, t.ticket_key))
      li.appendChild(txtBtn)
      li.appendChild(document.createTextNode(" "))

      const forgetBtn = document.createElement("button")
      forgetBtn.type = "button"
      forgetBtn.textContent = "Forget"
      forgetBtn.addEventListener("click", () => {
        this._removeSavedTicket(t.ticket_key)
        this.refreshSavedTickets()
      })
      li.appendChild(forgetBtn)
      li.appendChild(document.createTextNode(" "))

      const meta = document.createElement("span")
      meta.className = "cv-muted"
      meta.textContent = t.saved_at ? `saved ${t.saved_at}` : "saved"
      li.appendChild(meta)

      ul.appendChild(li)
    }

    container.appendChild(ul)
  }

  clearSavedTickets() {
    if (!window.confirm("Delete locally stored ticket keys from this browser?")) return
    window.localStorage.removeItem(this._localKey())
    this.refreshSavedTickets()
  }

  _renderTicket(ticket) {
    const meta = ticket.diff_metadata || {}
    const summary = {
      id: ticket.id,
      title: ticket.title,
      status: ticket.status,
      source: ticket.source,
      target_ref: ticket.target_ref,
      tags: ticket.tags,
      created_at: ticket.created_at,
      updated_at: ticket.updated_at,
      summary: ticket.summary,
      reasoning: ticket.reasoning,
    }

    let summaryText = JSON.stringify(summary, null, 2)
    if (meta.kind === "annotations_edit") {
      const rows = Array.isArray(meta.preview_items) ? meta.preview_items : []
      const preview = rows.map((row) => {
        const base = `- ${row.kind || "annotation"} ${row.start}–${row.end}: ${row.text || ""}`
        return row.note ? `${base}\n  note: ${row.note}` : base
      }).join("\n")
      summaryText += `\n\nAnnotation preview\nTarget: ${meta.target_path || ""}\nItems: ${((meta.proposed_annotations || {}).items || []).length}\n${preview}`
    }

    this.ticketSummaryTarget.textContent = summaryText

    this.messagesTarget.textContent = ""
    const messages = Array.isArray(ticket.messages) ? ticket.messages : []
    if (messages.length === 0) {
      const p = document.createElement("p")
      p.className = "cv-muted"
      p.textContent = "No messages yet."
      this.messagesTarget.appendChild(p)
    } else {
      for (const message of messages) {
        const card = document.createElement("div")
        card.className = "cv-message-card"

        const head = document.createElement("div")
        head.className = "cv-muted"
        head.textContent = `${message.actor_label || message.actor_type || "message"} · ${message.created_at || ""}`
        card.appendChild(head)

        const body = document.createElement("pre")
        body.className = "cv-pre cv-pre-wrap"
        body.textContent = message.body || ""
        card.appendChild(body)

        this.messagesTarget.appendChild(card)
      }
    }

    this.evidenceTarget.textContent = ""
    const files = Array.isArray(ticket.evidence_files) ? ticket.evidence_files : []
    if (files.length === 0) {
      const p = document.createElement("p")
      p.className = "cv-muted"
      p.textContent = "No uploaded files."
      this.evidenceTarget.appendChild(p)
    } else {
      const ul = document.createElement("ul")
      for (const file of files) {
        const li = document.createElement("li")
        const a = document.createElement("a")
        a.textContent = file.filename || "download"
        a.href = `/api/tickets/${encodeURIComponent(ticket.id)}/evidence/${encodeURIComponent(file.attachment_id)}?ticket_key=${encodeURIComponent(this.currentTicketKey)}`
        li.appendChild(a)
        ul.appendChild(li)
      }
      this.evidenceTarget.appendChild(ul)
    }
  }

  _csrfToken() {
    const el = document.querySelector('meta[name="csrf-token"]')
    return el ? el.content : ""
  }

  _setStatus(text) {
    this.statusTarget.textContent = text
  }

  _localKey() {
    return "cv_ticket_keys_v1"
  }

  _readSavedTickets() {
    const raw = window.localStorage.getItem(this._localKey())
    if (!raw) return []
    try {
      const parsed = JSON.parse(raw)
      return Array.isArray(parsed) ? parsed : []
    } catch (_e) {
      return []
    }
  }

  _writeSavedTickets(list) {
    window.localStorage.setItem(this._localKey(), JSON.stringify(list.slice(0, 25)))
  }

  _removeSavedTicket(ticketKey) {
    const list = this._readSavedTickets().filter((t) => t.ticket_key !== ticketKey)
    this._writeSavedTickets(list)
  }

  _rememberResolvedTicket(ticketId, ticketKey) {
    if (!ticketKey) return
    const list = this._readSavedTickets()
    const next = list.filter((t) => t.ticket_key !== ticketKey)
    next.unshift({
      ticket_id: ticketId || "",
      ticket_key: ticketKey,
      saved_at: new Date().toISOString(),
    })
    this._writeSavedTickets(next)
    this.refreshSavedTickets()
  }

  _migrateLegacyKeys() {
    const list = this._readSavedTickets()
    const seen = new Set(list.map((t) => `${t.ticket_id || ""}:${t.ticket_key || ""}`))

    for (let i = 0; i < window.localStorage.length; i += 1) {
      const keyName = window.localStorage.key(i)
      if (!keyName || !keyName.startsWith("ticket_key:")) continue
      const ticketId = keyName.slice("ticket_key:".length)
      const ticketKey = window.localStorage.getItem(keyName)
      const sig = `${ticketId}:${ticketKey}`
      if (!ticketId || !ticketKey || seen.has(sig)) continue
      list.unshift({
        ticket_id: ticketId,
        ticket_key: ticketKey,
        saved_at: new Date().toISOString(),
      })
      seen.add(sig)
    }

    this._writeSavedTickets(list)
  }

  _downloadTicketTxt(ticketId, ticketKey) {
    const lines = [`TICKET KEY: ${ticketKey}`]
    if (ticketId) lines.push(`TICKET ID: ${ticketId}`)
    const content = `${lines.join("\n")}\n`
    const blob = new Blob([content], { type: "text/plain;charset=utf-8" })
    const url = URL.createObjectURL(blob)
    const a = document.createElement("a")
    a.href = url
    a.download = ticketId ? `ticket_${ticketId}_key.txt` : "ticket_key.txt"
    document.body.appendChild(a)
    a.click()
    a.remove()
    URL.revokeObjectURL(url)
  }
}
