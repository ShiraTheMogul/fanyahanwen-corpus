import { Controller } from "@hotwired/stimulus"

// Turns the long Tools page into a small chooser without changing any of the
// existing tool forms. Each old <h2> section becomes one panel, so the tools
// keep their current Rails/Turbo behaviour and their form state when hidden.
export default class extends Controller {
  connect() {
    this.panels = new Map()
    this.boundPopState = () => this.openFromLocation(false)

    this.prepareLegacyTools()
    this.prepareMeasurementConverter()
    this.buildChooser()

    window.addEventListener("popstate", this.boundPopState)
    this.element.dataset.toolsPickerState = "ready"
    this.openFromLocation(false)
  }

  disconnect() {
    window.removeEventListener("popstate", this.boundPopState)
  }

  prepareLegacyTools() {
    const legacy = this.element.querySelector("[data-tools-picker-legacy]")
    if (!legacy) return

    const nodes = Array.from(legacy.childNodes)
    const firstHeadingIndex = nodes.findIndex((node) => node.nodeType === Node.ELEMENT_NODE && node.tagName === "H2")
    if (firstHeadingIndex < 0) return

    const panelHost = this.panelHost()
    let panel = null

    nodes.slice(firstHeadingIndex).forEach((node) => {
      if (node.nodeType === Node.ELEMENT_NODE && node.tagName === "H2") {
        panel = document.createElement("section")
        panel.className = "tools-picker__panel"
        panel.hidden = true
        panelHost.appendChild(panel)
      }

      if (panel) panel.appendChild(node)
    })

    Array.from(panelHost.querySelectorAll(":scope > .tools-picker__panel")).forEach((candidate, index) => {
      const title = candidate.querySelector("h2")?.textContent?.trim() || `Tool ${index + 1}`
      const id = this.identifyLegacyPanel(candidate, index)
      this.registerPanel(id, title, candidate)
    })
  }

  prepareMeasurementConverter() {
    const converter = this.element.querySelector(":scope > .measurement-converter")
    if (!converter) return

    const title = converter.querySelector("h2")?.textContent?.trim() || "Historical measurement converter"
    converter.classList.add("tools-picker__panel")
    converter.hidden = true
    this.panelHost().appendChild(converter)
    this.registerPanel("historical-measurements", title, converter)
  }

  identifyLegacyPanel(panel, index) {
    const markers = [
      ["mandarin_out", "mandarin"],
      ["cantonese_out", "cantonese"],
      ["cangjie_out", "character-data"],
      ["anki_enrich_out", "anki"],
      ["lunar_out", "lunar-calendar"],
      ["numerals_out", "numerals"]
    ]

    for (const [marker, id] of markers) {
      if (panel.querySelector(`#${marker}`)) return id
    }

    return `tool-${index + 1}`
  }

  registerPanel(id, title, panel) {
    let finalId = id
    let suffix = 2
    while (this.panels.has(finalId)) {
      finalId = `${id}-${suffix}`
      suffix += 1
    }

    panel.dataset.toolsPickerPanel = finalId
    panel.setAttribute("aria-labelledby", `tool-card-${finalId}`)
    this.panels.set(finalId, { title, panel })
  }

  panelHost() {
    let host = this.element.querySelector("[data-tools-picker-panels]")
    if (!host) {
      host = document.createElement("div")
      host.dataset.toolsPickerPanels = ""
      this.element.appendChild(host)
    }
    return host
  }

  buildChooser() {
    const legacy = this.element.querySelector("[data-tools-picker-legacy]")
    if (!legacy || this.element.querySelector("[data-tools-picker-grid]")) return

    const grid = document.createElement("div")
    grid.className = "tools-picker__grid"
    grid.dataset.toolsPickerGrid = ""
    grid.setAttribute("aria-label", "Choose a tool")

    const preferredOrder = [
      "historical-measurements",
      "character-data",
      "numerals",
      "lunar-calendar",
      "mandarin",
      "cantonese",
      "anki"
    ]

    const entries = Array.from(this.panels.entries()).sort(([a], [b]) => {
      const ai = preferredOrder.indexOf(a)
      const bi = preferredOrder.indexOf(b)
      const av = ai < 0 ? Number.MAX_SAFE_INTEGER : ai
      const bv = bi < 0 ? Number.MAX_SAFE_INTEGER : bi
      return av - bv
    })

    entries.forEach(([id, entry]) => {
      const button = document.createElement("button")
      button.type = "button"
      button.className = "tools-picker__card"
      button.id = `tool-card-${id}`
      button.dataset.toolId = id
      button.setAttribute("aria-controls", `tool-panel-${id}`)
      button.addEventListener("click", () => this.open(id, true))

      const title = document.createElement("span")
      title.className = "tools-picker__card-title"
      title.textContent = entry.title
      button.appendChild(title)

      entry.panel.id = `tool-panel-${id}`
      grid.appendChild(button)
    })

    const firstToolHeading = legacy.querySelector("h2")
    if (firstToolHeading) {
      legacy.insertBefore(grid, firstToolHeading)
    } else {
      legacy.appendChild(grid)
    }

    const back = document.createElement("button")
    back.type = "button"
    back.className = "tools-picker__back"
    back.dataset.toolsPickerBack = ""
    back.hidden = true
    back.textContent = "← All tools"
    back.addEventListener("click", () => this.showChooser(true))
    this.panelHost().before(back)
  }

  open(id, updateHistory = true) {
    const entry = this.panels.get(id)
    if (!entry) {
      this.showChooser(updateHistory)
      return
    }

    this.panels.forEach(({ panel }) => { panel.hidden = true })
    entry.panel.hidden = false

    const grid = this.element.querySelector("[data-tools-picker-grid]")
    const back = this.element.querySelector("[data-tools-picker-back]")
    if (grid) grid.hidden = true
    if (back) back.hidden = false

    if (updateHistory) {
      history.pushState({ tool: id }, "", `#tool-${encodeURIComponent(id)}`)
    }

    entry.panel.querySelector("input, select, textarea, button")?.focus({ preventScroll: true })
    entry.panel.scrollIntoView({ block: "start", behavior: "smooth" })
  }

  showChooser(updateHistory = true) {
    this.panels.forEach(({ panel }) => { panel.hidden = true })

    const grid = this.element.querySelector("[data-tools-picker-grid]")
    const back = this.element.querySelector("[data-tools-picker-back]")
    if (grid) grid.hidden = false
    if (back) back.hidden = true

    if (updateHistory) {
      history.pushState({}, "", `${window.location.pathname}${window.location.search}`)
    }

    grid?.scrollIntoView({ block: "start", behavior: "smooth" })
  }

  openFromLocation(updateHistory = false) {
    const match = window.location.hash.match(/^#tool-(.+)$/)
    if (!match) {
      this.showChooser(updateHistory)
      return
    }

    const id = decodeURIComponent(match[1])
    if (this.panels.has(id)) this.open(id, updateHistory)
    else this.showChooser(updateHistory)
  }
}
