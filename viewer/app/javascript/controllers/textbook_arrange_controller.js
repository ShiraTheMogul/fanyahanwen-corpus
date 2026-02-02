import { Controller } from "@hotwired/stimulus";

/*
ArrangeBlock controller: ordering tiles into a fixed number of slots.
Supports:
- Drag and drop (desktop)
- Tap-to-pick then tap slot (mobile)
- Tap a placed tile to return it to the bank

YAML storage (authoring UI will hide this later):
- type: arrange
  bank: [{id, text, img?, class?}, ...]
  answer: [id1, id2, ...]  # expected order
  slots: N  # optional (defaults to answer length)
  options: { shuffle: true, tile_scale: md, show_check: true }
*/
export default class extends Controller {
  static targets = ["slot", "bank", "feedback"];
  static values = { answer: Array };

  connect() {
    if (!this.hasAnswerValue) this.answerValue = [];
    this.pickedTile = null;

    this._wireBankTiles();
    this._wireSlots();
    this._wireBankDrop();
    this._say("");
  }

  _wireBankTiles() {
    if (!this.hasBankTarget) return;
    this._tiles().forEach((tile) => this._wireTile(tile));
  }

  _tiles() {
    if (!this.hasBankTarget) return [];
    return Array.from(this.element.querySelectorAll(".tb-arrange-tile"));
  }

  _wireTile(tile) {
    tile.addEventListener("dragstart", (e) => this._onDragStart(e, tile));
    tile.addEventListener("click", () => this._pick(tile));
  }

  _wireSlots() {
    this.slotTargets.forEach((slot) => {
      slot.addEventListener("dragover", (e) => this._onDragOver(e, slot));
      slot.addEventListener("dragleave", () => slot.classList.remove("tb-drop-over"));
      slot.addEventListener("drop", (e) => this._onDropToSlot(e, slot));
      slot.addEventListener("click", () => this._tapSlot(slot));
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

  _onDragOver(e, slot) {
    e.preventDefault();
    slot.classList.add("tb-drop-over");
  }

  _onDropToSlot(e, slot) {
    e.preventDefault();
    slot.classList.remove("tb-drop-over");

    const tileId = e.dataTransfer.getData("text/plain");
    const tile = this._tileById(tileId);
    if (!tile) return;

    this._place(tile, slot);
  }

  _onDropToBank(e) {
    e.preventDefault();
    const tileId = e.dataTransfer.getData("text/plain");
    const tile = this._tileById(tileId);
    if (!tile) return;
    this.bankTarget.appendChild(tile);
    this._restoreSlotPlaceholderIfNeeded();
    this._clearPicked();
    // Clear slot correctness after moving
    this.slotTargets.forEach((s) => s.classList.remove("tb-match-ok", "tb-match-bad"));
  }

  _tapSlot(slot) {
    if (!this.pickedTile) return;
    this._place(this.pickedTile, slot);
  }

  _pick(tile) {
    // If tile is already in a slot and user taps it, return it to bank.
    const inSlot = tile.closest(".tb-arrange-slot");
    if (inSlot && this.hasBankTarget) {
      this.bankTarget.appendChild(tile);
      this._restoreSlotPlaceholder(inSlot);
      this._clearPicked();
      inSlot.classList.remove("tb-match-ok", "tb-match-bad");
      return;
    }

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
    return this.element.querySelector(`.tb-arrange-tile[data-tile-id="${CSS.escape(id)}"]`);
  }

  _place(tile, slot) {
    // If slot already has a tile, move it back to bank.
    const existing = slot.querySelector(".tb-arrange-tile");
    if (existing && this.hasBankTarget) this.bankTarget.appendChild(existing);

    // Remove placeholder
    this._removePlaceholder(slot);

    slot.appendChild(tile);
    this._clearPicked();

    // Clear correctness marker when user changes placement
    slot.classList.remove("tb-match-ok", "tb-match-bad");
  }

  _removePlaceholder(slot) {
    const ph = slot.querySelector(".tb-arrange-placeholder");
    if (ph) ph.remove();
  }

  _restoreSlotPlaceholder(slot) {
    if (slot.querySelector(".tb-arrange-tile")) return;
    if (slot.querySelector(".tb-arrange-placeholder")) return;
    const span = document.createElement("span");
    span.className = "tb-arrange-placeholder";
    span.textContent = "Drop here (or tap a tile, then tap here)";
    slot.appendChild(span);
  }

  _restoreSlotPlaceholderIfNeeded() {
    this.slotTargets.forEach((slot) => this._restoreSlotPlaceholder(slot));
  }

  check() {
    const expected = (this.answerValue || []).map((x) => (x || "").toString());
    const chosen = this.slotTargets.map((slot) => {
      const tile = slot.querySelector(".tb-arrange-tile");
      return tile ? (tile.dataset.tileId || "").toString() : "";
    });

    let total = this.slotTargets.length;
    let correct = 0;

    this.slotTargets.forEach((slot, idx) => {
      slot.classList.remove("tb-match-ok", "tb-match-bad");
      const got = chosen[idx];
      const want = expected[idx] || "";
      if (got.length === 0) return; // unanswered
      if (want.length > 0 && got === want) {
        correct += 1;
        slot.classList.add("tb-match-ok");
      } else {
        slot.classList.add("tb-match-bad");
      }
    });

    if (total === 0) return this._say("Nothing to check.");

    if (correct === total && expected.length === total) {
      this._say(`Perfect — ${correct}/${total}.`);
    } else {
      this._say(`${correct}/${total} correct. Fix the highlighted slots and try again.`);
    }
  }

  reset() {
    // Move all placed tiles back to bank
    this.slotTargets.forEach((slot) => {
      slot.classList.remove("tb-match-ok", "tb-match-bad");
      const tile = slot.querySelector(".tb-arrange-tile");
      if (tile && this.hasBankTarget) this.bankTarget.appendChild(tile);
      this._restoreSlotPlaceholder(slot);
    });

    this._clearPicked();
    this._say("Reset.");
  }

  _say(msg) {
    if (this.hasFeedbackTarget) this.feedbackTarget.textContent = msg;
  }
}
