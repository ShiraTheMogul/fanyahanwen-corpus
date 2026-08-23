# frozen_string_literal: true

require_relative "test_helper"
require "open3"

class AuthorityAnnotationJavascriptTest < ActiveSupport::TestCase
  # This is a Ruby-to-JavaScript false friend: Ruby's Array(value) normalizes
  # an existing array, while JavaScript's Array(value) wraps it as one element.
  # The latter made every JSON annotation response look like one nested item.
  test "automatic annotation JSON arrays remain flat and produce visible DOM marks" do
    skip "node is not installed" unless system("node", "--version", out: File::NULL, err: File::NULL)

    javascript = <<~'JS'
      const fs = require("fs")
      const vm = require("vm")
      let source = fs.readFileSync(process.argv[1], "utf8")
        .replace(/^\uFEFF?import \{ t \} from "i18n"\s*/, "const t = (key) => key;\n")

      class ClassList {
        constructor(names = []) { this.names = new Set(names) }
        contains(name) { return this.names.has(name) }
        add(...names) { names.forEach((name) => this.names.add(name)) }
        remove(...names) { names.forEach((name) => this.names.delete(name)) }
      }
      class Span {
        constructor(index) {
          this.attrs = new Map([["data-corpus-idx", String(index)]])
          this.classList = new ClassList(["cch"])
        }
        getAttribute(name) { return this.attrs.get(name) || null }
        setAttribute(name, value) { this.attrs.set(name, String(value)) }
        removeAttribute(name) { this.attrs.delete(name) }
      }
      class Reader {
        constructor(spans) {
          this._spans = spans
          this._authorityAutoSuppressions = new Set()
          this._authorityAutoEnabled = true
        }
        querySelectorAll(selector) { return selector.includes("span.cch") ? this._spans : [] }
        querySelector() { return null }
        getAttribute() { return "fixture.txt" }
      }

      const context = {
        console,
        URL,
        FormData: class {},
        Element: class {},
        MutationObserver: class { observe() {} disconnect() {} },
        document: {
          addEventListener() {}, readyState: "loading", querySelectorAll() { return [] }, querySelector() { return null },
          getElementById() { return null }, createElement() { return { style: {}, classList: new ClassList(), appendChild() {}, setAttribute() {}, addEventListener() {}, querySelector() { return null } } },
          head: { appendChild() {} }, body: { appendChild() {} }
        },
        window: {
          localStorage: { getItem() { return null }, setItem() {}, removeItem() {} },
          location: { origin: "http://example.test" }, addEventListener() {}, removeEventListener() {},
          requestAnimationFrame(callback) { callback() }, innerWidth: 1000, innerHeight: 1000
        },
        fetch: async () => { throw new Error("unused") },
        setTimeout, clearTimeout
      }
      vm.createContext(context)
      vm.runInContext(source, context)

      if (context.asArray([]).length !== 0) throw new Error("empty JSON array became non-empty")
      if (context.asArray([{ a: 1 }, { a: 2 }]).length !== 2) throw new Error("JSON array was nested")

      const reader = new Reader([0, 1, 2, 3].map((index) => new Span(index)))
      const stats = context.applyItems(reader, [{ start: 1, end: 3, kind: "person", text: "孔子", confidence: "high" }])
      if (stats.found !== 1 || stats.applied !== 1) throw new Error(JSON.stringify(stats))
      if (!reader._spans[1].classList.contains("ne-auto-person")) throw new Error("person class was not applied")

      const clanStats = context.applyItems(reader, [{ start: 0, end: 3, kind: "clan", text: "有虞氏", confidence: "high" }])
      if (clanStats.found !== 1 || clanStats.applied !== 1) throw new Error(JSON.stringify(clanStats))
      if (!reader._spans[0].classList.contains("ne-auto-clan")) throw new Error("clan class was not applied")
      if (reader._spans[0].classList.contains("ne-auto-person")) throw new Error("clan fell back to person styling")
      if (!source.includes('clan: "clan"')) throw new Error("clan popover label is missing")
      if (!source.includes(".ne-auto-clan")) throw new Error("clan CSS is missing")
    JS

    path = Rails.root.join("app/javascript/authority_auto_annotations.js")
    stdout, stderr, status = Open3.capture3("node", "-e", javascript, path.to_s)
    assert status.success?, [stdout, stderr].reject(&:empty?).join("\n")
  end

  test "author authority linker normalizes payload arrays with Array.isArray" do
    source = Rails.root.join("app/javascript/author_authority_link.js").read(encoding: "bom|utf-8")
    assert_includes source, "asArray(payload.authors)"
    assert_includes source, "asArray(payload.matches)"
    refute_match(/\bArray\(payload\.(?:authors|matches)/, source)
  end
end
