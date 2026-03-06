import { Controller } from "@hotwired/stimulus"

// This controller exists purely to test the Ticket ID + Key system.
// It uses fetch() + FormData so you can upload files and diffs.
//
// Pattern you can reuse elsewhere:
//   - Get a form element
//   - Build a FormData
//   - fetch(url, { method, headers, body: formData })
//   - render response as textContent (never innerHTML)

export default class extends Controller {
  static targets = [
    "createForm",
    "loadForm",
    "createResult",
    "ticketJson",
    "localTickets",
  ]

  connect() {
    this._lastCreated = null
    this.refreshLocalTickets()
  }

  async submitCreate(event) {
    event.preventDefault()

    const form = this.createFormTarget
    const fd = new FormData()

    // Basic scalar fields
    fd.append("title", form.querySelector("[name=title]").value)
    fd.append("summary", form.querySelector("[name=summary]").value)
    fd.append("reasoning", form.querySelector("[name=reasoning]").value)
    fd.append("source", form.querySelector("[name=source]").value)
    fd.append("target_ref", form.querySelector("[name=target_ref]").value)

    // Evidence links: one-per-line -> JSON array
    const linksText = form.querySelector("[name=evidence_links_text]").value
    const links = linksText
      .split("\n")
      .map((s) => s.trim())
      .filter((s) => s.length > 0)
    if (links.length > 0) {
      fd.append("evidence_links", JSON.stringify(links))
    }

    // Evidence files (multiple)
    const filesInput = form.querySelector("[name=evidence_files]")
    for (const file of filesInput.files) {
      fd.append("evidence_files[]", file)
    }

    // Optional diff
    const diffInput = form.querySelector("[name=diff_file]")
    if (diffInput.files && diffInput.files[0]) {
      fd.append("diff_file", diffInput.files[0])
    }

    // Optional contact
    const contact = {
      name: form.querySelector("[name=contact_name]").value.trim(),
      email: form.querySelector("[name=contact_email]").value.trim(),
      notes: form.querySelector("[name=contact_notes]").value.trim(),
    }
    const anyContact = contact.name || contact.email || contact.notes
    if (anyContact) {
      fd.append("contact", JSON.stringify(contact))
    }

    this.createResultTarget.textContent = "Submitting..."

    const res = await fetch("/api/tickets", {
      method: "POST",
      body: fd,
      headers: {
        "Accept": "application/json",
      },
      credentials: "same-origin",
    })

    const text = await res.text()
    let data = null
    try {
      data = JSON.parse(text)
    } catch (_e) {
      // keep as raw text
    }

    if (!res.ok) {
      this.createResultTarget.textContent = text
      this._lastCreated = null
      return
    }

    // The API returns either a back-compat top-level `ticket_id`, or a richer
    // `ticket` object (with `id` / `public_id`). Accept either.
    const ticketObj = data?.ticket || {}
    const ticketId = data?.ticket_id || ticketObj.id || ticketObj.public_id
    const ticketKey = data?.ticket_key

    this._lastCreated = {
      ticket_id: ticketId,
      ticket_key: ticketKey,
      raw: data,
    }

    const lines = []
    lines.push(`TICKET ID: ${ticketId}`)
    lines.push(`TICKET KEY (save this): ${ticketKey}`)
    lines.push("")
    lines.push("Server response (JSON):")
    lines.push(JSON.stringify(data, null, 2))
    this.createResultTarget.textContent = lines.join("\n")

    const store = form.querySelector("[name=store_on_device]").checked
    if (store) {
      this._storeTicketOnDevice(ticketId, ticketKey, anyContact ? contact : null)
      this.refreshLocalTickets()
    }
  }

  async loadTicket(event) {
    event.preventDefault()

    const form = this.loadFormTarget
    const publicId = form.querySelector("[name=public_id]").value.trim()
    const ticketKey = form.querySelector("[name=ticket_key]").value.trim()

    this.ticketJsonTarget.textContent = "Loading..."

    const res = await fetch(`/api/tickets/${encodeURIComponent(publicId)}`, {
      method: "GET",
      headers: {
        "Accept": "application/json",
        "X-TICKET-KEY": ticketKey,
      },
      credentials: "same-origin",
    })

    const text = await res.text()
    if (!res.ok) {
      this.ticketJsonTarget.textContent = text
      return
    }

    // Render as plain text, never HTML.
    try {
      const data = JSON.parse(text)
      this.ticketJsonTarget.textContent = JSON.stringify(data, null, 2)
    } catch (_e) {
      this.ticketJsonTarget.textContent = text
    }
  }

  downloadTicketTxt() {
    if (!this._lastCreated) {
      alert("Create a ticket first.")
      return
    }

    const content = this.createResultTarget.textContent || ""
    const blob = new Blob([content], { type: "text/plain;charset=utf-8" })
    const url = URL.createObjectURL(blob)
    const a = document.createElement("a")
    a.href = url
    a.download = `ticket_${this._lastCreated.ticket_id}.txt`
    document.body.appendChild(a)
    a.click()
    a.remove()
    URL.revokeObjectURL(url)
  }

  async copyTicket() {
    const content = this.createResultTarget.textContent || ""
    if (!content) return
    try {
      await navigator.clipboard.writeText(content)
      alert("Copied.")
    } catch (_e) {
      alert("Copy failed. Select the text and copy manually.")
    }
  }

  refreshLocalTickets() {
    const list = this._readLocalTickets()
    const container = this.localTicketsTarget
    container.textContent = "" // clear

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
      const id = document.createElement("code")
      id.textContent = t.ticket_id
      const btn = document.createElement("button")
      btn.type = "button"
      btn.textContent = "Use"
      btn.addEventListener("click", () => {
        this.loadFormTarget.querySelector("[name=public_id]").value = t.ticket_id
        this.loadFormTarget.querySelector("[name=ticket_key]").value = t.ticket_key
        this.loadTicket(new Event("submit"))
      })

      const meta = document.createElement("span")
      meta.className = "cv-muted"
      meta.textContent = t.saved_at ? `saved ${t.saved_at}` : "saved"

      li.appendChild(id)
      li.appendChild(document.createTextNode(" "))
      li.appendChild(btn)
      li.appendChild(document.createTextNode(" "))
      li.appendChild(meta)
      ul.appendChild(li)
    }

    container.appendChild(ul)
  }

  clearLocalTickets() {
    if (!confirm("Delete locally stored ticket keys from this browser?")) return
    localStorage.removeItem(this._localKey())
    this.refreshLocalTickets()
  }

  // ---- localStorage helpers ----

  _localKey() {
    return "cv_ticket_keys_v1"
  }

  _readLocalTickets() {
    const raw = localStorage.getItem(this._localKey())
    if (!raw) return []
    try {
      const parsed = JSON.parse(raw)
      return Array.isArray(parsed) ? parsed : []
    } catch (_e) {
      return []
    }
  }

  _storeTicketOnDevice(ticketId, ticketKey, contact) {
    const list = this._readLocalTickets()

    // De-dup by ticket_id
    const filtered = list.filter((t) => t.ticket_id !== ticketId)
    filtered.unshift({
      ticket_id: ticketId,
      ticket_key: ticketKey,
      contact: contact,
      saved_at: new Date().toISOString(),
    })

    // Keep the list small to reduce risk if someone shares a browser profile
    const capped = filtered.slice(0, 25)
    localStorage.setItem(this._localKey(), JSON.stringify(capped))
  }
}
