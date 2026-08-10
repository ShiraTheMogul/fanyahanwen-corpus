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
    this.locked = false
    this.renderRound()
  }

  chooseStrokeCount(event) {
    if (this.locked) return
    this.strokeCount = event.currentTarget.dataset.value
    this.markChoice(event.currentTarget)
    this.clearJudgement("stroke-count")
  }

  chooseStrokeClass(event) {
    if (this.locked) return
    this.strokeClass = event.currentTarget.dataset.value
    this.markChoice(event.currentTarget)
    this.clearJudgement("stroke-class")
  }

  check() {
    if (this.locked) return
    if (!this.strokeCount || !this.strokeClass) {
      this.statusTarget.textContent = "Choose both the total stroke count and the first stroke."
      return
    }

    const answer = this.currentRound.answers.find((candidate) =>
      candidate.stroke_count === this.strokeCount && candidate.stroke_class === this.strokeClass
    )

    if (answer) {
      this.locked = true
      this.points += 1
      this.markCorrectAnswer(answer)
      this.statusTarget.textContent = `Correct. In the hard-to-input palette, find ${this.currentRound.glyph} under ${answer.stroke_count} strokes → ${className(answer.stroke_class)} (${classEnglish(answer.stroke_class)}).`
      this.saveHighScore()
      this.updateScore()
      window.setTimeout(() => this.nextRound(), 1050)
    } else {
      this.markIncorrectChoices()
      this.statusTarget.textContent = "Not quite. Recount the component, then identify its first stroke."
    }
  }

  skip() {
    if (this.locked) return
    const answers = this.currentRound.answers
    this.locked = true
    this.markAcceptedAnswers(answers)
    this.statusTarget.textContent = `Answer: ${answers.map((answer) => `${answer.stroke_count} strokes → ${className(answer.stroke_class)} (${classEnglish(answer.stroke_class)})`).join("; ")}.`
    window.setTimeout(() => this.nextRound(), 1350)
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
    this.locked = false
    this.glyphTarget.textContent = round.glyph
    this.codepointTarget.textContent = round.codepoint || ""
    this.statusTarget.textContent = "Choose where you would look for this component in the hard-to-input palette."
    this.element.querySelectorAll(".component-game-choice button").forEach((button) => {
      button.classList.remove("is-selected", "is-correct", "is-incorrect", "is-answer")
      button.disabled = false
    })
    this.updateScore()
  }

  markChoice(button) {
    const fieldset = button.closest("fieldset")
    fieldset.querySelectorAll("button").forEach((candidate) => {
      candidate.classList.remove("is-selected", "is-incorrect")
    })
    button.classList.add("is-selected")
  }

  clearJudgement(kind) {
    const selector = kind === "stroke-count"
      ? '.component-game-choice[data-component-dimension="stroke-count"] button'
      : '.component-game-choice[data-component-dimension="stroke-class"] button'
    this.element.querySelectorAll(selector).forEach((button) => {
      button.classList.remove("is-correct", "is-incorrect", "is-answer")
    })
  }

  markCorrectAnswer(answer) {
    const countButton = this.findButton("stroke-count", answer.stroke_count)
    const classButton = this.findButton("stroke-class", answer.stroke_class)
    ;[countButton, classButton].forEach((button) => {
      if (!button) return
      button.classList.remove("is-incorrect")
      button.classList.add("is-correct", "is-answer")
    })
    this.disableChoices()
  }

  markAcceptedAnswers(answers) {
    answers.forEach((answer) => {
      this.findButton("stroke-count", answer.stroke_count)?.classList.add("is-answer")
      this.findButton("stroke-class", answer.stroke_class)?.classList.add("is-answer")
    })
    this.disableChoices()
  }

  markIncorrectChoices() {
    this.element.querySelectorAll(".component-game-choice button.is-selected").forEach((button) => {
      button.classList.add("is-incorrect")
    })
  }

  findButton(dimension, value) {
    return this.element.querySelector(`.component-game-choice[data-component-dimension="${dimension}"] button[data-value="${cssEscape(value)}"]`)
  }

  disableChoices() {
    this.element.querySelectorAll(".component-game-choice button").forEach((button) => {
      button.disabled = true
    })
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

function classEnglish(key) {
  return { horizontal: "Horizontal bar", vertical: "Vertical bar", slash: "Slash", dot: "Dot", turn: "Turn" }[key] || key
}

function cssEscape(value) {
  if (globalThis.CSS?.escape) return CSS.escape(value)
  return value.toString().replace(/["\\]/g, "\\$&")
}

function shuffle(values) {
  for (let index = values.length - 1; index > 0; index -= 1) {
    const target = Math.floor(Math.random() * (index + 1))
    ;[values[index], values[target]] = [values[target], values[index]]
  }
  return values
}
