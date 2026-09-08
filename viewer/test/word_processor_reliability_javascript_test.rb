# frozen_string_literal: true

require_relative "test_helper"
require "open3"

class WordProcessorReliabilityJavascriptTest < ActiveSupport::TestCase
  test "shared 夾注 layout pads odd notes without altering stored text" do
    skip "node is not installed" unless system("node", "--version", out: File::NULL, err: File::NULL)

    javascript = <<~'JS'
      const fs = require("fs")
      const vm = require("vm")
      let source = fs.readFileSync(process.argv[1], "utf8")
        .replace(/^\uFEFF/, "")
        .replace(/^export\s+/gm, "")

      const context = { console }
      vm.createContext(context)
      vm.runInContext(source, context)

      const odd = context.jiagzhuLayout("甲乙丙")
      if (odd.original !== "甲乙丙") throw new Error("夾注 source was altered")
      if (odd.padded !== "甲乙丙　") throw new Error(`odd 夾注 did not gain one U+3000 slot: ${odd.padded}`)
      if (odd.first !== "甲乙" || odd.second !== "丙　") throw new Error("odd 夾注 was not balanced into two columns")

      const even = context.jiagzhuLayout("甲乙丙丁")
      if (even.original !== "甲乙丙丁" || even.padded !== "甲乙丙丁") throw new Error("even 夾注 was padded")
      if (even.first !== "甲乙" || even.second !== "丙丁") throw new Error("even 夾注 columns are wrong")
    JS

    path = Rails.root.join("app/javascript/controllers/han_jiagzhu.js")
    stdout, stderr, status = Open3.capture3("node", "-e", javascript, path.to_s)
    assert status.success?, [stdout, stderr].reject(&:empty?).join("\n")
  end

  test "Text Viewer 夾注 insertion stays outside a ruby wrapper" do
    skip "node is not installed" unless system("node", "--version", out: File::NULL, err: File::NULL)

    javascript = <<~'JS'
      const fs = require("fs")
      const vm = require("vm")
      let source = fs.readFileSync(process.argv[1], "utf8")
        .replace(/^\uFEFF/, "")
        .replace(/^export\s+/gm, "")

      const context = { console }
      vm.createContext(context)
      vm.runInContext(source, context)

      const ruby = { marker: "complete-ruby" }
      const anchor = { closest: (selector) => selector === "ruby" ? ruby : null }
      const root = { contains: (node) => node === ruby }
      if (context.corpusInsertionBoundary(anchor, root) !== ruby) {
        throw new Error("夾注 would be inserted between the ruby base and <rt>")
      }

      const outsideRuby = { marker: "outside" }
      const rootWithoutRuby = { contains: () => false }
      const otherAnchor = { closest: () => outsideRuby }
      if (context.corpusInsertionBoundary(otherAnchor, rootWithoutRuby) !== otherAnchor) {
        throw new Error("an out-of-reader ruby wrapper was incorrectly used as the insertion boundary")
      }

      const plainAnchor = { closest: () => null }
      if (context.corpusInsertionBoundary(plainAnchor, root) !== plainAnchor) {
        throw new Error("plain corpus span insertion boundary changed")
      }
    JS

    path = Rails.root.join("app/javascript/controllers/han_jiagzhu.js")
    stdout, stderr, status = Open3.capture3("node", "-e", javascript, path.to_s)
    assert status.success?, [stdout, stderr].reject(&:empty?).join("\n")
  end

  test "Writer and Text Viewer use the same shared 夾注 renderer" do
    writer = Rails.root.join("app/javascript/controllers/word_processor_semantic_annotations.js").read(encoding: "bom|utf-8")
    viewer = Rails.root.join("app/javascript/controllers/corpus_annotations_reliability.js").read(encoding: "bom|utf-8")

    assert_includes writer, 'from "controllers/han_jiagzhu"'
    assert_includes writer, "updateJiagzhuColumnsFromSource"
    assert_includes viewer, 'from "controllers/han_jiagzhu"'
    assert_includes viewer, "enhanceCorpusNoteBlocks"
    assert_includes viewer, 'owner: "corpus-source-jiazhu"'
    refute_includes viewer, "renderJiagzhuAfterCorpusSpans"
  end

  test "Writer reliability keeps layout-only data outside source text" do
    source = Rails.root.join("app/javascript/controllers/word_processor_reliability.js").read(encoding: "bom|utf-8")

    assert_includes source, 'marker.dataset.wpNondocument = "terminal-line"'
    assert_includes source, '[data-han-jiagzhu]'
    assert_includes source, 'wp-horizontal-numeral__run'
    assert_includes source, 'inline-size: 1em'
    assert_includes source, 'block-size: 1em'
    assert_includes source, 'text-combine-upright: none'
    refute_includes source, 'text-combine-upright: all'
    assert_includes source, 'character === "〜"'
    assert_includes source, 'character === "～"'
    assert_includes source, "wpUndo"
    assert_includes source, "wpRedo"
  end

  test "counting-rod runs are distinguished from ordinary zero" do
    skip "node is not installed" unless system("node", "--version", out: File::NULL, err: File::NULL)

    javascript = <<~'JS'
      const fs = require("fs")
      const vm = require("vm")
      let source = fs.readFileSync(process.argv[1], "utf8")
        .replace(/^\uFEFF/, "")
        .replace(/^import[\s\S]*?from\s+"controllers\/han_jiagzhu"\s*\n/, "")
        .replace(/^export\s+/gm, "")
      const context = { console }
      vm.createContext(context)
      vm.runInContext(source, context)
      if (!context.isCountingRodRun("𝍠𝍩𝍢")) throw new Error("counting-rod run was not recognised")
      if (!context.isCountingRodRun("𝍠〇𝍢")) throw new Error("counting-rod zero was not recognised inside a run")
      if (context.isCountingRodRun("〇")) throw new Error("plain zero was misclassified as a counting-rod run")
      if (context.isCountingRodRun("𝍠A")) throw new Error("mixed text was misclassified as counting rods")
    JS

    path = Rails.root.join("app/javascript/controllers/word_processor_reliability.js")
    stdout, stderr, status = Open3.capture3("node", "-e", javascript, path.to_s)
    assert status.success?, [stdout, stderr].reject(&:empty?).join("\n")
  end

  test "both reliability layers are installed before Stimulus eager registration" do
    source = Rails.root.join("app/javascript/controllers/index.js").read(encoding: "bom|utf-8")
    writer_install = source.index("installWordProcessorReliability(WordProcessorController)")
    semantic_install = source.index("installWordProcessorSemanticAnnotations(WordProcessorController)")
    viewer_install = source.index("installCorpusAnnotationsReliability(CorpusAnnotationsController)")
    typography_install = source.index("installCorpusReaderTypographyReliability(CorpusReaderController)")
    eager = source.index('eagerLoadControllersFrom("controllers", application)')

    assert writer_install
    assert semantic_install
    assert viewer_install
    assert typography_install
    assert eager
    assert_operator writer_install, :<, semantic_install
    assert_operator semantic_install, :<, eager
    assert_operator viewer_install, :<, eager
    assert_operator typography_install, :<, eager
  end
  test "terminal newline marker has zero layout advance" do
    source = Rails.root.join("app/javascript/controllers/word_processor_reliability.js").read(encoding: "bom|utf-8")
    terminal_css = source[/\.wp-editor \.wp-terminal-line \{.*?\n    \}/m]

    assert terminal_css
    assert_includes terminal_css, "display: inline"
    refute_match(/\bwidth\s*:/, terminal_css)
    refute_match(/\bheight\s*:/, terminal_css)
  end

  test "horizontal numeral renderer uses a fixed slot with a natural-width child run" do
    source = Rails.root.join("app/javascript/controllers/word_processor_reliability.js").read(encoding: "bom|utf-8")

    assert_includes source, 'slot.className = `wp-horizontal-numeral wp-horizontal-numeral--${kind}`'
    assert_includes source, 'run.className = "wp-horizontal-numeral__run"'
    assert_includes source, 'appendHorizontal(run, "arabic")'
    assert_includes source, 'appendHorizontal(run, "rods")'
    assert_includes source, "position: absolute"
    assert_includes source, "transform: translate(-50%, -50%)"
  end

  test "Writer 夾注 and 批注 are source-backed semantic ranges" do
    semantic = Rails.root.join("app/javascript/controllers/word_processor_semantic_annotations.js").read(encoding: "bom|utf-8")

    assert_includes semantic, 'const SEMANTIC_KINDS = new Set(["jiazhu", "pizhu"])'
    assert_includes semantic, 'const OPEN = "〈"'
    assert_includes semantic, 'const CLOSE = "〉"'
    assert_includes semantic, 'kind: annotation.kind === "note" ? "jiazhu" : "pizhu"'
    assert_includes semantic, 'this.wpSemanticInsertBoundaryText(chapter, end, CLOSE)'
    assert_includes semantic, 'this.wpSemanticInsertBoundaryText(chapter, start, OPEN)'
    assert_includes semantic, 'if (start >= position) return { ...annotation, start: start + delta, end: end + delta }'
    refute_includes semantic, 'inlineObject: true'
  end

  test "Writer 夾注 is directly editable and keyboard-navigable" do
    semantic = Rails.root.join("app/javascript/controllers/word_processor_semantic_annotations.js").read(encoding: "bom|utf-8")

    assert_includes semantic, 'editor.className = "wp-semantic-editor"'
    assert_includes semantic, 'editor.contentEditable = "true"'
    assert_includes semantic, 'const forwardKey = vertical ? "ArrowDown" : "ArrowRight"'
    assert_includes semantic, 'if (event.key === "Backspace")'
    assert_includes semantic, 'this.wpSemanticOpen(previous.id, "end")'
    assert_includes semantic, 'this.insertTextAtSelection("\n", { convert: false'
    assert_includes semantic, 'prototype.addNote = function()'
    assert_includes semantic, 'this.wpSemanticAdd("jiazhu")'
  end

  test "Writer 批注 is separate from 夾注 and remains red in text" do
    semantic = Rails.root.join("app/javascript/controllers/word_processor_semantic_annotations.js").read(encoding: "bom|utf-8")

    assert_includes semantic, '.wp-source-pizhu,'
    assert_includes semantic, 'color: #b00000'
    assert_includes semantic, 'prototype.addComment = function()'
    assert_includes semantic, 'this.wpSemanticAdd("pizhu")'
    assert_includes semantic, 'annotation.kind === "jiazhu" ? "夾注" : "批注"'
  end

  test "批注 inside 夾注 is a nested source range in the same half-size stream" do
    semantic = Rails.root.join("app/javascript/controllers/word_processor_semantic_annotations.js").read(encoding: "bom|utf-8")
    shared = Rails.root.join("app/javascript/controllers/han_jiagzhu.js").read(encoding: "bom|utf-8")

    assert_includes semantic, 'Number(annotation.start) >= innerStart'
    assert_includes semantic, 'Number(annotation.end) <= innerEnd'
    assert_includes semantic, 'updateJiagzhuColumnsFromSource'
    assert_includes semantic, 'span.className = "wp-semantic-editor-pizhu"'
    assert_includes shared, 'export function jiagzhuSourceTokenLayout'
    assert_includes shared, 'kind: matching ? "comment" : "text"'
    assert_includes shared, '.han-jiagzhu__comment {'
  end

  test "semantic annotation deletion removes the real serialized text" do
    semantic = Rails.root.join("app/javascript/controllers/word_processor_semantic_annotations.js").read(encoding: "bom|utf-8")

    assert_includes semantic, 'this.replaceRange(chapter, start, end, "", { render: false })'
    assert_includes semantic, 'this.wpSemanticPruneInvalid(chapter)'
    assert_includes semantic, 'validSemanticSource(chapter.text, annotation)'
    refute_includes semantic, 'annotation.note = ""'
  end

  test "Writer reliability layers never invoke native browser message dialogs" do
    files = %w[word_processor_reliability.js word_processor_semantic_annotations.js]
    files.each do |name|
      source = Rails.root.join("app/javascript/controllers", name).read(encoding: "bom|utf-8")
      refute_match(/\b(?:window\.)?alert\s*\(/, source)
      refute_match(/\b(?:window\.)?confirm\s*\(/, source)
      refute_match(/\b(?:window\.)?prompt\s*\(/, source)
    end
  end

  test "semantic annotation model serializes real 〈〉 text and nests 批注 inside 夾注" do
    skip "node is not installed" unless system("node", "--version", out: File::NULL, err: File::NULL)

    javascript = <<~'JS'
      const fs = require("fs")
      const os = require("os")
      const path = require("path")
      const { pathToFileURL } = require("url")

      const semanticSource = fs.readFileSync(process.argv[1], "utf8")
        .replace('from "controllers/han_jiagzhu"', 'from "./han_jiagzhu_test.mjs"')
      const jiagzhuSource = fs.readFileSync(process.argv[2], "utf8")
      const dir = fs.mkdtempSync(path.join(os.tmpdir(), "fanya-semantic-"))
      const semanticPath = path.join(dir, "semantic_test.mjs")
      const jiagzhuPath = path.join(dir, "han_jiagzhu_test.mjs")
      fs.writeFileSync(semanticPath, semanticSource)
      fs.writeFileSync(jiagzhuPath, jiagzhuSource)

      global.document = {
        head: { appendChild() {} },
        getElementById() { return null },
        createElement() {
          return {
            style: {}, dataset: {},
            classList: { add() {}, remove() {} },
            setAttribute() {}, appendChild() {}, append() {},
            querySelector() { return null }, addEventListener() {}
          }
        }
      }

      ;(async () => {
        const m = await import(pathToFileURL(semanticPath).href + `?${Date.now()}`)
        class Fake {}
        Object.assign(Fake.prototype, {
          activeChapter() { return this.chapter },
          uuid() { this._n = (this._n || 0) + 1; return `a${this._n}` },
          scheduleAutosave() {}, adjustAnnotations(rows) { return rows },
          renderEditor() {}, renderNotes() {}, editorPlainText() { return this.chapter.text },
          offsetForPoint() { return 0 }, pointForOffset() { return {} }, contextMenu() {},
          editorKeydown() {}, deleteNote() {}, editNote() {}, syncEditorToModel() {}, connect() {}
        })
        m.installWordProcessorSemanticAnnotations(Fake)

        const writer = new Fake()
        writer.chapter = { text: "東〈甲乙〉菄", annotations: [{ id: "j", kind: "jiazhu", start: 1, end: 5 }] }
        const pizhu = writer.wpSemanticWrapRange("pizhu", { start: 3, end: 3 })
        if (writer.chapter.text !== "東〈甲〈〉乙〉菄") throw new Error(`serialized text wrong: ${writer.chapter.text}`)
        const parent = writer.chapter.annotations.find((row) => row.id === "j")
        if (parent.end !== 7) throw new Error("parent 夾注 did not expand with nested 批注")
        if (!(pizhu.start > parent.start && pizhu.end < parent.end)) throw new Error("批注 is not structurally inside 夾注")

        fs.rmSync(dir, { recursive: true, force: true })
      })().catch((error) => { console.error(error); process.exit(1) })
    JS

    semantic = Rails.root.join("app/javascript/controllers/word_processor_semantic_annotations.js")
    shared = Rails.root.join("app/javascript/controllers/han_jiagzhu.js")
    stdout, stderr, status = Open3.capture3("node", "-e", javascript, semantic.to_s, shared.to_s)
    assert status.success?, [stdout, stderr].reject(&:empty?).join("\n")
  end

  test "vertical 夾注 uses an atomic main-character frame with explicit right-to-left columns" do
    source = Rails.root.join("app/javascript/controllers/han_jiagzhu.js").read(encoding: "bom|utf-8")
    vertical_css = source[/\.is-vertical \.han-jiagzhu \{.*?\n    \}/m]

    assert vertical_css
    assert_includes vertical_css, "display: inline-block"
    assert_includes vertical_css, "position: relative"
    assert_includes vertical_css, "block-size: 1em"
    assert_includes vertical_css, "inline-size: var(--han-jiagzhu-inline-size, 0.5em)"
    assert_includes vertical_css, "vertical-align: baseline"
    refute_match(/margin-block/, vertical_css)
    assert_includes source, ".is-vertical .han-jiagzhu__column--first"
    assert_includes source, "right: 0"
    assert_includes source, ".is-vertical .han-jiagzhu__column--second"
    assert_includes source, "left: 0"
  end

  test "批注 inside 夾注 participates in the same balanced half-size stream" do
    skip "node is not installed" unless system("node", "--version", out: File::NULL, err: File::NULL)

    javascript = <<~'JS'
      const fs = require("fs")
      const vm = require("vm")
      let source = fs.readFileSync(process.argv[1], "utf8")
        .replace(/^\uFEFF/, "")
        .replace(/^export\s+/gm, "")
      const context = { console }
      vm.createContext(context)
      vm.runInContext(source, context)

      const layout = context.jiagzhuSourceTokenLayout("甲〈丙〉乙", [{ id: "c1", start: 1, end: 4 }])
      if (layout.source !== "甲〈丙〉乙") throw new Error("source-backed 夾注 text was altered")
      if (layout.first.length !== layout.second.length) throw new Error("nested 批注 was not balanced with its parent 夾注")
      if (!layout.first.concat(layout.second).some((token) => token.kind === "comment")) throw new Error("nested 批注 tokens lost their display role")
    JS

    path = Rails.root.join("app/javascript/controllers/han_jiagzhu.js")
    stdout, stderr, status = Open3.capture3("node", "-e", javascript, path.to_s)
    assert status.success?, [stdout, stderr].reject(&:empty?).join("\n")
  end

  test "Writer and Text Viewer share one font-size metric system" do
    typography = Rails.root.join("app/javascript/controllers/han_typography.js").read(encoding: "bom|utf-8")
    writer = Rails.root.join("app/javascript/controllers/word_processor_reliability.js").read(encoding: "bom|utf-8")
    viewer = Rails.root.join("app/javascript/controllers/corpus_reader_typography_reliability.js").read(encoding: "bom|utf-8")

    assert_includes typography, '--cv-font-size'
    assert_includes typography, '--han-main-font-size'
    assert_includes typography, '--han-column-advance'
    assert_includes typography, '--han-jiagzhu-font-size'
    assert_includes writer, 'from "controllers/han_typography"'
    assert_includes viewer, 'from "controllers/han_typography"'
    assert_includes writer, 'documentValue.settings.fontSizePx'
    assert_includes viewer, 'this._state.fontSizePx'
  end

end
