import { Controller } from "@hotwired/stimulus";

/*
GapFillBlock controller.

Design goals:
- Simple, stable, no dependency on external libs.
- Works for English and CJK equally.
- Supports input blanks and dropdown blanks.
- Multiple acceptable answers per blank.

Authoring schema (will be hidden by editor later):
segments:
  - "prefix"
  - { id: a, answer: "於", width: 3 }
  - "suffix"
or
  - { id: b, answers: ["之","其"] }
  - { id: c, choices: ["一","二","三"], answer: "二" }

Options:
- trim: true (default)
- case_sensitive: false (default)
- normalize_spaces: true (default)  // collapses whitespace for checking
*/
export default class extends Controller {
  static targets = ["field", "feedback"];
  static values = { options: Object };

  connect() {
    if (!this.hasOptionsValue) this.optionsValue = {};
    this._say("");
  }

  check() {
    const opts = this.optionsValue || {};
    const trim = opts.trim !== false;
    const caseSensitive = opts.case_sensitive === true;
    const normalizeSpaces = opts.normalize_spaces !== false;

    let total = 0;
    let correct = 0;

    this.fieldTargets.forEach((el) => {
      total += 1;

      el.classList.remove("tb-gap-ok", "tb-gap-bad");

      const raw = (el.value || "").toString();
      if (raw.length === 0) return; // unanswered is neutral

      const answersJson = el.dataset.answers || "[]";
      let answers = [];
      try { answers = JSON.parse(answersJson) || []; } catch { answers = []; }
      answers = Array.isArray(answers) ? answers : [answers];
      answers = answers.map((a) => (a || "").toString()).filter((a) => a.length > 0);

      const got = this._norm(raw, { trim, caseSensitive, normalizeSpaces });
      const ok = answers.some((a) => this._norm(a, { trim, caseSensitive, normalizeSpaces }) === got);

      if (ok) {
        correct += 1;
        el.classList.add("tb-gap-ok");
      } else {
        el.classList.add("tb-gap-bad");
      }
    });

    if (total === 0) return this._say("Nothing to check.");

    if (correct === total) this._say(`Perfect — ${correct}/${total}.`);
    else this._say(`${correct}/${total} correct. Fix the highlighted blanks and try again.`);
  }

  reset() {
    this.fieldTargets.forEach((el) => {
      el.value = "";
      el.classList.remove("tb-gap-ok", "tb-gap-bad");
    });
    this._say("Reset.");
  }

  _norm(s, { trim, caseSensitive, normalizeSpaces }) {
    let out = (s || "").toString();
    if (trim) out = out.trim();
    if (normalizeSpaces) out = out.replace(/\s+/g, " ");
    if (!caseSensitive) out = out.toLowerCase();
    return out;
  }

  _say(msg) {
    if (this.hasFeedbackTarget) this.feedbackTarget.textContent = msg;
  }
}
