import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["arabic", "han", "feedback", "formatSelect", "parseSelect"];
  static values = { formatProfile: String, parseProfile: String };

  changeFormatProfile() {
    if (!this.hasFormatSelectTarget) return;
    this.formatProfileValue = this.formatSelectTarget.value;
  }

  changeParseProfile() {
    if (!this.hasParseSelectTarget) return;
    this.parseProfileValue = this.parseSelectTarget.value;
  }

  async toHan() {
    const raw = this.arabicTarget.value.trim();
    if (raw.length === 0) return this._say("Enter a number.");
    const n = Number.parseInt(raw, 10);
    if (!Number.isFinite(n)) return this._say("That doesn't look like an integer.");

    const res = await this._postJSON("/textbook/api/format_numeral", { n, profile: this.formatProfileValue });
    if (!res.ok) return this._say(res.error || "Couldn't format.");

    this.hanTarget.value = res.output;
    this._say(`${res.input} → ${res.output}`);
  }

  async toArabic() {
    const s = this.hanTarget.value.trim();
    if (s.length === 0) return this._say("Enter a numeral.");

    const res = await this._postJSON("/textbook/api/parse_numeral", { s, profile: this.parseProfileValue });
    if (!res.ok) return this._say(res.error || "Couldn't parse.");

    this.arabicTarget.value = String(res.output);
    this._say(`${res.input} → ${res.output}`);
  }

  _say(msg) {
    this.feedbackTarget.textContent = msg;
  }

  async _postJSON(url, payload) {
    const token = document.querySelector('meta[name="csrf-token"]')?.content;
    const r = await fetch(url, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        ...(token ? { "X-CSRF-Token": token } : {}),
      },
      body: JSON.stringify(payload),
    });
    const j = await r.json().catch(() => ({}));
    return { ...j, ok: r.ok && j.ok };
  }
}
