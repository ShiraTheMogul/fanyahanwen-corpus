import { Controller } from "@hotwired/stimulus";

/*
GapFillBlock (drag mode) controller.

Mechanics:
- Bank contains draggable tiles.
- Each blank is a drop target.
- Mobile: tap a tile to pick, tap a blank to place.
- Tap a placed tile to return it to the bank.

Checking:
- Each drop has data-answers JSON array (acceptable tile IDs).
- We compare chosen tile-id to acceptable set.

Authoring UI will hide this later.
*/
export default class extends Controller {
  static targets = ["drop", "bank", "feedback"];
  static values = { options: Object };

  connect() {
    if (!this.hasOptionsValue) this.optionsValue = {};
    this.pickedTile = null;

    this._wireTiles();
    this._wireDrops();
    this._wireBankDrop();
    this._say("");
  }

  _tiles() {
    return Array.from(this.element.querySelectorAll(".tb-gapdrag-tile"));
  }

  _wireTiles() {
    this._tiles().forEach((tile) => {
      tile.addEventListener("dragstart", (e) => this._onDragStart(e, tile));
      tile.addEventListener("click", () => this._pickOrReturn(tile));
    });
  }

  _wireDrops() {
    this.dropTargets.forEach((drop) => {
      drop.addEventListener("dragover", (e) => this._onDragOver(e, drop));
      drop.addEventListener("dragleave", () => drop.classList.remove("tb-drop-over"));
      drop.addEventListener("drop", (e) => this._onDrop(e, drop));
      drop.addEventListener("click", () => this._tapDrop(drop));
    });
  }

  _wireBankDrop() {
    if (!this.hasBankTarget) return;
    this.bankTarget.addEventListener("dragover", (e) => e.preventDefault());
    this.bankTarget.addEventListener("drop", (e) => this._onDropToBank(e));
  }

  _onDragStart(e, tile) {
    const id = tile.dataset.tileId || "";
    e.dataTransfer.setData("text/plain", id);
    e.dataTransfer.effectAllowed = "move";
    this._pick(tile);
  }

  _onDragOver(e, drop) {
    e.preventDefault();
    drop.classList.add("tb-drop-over");
  }

  _onDrop(e, drop) {
    e.preventDefault();
    drop.classList.remove("tb-drop-over");

    const tileId = e.dataTransfer.getData("text/plain");
    const tile = this._tileById(tileId);
    if (!tile) return;

    this._place(tile, drop);
  }

  _onDropToBank(e) {
    e.preventDefault();
    const tileId = e.dataTransfer.getData("text/plain");
    const tile = this._tileById(tileId);
    if (!tile) return;

    this.bankTarget.appendChild(tile);
    this._restoreAllPlaceholders();
    this._clearPicked();
    this.dropTargets.forEach((d) => d.classList.remove("tb-match-ok", "tb-match-bad"));
  }

  _tapDrop(drop) {
    if (!this.pickedTile) return;
    this._place(this.pickedTile, drop);
  }

  _pickOrReturn(tile) {
    // If tile is in a drop and user taps it, return it to bank.
    const inDrop = tile.closest(".tb-gapdrag-drop");
    if (inDrop && this.hasBankTarget) {
      this.bankTarget.appendChild(tile);
      this._restorePlaceholder(inDrop);
      inDrop.classList.remove("tb-match-ok", "tb-match-bad");
      this._clearPicked();
      return;
    }
    this._pick(tile);
  }

  _pick(tile) {
    const already = this.pickedTile === tile;
    this._clearPicked();
    if (!already) {
      this.pickedTile = tile;
      tile.classList.add("tb-picked");
    }
  }

  _clearPicked() {
    if (this.pickedTile) this.pickedTile.classList.remove("tb-picked");
    this.pickedTile = null;
  }

  _tileById(id) {
    if (!id) return null;
    return this.element.querySelector(`.tb-gapdrag-tile[data-tile-id="${CSS.escape(id)}"]`);
  }

  _place(tile, drop) {
    // If drop already has a tile, send it back to bank.
    const existing = drop.querySelector(".tb-gapdrag-tile");
    if (existing && this.hasBankTarget) this.bankTarget.appendChild(existing);

    this._removePlaceholder(drop);
    drop.appendChild(tile);
    this._clearPicked();
    drop.classList.remove("tb-match-ok", "tb-match-bad");
  }

  _removePlaceholder(drop) {
    const ph = drop.querySelector(".tb-gapdrag-placeholder");
    if (ph) ph.remove();
  }

  _restorePlaceholder(drop) {
    if (drop.querySelector(".tb-gapdrag-tile")) return;
    if (drop.querySelector(".tb-gapdrag-placeholder")) return;
    const span = document.createElement("span");
    span.className = "tb-gapdrag-placeholder";
    span.textContent = "Drop";
    drop.appendChild(span);
  }

  _restoreAllPlaceholders() {
    this.dropTargets.forEach((drop) => this._restorePlaceholder(drop));
  }

  check() {
    let total = 0;
    let correct = 0;

    this.dropTargets.forEach((drop) => {
      total += 1;
      drop.classList.remove("tb-match-ok", "tb-match-bad");

      const tile = drop.querySelector(".tb-gapdrag-tile");
      if (!tile) return; // unanswered

      const chosen = (tile.dataset.tileId || "").toString();

      let answers = [];
      try { answers = JSON.parse(drop.dataset.answers || "[]") || []; } catch { answers = []; }
      answers = Array.isArray(answers) ? answers : [answers];
      answers = answers.map((a) => (a || "").toString()).filter((a) => a.length > 0);

      const ok = answers.includes(chosen);

      if (ok) {
        correct += 1;
        drop.classList.add("tb-match-ok");
      } else {
        drop.classList.add("tb-match-bad");
      }
    });

    if (total === 0) return this._say("Nothing to check.");
    if (correct === total) this._say(`Perfect — ${correct}/${total}.`);
    else this._say(`${correct}/${total} correct. Fix the highlighted blanks and try again.`);
  }

  reset() {
    // Move placed tiles back to bank
    this.dropTargets.forEach((drop) => {
      drop.classList.remove("tb-match-ok", "tb-match-bad");
      const tile = drop.querySelector(".tb-gapdrag-tile");
      if (tile && this.hasBankTarget) this.bankTarget.appendChild(tile);
      this._restorePlaceholder(drop);
    });

    this._clearPicked();
    this._say("Reset.");
  }

  _say(msg) {
    if (this.hasFeedbackTarget) this.feedbackTarget.textContent = msg;
  }
}
