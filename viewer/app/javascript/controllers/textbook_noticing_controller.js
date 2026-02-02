import { Controller } from "@hotwired/stimulus";

// Click-to-mark activity.
//
// How it works:
// - A TextBlock renders each character as: <span class="tb-ch" data-tb-idx="0">一</span>
// - This controller finds the TextBlock with the matching ref and attaches click handlers.
// - Targets can be specified as indices or as a set of characters.
export default class extends Controller {
  static targets = ["feedback"];
  static values = {
    textRef: String,
    mode: String,
    targetIndices: String,
    targetChars: String,
  };

  connect() {
    this.textPane = document.querySelector(`[data-textbook-text="${this.textRefValue}"]`);
    if (!this.textPane) {
      console.warn("Textbook Noticing: missing text pane for ref", this.textRefValue);
      return;
    }

    this._onCharClick = (e) => {
      const el = e.target.closest(".tb-ch");
      if (!el) return;
      el.classList.toggle("is-picked");
    };

    this.textPane.addEventListener("click", this._onCharClick);
  }

  disconnect() {
    if (this.textPane && this._onCharClick) {
      this.textPane.removeEventListener("click", this._onCharClick);
    }
  }

  reset() {
    if (!this.textPane) return;
    this._clearMarks();
    this.feedbackTarget.textContent = "";
  }

  check() {
    if (!this.textPane) return;
    this._clearMarks({ keepPicked: true });

    const picked = Array.from(this.textPane.querySelectorAll(".tb-ch.is-picked"));
    const targetSet = this._targetSet();
    let correct = 0;

    picked.forEach((el) => {
      const key = this.modeValue === "chars" ? el.dataset.tbCh : parseInt(el.dataset.tbIdx, 10);
      if (targetSet.has(key)) {
        el.classList.add("is-correct");
        correct += 1;
      } else {
        el.classList.add("is-wrong");
      }
    });

    const total = picked.length;
    const expected = targetSet.size;
    if (total === 0) {
      this.feedbackTarget.textContent = "Click a few items first.";
      return;
    }

    // Friendly feedback, not “graded exam” feedback.
    this.feedbackTarget.textContent = `You marked ${total}. ${correct} matched the target set (expected ${expected}).`;
  }

  _targetSet() {
    if (this.modeValue === "chars") {
      const raw = (this.targetCharsValue || "").split("|").filter(Boolean);
      return new Set(raw);
    }

    const raw = (this.targetIndicesValue || "").split(",").map((s) => s.trim()).filter(Boolean);
    return new Set(raw.map((s) => parseInt(s, 10)).filter((n) => Number.isFinite(n)));
  }

  _clearMarks({ keepPicked = false } = {}) {
    if (!this.textPane) return;
    const spans = Array.from(this.textPane.querySelectorAll(".tb-ch"));
    spans.forEach((el) => {
      el.classList.remove("is-correct", "is-wrong");
      if (!keepPicked) el.classList.remove("is-picked");
    });
  }
}
