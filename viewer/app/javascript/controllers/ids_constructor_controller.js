import { Controller } from "@hotwired/stimulus"

const OPERATOR_LAYOUT = {
  "⿰": { arity: 2, layout: "left-right" },
  "⿲": { arity: 3, layout: "left-middle-right" },
  "⿱": { arity: 2, layout: "top-bottom" },
  "⿳": { arity: 3, layout: "top-middle-bottom" },
  "⿴": { arity: 2, layout: "surround" },
  "⿵": { arity: 2, layout: "surround-above" },
  "⿶": { arity: 2, layout: "surround-below" },
  "⿷": { arity: 2, layout: "surround-left" },
  "⿸": { arity: 2, layout: "surround-upper-left" },
  "⿹": { arity: 2, layout: "surround-upper-right" },
  "⿺": { arity: 2, layout: "surround-lower-left" },
  "⿻": { arity: 2, layout: "overlay" },
  "⿼": { arity: 2, layout: "surround-right" },
  "⿽": { arity: 2, layout: "surround-lower-right" },
  "⿾": { arity: 1, layout: "horizontal-reflection" },
  "⿿": { arity: 1, layout: "rotation" },
  "㇯": { arity: 2, layout: "subtraction" },
}

export default class extends Controller {
  static targets = ["tree", "expression", "component", "difficultGroup"]
  static values = { searchUrl: String }

  connect() {
    this.root = this.emptyNode()
    this.selectedPath = []
    this.history = []
    this.decorateOperatorButtons()
    this.render()
  }

  insertOperator(event) {
    const operator = event.currentTarget.dataset.operator
    const definition = OPERATOR_LAYOUT[operator]
    if (!definition) return

    const current = this.nodeAt(this.root, this.selectedPath)
    let replacement

    if (this.operatorDefinition(current)) {
      // The frame itself is selected: change its layout instead of nesting a
      // second frame.  Existing operands survive whenever that can be done
      // without throwing populated slots away.
      const resizedChildren = this.resizedChildren(current.children, definition.arity)
      if (!resizedChildren) return
      replacement = { token: operator, children: resizedChildren }
    } else if (current.token) {
      // A populated operand is selected: nesting should not destroy a component
      // that may have taken time to locate.  Wrap it as operand 1.
      replacement = {
        token: operator,
        children: [structuredClone(current), ...Array.from({ length: definition.arity - 1 }, () => this.emptyNode())],
      }
    } else {
      // An empty operand box is selected: put the new frame inside that box.
      replacement = { token: operator, children: Array.from({ length: definition.arity }, () => this.emptyNode()) }
    }

    this.replaceSelected(replacement, { select: "replacement" })
  }

  insertComponent() {
    const value = this.componentTarget.value.trim()
    if (!value) return
    const token = this.componentToken(value)
    if (!token) return

    this.insertComponentToken(token)
    this.componentTarget.value = ""
    this.componentTarget.focus()
  }

  insertDifficultComponent(event) {
    const token = this.componentToken(event.currentTarget.dataset.component || "")
    if (!token) return
    this.insertComponentToken(token)
  }

  insertComponentToken(token) {
    const current = this.nodeAt(this.root, this.selectedPath)

    if (this.operatorDefinition(current)) {
      // Immediately after choosing a frame, the frame remains selected so a
      // second operator can replace it.  A component, however, naturally fills
      // the first empty operand of that selected frame.
      const relativeEmpty = this.firstEmptyPath(current)
      if (!relativeEmpty) return
      const targetPath = [...this.selectedPath, ...relativeEmpty]
      this.pushHistory()
      this.root = this.replaceAt(this.root, targetPath, { token, children: [] })
      this.selectedPath = this.firstEmptyPath(this.root) || targetPath
      this.render()
      return
    }

    this.replaceSelected({ token, children: [] }, { select: "next-empty" })
  }

  showDifficultGroup(event) {
    const group = event.currentTarget.dataset.group
    this.difficultGroupTargets.forEach((element) => {
      element.hidden = element.dataset.group !== group
    })
    this.element.querySelectorAll(".ids-difficult-count").forEach((button) => {
      const active = button.dataset.group === group
      button.classList.toggle("is-active", active)
      button.setAttribute("aria-selected", active ? "true" : "false")
    })
  }

  select(event) {
    event.stopPropagation()
    this.selectedPath = JSON.parse(event.currentTarget.dataset.path)
    this.render()
  }

  selectFrame(event) {
    event.stopPropagation()
    this.selectedPath = JSON.parse(event.currentTarget.dataset.path)
    this.render()
  }

  undo() {
    const previous = this.history.pop()
    if (!previous) return
    this.root = previous.root
    this.selectedPath = previous.selectedPath
    this.render()
  }

  clear() {
    this.pushHistory()
    this.root = this.emptyNode()
    this.selectedPath = []
    this.render()
  }

  search() {
    const expression = this.serialize(this.root)
    if (!expression) return
    const destination = this.hasSearchUrlValue ? this.searchUrlValue : window.location.href
    const url = new URL(destination, window.location.origin)
    url.searchParams.set("q", expression)
    url.searchParams.set("mode", expression.includes("?") ? "fuzzy" : "exact")
    window.location.assign(url.toString())
  }

  replaceSelected(replacement, { select = "replacement" } = {}) {
    const replacedPath = [...this.selectedPath]
    this.pushHistory()
    this.root = this.replaceAt(this.root, replacedPath, replacement)

    if (select === "next-empty") {
      this.selectedPath = this.firstEmptyPath(this.root) || replacedPath
    } else {
      // Keep the newly-created/replaced frame selected.  This is what makes a
      // second operator click change the frame rather than unexpectedly nest.
      this.selectedPath = replacedPath
    }

    this.render()
  }

  pushHistory() {
    this.history.push({ root: structuredClone(this.root), selectedPath: [...this.selectedPath] })
    if (this.history.length > 100) this.history.shift()
  }

  emptyNode() { return { token: null, children: [] } }

  operatorDefinition(node) {
    return node?.token ? OPERATOR_LAYOUT[node.token] : null
  }

  resizedChildren(children, arity) {
    const existing = Array(children).map((child) => structuredClone(child))

    if (existing.length > arity) {
      const discarded = existing.slice(arity)
      if (discarded.some((child) => !this.nodeEmpty(child))) return null
    }

    const kept = existing.slice(0, arity)
    while (kept.length < arity) kept.push(this.emptyNode())
    return kept
  }

  nodeEmpty(node) {
    if (!node?.token) return true
    return false
  }

  componentToken(value) {
    if (value.startsWith("&") && value.endsWith(";")) return value
    if (typeof Intl !== "undefined" && Intl.Segmenter) {
      const segmenter = new Intl.Segmenter(undefined, { granularity: "grapheme" })
      return Array.from(segmenter.segment(value), (entry) => entry.segment)[0] || null
    }
    return Array.from(value)[0] || null
  }

  nodeAt(root, path) { return path.reduce((node, index) => node.children[index], root) }

  replaceAt(root, path, replacement) {
    if (path.length === 0) return replacement
    const copy = structuredClone(root)
    const parent = this.nodeAt(copy, path.slice(0, -1))
    parent.children[path[path.length - 1]] = replacement
    return copy
  }

  firstEmptyPath(node, path = []) {
    if (!node.token) return path
    for (let index = 0; index < node.children.length; index += 1) {
      const found = this.firstEmptyPath(node.children[index], [...path, index])
      if (found) return found
    }
    return null
  }

  serialize(node) {
    if (!node.token) return "?"
    return `${node.token}${node.children.map((child) => this.serialize(child)).join("")}`
  }

  render() {
    this.treeTarget.replaceChildren(this.renderNode(this.root, []))
    const expression = this.serialize(this.root)
    this.expressionTarget.textContent = expression
    this.element.dispatchEvent(new CustomEvent("ids-constructor:changed", {
      bubbles: true,
      detail: { expression },
    }))
  }

  renderNode(node, path) {
    const definition = this.operatorDefinition(node)
    if (definition) return this.renderOperatorNode(node, path, definition)
    return this.renderLeafNode(node, path)
  }

  renderLeafNode(node, path) {
    const wrapper = document.createElement("div")
    wrapper.className = "ids-tree-node ids-tree-node--leaf"

    const button = document.createElement("button")
    button.type = "button"
    button.className = "ids-tree-token ids-tree-slot"
    if (this.samePath(path, this.selectedPath)) button.classList.add("is-selected")
    button.textContent = node.token || "?"
    button.dataset.path = JSON.stringify(path)
    button.dataset.action = "ids-constructor#select"
    button.setAttribute("aria-label", node.token ? `Component ${node.token}` : "Empty IDS component slot")
    wrapper.append(button)
    return wrapper
  }

  renderOperatorNode(node, path, definition) {
    const selected = this.samePath(path, this.selectedPath)
    const wrapper = document.createElement("div")
    wrapper.className = `ids-tree-node ids-tree-node--operator ids-layout ids-layout--${definition.layout}`
    if (selected) wrapper.classList.add("is-selected")
    wrapper.dataset.operator = node.token

    const selector = document.createElement("button")
    selector.type = "button"
    selector.className = "ids-layout-selector"
    selector.textContent = node.token
    selector.title = `Select ${node.token} structure`
    selector.dataset.path = JSON.stringify(path)
    selector.dataset.action = "ids-constructor#select"
    wrapper.append(selector)

    const frame = document.createElement("div")
    frame.className = `ids-layout-frame ids-layout-frame--${definition.layout}`
    frame.setAttribute("role", "group")
    frame.setAttribute("aria-label", `${node.token} IDS structure`)
    frame.dataset.path = JSON.stringify(path)
    frame.dataset.action = "click->ids-constructor#selectFrame"

    node.children.forEach((child, index) => {
      const slot = document.createElement("div")
      const childPath = [...path, index]
      slot.className = `ids-layout-child ids-layout-child--${index + 1}`
      slot.dataset.slotIndex = index
      slot.dataset.path = JSON.stringify(childPath)
      slot.dataset.action = "click->ids-constructor#select"
      slot.append(this.renderNode(child, childPath))
      frame.append(slot)
    })

    wrapper.append(frame)
    return wrapper
  }

  decorateOperatorButtons() {
    this.element.querySelectorAll(".ids-operator[data-operator]").forEach((button) => {
      const operator = button.dataset.operator
      const definition = OPERATOR_LAYOUT[operator]
      if (!definition || button.querySelector(".ids-operator-diagram")) return

      button.textContent = ""
      button.classList.add(`ids-operator--${definition.layout}`)
      button.title = operator
      button.setAttribute("aria-label", operator)

      const diagram = document.createElement("span")
      diagram.className = `ids-operator-diagram ids-operator-diagram--${definition.layout}`
      diagram.setAttribute("aria-hidden", "true")
      button.append(diagram)

      if (["horizontal-reflection", "rotation", "subtraction"].includes(definition.layout)) {
        const mark = document.createElement("span")
        mark.className = "ids-operator-diagram__mark"
        mark.textContent = definition.layout === "horizontal-reflection" ? "↔" : definition.layout === "rotation" ? "↻" : "−"
        diagram.append(mark)
      }
    })
  }

  samePath(left, right) {
    return left.length === right.length && left.every((value, index) => value === right[index])
  }
}
