import { Controller } from "@hotwired/stimulus"

// app/javascript/controllers/daily_reading_controller.js
//
// Simple dialog toggle for the header "今日誦詩" button.
//
// Reusable pattern:
//   - Put data-controller="daily-reading" on the toggle button.
//   - Put data-daily-reading-target="dialog" on the dialog container.
//   - Add data-action="daily-reading#toggle" on the button.
//
export default class extends Controller {
  static targets = ["dialog"]

  connect() {
    // Close on Escape.
    this._onKeyDown = (e) => {
      if (e.key === "Escape") this.close()
    }
    document.addEventListener("keydown", this._onKeyDown)
  }

  disconnect() {
    document.removeEventListener("keydown", this._onKeyDown)
  }

  toggle() {
    if (this.dialogTarget.hidden) {
      this.open()
    } else {
      this.close()
    }
  }

  open() {
    this.dialogTarget.hidden = false
    this.element.setAttribute("aria-expanded", "true")
  }

  close() {
    this.dialogTarget.hidden = true
    this.element.setAttribute("aria-expanded", "false")
  }
}
