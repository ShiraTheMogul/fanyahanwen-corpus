import { Controller } from "@hotwired/stimulus"

const ARITY = {
  "⿾": 1, "⿿": 1,
  "⿲": 3, "⿳": 3,
  "⿰": 2, "⿱": 2, "⿴": 2, "⿵": 2, "⿶": 2, "⿷": 2,
  "⿸": 2, "⿹": 2, "⿺": 2, "⿻": 2, "⿼": 2, "⿽": 2, "㇯": 2,
}

export default class extends Controller {
  static targets = ["tree", "expression", "component", "difficultGroup"]

  connect() {
    this.root = this.emptyNode()
    this.selectedPath = []
    this.history = []
    this.render()
  }

  insertOperator(event) {
    const operator = event.currentTarget.dataset.operator
    const arity = ARITY[operator]
    if (!arity) return

    this.mutateSelected({ token: operator, children: Array.from({ length: arity }, () => this.emptyNode()) })
  }

  insertComponent() {
    const value = this.componentTarget.value.trim()
    if (!value) return

    const token = this.componentToken(value)
    if (!token) return
    this.mutateSelected({ token, children: [] })
    this.componentTarget.value = ""
    this.componentTarget.focus()
  }

  insertDifficultComponent(event) {
    const token = this.componentToken(event.currentTarget.dataset.component || "")
    if (!token) return

    this.mutateSelected({ token, children: [] })
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
    if (!expression || expression.includes("?")) return

    const url = new URL(window.location.href)
    url.searchParams.set("q", expression)
    url.searchParams.set("mode", "fuzzy")
    window.location.assign(url.toString())
  }

  mutateSelected(replacement) {
    this.pushHistory()
    this.root = this.replaceAt(this.root, this.selectedPath, replacement)
    this.selectedPath = this.firstEmptyPath(this.root) || this.selectedPath
    this.render()
  }

  pushHistory() {
    this.history.push({
      root: structuredClone(this.root),
      selectedPath: [...this.selectedPath],
    })
    if (this.history.length > 100) this.history.shift()
  }

  emptyNode() {
    return { token: null, children: [] }
  }

  componentToken(value) {
    if (value.startsWith("&") && value.endsWith(";")) return value
    if (typeof Intl !== "undefined" && Intl.Segmenter) {
      const segmenter = new Intl.Segmenter(undefined, { granularity: "grapheme" })
      return Array.from(segmenter.segment(value), (entry) => entry.segment)[0] || null
    }
    return Array.from(value)[0] || null
  }

  nodeAt(root, path) {
    return path.reduce((node, index) => node.children[index], root)
  }

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
    this.expressionTarget.textContent = this.serialize(this.root)
  }

  renderNode(node, path) {
    const wrapper = document.createElement("div")
    wrapper.className = "ids-tree-node"

    const button = document.createElement("button")
    button.type = "button"
    button.className = "ids-tree-token"
    if (JSON.stringify(path) === JSON.stringify(this.selectedPath)) button.classList.add("is-selected")
    button.textContent = node.token || "?"
    button.dataset.path = JSON.stringify(path)
    button.dataset.action = "ids-constructor#select"
    wrapper.append(button)

    if (node.children.length > 0) {
      const children = document.createElement("div")
      children.className = "ids-tree-children"
      node.children.forEach((child, index) => children.append(this.renderNode(child, [...path, index])))
      wrapper.append(children)
    }

    return wrapper
  }
}
