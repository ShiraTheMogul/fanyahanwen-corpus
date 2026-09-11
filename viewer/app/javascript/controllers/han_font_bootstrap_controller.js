import { Controller } from "@hotwired/stimulus"

// Keeps Han font CSS variables "sticky" across Turbo renders and any DOM churn.
//
// Source of truth is the server-rendered <body data-han-font-*> attributes.
export default class extends Controller {
	connect() {
		this._apply = this._apply.bind(this)

		// Apply immediately, then again once fonts have a chance to settle.
		this._apply()
		setTimeout(this._apply, 0)
		setTimeout(this._apply, 250)

		if (document.fonts?.ready) {
			document.fonts.ready.then(() => this._apply()).catch(() => this._apply())
		}

		// Turbo can re-render the document and leave root-level custom properties
		// behind, so re-check whether this page is actually a font target.
		this._onTurboLoad = () => this._apply()
		document.addEventListener("turbo:load", this._onTurboLoad)
		document.addEventListener("turbo:render", this._onTurboLoad)
		document.addEventListener("turbo:frame-load", this._onTurboLoad)

		// Other controllers dispatch this when preferences change.
		this._onFontChanged = () => this._apply()
		window.addEventListener("han-font-changed", this._onFontChanged)
	}

	disconnect() {
		document.removeEventListener("turbo:load", this._onTurboLoad)
		document.removeEventListener("turbo:render", this._onTurboLoad)
		document.removeEventListener("turbo:frame-load", this._onTurboLoad)
		window.removeEventListener("han-font-changed", this._onFontChanged)
	}

	_apply() {
		const body = document.body
		if (!body) return

		const primary = (body.dataset.hanFontPrimary || body.dataset.hanFontFamily || "").trim()
		const stack = (body.dataset.hanFontStack || "").trim()
		const scopeActive = body.classList.contains("han-font-scope-all") ||
			body.classList.contains("han-font-scope-headwords")

		if (scopeActive && primary) {
			document.documentElement.style.setProperty("--han-font-primary", `"${primary}"`)
		} else {
			document.documentElement.style.removeProperty("--han-font-primary")
		}
		if (scopeActive && stack) {
			document.documentElement.style.setProperty("--han-font-stack", stack)
		} else {
			document.documentElement.style.removeProperty("--han-font-stack")
		}

		// Let other scripts know which family is saved, even when this page does
		// not use it. The next reader/editor page can then apply it normally.
		body.dataset.hanFontFamily = primary || body.dataset.hanFontFamily
	}
}
