import { Controller } from "@hotwired/stimulus"

const STORAGE_KEY = "fanya-site-theme"
const THEMES = new Set(["light", "dark"])

export default class extends Controller {
  static targets = ["button"]

  connect() {
    this.apply(this.currentTheme())
  }

  select(event) {
    const theme = event.params.theme
    if (!THEMES.has(theme)) return

    try {
      window.localStorage.setItem(STORAGE_KEY, theme)
    } catch (_error) {
      // The theme still works for this page when storage is unavailable.
    }

    this.apply(theme)
  }

  currentTheme() {
    const current = document.documentElement.dataset.theme
    if (THEMES.has(current)) return current

    try {
      const stored = window.localStorage.getItem(STORAGE_KEY)
      if (THEMES.has(stored)) return stored
    } catch (_error) {
      // Fall through to the existing light theme.
    }

    return "light"
  }

  apply(theme) {
    const safeTheme = THEMES.has(theme) ? theme : "light"
    document.documentElement.dataset.theme = safeTheme
    document.documentElement.style.colorScheme = safeTheme

    this.buttonTargets.forEach((button) => {
      const active = button.dataset.siteThemeThemeParam === safeTheme
      button.setAttribute("aria-pressed", active ? "true" : "false")
    })
  }
}
