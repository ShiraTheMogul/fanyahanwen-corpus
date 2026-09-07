// Word Processor access to the Corpus reader's punctuation model.
// Storage keys and conversion behaviour intentionally match corpus_reader_controller.js.

export function punctuationPresetOptions(preset) {
  const options = {
    quoteFamily: "corner",
    quoteOrder: "trad",
    verticalQuoteForms: false,
    semicolon: "keep",
    colon: "keep",
    question: "keep",
    exclamation: "keep",
    comma: "keep",
  }

  if (preset === "modern_prc") {
    options.quoteFamily = "speech_curly"
    options.quoteOrder = "simp"
  } else if (preset === "pure") {
    options.comma = "dunhao"
    options.semicolon = "collapse"
    options.colon = "collapse"
    options.question = "collapse"
    options.exclamation = "collapse"
  }

  return options
}

export function loadPunctuationState() {
  const getString = (key, fallback) => {
    const value = window.localStorage.getItem(key)
    return value === null || value === undefined || value === "" ? fallback : value.toString()
  }
  const getBoolean = (key, fallback) => {
    const value = window.localStorage.getItem(key)
    return value === null || value === undefined || value === "" ? fallback : value === "1"
  }

  return {
    preset: getString("corpus.punctPreset", "modern_trad"),
    userOverrodeVerticalQuotes: getBoolean("corpus.punctUserOverrodeVQ", false),
    options: {
      quoteFamily: getString("corpus.quoteFamily", "corner"),
      quoteOrder: getString("corpus.quoteOrder", "trad"),
      verticalQuoteForms: getBoolean("corpus.verticalQuoteForms", false),
      semicolon: getString("corpus.punctSemi", "keep"),
      colon: getString("corpus.punctColon", "keep"),
      question: getString("corpus.punctQ", "keep"),
      exclamation: getString("corpus.punctEx", "keep"),
      comma: getString("corpus.punctComma", "keep"),
    },
  }
}

export function savePunctuationState(state) {
  const options = state?.options || punctuationPresetOptions("source")
  window.localStorage.setItem("corpus.punctPreset", (state?.preset || "source").toString())
  window.localStorage.setItem("corpus.punctUserOverrodeVQ", state?.userOverrodeVerticalQuotes ? "1" : "0")
  window.localStorage.setItem("corpus.quoteFamily", (options.quoteFamily || "corner").toString())
  window.localStorage.setItem("corpus.quoteOrder", (options.quoteOrder || "trad").toString())
  window.localStorage.setItem("corpus.verticalQuoteForms", options.verticalQuoteForms ? "1" : "0")
  window.localStorage.setItem("corpus.punctSemi", (options.semicolon || "keep").toString())
  window.localStorage.setItem("corpus.punctColon", (options.colon || "keep").toString())
  window.localStorage.setItem("corpus.punctQ", (options.question || "keep").toString())
  window.localStorage.setItem("corpus.punctEx", (options.exclamation || "keep").toString())
  window.localStorage.setItem("corpus.punctComma", (options.comma || "keep").toString())
}

export function convertPunctuation(text, state, { vertical = false } = {}) {
  const preset = (state?.preset || "source").toString()
  if (preset === "source") return text
  if (preset === "strip") return stripPunctuation(text)

  let options = state?.options || punctuationPresetOptions("source")
  if (preset !== "custom") options = punctuationPresetOptions(preset)
  if (preset === "modern_prc" && vertical) options = { ...options, quoteFamily: "corner" }
  if (vertical && !state?.userOverrodeVerticalQuotes) options = { ...options, verticalQuoteForms: true }

  const converter = new QuoteConverter(options)
  return converter.convert(convertPuncText(text, options))
}

export function stripPunctuation(text) {
  const pattern = /[\u2000-\u206F\u2E00-\u2E7F\u3000-\u303F\uFE10-\uFE1F\uFE30-\uFE4F\uFF00-\uFF65!"#$%&'()*+,\-.\/:;<=>?@[\\\]^_`{|}~]/g
  return String(text || "").replace(pattern, "")
}

function convertStrong(full, mode) {
  return mode === "collapse" ? "。" : full
}

export function convertPuncText(text, options) {
  let value = String(text || "")

  if (options.comma === "dunhao") {
    value = value.replace(/,/g, "、").replace(/，/g, "、")
  } else {
    value = value.replace(/,/g, "，")
  }

  value = value.replace(/(?<!\d)\.(?!\d)/g, "。")
  value = value.replace(/;/g, convertStrong("；", options.semicolon)).replace(/；/g, convertStrong("；", options.semicolon))
  value = value.replace(/:/g, convertStrong("：", options.colon)).replace(/：/g, convertStrong("：", options.colon))
  value = value.replace(/\?/g, convertStrong("？", options.question)).replace(/？/g, convertStrong("？", options.question))
  value = value.replace(/!/g, convertStrong("！", options.exclamation)).replace(/！/g, convertStrong("！", options.exclamation))
  return value
}

export class QuoteConverter {
  constructor(options) {
    this.options = options || {}
    this.stack = []
  }

  isQuote(character) {
    return ['"', "'", "「", "」", "『", "』", "﹁", "﹂", "﹃", "﹄", "“", "”", "‘", "’", "＂", "＇"].includes(character)
  }

  isOpen(character) {
    return ["「", "『", "﹁", "﹃", "“", "‘"].includes(character)
  }

  isClose(character) {
    return ["」", "』", "﹂", "﹄", "”", "’"].includes(character)
  }

  glyphs() {
    const family = (this.options.quoteFamily || "corner").toString()
    if (family === "off") return null
    const order = (this.options.quoteOrder || "trad").toString()

    let aOpen = "「", aClose = "」", bOpen = "『", bClose = "』"
    if (family === "corner" && this.options.verticalQuoteForms) {
      aOpen = "﹁"; aClose = "﹂"; bOpen = "﹃"; bClose = "﹄"
    }

    if (family === "speech_curly") {
      const outerOpen = "“", outerClose = "”", innerOpen = "‘", innerClose = "’"
      return order === "simp"
        ? { outerOpen: innerOpen, outerClose: innerClose, innerOpen: outerOpen, innerClose: outerClose }
        : { outerOpen, outerClose, innerOpen, innerClose }
    }

    if (family === "speech_fullwidth") {
      const outerOpen = "＂", outerClose = "＂", innerOpen = "＇", innerClose = "＇"
      return order === "simp"
        ? { outerOpen: innerOpen, outerClose: innerClose, innerOpen: outerOpen, innerClose: outerClose }
        : { outerOpen, outerClose, innerOpen, innerClose }
    }

    return order === "simp"
      ? { outerOpen: bOpen, outerClose: bClose, innerOpen: aOpen, innerClose: aClose }
      : { outerOpen: aOpen, outerClose: aClose, innerOpen: bOpen, innerClose: bClose }
  }

  convert(text) {
    const glyphs = this.glyphs()
    if (!glyphs) return text

    let output = ""
    for (const character of text) {
      if (!this.isQuote(character)) {
        output += character
        continue
      }

      if (this.isOpen(character)) {
        const kind = this.stack.length === 0 ? "outer" : "inner"
        this.stack.push({ kind, neutralType: null })
        output += kind === "outer" ? glyphs.outerOpen : glyphs.innerOpen
        continue
      }

      if (this.isClose(character)) {
        const frame = this.stack.pop()
        const kind = frame?.kind || (this.stack.length === 0 ? "outer" : "inner")
        output += kind === "outer" ? glyphs.outerClose : glyphs.innerClose
        continue
      }

      // ASCII/fullwidth quote marks do not encode opening/closing direction.
      // Pair a repeated quote type with its most recent opening frame. This
      // makes "text" close correctly while still allowing the usual nested
      // "outer 'inner' outer" pattern.
      const neutralType = (character === '"' || character === "＂") ? "double" : "single"
      const top = this.stack[this.stack.length - 1]
      if (top?.neutralType === neutralType) {
        const frame = this.stack.pop()
        output += frame.kind === "outer" ? glyphs.outerClose : glyphs.innerClose
        continue
      }

      const kind = this.stack.length === 0 ? "outer" : "inner"
      this.stack.push({ kind, neutralType })
      output += kind === "outer" ? glyphs.outerOpen : glyphs.innerOpen
    }
    return output
  }
}
