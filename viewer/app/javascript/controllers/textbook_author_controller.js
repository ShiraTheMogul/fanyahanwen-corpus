import { Controller } from "@hotwired/stimulus";

/*
Template-palette authoring controller.

Goal: reduce repetitive YAML typing NOW, without forcing a full WYSIWYG editor immediately.

Patterns:
- insertAtCursor(textarea, snippet)
- slugify(title)
- syncHeader(): writes title/slug into YAML header if present

The "real" editor later:
- keeps the same templates, but generates YAML behind the scenes.
*/
export default class extends Controller {
  static targets = ["raw", "title", "slug"];

  connect() {}

  focusRaw() {
    if (this.hasRawTarget) this.rawTarget.focus();
  }

  insert(e) {
    const key = e.currentTarget.dataset.template;
    const snippet = this._template(key);
    if (!snippet) return;
    this._insertAtCursor(this.rawTarget, snippet);
    this.rawTarget.focus();
  }

  slugify() {
    const t = (this.titleTarget?.value || "").toString();
    const slug = this._slugify(t);
    if (this.slugTarget) this.slugTarget.value = slug;
  }

  syncHeader() {
    const title = (this.titleTarget?.value || "").toString().trim();
    const slug = (this.slugTarget?.value || "").toString().trim();
    if (!this.hasRawTarget) return;

    let y = this.rawTarget.value || "";
    // Replace or insert title/slug lines near the top.
    y = this._upsertHeaderLine(y, "title", title || "Untitled lesson");
    y = this._upsertHeaderLine(y, "slug", slug || this._slugify(title || "untitled"));
    this.rawTarget.value = y;
  }

  _upsertHeaderLine(yaml, key, value) {
    const re = new RegExp(`^${key}:.*$`, "m");
    const line = `${key}: ${this._yamlQuoteIfNeeded(value)}`;
    if (re.test(yaml)) return yaml.replace(re, line);
    // Insert after schema_version if present, else at top.
    if (/^schema_version:/m.test(yaml)) {
      return yaml.replace(/^schema_version:.*$/m, (m) => `${m}\n${line}`);
    }
    return `${line}\n${yaml}`;
  }

  _yamlQuoteIfNeeded(s) {
    // Quote strings containing ':' or leading/trailing spaces.
    if (s.includes(":") || s !== s.trim()) return JSON.stringify(s);
    return s;
  }

  _insertAtCursor(textarea, text) {
    if (!textarea) return;
    const start = textarea.selectionStart ?? textarea.value.length;
    const end = textarea.selectionEnd ?? textarea.value.length;
    const before = textarea.value.slice(0, start);
    const after = textarea.value.slice(end);
    textarea.value = before + text + after;

    const pos = start + text.length;
    textarea.selectionStart = textarea.selectionEnd = pos;
  }

  _slugify(s) {
    return s
      .toLowerCase()
      .replace(/['"]/g, "")
      .replace(/[^a-z0-9]+/g, "_")
      .replace(/^_+|_+$/g, "")
      .slice(0, 64) || "lesson";
  }

  _template(key) {
    const T = {
      context: `\n  - type: context\n    title: Context\n    body: "Write your lead-in here."\n`,
      match_select: `\n  - type: match\n    title: Match (click)\n    prompt: "Click the pairs."\n    pairs:\n      - left: "日"\n        right: "sun"\n      - left: "月"\n        right: "moon"\n    options:\n      mode: select\n      shuffle: true\n`,
      match_drag_cards: `\n  - type: match\n    title: Match (drag cards)\n    prompt: "Drag tiles onto the matching cards."\n    pairs:\n      - left: { text: "日", class: "chongxi-seal" }\n        right: { text: "sun" }\n      - left: { text: "月", class: "chongxi-seal" }\n        right: { text: "moon" }\n    options:\n      mode: drag\n      layout: cards\n      tile_scale: xl\n      shuffle: true\n`,
      arrange: `\n  - type: arrange\n    title: Arrange\n    prompt: "Put the tiles in the correct order."\n    bank:\n      - { id: yi, text: "一" }\n      - { id: shi, text: "十" }\n      - { id: liu, text: "六" }\n    answer: [yi, shi, liu]\n    options:\n      shuffle: true\n      tile_scale: lg\n`,
      gap_input: `\n  - type: gapfill\n    title: GapFill (type)\n    prompt: "Fill the missing word."\n    segments:\n      - "學而時習之，"\n      - { id: a, answer: "不", width: 3 }\n      - "亦說乎？"\n`,
      gap_drag: `\n  - type: gapfill\n    title: GapFill (drag)\n    prompt: "Drag tiles into the blanks."\n    segments:\n      - "有"\n      - { id: a, answers: ["er"], width: 4 }\n      - "人，"\n      - { id: b, answers: ["yu"], width: 4 }\n      - "此。"\n    bank:\n      - { id: er, text: "二" }\n      - { id: san, text: "三" }\n      - { id: yu, text: "於" }\n      - { id: yi, text: "以" }\n    options:\n      mode: drag\n      shuffle: true\n      tile_scale: lg\n`,
      convert: `\n  - type: convert\n    title: Convert\n    prompt: "Convert the number."\n    input: "十六"\n    profile: zhouli_numerals\n`,
    };
    return T[key] || "";
  }

  previewDraft(event) {
    // Copy current YAML to the hidden field in the preview form, then submit it.
    // This avoids per-form CSRF issues that happen when using `formaction` on a single form.
    event.preventDefault();

    const raw = this.rawTarget.value;
    const slug = (this.hasSlugTarget ? this.slugTarget.value : "") || "";

    const previewForm = document.getElementById("tb_preview_form");
    const previewRaw  = document.getElementById("tb_preview_raw");
    const previewSlug = document.getElementById("tb_preview_slug");

    if (!previewForm || !previewRaw || !previewSlug) {
      // No preview form wired (route missing or template not loaded).
      return;
    }

    previewRaw.value = raw;
    previewSlug.value = slug;
    previewForm.submit();
  }

}
