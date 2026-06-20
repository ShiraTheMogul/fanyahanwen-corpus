import { Controller } from "@hotwired/stimulus";
import { appendSubmissionExtras, maybeStoreTicketOnDevice } from "controllers/ticket_submission_helpers";

// Propose a corpus text edit by creating an EditTicket.
//
// This controller is intentionally "dumb": it does not attempt to compute a
// diff client-side. Instead, it sends the edited text to the server endpoint
// /api/tickets/text_edit, which:
//   1) loads the current file from disk
//   2) generates a unified diff
//   3) stores that diff as ticket evidence
export default class extends Controller {
  static targets = [
    "panel",
    "original",
    "edited",
    "title",
    "summary",
    "reasoning",
    "status",
    "ticketId",
    "ticketKey",
    "copyKeyBtn",
    "downloadKeyBtn",
    "openJsonLink",
    "openTicketLink",
    "storeOnDevice",
    "evidenceLinks",
    "contactName",
    "contactEmail",
    "contactNotes",
    "uploads",
  ];

  static values = {
    source: String,
    targetPath: String,
  };

  connect() {
    // Initialize the edit box with the file contents.
    if (this.hasOriginalTarget && this.hasEditedTarget) {
      this.editedTarget.value = this.originalTarget.value;
    }
  }

  toggle() {
    if (!this.hasPanelTarget) return;
    this.panelTarget.classList.toggle("hidden");
  }

  async submit(event) {
    event.preventDefault();

    const title = this.hasTitleTarget ? this.titleTarget.value : "";
    const summary = this.hasSummaryTarget ? this.summaryTarget.value : "";
    const reasoning = this.hasReasoningTarget ? this.reasoningTarget.value : "";
    const newText = this.hasEditedTarget ? this.editedTarget.value : "";

    this._setStatus("Submitting ticket…");
    this._setTicket("", "");

    try {
      const form = new FormData();
      form.append("title", title);
      form.append("summary", summary);
      form.append("reasoning", reasoning);
      form.append("source", this.sourceValue || "corpus_viewer");
      form.append("target_path", this.targetPathValue);
      form.append("new_text", newText);
      appendSubmissionExtras(form, this);

      const resp = await fetch("/api/tickets/text_edit", {
        method: "POST",
        headers: {
          "Accept": "application/json",
          "X-CSRF-Token": this._csrfToken(),
        },
        body: form,
      });

      const data = await resp.json().catch(() => null);
      if (!resp.ok || !data || data.ok !== true) {
        const msg = (data && (data.error || data.detail)) ? (data.error || data.detail) : `HTTP ${resp.status}`;
        this._setStatus(`Error: ${msg}`);
        return;
      }

      this._setStatus("Ticket created ✅ (save the key below)");
      this._setTicket(data.ticket_id || (data.ticket && data.ticket.id) || "", data.ticket_key || "");

      try {
        maybeStoreTicketOnDevice(this, data.ticket_id, data.ticket_key, {
          title,
          source: "text_edit",
        });
      } catch (_error) {}
    } catch (e) {
      this._setStatus(`Error: ${e.message || e}`);
    }
  }

  copyKey(event) {
    event.preventDefault();
    if (!this.hasTicketKeyTarget) return;
    const key = this.ticketKeyTarget.textContent || "";
    if (!key) return;
    navigator.clipboard.writeText(key).then(() => {
      if (this.hasCopyKeyBtnTarget) {
        const before = this.copyKeyBtnTarget.textContent;
        this.copyKeyBtnTarget.textContent = "Copied!";
        setTimeout(() => (this.copyKeyBtnTarget.textContent = before), 1000);
      }
    });
  }


  downloadKey(event) {
    event.preventDefault();
    const id = this.hasTicketIdTarget ? (this.ticketIdTarget.textContent || "") : "";
    const key = this.hasTicketKeyTarget ? (this.ticketKeyTarget.textContent || "") : "";
    if (!id || !key) return;

    const content = `TICKET ID: ${id}\nTICKET KEY: ${key}\n`;
    const blob = new Blob([content], { type: "text/plain;charset=utf-8" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = `ticket_${id}_key.txt`;
    document.body.appendChild(a);
    a.click();
    a.remove();
    URL.revokeObjectURL(url);
  }

  _csrfToken() {
    const el = document.querySelector('meta[name="csrf-token"]');
    return el ? el.content : "";
  }

  _setStatus(text) {
    if (!this.hasStatusTarget) return;
    this.statusTarget.textContent = text;
  }

  _setTicket(id, key) {
    if (this.hasTicketIdTarget) this.ticketIdTarget.textContent = id || "";
    if (this.hasTicketKeyTarget) this.ticketKeyTarget.textContent = key || "";

    if (this.hasDownloadKeyBtnTarget) {
      this.downloadKeyBtnTarget.hidden = !(id && key);
    }

    if (this.hasOpenJsonLinkTarget) {
      if (id && key) {
        this.openJsonLinkTarget.hidden = false;
        this.openJsonLinkTarget.href = `/api/tickets/${encodeURIComponent(id)}?ticket_key=${encodeURIComponent(key)}`;
      } else {
        this.openJsonLinkTarget.hidden = true;
        this.openJsonLinkTarget.removeAttribute("href");
      }
    }

    if (this.hasOpenTicketLinkTarget) {
      if (id && key) {
        this.openTicketLinkTarget.hidden = false;
        this.openTicketLinkTarget.href = `/ticket_access?key=${encodeURIComponent(key)}`;
      } else {
        this.openTicketLinkTarget.hidden = true;
        this.openTicketLinkTarget.removeAttribute("href");
      }
    }
  }
}
