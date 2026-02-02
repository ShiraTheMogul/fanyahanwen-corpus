import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["prompt", "answer", "feedback"];
  static values = { profile: String, parseProfile: String, min: Number, max: Number };

  connect() {
    this.next();
  }

  async next() {
    const n = this._rand(this.minValue || 1, this.maxValue || 99);
    this.current = n;

    const res = await this._postJSON("/textbook/api/format_numeral", { n, profile: this.profileValue });
    if (!res.ok) {
      this.feedbackTarget.textContent = res.error || "Couldn't generate.";
      return;
    }
    this.promptTarget.textContent = `Convert: ${res.output}`;
    this.answerTarget.value = "";
    this.feedbackTarget.textContent = "";
  }

  async check() {
    const raw = this.answerTarget.value.trim();
    if (raw.length === 0) return (this.feedbackTarget.textContent = "Type an answer.");

    // Accept Arabic directly
    const asInt = Number.parseInt(raw, 10);
    if (Number.isFinite(asInt)) {
      this.feedbackTarget.textContent = asInt === this.current ? "✅ Correct" : `❌ Expected ${this.current}`;
      return;
    }

    // Or parse as Han numerals
    const res = await this._postJSON("/textbook/api/parse_numeral", { s: raw, profile: this.parseProfileValue });
    if (!res.ok) {
      this.feedbackTarget.textContent = res.error || "Couldn't parse.";
      return;
    }

    this.feedbackTarget.textContent = res.output === this.current ? "✅ Correct" : `❌ Expected ${this.current}`;
  }

  _rand(min, max) {
    const lo = Math.min(min, max);
    const hi = Math.max(min, max);
    return Math.floor(Math.random() * (hi - lo + 1)) + lo;
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
