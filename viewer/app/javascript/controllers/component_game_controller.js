import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { rounds: Array }
  static targets = ["glyph", "codepoint", "score", "status"]

  connect() {
    this.rounds = shuffle([...this.roundsValue])
    this.index = 0
    this.points = 0
    this.strokeCount = null
    this.strokeClass = null
    this.renderRound()
  }

  chooseStrokeCount(event) {
    this.strokeCount = event.currentTarget.dataset.value
    this.markChoice(event.currentTarget, "stroke-count")
  }

  chooseStrokeClass(event) {
    this.strokeClass = event.currentTarget.dataset.value
    this.markChoice(event.currentTarget, "stroke-class")
  }

  check() {
    if (!this.strokeCount || !this.strokeClass) {
      this.statusTarget.textContent = "Choose both the stroke count and the first-stroke class."
      return
    }

    const correct = this.currentRound.answers.some((answer) =>
      answer.stroke_count === this.strokeCount && answer.stroke_class === this.strokeClass
    )

    if (correct) {
      this.points += 1
      this.statusTarget.textContent = "Correct. That is where this component appears in the lookup palette."
      this.saveHighScore()
      this.updateScore()
      window.setTimeout(() => this.nextRound(), 650)
    } else {
      this.statusTarget.textContent = "Not that shelf. Count the strokes again, then identify the first stroke."
    }
  }

  skip() {
    const answers = this.currentRound.answers.map((answer) => `${answer.stroke_count} → ${className(answer.stroke_class)}`).join("; ")
    this.statusTarget.textContent = `Lookup location: ${answers}.`
    window.setTimeout(() => this.nextRound(), 900)
  }

  get currentRound() { return this.rounds[this.index] }

  nextRound() {
    if (this.rounds.length === 0) return
    this.index = (this.index + 1) % this.rounds.length
    this.renderRound()
  }

  renderRound() {
    const round = this.currentRound
    if (!round) {
      this.statusTarget.textContent = "No hard-to-input components are available."
      return
    }

    this.strokeCount = null
    this.strokeClass = null
    this.glyphTarget.textContent = round.glyph
    this.codepointTarget.textContent = round.codepoint || ""
    this.statusTarget.textContent = ""
    this.element.querySelectorAll(".component-game-choice button").forEach((button) => button.classList.remove("is-selected"))
    this.updateScore()
  }

  markChoice(button, kind) {
    const fieldset = button.closest("fieldset")
    fieldset.querySelectorAll("button").forEach((candidate) => candidate.classList.remove("is-selected"))
    button.classList.add("is-selected")
  }

  updateScore() {
    const high = Number(localStorage.getItem(this.highScoreKey) || 0)
    this.scoreTarget.textContent = `Score ${this.points} · Best ${Math.max(high, this.points)}`
  }

  saveHighScore() {
    const high = Number(localStorage.getItem(this.highScoreKey) || 0)
    if (this.points > high) localStorage.setItem(this.highScoreKey, String(this.points))
  }

  get highScoreKey() { return "fanya.componentGame.highScore" }
}

function className(key) {
  return { horizontal: "橫", vertical: "豎", slash: "撇", dot: "點", turn: "折" }[key] || key
}

function shuffle(values) {
  for (let index = values.length - 1; index > 0; index -= 1) {
    const target = Math.floor(Math.random() * (index + 1))
    ;[values[index], values[target]] = [values[target], values[index]]
  }
  return values
}
