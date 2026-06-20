import { Controller } from "@hotwired/stimulus";

// Create a ticket for a brand-new corpus text file.
//
// Pattern:
// 1) User opens a directory in /corpus_viewer
// 2) User chooses the current directory as the parent location
// 3) User optionally adds a work folder name
// 4) User enters metadata + body text
// 5) Server builds the proposed .txt file and stores it as a ticket
export default class extends Controller {
  static targets = [
    "panel",
    "title",
    "summary",
    "reasoning",
    "workFolder",
    "filename",
    "nation",
    "category",
    "times",
    "year",
    "workBaseTitle",
    "workTitle",
    "displayTitle",
    "pageTitle",
    "author",
    "sourceMeta",
    "wsCategories",
    "extraMetadata",
    "bodyText",
    "status",
    "ticketId",
    "ticketKey",
    "copyKeyBtn",
    "downloadKeyBtn",
    "openTicketLink",
    "storeOnDevice",
    "pathPreview",
  ];

  static values = {
    source: String,
    targetDir: String,
  };

  connect() {
    this.updatePathPreview();
  }

  toggle() {
    if (!this.hasPanelTarget) return;
    this.panelTarget.classList.toggle("hidden");
    if (!this.panelTarget.classList.contains("hidden")) {
      this.updatePathPreview();
    }
  }

  updatePathPreview() {
    if (!this.hasPathPreviewTarget) return;

    const targetDir = (this.targetDirValue || "").replace(/\\/g, "/").replace(/^\/+|\/+$/g, "");
    const workFolder = this.hasWorkFolderTarget ? this.workFolderTarget.value.trim() : "";
    const filename = this._normalizedFilename();

    const parts = [targetDir];
    if (workFolder) parts.push(workFolder);
    if (filename) parts.push(filename);

    this.pathPreviewTarget.textContent = parts.filter(Boolean).join("/") || "(choose a filename)";
  }

  async submit(event) {
    event.preventDefault();

    const bodyText = this.hasBodyTextTarget ? this.bodyTextTarget.value : "";
    if (!bodyText.trim()) {
      this._setStatus("Error: body text is empty.");
      return;
    }

    const filename = this._normalizedFilename();
    if (!filename) {
      this._setStatus("Error: filename is required.");
      return;
    }

    const payload = {
      kind: "corpus_submission",
      source: this.sourceValue || "corpus_submission",
      target_dir: this.targetDirValue,
      work_folder: this.hasWorkFolderTarget ? this.workFolderTarget.value.trim() : "",
      filename,
      title: this.hasTitleTarget ? this.titleTarget.value : "",
      summary: this.hasSummaryTarget ? this.summaryTarget.value : "",
      reasoning: this.hasReasoningTarget ? this.reasoningTarget.value : "",
      body_text: bodyText,
      metadata: {
        nation: this._value("nation"),
        category: this._value("category"),
        times: this._value("times"),
        year: this._value("year"),
        work_base_title: this._value("workBaseTitle"),
        work_title: this._value("workTitle"),
        display_title: this._value("displayTitle"),
        page_title: this._value("pageTitle"),
        author: this._value("author"),
        source: this._value("sourceMeta"),
        ws_categories: this._value("wsCategories"),
        extra_metadata: this._value("extraMetadata"),
      },
    };

    this._setStatus("Submitting ticket…");
    this._setTicket("", "");

    try {
      const resp = await fetch("/api/tickets", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Accept": "application/json",
          "X-CSRF-Token": this._csrfToken(),
        },
        body: JSON.stringify(payload),
      });

      const data = await resp.json().catch(() => null);
      if (!resp.ok || !data || data.ok !== true) {
        const msg = (data && (data.error || data.detail)) ? (data.error || data.detail) : `HTTP ${resp.status}`;
        this._setStatus(`Error: ${msg}`);
        return;
      }

      const ticketId = data.ticket_id || data.ticket?.id || "";
      const ticketKey = data.ticket_key || "";
      this._setStatus("Ticket created ✅ (save the key below)");
      this._setTicket(ticketId, ticketKey);

      if (ticketId && ticketKey) {
        try {
          if (this.hasStoreOnDeviceTarget && this.storeOnDeviceTarget.checked) {
            this._storeTicketOnDevice(ticketId, ticketKey);
          }
        } catch (_e) {}
      }
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

    const target = this.hasPathPreviewTarget ? (this.pathPreviewTarget.textContent || "") : "";
    const content = `TICKET ID: ${id}\nTICKET KEY: ${key}\nTARGET FILE: ${target}\n`;
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

  _normalizedFilename() {
    if (!this.hasFilenameTarget) return "";
    const raw = this.filenameTarget.value.trim();
    if (!raw) return "";
    return raw.toLowerCase().endsWith(".txt") ? raw : `${raw}.txt`;
  }

  _value(name) {
    const targetName = `has${name.charAt(0).toUpperCase()}${name.slice(1)}Target`;
    const valueName = `${name}Target`;
    return this[targetName] ? this[valueName].value : "";
  }

  _storeTicketOnDevice(ticketId, ticketKey) {
    const key = "cv_ticket_keys_v1";
    let list = [];
    try {
      list = JSON.parse(window.localStorage.getItem(key) || "[]");
      if (!Array.isArray(list)) list = [];
    } catch (_e) {
      list = [];
    }

    list = list.filter((t) => t.ticket_id !== ticketId);
    list.unshift({
      ticket_id: ticketId,
      ticket_key: ticketKey,
      saved_at: new Date().toISOString(),
    });

    window.localStorage.setItem(key, JSON.stringify(list.slice(0, 25)));
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
