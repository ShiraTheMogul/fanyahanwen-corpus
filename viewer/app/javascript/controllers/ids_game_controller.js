import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { rounds: Array, mode: String }
  static targets = ["glyph", "prompt", "components", "score", "status"]

  connect() {
    this.rounds = shuffle([...this.roundsValue])
    this.index = 0
    this.points = 0
    this.expression = "?"
    this.renderRound()
  }

  constructorChanged(event) {
    this.expression = event.detail.expression
  }

  check() {
    const round = this.currentRound
    if (!round) return
    if (!this.expression || this.expression.includes("?")) {
      this.statusTarget.textContent = "Fill every slot before checking."
      return
    }

    if (round.expressions.includes(this.expression)) {
      this.points += 1
      this.statusTarget.textContent = `Correct: ${round.glyph} = ${this.expression}`
      this.saveHighScore()
      this.updateScore()
      window.setTimeout(() => this.nextRound(), 650)
    } else {
      this.statusTarget.textContent = "That is a valid attempt, but it is not one of the imported decompositions for this character. Try another structure."
    }
  }

  skip() {
    const round = this.currentRound
    if (!round) return
    this.statusTarget.textContent = `One accepted answer is ${round.expressions[0]}.`
    window.setTimeout(() => this.nextRound(), 900)
  }

  get currentRound() { return this.rounds[this.index] }

  nextRound() {
    if (this.rounds.length === 0) return
    this.index = (this.index + 1) % this.rounds.length
    this.clearBuilder()
    this.renderRound()
  }

  renderRound() {
    const round = this.currentRound
    if (!round) {
      this.promptTarget.textContent = "No IDS rounds are available. Import the Yi Bai structures first."
      return
    }

    this.statusTarget.textContent = ""
    this.expression = "?"

    if (this.modeValue === "construction") {
      this.glyphTarget.textContent = "？"
      this.promptTarget.textContent = "Arrange these components into the hidden character:"
      this.componentsTarget.replaceChildren(...shuffle([...round.components]).map((component) => componentPill(component)))
    } else {
      this.glyphTarget.textContent = round.glyph
      this.promptTarget.textContent = `${round.codepoint} — deconstruct this character using IDS.`
      this.componentsTarget.replaceChildren()
    }

    this.updateScore()
  }

  clearBuilder() {
    const button = this.element.querySelector('[data-action="ids-constructor#clear"]')
    button?.click()
  }

  updateScore() {
    const high = Number(localStorage.getItem(this.highScoreKey) || 0)
    this.scoreTarget.textContent = `Score ${this.points} · Best ${Math.max(high, this.points)}`
  }

  saveHighScore() {
    const high = Number(localStorage.getItem(this.highScoreKey) || 0)
    if (this.points > high) localStorage.setItem(this.highScoreKey, String(this.points))
  }

  get highScoreKey() { return `fanya.idsGame.${this.modeValue}.highScore` }
}

function componentPill(component) {
  const span = document.createElement("span")
  span.className = "character-learning-component-pill"
  span.textContent = component
  return span
}

function shuffle(values) {
  for (let index = values.length - 1; index > 0; index -= 1) {
    const target = Math.floor(Math.random() * (index + 1))
    ;[values[index], values[target]] = [values[target], values[index]]
  }
  return values
}
