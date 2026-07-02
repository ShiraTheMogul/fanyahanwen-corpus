import { Controller } from "@hotwired/stimulus"

// Keeps the two group selectors aligned with the selected analytical dimension.
// The server still validates every submitted group; this controller only makes
// the prepared-analysis form easier to use.
export default class extends Controller {
  static targets = ["dimension", "left", "right"]

  connect() {
    this.updateDimension()
  }

  updateDimension() {
    const dimension = this.dimensionTarget.value
    this.filterSelect(this.leftTarget, dimension)
    this.filterSelect(this.rightTarget, dimension)
    this.keepDistinct()
  }

  keepDistinct() {
    const dimension = this.dimensionTarget.value
    const leftValue = this.leftTarget.value

    for (const option of this.rightTarget.options) {
      if (!option.value) continue

      const matchesDimension = option.dataset.dimension === dimension
      option.disabled = !matchesDimension || option.value === leftValue
      option.hidden = !matchesDimension
    }

    this.filterOptionGroups(this.rightTarget, dimension)

    if (!this.rightTarget.value || this.rightTarget.selectedOptions[0]?.disabled) {
      this.selectFirstEnabled(this.rightTarget)
    }
  }

  filterSelect(select, dimension) {
    for (const option of select.options) {
      if (!option.value) continue

      const enabled = option.dataset.dimension === dimension
      option.disabled = !enabled
      option.hidden = !enabled
    }

    this.filterOptionGroups(select, dimension)

    if (!select.value || select.selectedOptions[0]?.disabled) {
      this.selectFirstEnabled(select)
    }
  }

  filterOptionGroups(select, dimension) {
    for (const group of select.querySelectorAll("optgroup")) {
      group.hidden = group.dataset.dimension !== dimension
      group.disabled = group.dataset.dimension !== dimension
    }
  }

  selectFirstEnabled(select) {
    const option = Array.from(select.options).find((candidate) => candidate.value && !candidate.disabled)
    select.value = option?.value || ""
  }
}
