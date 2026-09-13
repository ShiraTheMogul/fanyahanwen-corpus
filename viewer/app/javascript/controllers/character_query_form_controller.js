import { Controller } from "@hotwired/stimulus"

// The parts of the query form that are not the family picker.
//
//  1. Repeatable "also read as" rows. The first is hidden until asked for, so
//     the common case — one reading — costs no space. Each row is cloned from
//     a <template>, with __INDEX__ swapped for a counter so ids stay unique
//     and labels keep working. Stimulus connects the cloned picker on its own.
//
//  2. Syllable and homophone are alternatives, not a sequence. Filling either
//     disables the other, because a query carrying both asks the same question
//     twice and the homophone lookup would quietly overwrite the syllable.
//     Disabled rather than hidden: the reader can see what the other choice
//     was, and why it went away.
//
//  3. The IDS builder. The site's own shared builder emits
//     ids-constructor:changed with the expression; this copies it into a hidden
//     field and shows it on the disclosure's summary, so the expression is
//     visible without opening the panel.
//
//  4. The Kangxi radical grid, and paging. Paging buttons are rendered by the
//     server into the output frame, which is why this controller wraps the
//     frame as well as the form.
export default class extends Controller {
  static targets = [
    "rowTemplate", "rows", "addButton",
    "radicalInput", "radicalGrid",
    "slotInput", "slotSide", "homophoneInput", "homophoneSide",
    "idsExpression", "idsPreview", "idsPanel",
    "rimePanel", "rimeBook", "rimeBookField", "rimeNote", "combineRow", "sourceNote",
    "rimeTone", "rimeToneField",
    "rimeSection", "rimeSectionField", "rimeSectionLabel", "rimeSectionList",
    "fanqie", "fanqieField", "smallRime", "smallRimeField",
    "page", "form"
  ]
  static values = { maxRows: { type: Number, default: 8 } }

  connect() {
    this.index = this.hasRowsTarget ? this.rowsTarget.querySelectorAll("[data-cq-row]").length : 0
    this.refreshAddButton()
    this.sideChanged()
    this.rimeBookChanged()
  }

  // -- repeatable readings ------------------------------------------------

  addRow(event) {
    event?.preventDefault()
    if (!this.hasRowTemplateTarget || !this.hasRowsTarget) return
    if (this.count() >= this.maxRowsValue) return

    this.index += 1
    const html = this.rowTemplateTarget.innerHTML.replaceAll("__INDEX__", String(this.index))
    const holder = document.createElement("div")
    holder.innerHTML = html

    const row = holder.firstElementChild
    if (!row) return

    this.rowsTarget.appendChild(row)
    this.refreshAddButton()
    row.querySelector("input, select")?.focus()
  }

  removeRow(event) {
    event?.preventDefault()
    event.currentTarget.closest("[data-cq-row]")?.remove()
    this.refreshAddButton()
  }

  count() {
    return this.hasRowsTarget ? this.rowsTarget.querySelectorAll("[data-cq-row]").length : 0
  }

  refreshAddButton() {
    if (!this.hasAddButtonTarget) return
    this.addButtonTarget.disabled = this.count() >= this.maxRowsValue
  }

  // -- syllable vs homophone ---------------------------------------------

  sideChanged() {
    if (!this.hasSlotInputTarget || !this.hasHomophoneInputTarget) return

    const slotFilled = this.slotInputTarget.value.trim() !== ""
    const homophoneFilled = this.homophoneInputTarget.value.trim() !== ""

    // Neither filled: both live. Both filled can only happen if something set
    // a value without firing input, and leaving both live is the safe read.
    this.setSideEnabled(this.homophoneSideTarget, !slotFilled || homophoneFilled)
    this.setSideEnabled(this.slotSideTarget, !homophoneFilled || slotFilled)
  }

  setSideEnabled(side, enabled) {
    if (!side) return

    side.classList.toggle("is-disabled", !enabled)
    side.querySelectorAll("input, select, button").forEach((field) => {
      field.disabled = !enabled
    })
  }

  // -- IDS builder --------------------------------------------------------

  // The builder writes "?" into every slot the reader has not filled, and a
  // bare "?" is no constraint at all, so it is stored as an empty value rather
  // than sent to the server to be discarded there.
  idsChanged(event) {
    const expression = event?.detail?.expression || "?"
    if (this.hasIdsPreviewTarget) this.idsPreviewTarget.textContent = expression
    if (!this.hasIdsExpressionTarget) return

    this.idsExpressionTarget.value = expression.replaceAll("?", "") === "" ? "" : expression
  }

  clearIds(event) {
    event?.preventDefault()
    if (this.hasIdsExpressionTarget) this.idsExpressionTarget.value = ""
    if (this.hasIdsPreviewTarget) this.idsPreviewTarget.textContent = "?"

    // Drive the shared builder's own clear button rather than reaching into
    // its internals, so this keeps working if the builder changes.
    this.element.querySelector('[data-action~="ids-constructor#clear"]')?.click()
  }

  // -- radical grid -------------------------------------------------------

  chooseRadical(event) {
    event.preventDefault()
    const number = event.currentTarget.dataset.radicalNumber
    if (!number || !this.hasRadicalInputTarget) return

    this.radicalInputTarget.value = number
    this.radicalGridTarget?.removeAttribute("open")
    this.radicalInputTarget.focus()
  }

  // -- variant rows -------------------------------------------------------

  // Each character is its own <tbody>; its variants are ordinary rows in that
  // same <tbody>, hidden until asked for. A <details> cannot span table rows,
  // which is why the old version had to cram a whole record into one cell.
  toggleVariants(event) {
    event.preventDefault()
    const button = event.currentTarget
    const group = button.closest("tbody")
    if (!group) return

    const rows = group.querySelectorAll(".cq-variant-row")
    const opening = rows.length > 0 && rows[0].hidden

    rows.forEach((row) => { row.hidden = !opening })
    button.setAttribute("aria-expanded", String(opening))
    const marker = button.querySelector("[aria-hidden]")
    if (marker) marker.textContent = opening ? "\u25BE" : "\u25B8"
  }

  // -- rime books ---------------------------------------------------------

  // Every control in this panel belongs to ONE book, and none of them means
  // anything without it.
  //
  // 上聲 is not a shared category: 廣韻 puts 3,713 characters in it, 集韻
  // 5,960, 五音集韻 6,273, 切韻 2,180, 洪武正韻 2,603 — five compilers between
  // 601 and 1375 reaching five different judgements. 韻目 collides outright,
  // since 麻 heads a section in six of these books and names a different rime
  // in each. So until a book is chosen the facets are disabled, and when one
  // is chosen they are rebuilt from that book's own sections.
  //
  // The books also differ in WHICH facets exist. 玉篇 is arranged by 部首 and
  // records no tone, so it offers no tone box and its section box is
  // relabelled. The server checks the same thing, so this is a convenience,
  // not the guard.
  // The primary picker chose a source. If it is a rime book, this panel stops
  // asking for one: the facets below belong to that book, and there is only
  // one side, so the and/or choice has nothing to join either.
  primarySystemChanged(event) {
    const system = String(event?.detail?.system || "")
    this.primaryBook = system.startsWith("rimebook:") ? system : null
    this.rimeBookChanged()
  }

  rimeBookChanged() {
    if (!this.hasRimeBookTarget || !this.hasRimePanelTarget) return

    const owned = Boolean(this.primaryBook)
    if (this.hasRimeBookFieldTarget) this.rimeBookFieldTarget.hidden = owned
    if (this.hasSourceNoteTarget) this.sourceNoteTarget.hidden = !owned
    if (this.hasCombineRowTarget) this.combineRowTarget.hidden = owned
    if (owned) this.rimeBookTarget.value = ""

    // The source's own id is a key in this same table, so when a book is the
    // source its vocabulary is already here — no second lookup, and 玉篇 still
    // correctly offers no tone box.
    const book = this.books()[owned ? this.primaryBook : this.rimeBookTarget.value] || null

    if (this.hasRimeNoteTarget) this.rimeNoteTarget.hidden = owned || Boolean(book)

    this.setFacet(this.rimeToneFieldTarget, this.rimeToneTarget, book, "tone")
    this.setFacet(this.rimeSectionFieldTarget, this.rimeSectionTarget, book, "rhyme_label")
    this.setFacet(this.fanqieFieldTarget, this.fanqieTarget, book, "fanqie")
    this.setFacet(this.smallRimeFieldTarget, this.smallRimeTarget, book, "small_rime")

    this.fillTones(book)
    this.fillSections(book)
  }

  // Parsed once per change, from the panel's data-books attribute. Kept out
  // of a Stimulus value because it is a fixed table the server rendered, not
  // state either side mutates.
  books() {
    if (!this._books) {
      try {
        this._books = JSON.parse(this.rimePanelTarget.dataset.books || "{}")
      } catch (error) {
        this._books = {}
      }
    }
    return this._books
  }

  // A facet the chosen book does not carry is hidden rather than greyed: an
  // empty tone box beside 玉篇 invites the reader to wonder what is wrong
  // with it, when the answer is that a 字書 has no tone sections to offer.
  setFacet(field, input, book, name) {
    if (!field || !input) return

    const offered = Boolean(book) && (book.facets || []).includes(name)
    field.hidden = Boolean(book) && !offered
    field.classList.toggle("is-disabled", !offered)
    input.disabled = !offered
    if (!offered) input.value = ""
  }

  fillTones(book) {
    if (!this.hasRimeToneTarget) return

    const keep = this.rimeToneTarget.value
    this.rimeToneTarget.replaceChildren(new Option("", ""))
    if (!book) return
    ;(book.tones || []).forEach((tone) => {
      this.rimeToneTarget.appendChild(new Option(tone, tone))
    })
    // A tone that survives the change of book keeps its selection; one that
    // does not exist in the new book is dropped rather than silently
    // reinterpreted. 上平聲 means nothing in 集韻.
    if ((book.tones || []).includes(keep)) this.rimeToneTarget.value = keep
  }

  fillSections(book) {
    if (!this.hasRimeSectionListTarget) return

    this.rimeSectionListTarget.replaceChildren()
    if (!book) return
    ;(book.rhymes || []).forEach((value) => {
      this.rimeSectionListTarget.appendChild(new Option(value, value))
    })

    if (this.hasRimeSectionLabelTarget) {
      const key = book.axis === "radical" ? "radicalLabel" : "rhymeLabel"
      const text = this.rimeSectionLabelTarget.dataset[key]
      if (text) this.rimeSectionLabelTarget.textContent = text
    }
  }

  // -- paging -------------------------------------------------------------

  // Running the query again is a new question, so it starts at page one.
  // Without this, narrowing a query while on page 12 lands on an empty page.
  resetPage() {
    if (this.hasPageTarget) this.pageTarget.value = "1"
  }

  goToPage(event) {
    event.preventDefault()
    const page = event.currentTarget.dataset.page
    if (!page || !this.hasPageTarget || !this.hasFormTarget) return

    this.pageTarget.value = page
    this.formTarget.requestSubmit()
  }
}
