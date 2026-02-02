import { Controller } from "@hotwired/stimulus";

// Staged reveal cards for guided discovery.
// The HTML contains a list of cards; we show them one-by-one.
export default class extends Controller {
  static targets = ["cards"];

  connect() {
    this.index = 0;
    this._sync();
  }

  next() {
    this.index += 1;
    this._sync();
  }

  reset() {
    this.index = 0;
    this._sync();
  }

  _sync() {
    const cards = Array.from(this.cardsTarget.querySelectorAll(".tb-reveal-card"));
    cards.forEach((el, i) => {
      if (i <= this.index) {
        el.classList.add("is-visible");
      } else {
        el.classList.remove("is-visible");
      }
    });

    // Clamp in case the lesson has fewer cards than expected.
    if (this.index > cards.length - 1) {
      this.index = Math.max(cards.length - 1, 0);
    }
  }
}
