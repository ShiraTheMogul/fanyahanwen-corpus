# frozen_string_literal: true

require_relative "test_helper"
require "open3"

class AuthorityDateAnnotationJavascriptTest < ActiveSupport::TestCase
  test "regnal-date payload produces a dashed in-text hover annotation" do
    skip "node is not installed" unless system("node", "--version", out: File::NULL, err: File::NULL)

    javascript = <<~'JS'
      const fs = require("fs")
      const vm = require("vm")
      const source = fs.readFileSync(process.argv[1], "utf8").replace(/^\uFEFF/, "")

      class ClassList {
        constructor(names = []) { this.names = new Set(names) }
        contains(name) { return this.names.has(name) }
        add(...names) { names.forEach((name) => this.names.add(name)) }
        remove(...names) { names.forEach((name) => this.names.delete(name)) }
      }
      class Span {
        constructor(index, text) {
          this.attrs = new Map([["data-corpus-idx", String(index)]])
          this.classList = new ClassList(["cch"])
          this.textContent = text
        }
        getAttribute(name) { return this.attrs.has(name) ? this.attrs.get(name) : null }
        setAttribute(name, value) { this.attrs.set(name, String(value)) }
        removeAttribute(name) { this.attrs.delete(name) }
        hasAttribute(name) { return this.attrs.has(name) }
      }
      class Reader {
        constructor(spans) { this._spans = spans }
        querySelectorAll(selector) { return selector.includes("span.cch") ? this._spans : [] }
        querySelector() { return null }
      }

      const context = {
        console,
        MutationObserver: class { observe() {} disconnect() {} },
        document: {
          addEventListener() {}, readyState: "loading", querySelectorAll() { return [] },
          getElementById() { return null }, createElement() { return { id: "", style: {}, textContent: "" } },
          head: { appendChild() {} }
        },
        window: { requestAnimationFrame(callback) { callback() }, addEventListener() {}, removeEventListener() {} }
      }
      vm.createContext(context)
      vm.runInContext(source, context)

      const chars = Array.from("永曆二十五年。")
      const reader = new Reader(chars.map((char, index) => new Span(index, char)))
      reader._authorityAutoPayload = {
        context: { regnal_dates: [{ start: 0, end: 6, text: "永曆二十五年", absolute_year: 1671 }] }
      }
      context.applyDates(reader)

      if (!reader._spans[0].classList.contains("ne-auto-date")) throw new Error("date underline class was not applied")
      if (reader._spans[0].getAttribute("title") !== "永曆二十五年 → 1671 CE") throw new Error(reader._spans[0].getAttribute("title"))
      if (reader._spans[6].classList.contains("ne-auto-date")) throw new Error("punctuation was incorrectly included")
    JS

    path = Rails.root.join("app/javascript/authority_date_annotations.js")
    stdout, stderr, status = Open3.capture3("node", "-e", javascript, path.to_s)
    assert status.success?, [stdout, stderr].reject(&:empty?).join("\n")
  end
end
