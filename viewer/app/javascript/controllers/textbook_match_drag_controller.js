import { Controller } from "@hotwired/stimulus";

/*
MatchBlock drag/tap controller.
Supports:
- Drag and drop (desktop)
- Tap-to-pick, tap-to-drop (mobile fallback)
Authoring:
- left/right items with id, text/img, optional class for font styling
- answer mapping left_id -> right_id
- mode: drag
*/
export default class extends Controller {
  static targets = ["drop", "bank", "feedback"];
  static values = { answer: Object };

  connect() {
    if (!this.hasAnswerValue) this.answerValue = {};
    this.pickedTile = null;

    // Wire up tiles in bank
    this._refreshTiles();
    this._wireDrops();
    this._say("");
  }

  _refreshTiles() {
    const tiles = this.bankTarget ? Array.from(this.bankTarget.querySelectorAll(".tb-match-tile")) : [];
    tiles.forEach((tile) => {
      tile.addEventListener("dragstart", (e) => this._onDragStart(e, tile));
      tile.addEventListener("click", () => this._pick(tile));
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

    this._assignToDrop(tile, drop);
  }

  _tapDrop(drop) {
    // Mobile-friendly: if user has picked a tile, drop it here.
    if (!this.pickedTile) return;
    this._assignToDrop(this.pickedTile, drop);
  }

  _pick(tile) {
    // Toggle pick
    const alreadyPicked = this.pickedTile === tile;
    this._clearPicked();
    if (!alreadyPicked) {
      this.pickedTile = tile;
      tile.classList.add("tb-picked");
    }
  }

  _clearPicked() {
    if (this.pickedTile) this.pickedTile.classList.remove("tb-picked");
    this.pickedTile = null;
  }

  _tileById(id) {
    if (!this.bankTarget) return null;
    return this.bankTarget.querySelector(`.tb-match-tile[data-tile-id="${CSS.escape(id)}"]`);
  }

  _assignToDrop(tile, drop) {
    // If drop already has a tile, return it to bank.
    const existing = drop.querySelector(".tb-match-tile");
    if (existing) this.bankTarget.appendChild(existing);

    // Remove placeholder
    const ph = drop.querySelector(".tb-match-drop-placeholder");
    if (ph) ph.remove();

    drop.appendChild(tile);
    this._clearPicked();
    // clear correctness styling
    drop.classList.remove("tb-match-ok", "tb-match-bad");
  }

  check() {
    const answer = this.answerValue || {};
    let total = 0;
    let correct = 0;

    this.dropTargets.forEach((drop) => {
      const leftId = drop.dataset.leftId;
      if (!leftId) return;
      total += 1;

      drop.classList.remove("tb-match-ok", "tb-match-bad");

      const tile = drop.querySelector(".tb-match-tile");
      if (!tile) return; // unanswered
      const chosen = (tile.dataset.tileId || "").toString();
      const expected = (answer[leftId] || "").toString();

      if (chosen === expected && expected.length > 0) {
        correct += 1;
        drop.classList.add("tb-match-ok");
      } else {
        drop.classList.add("tb-match-bad");
      }
    });

    if (total === 0) return this._say("Nothing to check.");

    if (correct === total) this._say(`Perfect — ${correct}/${total}.`);
    else this._say(`${correct}/${total} correct. Fix the highlighted ones and try again.`);
  }

  reset() {
    // Return all tiles to bank
    this.dropTargets.forEach((drop) => {
      drop.classList.remove("tb-match-ok", "tb-match-bad");
      const tile = drop.querySelector(".tb-match-tile");
      if (tile && this.bankTarget) this.bankTarget.appendChild(tile);
      if (!drop.querySelector(".tb-match-drop-placeholder")) {
        const span = document.createElement("span");
        span.className = "tb-match-drop-placeholder";
        span.textContent = "Drop here (or tap a tile, then tap here)";
        drop.appendChild(span);
      }
    });
    this._clearPicked();
    this._say("Reset.");
  }

  _say(msg) {
    if (this.hasFeedbackTarget) this.feedbackTarget.textContent = msg;
  }
}
