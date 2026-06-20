import { Controller } from "@hotwired/stimulus"

// Keeps the large pronunciation registry usable without changing the stored
// preference format. Users choose a family first, then one reading system.
// The hidden `ruby_source` field remains the value submitted to Rails.
export default class extends Controller {
  static targets = ["family", "source", "hidden"]
  static values = {
    groups: Array,
    current: String,
  }

  connect() {
    const current = this.currentValue || this.hiddenTarget.value
    const currentFamily = this._familyForSource(current)
    const fallbackFamily = this.groupsValue[0]?.key || ""

    this.familyTarget.value = currentFamily || fallbackFamily
    this._populateSources(current)

    // Repair an obsolete session value quietly. A later user change will still
    // dispatch the normal form event and autosubmit.
    if (this.sourceTarget.value && this.hiddenTarget.value !== this.sourceTarget.value) {
      this.hiddenTarget.value = this.sourceTarget.value
    }
  }

  changeFamily() {
    this._populateSources(null)
    this._storeSelectedSource()
  }

  changeSource() {
    this._storeSelectedSource()
  }

  _populateSources(preferredKey) {
    const group = this.groupsValue.find((item) => item.key === this.familyTarget.value)
    const sources = group?.sources || []

    this.sourceTarget.replaceChildren(
      ...sources.map((source) => {
        const option = document.createElement("option")
        option.value = source.key
        option.textContent = source.label
        return option
      })
    )

    if (preferredKey && sources.some((source) => source.key === preferredKey)) {
      this.sourceTarget.value = preferredKey
    }
  }

  _storeSelectedSource() {
    const next = this.sourceTarget.value || ""
    if (this.hiddenTarget.value === next) return

    this.hiddenTarget.value = next
    this.hiddenTarget.dispatchEvent(new Event("change", { bubbles: true }))
  }

  _familyForSource(sourceKey) {
    return this.groupsValue.find((group) =>
      (group.sources || []).some((source) => source.key === sourceKey)
    )?.key
  }
}
