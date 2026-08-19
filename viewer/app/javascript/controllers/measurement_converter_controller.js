import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "catalogue", "category", "period", "limitPeriod", "standard", "input", "sourceUnit",
    "units", "comparisons", "result", "correspondence", "references", "sourcesSummary"
  ]

  connect() {
    this.catalogue = JSON.parse(this.catalogueTarget.textContent)
    this.selectedUnits = new Set()
    this.selectedComparisons = new Set()
    this.selectedDefinitions = {}
    this.currentUnitGroups = {}
    this.lastParseReferenceIds = []
    this.defaultComparisons = {
      length: ["m", "cm", "foot", "inch"],
      area: ["square_metre", "hectare", "acre"],
      mass: ["kg", "g", "lb", "oz"],
      capacity: ["litre", "millilitre", "imperial_pint", "us_pint"],
      time: ["hour_si", "minute_si", "second_si"]
    }
    this.genericFallbackUnits = new Set([
      "hu_length", "hao_length", "li_small_length", "fen_length", "cun", "chi", "zhang", "yin",
      "zhu", "liang_mass", "jin", "qian_mass", "fen_mass", "li_mass", "hao_mass",
      "gui_capacity", "chao_capacity", "cuo", "shao", "he", "sheng", "dou_capacity", "hu_capacity",
      "ri", "hour", "minute", "second"
    ])

    this.renderCategoryOptions()
    this.renderPeriodOptions()
    this.categoryTarget.value = this.catalogue.categories[0]?.id || "length"
    this.periodTarget.value = this.catalogue.periods.find((period) => period.default)?.id || "all"
    this.selectedComparisons = new Set(this.defaultComparisons[this.categoryTarget.value] || [])
    this.rebuild(true, true)
  }

  categoryChanged() {
    this.selectedComparisons = new Set(this.defaultComparisons[this.categoryTarget.value] || [])
    this.selectedDefinitions = {}
    this.inputTarget.value = ""
    this.rebuild(true, true)
  }

  periodChanged() {
    this.selectedDefinitions = {}
    this.rebuild(true, false)
  }

  periodLimitChanged() {
    this.selectedDefinitions = {}
    this.rebuild(true, false)
  }

  standardChanged() {
    this.selectedDefinitions = {}
    this.rebuild(false, false, true)
  }

  selectAllUnits() {
    Object.keys(this.currentUnitGroups).forEach((unitId) => {
      if (this.currentUnitGroups[unitId].some((group) => group.factor !== null)) this.selectedUnits.add(unitId)
    })
    this.renderUnits(false)
    this.calculate()
  }

  clearUnits() {
    this.selectedUnits.clear()
    this.renderUnits(false)
    this.calculate()
  }

  selectAllComparisons() {
    this.comparisonsForCategory().forEach((unit) => this.selectedComparisons.add(unit.id))
    this.renderComparisons()
    this.calculate()
  }

  clearComparisons() {
    this.selectedComparisons.clear()
    this.renderComparisons()
    this.calculate()
  }

  rebuild(resetStandard = false, resetComparisons = false, resetUnits = false) {
    this.renderStandards(resetStandard)
    this.renderUnits(resetUnits || resetStandard)
    this.renderSourceUnits()
    if (resetComparisons) this.selectedComparisons = new Set(this.defaultComparisons[this.categoryTarget.value] || [])
    this.renderComparisons()
    this.calculate()
  }

  renderCategoryOptions() {
    this.categoryTarget.innerHTML = this.catalogue.categories
      .map((category) => `<option value="${this.escapeAttr(category.id)}">${this.escapeHtml(category.label)}</option>`)
      .join("")
  }

  renderPeriodOptions() {
    this.periodTarget.innerHTML = this.catalogue.periods
      .map((period) => {
        const dates = period.dates ? ` — ${period.dates}` : ""
        return `<option value="${this.escapeAttr(period.id)}">${this.escapeHtml(period.label + dates)}</option>`
      })
      .join("")
  }

  standardsForCurrentScope() {
    const category = this.categoryTarget.value
    const period = this.periodTarget.value
    const limited = this.limitPeriodTarget.checked && period !== "all"
    const categoryStandards = this.catalogue.standards.filter((standard) => standard.category === category)

    if (!limited) return categoryStandards

    const family = this.periodFamily(period)
    const exact = categoryStandards.filter((standard) => standard.period === period)
    const compatible = categoryStandards.filter((standard) => {
      if (exact.includes(standard)) return false
      const periods = standard.periods || [standard.period]
      return periods.some((candidate) => family.includes(candidate))
    })
    return [...exact, ...compatible]
  }

  renderStandards(forceFirst = false) {
    const previous = this.standardTarget.value
    const standards = this.standardsForCurrentScope()
    this.standardTarget.innerHTML = standards
      .map((standard) => `<option value="${this.escapeAttr(standard.id)}">${this.escapeHtml(standard.label)}</option>`)
      .join("")

    if (!forceFirst && standards.some((standard) => standard.id === previous)) {
      this.standardTarget.value = previous
    } else if (standards[0]) {
      this.standardTarget.value = standards[0].id
    }

    this.standardTarget.disabled = standards.length === 0
  }

  currentStandard() {
    return this.catalogue.standards.find((standard) => standard.id === this.standardTarget.value) || null
  }

  currentCategory() {
    return this.catalogue.categories.find((item) => item.id === this.categoryTarget.value) || null
  }

  periodFamily(periodId) {
    const families = {
      qin_han: ["qin_han", "han", "eastern_han"],
      han: ["han", "qin_han"],
      eastern_han: ["eastern_han", "han", "qin_han"],
      three_kingdoms: ["three_kingdoms"],
      jin: ["jin"],
      southern_dynasties: ["southern_dynasties"],
      northern_dynasties: ["northern_dynasties"],
      tang: ["tang"],
      song: ["song"],
      ming: ["ming"],
      qing: ["qing"],
      roc_1915: ["roc_1915"],
      roc_1930: ["roc_1930"],
      zhou: ["zhou"]
    }
    return families[periodId] || [periodId]
  }

  claimsForUnit(unitId, unit) {
    const claims = unit.claims || []
    const period = this.periodTarget.value
    if (!this.limitPeriodTarget.checked || period === "all") return { claims, fallback: false }

    const family = this.periodFamily(period)
    const specific = claims.filter((claim) => (claim.periods || []).some((candidate) => family.includes(candidate)))
    if (specific.length > 0) return { claims: specific, fallback: false }

    if (this.genericFallbackUnits.has(unitId)) {
      const generic = claims.filter((claim) => (claim.periods || []).includes("all"))
      if (generic.length > 0) return { claims: generic, fallback: true }
    }

    return { claims: [], fallback: false }
  }

  groupClaims(unitId, unit) {
    const scoped = this.claimsForUnit(unitId, unit)
    const standard = this.currentStandard()
    const groups = new Map()

    scoped.claims.forEach((claim) => {
      const key = claim.factor === null ? `info:${claim.note || claim.authority}` : this.factorKey(claim.factor)
      if (!groups.has(key)) {
        groups.set(key, {
          key,
          factor: claim.factor,
          status: claim.status,
          authorities: [],
          referenceIds: [],
          notes: [],
          fallback: scoped.fallback
        })
      }
      const group = groups.get(key)
      if (claim.authority && !group.authorities.includes(claim.authority)) group.authorities.push(claim.authority)
      ;(claim.reference_ids || []).forEach((referenceId) => {
        if (!group.referenceIds.includes(referenceId)) group.referenceIds.push(referenceId)
      })
      if (claim.note && !group.notes.includes(claim.note)) group.notes.push(claim.note)
    })

    if (scoped.fallback && standard) {
      groups.forEach((group) => {
        group.referenceIds = Array.from(new Set([...(standard.reference_ids || []), ...group.referenceIds]))
      })
    }

    return Array.from(groups.values())
  }

  factorKey(value) {
    return Number(value).toPrecision(14)
  }

  factorLabel(factor) {
    const category = this.currentCategory()
    if (factor === null) return "Reference only"
    return `${this.formatNumber(factor)} ${category?.base_label || "base units"}`
  }

  renderUnits(resetToRecommendations = false) {
    const category = this.categoryTarget.value
    const standard = this.currentStandard()
    const units = Object.entries(this.catalogue.units).filter(([, unit]) => unit.category === category)
    const visible = []
    this.currentUnitGroups = {}

    units.forEach(([unitId, unit]) => {
      const groups = this.groupClaims(unitId, unit)
      if (groups.length === 0) return
      this.currentUnitGroups[unitId] = groups
      visible.push([unitId, unit, groups])
    })

    if (resetToRecommendations) {
      const simpleDefaults = {
        length: ["zhang", "chi", "cun"],
        area: ["qing_area", "mu", "fangchi"],
        mass: ["jin", "liang_mass", "qian_mass"],
        capacity: ["dou_capacity", "sheng", "he"],
        time: ["ri", "shichen", "ke"]
      }
      const recommended = (standard?.recommended_units || []).filter((unitId) => this.currentUnitGroups[unitId])
      const simple = (simpleDefaults[category] || []).filter((unitId) => recommended.includes(unitId))
      this.selectedUnits = new Set(simple.length > 0 ? simple : recommended)
    } else {
      this.selectedUnits = new Set(Array.from(this.selectedUnits).filter((unitId) => this.currentUnitGroups[unitId]))
    }

    visible.forEach(([unitId, , groups]) => {
      const defaultFactor = standard?.definition_defaults?.[unitId]
      if (defaultFactor !== undefined) {
        const matching = groups.find((group) => group.factor !== null && Math.abs(group.factor - defaultFactor) < 1e-12)
        if (matching) this.selectedDefinitions[unitId] = matching.key
      }
      if (!this.selectedDefinitions[unitId] || !groups.some((group) => group.key === this.selectedDefinitions[unitId])) {
        const firstConvertible = groups.find((group) => group.factor !== null)
        this.selectedDefinitions[unitId] = (firstConvertible || groups[0])?.key
      }
    })

    this.unitsTarget.innerHTML = visible.map(([unitId, unit, groups]) => this.unitCardHtml(unitId, unit, groups)).join("")

    this.unitsTarget.querySelectorAll("input[data-unit-id]").forEach((checkbox) => {
      checkbox.addEventListener("change", (event) => {
        const id = event.currentTarget.dataset.unitId
        if (event.currentTarget.checked) this.selectedUnits.add(id)
        else this.selectedUnits.delete(id)
        this.calculate()
      })
    })

    this.unitsTarget.querySelectorAll("select[data-definition-unit-id]").forEach((select) => {
      select.addEventListener("change", (event) => {
        const id = event.currentTarget.dataset.definitionUnitId
        this.selectedDefinitions[id] = event.currentTarget.value
        this.refreshAuthorityText(id)
        this.renderSourceUnits()
        this.calculate()
      })
    })
  }

  unitCardHtml(unitId, unit, groups) {
    const convertible = groups.filter((group) => group.factor !== null)
    const information = groups.filter((group) => group.factor === null)
    const selectedKey = this.selectedDefinitions[unitId]
    const selected = groups.find((group) => group.key === selectedKey) || groups[0]
    const checked = this.selectedUnits.has(unitId) && convertible.length > 0
    const checkbox = convertible.length > 0
      ? `<input type="checkbox" data-unit-id="${this.escapeAttr(unitId)}" ${checked ? "checked" : ""}>`
      : `<input type="checkbox" disabled>`

    let definitionHtml = ""
    if (convertible.length > 1) {
      definitionHtml = `<select data-definition-unit-id="${this.escapeAttr(unitId)}">${convertible.map((group) => {
        const chosen = group.key === selectedKey ? " selected" : ""
        const sourceCount = group.referenceIds.length
        return `<option value="${this.escapeAttr(group.key)}"${chosen}>${this.escapeHtml(this.relationshipText(unit, group.factor))} — ${sourceCount} source${sourceCount === 1 ? "" : "s"}</option>`
      }).join("")}</select>`
    } else if (convertible.length === 1) {
      definitionHtml = `<div class="measurement-converter__subtle">${this.escapeHtml(this.relationshipText(unit, convertible[0].factor))}</div>`
    }

    const notes = Array.from(new Set([...(selected?.notes || []), ...information.flatMap((group) => group.notes || [])]))
    const authority = selected?.authorities?.join("; ") || information.flatMap((group) => group.authorities || []).join("; ")
    const noteHtml = notes.length > 0 ? `<small class="measurement-converter__authority">${this.escapeHtml(notes.join(" "))}</small>` : ""

    return `<div class="measurement-converter__unit">
      <label>${checkbox}<strong>${this.escapeHtml(unit.han)}</strong> <span>(${this.escapeHtml(unit.romanisation)})</span></label>
      ${definitionHtml}
      <small class="measurement-converter__authority" data-authority-unit-id="${this.escapeAttr(unitId)}">${this.escapeHtml(authority)}</small>
      ${noteHtml}
    </div>`
  }

  refreshAuthorityText(unitId) {
    const group = this.selectedGroup(unitId)
    const node = this.unitsTarget.querySelector(`[data-authority-unit-id="${CSS.escape(unitId)}"]`)
    if (node && group) node.textContent = group.authorities.join("; ")
  }

  selectedGroup(unitId) {
    const groups = this.currentUnitGroups[unitId] || []
    const key = this.selectedDefinitions[unitId]
    return groups.find((group) => group.key === key) || groups.find((group) => group.factor !== null) || groups[0] || null
  }

  renderSourceUnits() {
    const previous = this.sourceUnitTarget.value
    const historicalRows = Object.entries(this.currentUnitGroups)
      .map(([unitId]) => [unitId, this.catalogue.units[unitId], this.selectedGroup(unitId)])
      .filter(([, , group]) => group && group.factor !== null)
      .sort((a, b) => b[2].factor - a[2].factor)

    const historicalOptions = historicalRows.map(([unitId, unit]) =>
      `<option value="historical:${this.escapeAttr(unitId)}">${this.escapeHtml(unit.han)} (${this.escapeHtml(unit.romanisation)})</option>`
    ).join("")

    const comparisonOptions = this.comparisonsForCategory().map((unit) =>
      `<option value="comparison:${this.escapeAttr(unit.id)}">${this.escapeHtml(unit.label)} (${this.escapeHtml(unit.symbol)})</option>`
    ).join("")

    this.sourceUnitTarget.innerHTML = `${historicalOptions ? `<optgroup label="Chinese units">${historicalOptions}</optgroup>` : ""}${comparisonOptions ? `<optgroup label="Modern and comparison units">${comparisonOptions}</optgroup>` : ""}`

    const standard = this.currentStandard()
    const preferredHistorical = [standard?.base_unit, ...(standard?.recommended_units || [])]
      .find((candidate) => candidate && historicalRows.some(([unitId]) => unitId === candidate))
    const preferred = [previous, preferredHistorical ? `historical:${preferredHistorical}` : null]
      .find((candidate) => candidate && Array.from(this.sourceUnitTarget.options).some((option) => option.value === candidate))
    if (preferred) this.sourceUnitTarget.value = preferred
  }

  comparisonsForCategory() {
    return this.catalogue.comparison_units.filter((unit) => unit.category === this.categoryTarget.value)
  }

  comparisonById(id) {
    return this.catalogue.comparison_units.find((unit) => unit.id === id) || null
  }

  renderComparisons() {
    const groups = new Map()
    this.comparisonsForCategory().forEach((unit) => {
      if (!groups.has(unit.system)) groups.set(unit.system, [])
      groups.get(unit.system).push(unit)
    })

    this.comparisonsTarget.innerHTML = Array.from(groups.entries()).map(([system, units]) => {
      const items = units.map((unit) => `<label style="display:inline-block; min-width:12rem; margin:0 0.8rem 0.35rem 0;">
        <input type="checkbox" data-comparison-id="${this.escapeAttr(unit.id)}" ${this.selectedComparisons.has(unit.id) ? "checked" : ""}>
        ${this.escapeHtml(unit.label)} (${this.escapeHtml(unit.symbol)})
      </label>`).join("")
      return `<details><summary>${this.escapeHtml(system)}</summary><div>${items}</div></details>`
    }).join("") || `<p class="measurement-converter__subtle">No comparison units are available for this measure yet.</p>`

    this.comparisonsTarget.querySelectorAll("input[data-comparison-id]").forEach((checkbox) => {
      checkbox.addEventListener("change", (event) => {
        const id = event.currentTarget.dataset.comparisonId
        if (event.currentTarget.checked) this.selectedComparisons.add(id)
        else this.selectedComparisons.delete(id)
        this.calculate()
      })
    })
  }

  calculate() {
    const standard = this.currentStandard()
    if (!standard) {
      this.resultTarget.innerHTML = `<p class="measurement-converter__error">No standard is available for this period and measure. Untick the period filter to see the full list.</p>`
      this.referencesTarget.innerHTML = ""
      this.correspondenceTarget.textContent = ""
      this.updateSourcesSummary([])
      return
    }

    if (this.categoryTarget.value === "construction") {
      this.renderConstructionResult(standard)
      return
    }

    const raw = String(this.inputTarget.value || "").trim()
    if (!raw) {
      this.resultTarget.innerHTML = `<p class="measurement-converter__subtle">Enter a measurement above.</p>`
      this.correspondenceTarget.textContent = ""
      this.renderReferences([])
      return
    }

    try {
      const totalBase = this.parseQuantity(raw, standard)
      if (!Number.isFinite(totalBase)) throw new Error("The measurement could not be converted using this standard.")

      const selectedRows = this.selectedHistoricalRows()
      const naturalRows = this.naturalExpressionRows(selectedRows)
      const compound = this.formatCompound(totalBase, naturalRows)
      const comparisonRows = this.selectedComparisonRows(standard, totalBase)
      const referenceIds = this.collectReferenceIds(standard, selectedRows, comparisonRows)

      this.resultTarget.innerHTML = this.resultHtml(standard, totalBase, compound, selectedRows, comparisonRows)
      this.renderReferences(referenceIds)
      this.renderCorrespondence(standard, totalBase, compound, selectedRows, comparisonRows, referenceIds)
    } catch (error) {
      this.resultTarget.innerHTML = `<p class="measurement-converter__error">${this.escapeHtml(error.message)}</p>`
      this.correspondenceTarget.textContent = ""
      this.renderReferences(this.baseReferenceIds(standard))
    }
  }

  selectedHistoricalRows() {
    return Array.from(this.selectedUnits)
      .map((unitId) => ({ unitId, unit: this.catalogue.units[unitId], group: this.selectedGroup(unitId) }))
      .filter((row) => row.unit && row.group && row.group.factor !== null)
  }

  naturalExpressionRows(selectedRows) {
    const preferredByCategory = {
      length: ["zhang", "chi", "cun"],
      area: ["qing_area", "mu", "fangbu", "fangchi", "fangcun"],
      mass: ["jin", "liang_mass", "qian_mass"],
      capacity: ["dou_capacity", "sheng", "he"],
      time: ["ri", "shichen", "ke", "hour", "minute", "second"]
    }
    const preferred = preferredByCategory[this.categoryTarget.value] || []
    const available = preferred.map((id) => {
      const unit = this.catalogue.units[id]
      const group = this.selectedGroup(id)
      return unit && group && group.factor !== null ? { unitId: id, unit, group } : null
    }).filter(Boolean)
    if (available.length > 0) return available
    return selectedRows
  }

  resultHtml(standard, totalBase, compound, selectedRows, comparisonRows) {
    const category = this.currentCategory()
    const main = compound || `${this.formatNumber(totalBase)} ${category?.base_label || ""}`
    const absoluteNote = standard.base_si === null
      ? `<p class="measurement-converter__note">This source tells us how the Chinese units relate to each other, but not their exact modern size. Choose a standard with a metric estimate if you need metres, feet, kilograms, litres, or seconds.</p>`
      : ""

    const historicalTable = selectedRows.length
      ? `<h4>Same measurement in other Chinese units</h4>${this.historicalTableHtml(totalBase, selectedRows)}`
      : ""
    const comparisonSummary = comparisonRows.length ? this.comparisonSummaryHtml(standard, totalBase, comparisonRows) : ""
    const comparisonTable = comparisonRows.length
      ? `<h4>Modern equivalents</h4>${comparisonSummary}${this.comparisonTableHtml(comparisonRows)}`
      : ""

    return `
      <div class="measurement-converter__result-main"><strong>${this.escapeHtml(main)}</strong></div>
      <div class="measurement-converter__result-subtitle">Using: ${this.escapeHtml(standard.label)}</div>
      ${absoluteNote}
      ${comparisonTable}
      ${historicalTable}
    `
  }

  comparisonSummaryHtml(standard, totalBase, rows) {
    if (standard.base_si === null) return ""
    const totalSi = totalBase * standard.base_si
    const bits = []
    const find = (id) => rows.find((row) => row.id === id)

    if (this.categoryTarget.value === "length") {
      const metre = find("m")
      if (metre) bits.push(`${this.formatNumber(totalSi, 6)} m`)
      const foot = find("foot")
      const inch = find("inch")
      if (foot && inch) {
        const sign = totalSi < 0 ? "−" : ""
        const totalInches = Math.abs(totalSi) / 0.0254
        const feet = Math.floor(totalInches / 12)
        const inches = totalInches - feet * 12
        bits.push(`${sign}${feet} ft ${this.formatNumber(inches, 4)} in`)
      }
    } else if (this.categoryTarget.value === "mass") {
      const kg = find("kg")
      if (kg) bits.push(`${this.formatNumber(totalSi, 6)} kg`)
      const lb = find("lb")
      const oz = find("oz")
      if (lb && oz) {
        const sign = totalSi < 0 ? "−" : ""
        const totalOunces = Math.abs(totalSi) / 0.028349523125
        const pounds = Math.floor(totalOunces / 16)
        const ounces = totalOunces - pounds * 16
        bits.push(`${sign}${pounds} lb ${this.formatNumber(ounces, 4)} oz`)
      }
    } else if (this.categoryTarget.value === "capacity") {
      const litre = find("litre")
      if (litre) bits.push(`${this.formatNumber(totalSi, 6)} L`)
    } else if (this.categoryTarget.value === "area") {
      const squareMetre = find("square_metre")
      if (squareMetre) bits.push(`${this.formatNumber(totalSi, 6)} m²`)
    } else if (this.categoryTarget.value === "time") {
      const seconds = totalSi
      const sign = seconds < 0 ? "−" : ""
      let remaining = Math.abs(seconds)
      const hours = Math.floor(remaining / 3600)
      remaining -= hours * 3600
      const minutes = Math.floor(remaining / 60)
      remaining -= minutes * 60
      bits.push(`${sign}${hours} h ${minutes} min ${this.formatNumber(remaining, 4)} s`)
    }

    return bits.length ? `<p><strong>${bits.map((bit) => this.escapeHtml(bit)).join(" · ")}</strong></p>` : ""
  }

  historicalTableHtml(totalBase, rows) {
    const sorted = [...rows].sort((a, b) => b.group.factor - a.group.factor)
    const body = sorted.map((row) => {
      const han = row.unit.han.split("/")[0].trim()
      return `<tr>
        <td><strong>${this.escapeHtml(han)}</strong> <span class="measurement-converter__subtle">(${this.escapeHtml(row.unit.romanisation)})</span></td>
        <td>${this.escapeHtml(this.relationshipText(row.unit, row.group.factor))}</td>
        <td class="measurement-converter__equivalent">${this.escapeHtml(this.formatNumber(totalBase / row.group.factor))} ${this.escapeHtml(han)}</td>
      </tr>`
    }).join("")
    return `<div class="measurement-converter__table-wrap"><table class="measurement-converter__table">
      <thead><tr><th>Unit</th><th>Relationship</th><th>Equivalent</th></tr></thead>
      <tbody>${body}</tbody>
    </table></div>`
  }

  relationshipText(unit, factor) {
    const base = this.currentCategory()?.base_label || "base unit"
    const han = unit.han.split("/")[0].trim()
    if (Math.abs(factor - 1) < 1e-12) return `1 ${han} = 1 ${base}`
    return `1 ${han} = ${this.formatNumber(factor)} ${base}`
  }

  comparisonTableHtml(rows) {
    if (this.categoryTarget.value === "time") {
      const modern = rows.map((row) => `${row.value} ${row.symbol}`)
      const body = modern.map((value) => `<tr><td>${this.escapeHtml(value)}</td></tr>`).join("")
      return `<div class="measurement-converter__table-wrap"><table class="measurement-converter__table">
        <thead><tr><th>Modern</th></tr></thead>
        <tbody>${body}</tbody>
      </table></div>`
    }

    const metricRows = rows.filter((row) => row.system === "SI / metric" || row.system === "SI")
    const imperialRows = rows.filter((row) => row.system.startsWith("British"))
    const usRows = rows.filter((row) => row.system.startsWith("U.S."))
    const used = new Set([...metricRows, ...imperialRows, ...usRows].map((row) => row.id))
    const otherRows = rows.filter((row) => !used.has(row.id))

    const metric = this.comparisonColumnValues(metricRows, "metric")
    const imperial = this.comparisonColumnValues(imperialRows, "imperial")
    const us = this.comparisonColumnValues(usRows, "us")
    const columns = [
      ["Metric", metric],
      ["Imperial", imperial],
      ...(us.length ? [["U.S.", us]] : [])
    ].filter(([, values]) => values.length)

    let html = ""
    if (columns.length) {
      const rowCount = Math.max(...columns.map(([, values]) => values.length))
      const head = columns.map(([label]) => `<th>${this.escapeHtml(label)}</th>`).join("")
      const body = Array.from({ length: rowCount }, (_, index) => `<tr>${columns.map(([, values]) => `<td class="measurement-converter__equivalent">${values[index] ? this.escapeHtml(values[index]) : ""}</td>`).join("")}</tr>`).join("")
      html += `<div class="measurement-converter__table-wrap"><table class="measurement-converter__table">
        <thead><tr>${head}</tr></thead>
        <tbody>${body}</tbody>
      </table></div>`
    }

    if (otherRows.length) {
      const otherBody = otherRows.map((row) => `<tr>
        <td>${this.escapeHtml(row.label)}</td>
        <td class="measurement-converter__equivalent">${this.escapeHtml(row.value)} ${this.escapeHtml(row.symbol)}</td>
      </tr>`).join("")
      html += `<h5>Other selected units</h5><div class="measurement-converter__table-wrap"><table class="measurement-converter__table">
        <thead><tr><th>Unit</th><th>Equivalent</th></tr></thead>
        <tbody>${otherBody}</tbody>
      </table></div>`
    }

    return html
  }

  comparisonColumnValues(rows, kind) {
    const byId = (id) => rows.find((row) => row.id === id)
    const skip = new Set()
    const values = []

    if (this.categoryTarget.value === "length" && kind === "imperial") {
      const foot = byId("foot")
      const inch = byId("inch")
      if (foot && inch) {
        const totalInches = Math.abs(Number(inch.value))
        const feet = Math.floor(totalInches / 12)
        const inches = totalInches - feet * 12
        const sign = Number(inch.value) < 0 ? "−" : ""
        values.push(`${sign}${feet} ft ${this.formatNumber(inches, 4)} in`)
        values.push(`${inch.value} ${inch.symbol}`)
        skip.add("foot")
        skip.add("inch")
      }
    }

    if (this.categoryTarget.value === "mass" && kind === "imperial") {
      const lb = byId("lb")
      const oz = byId("oz")
      if (lb && oz) {
        const totalOunces = Math.abs(Number(oz.value))
        const pounds = Math.floor(totalOunces / 16)
        const ounces = totalOunces - pounds * 16
        const sign = Number(oz.value) < 0 ? "−" : ""
        values.push(`${sign}${pounds} lb ${this.formatNumber(ounces, 4)} oz`)
        values.push(`${oz.value} ${oz.symbol}`)
        skip.add("lb")
        skip.add("oz")
      }
    }

    rows.forEach((row) => {
      if (!skip.has(row.id)) values.push(`${row.value} ${row.symbol}`)
    })
    return values
  }

  renderConstructionResult(standard) {
    const rows = Object.entries(this.currentUnitGroups).map(([unitId]) => ({
      unitId,
      unit: this.catalogue.units[unitId],
      group: this.selectedGroup(unitId)
    }))
    this.resultTarget.innerHTML = `<p class="measurement-converter__note">These are wall-building modules with dimensions, so they are shown as definitions instead of being forced into one length.</p>` +
      rows.map((row) => `<p><strong>${this.escapeHtml(row.unit.han)} (${this.escapeHtml(row.unit.romanisation)})</strong>: ${this.escapeHtml((row.group?.notes || []).join(" "))}</p>`).join("")
    const refs = Array.from(new Set([...this.baseReferenceIds(standard), ...rows.flatMap((row) => row.group?.referenceIds || [])]))
    this.renderReferences(refs)
    this.correspondenceTarget.textContent = rows.map((row) => `${row.unit.han}: ${(row.group?.notes || []).join(" ")}`).join("\n") + this.referenceText(refs)
  }

  parseQuantity(raw, standard) {
    const input = this.normaliseMeasurementShorthand(String(raw || "").trim())
    if (!input) throw new Error("Enter a measurement.")
    this.lastParseReferenceIds = []

    if (/^[+-]?\d+(?:\.\d+)?$/.test(input)) {
      const selected = this.sourceUnitTarget.value
      const [kind, id] = selected.split(":", 2)
      if (kind === "historical") {
        const group = this.selectedGroup(id)
        if (!group || group.factor === null) throw new Error("Choose a usable unit for the number.")
        this.lastParseReferenceIds = [...(group.referenceIds || [])]
        return Number(input) * group.factor
      }
      if (kind === "comparison") {
        const comparison = this.comparisonById(id)
        if (!comparison) throw new Error("Choose a usable unit for the number.")
        if (standard.base_si === null) throw new Error("This standard has no exact modern size, so a modern measurement cannot be converted into it.")
        this.lastParseReferenceIds = [...(comparison.reference_ids || [])]
        return Number(input) * comparison.to_si / standard.base_si
      }
      throw new Error("Choose a unit for the number.")
    }

    const aliases = this.aliasMap()
    const aliasNames = Array.from(aliases.keys()).sort((a, b) => b.length - a.length)
    if (aliasNames.length === 0) throw new Error("No recognised units are available for this measure.")

    const numberPattern = "(?:[+-]?\\d+(?:\\.\\d+)?|[零〇一二三四五六七八九十百千萬万億亿廿卅卌]+)"
    const aliasPattern = aliasNames.map((alias) => this.escapeRegExp(alias)).join("|")
    const regex = new RegExp(`(${numberPattern})\\s*(${aliasPattern})(?=\\s|$|[0-9零〇一二三四五六七八九十百千萬万億亿廿卅卌])`, "giu")
    let totalBase = 0
    let matched = false
    let residue = input
    let match
    const refs = new Set()

    while ((match = regex.exec(input)) !== null) {
      matched = true
      const numeric = this.parseNumberToken(match[1])
      if (!Number.isFinite(numeric)) throw new Error(`Could not read the number “${match[1]}”.`)
      const alias = match[2].toLowerCase()
      const candidates = aliases.get(alias) || []
      if (candidates.length !== 1) throw new Error(`“${match[2]}” could mean more than one unit. Use the Han character or a more specific abbreviation.`)
      const candidate = candidates[0]
      if (candidate.kind === "historical") {
        totalBase += numeric * candidate.factor
        ;(candidate.referenceIds || []).forEach((id) => refs.add(id))
      } else {
        if (standard.base_si === null) throw new Error(`This standard has no exact modern size, so “${match[2]}” cannot be converted into it.`)
        totalBase += numeric * candidate.toSi / standard.base_si
        ;(candidate.referenceIds || []).forEach((id) => refs.add(id))
      }
      residue = residue.replace(match[0], " ")
    }

    residue = residue.replace(/[\s+,，;；]+/g, "")
    if (!matched || residue.length > 0) throw new Error(`I could not read the whole measurement${residue ? `; unrecognised text: ${residue}` : ""}.`)
    this.lastParseReferenceIds = Array.from(refs)
    return totalBase
  }

  normaliseMeasurementShorthand(raw) {
    let input = String(raw || "").trim()

    // Common typographic forms for feet and inches.
    input = input
      .replace(/([+-]?\d+(?:\.\d+)?)\s*[’‘′']/g, "$1ft")
      .replace(/([+-]?\d+(?:\.\d+)?)\s*[“”″"]/g, "$1in")

    // Common omitted secondary units: 5ft7 = 5 ft 7 in; 1m75 = 1 m 75 cm.
    // Keep this deliberately narrow so ordinary unit parsing never has to guess.
    input = input
      .replace(/([+-]?\d+(?:\.\d+)?)\s*ft\s*([+-]?\d+(?:\.\d+)?)(?!\d|\s*[A-Za-z])/gi, "$1ft$2in")
      .replace(/([+-]?\d+(?:\.\d+)?)\s*m\s*([+-]?\d+(?:\.\d+)?)(?!\d|\s*[A-Za-z])/g, "$1m$2cm")

    return input
  }

  aliasMap() {
    const map = new Map()
    const add = (alias, value) => {
      const key = String(alias || "").trim().toLowerCase()
      if (!key) return
      if (!map.has(key)) map.set(key, [])
      const values = map.get(key)
      if (!values.some((existing) => existing.kind === value.kind && existing.id === value.id)) values.push(value)
    }
    const addRomanisation = (value, payload) => {
      const raw = String(value || "").trim()
      if (!raw) return
      raw.split("/").map((part) => part.trim()).filter(Boolean).forEach((part) => {
        add(part, payload)
        add(this.stripDiacritics(part), payload)
        add(this.stripDiacritics(part).replace(/[1-9]$/g, ""), payload)
      })
    }

    Object.keys(this.currentUnitGroups).forEach((unitId) => {
      const unit = this.catalogue.units[unitId]
      const group = this.selectedGroup(unitId)
      if (!group || group.factor === null) return
      const payload = { kind: "historical", id: unitId, factor: group.factor, referenceIds: group.referenceIds || [] }
      unit.han.split("/").map((part) => part.trim()).forEach((alias) => add(alias, payload))
      ;(unit.aliases || []).forEach((alias) => add(alias, payload))
      addRomanisation(unit.romanisation, payload)
      Object.values(unit.romanisations || {}).forEach((romanisation) => addRomanisation(romanisation, payload))
    })

    this.comparisonsForCategory().forEach((unit) => {
      const payload = { kind: "comparison", id: unit.id, toSi: unit.to_si, referenceIds: unit.reference_ids || [] }
      add(unit.symbol, payload)
      add(unit.label, payload)
      ;(unit.aliases || []).forEach((alias) => add(alias, payload))
    })

    return map
  }

  parseNumberToken(token) {
    if (/^[+-]?\d+(?:\.\d+)?$/.test(token)) return Number(token)
    return this.parseHanNumber(token)
  }

  parseHanNumber(token) {
    let text = String(token)
      .replace(/廿/g, "二十")
      .replace(/卅/g, "三十")
      .replace(/卌/g, "四十")
      .replace(/万/g, "萬")
      .replace(/亿/g, "億")

    const digits = { 零: 0, 〇: 0, 一: 1, 二: 2, 三: 3, 四: 4, 五: 5, 六: 6, 七: 7, 八: 8, 九: 9 }
    if ([...text].every((char) => Object.prototype.hasOwnProperty.call(digits, char))) {
      return Number([...text].map((char) => digits[char]).join(""))
    }

    const smallUnits = { 十: 10, 百: 100, 千: 1000 }
    let total = 0
    let section = 0
    let number = 0

    for (const char of text) {
      if (Object.prototype.hasOwnProperty.call(digits, char)) {
        number = digits[char]
      } else if (Object.prototype.hasOwnProperty.call(smallUnits, char)) {
        const unit = smallUnits[char]
        section += (number || 1) * unit
        number = 0
      } else if (char === "萬" || char === "億") {
        section += number
        number = 0
        const multiplier = char === "萬" ? 10000 : 100000000
        total += (section || 1) * multiplier
        section = 0
      } else {
        return NaN
      }
    }
    return total + section + number
  }

  selectedComparisonRows(standard, totalBase) {
    if (standard.base_si === null) return []
    const totalSi = totalBase * standard.base_si
    return this.comparisonsForCategory()
      .filter((unit) => this.selectedComparisons.has(unit.id))
      .map((unit) => ({ ...unit, value: this.formatNumber(totalSi / unit.to_si) }))
  }

  formatCompound(totalBase, rows) {
    const usable = rows.filter((row) => row.group.factor > 0).sort((a, b) => b.group.factor - a.group.factor)
    const unique = []
    const seen = new Set()
    usable.forEach((row) => {
      const key = this.factorKey(row.group.factor)
      if (!seen.has(key)) {
        seen.add(key)
        unique.push(row)
      }
    })
    if (unique.length === 0) return ""

    const sign = totalBase < 0 ? "負" : ""
    let remaining = Math.abs(totalBase)
    const parts = []

    unique.forEach((row, index) => {
      const factor = row.group.factor
      const isLast = index === unique.length - 1
      let amount
      if (isLast) {
        amount = remaining / factor
      } else {
        amount = Math.floor((remaining + 1e-12) / factor)
        remaining -= amount * factor
      }
      if (amount > 1e-10 || (isLast && parts.length === 0)) {
        const unitHan = row.unit.han.split("/")[0].trim()
        if (isLast && Math.abs(amount - Math.round(amount)) > 1e-9 && parts.length > 0) {
          const whole = Math.floor(amount)
          if (whole > 0) parts.push(`${this.hanNumber(whole)}${unitHan}`)
          parts.push("餘")
        } else {
          const printable = isLast ? Number(this.formatNumber(amount, 3)) : amount
          parts.push(`${this.hanNumber(printable)}${unitHan}`)
        }
      }
    })

    return sign + parts.join("")
  }

  hanNumber(value) {
    if (!Number.isFinite(value)) return String(value)
    if (Math.abs(value - Math.round(value)) > 1e-9) {
      const text = this.formatNumber(value, 8)
      const digitMap = { "0": "〇", "1": "一", "2": "二", "3": "三", "4": "四", "5": "五", "6": "六", "7": "七", "8": "八", "9": "九", ".": "點", "-": "負" }
      return [...text].map((char) => digitMap[char] || char).join("")
    }

    const n = Math.round(value)
    if (n === 0) return "〇"
    if (n < 0) return `負${this.hanInteger(-n)}`
    return this.hanInteger(n)
  }

  hanInteger(n) {
    const digits = ["〇", "一", "二", "三", "四", "五", "六", "七", "八", "九"]
    if (n < 10) return digits[n]
    if (n < 10000) {
      const units = [[1000, "千"], [100, "百"], [10, "十"], [1, ""]]
      let remainder = n
      let output = ""
      let zeroPending = false
      units.forEach(([unit, label]) => {
        const digit = Math.floor(remainder / unit)
        remainder %= unit
        if (digit > 0) {
          if (zeroPending && output) output += "〇"
          if (!(unit === 10 && digit === 1 && output === "")) output += digits[digit]
          output += label
          zeroPending = false
        } else if (output && remainder > 0) {
          zeroPending = true
        }
      })
      return output
    }
    if (n < 100000000) {
      const high = Math.floor(n / 10000)
      const low = n % 10000
      return `${this.hanInteger(high)}萬${low ? (low < 1000 ? "〇" : "") + this.hanInteger(low) : ""}`
    }
    const high = Math.floor(n / 100000000)
    const low = n % 100000000
    return `${this.hanInteger(high)}億${low ? (low < 10000000 ? "〇" : "") + this.hanInteger(low) : ""}`
  }

  baseReferenceIds(standard) {
    return Array.from(new Set(standard?.reference_ids || []))
  }

  collectReferenceIds(standard, selectedRows, comparisonRows) {
    const ids = new Set(this.baseReferenceIds(standard))
    this.lastParseReferenceIds.forEach((id) => ids.add(id))
    selectedRows.forEach((row) => (row.group.referenceIds || []).forEach((id) => ids.add(id)))
    comparisonRows.forEach((row) => (row.reference_ids || []).forEach((id) => ids.add(id)))
    return Array.from(ids)
  }

  renderReferences(referenceIds) {
    const records = referenceIds.map((id) => this.catalogue.references[id]).filter(Boolean)
    this.referencesTarget.innerHTML = records.map((ref) => `<div class="measurement-converter__reference">
      <div>${this.escapeHtml(ref.citation)}</div>
      ${ref.quote ? `<blockquote>${this.escapeHtml(ref.quote)}</blockquote>` : ""}
      ${ref.url ? `<div><a href="${this.escapeAttr(ref.url)}" target="_blank" rel="noopener">Open source</a></div>` : ""}
    </div>`).join("") || `<p class="measurement-converter__subtle">No sources are needed until a measurement is converted.</p>`
    this.updateSourcesSummary(referenceIds)
  }

  updateSourcesSummary(referenceIds) {
    if (!this.hasSourcesSummaryTarget) return
    const count = referenceIds.filter((id) => this.catalogue.references[id]).length
    this.sourcesSummaryTarget.textContent = count > 0 ? `Sources (${count})` : "Sources"
  }

  renderCorrespondence(standard, totalBase, compound, selectedRows, comparisonRows, referenceIds) {
    const lines = []
    lines.push(`Measurement: ${this.inputTarget.value}`)
    lines.push(`Period: ${this.periodTarget.options[this.periodTarget.selectedIndex]?.text || this.periodTarget.value}`)
    lines.push(`Standard: ${standard.label}`)
    lines.push(`Historical expression: ${compound || this.formatNumber(totalBase) + " " + (this.currentCategory()?.base_label || "")}`)

    if (comparisonRows.length) {
      lines.push("")
      lines.push("Modern equivalents")
      comparisonRows.forEach((row) => lines.push(`${row.system} — ${row.label}: ${row.value} ${row.symbol}`))
    }

    if (selectedRows.length) {
      lines.push("")
      lines.push("Same measurement in other Chinese units")
      selectedRows.sort((a, b) => b.group.factor - a.group.factor).forEach((row) => {
        const han = row.unit.han.split("/")[0].trim()
        lines.push(`${han} (${row.unit.romanisation}) — ${this.relationshipText(row.unit, row.group.factor)} — ${this.formatNumber(totalBase / row.group.factor)} ${han}`)
      })
    }

    lines.push(this.referenceText(referenceIds))
    this.correspondenceTarget.textContent = lines.join("\n")
  }

  referenceText(referenceIds) {
    const lines = ["", "Sources"]
    referenceIds.forEach((id) => {
      const ref = this.catalogue.references[id]
      if (!ref) return
      lines.push(ref.citation)
      if (ref.quote) lines.push(ref.quote)
      lines.push("")
    })
    return lines.join("\n").trimEnd()
  }

  formatNumber(value, digits = 10) {
    if (!Number.isFinite(Number(value))) return String(value)
    const number = Number(value)
    if (Math.abs(number) < 1e-12) return "0"
    const rounded = Number(number.toPrecision(digits))
    return String(rounded)
  }

  stripDiacritics(value) {
    return String(value || "").normalize("NFD").replace(/[\u0300-\u036f]/g, "").replace(/\s*\/\s*/g, "/").toLowerCase()
  }

  escapeRegExp(value) {
    return String(value).replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
  }

  escapeHtml(value) {
    return String(value ?? "")
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&#39;")
  }

  escapeAttr(value) {
    return this.escapeHtml(value)
  }
}
