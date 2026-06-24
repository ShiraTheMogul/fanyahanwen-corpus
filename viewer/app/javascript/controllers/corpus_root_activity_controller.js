import { Controller } from "@hotwired/stimulus"

// Uses one <details> element for both responsive layouts.
// Wide screens keep it open beside the root folder list.
// Narrow screens reset it to a collapsed disclosure above the list.
export default class extends Controller {
  connect() {
    this.desktopQuery = window.matchMedia("(min-width: 1101px)")
    this.handleViewportChange = this.handleViewportChange.bind(this)

    this.applyViewportMode()

    if (this.desktopQuery.addEventListener) {
      this.desktopQuery.addEventListener("change", this.handleViewportChange)
    } else {
      this.desktopQuery.addListener(this.handleViewportChange)
    }
  }

  disconnect() {
    if (!this.desktopQuery) return

    if (this.desktopQuery.removeEventListener) {
      this.desktopQuery.removeEventListener("change", this.handleViewportChange)
    } else {
      this.desktopQuery.removeListener(this.handleViewportChange)
    }
  }

  handleViewportChange() {
    this.applyViewportMode()
  }

  applyViewportMode() {
    this.element.open = this.desktopQuery.matches
  }
}
