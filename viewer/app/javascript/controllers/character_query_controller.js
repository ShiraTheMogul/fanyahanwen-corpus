import { Controller } from "@hotwired/stimulus"

// Three dependent dropdowns: language family, then language or branch, then
// the specific reading system or locality.
//
// Genetic family at the top because "Wu" was never a unit a visitor could pick
// and be done with — Wu speakers do not all follow Shanghainese, so the
// locality is the real unit and the branch is only how you reach it. With 408
// localities in the corpus, one flat list is unusable and a single grouped
// list still means scrolling past every family to find yours.
//
// The third dropdown hides itself when a branch offers exactly one system, so
// Japanese or Vietnamese take two choices rather than three.
//
// One controller instance per picker, so the secondary constraint row behaves
// identically to the primary one with no extra code. All instances read the
// same JSON payload, rendered once by the server.
export default class extends Controller {
  static targets = ["family", "branch", "system", "systemWrap", "umlautHelp"]
  static values = { payloadId: String }

  connect() {
    this.payload = this.readPayload()
    this.initial = {
      family: this.familyTarget.dataset.initial || "",
      branch: this.branchTarget.dataset.initial || "",
      system: this.systemTarget.dataset.initial || ""
    }

    if (this.initial.family) this.familyTarget.value = this.initial.family
    this.renderBranches()
  }

  readPayload() {
    const node = document.getElementById(this.payloadIdValue)
    if (!node) return { families: [], branches: {}, systems: {}, singles: {}, labels: {} }
    try {
      return JSON.parse(node.textContent)
    } catch (_error) {
      // A malformed payload must not take the panel down with it. An empty
      // list is recoverable; a throw inside connect() is not.
      return { families: [], branches: {}, systems: {}, singles: {}, labels: {} }
    }
  }

  familyChanged() {
    this.initial.branch = ""
    this.initial.system = ""
    this.renderBranches()
  }

  branchChanged() {
    this.initial.system = ""
    this.renderSystems()
  }

  renderBranches() {
    const family = this.familyTarget.value
    const entries = (this.payload.branches || {})[family] || []
    const select = this.branchTarget
    const previous = select.value

    this.fill(select, entries)
    const wanted = this.initial.branch || previous
    if (wanted && this.hasOption(select, wanted)) select.value = wanted

    this.renderSystems()
  }

  renderSystems() {
    const key = `${this.familyTarget.value}/${this.branchTarget.value}`
    const single = (this.payload.singles || {})[key]
    const select = this.systemTarget

    // One system and no localities: the dropdown would hold a single option,
    // so carry the value on a hidden input instead of asking for a choice
    // that has already been made.
    if (single) {
      select.textContent = ""
      select.appendChild(new Option("", single))
      select.value = single
      this.setSystemVisible(false)
      this.systemChanged()
      return
    }

    this.setSystemVisible(true)

    const groups = (this.payload.systems || {})[key] ||
      { named: [], rime_books: [], common: [], all: [] }
    const labels = this.payload.labels || {}
    const previous = select.value

    select.textContent = ""
    if (select.dataset.includeBlank === "true") {
      select.appendChild(new Option(select.dataset.blankLabel || "", ""))
    }

    const named = groups.named || []
    // Attested books get their own heading and never sit in the same group as
    // the reconstructions. 廣韻 records 徳紅切; Baxter & Sagart say what they
    // think that spelling sounded like. Listing them as peers is what let a
    // reading from one be shown under the authority of the other.
    const rimeBooks = groups.rime_books || []
    const common = groups.common || []
    const all = groups.all || []

    // A branch with nothing commonly consulted simply shows the full list.
    // No notice and no explanation: a heuristic that found nothing is not the
    // visitor's problem.
    if (named.length > 0 && (rimeBooks.length > 0 || common.length > 0 || all.length > 0)) {
      this.appendGroup(select, labels.named, named)
    } else {
      named.forEach((entry) => select.appendChild(this.option(entry)))
    }

    if (rimeBooks.length > 0) this.appendGroup(select, labels.rime_books, rimeBooks)

    if (common.length > 0) {
      this.appendGroup(select, labels.common, common)
      this.appendGroup(select, labels.all, all)
    } else if (named.length > 0 && all.length > 0) {
      this.appendGroup(select, labels.all, all)
    } else {
      all.forEach((entry) => select.appendChild(this.option(entry)))
    }

    const wanted = this.initial.system || previous
    if (wanted && this.hasOption(select, wanted)) select.value = wanted

    this.systemChanged()
  }

  // The v-for-ü affordance only makes sense where ü is a letter distinction,
  // which among these systems is Mandarin. Shown from the payload's list
  // rather than a hardcoded id, so adding another pinyin-toned system needs
  // no change here.
  systemChanged() {
    // Announced so the rime-book panel can react. A book chosen HERE is the
    // source, and the panel must not then ask for a second one — naming two
    // books is the conflict the server warns about, and it should not be
    // possible to walk into it from the interface.
    this.element.dispatchEvent(new CustomEvent("character-query:system-changed", {
      bubbles: true,
      detail: { system: this.systemTarget?.value || "" }
    }))

    if (!this.hasUmlautHelpTarget) return

    const pinyin = this.payload.pinyin_systems || []
    this.umlautHelpTarget.hidden = !pinyin.includes(this.systemTarget.value)
  }

  setSystemVisible(visible) {
    if (!this.hasSystemWrapTarget) return
    this.systemWrapTarget.hidden = !visible
  }

  // Entries are [label, value, hint]. The hint becomes the option's title, so
  // the romanisation is there on hover without spending label width on it.
  option([text, value, hint]) {
    const option = new Option(text, value)
    if (hint) option.title = hint
    return option
  }

  fill(select, entries) {
    select.textContent = ""
    entries.forEach((entry) => select.appendChild(this.option(entry)))
  }

  appendGroup(select, label, entries) {
    if (entries.length === 0) return

    const group = document.createElement("optgroup")
    group.label = label || ""
    entries.forEach((entry) => group.appendChild(this.option(entry)))
    select.appendChild(group)
  }

  hasOption(select, value) {
    return Array.from(select.querySelectorAll("option")).some((option) => option.value === value)
  }
}
